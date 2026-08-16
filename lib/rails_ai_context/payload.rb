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

    # The key Rails routes a controller by: its path, minus the controllers
    # root and the _controller suffix. Packs and in-repo engines put that root
    # somewhere other than the start of the path.
    def controller_route_key(ctx, name)
      file = controller_file(ctx, name)
      return name.to_s.underscore.delete_suffix("_controller") unless file

      file.to_s.sub(%r{\A.*app/controllers/}, "").sub(/_controller\.rb\z/, "")
    end
  end
end
