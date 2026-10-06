# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe RailsAiContext::Tools::BaseTool do
  describe ".cached_context" do
    let(:cache) { described_class::SHARED_CACHE }

    before do
      described_class.reset_cache!
      cache[:context] = { models: { "User" => { table_name: "users" } } }
      cache[:timestamp] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    after { described_class.reset_cache! }

    it "copies the context once per tool call, however many helpers read it" do
      first, second = RailsAiContext::RunCache.around { [ described_class.cached_context, described_class.cached_context ] }

      expect(first).to equal(second)
      expect(first).not_to equal(cache[:context])
      expect(RailsAiContext::RunCache.around { described_class.cached_context }).not_to equal(first)
    end

    it "copies it on every read outside a tool call" do
      expect(described_class.cached_context).not_to equal(described_class.cached_context)
    end

    it "rereads the app's Active Record settings when a stale fingerprint rebuilds the context" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "config"))
        application = File.join(root, "config", "application.rb")
        File.write(application, "module App\n  class Application < Rails::Application\n  end\nend\n")
        settings = -> { RailsAiContext::Introspectors::TableName.active_record_settings(root)[:schema_format] }
        expect(settings.call).to be_nil

        File.write(application, "module App\n  class Application < Rails::Application\n    config.active_record.schema_format = :sql\n  end\nend\n")
        cache[:timestamp] -= RailsAiContext.configuration.cache_ttl + 1
        allow(RailsAiContext::Fingerprinter).to receive_messages(stale?: true, mark: "mark")
        allow(RailsAiContext).to receive(:introspect) { { schema_format: settings.call } }

        expect(described_class.cached_context[:schema_format]).to eq(:sql)
      ensure
        RailsAiContext::Introspectors::TableName.clear_namespace_prefixes
      end
    end
  end

  describe ".abstract?" do
    it "is abstract (excluded from registry)" do
      expect(described_class).to be_abstract
    end
  end

  # A first-three-characters prefix scan answered
  # `Api::V1::Admin::UserController` with `Api::V1::AddressesController`,
  # because both start with "api". Ruby's own spell checker knows what a typo
  # looks like.
  describe ".find_closest_matches" do
    def suggest(input, available)
      described_class.send(:find_closest_matches, input, available)
    end

    it "suggests the nearest name, not one sharing three characters" do
      available = %w[Api::V1::AddressesController Api::V1::Admin::UsersController]

      expect(suggest("Api::V1::Admin::UserController", available).first)
        .to eq("Api::V1::Admin::UsersController")
    end

    it "suggests a name with a letter missing" do
      expect(suggest("Lsting", %w[Listing Payment User])).to eq(%w[Listing])
    end

    it "suggests over the last segment when the namespace is wrong" do
      expect(suggest("Billing::Invoice", %w[Admin::Invoice User]).first).to eq("Admin::Invoice")
    end

    it "suggests the app's own locale for a one-letter query" do
      expect(suggest("e", %w[en])).to eq(%w[en])
      expect(suggest("e", %w[en de fr])).to eq(%w[en])
    end

    it "still suggests the whole name an abbreviation stands for" do
      expect(suggest("prod", %w[development production staging])).to eq(%w[production])
      expect(suggest("en-GB", %w[en fr])).to eq(%w[en])
    end

    it "suggests nothing for a name nothing resembles" do
      expect(suggest("zzqqxx", %w[Listing Payment])).to eq([])
    end

    it "answers the exact match rather than a suggestion" do
      expect(suggest("Listing", %w[Listing ListingItem])).to eq(%w[Listing])
    end
  end

  describe ".registered_tools" do
    it "returns all 45 built-in tool classes" do
      tools = described_class.registered_tools
      expect(tools.size).to eq(45)
    end

    # Registration order is reversed here so the sort has something to undo.
    it "lists the tools in tool_name order whatever order they registered in" do
      registered = described_class.registered_tools
      allow(described_class).to receive(:descendants).and_return(registered.reverse)

      names = described_class.registered_tools.map(&:tool_name)

      expect(names).to eq(registered.map(&:tool_name).sort)
      expect(names.size).to eq(45)
    end

    it "sorts past a tool that has no name yet" do
      registered = described_class.registered_tools
      nameless = double("tool", tool_name: nil, abstract?: false)
      allow(described_class).to receive(:descendants).and_return(registered + [ nameless ])

      expect(described_class.registered_tools.first).to be(nameless)
    end

    it "excludes BaseTool itself" do
      expect(described_class.registered_tools).not_to include(described_class)
    end

    it "returns only MCP::Tool subclasses" do
      described_class.registered_tools.each do |tool|
        expect(tool).to be < MCP::Tool
      end
    end

    it "includes core tools" do
      tools = described_class.registered_tools
      expect(tools).to include(RailsAiContext::Tools::GetSchema)
      expect(tools).to include(RailsAiContext::Tools::GetRoutes)
      expect(tools).to include(RailsAiContext::Tools::Query)
    end

    it "does not include abstract tools" do
      described_class.registered_tools.each do |tool|
        expect(tool).not_to be_abstract
      end
    end
  end

  describe ".descendants" do
    before { described_class.registered_tools }

    it "tracks all subclasses" do
      expect(described_class.descendants).to be_an(Array)
      expect(described_class.descendants.size).to eq(45)
    end
  end

  describe "Server.builtin_tools integration" do
    it "returns the same tools as registered_tools" do
      expect(RailsAiContext::Server.builtin_tools).to eq(described_class.registered_tools)
    end
  end

  describe "const_missing backwards compatibility" do
    it "Server::TOOLS still works" do
      expect(RailsAiContext::Server::TOOLS).to be_an(Array)
      expect(RailsAiContext::Server::TOOLS.size).to eq(45)
    end
  end

  describe ".empty_response and .empty?" do
    it "marks an answer that found nothing without changing what the reader sees" do
      response = described_class.empty_response("No views found for posts.")
      expect(described_class.empty?(response)).to be true
      expect(response.content.first[:text]).to eq("No views found for posts.")
    end

    it "treats a not-found response as empty" do
      response = described_class.not_found_response("Model", "Nope", %w[Post])
      expect(described_class.empty?(response)).to be true
    end

    # The old test was a substring search on the prose, so a real answer
    # whose body mentioned "not found" was dropped by every composing tool.
    it "does not treat a real answer that mentions not found as empty" do
      response = described_class.text_response("## PostsController\n- rescue_from ActiveRecord::RecordNotFound")
      expect(described_class.empty?(response)).to be false
    end

    # The mark rides in _meta, so nothing about the rendered answer changes.
    it "renders the text it was given, byte for byte" do
      response = described_class.empty_response("x")
      expect(described_class.response_text(response)).to eq("x")
      expect(response.to_h[:content]).to eq([ { type: "text", text: "x" } ])
    end
  end

  describe ".paginate" do
    it "keeps the plain hint when the caller names no unit" do
      hint = described_class.paginate((1..10).to_a, offset: 0, limit: 3)[:hint]

      expect(hint).to eq("_Showing 1-3 of 10. Use offset:3 for next page._")
    end

    it "names the unit and marks a total that was cut short" do
      hint = described_class.paginate((1..10).to_a, offset: 0, limit: 3, noun: "line", truncated: true)[:hint]

      expect(hint).to eq("_Showing 1-3 of 10+ lines. Use offset:3 for next page._")
    end
  end

  describe ".leading_boundary and .trailing_boundary" do
    it "adds a boundary only where the pattern edge is a word character" do
      expect(described_class.leading_boundary("user")).to eq("\\b")
      expect(described_class.leading_boundary("@user")).to eq("")
      expect(described_class.trailing_boundary("user")).to eq("\\b")
      expect(described_class.trailing_boundary("reblog?")).to eq("")
    end
  end

  describe ".extract_method_source_from_string" do
    let(:source) do
      <<~RB
        class Store
          def [](key)
            @data[key]
          end

          def name=(value)
            @name = value
          end

          def save!
            true
          end
        end
      RB
    end

    it "finds a method whose name ends in a non-word character" do
      expect(described_class.extract_method_source_from_string(source, "[]")[:start_line]).to eq(2)
      expect(described_class.extract_method_source_from_string(source, "name=")[:start_line]).to eq(6)
      expect(described_class.extract_method_source_from_string(source, "save!")[:start_line]).to eq(10)
    end

    it "answers the file's own class before a nested class that defines the name first" do
      source = <<~RB
        class Order
          class Line
            def normalize
              :line
            end
          end

          def normalize
            :order
          end

          module ClassMethods
            def build
              new
            end
          end
        end
      RB

      expect(described_class.extract_method_source_from_string(source, "normalize")[:start_line]).to eq(8)
      expect(described_class.extract_method_source_from_string(source, "build")[:start_line]).to eq(13)
    end

    it "does not answer a ?, ! or = method for the plain name declared after it" do
      source = <<~RB
        class Post
          def touch?
            true
          end

          def touch!
            nil
          end

          def touch=(value)
            nil
          end

          def touch
            update(at: 1)
          end
        end
      RB

      expect(described_class.extract_method_source_from_string(source, "touch")[:start_line]).to eq(14)
    end

    it "cuts a one-line or endless method at its own line" do
      source = <<~RB
        class User < ApplicationRecord
          before_validation :strip_name
          around_save :wrap_save
          private
          def strip_name; end
          def wrap_save = yield
          def self.build = new
          def other; end
        end
      RB

      expect(described_class.extract_method_source_from_string(source, "strip_name"))
        .to eq(code: "  def strip_name; end", start_line: 5, end_line: 5)
      expect(described_class.extract_method_source_from_string(source, "wrap_save"))
        .to eq(code: "  def wrap_save = yield", start_line: 6, end_line: 6)
      expect(described_class.extract_method_source_from_string(source, "self.build"))
        .to eq(code: "  def self.build = new", start_line: 7, end_line: 7)
    end
  end

  # The stub stands in for Rails 7.0's activesupport, left on the load path by a failed boot.
  describe "loading on an activesupport that does not require logger itself" do
    it "loads the tool classes, and any later full require of activesupport" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "active_support.rb"), <<~RUBY)
          Logger::Severity
          load File.join(Gem.loaded_specs["activesupport"].full_gem_path, "lib", "active_support.rb")
        RUBY
        lib = File.expand_path("../../../../lib", __dir__)
        script = 'require "rails_ai_context"; require "active_support"; RailsAiContext::Tools::BaseTool; print "loaded"'

        out, err, status = Open3.capture3(RbConfig.ruby, "-I", dir, "-I", lib, "-e", script)

        expect([ out, status.success? ]).to eq([ "loaded", true ]), err
      end
    end
  end
end
