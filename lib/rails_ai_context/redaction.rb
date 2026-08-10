# frozen_string_literal: true

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

    # Regex by design: these scrub vocabulary out of values already read from
    # the AST or a log file rather than parsing structure. A credential can
    # sit in an interpolation, a heredoc or a bare string, and no node type
    # marks one - the words are the signal.
    SECRET_WORD = /password|passwd|secret|token|api_key|apikey|access_key|private_key|credentials|
                   pepper|salt|master_key|signing_key|encryption_key|deterministic_key/x

    # `primary_key` is ordinary ActiveRecord vocabulary; under
    # `active_record.encryption` it is a credential. Only the path tells them
    # apart, so these are matched against the whole path, not the leaf.
    SECRET_PATH = /encryption\.(?:primary_key|deterministic_key|key_derivation_salt)\z/i

    # The secret word has to be a whole underscore-delimited part of the name,
    # so `secret_key` and `api_key` match while `passwordless_login` does not.
    SECRET_NAME = /(?<!\w)(?:\w+_)?(?:#{SECRET_WORD})(?:_\w+)?(?!\w)/i

    # `password_length` and `token_expiry` describe a secret rather than
    # being one; their values are policy, and filtering them hides config the
    # reader asked for.
    DESCRIPTOR_SUFFIX = /_(?:length|size|min|max|expiry|ttl|strategy|regex|format|field|params?|columns?|names?|enabled|required|confirmation|count|algorithm|method|type|salt_length)\z/i

    # `=(?!>)` so the alternation cannot backtrack into matching the `=` of a
    # `=>` and treating the stray `>` as the value.
    ASSIGN = /\s*(?::|=>|=(?!>))\s*/

    URI_USERINFO = %r{([a-z][a-z0-9+.-]*://)[^\s/]*:[^@\s]+@}i
    QUOTED_SECRET = /#{SECRET_NAME}#{ASSIGN}["'][^"']*["']/
    BARE_SECRET = /#{SECRET_NAME}#{ASSIGN}(?!["'])[^\s,;)\]}]+/

    # A value actually shaped like a credential: a long hex blob or a vendor
    # prefix. For callers reading a bare value with no key beside it to match
    # on.
    CREDENTIAL_SHAPE = /[a-f0-9]{16,}|sk_|pk_/i

    # The above, plus a value that merely names itself a secret. Right for a
    # real `.env`, wrong for a `.env.example`, whose placeholders exist to be
    # read and often say "secret" precisely because they are not one.
    SECRET_VALUE = /#{CREDENTIAL_SHAPE}|key_|secret/i

    ANSI_ESCAPE = /\e\[[0-9;]*[mGKHF]/
    EMAIL_PATTERN = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}\b/i
    DOTENV_LINE = /\[dotenv\]\s+Set\s+.*/i
    ENV_VAR_LINE = /\b[A-Z][A-Z0-9_]*(SECRET|KEY|TOKEN|PASSWORD|API|CREDENTIAL)[A-Z0-9_]*=\S+/

    # Each entry is [pattern, replacement]. The replacement is spelled beside
    # the pattern rather than worked out later by grepping the pattern's own
    # source for a distinguishing substring.
    LOG_PATTERNS = [
      [ /(?<=password=)\S+/i, FILTERED ],
      [ /(?<=password:\s)\S+/i, FILTERED ],
      [ /("password":\s*")[^"]+(")/i, "\\1#{FILTERED}\\2" ],
      [ /("password"=>")[^"]+(")/i, "\\1#{FILTERED}\\2" ],
      [ /(?<=token=)\S+/i, FILTERED ],
      [ /(?<=token:\s)\S+/i, FILTERED ],
      [ /(?<=secret=)\S+/i, FILTERED ],
      [ /(?<=secret:\s)\S+/i, FILTERED ],
      [ /(?<=api_key=)\S+/i, FILTERED ],
      [ /(?<=api_key:\s)\S+/i, FILTERED ],
      [ /(?<=authorization:\s)(Bearer\s)?\S+/i, FILTERED ],
      # Keeps the variable's name, filters only what it was set to.
      [ /((?:SECRET|PRIVATE|SIGNING|ENCRYPTION)[_A-Z]*=)\S+/i, "\\1#{FILTERED}" ],
      [ /(?<=cookie:\s)\S+/i, FILTERED ],
      [ /(?<=session_id=)\S+/i, FILTERED ],
      [ /(?<=_session=)\S+/i, FILTERED ],
      [ /\bAKIA[0-9A-Z]{16}\b/, FILTERED ],
      [ /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/, FILTERED ],
      [ /-----BEGIN\s+(RSA|DSA|EC|OPENSSH)?\s*PRIVATE KEY-----/, FILTERED ],
      [ /\bsk_(?:live|test)_[A-Za-z0-9]{10,}\b/, FILTERED ],
      [ /\brk_(?:live|test)_[A-Za-z0-9]{10,}\b/, FILTERED ],
      [ /\bSG\.[A-Za-z0-9_-]{22,}\.[A-Za-z0-9_-]{10,}\b/, FILTERED ],
      [ /\bxox[bpras]-[A-Za-z0-9-]{10,}\b/, FILTERED ],
      [ /\bghp_[A-Za-z0-9]{36,}\b/, FILTERED ],
      [ /\bghu_[A-Za-z0-9]{36,}\b/, FILTERED ],
      [ /\bghs_[A-Za-z0-9]{36,}\b/, FILTERED ],
      [ /\bglpat-[A-Za-z0-9_-]{20,}\b/, FILTERED ],
      [ /\bnpm_[A-Za-z0-9]{36,}\b/, FILTERED ]
    ].freeze

    class << self
      # Source slices and config values.
      def call(value)
        return value unless value.is_a?(String)

        value
          .gsub(URI_USERINFO) { "#{Regexp.last_match(1)}#{FILTERED}@" }
          .gsub(QUOTED_SECRET) { |m| descriptor?(m) ? m : m.sub(/["'][^"']*["']\s*\z/, %("#{FILTERED}")) }
          .gsub(BARE_SECRET) { |m| descriptor?(m) ? m : m.sub(/\S+\z/, FILTERED) }
      end

      # A config value arrives without its context, so the setting's name is
      # what says whether it holds a secret. Values are walked rather than
      # type-checked: an evaluated value is often a hash or an array, and the
      # credential is as often under a key inside it (`smtp_settings` holding
      # a `password`) as it is under the setting itself.
      #
      # @param name [Symbol, String, Array] the setting, or its full path
      def redact_setting(name, source)
        walk(source, secret_name?(name))
      end

      def secret_value?(value)
        value.to_s.match?(SECRET_VALUE)
      end

      def credential_shaped?(value)
        value.to_s.match?(CREDENTIAL_SHAPE)
      end

      def secret_name?(name)
        path = Array(name).join(".")
        return true if path.match?(SECRET_PATH)

        leaf = path.split(".").last.to_s
        leaf.match?(/\A#{SECRET_NAME}\z/) && !leaf.match?(DESCRIPTOR_SUFFIX)
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
        result.gsub!(ENV_VAR_LINE, FILTERED)
        result.gsub!(EMAIL_PATTERN, EMAIL)

        LOG_PATTERNS.each { |pattern, replacement| result.gsub!(pattern, replacement) }

        result
      end

      private

      # `secret` says the enclosing name already marks this as credential
      # material. Symbols, numbers and booleans are identifiers and policy,
      # never secrets, so they survive either way - filtering them would hide
      # the config the reader came for (`reset_password_keys = [:email]`).
      def walk(value, secret)
        case value
        when nil    then nil
        when String then secret ? filtered_like(value) : call(value)
        when Array  then value.map { |element| walk(element, secret) }
        when Hash   then value.to_h { |key, inner| [ key, walk(inner, secret || secret_name?(key)) ] }
        else value
        end
      end

      # Keeps the quoting of a source slice so the result still reads as the
      # assignment it replaced.
      def filtered_like(value)
        quote = value.start_with?('"', "'") ? value[0] : nil
        quote ? "#{quote}#{FILTERED}#{quote}" : FILTERED
      end

      # The setting name at the head of a matched assignment.
      def descriptor?(match)
        match[/\A\w+/].to_s.match?(DESCRIPTOR_SUFFIX)
      end
    end
  end
end
