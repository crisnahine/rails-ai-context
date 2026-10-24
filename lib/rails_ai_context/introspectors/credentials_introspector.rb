# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Inspects Rails credentials configuration WITHOUT revealing any
    # decrypted value. Returns file presence, master-key source (file vs
    # env), per-environment encrypted files, and top-level key names.
    # Covers RAILS_NERVOUS_SYSTEM.md §30 (Credentials, Secrets, Encrypted
    # files).
    #
    # Safety contract:
    # - Values are NEVER returned. Top-level keys are listed only when the
    #   credentials decrypt successfully; the values behind each key stay
    #   on the user's machine.
    # - Master-key contents are NEVER read. Only presence (file exists vs
    #   RAILS_MASTER_KEY set) is reported.
    class CredentialsIntrospector < Base
      extend StaticTier
      static_tier :files_only

      def call
        {
          default: inspect_default_credentials,
          environments: inspect_environment_credentials,
          master_key_source: detect_master_key_source,
          require_master_key: require_master_key_flag,
          encrypted_configs: detect_encrypted_configs
        }.merge(inspect_custom_credentials)
      rescue => e
        # Never echo `e.message` into the return hash - exception messages
        # from OS errors (EACCES, ENOENT) or OpenSSL decryption failures
        # can contain absolute paths with the OS username or partial
        # ciphertext. The stderr log is fine because it's debug-gated.
        RailsAiContext.debug_fail(e, { error: "credentials introspection failed", exception_class: e.class.name },
          label: "CredentialsIntrospector#call")
      end

      private

      def inspect_default_credentials
        file = File.join(root, "config/credentials.yml.enc")
        return { file: "config/credentials.yml.enc", present: false } unless File.exist?(file)

        entry = {
          file: "config/credentials.yml.enc",
          present: true,
          key_file: "config/master.key",
          key_file_present: File.exist?(File.join(root, "config/master.key"))
        }

        with_key_names(entry) { |read| read.nil? || same_file?(read, file) }
      rescue => e
        # Same rationale as `#call`: keep `e.message` in stderr, never in output.
        RailsAiContext.debug_fail(e, { file: "config/credentials.yml.enc", error: "inspection failed", exception_class: e.class.name },
          label: "inspect_default_credentials")
      end

      def inspect_environment_credentials
        dir = File.join(root, "config/credentials")
        return [] unless Dir.exist?(dir)

        PathResolver.glob(dir, "*.yml.enc").sort.map do |enc|
          env = File.basename(enc, ".yml.enc")
          key = File.join(dir, "#{env}.key")
          entry = {
            environment: env,
            file: enc.sub("#{root}/", ""),
            key_file: "config/credentials/#{env}.key",
            key_file_present: File.exist?(key)
          }
          with_key_names(entry) { |read| read && same_file?(read, enc) }
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "inspect_environment_credentials")
      end

      # `config.credentials.content_path` set to a file that is neither of the standard ones.
      def inspect_custom_credentials
        read = rails_credentials_path(:content_path)
        standard = [ File.join(root, "config/credentials.yml.enc"), *PathResolver.glob(File.join(root, "config/credentials"), "*.yml.enc") ]
        return {} if read.nil? || standard.any? { |file| same_file?(read, file) }

        key = rails_credentials_path(:key_path)
        entry = { file: app_relative(read), present: File.exist?(read) }
        entry.merge!(key_file: app_relative(key), key_file_present: File.exist?(key)) if key
        { custom: with_key_names(entry) { entry[:present] } }
      rescue => e
        RailsAiContext.debug_fail(e, { custom: { error: "inspection failed", exception_class: e.class.name } }, label: "inspect_custom_credentials")
      end

      # The entry, with the decrypted key names when the block, given the path Rails reads, says it is that file.
      def with_key_names(entry)
        names = attempt_top_level_keys(credentials) if yield(rails_credentials_path(:content_path))
        entry[:top_level_keys] = names if names
        entry
      end

      # Which source Rails uses to obtain the master key. Important because
      # ops teams often rely on RAILS_MASTER_KEY over key files on disk.
      def detect_master_key_source
        key_path = rails_credentials_path(:key_path) || declared_key_path
        if ENV["RAILS_MASTER_KEY"] && !ENV["RAILS_MASTER_KEY"].empty?
          "env:RAILS_MASTER_KEY"
        else
          File.exist?(key_path) ? "file:#{app_relative(key_path)}" : "missing"
        end
      end

      # Rails reads a symlinked content_path at its realpath.
      def same_file?(path, other)
        SafePath.canonical(path) == SafePath.canonical(other)
      end

      OUTSIDE_APP = "(outside the app root)"

      # A path outside the app names the machine it is on, so it is never printed.
      def app_relative(path)
        spelled = File.expand_path(path)
        return PortablePath.relativize(spelled, root) if spelled.start_with?(SafePath.dir_prefix(root))

        real = SafePath.canonical(path)
        real_root = SafePath.canonical(root)
        SafePath.contained?(real, real_root) ? PortablePath.relativize(real, real_root) : OUTSIDE_APP
      end

      # The path Rails itself chose: config/credentials/<env>.yml.enc
      # wins over config/credentials.yml.enc, and the key path follows its own rule per version.
      def rails_credentials_path(name)
        creds = credentials
        creds.public_send(name).to_s if creds.respond_to?(name)
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "rails_credentials_path")
      end

      # Rails 7.0 takes <env>.key whenever <env>.yml.enc exists; 7.1+ only when the key file exists.
      def declared_key_path
        env = RailsAiContext.environment_name
        env_key = File.join(root, "config/credentials/#{env}.key")
        version = GemLock.for(root).rails_version
        rails70 = version && Gem::Version.new(version) < Gem::Version.new("7.1")
        File.exist?(rails70 ? File.join(root, "config/credentials/#{env}.yml.enc") : env_key) ? env_key : File.join(root, "config/master.key")
      end

      # A static run has no credentials object: nothing is decrypted without a boot.
      def credentials
        app.credentials if app.respond_to?(:credentials)
      end

      def require_master_key_flag
        return declared_require_master_key unless app.respond_to?(:config)

        !!(app.config.require_master_key if app.config.respond_to?(:require_master_key))
      rescue StandardError => e
        RailsAiContext.debug_fail(e, Confidence.unavailable("the app's config could not be read"), label: "require_master_key_flag")
      end

      # The last assignment in the order Rails runs the files, when it is an unconditional true or false;
      # Rails' default, false, when no call in the files names it.
      def declared_require_master_key
        files = [ File.join(root, "config/application.rb"),
                  File.join(root, "config/environments/#{RailsAiContext.environment_name}.rb"),
                  *PathResolver.initializer_paths(root) ].select { |path| File.file?(path) && !PathResolver.linked_out?(path, root) }
        seen = Set.new
        items = files.flat_map { |path| declared_settings(path, seen) }
        last = items.reject { |item| item == :mention }.last
        return false if last.nil? && !items.include?(:mention)
        return last[:value] if last.is_a?(Hash) && last[:condition].nil? && [ true, false ].include?(last[:value])

        Confidence.unavailable(StaticTier.unavailable_reason)
      end

      LOADS = %i[require require_relative load].freeze
      SETTING = %i[require_master_key require_master_key=].freeze
      SENDS = %i[send public_send __send__].freeze

      # The file's require_master_key assignments in run order, with each config/ file it
      # require_relatives spliced in where it runs; :unknown for a load it cannot follow or a
      # file it cannot read, and :mention when a call, or a send's method name, names the setting.
      def declared_settings(path, seen)
        return [] unless seen.add?(path)

        parse = AstCache.parse(path)
        walked = SourceIntrospector.walk_dispatch(parse, config: Listeners::ConfigAssignmentListener,
                                                         loads: -> { Listeners::MethodCallListener.new(names: LOADS) },
                                                         mentions: -> { Listeners::MethodCallListener.new(names: SETTING + SENDS) })
        settings = walked[:config].select { |entry| entry[:assignment] && entry[:path] == [ :require_master_key ] }.map { |entry| [ entry[:location], [ entry ] ] }
        loads = walked[:loads].select { |call| call[:receiver].nil? }.map { |call| [ call[:line], loaded_settings(call, path, seen) ] }
        items = (settings + loads).sort_by(&:first).flat_map(&:last)
        mentioned = walked[:mentions].any? { |call| SETTING.include?(call[:name].to_sym) || SETTING.include?(call[:arguments].first.to_s.to_sym) }
        mentioned ? [ :mention, *items ] : items
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [ :unknown ], label: "declared_settings")
      end

      # A gem's `require "x"` sets no app config.
      def loaded_settings(call, path, seen)
        feature = call[:arguments].first
        return [ :unknown ] unless call[:computed].empty? && feature.is_a?(String)
        return [] if call[:name] == "require" && !feature.start_with?(".", "/")
        return [ :unknown ] unless call[:name] == "require_relative"

        target = File.expand_path(feature.end_with?(".rb") ? feature : "#{feature}.rb", File.dirname(path))
        return [ :unknown ] unless target.start_with?(SafePath.dir_prefix(File.join(root, "config"))) && File.file?(target) && !PathResolver.linked_out?(target, root)

        declared_settings(target, seen)
      end

      # Rails 6.2+ supports arbitrary encrypted files via
      # `config/<name>.yml.enc` + `config/<name>.key`. Detect them.
      def detect_encrypted_configs
        config_dir = File.join(root, "config")
        return [] unless Dir.exist?(config_dir)

        PathResolver.glob(config_dir, "*.yml.enc").sort.filter_map do |enc|
          name = File.basename(enc, ".yml.enc")
          next if name == "credentials" # covered by `default`
          rel = enc.sub("#{root}/", "")
          key_file = File.join(config_dir, "#{name}.key")
          { name: name, file: rel, key_file_present: File.exist?(key_file) }
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_encrypted_configs")
      end

      # Try to enumerate top-level keys without revealing values. Returns
      # nil if decryption fails (no master key, invalid ciphertext, etc.).
      def attempt_top_level_keys(creds)
        return nil unless creds
        hash = creds.respond_to?(:config) ? creds.config : nil
        return nil unless hash.is_a?(Hash)
        hash.keys.map(&:to_s).sort
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "attempt_top_level_keys")
      end
    end
  end
end
