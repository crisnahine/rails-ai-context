# frozen_string_literal: true

require_relative "safe_path"

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
    YAML_FILE = /\.ya?ml(?:\.(?:erb|#{PLACEHOLDER_NAMES}))*\z/
    # A log, rotated or kept ones included: Logger's development.log.0, logrotate's .log-20261001, .log-2026-10-01 and .log.old, and a .log.bak.
    LOG_FILE = /\.log(?:\.\d+|-\d{4}-?\d{2}-?\d{2}(?:-?\d{2})?|\.old|\.bak)?\z/

    # Regex by design: these scrub vocabulary out of values already read from
    # the AST or a log file rather than parsing structure. A credential can
    # sit in an interpolation, a heredoc or a bare string, and no node type
    # marks one - the words are the signal.
    SECRET_WORD = /password|passwd|secret|token|api_key|apikey|access_key|private_key|credentials|
                   pepper|salt|master_key|signing_key|encryption_key|deterministic_key|cipher_key|aes_key|cbc_key|gcm_key|hmac_key/xi

    # `primary_key` is ordinary ActiveRecord vocabulary; under
    # `active_record.encryption` it is a credential. Only the path tells them
    # apart, so these are matched against the whole path, not the leaf.
    SECRET_PATH = /encryption\.(?:primary_key|deterministic_key|key_derivation_salt)\z/i

    # The secret word has to be a whole underscore-delimited part of the name,
    # so `secret_key` and `api_key` match while `passwordless_login` does not.
    # A name is a whole word, so it is taken atomically: when what follows it
    # fails, trying the word split another way cannot help, and doing so cost
    # the square of a long word with the secret word in many of its parts.
    SECRET_NAME = /(?<!\w)(?>(?:\w+_)?(?:#{SECRET_WORD})(?:_\w+)?(?!\w))/i

    # A name ending in `_KEY`/`Key`/`key` is as often a cache or i18n key as a credential,
    # so under it only a credential-looking value is filtered (see key_credential?).
    KEYISH_NAME = /(?<!\w)(?:\w*_)?(?:KEY|[Kk]ey)(?!\w)|(?<!\w)[a-z][A-Za-z0-9]*Key(?!\w)/

    # `password_length` and `token_expiry` describe a secret rather than
    # being one; their values are policy, and filtering them hides config the
    # reader asked for.
    DESCRIPTOR_SUFFIX = /_(?:length|size|min|max|expiry|ttl|strategy|regex|format|field|params?|columns?|names?|enabled|required|count|algorithm|method|type|salt_length)\z/i

    # `=(?!>)` so the alternation cannot backtrack into matching the `=` of a
    # `=>` and treating the stray `>` as the value.
    ASSIGN = /\s*(?::|=>|=(?!>))\s*/

    # Userinfo holds no quote, bracket or slash, so the match cannot run across JSON or a path.
    URI_USERINFO = %r{([a-z][a-z0-9+.-]*://)[^\s/"'<>@]*:[^@\s/"'<>]+@}i
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
    # code or config is written this way. A JWT's signature may be empty.
    CREDENTIAL_TOKENS = [
      /\bAKIA[0-9A-Z]{16}\b/,
      /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*/,
      /\bsk_(?:live|test)_[A-Za-z0-9]{10,}\b/,
      /\brk_(?:live|test)_[A-Za-z0-9]{10,}\b/,
      /\bSG\.[A-Za-z0-9_-]{22,}\.[A-Za-z0-9_-]{10,}\b/,
      /\bxox[bpras]-[A-Za-z0-9-]{10,}\b/,
      /\bgh[pus]_[A-Za-z0-9]{36,}\b/,
      /\bglpat-[A-Za-z0-9_-]{20,}\b/,
      /\bnpm_[A-Za-z0-9]{36,}\b/,
      /\bsk-(?:ant-|proj-)?(?=[\w-]*\d)[\w-]{32,}/
    ].freeze

    PEM_BEGIN = /-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----/
    PEM_END = /-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----/
    # A marker opens a block only when it ends its line (a regex or a string naming it is code),
    # and the block lasts while its lines read as key body: base64, an armor header, blank.
    LINE_TAIL = %r{(?:\\n)?["'`]?[ \t]*(?:[\\+,][ \t]*)?\z}
    PEM_OPENS = /#{PEM_BEGIN}[ \t]*(?:\\n)?(?:\z|(?<=\\n)["'`][ \t]*[\\+,]?[ \t]*\z|["'`][ \t]*[\\+,][ \t]*\z)/
    PEM_BODY = %r{\A\s*["'`]?(?:[A-Za-z0-9+/=]+|(?:Proc-Type|DEK-Info|Version|Comment):.*)?#{LINE_TAIL}}
    # A key in one literal: the marker, any armor headers, then a body-length base64 run.
    PEM_INLINE = %r{#{PEM_BEGIN}.*?[A-Za-z0-9+/]{40,}}m

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
    # (`accessToken`, `clientSecret`, `secretAccessKey`, `jwtSecretKey`), as one between
    # underscores is in SECRET_NAME. `tokenizer` and `secretary` have none.
    CAMEL_SECRET_NAME = /(?<!\w)(?>(?:secret|token|[a-z][a-z\d]*(?:[A-Z][a-z\d]*)*?(?:Secret|Token))(?:[A-Z][a-z\d]*)*(?!\w))/
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
    LOG_SECRET_ASSIGNMENT = /
      (["']?)((?<![\w-])(?=[\w-]*?(?:#{KEY_NAME}))[\w-]++)\1
      (\s*(?:=>|:|=(?!>))\s*)
      (?!["']?\[FILTERED\])(?:"([^"]*)"|'([^']*)'|([^\s,;&)\]}]+))
    /xi
    # A `["name", "value"]` pair in a query's logged binds. Active Record filters a bind only
    # when config.filter_parameters lists its name, which pre-Rails-7 apps often leave at
    # [:password], so a token or reset key logs in full. The name and the quoted value are
    # captured and the value filtered when the name is a secret; a bare value (a number, nil) is
    # left, as is the `$n` placeholder in the SQL before the binds.
    LOG_BIND = /\[\s*"((?:[^"\\]|\\.)*)"\s*,\s*("(?:[^"\\]|\\.)*")\s*\]/

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
    # lookbehind and a regex's wildcard (`/--password=.+/`) are not assignments.
    ENV_ASSIGNMENT = /(?<![\w.:=!])(?<name>#{KEY_NAME})=(?!\#\{|\.[*+?])(?<value>[^\s"'`$<>\\()\[\]{},;&]+)/

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
    NAMING_LINE = /\A(?<indent>[ \t]*)(?:-[ \t]+(?:key|name)[ \t]*:[ \t]+["']?(?<name>#{KEY_NAME})["']?|["']?(?<name>#{KEY_NAME})["']?[ \t]*:[ \t]*\{?)[ \t]*\z/
    VALUE_LINE = /\A(?<head>[ \t]*["']?value["']?[ \t]*:[ \t]*)(?:(?<quote>["'])(?<value>[^"']*)\k<quote>|(?<value>[^\s"'#,{\[][^#,]*?))(?<tail>[ \t]*,?[ \t]*(?:#.*)?)\z/
    STRUCTURED_FILE = /#{YAML_FILE}|\.json(?:\.(?:#{PLACEHOLDER_NAMES}))*\z/

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

        # Locale files hold translations: only credential formats are filtered.
        # Example files often hold real values, so only a plain placeholder is kept.
        locale = path.to_s.match?(%r{(?:\A|/)locales?/})
        example = path.to_s.match?(EXAMPLE_FILE)
        result = line.gsub(URI_USERINFO) { |m| placeholder?(m) ? m : "#{Regexp.last_match(1)}#{FILTERED}@" }
        unless locale
          result = result.gsub(KEYED_LITERAL) do |m|
            match = Regexp.last_match
            # `cond ? "pass" : "fail"` is a ternary: its branches are values, not a key and its value.
            next m if match[:assign].strip == ":" && match.pre_match.match?(/\?\s*\z/)

            filter_literal(m, match, example)
          end
          result = result.gsub(CALL_KEYED) { |m| filter_literal(m, Regexp.last_match, example) }
          result = result.gsub(ENV_ASSIGNMENT) do |m|
            match = Regexp.last_match
            next m unless keyed_secret?(match[:name], match[:value], example)

            "#{match[:name]}=#{FILTERED}"
          end
          result = result.gsub(FLAG_ARGUMENT) { |m| filter_flag(m, Regexp.last_match, example) }
          result = result.gsub(NAMED_OBJECT) { |m| filter_named_object(m, Regexp.last_match, example) }
        end
        result = result.gsub(STRING_LITERAL) { |lit| credential?(lit[1..-2]) ? "#{lit[0]}#{FILTERED}#{lit[0]}" : lit }
        result = CREDENTIAL_TOKENS.reduce(result) { |text, pattern| text.gsub(pattern, FILTERED) }
        result = scheme_credentials(result)
        # A log shown as a file (a tracked log's diff) gets what rails_read_logs filters too.
        return redact_log_line(result) if path.to_s.match?(LOG_FILE)

        path.to_s.match?(YAML_FILE) && !locale ? yaml_scalar(result, example) : result
      end

      # Consecutive lines, so a PEM key across them is filtered whole, and in a
      # YAML or JSON file a `value` under a mapping a secret's name names; the
      # line count is kept, since callers number the lines.
      def redact_source_lines(lines, path: nil)
        redacted = outside_key_bodies(lines) { |line| redact_source_line(line, path: path) }
        return redacted unless path.to_s.match?(STRUCTURED_FILE) && !path.to_s.match?(%r{(?:\A|/)locales?/})

        named_values(redacted, path.to_s.match?(EXAMPLE_FILE))
      end

      # A slice of the app's source - a method body, a template - as a tool
      # prints it: the same lines, each secret filtered.
      def redact_source(text, path: nil)
        return text unless text.is_a?(String)

        trailing = text.end_with?("\n") ? "\n" : ""
        redact_source_lines(text.lines.map(&:chomp), path: path).join("\n") + trailing
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

        result = line.dup
        result.gsub!(ANSI_ESCAPE, "")
        result.gsub!(DOTENV_LINE, "[dotenv] Set #{FILTERED}")
        result.gsub!(URI_USERINFO) { "#{Regexp.last_match(1)}#{FILTERED}@" }
        result.gsub!(ENV_ASSIGNMENT) do |m|
          name = Regexp.last_match(:name)
          log_secret?(name, Regexp.last_match(:value)) ? "#{name}=#{FILTERED}" : m
        end
        result.gsub!(FLAG_ARGUMENT) { |m| filter_flag(m, Regexp.last_match, false) }
        result.gsub!(result.encoding == Encoding::UTF_8 ? EMAIL_PATTERN : ASCII_EMAIL_PATTERN, EMAIL)

        result.gsub!(LOG_SECRET_ASSIGNMENT) { filter_assignment(Regexp.last_match) }
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

        scheme_credentials(result)
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

      # Redacting before the search means a term can only match text the
      # reader would see; matching the original told a caller whether a
      # secret was there by whether a line came back.
      def redact_log_lines(lines, search: nil)
        redacted = outside_key_bodies(Array(lines)) { |line| redact_log_line(line) }
        term = search.to_s.strip
        return redacted if term.empty?

        needle = term.downcase
        redacted.select { |line| line.downcase.include?(needle) }
      end

      private

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
      def named_values(lines, example)
        named = nil
        lines.map do |line|
          if (naming = line.match(NAMING_LINE))
            named = { name: naming[:name], indent: naming[:indent].size }
            next line
          end
          next line if line.strip.empty?

          named = nil if named && line[/\A[ \t]*/].size <= named[:indent]
          value = named && line.match(VALUE_LINE)
          next line unless value

          scalar = value[:value].to_s
          next line if scalar.empty? || scalar.start_with?(FILTERED) || scalar.match?(/\A(?:true|false|yes|no|null|~)\z/i)
          next line unless keyed_secret?(named[:name], scalar, example)

          "#{value[:head]}#{value[:quote]}#{FILTERED}#{value[:quote]}#{value[:tail]}"
        end
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
        return true if CREDENTIAL_TOKENS.any? { |pattern| value.match?(pattern) }
        return false if placeholder?(value)

        alnum = value.delete("^A-Za-z0-9")
        alnum.length >= 16 && alnum.match?(/[A-Za-z]/) && alnum.match?(/\d/)
      end

      # The one verdict on a name and value in a log line, whichever pattern found the pair.
      def log_secret?(name, value)
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

      # By format only: a long random literal is as often an id as a key.
      def credential?(inner)
        return false if placeholder?(inner)

        inner.match?(PEM_INLINE) || CREDENTIAL_TOKENS.any? { |pattern| inner.match?(pattern) }
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
      ENV_NAME = /\A_?[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\z/

      # A switch's value (`showPassword=false`), not a credential, under any name.
      NOT_A_SECRET_WORD = /\A(?:true|false|yes|no|on|off|null|nil|none|undefined)\z/i

      def secret_literal?(value, key)
        password = key.match?(WHOLE_PASSWORD_NAME)
        return false if value.length < (password ? 4 : 8) || !value.ascii_only? || placeholder?(value)
        return false if value.match?(NOT_A_SECRET_WORD)
        # The key's own name, in any case (`currentPassword: "current_password"`, an enum's `password: 'password'`).
        return false if snake_name(value) == snake_name(key)
        # Whitespace makes a message, except in a passphrase.
        return false if value.match?(/\s/) && !key.match?(/passphrase/i)
        # Under a password key a word-joined value is the password itself.
        return false if !password && names_a_secret?(value)
        return false if value.match?(ENV_NAME) && (value.start_with?("_", "HTTP_") || secret_words?(value))

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
        words = value.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2').gsub(/([a-z])([A-Z])/, '\\1_\\2')
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
        return true if CREDENTIAL_TOKENS.any? { |pattern| value.match?(pattern) }
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
        return match[0] unless name && log_secret?(name, match[4] || match[5] || match[6])

        value_quote = match[4] ? '"' : (match[5] ? "'" : "")
        "#{quote}#{key}#{quote}#{assign}#{value_quote}#{FILTERED}#{value_quote}"
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
