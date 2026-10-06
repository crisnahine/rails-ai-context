# frozen_string_literal: true

require "uri"
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
      data = file(root)
      data[RailsAiContext.environment_name] if data
    end

    # Every environment by name. Every database question routes here, so a run reads the file once.
    def file(root)
      RailsAiContext::RunCache.fetch([ :database_yml, root.to_s ]) { read_file(root) }
    end

    def read_file(root)
      path = File.join(root.to_s, "config/database.yml")
      return nil unless File.exist?(path)

      content = RailsAiContext::SafeFile.read(path)
      return nil unless content

      data = YAML.safe_load(neutralize_erb(content), aliases: true, permitted_classes: [ Symbol ])
      data if data.is_a?(Hash)
    rescue => e
      RailsAiContext.debug_fail(e, nil, label: "database_yml")
    end

    # Each database by name, in the file's order. An env whose values are all Hashes names one database per key.
    def databases(root)
      databases_in(env(root))
    end

    def databases_in(config)
      return {} unless config.is_a?(Hash) && config.any?

      config.values.all?(Hash) ? config : { "primary" => config }
    end

    # Rails' rule: "primary", else the first database.
    def primary_name(root)
      primary_name_in(databases(root))
    end

    def primary_name_in(found)
      found.key?("primary") ? "primary" : found.keys.first
    end

    # The databases other than the primary that Rails dumps and migrates:
    # HashConfig#database_tasks? skips a replica and database_tasks: false.
    def task_secondaries(root)
      databases(root).except(primary_name(root)).select { |_, entry| !entry["replica"] && entry.fetch("database_tasks", true) }
    end

    # The primary database's settings.
    def primary(root)
      databases(root)[primary_name(root)]
    end

    # A database's schema_search_path as PostgreSQL reads it: an unquoted name folds to
    # lowercase and "$user" is the configured username. Unset, PostgreSQL's "$user", public.
    def schema_search_path(root, name = "primary")
      settings = entry(root, name)
      settings = {} unless settings.is_a?(Hash)
      known = adapter(name, settings).first
      return %w[public] if known && !known.start_with?("postg")

      settings = settings.merge(url_settings(name, settings["url"]))
      # postgresql_adapter.rb:984 (8.1), :865 (7.0): schema_order is the older name.
      text = (settings["schema_search_path"] || settings["schema_order"]).to_s
      text = '"$user", public' if text.strip.empty?
      user = settings["username"].to_s
      text.split(",").filter_map do |part|
        part = part.strip
        next if part.empty? || computed?(part)
        next (user unless user.empty? || computed?(user)) if part.delete('"') == "$user"

        part.start_with?('"') ? part.delete('"') : part.downcase
      end
    end

    # The named database's settings in the running environment, or nil.
    def entry(root, name)
      entry_in(databases(root), name)
    end

    # [environment, settings] from the first other environment that configures the database,
    # the one whose tasks wrote its dump; nil when none does.
    def elsewhere(root, name)
      data = file(root)
      return nil unless data

      # A key with no config/environments file holds an anchor (`default: &default`), not an environment.
      declared = Dir.glob(File.join(root.to_s, "config/environments/*.rb")).map { |path| File.basename(path, ".rb") }
      data.each do |env_name, config|
        next if env_name == RailsAiContext.environment_name
        next if declared.any? && !declared.include?(env_name)

        found = entry_in(databases_in(config), name)
        return [ env_name, found ] if found.is_a?(Hash)
      end
      nil
    end

    def entry_in(found, name)
      found[name] || (found[primary_name_in(found)] if name == "primary")
    end

    # Rails' DatabaseConfigurations: an entry's own url wins over its keys, and an entry
    # without one takes <NAME>_DATABASE_URL, or DATABASE_URL for the primary.
    def url_adapter(name, own_url)
      url = url_for(name, own_url) or return nil

      scheme = url[/\A([a-z][a-z0-9+.-]*):/i, 1]&.tr("-", "_")
      scheme && URL_SCHEME_ADAPTERS.fetch(scheme, scheme)
    end

    def url_for(name, own_url)
      url = own_url.nil? ? ENV["#{name.upcase}_DATABASE_URL"] || (ENV["DATABASE_URL"] if name == "primary") : own_url.to_s
      url unless url.to_s.empty? || computed?(url)
    end

    # The username and schema_search_path a database URL carries, which Rails merges over the entry's keys.
    def url_settings(name, own_url)
      uri = URI.parse(url_for(name, own_url).to_s)
      found = uri.query ? URI.decode_www_form(uri.query).to_h.slice("schema_search_path") : {}
      found["username"] = URI.decode_www_form_component(uri.user) if uri.user
      found
    rescue URI::Error, ArgumentError
      {}
    end

    # [adapter, from_default]: the URL's scheme wins, then the entry's adapter. An ERB-computed
    # value is unknown unless it is one tag carrying its own literal default.
    def adapter(name, entry)
      entry = {} unless entry.is_a?(Hash)
      from_url = url_adapter(name.to_s, entry["url"])
      return [ from_url, false ] if from_url

      text = entry["adapter"]&.to_s
      return [ text, false ] unless computed?(text)
      return [ nil, false ] unless text.start_with?(ERB_SENTINEL) && text.scan(ERB_SENTINEL).size == 1

      literal = text.delete_prefix(ERB_SENTINEL)
      literal.empty? ? [ nil, false ] : [ literal, true ]
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
