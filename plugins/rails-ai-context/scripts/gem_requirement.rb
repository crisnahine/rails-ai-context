# frozen_string_literal: true

# The first release with everything both scripts call and every tool and parameter rules.md names; a release that
# changes either, or what its doctor says about the plugin, raises it.
module RailsAiContextPlugin
  GEM_REQUIREMENT = ">= 5.36.9"

  # Whether the activated gem has this file, which tells a release that has a feature from one before it.
  def self.gem_has?(feature)
    !$LOAD_PATH.resolve_feature_path(feature).nil?
  rescue LoadError
    false
  end

  # The gem whose serve refuses by handshake is the one that serves a folder of apps itself.
  def self.routes?
    gem_has?("rails_ai_context/cli/refusal")
  end
end
