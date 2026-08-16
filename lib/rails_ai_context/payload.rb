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
      rails_engines: %i[engines rails_engines],
      turbo_frames: %i[turbo turbo_frames],
      turbo_streams: %i[turbo turbo_streams],
      model_broadcasts: %i[turbo model_broadcasts],
      jobs: %i[jobs jobs],
      channels: %i[jobs channels],
      mailers: %i[jobs mailers],
      available_locales: %i[i18n available_locales],
      storage_attachments: %i[active_storage attachments],
      rich_text_fields: %i[action_text rich_text_fields],
      databases: %i[multi_database databases]
    }.freeze

    module_function

    # The section, or nil when it is absent or failed - one guard instead of
    # the hand-rolled `x.is_a?(Hash) && !x[:error]` at every call site.
    def section(ctx, key)
      value = ctx.is_a?(Hash) ? ctx[key] : nil
      value.is_a?(Hash) && !value[:error] ? value : nil
    end

    def list(ctx, section_key, key)
      Array(section(ctx, section_key)&.dig(key))
    end

    LISTS.each do |name, (section_key, key)|
      define_singleton_method(name) { |ctx| list(ctx, section_key, key) }
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

      # One slot, holding the hash it indexed: keeping the reference is what
      # makes identity safe to compare on, and it drops as soon as the next
      # context arrives.
      unless @indexed_controllers.equal?(controllers)
        @route_key_index = controllers.to_h { |name, _| [ controller_route_key(ctx, name), name ] }
        @indexed_controllers = controllers
      end

      name = @route_key_index[key.to_s]
      name ? [ name, controllers[name] ] : nil
    end

    # The key Rails routes a controller by: its path, minus the controllers
    # root and the _controller suffix. Packs and in-repo engines put that root
    # somewhere other than the start of the path.
    def controller_route_key(ctx, name)
      file = controller_file(ctx, name)
      return name.to_s.underscore.delete_suffix("_controller") unless file

      file.to_s.sub(%r{\A.*app/controllers/}, "").sub(/(?:_controller)?\.rb\z/, "")
    end
  end
end
