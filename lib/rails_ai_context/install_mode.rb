# frozen_string_literal: true

require_relative "safe_file"

module RailsAiContext
  # Detects how the gem is installed into the current app so user-facing copy
  # can advertise invocation forms that actually exist.
  #
  # A standalone install runs the gem via its own CLI binary (`gem install
  # rails-ai-context` + `rails-ai-context init`) rather than through the host
  # app's Bundler group, so none of the rake tasks this gem ships (`rails
  # ai:*`) are available - only the `rails-ai-context` binary works. Detected
  # by scanning the resolved Gemfile.lock for a rails-ai-context spec line.
  # Falls back to treating the install as in-Gemfile (the common case) when
  # the lock file can't be read.
  module InstallMode
    module_function

    def standalone?
      root = if defined?(Bundler)
        Bundler.root.to_s
      elsif defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s
      else
        Dir.pwd
      end

      # Explicit size cap: SafeFile's default limit comes from the gem
      # configuration, which is not loaded yet when the standalone CLI detects
      # install mode before booting the app. Lock files are small; 5 MB is
      # generous headroom.
      content = RailsAiContext::SafeFile.read(File.join(root, "Gemfile.lock"), max_size: 5 * 1024 * 1024)
      content ? !content.include?("rails-ai-context (") : false
    rescue => e
      $stderr.puts "[rails-ai-context] standalone install detection failed: #{e.message}" if ENV["DEBUG"]
      false
    end
  end
end
