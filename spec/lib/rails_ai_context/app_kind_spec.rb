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

  it "detects Mongoid when it is a git gem" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GIT\n  remote: https://github.com/mongodb/mongoid.git\n  specs:\n    mongoid (9.0.4)\n")
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

    # The reason docs/INTROSPECTORS.md puts assignments in AST territory: a
    # regex has to hand-roll what the parser already knows. A string that
    # merely contains the assignment is not one.
    it "is not fooled by the text appearing inside a string" do
      expect(app_with(<<~'RUBY')).to be(false)
        module Dummy
          class Application < Rails::Application
            BANNER = "set config.api_only = true to go headless"
          end
        end
      RUBY
    end

    it "is false when there is no application.rb at all" do
      Dir.mktmpdir { |dir| expect(described_class.api_only?(dir)).to be(false) }
    end
  end

  describe ".active_record?" do
    def app_with(application_rb)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"), application_rb) if application_rb
        yield dir
      end
    end

    it "is false when application.rb leaves the railtie commented out" do
      app_with("require \"rails\"\nrequire \"active_model/railtie\"\n# require \"active_record/railtie\"\nrequire \"action_controller/railtie\"\n") { |dir| expect(described_class.active_record?(dir)).to be(false) }
    end

    it "is true for rails/all, the railtie, or a list of railties it requires in a loop" do
      app_with("require \"rails/all\"\n") { |dir| expect(described_class.active_record?(dir)).to be(true) }
      app_with("%w[active_record/railtie action_controller/railtie].each { |r| require r }\n") { |dir| expect(described_class.active_record?(dir)).to be(true) }
    end

    it "is true when there is no application.rb to read, or it does not parse" do
      app_with(nil) { |dir| expect(described_class.active_record?(dir)).to be(true) }
      app_with("\xff\xfe class (") { |dir| expect(described_class.active_record?(dir)).to be(true) }
    end
  end

  describe ".sequel_schema" do
    def sequel_app(schema)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    sequel (5.80.0)\n")
        File.write(File.join(dir, "db", "schema.rb"), schema)
        return described_class.sequel_schema(dir)
      end
    end

    it "reads Sequel's DSL by the call, behind a block comment or a top-level constant" do
      expect(sequel_app("=begin\ndumped\n=end\n::Sequel.migration do\n  change do\n  end\nend\n")).to eq("db/schema.rb is a Sequel migration")
    end

    it "is nil for an Active Record schema that only mentions Sequel.migration" do
      expect(sequel_app("# Sequel.migration was here\nActiveRecord::Schema[7.1].define(version: 1) do\nend\n")).to be_nil
    end
  end
end
