# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The app's Rails version, which picks the rules the static tier answers by.
    module RailsVersion
      module_function

      # The running Rails when booted, else the lockfile's; nil when neither says.
      def of(root)
        return Rails.version if defined?(Rails) && Rails.respond_to?(:version) && !RailsAiContext.static_tier?

        GemLock.for(root).rails_version
      end

      # An unknown version takes the newest rules.
      def at_least?(version, release)
        version.nil? || Gem::Version.new(version) >= Gem::Version.new(release)
      end
    end
  end
end
