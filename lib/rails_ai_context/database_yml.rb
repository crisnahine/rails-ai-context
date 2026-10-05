# frozen_string_literal: true

require "yaml"

module RailsAiContext
  # config/database.yml read without booting: YAML, so anchors, merge keys and
  # comments follow the file format itself, and ERB never runs.
  module DatabaseYml
    ERB_SENTINEL = "__rails_ai_context_erb__"
    # `ENV["X"].presence || "mysql2"`: the literal is what runs with the variable unset.
    ERB_DEFAULT = /\|\|\s*(["'])([\w.-]+)\1\s*\z/
    # ActiveRecord.protocol_adapters' defaults.
    URL_SCHEME_ADAPTERS = { "postgres" => "postgresql", "mysql" => "mysql2", "sqlite" => "sqlite3" }.freeze

    module_function

    # The running environment's entry, or nil when the file is missing or unreadable.
    def env(root)
      path = File.join(root.to_s, "config/database.yml")
      return nil unless File.exist?(path)

      content = RailsAiContext::SafeFile.read(path)
      return nil unless content

      data = YAML.safe_load(neutralize_erb(content), aliases: true, permitted_classes: [ Symbol ])
      return nil unless data.is_a?(Hash)

      data[RailsAiContext.environment_name]
    rescue => e
      RailsAiContext.debug_fail(e, nil, label: "database_yml")
    end

    # The primary database's settings: Rails' own rule is that an env whose values
    # are all Hashes names one database per key, the primary first.
    def primary(root)
      config = env(root)
      return nil unless config.is_a?(Hash) && config.any?
      return config unless config.values.all? { |value| value.is_a?(Hash) }

      config["primary"] || config.values.first
    end

    # The named database's settings in the running environment, or nil.
    def entry(root, name)
      config = env(root)
      return nil unless config.is_a?(Hash) && config.any?
      return (config if name == "primary") unless config.values.all? { |value| value.is_a?(Hash) }

      config[name] || (config.values.first if name == "primary")
    end

    # Rails' DatabaseConfigurations: an entry's own url wins over its keys, and an entry
    # without one takes <NAME>_DATABASE_URL, or DATABASE_URL for the primary.
    def url_adapter(name, own_url)
      url = own_url.nil? ? ENV["#{name.upcase}_DATABASE_URL"] || (ENV["DATABASE_URL"] if name == "primary") : own_url.to_s
      return nil if url.to_s.empty? || computed?(url)

      scheme = url[/\A([a-z][a-z0-9+.-]*):/i, 1]&.tr("-", "_")
      scheme && URL_SCHEME_ADAPTERS.fetch(scheme, scheme)
    end

    # An output tag becomes an unknown marker, other tags go, and both keep their
    # newlines so the rest of the file parses at its written indentation.
    def neutralize_erb(content)
      content.gsub(RailsAiContext::ErbSource::TAG) do |tag|
        (tag.start_with?("<%=") ? ERB_SENTINEL + Regexp.last_match(1).to_s[ERB_DEFAULT, 2].to_s : "") + ("\n" * tag.count("\n"))
      end
    end

    def computed?(value)
      value.to_s.include?(ERB_SENTINEL)
    end
  end
end
