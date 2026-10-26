# frozen_string_literal: true

require_relative "safe_path"
require_relative "source_files"
require_relative "redaction/bundler_credentials"

# strscan and json are gems an app's bundle pins, and the CLI reads files before the app boots: each loads when first named.
autoload :StringScanner, "strscan"
autoload :JSON, "json"
autoload :Set, "set"

module RailsAiContext
  # Every value that leaves the app through this gem - config source slices,
  # log lines, query rows, environment values - passes through here first.
  # One set of patterns, one marker vocabulary, and redact-and-shorten as a
  # single operation so no caller can shorten a credential out of reach of
  # the pattern that would have caught it.
  module Redaction
    FILTERED = "[FILTERED]"
    # The one semantic marker: an address in a log line is worth telling
    # apart from a secret, because it says what kind of data was there.
    EMAIL = "[EMAIL]"

    PLACEHOLDER_NAMES = SafePath::PLACEHOLDER_SUFFIXES.map { |suffix| Regexp.escape(suffix.delete_prefix(".")) }.join("|")
    EXAMPLE_FILE = /\.(?:#{PLACEHOLDER_NAMES})\b/
    YAML_FILE = /\.ya?ml(?:\.(?:erb|#{PLACEHOLDER_NAMES}))*\z/i
    SOURCE_OR_DOC_EXTNAMES = (SourceFiles::EXTNAMES + %w[.ru .md .markdown .txt .rdoc .adoc]).freeze
    # A Docker build file as Docker and its tooling name one: Dockerfile, Dockerfile.prod, Dockerfile-dev, web.Dockerfile.
    # A name ending in a source or doc extension (dockerfile_parser.rb, Dockerfile.md) is not one.
    DOCKER_FILE = %r{(?:\A|/)(?:(?:Docker|Container)file(?![^/]*(?:#{SOURCE_OR_DOC_EXTNAMES.map { |ext| Regexp.escape(ext) }.join("|")})\z)
                     (?:[._-][^/]*+)?|[^/]*\.(?:docker|container)file)\z}ix
    # A log, rotated or kept ones included: Logger's development.log.0, logrotate's .log-20261001, .log-2026-10-01 and .log.old, and a .log.bak.
    LOG_FILE = /\.log(?:\.\d+|-\d{4}-?\d{2}-?\d{2}(?:-?\d{2})?|\.old|\.bak)?\z/i

    # Regex by design: these scrub vocabulary out of values already read from
    # the AST or a log file rather than parsing structure. A credential can
    # sit in an interpolation, a heredoc or a bare string, and no node type
    # marks one - the words are the signal.
    SECRET_WORD = /password|passwd|secret|token|api_key|apikey|access_key|private_key|credentials|creds?|
                   pepper|salt|master_key|signing_key|encryption_key|deterministic_key|cipher_key|aes_key|cbc_key|gcm_key|hmac_key|
                   recovery_code|recoverycode|backup_code|backupcode/xi

    # `primary_key` is ordinary ActiveRecord vocabulary; under
    # `active_record.encryption` it is a credential. Only the path tells them
    # apart, so these are matched against the whole path, not the leaf.
    SECRET_PATH = /encryption\.(?:primary_key|deterministic_key|key_derivation_salt)\z/i

    # The secret word has to be a whole underscore-delimited part of the name,
    # so `secret_key` and `api_key` match while `passwordless_login` does not.
    # Its plural ends a name (`api_keys`, `tokens`), so `tokens_used` stays a count.
    # A name is a whole word, so it is taken atomically: when what follows it
    # fails, trying the word split another way cannot help, and doing so cost
    # the square of a long word with the secret word in many of its parts.
    SECRET_NAME = /(?<!\w)(?>(?:\w+_)?(?:#{SECRET_WORD})(?:s(?!\w)|(?:_\w+)?(?!\w)))/i

    # A name ending in `_KEY`/`Key`/`key` is as often a cache or i18n key as a credential,
    # so under it only a credential-looking value is filtered (see key_credential?).
    KEYISH_NAME = /(?<!\w)(?:\w*_)?(?:KEY|[Kk]ey)(?!\w)|(?<!\w)[a-z][A-Za-z0-9]*Key(?!\w)/

    # `password_length` and `token_expiry` describe a secret rather than
    # being one; their values are policy, and filtering them hides config the
    # reader asked for.
    DESCRIPTOR_SUFFIX = /_(?:length|size|min|max|expiry|ttl|strategy|regex|format|field|params?|columns?|names?|enabled|required|count|algorithm|method|type|salt_length|at|on)\z/i

    # `=(?!>)` so the alternation cannot backtrack into matching the `=` of a
    # `=>` and treating the stray `>` as the value.
    ASSIGN = /\s*(?::|=>|=(?!>))\s*/

    # Userinfo holds no quote, bracket or slash, so the match cannot run across JSON or a path. It is
    # read from the `://` a scheme's letter stands before, whatever stands before the scheme (`:-` in
    # a shell default). The user part may hold an `@` (an email address) and the password runs to the
    # last `@` before the host; the match starts at `://` only, so a long run costs its length.
    URI_USERINFO = %r{(?<=[a-z0-9+.-])(://)[^\s/"'<>:]*+:[^\s/"'<>]*@}i
    # Shapes an environment value carries a secret in where no name says so: a webhook's address, a
    # token in a query, and the runs secret_shaped? reads.
    ENV_SECRET_SHAPES = [
      %r{\b(?:hooks\.slack(?:-gov)?\.com|(?:discord|discordapp)\.com/api/webhooks|webhook\.office\.com|outlook\.office\.com/webhook|hooks\.zapier\.com)\b}i,
      %r{/(?:web)?hooks?/[A-Za-z0-9]{16,}}i,
      /[?&][\w.-]*(?:token|key|secret|signature|sig|password|passwd|pwd|auth|authorization|credential)=/i
    ].freeze
    # A run a key is written in: `/`, `.`, `-` and `_` break it, so a path, a host or a slug is many runs.
    OPAQUE_RUN = /[A-Za-z0-9+=]{16,}/
    # A URL's user part with no password: a name shows, a key in its place (a DSN's) does not.
    ENV_USER = %r{://([^\s/"'<>@:]+)@}
    # One case on each side of at most four digits. Each part is atomic, since overlapping groups backtrack
    # on Ruby 3.1; `\d{0,4}+` would be a repeat in Ruby, not possessive.
    NAME_USER = /\A(?:[a-z_.-]*+|[A-Z_.-]*+)(?>\d{0,4})(?:[a-z_.-]*+|[A-Z_.-]*+)\z/
    GROUPED_HEX = /\A\h{16,}\z/
    QUOTED_SECRET = /#{SECRET_NAME}#{ASSIGN}["'][^"']*["']/
    # Stops before a collection: the value pattern ends at the first comma or
    # bracket, so matching `token: ["a", "b"]` would cut mid-literal and
    # leave the tail of the credential in place. Collections are handled by
    # filtering the whole slice instead. Symbols are skipped for the reason
    # policy_value? skips them - `password: :from_env` names where the value
    # comes from, it is not the value.
    BARE_SECRET = /#{SECRET_NAME}#{ASSIGN}(?!["'\[{:])[^\s,;)\]}]+/

    COLLECTION_LITERAL = /\A\s*[\[{]/

    # A value actually shaped like a credential: a long hex blob or a vendor
    # prefix. For callers reading a bare value with no key beside it to match
    # on.
    CREDENTIAL_SHAPE = /[a-f0-9]{16,}|sk_|pk_/i

    ANSI_ESCAPE = /\e\[[0-9;]*[mGKHF]/
    # An address in any script (jürgen@example.com, anna@münchen.de). It starts
    # where a run of name characters starts and takes the name whole, with
    # nothing to give back, so a 1 MB line of near-addresses costs a pass,
    # not a pass per character.
    EMAIL_PATTERN = /(?<![\p{L}\p{M}\p{N}._%+-])[\p{L}\p{M}\p{N}._%+-]++@(?:[\p{L}\p{M}\p{N}-]++\.)+[\p{L}\p{M}]{2,}(?![\p{L}\p{M}\p{N}-])/
    # The same for a line in another encoding, which a Unicode pattern cannot read.
    ASCII_EMAIL_PATTERN = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}\b/i
    DOTENV_LINE = /\[dotenv\]\s+Set\s+.*/i
    # A log value: quoted whole, or bare up to a space, a quote or a separator,
    # so the quotes and the comma around it survive its redaction.
    LOG_VALUE = /(?!["']?\[FILTERED\])(?:"[^"]*"|'[^']*'|[^\s"',;)\]}]+)/

    # Formats that are a credential wherever they appear: nothing else in
    # code or config is written this way, so one may follow an `_` (a route name). A JWT's signature may be empty.
    CREDENTIAL_TOKENS = [
      /(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
      # A key's first digit sits near its start: a bound keeps each try short when a run of `sk-` offers
      # a start at every repeat. A JWT is read by filter_jwts.
      /(?<![A-Za-z0-9])sk_(?:live|test)_[A-Za-z0-9]{24,}\b/,
      /(?<![A-Za-z0-9])rk_(?:live|test)_[A-Za-z0-9]{24,}\b/,
      /(?<![A-Za-z0-9])SG\.[A-Za-z0-9_-]{22,}\.[A-Za-z0-9_-]{10,}\b/,
      /(?<![A-Za-z0-9])xox[bpras]-[A-Za-z0-9-]{10,}\b/,
      /(?<![A-Za-z0-9])gh[opsur]_[A-Za-z0-9]{36,}\b/,
      /(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{40,}\b/,
      /(?<![A-Za-z0-9])glpat-[A-Za-z0-9_-]{20,}\b/,
      /(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36,}\b/,
      /(?<![A-Za-z0-9])sk-(?:ant-|proj-)?(?=[\w-]{0,255}\d)[\w-]{32,}/
    ].freeze

    # The characters a JWT's three parts and their dots are written in, a run long enough to hold one.
    JWT_RUN = /[A-Za-z0-9_.-]{24,}/

    PEM_BEGIN = /-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----/
    PEM_END = /-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----/
    # A marker opens a block only when it ends its line (a regex or a string naming it is code),
    # and the block lasts while its lines read as key body: base64, an armor header, blank.
    LINE_TAIL = %r{(?:\\n)?["'`]?[ \t]*(?:[\\+,][ \t]*)?\z}
    PEM_OPENS = /#{PEM_BEGIN}[ \t]*(?:\\n)?(?:\z|(?<=\\n)["'`][ \t]*[\\+,]?[ \t]*\z|["'`][ \t]*[\\+,][ \t]*\z)/
    PEM_BODY = %r{\A\s*+["'`]?(?:[A-Za-z0-9+/=]+|(?:Proc-Type|DEK-Info|Version|Comment):.*)?#{LINE_TAIL}}
    # A key in one literal: the marker, any armor headers, then a body-length base64 run. Searched from
    # the first marker only (pem_inline?): tried from every marker, a run of markers cost their square.
    PEM_INLINE_BODY = %r{[A-Za-z0-9+/]{40}}
    # A key in a payload value: the marker to its end marker, or to the end of the value.
    PEM_BLOCK = /#{PEM_BEGIN}.*?(?:#{PEM_END}|\z)/m

    # Each entry is [pattern, replacement]. The replacement is spelled beside
    # the pattern rather than worked out later by grepping the pattern's own
    # source for a distinguishing substring.
    #
    # The names are matched, not looked behind for. Under /i Unicode case
    # folding makes `s` two bytes long (`ſ` is one), so a look-behind holding
    # one has no fixed length, and Onigmo before Ruby 3.4 raises on it as
    # soon as the line carries any non-ASCII character - which every
    # development log's `↳` query-source line does. read_logs then failed
    # outright, and diagnose lost its log section.
    LOG_PATTERNS = ([
      # A `value` group, which ends the match, is filtered in place, keeping
      # the name and the quotes. The Authorization header goes whole, its
      # scheme with it, however the line spells it: `Authorization: Basic ...`,
      # a quoted value, a hash or JSON key, Rack's `HTTP_AUTHORIZATION`.
      # Unquoted, the name needs a header's space after its colon (so
      # `Authorization::UnauthorizedError` is a class), or an env dump's `=` or
      # a debug line's `=>`; after `name=` an `&` starts the next query parameter.
      [ /(?:(?<quote>["'])(?:HTTP_(?:PROXY_)?|Proxy-|X-)?authorization\k<quote>\s*(?:=>|:|=(?!>))\s*|authorization(?::\s+|\s*=>\s*|\s*(?<query>=)(?![=~>])\s*))
         (?<value>(?!["']?\[FILTERED\]|(?:true|false|nil|null)(?=[\s,;)\]}]|\z|(?(<query>)&|(?!))))(?:"(?:[^"\\]|\\.)*+"|'(?:[^'\\]|\\.)*+'
           |(?:Token|Digest)\s+[\w-]+=(?:"[^"]*"|\[FILTERED\]|[^\s",]+)(?:,\s*[\w-]+=(?:"[^"]*"|\[FILTERED\]|[^\s",]+))*
           |(?:(?:Bearer|Basic|Token)\s+)?(?:\[FILTERED\]|="[^"]*"|(?(<query>)[^\s"',;&)\]}]|[^\s"',;)\]}]))+))/xi, :value ],
      [ /cookie:\s(?<value>#{LOG_VALUE})/i, :value ],
      [ /session_id=(?<value>#{LOG_VALUE})/i, :value ],
      [ /_session=(?<value>#{LOG_VALUE})/i, :value ],
      [ PEM_BEGIN, FILTERED ]
    ] + CREDENTIAL_TOKENS.map { |pattern| [ pattern, FILTERED ] }).freeze

    # In source, only a string literal is a value; the rest is code to leave byte for byte.
    STRING_LITERAL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/
    DOUBLE_QUOTED = /"(?:[^"\\]|\\.)*+"/
    SINGLE_QUOTED = /'(?:[^'\\]|\\.)*+'/

    # A key is a name, bare or quoted whole (`'api/verify_token'` is a route path). Password
    # words hold short literals (a PIN), so they stay out of SECRET_WORD, which logs share.
    # `requirepass` and `masterauth` are Redis's two password settings, and `MYSQL_PWD` and
    # `REDISCLI_AUTH` the variables the mysql and redis-cli clients read theirs from.
    PASSWORD_WORD = /passphrase|password|passwd|pass|pin|requirepass|masterauth|mysql_pwd|rediscli_auth/i
    # A long password word that ends a name may have another joined on before it: Postgres's
    # `PGPASSWORD`, `dbpassword`, a camel-cased `userPassword`. A short word may not (`bypass`,
    # `spin`), nor may one with more after it (`ONEPASSWORD_VAULT` names 1Password's vault).
    PASSWORD_NAME = /(?<!\w)(?>(?:\w+_)?(?:(?:#{PASSWORD_WORD})(?:_\w+)?|[a-z\d]+(?:passphrase|password|passwd))(?!\w))/i
    # JSON and JavaScript write a key's words in camel case: one of them is the secret's
    # (`accessToken`, `clientSecret`, `secretAccessKey`, `jwtSecretKey`, `otpBackupCodes`), as one
    # between underscores is in SECRET_NAME. `tokenizer` and `secretary` have none.
    CAMEL_SECRET_NAME = /(?<!\w)(?>(?:secret|token|[a-z][a-z\d]*(?:[A-Z][a-z\d]*)*?(?:Secret|Token|RecoveryCode|BackupCode))(?:s(?!\w)|(?:[A-Z][a-z\d]*)*(?!\w)))/
    # Each of these takes a whole word, and when two of them can, they take the same one.
    KEY_NAME = /(?>#{SECRET_NAME}|#{PASSWORD_NAME}|#{KEYISH_NAME}|#{CAMEL_SECRET_NAME})/
    # A header or an attribute joins its words with dashes (`"X-Api-Key"`, `"x-auth-token"`). Quoted,
    # one with a part a key name reads is taken whole and read with its dashes as underscores (see
    # key_name); one with none (`"Content-Type"`) is not matched, so its literal stays in reach of
    # every pattern. The run is taken in one pass, never given back, so a long one costs no more.
    DASHED_KEY_NAME = /(?=[\w-]*?(?:#{KEY_NAME}))[\w-]++/

    # A log line spells an assignment four ways: `key=value`, `key: value`,
    # `"key"=>"value"` and `"key":"value"`. One pattern over KEY_NAME covers
    # every secret-ish name in all four, a camel-cased or joined one included
    # (`{"accessToken"=>...}`, `PGPASSWORD: ...`); a per-name lookbehind list
    # covered four names in two shapes and shipped the rest verbatim.
    # Lookbehind is unavailable here because KEY_NAME is variable width,
    # so the key and the assignment are captured and written back. A header
    # name comes whole (`"X-Api-Key"=>`), its dashes read as underscores (see
    # key_name): a run of words and dashes with a secret-ish part, taken from
    # its start in one pass, as DASHED_KEY_NAME takes one in source.
    # A list or a hash as one value: quoted commas and brackets included, nested three deep, and to the
    # line's end when cut off. Spelled out per depth, since a recursive call costs the square of an unclosed run.
    LOG_COLLECTION = 3.times.reduce(nil) do |inner, _|
      /[\[{](?:\\.|"(?:[^"\\]|\\.)*+"?|'(?:[^'\\]|\\.)*+'?|[^\[\]{}"'\\]#{"|#{inner}" if inner})*+[\]}]?/
    end
    # Marks where a filtered collection ran on past what LOG_COLLECTION reads; the line is cut there.
    RUNS_ON = "\u0000rails-ai-context-runs-on\u0000"
    LOG_SECRET_ASSIGNMENT = /
      (\\?["']?)((?<![\w-])(?=[\w-]*?(?:#{KEY_NAME}))[\w-]++)\1
      (\s*(?:=>|:(?!:)|=(?!>))\s*)
      (?!\\?["']?\[FILTERED\]|\$\d+(?![\w$])|\?(?![\w?]))(?:"([^"]*)"|'([^']*)'|\\"((?:\\\\\\\\|\\\\\\"|\\\\[^\\"]|[^\\"])*+)\\"
        |(#{LOG_COLLECTION})|([^\s,;&)\]}]+))
    /xi
    # A `["name", "value"]` pair in a query's logged binds. Active Record filters a bind only
    # when config.filter_parameters lists its name, which pre-Rails-7 apps often leave at
    # [:password], so a token or reset key logs in full. The name and the quoted value are
    # captured and the value filtered when the name is a secret; a bare value (a number, nil) is
    # left, as is the `$n` placeholder in the SQL before the binds.
    LOG_BIND = /\[\s*"((?:[^"\\]|\\.)*)"\s*,\s*("(?:[^"\\]|\\.)*")\s*\]/
    LOG_UNNAMED_BIND = /\[\s*nil\s*,\s*("(?:[^"\\]|\\.)*")\s*\]/

    # A string literal in a logged statement, with the letters one may carry before its quote (x'..', _binary'..'),
    # and to the line's end when the line cuts it off. MySQL escapes a quote with a backslash and quotes names in
    # backticks; standard SQL doubles the quote.
    SQL_STRING = /(?:[xXbBnN])?'(?:[^']|'')*'?/
    MYSQL_STRING = /(?:[xXbBnN]|_\w+)?'(?:[^'\\]|\\.|'')*'?/m
    # MySQL reads double quotes as a string too, where Active Record's backquotes name the columns.
    MYSQL_DQ_STRING = /"(?:[^"\\]|\\.|"")*"?/m
    # PostgreSQL's E'..' and MySQL's _charset'..' read a backslash as an escape whatever quotes the names.
    ESCAPED_STRING = /(?:[eE]|_\w+)'(?:[^'\\]|\\.|'')*'?/m
    SQL_WORD = /`(?:[^`]|``)*`?|"(?:[^"\\]|\\.|"")*"?|[A-Za-z_][\w$]*/
    # A comment, Rails' query log tags among them, to the line's end when cut off. MySQL runs `/*!` and
    # `/*+` as SQL, so those are read as SQL. A tag's quoted value may hold `*/`; an apostrophe in prose
    # (`/* don't */`) starts no value.
    SQL_COMMENT = %r{/\*(?![!+])(?:(?<![\w.-])[\d.-]*+[A-Za-z_][\w.-]*+\s*=\s*'(?:[^'\\]|\\.)*+'|.)*?(?:\*/|\z)}m
    # A query log tag: sqlcommenter's key='value' or the legacy key:value. The key starts at its word's first
    # letter, read from the word's start so a long word is read once.
    COMMENT_TAG = /(?<![\w.-])[\d.-]*+(?<key>[A-Za-z_][\w.-]*+)\s*+[=:]\s*(?<value>'(?:[^'\\]|\\.)*'?|[^,\s*\/]+)/
    # PostgreSQL's array overlap and containment compare a column with a value too.
    SQL_COMPARISON = %w[= != <> <=> < > <= >= && @> <@].freeze
    # Read as one token, so the `>` in a JSON arrow is no comparison.
    SQL_OPERATOR = /<=>|!=|<>|<=|>=|->>|->|\#>>|\#>|@>|<@|&&|\?\||\?&|\d[\w.]*/
    JSON_ARROWS = %w[-> ->> #> #>>].freeze
    # A statement and a clause of one, as against a log line of prose.
    SQL_STATEMENT = /\A(?:select|insert|update|delete|replace|with|upsert)\z/i
    SQL_CLAUSE = /\A(?:from|into|set|values|where)\z/i
    SQL_VALUES = /\Avalues?\z/i
    # What a column name stands after; a word after anything else (`COLLATE "C"`, `::text`) is no column.
    SQL_COLUMN_LEAD = /\A(?:where|and|or|on|set|not|when|having|by|then|else|case|select)\z/i
    # Where PostgreSQL's key error ends its values, which can hold parentheses of their own.
    KEY_VALUES_END = /\)(?= (?:already exists|is not present|is still referenced|conflicts with))/
    KEY_VALUES_START = /(?:Key|existing key) \(/
    # Each pair of a query's logged binds, named or not, in the order of the `$n` placeholders.
    ANY_BIND = /\[\s*(nil|"(?:[^"\\]|\\.)*")\s*,\s*("(?:[^"\\]|\\.)*"|[^\[\]"]*?)\s*\]/
    JSON_STRING = /"(?:[^"\\]|\\.)*"/
    # MySQL repeats the statement from where it stopped reading in a syntax error.
    SYNTAX_NEAR = "for the right syntax to use near '"

    # A quoted key may close an index (`ENV["API_TOKEN"] =`); the assignment may be `||=` or another op-assign.
    SECRET_KEY = /"(?<name>#{DASHED_KEY_NAME})"\]?|'(?<name>#{DASHED_KEY_NAME})'\]?|(?<![\w"'\/\\-])(?<name>#{KEY_NAME})/
    KEYED_LITERAL = /(?:#{SECRET_KEY})(?<assign>\s*(?::|=>|(?:\|\||&&|[-+*\/|&])?=(?![=~>]))\s*)(?<literal>#{STRING_LITERAL})/

    # A call or block whose first argument names the secret holds its value: a setter or a
    # fetch default (`ENV.fetch("SECRET_KEY_BASE", "...")`), a block's value (`let(:api_key) { "..." }`),
    # a `default:` (`option :client_secret, :string, default: "..."`), a `credentials.fetch` default.
    # Any other call's second argument is just another argument (`include("password", "email")`).
    SECRET_ARG = /:(?<name>#{KEY_NAME})|"(?<name>#{KEY_NAME})"|'(?<name>#{KEY_NAME})'/
    # A call's receiver and name are read from where their run of characters starts, and taken
    # whole: tried from each character, a long word or hex blob cost the square of its length,
    # a minute for 80 KB on Ruby 3.1, and on 3.2 and later passed the second Rails 8 allows a match.
    CALL_RECEIVER = /(?<![\w.!?])[.!?]*+\w[\w.!?]*+/
    CALL_KEYED = /
      \b(?:fetch|store|stub_const|update_column|update_attribute|write_attribute|set|put|append|setenv)
      \(\s*(?:#{SECRET_ARG})\s*,\s*(?<literal>#{STRING_LITERAL})
    |
      #{CALL_RECEIVER}\(\s*(?:#{SECRET_ARG})\s*\)\s*\{\s*(?<literal>#{STRING_LITERAL})
    |
      #{CALL_RECEIVER}[(\ ]\s*:(?<name>#{KEY_NAME})(?:\s*,\s*:\w+)*\s*,\s*default:\s*(?<literal>#{STRING_LITERAL})
    |
      (?<name>credentials)\.(?:fetch|dig)\([^()]*?,\s*(?<literal>#{STRING_LITERAL})
    /x

    # Shell, Dockerfile, compose, env files and log lines: `NAME=value`, no space
    # around the `=` (Ruby never writes that), the value unquoted and not `$VAR`/ERB.
    # The same shape sits in a URL query, a quoted env entry or a flag
    # (`--password=...`, `x-api-key=...`), so the value stops where a quote,
    # bracket or separator starts; a `:name=` setter symbol, a `(?<=name=`
    # lookbehind and a regex's wildcard (`/--password=.+/`) are not assignments. A comma that no
    # `name=` follows continues the value, a list of keys (`API_KEYS=k1,k2`).
    # A Dockerfile's legacy `ENV NAME value`: the value runs to the end of the line and is judged by its first word.
    DOCKER_ENV = /\A(?<head>[ \t]*(?<instruction>(?i:ENV))[ \t]+(?<name>BUNDLE_[A-Z0-9_]+|#{KEY_NAME})[ \t]+)(?!=)(?<value>\S(?:.*\S)?)/
    ENV_ASSIGNMENT = /(?<![\w.:=!])(?<name>#{KEY_NAME})=(?!\#\{|\.[*+?])(?<value>[^\s"'`$<>\\()\[\]{},;&]++(?:,(?![\w-]+=[^\s=,;&"'])[^\s"'`$<>\\()\[\]{},;&]++)*+)/

    # A query parameter named with brackets (`user[password]=`, `api_keys[]=`), raw or percent-encoded
    # as Rails' filtered path writes it.
    QUERY_PARAM = /(?<![^\s?&"'])(?<name>[\w-]+(?:(?:\[|%5B)[\w-]*(?:\]|%5D))++)=(?!\[FILTERED\]|%5BFILTERED%5D)(?<value>[^&\s"'#]+)/i

    # A flag may take its value as the next word, bare or quoted (`redis-server --requirepass ...`,
    # `docker login --password "..."`), its name read as a dashed name is (key_name). Prose names a
    # flag that way too (`the --password option`), so there only a value with a digit is a secret
    # (flag_secret?). A `--no-...` switch takes no value; a value that is another flag, a variable,
    # ERB, a placeholder or a path (`~/`, `./`, `/`) is no literal.
    FLAG_ARGUMENT = /
      (?<![\w-])--(?!no-)(?<name>[A-Za-z][\w-]*+)[ \t]++
      (?:(?<quote>["'])(?<value>[^\s"'`$<>\\#%{~.\/][^"'`$\\]*?)\k<quote>
        |(?<value>[^\s"'`$<>\\()\[\]{},;&|#%=~.\/-][^\s"'`$<>\\()\[\]{},;&|]*+))
    /x

    # An HTTP auth scheme says the word after it is a credential (`Bearer <token>`, `Basic <base64>`,
    # `Token <token>`), under an Authorization key, in a curl line or a cassette alike. "Authorization"
    # is no secret word and the value has a space, so no key rule reads it; the credential alone goes,
    # wherever it sits, when it is shaped like one (scheme_credential?). `Bearer #{token}`,
    # `Basic realm=...` and `Bearer YOUR_TOKEN` hold none.
    AUTH_CREDENTIALS = %r{\b(?:Bearer|Basic|Token)[ \t]++(?<credentials>[\w.~+/-]++=*+)(?![\w.~+/=-])}i

    # YAML writes a string unquoted, so there a secret-named key's plain
    # scalar is a literal too.
    # A Ruby library's YAML may write its keys as symbols (`:password: ...` in config/sidekiq.yml).
    YAML_SCALAR = /\A(?<head>\s*:?["']?(?<name>#{KEY_NAME})["']?:[ \t]+)(?<value>[^\s#][^#]*?)(?<tail>\s+#.*)?\z/

    # A mapping a secret's name names holds the secret in its `value`. Heroku's app.json writes
    # `"STRIPE_SECRET_KEY": { "value": "..." }` on one line or across several, a YAML file
    # `STRIPE_SECRET_KEY:` over `value: ...`, and render.yaml and a Kubernetes manifest name a
    # list entry by a sibling (`- key: CLIENT_SECRET`, `- name: API_TOKEN`) over its `value:`.
    NAMED_OBJECT = /"(?<name>#{DASHED_KEY_NAME})"[ \t]*:[ \t]*\{[^{}]*\}/
    NAMED_VALUE_PAIR = /(?<head>"value"[ \t]*:[ \t]*")(?<value>[^"]*)"/
    GIVEN_NAME = /#{KEY_NAME}|#{BundlerCredentials::NAME}/
    NAMING_LINE = /\A(?<indent>[ \t]*)(?:-[ \t]+(?:key|name)[ \t]*:[ \t]+["']?(?<name>#{GIVEN_NAME})["']?|["']?(?<name>#{GIVEN_NAME})["']?[ \t]*:[ \t]*+\{?)[ \t]*\z/
    VALUE_HEAD = /\A[ \t]*["']?value["']?[ \t]*:[ \t]*/
    VALUE_LINE = /\A(?<head>[ \t]*["']?value["']?[ \t]*:[ \t]*)(?:(?<quote>["'])(?<value>[^"']*)\k<quote>|(?<value>[^\s"'#,{\[][^#,]*?))(?<tail>[ \t]*,?[ \t]*(?:#.*)?)\z/
    STRUCTURED_FILE = /#{YAML_FILE}|\.json(?:\.(?:#{PLACEHOLDER_NAMES}))*\z/i

    class << self
      # Source slices and config values.
      def call(value)
        return value unless value.is_a?(String)

        value
          .gsub(URI_USERINFO) { "#{Regexp.last_match(1)}#{FILTERED}@" }
          .gsub(QUOTED_SECRET) { |m| descriptor?(m) ? m : m.sub(/["'][^"']*["']\s*\z/, %("#{FILTERED}")) }
          .gsub(BARE_SECRET) { |m| descriptor?(m) ? m : m.sub(/\S+\z/, FILTERED) }
      end

      # One line of source. `path` says whether it is YAML, where a plain
      # scalar is a literal.
      def redact_source_line(line, path: nil)
        return line unless line.is_a?(String)

        source_line(line, path, nil).first
      end

      # Consecutive lines, so a PEM key across them is filtered whole, and in a
      # YAML or JSON file a `value` under a mapping a secret's name names; the
      # line count is kept, since callers number the lines.
      def redact_source_lines(lines, path: nil)
        carry = nil
        redacted = outside_key_bodies(lines.map { |line| readable(line) }) do |line|
          shown, carry = source_line(line, path, carry)
          shown
        end
        return redacted unless path.to_s.match?(STRUCTURED_FILE) && !path.to_s.match?(%r{(?:\A|/)locales?/})

        pairs = named_values(redacted, path.to_s.match?(EXAMPLE_FILE), path)
        BundlerCredentials.name_value_pairs(pairs, path) { |literal| placeholder?(literal) }
      end

      # A slice of the app's source - a method body, a template - as a tool
      # prints it: the same lines, each secret filtered.
      def redact_source(text, path: nil)
        return text unless text.is_a?(String)

        text = readable(text)
        trailing = text.end_with?("\n") ? "\n" : ""
        redact_source_lines(text.lines.map(&:chomp), path: path).join("\n") + trailing
      end

      # Text any redaction can read: a UTF-16 or UTF-32 string is transcoded and an invalid byte replaced, since
      # a pattern raises on either.
      def readable(text)
        return text unless text.is_a?(String)
        return text.encode("UTF-8", invalid: :replace, undef: :replace) unless text.encoding.ascii_compatible?

        text.valid_encoding? ? text : text.scrub
      end
      private :readable

      # Source text an introspector records in the payload, filtered where it is captured; `path` nil for none.
      def source_slice(text, path: nil)
        redact_source(text, path: path)
      end

      # The line filtered and what the next line still belongs to: a gem server credential's open quote,
      # block scalar, heredoc or trailing backslash.
      def source_line(line, path, carry)
        line = line.scrub unless line.valid_encoding?
        opener = carry&.first == :opener
        carry = nil if opener
        line, carry = BundlerCredentials.continue(line, carry, path: path) { |literal| placeholder?(literal) } if carry
        # Locale files hold translations: only credential formats are filtered.
        # Example files often hold real values, so only a plain placeholder is kept.
        locale = path.to_s.match?(%r{(?:\A|/)locales?/})
        example = path.to_s.match?(EXAMPLE_FILE)
        result = line.gsub(URI_USERINFO) { |m| placeholder?(m) ? m : "#{Regexp.last_match(1)}#{FILTERED}@" }
        result = result.gsub(ENV_USER) { |m| key_user?(Regexp.last_match(1)) ? "://#{FILTERED}@" : m }
        unless locale
          result, opened = BundlerCredentials.redact(result, path: path, opener: opener) { |literal| placeholder?(literal) }
          carry = opened || carry
          result = BundlerCredentials.inline_pairs(result, path) { |literal| placeholder?(literal) }
          result = result.gsub(KEYED_LITERAL) do |m|
            match = Regexp.last_match
            # `cond ? "pass" : "fail"` is a ternary: its branches are values, not a key and its value.
            next m if match[:assign].strip == ":" && match.pre_match.match?(/\?\s*\z/)

            filter_literal(m, match, example)
          end
          result = result.gsub(CALL_KEYED) { |m| filter_literal(m, Regexp.last_match, example) }
          result = result.sub(DOCKER_ENV) do |m|
            match = Regexp.last_match
            # Docker reads an instruction in any case; elsewhere `env NAME value` is a shell command.
            next m unless match[:instruction] == "ENV" || path.to_s.match?(DOCKER_FILE)

            quote = match[:value].match?(/\A".+"\z/) ? '"' : ""
            value = match[:value][/\A\S+/].delete_prefix('"').delete_suffix('"')
            next m if value.start_with?("$")

            secret = if bundler_credential?(match[:name]) then !placeholder?(value)
            elsif !match[:name].start_with?("BUNDLE_") then keyed_secret?(match[:name], value, example)
            end
            secret ? "#{match[:head]}#{quote}#{FILTERED}#{quote}" : m
          end
          result = result.gsub(ENV_ASSIGNMENT) do |m|
            match = Regexp.last_match
            next m unless keyed_secret?(match[:name], match[:value], example)

            "#{match[:name]}=#{FILTERED}"
          end
          result = result.gsub(FLAG_ARGUMENT) { |m| filter_flag(m, Regexp.last_match, example) }
          result = result.gsub(NAMED_OBJECT) { |m| filter_named_object(m, Regexp.last_match, example) }
        end
        result = filter_string_literals(result)
        result = filter_jwts(CREDENTIAL_TOKENS.reduce(result) { |text, pattern| text.gsub(pattern, FILTERED) })
        result = scheme_credentials(result)
        # A log shown as a file (a tracked log's diff) gets what rails_read_logs filters too.
        return [ redact_log_line(result), carry ] if path.to_s.match?(LOG_FILE)

        [ path.to_s.match?(YAML_FILE) && !locale ? yaml_scalar(result, example) : result, carry ]
      end
      private :source_line

      # A secret no name marks, in any string of the assembled payload: only formats no identifier is written in.
      def payload_tokens(value)
        case value
        when String then vendor_tokens(value)
        when Hash
          walked = value.to_h { |key, inner| [ key.is_a?(String) ? vendor_tokens(key) : key, payload_tokens(inner) ] }
          walked.default_proc = value.default_proc if value.default_proc
          walked
        when Array then value.map { |inner| payload_tokens(inner) }
        when Set then value.class.new(value.map { |inner| payload_tokens(inner) })
        when Struct then value.dup.tap { |copy| copy.members.each { |member| copy[member] = payload_tokens(copy[member]) } }
        else data_value?(value) ? value.with(**value.to_h.transform_values { |inner| payload_tokens(inner) }) : value
        end
      end

      def data_value?(value)
        defined?(::Data) && ::Data.respond_to?(:define) && value.is_a?(::Data)
      end

      def vendor_tokens(text)
        text = CREDENTIAL_TOKENS.reduce(text) { |current, pattern| current.match?(pattern) ? current.gsub(pattern, FILTERED) : current }
        text = text.gsub(PEM_BLOCK, FILTERED) if text.include?("-----BEGIN ")
        filter_jwts(text)
      end

      # A config value arrives without its context, so the setting's name is
      # what says whether it holds a secret. Values are walked rather than
      # type-checked: an evaluated value is often a hash or an array, and the
      # credential is as often under a key inside it (`smtp_settings` holding
      # a `password`) as it is under the setting itself.
      #
      # Both of the fields a listener emits for one assignment are decided
      # together. Deciding separately let them disagree: the source slice is
      # always a String, so any rule about the value's type never reached it.
      #
      # @param name [Symbol, String, Array] the setting, or its full path
      # @return [Hash] { value:, source: }
      def redact_assignment(name, value:, source:)
        if secret_assignment?(name, value)
          # Walked, not collapsed: the reader still learns the shape - that
          # there are two keys, that a hash has a `token` - while the values
          # go. The slice cannot be scrubbed that precisely, so it goes whole.
          return { value: walk(value, true), source: source.nil? ? nil : filtered_like(source) }
        end

        walked = walk(value, false)
        { value: walked, source: scrub_slice(source, changed: walked != value) }
      end

      def credential_shaped?(value)
        value.to_s.match?(CREDENTIAL_SHAPE)
      end

      def secret_name?(name)
        path = Array(name).join(".")
        return true if path.match?(SECRET_PATH)

        leaf = path.split(".").last.to_s
        leaf.match?(WHOLE_SECRET_NAME) && !leaf.match?(DESCRIPTOR_SUFFIX)
      end

      # Redaction and shortening are one operation because their order is the
      # whole point: shorten first and a cut landing between a password and
      # its `@host` leaves the pattern nothing to match, so the credential's
      # prefix ships in plaintext.
      def redact_and_shorten(value, limit)
        return value unless value.is_a?(String)

        call(value).truncate(limit)
      end

      # Log lines carry shapes config values do not: ANSI colour, dotenv
      # announcements, bare env assignments, addresses.
      def redact_log_line(line)
        return line unless line.is_a?(String)

        result = json_line(line).dup
        result.gsub!(ANSI_ESCAPE, "")
        result.gsub!(DOTENV_LINE, "[dotenv] Set #{FILTERED}")
        result.gsub!(URI_USERINFO) { "#{Regexp.last_match(1)}#{FILTERED}@" }
        result.gsub!(ENV_ASSIGNMENT) do |m|
          name = Regexp.last_match(:name)
          log_secret?(name, Regexp.last_match(:value)) ? "#{name}=#{FILTERED}" : m
        end
        result.gsub!(QUERY_PARAM) { |m| filter_query_param(m, Regexp.last_match) }
        result.gsub!(FLAG_ARGUMENT) { |m| filter_flag(m, Regexp.last_match, false) }
        result.gsub!(result.encoding == Encoding::UTF_8 ? EMAIL_PATTERN : ASCII_EMAIL_PATTERN, EMAIL)

        result, bind_columns = filter_sql_values(syntax_near(result))
        result = filter_unnamed_binds(error_values(result), bind_columns)
        result.gsub!(LOG_SECRET_ASSIGNMENT) { filter_assignment(Regexp.last_match) }
        result = result[0, result.index(RUNS_ON)] if result.include?(RUNS_ON)
        result.gsub!(LOG_BIND) { filter_bind(Regexp.last_match) }

        LOG_PATTERNS.each do |pattern, replacement|
          next result.gsub!(pattern, replacement) unless replacement == :value

          # A value pattern ends with its value. A group's offset is counted
          # from the line's start, so reading one per match made a line of
          # many matches cost the square of its length.
          result.gsub!(pattern) do
            match = Regexp.last_match
            match[0].delete_suffix(match[:value]) + filtered_like(match[:value])
          end
        end

        scheme_credentials(filter_jwts(result))
      end

      # A JWT in a run of its characters: three dot-joined parts, the first a base64url JSON header
      # (`eyJ`) of 13 or more that starts the run or follows a `-` or a `.`, the second of 10 or more. The
      # run is read once, a part at a time, so a header of any length is caught and a run of repeats costs
      # its length.
      def filter_jwts(text)
        return text unless text.include?("eyJ") && text.include?(".")

        text.gsub(JWT_RUN) { |run| jwt_redacted(run) }
      end

      def jwt?(text)
        text.include?("eyJ") && filter_jwts(text) != text
      end

      # The next `eyJ` at or after from that no letter or digit stands before (`surveyJobs` holds none).
      def jwt_start(run, from)
        while (at = run.index("eyJ", from))
          return at if at.zero? || !run[at - 1].match?(/[A-Za-z0-9]/)

          from = at + 1
        end
      end

      def jwt_redacted(run)
        return run unless run.include?("eyJ") && run.count(".") >= 2

        out = +""
        pos = 0
        header = jwt_start(run, 0)
        while header && (dot = run.index(".", pos))
          header = jwt_start(run, pos) if header < pos
          break unless header

          second = run.index(".", dot + 1) if header < dot && dot - header >= 13
          if second && second - dot > 10
            out << run[pos...header] << FILTERED
            pos = run.index(".", second + 1) || run.length
          else
            out << run[pos..dot]
            pos = dot + 1
          end
        end
        out << run[pos..]
      end

      # The one place a name and value pair leaves the process. Normally the
      # name condemns a value on its own, and so does the value's shape.
      # Judged by the rule a source literal gets: a credential format anywhere, a URL's
      # password, and under a secret-named key whatever keyed_secret? says. `placeholder_ok`
      # says this is an example file, where a plain placeholder is kept.
      def value(name, value, placeholder_ok: false)
        return nil if value.nil?

        stripped = value.to_s.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        # An empty value holds no secret whatever it is called (`'{}'`, `nil`).
        return value.to_s.strip if stripped.match?(/\A(?:|\{\s*\}|\[\s*\]|nil|false|0)\z/)
        return FILTERED if credential?(stripped)

        name = name.to_s
        return FILTERED if name.match?(WHOLE_KEY_NAME) && keyed_secret?(name, stripped, placeholder_ok)

        stripped.gsub(URI_USERINFO) { |m| placeholder?(m) ? m : "#{Regexp.last_match(1)}#{FILTERED}@" }
      end

      # An environment value as an env file or a code default gives it: as Redaction.value reads it, or
      # FILTERED when its shape can hold a secret. `placeholder_ok` as for value.
      def env_value(name, value, placeholder_ok: false)
        text = value.to_s
        shown = value(name, text, placeholder_ok: placeholder_ok)
        shown.to_s.include?(FILTERED) || bundler_credential?(name.to_s) || secret_shaped?(text) ? FILTERED : shown
      end

      # An env file's comment, printed beside its variable: FILTERED when it holds a credential, a
      # secret's shape, or a hex key in groups (a UUID) among its words.
      def env_comment(text)
        hidden = credential?(text) || secret_shaped?(text) || text.split.any? { |word| word.delete("-_").match?(GROUPED_HEX) }
        hidden ? FILTERED : call(text)
      end

      # Whether text has a shape a secret is kept in where no name says so: ENV_SECRET_SHAPES, a hex key
      # split into groups, a key in a URL's user part, or a run of 16 letters and digits with both in it.
      def secret_shaped?(text)
        ENV_SECRET_SHAPES.any? { |shape| text.match?(shape) } || grouped_hex?(text) ||
          text.scan(ENV_USER).any? { |(user)| key_user?(user) } || opaque_text?(text)
      end

      # A URL's user part that is a key (a token as GitHub takes one), not a name. A name is one case on
      # each side of at most four digits (`appuser2024production`); a key mixes them through.
      def key_user?(user)
        return true if credential?(user) || grouped_hex?(user)

        opaque_text?(user) && !user.match?(NAME_USER)
      end

      def opaque_text?(text)
        text.scan(OPAQUE_RUN).any? { |run| run.match?(/\d/) && run.match?(/[A-Za-z]/) }
      end

      def grouped_hex?(text)
        text.delete("-_").match?(GROUPED_HEX)
      end

      def bundler_credential?(name)
        BundlerCredentials.credential?(name)
      end

      # Redacting before the search means a term can only match text the
      # reader would see; matching the original told a caller whether a
      # secret was there by whether a line came back.
      def redact_log_lines(lines, search: nil)
        open = 0
        redacted = outside_key_bodies(Array(lines)) do |line|
          # A secret list a logger spreads over lines: its indented lines are filtered until it closes.
          if open.positive? && line.match?(/\A(?:\s|[\]}])/)
            open += bracket_depth(line)
            next line.strip.match?(/\A[\]},]+\z/) ? line : line.sub(/\S.*/, FILTERED)
          end
          open = open_secret_collection(line)
          redact_log_line(line)
        end
        term = search.to_s.strip
        return redacted if term.empty?

        needle = term.downcase
        redacted.select { |line| line.downcase.include?(needle) }
      end

      private

      # Each string literal that is a credential by its format. A quote that opens no string leaves every later
      # quote of its kind unable to close one (a close would be an unescaped quote the scan has passed), so the
      # text is read once, not once per quote.
      def filter_string_literals(text)
        return text unless text.include?('"') || text.include?("'")

        scanner = StringScanner.new(text)
        out = +""
        dead = {}
        until scanner.eos?
          out << scanner.scan(/[^"']*+/)
          break if scanner.eos?

          quote = scanner.peek(1)
          literal = dead[quote] ? nil : scanner.scan(quote == '"' ? DOUBLE_QUOTED : SINGLE_QUOTED)
          if literal
            out << (credential?(literal[1..-2]) ? "#{quote}#{FILTERED}#{quote}" : literal)
          else
            dead[quote] = true
            out << scanner.getch
          end
        end
        out
      end

      # A matched name and literal, with the literal filtered when it holds a secret.
      def filter_literal(text, match, example)
        name = key_name(match[:name])
        return text unless name && keyed_secret?(name, match[:literal][1..-2], example)

        quote = match[:literal][0]
        text.delete_suffix(match[:literal]) + "#{quote}#{FILTERED}#{quote}"
      end

      # Compiled once. A pattern built inside a method is compiled again on every call, 23
      # microseconds each, which was most of what a line of many keys or flags cost to filter.
      WHOLE_KEY_NAME = /\A(?:#{KEY_NAME})\z/
      WHOLE_SECRET_NAME = /\A#{SECRET_NAME}\z/
      WHOLE_PASSWORD_NAME = /\A#{PASSWORD_NAME}\z/
      WHOLE_KEYISH_NAME = /\A(?:#{KEYISH_NAME})\z/
      # A name with a secret word in it, in any spelling: a `_KEY` name with one is no mere key.
      WHOLE_SECRET_OR_PASSWORD_NAME = /\A(?:#{SECRET_NAME}|#{PASSWORD_NAME}|#{CAMEL_SECRET_NAME})\z/
      WHOLE_SECRET_WORD = /\A(?:#{SECRET_WORD})\z/

      # The name a matched key reads as. A dashed one reads with underscores, so `X-Api-Key` is
      # `X_Api_Key`, an API key's name; one that then spells no key name (`X-Key-Id`) is none.
      def key_name(name)
        spelled = name.tr("-", "_")
        spelled if spelled.match?(WHOLE_KEY_NAME)
      end

      # A one-line object a secret's name names, with its `"value"` filtered when it is that secret.
      def filter_named_object(text, match, example)
        name = key_name(match[:name])
        return text unless name

        text.sub(NAMED_VALUE_PAIR) do |pair|
          value = Regexp.last_match(:value)
          keyed_secret?(name, value, example) ? %(#{Regexp.last_match(:head)}#{FILTERED}") : pair
        end
      end

      # The `value` lines of each mapping a secret's name names (NAMING_LINE), up to the line
      # that leaves it: one no deeper than the name. A boolean or null is no secret.
      def named_values(lines, example, path)
        named = nil
        carry = nil
        lines.map do |line|
          if carry
            line, carry = BundlerCredentials.continue(line, carry, path: path) { |literal| placeholder?(literal) }
            next line if carry
          end
          if (naming = line.match(NAMING_LINE))
            named = { name: naming[:name], indent: naming[:indent].size }
            next line
          end
          next line if line.strip.empty?

          named = nil if named && line[/\A[ \t]*/].size <= named[:indent]
          if named && BundlerCredentials.credential?(named[:name].to_s)
            head = line.match(VALUE_HEAD)
            next line unless head

            line, carry = BundlerCredentials.redact_value(line, head.end(0), path: path, column: head[0][/\A[ \t]*/].size) { |literal| placeholder?(literal) }
            next line
          end

          value = named && line.match(VALUE_LINE)
          next line unless value

          scalar = value[:value].to_s
          next line if scalar.empty? || scalar.start_with?(FILTERED) || scalar.match?(/\A(?:true|false|yes|no|null|~)\z/i)
          next line unless keyed_secret?(named[:name], scalar, example)

          "#{value[:head]}#{value[:quote]}#{FILTERED}#{value[:quote]}#{value[:tail]}"
        end
      end

      # The value sits under every word of its name, so a secret word anywhere in it holds the value.
      def filter_query_param(text, match)
        words = match[:name].split(/\[|\]|%5B|%5D/i).grep(/[A-Za-z]/)
        return text unless words.any? { |word| (name = key_name(word)) && log_secret?(name, match[:value]) }

        text.delete_suffix(match[:value]) + FILTERED
      end

      # A matched flag and the word after it, with the word filtered when it is the flag's secret.
      def filter_flag(text, match, example)
        name = key_name(match[:name])
        value = match[:value]
        return text unless name && flag_secret?(name, value, example)

        quote = match[:quote].to_s
        text.delete_suffix("#{quote}#{value}#{quote}") + "#{quote}#{FILTERED}#{quote}"
      end

      # A word after a flag is as often prose as the flag's value, so it needs a digit as well as
      # what keyed_secret? asks of a value: a word is no secret, and a generated one has digits.
      # A `name=value` list (BuildKit's `--secret id=...,env=...`) and a relative path
      # (`keys/deploy.pem`) name where a secret is, not what it is.
      def flag_secret?(name, value, example)
        return false if value.match?(/\A[A-Za-z][\w-]*=[^=]/) || object_path?(value)

        value.match?(/\d/) && keyed_secret?(name, value, example)
      end

      # The credential after an auth scheme goes; the scheme stays, so the line still reads.
      def scheme_credentials(text)
        text.gsub(AUTH_CREDENTIALS) do |m|
          credentials = Regexp.last_match(:credentials)
          scheme_credential?(credentials) ? m.delete_suffix(credentials) + FILTERED : m
        end
      end

      # After a scheme, key_credential?'s 16+ letters and digits, both, read past the separators a
      # credential is written with: a UUID's dashes, base64's `+`, `/` and `=`. A word or a
      # placeholder has no digits to count.
      def scheme_credential?(value)
        return true if CREDENTIAL_TOKENS.any? { |pattern| value.match?(pattern) } || jwt?(value)
        return false if placeholder?(value)

        alnum = value.delete("^A-Za-z0-9")
        alnum.length >= 16 && alnum.match?(/[A-Za-z]/) && alnum.match?(/\d/)
      end

      # The one verdict on a name and value in a log line, whichever pattern found the pair.
      def log_secret?(name, value)
        # A short number under a `*_tokens` or `*Tokens` name is a usage count (`prompt_tokens: 123`), never a token.
        return false if name.match?(/(?:_|[a-z\d])tokens\z/i) && value.to_s.delete(%("')).match?(/\A\d{1,9}\z/)

        !descriptor_name?(name) && !(keyish_only?(name) && !key_credential?(value))
      end

      # A key body line is filtered whole; every other line goes to the block.
      def outside_key_bodies(lines)
        inside = false
        lines.map do |line|
          if inside && line.match?(PEM_END)
            inside = false
            next line
          end
          inside &&= line.match?(PEM_BODY)
          next line.sub(/\S.*/, FILTERED) if inside

          inside = line.match?(PEM_OPENS) && !line.match?(PEM_END)
          yield line
        end
      end

      # Credential shape beats the descriptor list: `api_key_params` is
      # excused by its suffix, but a value reading `sk_live_...` is a
      # credential whatever the setting is called.
      def secret_assignment?(name, value)
        return true if value.is_a?(String) && credential_shaped?(value)
        return false unless secret_name?(name)

        !policy_value?(value)
      end

      def pem_inline?(text)
        marker = text.match(PEM_BEGIN)
        marker ? text.match?(PEM_INLINE_BODY, marker.end(0)) : false
      end

      # By format only: a long random literal is as often an id as a key.
      def credential?(inner)
        return false if placeholder?(inner)

        pem_inline?(inner) || CREDENTIAL_TOKENS.any? { |pattern| inner.match?(pattern) } || jwt?(inner)
      end

      PLACEHOLDER = /\#\{|<%|\$\{|%\{|\{\w+\}|\A<[^<>]*>\z|\A(?:[xX]{3,}|\*{3,})\z|
                     \A(?:your|change|replace|insert|enter)(?:[_.\s-]|\z)|[_.\s-]your[_.\s-]/xi

      def placeholder?(text)
        text.empty? || text.match?(PLACEHOLDER)
      end

      # A secret-named key whose value describes the secret: `TOKEN_USE`,
      # `DEAD_TOKEN_ERROR`, `token_url`, besides the config descriptors. A
      # Stimulus target, action, controller, outlet or class names an element
      # or a method (`"password-visibility-target": "input"`); a value may be a token.
      # A name for a file, a directory or an identifier says where a secret is or which one
      # (`token_file`, `secret_id`, AWS's `--secret-id`), not what it is.
      SOURCE_DESCRIPTOR = /_(?:use|scope|kind|label|prefix|suffix|errors?|message|url|uri|endpoint|path|header|
                             target|action|controller|outlet|class(?:es)?|files?|filename|dir|directory|ids?)\z/xi

      # A camel-cased name is read with its words joined by underscores (`tokenType` is `token_type`).
      def descriptor_name?(name)
        snake = name.gsub(/([a-z\d])([A-Z])/, '\1_\2')
        snake.match?(DESCRIPTOR_SUFFIX) || snake.match?(SOURCE_DESCRIPTOR)
      end

      # Under a secret-named key a value is a secret unless it is clearly not
      # one (docs/TOOLS.md lists the shapes): a leak costs more than a hidden line.
      NOT_A_SECRET = [
        # A path has two slashes and no base64 padding or `+`. Its first segment is taken whole, so
        # a slash-filled value ending in `=` is one pass, not a retry from every slash.
        %r{\A(?:[a-z][a-z0-9+.-]*://|/[^+=/]*+/[^+=]*+\z)}i,
        /\A[?&][\w-]+=/,
        /\A(?:[vV]\d+(?:[.-]\d+)*|\d+(?:\.\d+){1,3})\z/,
        /\A\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?\z/,
        ADDRESS = /\A[\w.+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}\z/i,
        HOSTNAME = /\A(?:[a-z0-9-]+\.)+[a-z]{2,}\z/,
        HEADER_NAME = /\A[A-Z][a-z0-9]*(?:-[A-Z][a-z0-9]*)+\z/
      ].freeze

      # An env or header-variable name: capitals joined by `_`, led by `_` or
      # `HTTP_` or naming a secret word (`_FORUM_API`, `HTTP_API_KEY`).
      ENV_NAME = /\A_?[A-Z][A-Z0-9]*(?:_+[A-Z0-9]+)+\z/

      APP_PASSWORD = /\A[a-z]{4}(?: [a-z]{4}){3}\z/

      # A switch's value (`showPassword=false`), not a credential, under any name.
      NOT_A_SECRET_WORD = /\A(?:true|false|yes|no|on|off|null|nil|none|undefined)\z/i

      def secret_literal?(value, key)
        password = key.match?(WHOLE_PASSWORD_NAME)
        return false if value.length < (password ? 4 : 8) || !value.ascii_only? || placeholder?(value)
        return false if value.match?(NOT_A_SECRET_WORD)
        # The key's own name, in any case (`currentPassword: "current_password"`, an enum's `password: 'password'`).
        return false if snake_name(value) == snake_name(key)
        # Whitespace makes a message, except in a passphrase or an app password's four groups of four.
        return false if value.match?(/\s/) && !key.match?(/passphrase/i) && !value.match?(APP_PASSWORD)
        # Under a password key a word-joined value is the password itself.
        return false if !password && names_a_secret?(value)
        return false if value.match?(ENV_NAME) && (value.start_with?("_", "HTTP_", "BUNDLE_") || secret_words?(value))

        # A password may be spelled like a header name, an address or a hostname (`P4ss-W0rd`).
        (password ? NOT_A_SECRET - [ HEADER_NAME, ADDRESS, HOSTNAME ] : NOT_A_SECRET).none? { |shape| value.match?(shape) }
      end

      def snake_name(name)
        name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.tr("-", "_")
      end

      # Letter-only words, one a secret word, spell a name (`user_api_key`).
      # ponytail: `super-secret-password` reads as a name; score entropy per word if that leaks.
      def names_a_secret?(value)
        return false if value.match?(/\d/) || !value.match?(/\A_?[A-Za-z]+(?:[_.-][A-Za-z]+)*\z/)

        secret_words?(value)
      end

      def secret_words?(value)
        words = value.gsub(/(?<=[A-Z])(?=[A-Z][a-z])/, "_").gsub(/([a-z])([A-Z])/, '\\1_\\2')
                     .downcase.split(/[_.-]+/).reject(&:empty?)
        (words + words.each_cons(2).map { |pair| pair.join("_") }).any? { |word| word.match?(WHOLE_SECRET_WORD) }
      end

      def yaml_scalar(line, example)
        match = line.match(YAML_SCALAR) or return line
        value = match[:value].strip
        return line if value.start_with?(FILTERED, '"', "'", "&", "*", "|", ">", "{", "[")
        return line if value.match?(/\A(?:true|false|yes|no|null|~)\z/i) || !keyed_secret?(match[:name], value, example)

        "#{match[:head]}#{FILTERED}#{match[:tail]}"
      end

      def keyed_secret?(name, value, example)
        return key_credential?(value) if keyish_only?(name)
        return false if descriptor_name?(name) || !secret_literal?(value, name)

        !(example && example_placeholder?(value))
      end

      # Named only by `_KEY`, and not by a secret word.
      def keyish_only?(name)
        name.match?(WHOLE_KEYISH_NAME) && !name.match?(WHOLE_SECRET_OR_PASSWORD_NAME)
      end

      # A 16+ character run mixing letters and digits, or a known token format; a cache or i18n
      # key (`views/posts/1`, `users.index.title`), a path or a header name has no such run.
      def key_credential?(value)
        return true if CREDENTIAL_TOKENS.any? { |pattern| value.match?(pattern) } || jwt?(value)
        return false if placeholder?(value) || !value.ascii_only? || value.match?(/\s/)
        return false unless NOT_A_SECRET.none? { |shape| value.match?(shape) }
        return false if object_path?(value)

        value.scan(/[A-Za-z0-9]{16,}/).any? { |run| run.match?(/[A-Za-z]/) && run.match?(/\d/) }
      end

      # A relative path or storage key (`wp-content/uploads/2024/a1b2...png`): slash-joined, one
      # segment a plain word, and none of base64's `+` or `=`.
      def object_path?(value)
        value.match?(%r{\A[\w.%-]+(?:/[\w.%-]+)+\z}) && value.split("/").any? { |seg| seg.match?(/\A[a-z][a-z-]{3,}\z/) }
      end

      # An example file's plain placeholder: words with no digits, short enough
      # not to be a passphrase (`changeme`, `your_password_here`).
      def example_placeholder?(value)
        value.length <= 20 && value.match?(/\A[A-Za-z]+(?:[_.-][A-Za-z]+)*\z/)
      end

      # Identifiers and switches, never credential material. Filtering them
      # hides the config a reader came for - `reset_password_keys = [:email]`
      # says which field the reset uses, not what the secret is.
      def policy_value?(value)
        case value
        when Symbol, TrueClass, FalseClass, NilClass then true
        when Array then value.all? { |element| policy_value?(element) }
        else false
        end
      end


      # `secret` says the enclosing name already marks this as credential
      # material. What survives it is decided by policy_value?, the same rule
      # the top level uses - otherwise a number under a secret key is kept
      # while the same number under a secret setting is filtered.
      def walk(value, secret)
        case value
        when nil    then nil
        # A credential-shaped string is filtered wherever it sits, with or
        # without a secret name around it: inside a collection there is no
        # `key: value` for the patterns to match on, so the shape is the only
        # signal left.
        when String then secret || credential_shaped?(value) ? filtered_like(value) : call(value)
        when Array  then value.map { |element| walk(element, secret) }
        when Hash   then value.to_h { |key, inner| [ key, walk(inner, secret || secret_name?(key)) ] }
        else secret && !policy_value?(value) ? FILTERED : value
        end
      end

      # The slice is Ruby text, so the patterns can scrub a quoted value in
      # place. They cannot scrub inside a collection literal without cutting
      # it mid-value, so when walking the evaluated value found a secret that
      # the patterns did not reach, the whole slice goes.
      def scrub_slice(source, changed:)
        return source unless source.is_a?(String)

        scrubbed = call(source)
        return scrubbed unless changed && scrubbed == source && source.match?(COLLECTION_LITERAL)

        FILTERED
      end

      # Keeps the quoting of a source slice so the result still reads as the
      # assignment it replaced.
      def filtered_like(value)
        quote = value.start_with?('"', "'") ? value[0] : nil
        quote ? "#{quote}#{FILTERED}#{quote}" : FILTERED
      end

      # Rebuilds a matched log assignment with its value gone, keeping the
      # key, the quoting and the assignment shape so the line still reads.
      # The match is passed in because `$~` does not cross a method call.
      # `password_length: 8` is policy, not a credential, so it survives.
      def filter_assignment(match)
        quote, key, assign = match[1], match[2], match[3]
        name = key_name(key)
        return match[0] unless name && log_secret?(name, match[4] || match[5] || match[6] || match[7] || match[8])

        value_quote = match[4] ? '"' : (match[5] ? "'" : (match[6] ? '\\"' : ""))
        filtered = "#{quote}#{key}#{quote}#{assign}#{value_quote}#{FILTERED}#{value_quote}"
        # Nested deeper than LOG_COLLECTION reads, the collection runs on past the match: the line ends here.
        match[7] && !balanced?(match[7]) ? "#{filtered}#{RUNS_ON}" : filtered
      end

      def balanced?(text)
        bracket_depth(text) <= 0
      end

      # Brackets opened less brackets closed, its strings and escapes left out.
      def bracket_depth(text)
        depth = 0
        text.scan(/\\.|"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|[\[\]{}]/) do |token|
          depth += 1 if token == "[" || token == "{"
          depth -= 1 if token == "]" || token == "}"
        end
        depth
      end

      # How deep a list or hash under a secret name is still open where the line ends.
      def open_secret_collection(line)
        line.to_enum(:scan, LOG_SECRET_ASSIGNMENT).map { Regexp.last_match }.sum do |match|
          name = match[7] && key_name(match[2])
          name && log_secret?(name, match[7]) ? [ bracket_depth(match[7]), 0 ].max : 0
        end
      end

      # A statement's values written inline, filtered where the column they meet is a secret: compared
      # with it (through LOWER() or CAST() too), in a BETWEEN or an IN list for it, or inserted under
      # it. Active Record writes them so on MySQL and MariaDB, which run no prepared statements, and for
      # insert_all and upsert_all on every adapter. A value whose column cannot be told is filtered when
      # the statement names a secret column. A line with `\'` in it reads one way as MySQL and another
      # as standard SQL, so it is read both ways, and a value either reading filters is filtered.
      # Returns the line and the columns each bind placeholder meets, for the unnamed binds after it.
      def filter_sql_values(line)
        binds = line.match?(LOG_UNNAMED_BIND)
        return [ line, nil ] unless binds || line.include?("'") || (line.include?('"') && line.include?("`"))

        spans = []
        columns = {}
        sql_dialects(line).each { |mysql| sql_read(line, mysql, spans, columns) }
        [ sql_rewrite(line, spans), columns ]
      end

      # Whether to read a line as MySQL, as standard SQL, or both. Active Record quotes MySQL's names in
      # backquotes and the others' in double quotes, the first name before most values. A `\'` reads two
      # ways, so a line with one counts as MySQL only when a backquoted name stands outside its strings.
      def sql_dialects(line)
        if line.include?("\\'")
          sql_tokens(line, false).any? { |kind, text| kind == :word && text.start_with?("`") } ? [ true ] : [ true, false ]
        else
          tick = line.index("`")
          double = line.index('"')
          [ tick && (double.nil? || tick < double) ? true : false ]
        end
      end

      # One reading of a line: each filtered string's byte span into spans, each placeholder's column into columns.
      # One pass over the tokens, so a line cut off or full of parentheses costs no more than its length.
      def sql_read(line, mysql, spans, columns)
        tokens, comments = sql_tokens(line, mysql).partition { |kind, _| kind != :comment }
        comments.each { |_, text, start| comment_tag_spans(text, start, spans) }
        stack = []
        insert = closed = between = named = nil
        question = 0
        tokens.each_with_index do |(kind, text, start), i|
          insert = insert_stage(insert, tokens, i, stack)
          between = nil if between && between[:and] && !sql_keyword?(tokens[i], "and") && tokens[i - 1] && !sql_keyword?(tokens[i - 1], "and")
          case text
          when "(", "["
            stack << sql_context(tokens, i, stack.last, insert, closed)
            insert[:stage] = stack.last[:kind] if insert && %i[columns tuple].include?(stack.last[:kind])
          when ")", "]"
            group = stack.pop
            insert[:columns], insert[:stage] = group[:names], :columns_done if insert && group&.dig(:kind) == :columns
            insert[:stage] = :after_tuple if insert && group&.dig(:kind) == :tuple
            sql_note(stack.last, group[:found], group[:words]) if group
            closed = group && { index: i, column: group[:found], known: group[:found] || group[:words] }
          when ","
            stack.last[:item] += 1 if stack.last
          else
            if kind == :word
              stack.last[:names][stack.last[:item]] = sql_name(text) if stack.last&.dig(:kind) == :columns
              sql_note(stack.last, sql_secret_name(text), true)
              if text.casecmp?("between")
                between = { column: sql_left(tokens, i - 1, closed) }
              elsif between && (text.casecmp?("and") || text.casecmp?("or"))
                # BETWEEN takes one AND; the next AND or an OR starts another condition.
                between = between[:and] || text.casecmp?("or") ? nil : between.merge(and: true)
              end
              next
            end
            next unless kind == :string || kind == :bind

            # A key name in a function's arguments ('api_key', '$.api_key') says it reads that secret.
            sql_note(stack.last, json_secret(text), false) if kind == :string
            next if kind == :string && json_path?(tokens, i, stack.last)
            column = between && !sql_operator_before(tokens, i - 1) ? between[:column] : sql_column(tokens, i, stack.last, closed)
            if kind == :bind
              (columns[text == "?" ? (question += 1) : text[1..].to_i] ||= []) << column
              next
            end
            literal = sql_literal(text)
            hide = if column.nil?
              (named ||= sql_secret_names(tokens)).any? { |secret| log_secret?(secret, literal) }
            else
              column == true || (column && log_secret?(column, literal))
            end
            spans << [ start, start + text.bytesize ] if hide
          end
        end
      end

      # A query log tag whose key names a secret has its value filtered; no other word in a comment is SQL.
      def comment_tag_spans(text, start, spans)
        text.scan(COMMENT_TAG) do
          match = Regexp.last_match
          name = key_name(match[:key]) or next
          value = match[:value]
          next unless log_secret?(name, value.start_with?("'") ? sql_literal(value) : value)

          from = start + text[0, match.begin(:value)].bytesize
          spans << [ from, from + value.bytesize ]
        end
      end

      # The line with each span, merged where readings overlap, written as a filtered string.
      def sql_rewrite(line, spans)
        return line if spans.empty?

        merged = []
        spans.sort.each { |from, to| merged.last && from < merged.last[1] ? merged.last[1] = [ merged.last[1], to ].max : merged << [ from, to ] }
        out = +""
        cursor = 0
        merged.each do |from, to|
          text = line.byteslice(from, to - from)
          quote = text[/['"]/]
          if quote.nil?
            out << line.byteslice(cursor, from - cursor) << FILTERED
            cursor = to
            next
          end
          prefix = text[0, text.index(quote)]
          closed_quote = text.length > prefix.length + 1 && text.end_with?(quote)
          out << line.byteslice(cursor, from - cursor) << "#{prefix}#{quote}#{FILTERED}#{quote if closed_quote}"
          cursor = to
        end
        out << line.byteslice(cursor, line.bytesize - cursor)
      end

      # [kind, text, byte offset] for each token of a line read as SQL: :string, :word (a keyword or a
      # name, bare or quoted), :bind (a `$1` or `?` placeholder), :comment or :punct (an operator or one
      # character). Read as MySQL, a backslash escapes and double quotes make a string too. A `?` is a
      # placeholder unless the line numbers its placeholders, where it is PostgreSQL's JSON operator.
      def sql_tokens(line, mysql)
        string = mysql ? MYSQL_STRING : SQL_STRING
        numbered = line.match?(/(?<![\w$'"])\$\d+(?![\w$'"])/)
        scanner = StringScanner.new(line)
        tokens = []
        until scanner.eos?
          next if scanner.skip(/\s+/)

          start = scanner.pos
          kind = if scanner.scan(SQL_COMMENT) then :comment
          elsif scanner.scan(ESCAPED_STRING) || scanner.scan(string) || (mysql && scanner.scan(MYSQL_DQ_STRING)) then :string
          elsif scanner.scan(SQL_WORD) then :word
          elsif scanner.scan(/\$\d+/) || (!numbered && scanner.scan(/\?(?![|&])/)) then :bind
          else
            scanner.scan(SQL_OPERATOR) || scanner.getch
            :punct
          end
          tokens << [ kind, scanner.matched, start ]
        end
        tokens
      end

      # Where an INSERT (or MySQL's REPLACE) read so far stands after tokens[i]: INSERT [a word or two]
      # INTO name [(columns)] VALUES (...), (...). Nil once a token breaks that shape.
      def insert_stage(insert, tokens, i, stack)
        kind, text = tokens[i]
        # MySQL's INSERT() string function inside a row starts no statement.
        if kind == :word && (text.casecmp?("insert") || text.casecmp?("replace")) && !%i[columns tuple].include?(insert&.dig(:stage))
          return { stage: :insert, words: 0 }
        end
        return nil unless insert

        case insert[:stage]
        when :insert
          return insert.merge(stage: :into) if text.casecmp?("into")

          insert[:words] < 2 && kind == :word ? insert.merge(words: insert[:words] + 1) : nil
        when :into then kind == :word ? insert.merge(stage: :table) : nil
        when :table
          return insert.merge(stage: :values, columns: :unlisted) if kind == :word && text.match?(SQL_VALUES)

          text == "." || text == "(" || (kind == :word && tokens[i - 1][1] == ".") ? insert : nil
        when :columns, :tuple then insert
        when :columns_done then text.match?(SQL_VALUES) ? insert.merge(stage: :values) : nil
        when :values then text == "(" ? insert : nil
        when :after_tuple then text == "," || (text == "(" && tokens[i - 1][1] == ",") ? insert : nil
        end
      end

      # What a parenthesis or bracket opens: an IN list after `column [NOT] IN`, an INSERT's column list
      # or one of its rows, the right side of a comparison (`= LOWER(`, `&& ARRAY[`), or a group that
      # belongs to the list or row around it.
      def sql_context(tokens, i, outer, insert, closed)
        before = tokens[i - 1] if i.positive?
        if tokens[i][1] == "(" && sql_keyword?(before, "in")
          { kind: :list, column: sql_left(tokens, sql_keyword?(tokens[i - 2], "not") ? i - 3 : i - 2, closed), item: 0 }
        elsif tokens[i][1] == "(" && insert && insert[:stage] == :table
          { kind: :columns, names: [], item: 0 }
        elsif tokens[i][1] == "(" && insert && %i[values after_tuple].include?(insert[:stage])
          { kind: :tuple, columns: insert[:columns], item: 0 }
        elsif (op = sql_operator_before(tokens, i - 1))
          { kind: :list, column: sql_left(tokens, op - 1, closed), item: 0 }
        else
          { kind: :plain, owner: outer && (outer[:kind] == :plain ? outer[:owner] : outer), item: 0 }
        end
      end

      # Notes a name read inside a group, so a comparison with the group knows whether it holds a secret.
      def sql_note(context, secret, word)
        return unless context

        context[:found] ||= secret
        context[:words] ||= word
      end

      # The index of a comparison operator right before tokens[j + 1], a function's name (and BINARY) skipped.
      def sql_operator_before(tokens, j)
        j -= 1 if tokens[j]&.first == :word && !sql_keyword?(tokens[j], "and") && j.positive? && tokens[j - 1] && (sql_comparison?(tokens[j - 1]) || sql_keyword?(tokens[j - 1], "binary"))
        j -= 1 if sql_keyword?(tokens[j], "binary")
        j if j >= 0 && sql_comparison?(tokens[j])
      end

      def sql_comparison?(token)
        token && ((token.first == :punct && SQL_COMPARISON.include?(token[1])) || (token.first == :word && token[1].match?(/\A(?:like|ilike)\z/i)))
      end

      # The column a value meets: the one compared with it, the IN list's, BETWEEN's or INSERT row's it
      # sits in. false when that is known to be no secret, nil when it cannot be told, and true in a row
      # with no column list, where any value can be a secret.
      def sql_column(tokens, i, context, closed)
        if (op = sql_operator_before(tokens, i - 1))
          op -= 1 if sql_keyword?(tokens[op - 1], "not") && sql_keyword?(tokens[op], "like")
          return sql_left(tokens, op - 1, closed)
        end
        # A value on the left: 'v' = api_token.
        return sql_right(tokens, i + 2) if sql_comparison?(tokens[i + 1])

        list = context && context[:kind] == :plain ? context[:owner] : context
        case list&.dig(:kind)
        when :list then list[:column]
        when :tuple
          return true if list[:columns] == :unlisted

          column = list[:columns]&.at(list[:item])
          column && (sql_secret_name(column) || false)
        end
      end

      # The secret name an operand at tokens[j] holds: a column (the last name of a dotted one, standing
      # where a column stands), a JSON path's key, or a group just closed. false when it holds none, nil
      # when unread.
      def sql_left(tokens, j, closed)
        return nil if j.negative?
        return (closed[:column] || (closed[:known] ? false : nil)) if closed && closed[:index] == j && tokens[j][1] == ")"
        return json_secret(tokens[j][1]) || false if tokens[j].first == :string && JSON_ARROWS.include?(tokens[j - 1]&.at(1))
        return nil unless tokens[j].first == :word

        start = j
        start -= 2 while start >= 2 && tokens[start - 1][1] == "." && tokens[start - 2].first == :word
        lead = tokens[start - 1] if start.positive?
        trusted = lead.nil? || [ "(", ",", "[" ].include?(lead[1]) || (lead.first == :word && lead[1].match?(SQL_COLUMN_LEAD))
        trusted ? (sql_secret_name(tokens[j][1]) || false) : nil
      end

      # The column a value on the left is compared with: a name, dotted or not, after the operator.
      def sql_right(tokens, j)
        return nil unless tokens[j]&.first == :word

        j += 2 while tokens[j + 1]&.at(1) == "." && tokens[j + 2]&.first == :word
        sql_secret_name(tokens[j][1]) || false
      end

      # A string that names a JSON key rather than holding a value: after a JSON arrow, or a MySQL path
      # (`'$.a.b'`) a function is given. Compared, listed or inserted, a `$.` string is a value.
      def json_path?(tokens, i, context = :plain)
        return true if JSON_ARROWS.include?(tokens[i - 1]&.at(1))

        (context == :plain || context&.dig(:kind) == :plain) && sql_literal(tokens[i][1]).match?(/\A\$(?:[.\[]|\z)/)
      end

      # The secret name a JSON path's last key reads as: `api_key` in '$.auth.api_key' or '{auth,api_key}'.
      def json_secret(text)
        key = sql_literal(text).scan(/[\w-]+/).reverse.find { |word| !word.match?(/\A\d+\z/) }
        key && sql_secret_name(key)
      end

      # The name a word or a JSON key reads as when it is a secret's.
      def sql_secret_name(text)
        name = sql_name(text)
        name.length <= 128 ? key_name(name) : nil
      end

      # The secret names a statement holds in its words and JSON paths, none for a line that is no statement.
      def sql_secret_names(tokens)
        statement = tokens.any? { |kind, text| kind == :word && text.match?(SQL_STATEMENT) } &&
          tokens.any? { |kind, text| kind == :word && text.match?(SQL_CLAUSE) }
        # A comparison, or an IN list; prose says "in", "like" and "between" too.
        operator = tokens.each_with_index.any? do |(kind, text), i|
          (kind == :punct && SQL_COMPARISON.include?(text)) || (sql_keyword?(tokens[i], "in") && tokens[i + 1]&.at(1) == "(")
        end
        return [] unless statement || operator

        tokens.each_with_index.filter_map do |(kind, text), i|
          next sql_secret_name(text) if kind == :word

          json_secret(text) if kind == :string && json_path?(tokens, i)
        end.compact.uniq
      end

      def sql_literal(text)
        text.sub(/\A[^'"]*['"]/, "").delete_suffix(text[/['"]/])
      end

      # A bind Active Record logs with no name (`where("api_token = ?", x)`), filtered when the column its
      # placeholder meets is a secret, or when that cannot be told and the statement names a secret column.
      def filter_unnamed_binds(line, columns)
        return line unless line.match?(LOG_UNNAMED_BIND)

        named = nil
        position = 0
        line.gsub(ANY_BIND) do |pair|
          position += 1
          name, quoted = Regexp.last_match(1), Regexp.last_match(2)
          next pair unless name == "nil" && quoted.start_with?('"')

          value = quoted[1..-2]
          met = columns&.fetch(position, nil) || [ nil ]
          hide = met.any? do |column|
            next column == true || log_secret?(column, value) if column

            column.nil? && (named ||= sql_secret_names(sql_tokens(line, sql_dialects(line).first))).any? { |secret| log_secret?(secret, value) }
          end
          hide ? %([nil, "#{FILTERED}"]) : pair
        end
      end

      # The values a database error repeats: MySQL's and MariaDB's duplicate entry, PostgreSQL's failing
      # row (named after no column, so always filtered) and its duplicate key.
      def error_values(line)
        line = duplicate_entries(line)
        # A row's values can hold `)`; its own ends the message with a period.
        filter_key_values(filter_after(line, "Failing row contains (", ").", last: true))
      end

      # MySQL's `Duplicate entry 'v' for key 'index'` names only the index. Rails names one after its
      # columns (index_users_on_api_token), so the value shows when those name no secret; any other name
      # could cover a secret column, and its value is filtered. A message cut off is filtered to the end.
      def duplicate_entries(line)
        out = +""
        cursor = 0
        while (at = line.index("Duplicate entry '", cursor))
          start = at + 17
          finish = line.index("' for key '", start)
          key_end = finish && line.index("'", finish + 11)
          shown = key_end && plain_index?(line[(finish + 11)...key_end])
          out << line[cursor...start] << (shown ? line[start...finish] : FILTERED)
          cursor = finish || line.length
        end
        out << line[cursor..]
      end

      def plain_index?(key)
        name = key.split(".").last.to_s
        return true if name == "PRIMARY"
        return false unless name.start_with?("index_") && (on = name.index("_on_", 7)) && name.match?(/\A\w+\z/)

        name[(on + 4)..].split("_and_").none? { |column| (secret = key_name(column)) && !descriptor_name?(secret) }
      end

      # The text after each `opening` filtered up to `closing` (the line's last one when last), or up to
      # the line's end when none follows: a message cut off is no reason to show its value.
      def filter_after(line, opening, closing, last: false)
        out = +""
        cursor = 0
        while (at = line.index(opening, cursor))
          start = at + opening.length
          finish = last ? line.rindex(closing) : line.index(closing, start)
          finish = line.length unless finish && finish >= start
          out << line[cursor...start] << FILTERED
          cursor = finish
        end
        out << line[cursor..]
      end

      # PostgreSQL's `Key (key)=(values) already exists.` (and an exclusion constraint's `existing key`),
      # the values filtered when the key, an expression included, names a secret. Each search starts where
      # the last ended, so a line full of unfinished messages costs its length.
      def filter_key_values(line)
        out = +""
        cursor = 0
        while (at = line.index(KEY_VALUES_START, cursor)) && (split = line.index(")=(", at))
          key = line[(at + Regexp.last_match(0).length)...split]
          start = split + 3
          finish = line.index(KEY_VALUES_END, start) || line.rindex(")")
          finish = line.length unless finish && finish >= start
          secret = key.scan(/[A-Za-z_][\w$]*/).any? { |word| (name = key_name(word)) && !descriptor_name?(name) }
          out << line[cursor...start] << (secret ? FILTERED : line[start...finish])
          cursor = finish
        end
        out << line[cursor..]
      end

      # MySQL's syntax error quotes the statement from where it stopped reading, which can start inside
      # a value, so the excerpt is filtered whole.
      def syntax_near(line)
        at = line.index(SYNTAX_NEAR) or return line
        start = at + SYNTAX_NEAR.length
        finish = line.rindex(/' at line \d+/)
        finish = line.length unless finish && finish >= start
        line[0...start] + FILTERED + line[finish..]
      end

      # A JSON log line, or one a header stands before: each string value is read as a log line of its
      # own, so a statement a formatter wrote into one is read as SQL. A value under a secret's key is
      # filtered, an array's or an object's included, and so are a JSON logger's binds when the
      # statement beside them names a secret column. Any other line as it is.
      def json_line(line)
        start = line.index(/[{\[]/)
        return line unless start && line.rstrip.end_with?("}", "]")

        tokens = json_tokens(line[start..]) or return line
        named = json_named(tokens)
        binds = [ false ]
        key = nil
        out = +line[0...start]
        i = 0
        while i < tokens.size
          kind, text = tokens[i]
          if kind == :punct && [ "{", "[" ].include?(text) && json_secret_key?(key)
            # A secret's key holding an object or an array is filtered whole.
            out << JSON.generate(FILTERED)
            i = json_close(tokens, i)
            key = nil
          elsif kind == :punct
            case text
            when "{", "[" then binds << (binds.last || key == "binds")
            when "}", "]" then binds.pop if binds.size > 1
            end
            key = nil if [ "{", "[", "}", "]", "," ].include?(text)
            out << text
          elsif json_key?(tokens, i)
            key = json_text(text)
            out << text
          else
            value = json_text(text)
            name = key && key_name(key)
            hide = (name && value.is_a?(String) && log_secret?(name, value)) || ((binds.last || key == "binds") && named.any?)
            out << (hide ? JSON.generate(FILTERED) : json_value(text, value))
          end
          i += 1
        end
        out
      end

      # The index of the bracket that closes the one at tokens[open].
      def json_close(tokens, open)
        depth = 0
        (open...tokens.size).each do |i|
          kind, text = tokens[i]
          next unless kind == :punct

          depth += 1 if [ "{", "[" ].include?(text)
          depth -= 1 if [ "}", "]" ].include?(text)
          return i if depth.zero?
        end
        tokens.size
      end

      # [kind, text] for each string and each other run of a JSON text, nil for one with a string cut off.
      def json_tokens(text)
        scanner = StringScanner.new(text)
        tokens = []
        until scanner.eos?
          if scanner.scan(JSON_STRING) then tokens << [ :string, scanner.matched ]
          elsif scanner.check(/"/) then return nil
          else tokens << [ :punct, scanner.scan(/[{}\[\]:,]|[^"{}\[\]:,]+/) ]
          end
        end
        tokens
      end

      def json_key?(tokens, i)
        j = i + 1
        j += 1 while tokens[j] && tokens[j].first == :punct && tokens[j][1].strip.empty?
        tokens[j]&.at(1) == ":"
      end

      # The secret names the statements of a JSON line's "sql" keys hold.
      def json_named(tokens)
        tokens.each_index.each_with_object([]) do |i, named|
          next unless tokens[i].first == :string && json_key?(tokens, i) && json_text(tokens[i][1]) == "sql"

          j = i + 1
          j += 1 while tokens[j] && tokens[j].first != :string
          sql = tokens[j] && json_text(tokens[j][1])
          named.concat(sql_secret_names(sql_tokens(sql, sql_dialects(sql).first))) if sql.is_a?(String)
        end
      end

      def json_secret_key?(key)
        name = key && key_name(key)
        name && !descriptor_name?(name) && !keyish_only?(name) ? true : false
      end

      def json_text(token)
        JSON.parse(token)
      rescue JSON::ParserError
        nil
      end

      def json_value(token, text)
        return token unless text.is_a?(String)

        redacted = redact_log_line(text)
        redacted == text ? token : JSON.generate(redacted)
      end

      def sql_keyword?(token, word)
        token&.first == :word && token[1].casecmp?(word)
      end

      # A name with its quotes gone.
      def sql_name(text)
        quote = text[0]
        return text unless quote == "`" || quote == '"'

        text[1..].delete_suffix(quote).gsub(quote * 2, quote)
      end

      # A logged bind pair `["name", "value"]` with its value gone when the name is a secret.
      def filter_bind(match)
        name = key_name(match[1])
        return match[0] unless name && log_secret?(name, match[2])

        %(["#{match[1]}", "#{FILTERED}"])
      end

      # The setting name at the head of a matched assignment.
      def descriptor?(match)
        match[/\A\w+/].to_s.match?(DESCRIPTOR_SUFFIX)
      end
    end
  end
end
