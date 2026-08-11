# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::AppKind do
  it "detects Mongoid via config/mongoid.yml" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
      expect(described_class.mongoid?(dir)).to be(true)
    end
  end

  it "detects Mongoid via Gemfile.lock" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    mongoid (9.0.4)\n")
      expect(described_class.mongoid?(dir)).to be(true)
    end
  end

  it "is false for an ActiveRecord app" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    pg (1.5.6)\n")
      expect(described_class.mongoid?(dir)).to be(false)
    end
  end

  it "does not match gems whose name merely contains mongoid" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    mongoid_paranoia (1.0.0)\n")
      expect(described_class.mongoid?(dir)).to be(false)
    end
  end
  # config.api_only lives in config/application.rb, so the static tier can know
  # it. Without this, an API-only app was told "No Stimulus controllers found"
  # where a booted app says "Not applicable" - literally true, but it invites
  # an agent to add Stimulus to an app that has no view layer.
  describe ".api_only?" do
    def app_with(body, file: "config/application.rb")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
        File.write(File.join(dir, file), body)
        return described_class.api_only?(dir)
      end
    end

    it "reads config.api_only = true" do
      expect(app_with(<<~RUBY)).to be(true)
        module Dummy
          class Application < Rails::Application
            config.api_only = true
          end
        end
      RUBY
    end

    it "reads an explicit false as false" do
      expect(app_with(<<~RUBY)).to be(false)
        module Dummy
          class Application < Rails::Application
            config.api_only = false
          end
        end
      RUBY
    end

    it "ignores a commented-out assignment" do
      expect(app_with(<<~RUBY)).to be(false)
        module Dummy
          class Application < Rails::Application
            # config.api_only = true
          end
        end
      RUBY
    end

    it "is false when application.rb says nothing about it" do
      expect(app_with(<<~RUBY)).to be(false)
        module Dummy
          class Application < Rails::Application
          end
        end
      RUBY
    end

    it "is false when there is no application.rb at all" do
      Dir.mktmpdir { |dir| expect(described_class.api_only?(dir)).to be(false) }
    end
  end
end
