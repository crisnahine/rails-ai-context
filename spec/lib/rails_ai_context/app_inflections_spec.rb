# frozen_string_literal: true

require "spec_helper"

# Rails derives a table and a route name through the app's own inflector. The
# static tier reads the app's literal rules and applies them for its run only.
RSpec.describe "the static tier and the app's inflections" do
  def build_app(dir, inflections)
    FileUtils.mkdir_p(File.join(dir, "config", "initializers"))
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    FileUtils.mkdir_p(File.join(dir, "db"))
    File.write(File.join(dir, "config", "initializers", "inflections.rb"), inflections)
    File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        resources :heroes, only: [:index, :show]
        resources :staffers, only: [:show]
      end
    RUBY
    File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
      ActiveRecord::Schema[8.0].define(version: 1) do
        create_table "heroes" do |t|
          t.string "name"
        end
      end
    RUBY
    File.write(File.join(dir, "app", "models", "application_record.rb"), "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n")
    File.write(File.join(dir, "app", "models", "hero.rb"), "class Hero < ApplicationRecord\nend\n")
  end

  let(:irregular) do
    <<~RUBY
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        inflect.irregular "hero", "heroes"
        inflect.irregular "staff", "staffers"
      end
    RUBY
  end

  around do |example|
    previous = [ RailsAiContext.tier, RailsAiContext.configuration.app_root ]
    RailsAiContext.tier = :static
    example.run
  ensure
    RailsAiContext.tier = previous.first
    RailsAiContext.configuration.app_root = previous.last
    RailsAiContext::Tools::BaseTool.reset_cache!
  end

  # What a booted app with these rules answers: Hero.table_name is "heroes"
  # and `resources :staffers` names its member route "staff".
  it "gives the static run the table and the route name Rails derives with the app's irregular rules" do
    Dir.mktmpdir do |dir|
      build_app(dir, irregular)
      context = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(dir)).call

      expect(context[:models]["Hero"][:table_name]).to eq("heroes")
      expect(context[:routes][:by_controller]["staffers"].map { |route| route[:name] }).to eq([ "staff" ])
    end
  end

  it "answers the tools with the same names" do
    Dir.mktmpdir do |dir|
      build_app(dir, irregular)
      RailsAiContext.configuration.app_root = dir
      RailsAiContext::Tools::BaseTool.reset_cache!

      model = RailsAiContext::Tools::GetModelDetails.call(model: "Hero").content.first[:text]
      routes = RailsAiContext::Tools::GetRoutes.call.content.first[:text]

      expect(model).to include("**Table:** `heroes`")
      expect(model).not_to include("missing from db/schema.rb")
      expect(routes).to include("staff_path(@record)")
      expect(routes).not_to include("staffer_path")
    end
  end

  # A booted app with this rule pluralizes hero_id's stem to heroes, a table,
  # so the column reads as a conventional foreign key and is left out.
  it "writes the context files with the same rules" do
    Dir.mktmpdir do |dir|
      build_app(dir, irregular)
      File.write(File.join(dir, "db", "schema.rb"), <<~RUBY)
        ActiveRecord::Schema[8.0].define(version: 1) do
          create_table "heroes" do |t|
            t.string "name"
          end
          create_table "missions" do |t|
            t.integer "hero_id"
            t.string "code"
          end
        end
      RUBY
      RailsAiContext.configuration.app_root = dir
      RailsAiContext.generate_context(format: :claude)
      schema = File.read(File.join(dir, ".claude", "rules", "rails-schema.md"))

      expect(schema).to include("**heroes** (2 cols)", "**missions** (3 cols) - code:string")
      expect(schema).not_to include("hero_id")
    end
  end

  it "finds a model a resource read names by its plural, as the app singularizes it" do
    Dir.mktmpdir do |dir|
      build_app(dir, irregular)
      File.write(File.join(dir, "app", "models", "staff.rb"), "class Staff < ApplicationRecord\nend\n")
      RailsAiContext.configuration.app_root = dir
      RailsAiContext::Tools::BaseTool.reset_cache!
      handler = nil
      server = instance_double("MCP::Server")
      allow(server).to receive(:resources=)
      allow(server).to receive(:resources_read_handler) { |&block| handler = block }
      RailsAiContext::Resources.register(server)
      read = handler.call(uri: "rails-ai-context://models/staffers")

      expect(JSON.parse(read.first[:text])["table_name"]).to eq("staffers")
    end
  end

  # Action Mailbox's router constantizes "#{name.to_s.camelize}Mailbox", and
  # Zeitwerk loads sms_mailbox.rb as SMSMailbox under this acronym.
  it "names a mailbox and its routing target with the app's acronym" do
    Dir.mktmpdir do |dir|
      build_app(dir, "ActiveSupport::Inflector.inflections(:en) do |inflect|\n  inflect.acronym \"SMS\"\nend\n")
      FileUtils.mkdir_p(File.join(dir, "app", "mailboxes"))
      File.write(File.join(dir, "app", "mailboxes", "application_mailbox.rb"), "class ApplicationMailbox < ActionMailbox::Base\n  routing(/^sms@/i => :sms)\nend\n")
      File.write(File.join(dir, "app", "mailboxes", "sms_mailbox.rb"), "class SMSMailbox < ApplicationMailbox\n  def process\n  end\nend\n")
      mailbox = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(dir)).call[:action_mailbox]

      expect(mailbox[:mailboxes].map { |entry| entry[:name] }).to eq([ "SMSMailbox" ])
      expect(mailbox[:routes].map { |route| route[:mailbox] }).to eq([ "SMSMailbox" ])
    end
  end

  it "keeps the rules to the run: the process, and another app read after it, keep the stock ones" do
    Dir.mktmpdir do |with_rules|
      Dir.mktmpdir do |without_rules|
        build_app(with_rules, irregular)
        build_app(without_rules, "")

        inside = RailsAiContext::AppInflections.around(RailsAiContext::StaticApp.new(with_rules)) do
          [ "hero".pluralize, RailsAiContext::AppInflections.around(RailsAiContext::StaticApp.new(without_rules)) { "hero".pluralize }, "hero".pluralize ]
        end
        other = RailsAiContext::Introspector.new(RailsAiContext::StaticApp.new(without_rules)).call

        expect(inside).to eq(%w[heroes heros heroes])
        expect("hero".pluralize).to eq("heros")
        expect("staffers".singularize).to eq("staffer")
        expect(other[:models]["Hero"][:table_name]).to eq("heros")
      end
    end
  end

  # From ActiveSupport 8.1 a dup of the stock inflections shares the uncountables' word list,
  # which uncountable grows and irregular shrinks; only the 8.1 legs go red without the fresh list.
  it "leaves the stock uncountables as they were after a run with uncountable and irregular rules" do
    Dir.mktmpdir do |dir|
      build_app(dir, <<~RUBY)
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.uncountable %w[moose]
          inflect.irregular "sheep", "sheepies"
        end
      RUBY
      inside = RailsAiContext::AppInflections.around(RailsAiContext::StaticApp.new(dir)) { [ "moose".pluralize, "sheep".pluralize ] }

      expect(inside).to eq(%w[moose sheepies])
      expect(ActiveSupport::Inflector.inflections.uncountables.to_a).to include("sheep")
      expect(ActiveSupport::Inflector.inflections.uncountables.to_a).not_to include("moose")
      expect([ "moose".pluralize, "sheep".pluralize ]).to eq(%w[mooses sheep])
    end
  end

  it "keeps the rules to the thread that runs" do
    Dir.mktmpdir do |dir|
      build_app(dir, irregular)
      seen = RailsAiContext::AppInflections.around(RailsAiContext::StaticApp.new(dir)) { Thread.new { "hero".pluralize }.value }

      expect(seen).to eq("heros")
    end
  end

  it "applies nothing to a booted app, whose inflector already holds its rules" do
    path = File.join(Rails.root, "config", "initializers", "app_inflections_probe.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, irregular)

    expect(RailsAiContext::AppInflections.around(Rails.application) { "hero".pluralize }).to eq("heros")
  ensure
    FileUtils.rm_f(path)
  end

  it "applies the literal rules, the acronyms among them, and skips a computed one, one that raises and a file that does not parse" do
    Dir.mktmpdir do |dir|
      build_app(dir, <<~RUBY)
        SUFFIX = "ii"
        ActiveSupport::Inflector.inflections(:en) do |inflections|
          inflections.acronym "SMS"
          inflections.plural(/(octop)us$/i, '\\1odes')
          inflections.uncountable %w[moose]
          inflections.irregular "cactus", "cact" + SUFFIX
          inflections.irregular "lonely"
          inflections.irregular "hero", "heroes"
        end
        ActiveSupport::Inflector.inflections(:es) { |inflect| inflect.irregular "staff", "staffers" }
      RUBY
      File.write(File.join(dir, "config", "initializers", "broken.rb"), "ActiveSupport::Inflector.inflections do |i|\n  i.acronym(")

      answers = RailsAiContext::AppInflections.around(RailsAiContext::StaticApp.new(dir)) do
        [ "sms_mailbox".camelize, "octopus".pluralize, "moose".pluralize, "cactus".pluralize, "hero".pluralize, "staff".pluralize ]
      end

      expect(answers).to eq(%w[SMSMailbox octopodes moose cactus heroes staffs])
      expect([ "sms_mailbox".camelize, "moose".pluralize ]).to eq(%w[SmsMailbox mooses])
    end
  end
end
