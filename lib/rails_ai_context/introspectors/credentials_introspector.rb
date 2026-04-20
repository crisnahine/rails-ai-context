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
    class CredentialsIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          default: inspect_default_credentials,
          environments: inspect_environment_credentials,
          master_key_source: detect_master_key_source,
          require_master_key: !!require_master_key_flag,
          encrypted_configs: detect_encrypted_configs
        }
      rescue => e
        # Never echo `e.message` into the return hash — exception messages
        # from OS errors (EACCES, ENOENT) or OpenSSL decryption failures
        # can contain absolute paths with the OS username or partial
        # ciphertext. The stderr log is fine because it's debug-gated.
        $stderr.puts "[rails-ai-context] CredentialsIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: "credentials introspection failed", exception_class: e.class.name }
      end

      private

      def root
        app.root.to_s
      end

      def inspect_default_credentials
        file = File.join(root, "config/credentials.yml.enc")
        return { file: "config/credentials.yml.enc", present: false } unless File.exist?(file)

        entry = {
          file: "config/credentials.yml.enc",
          present: true,
          key_file: "config/master.key",
          key_file_present: File.exist?(File.join(root, "config/master.key"))
        }

        names = attempt_top_level_keys(app.credentials)
        entry[:top_level_keys] = names if names
        entry
      rescue => e
        # Same rationale as `#call`: keep `e.message` in stderr, never in output.
        $stderr.puts "[rails-ai-context] inspect_default_credentials failed: #{e.message}" if ENV["DEBUG"]
        { file: "config/credentials.yml.enc", error: "inspection failed", exception_class: e.class.name }
      end

      def inspect_environment_credentials
        dir = File.join(root, "config/credentials")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*.yml.enc")).sort.map do |enc|
          env = File.basename(enc, ".yml.enc")
          key = File.join(dir, "#{env}.key")
          entry = {
            environment: env,
            file: enc.sub("#{root}/", ""),
            key_file: "config/credentials/#{env}.key",
            key_file_present: File.exist?(key)
          }
          entry
        end
      rescue => e
        $stderr.puts "[rails-ai-context] inspect_environment_credentials failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Which source Rails uses to obtain the master key. Important because
      # ops teams often rely on RAILS_MASTER_KEY over key files on disk.
      def detect_master_key_source
        master_key_file = File.join(root, "config/master.key")
        if ENV["RAILS_MASTER_KEY"] && !ENV["RAILS_MASTER_KEY"].empty?
          "env:RAILS_MASTER_KEY"
        elsif File.exist?(master_key_file)
          "file:config/master.key"
        else
          "missing"
        end
      end

      def require_master_key_flag
        app.config.respond_to?(:require_master_key) ? app.config.require_master_key : nil
      rescue StandardError
        nil
      end

      # Rails 6.2+ supports arbitrary encrypted files via
      # `config/<name>.yml.enc` + `config/<name>.key`. Detect them.
      def detect_encrypted_configs
        config_dir = File.join(root, "config")
        return [] unless Dir.exist?(config_dir)

        Dir.glob(File.join(config_dir, "*.yml.enc")).sort.filter_map do |enc|
          name = File.basename(enc, ".yml.enc")
          next if name == "credentials" # covered by `default`
          rel = enc.sub("#{root}/", "")
          key_file = File.join(config_dir, "#{name}.key")
          { name: name, file: rel, key_file_present: File.exist?(key_file) }
        end
      rescue => e
        $stderr.puts "[rails-ai-context] detect_encrypted_configs failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Try to enumerate top-level keys without revealing values. Returns
      # nil if decryption fails (no master key, invalid ciphertext, etc.).
      def attempt_top_level_keys(creds)
        return nil unless creds
        hash = creds.respond_to?(:config) ? creds.config : nil
        return nil unless hash.is_a?(Hash)
        hash.keys.map(&:to_s).sort
      rescue StandardError => e
        $stderr.puts "[rails-ai-context] attempt_top_level_keys failed: #{e.message}" if ENV["DEBUG"]
        nil
      end
    end
  end
end
