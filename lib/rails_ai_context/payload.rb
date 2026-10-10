# frozen_string_literal: true

module RailsAiContext
  # The reading side of the introspection payload. Consumers used to reach
  # into the context hash by literal symbol behind an `x[:a] || x[:b] || []`
  # idiom, which turns a wrong key into "the app has none of these": the
  # engines and Hotwire lines were dead in every context file because the
  # readers named keys no introspector emits (#144, #145). A key named here
  # is pinned against the producing introspector's own output by spec, so a
  # rename fails loudly instead of silently emptying a section.
  module Payload
    # Every list this module can read: reader name => [section key, key
    # inside the section]. The spec walks this table against the
    # introspectors' real output.
    LISTS = {
      mounted_engines: %i[engines mounted_engines],
      in_repo_engines: %i[engines in_repo_engines],
      turbo_frames: %i[turbo turbo_frames],
      turbo_streams: %i[turbo turbo_streams],
      model_broadcasts: %i[turbo model_broadcasts],
      explicit_broadcasts: %i[turbo explicit_broadcasts],
      stream_subscriptions: %i[turbo stream_subscriptions],
      jobs: %i[jobs jobs],
      channels: %i[jobs channels],
      mailers: %i[jobs mailers],
      available_locales: %i[i18n available_locales],
      storage_attachments: %i[active_storage attachments],
      rich_text_fields: %i[action_text rich_text_fields],
      notable_gems: %i[gems notable_gems],
      stimulus_controllers: %i[stimulus controllers],
      architecture: %i[conventions architecture],
      patterns: %i[conventions patterns],
      pending_migrations: %i[migrations pending]
    }.freeze

    # Rails' own frameworks that keep a database of their own: a Rails 8 app
    # gets one each for Solid Queue, Solid Cache and Solid Cable.
    FRAMEWORK_DATABASE_GEMS = %w[solid_queue solid_cache solid_cable].freeze

    module_function

    # The section, or nil when it is absent, failed, or refused - one guard
    # instead of the hand-rolled `x.is_a?(Hash) && !x[:error]` at every call
    # site.
    def section(ctx, key)
      value = ctx.is_a?(Hash) ? ctx[key] : nil
      value.is_a?(Hash) && !value[:error] && !value[:unavailable] ? value : nil
    end

    def list(ctx, section_key, key)
      Array(section(ctx, section_key)&.dig(key))
    end

    LISTS.each do |name, (section_key, key)|
      define_singleton_method(name) { |ctx| list(ctx, section_key, key) }
    end

    def controllers(ctx)
      section(ctx, :controllers)&.dig(:controllers).then { |h| h.is_a?(Hash) ? h : {} }
    end

    # The app's own controllers: the framework ones the configuration names
    # are dropped here so every listing counts the same set. A lookup by name
    # still searches everything, so this is a reader, not an introspector rule.
    def app_controllers(ctx)
      excluded = RailsAiContext.configuration.excluded_controllers
      controllers(ctx).reject { |name, _| excluded.include?(name) }
    end

    # Counted from the model scan's files, since an engine's .rb files overcount. Nil,
    # not 0, when the models section failed or never ran.
    def in_repo_engines_with_models(ctx)
      section = ctx.is_a?(Hash) ? ctx[:models] : nil
      known = section.is_a?(Hash) && !section[:error] && !section[:unavailable]
      files = known ? section.values.filter_map { |data| data[:file] if data.is_a?(Hash) } : []
      in_repo_engines(ctx).map do |engine|
        prefix = "#{engine[:path]}/"
        engine.merge(model_count: known ? files.count { |file| file.to_s.start_with?(prefix) } : nil)
      end
    end

    def engine_model_phrase(engine)
      count = engine[:model_count]
      count.nil? ? " - model count unavailable" : " - #{CountPhrase.call(count, 'model')}"
    end

    # Every table the schema section holds, as [database, name, data]: the primary's
    # (database nil) first, then each secondary dump's.
    def schema_tables(schema)
      return [] unless schema.is_a?(Hash)

      primary = (schema[:tables].is_a?(Hash) ? schema[:tables] : {}).map { |name, data| [ nil, name, data ] }
      secondary = secondary_databases(schema).flat_map do |db, info|
        info[:tables].map { |name, data| [ db.to_s, name, data ] }
      end
      primary + secondary
    end

    # Each database past the primary that the schema section read tables
    # for, by its database.yml name.
    def secondary_databases(schema)
      found = schema.is_a?(Hash) ? schema[:secondary_databases] : nil
      return {} unless found.is_a?(Hash)

      found.select { |_, info| info.is_a?(Hash) && info[:tables].is_a?(Hash) }
    end

    # The secondary databases that hold tables of the app's own.
    def app_databases(schema)
      secondary_databases(schema).reject { |_, info| database_framework(info) }
    end

    # Those whose every table a Rails framework owns.
    def framework_databases(schema)
      secondary_databases(schema).select { |_, info| database_framework(info) }
    end

    # The frameworks owning every table of a database, by name ("Solid
    # Queue"), or nil when any table is the app's own. Their tables are the
    # framework's schema, so a context file names the database and leaves
    # the tables to the tools. The names are the ones rails_get_schema
    # knows those gems' tables by.
    def database_framework(info)
      tables = info.is_a?(Hash) && info[:tables].is_a?(Hash) ? info[:tables].keys.map(&:to_s) : []
      return nil if tables.empty?

      owners = tables.map do |table|
        FRAMEWORK_DATABASE_GEMS.find { |gem| table.match?(Tools::GetSchema::GEM_TABLES.fetch(gem)) }
      end
      return nil if owners.include?(nil)

      (FRAMEWORK_DATABASE_GEMS & owners).map { |gem| gem.split("_").map(&:capitalize).join(" ") }.join(" and ")
    end

    # A name in two databases answers `database`'s when given, else the primary's.
    def schema_table(schema, name, database: nil)
      found = table_holders(schema, name)
      (found.find { |db, _, _| database && db == database.to_s } || found.first)&.[](2)
    end

    # The table a model reads, from the database its `connects_to` writes to.
    def model_table(schema, model)
      model_tables(schema, model).first&.last
    end

    # [database, table] for each database a model may read its table from: the one it writes
    # to, or the primary without connects_to, when that holds the table; every holder otherwise (shards).
    def model_tables(schema, model)
      return [] unless model.is_a?(Hash) && model[:table_name]

      found = table_holders(schema, model[:table_name]).map { |db, _, data| [ db || "primary", data ] }
      writing = model.dig(:database, :writing)&.to_s || ("primary" unless model[:database])
      written = found.select { |db, _| db == writing }.first(1)
      written.any? ? written : found
    end

    def model_databases(schema, model)
      model_tables(schema, model).map(&:first)
    end

    # Every database whose schema holds the table, "primary" for the primary's.
    def schema_databases(schema, name)
      table_holders(schema, name).map { |db, _, _| db || "primary" }
    end

    # A schema-qualified name the listing does not hold is looked up when asked for: a table outside
    # the search path, or a listed one by its qualified name, as Rails resolves both.
    def table_holders(schema, name)
      found = schema_tables(schema).select { |_, table, _| table.to_s == name.to_s }
      return found if found.any? || !name.to_s.include?(".") || !schema.is_a?(Hash)

      secondary = schema[:secondary_databases].is_a?(Hash) ? schema[:secondary_databases].keys : []
      [ nil, *secondary ].filter_map do |db|
        live = db.nil? && !parsed_schema?(schema) && schema[:adapter].to_s.match?(/postg/i)
        shown, data = Introspectors::SchemaIntrospector.qualified_table(name.to_s, database: db&.to_s, live: live)
        # The fourth entry is the name the listing shows the table under, which its models read.
        [ db&.to_s, name.to_s, data, shown ] if data
      end
    end

    # Why the primary's dump leaves out a schema-qualified table, or nil.
    def missing_qualified_table(schema, name)
      return unless schema.is_a?(Hash) && parsed_schema?(schema) && name.to_s.include?(".")

      Introspectors::SchemaIntrospector.qualified_table_note(name.to_s)
    end

    # Read from the dump: the context names the adapter and keeps "static_parse" under adapter_source.
    def parsed_schema?(schema)
      [ schema[:adapter], schema[:adapter_source] ].include?("static_parse")
    end

    def models(ctx)
      value = ctx.is_a?(Hash) ? ctx[:models] : nil
      value.is_a?(Hash) && !value[:error] ? value : {}
    end

    # Every "key models" list orders here, or two disagree when counts tie. A
    # model ranks by the associations it adds to its listed parent.
    # ponytail: a child redeclaring a parent's association counts as adding none.
    def models_by_connection(models)
      models.keys.sort_by do |name|
        data = models[name]
        next [ 0, 0, name.to_s ] unless data.is_a?(Hash)

        parent = models[data[:parent_model]]
        inherited = parent.is_a?(Hash) ? Array(parent[:associations]).size : 0
        own = [ Array(data[:associations]).size - inherited, 0 ].max
        [ -own, parent.is_a?(Hash) ? 1 : 0, name.to_s ]
      end
    end

    # Answers only for gems in GemIntrospector::NOTABLE_GEMS - a gem missing
    # from that table reads as absent here however the app depends on it.
    def gem?(ctx, name)
      notable_gems(ctx).any? { |g| g.is_a?(Hash) && g[:name] == name.to_s }
    end

    # The file a controller was read from. Reconstructing it from the class
    # name breaks wherever the app registers an inflection, so the
    # introspector carries it - and one reader here means a rename of the key
    # fails loudly rather than sending every consumer back to guessing.
    def controller_file(ctx, name)
      section(ctx, :controllers)&.dig(:controllers, name.to_s)&.dig(:file)
    end

    # The file a model was read from. `models` is a bare Hash of name =>
    # details, not a section with its own wrapper.
    #
    # The derivation is the fallback for a model reflection found and no file
    # was recorded for, and it lives here so there is one of it.
    def model_file(ctx, name)
      models = ctx.is_a?(Hash) ? ctx[:models] : nil
      carried = models.dig(name.to_s, :file) if models.is_a?(Hash) && !models[:error]

      carried || "app/models/#{name.to_s.underscore}.rb"
    end

    # The file a job or mailer was read from, nil when the tier recorded
    # none: a job in a pack has no conventional path to fall back to.
    def job_file(ctx, name)
      jobs(ctx).find { |job| job.is_a?(Hash) && job[:name] == name.to_s }&.dig(:file)
    end

    # The model a file declares, as [name, data].
    #
    # Camelizing the path is the wrong way back: `oauth_client_config.rb` is
    # `OAuthClientConfig` wherever the app registers the acronym, and a checker
    # walking the models directory has only the path to start from.
    def model_for_file(ctx, file)
      models = ctx.is_a?(Hash) ? ctx[:models] : nil
      return nil unless models.is_a?(Hash) && !models[:error]

      wanted = file.to_s
      models.find { |_, data| data.is_a?(Hash) && data[:file].to_s == wanted }
    end

    # The controller Rails routes under a path, as [name, data].
    #
    # A view directory names the route key, not the constant: camelizing
    # `app/views/activitypub/` back gives `Activitypub`, and the controllers
    # hash is keyed by what the app declares.
    # Indexed, not scanned: the only caller runs per view file, and deriving
    # every controller's key again for each one is O(views x controllers).
    def controller_for_route_key(ctx, key)
      controllers = section(ctx, :controllers)&.dig(:controllers)
      return nil unless controllers.is_a?(Hash)

      # One slot holding the hash and the index built from it, read into a
      # local once and swapped as a single reference. Two threads serving two
      # contexts then cost at most a rebuild, never an index belonging to the
      # other one's controllers.
      memo = @route_key_memo
      unless memo && memo[0].equal?(controllers)
        memo = [ controllers, controllers.to_h { |name, _| [ controller_route_key(ctx, name), name ] } ].freeze
        @route_key_memo = memo
      end

      name = memo[1][key.to_s]
      name ? [ name, controllers[name] ] : nil
    end

    # The ivars a template reads, across every format that renders the same
    # action. Scraping them back out of GetView's rendered "ivars:" line made
    # the cross-check hostage to that line's wording, and it re-read files the
    # payload had already parsed.
    # `format:` keeps the template of one format: `format.json { render :show }`
    # renders show.json.jbuilder, not show.html.erb.
    def view_ivars(ctx, template, format: nil)
      templates = section(ctx, :view_templates)&.dig(:templates)
      return Set.new unless templates.is_a?(Hash)

      wanted = template.to_s
      templates.each_with_object(Set.new) do |(path, entry), found|
        next unless entry.is_a?(Hash) && template_key(path) == wanted
        next if format && File.basename(path.to_s).split(".")[1] != format.to_s

        found.merge(Array(entry[:ivars]).map(&:to_s))
      end
    end

    # A template path without its format and handler suffixes:
    # "posts/create.turbo_stream.erb" is the "posts/create" action.
    def template_key(path)
      path.to_s.sub(%r{(?:\.[^./]+)+\z}, "")
    end

    # The key Rails routes a controller by: its path, minus the controllers
    # root and the _controller suffix. Packs and in-repo engines put that root
    # somewhere other than the start of the path.
    def controller_route_key(ctx, name)
      file = controller_file(ctx, name)
      return name.to_s.underscore.delete_suffix("_controller") unless file

      file.to_s.sub(%r{\A.*app/controllers/}, "").sub(/(?:_controller)?\.rb\z/, "")
    end

    # Case-insensitive fuzzy key lookup for hashes keyed by class or table
    # names. Tries exact, underscore, singularize and classify variants.
    def fuzzy_find_key(keys, query)
      return nil if query.nil? || keys.nil? || keys.empty?
      q = query.to_s.strip
      return nil if q.empty?
      q_down = q.downcase
      q_under = q.underscore.downcase

      keys.find { |k| k.to_s.downcase == q_down } ||
        keys.find { |k| k.to_s.underscore.downcase == q_under } ||
        keys.find { |k| k.to_s.downcase == q.singularize.downcase } ||
        keys.find { |k| k.to_s.downcase == q.classify.downcase }
    end

    # The controller a name means: "posts", "PostsController", "admin/posts",
    # "Admin::PostsController", and a route key whose declared constant does
    # not camelize from it. One rule in one place, so the resource and the
    # tool cannot answer the same name differently.
    def find_controller(ctx, input)
      keys = controllers(ctx).keys
      by_route = controller_for_route_key(ctx, input.to_s.delete_suffix("_controller"))
      return by_route.first if by_route

      fuzzy_find_key(keys, input) ||
        fuzzy_find_key(keys, "#{input}Controller") ||
        fuzzy_find_key(keys, "#{input.to_s.camelize}Controller") ||
        short_name_match(ctx, keys, input)
    end

    # A controller name as a route key spells it. Underscored, not downcased:
    # a route key is snake_case, so "GiftCards" has to become "gift_cards" to
    # equal one, and downcasing alone gives "giftcards", which equals nothing.
    # Every surface that matches a caller's string against a route key reads
    # this, so they cannot disagree about what the string means.
    def route_needle(input)
      input.to_s.tr("-", "_").underscore.delete_suffix("_controller")
    end

    # `gift_cards` is the name a person types and the one the routes resource
    # already answers to. It camelizes to nothing the payload carries, because
    # the class is namespaced. Only an unambiguous match answers: two
    # controllers of the same basename are a question, not a resolution.
    def short_name_match(ctx, keys, input)
      needle = route_needle(input)
      return nil if needle.empty? || needle.include?("/") || needle.include?("::")

      matches = keys.select do |key|
        controller_route_key(ctx, key).to_s.split("/").last == needle ||
          key.to_s.split("::").last.underscore.delete_suffix("_controller") == needle
      end
      matches.first if matches.size == 1
    end
  end
end
