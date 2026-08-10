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
    SECRET_WORD = /password|passwd|secret|token|api_key|apikey|access_key|private_key|credentials/

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

    ANSI_ESCAPE = /\e\[[0-9;]*[mGKHF]/
    EMAIL_PATTERN = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}\b/i
    DOTENV_LINE = /\[dotenv\]\s+Set\s+.*/i
    ENV_VAR_LINE = /\b[A-Z][A-Z0-9_]*(SECRET|KEY|TOKEN|PASSWORD|API|CREDENTIAL)[A-Z0-9_]*=\S+/

    LOG_PATTERNS = [
      /(?<=password=)\S+/i,
      /(?<=password:\s)\S+/i,
      /("password":\s*")[^"]+(")/i,
      /("password"=>")[^"]+(")/i,
      /(?<=token=)\S+/i,
      /(?<=token:\s)\S+/i,
      /(?<=secret=)\S+/i,
      /(?<=secret:\s)\S+/i,
      /(?<=api_key=)\S+/i,
      /(?<=api_key:\s)\S+/i,
      /(?<=authorization:\s)(Bearer\s)?\S+/i,
      /(SECRET|PRIVATE|SIGNING|ENCRYPTION)[_A-Z]*=\S+/i,
      /(?<=cookie:\s)\S+/i,
      /(?<=session_id=)\S+/i,
      /(?<=_session=)\S+/i,
      /\bAKIA[0-9A-Z]{16}\b/,
      /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
      /-----BEGIN\s+(RSA|DSA|EC|OPENSSH)?\s*PRIVATE KEY-----/,
      /\bsk_(?:live|test)_[A-Za-z0-9]{10,}\b/,
      /\brk_(?:live|test)_[A-Za-z0-9]{10,}\b/,
      /\bSG\.[A-Za-z0-9_-]{22,}\.[A-Za-z0-9_-]{10,}\b/,
      /\bxox[bpras]-[A-Za-z0-9-]{10,}\b/,
      /\bghp_[A-Za-z0-9]{36,}\b/,
      /\bghu_[A-Za-z0-9]{36,}\b/,
      /\bghs_[A-Za-z0-9]{36,}\b/,
      /\bglpat-[A-Za-z0-9_-]{20,}\b/,
      /\bnpm_[A-Za-z0-9]{36,}\b/
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

      # A config value arrives on its own, so only the setting's name says
      # whether it is a secret: `config.secret_key = "s3cr3t"` reaches a
      # listener as the bare string `"s3cr3t"`, which looks like any other.
      def redact_setting(name, source)
        return source unless source.is_a?(String)
        return call(source) unless secret_name?(name)

        quote = source.start_with?('"', "'") ? source[0] : nil
        quote ? "#{quote}#{FILTERED}#{quote}" : FILTERED
      end

      def secret_name?(name)
        name = name.to_s
        name.match?(/\A#{SECRET_NAME}\z/) && !name.match?(DESCRIPTOR_SUFFIX)
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

        LOG_PATTERNS.each do |pattern|
          if pattern.source.include?("password\":") || pattern.source.include?("password\"=>")
            result.gsub!(pattern, "\\1#{FILTERED}\\2")
          elsif pattern.source.include?("SECRET|PRIVATE")
            result.gsub!(pattern) { |m| "#{m.split('=', 2)[0]}=#{FILTERED}" }
          else
            result.gsub!(pattern, FILTERED)
          end
        end

        result
      end

      private

      # The setting name at the head of a matched assignment.
      def descriptor?(match)
        match[/\A\w+/].to_s.match?(DESCRIPTOR_SUFFIX)
      end
    end
  end
end
