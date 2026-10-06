# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::TableName do
  describe ".explicit" do
    it "reads a string assignment from the named class" do
      source = "class FollowRecommendation < ApplicationRecord\n  self.table_name = 'global_follow_recommendations'\nend\n"

      expect(described_class.explicit(source, "FollowRecommendation")).to eq("global_follow_recommendations")
    end

    it "reads a symbol assignment" do
      source = "class FollowRecommendation < ApplicationRecord\n  self.table_name = :global_follow_recommendations\nend\n"

      expect(described_class.explicit(source, "FollowRecommendation")).to eq("global_follow_recommendations")
    end

    it "reads it through module nesting" do
      source = "module Admin\n  class ActionLog < ApplicationRecord\n    self.table_name = 'legacy_logs'\n  end\nend\n"

      expect(described_class.explicit(source, "Admin::ActionLog")).to eq("legacy_logs")
    end

    # A second class in the file, nested or not, is not this file's class, and
    # its table is not this file's table.
    it "ignores an assignment made by another class in the file" do
      source = "class Widget < ApplicationRecord\n  class Archive < ApplicationRecord\n    self.table_name = 'widget_archives'\n  end\nend\n"

      expect(described_class.explicit(source, "Widget")).to be_nil
      expect(described_class.explicit(source, "Widget::Archive")).to eq("widget_archives")
    end

    it "answers nil for a computed value" do
      source = "class Widget < ApplicationRecord\n  self.table_name = \"\#{prefix}_widgets\"\nend\n"

      expect(described_class.explicit(source, "Widget")).to be_nil
    end

    # OpenProject's Principal: `"#{table_name_prefix}users#{table_name_suffix}"`
    # reads the class attribute Rails sets from config.active_record.
    describe "a name interpolating only the class's own prefix and suffix" do
      let(:source) do
        "class Principal < ApplicationRecord\n  self.table_name = \"\#{table_name_prefix}users\#{self.table_name_suffix}\"\nend\n"
      end

      def with_config(body)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config/application.rb"), body) if body
          return yield(dir)
        end
      end

      it "reads the literal with the default empty affixes" do
        expect(described_class.explicit(source, "Principal")).to eq("users")
        expect(with_config(nil) { |dir| described_class.explicit(source, "Principal", dir) }).to eq("users")
      end

      it "takes the affixes config/application.rb sets" do
        config = <<~RUBY
          module Op
            class Application < Rails::Application
              config.active_record.table_name_prefix = "op_"
              config.active_record.table_name_suffix = "_v2"
            end
          end
        RUBY

        expect(with_config(config) { |dir| described_class.explicit(source, "Principal", dir) }).to eq("op_users_v2")
      end

      it "takes what the environment file and the initializers set after config/application.rb" do
        result = with_config("class Application < Rails::Application\n  config.active_record.table_name_prefix = \"op_\"\nend\n") do |dir|
          FileUtils.mkdir_p(File.join(dir, "config/initializers"))
          FileUtils.mkdir_p(File.join(dir, "config/environments"))
          File.write(File.join(dir, "config/environments/#{RailsAiContext.environment_name}.rb"),
                     "Rails.application.configure do\n  config.active_record.table_name_suffix = \"_v1\"\nend\n")
          File.write(File.join(dir, "config/initializers/ar.rb"), "ActiveRecord::Base.pluralize_table_names = false\n")
          File.write(File.join(dir, "config/initializers/z.rb"), "Rails.application.config.active_record.table_name_suffix = \"_v2\"\n")
          RailsAiContext::Introspectors::ActiveRecordSettings.for(dir)
        end

        expect(result).to eq(table_name_prefix: "op_", table_name_suffix: "_v2", pluralize_table_names: false)
      end

      it "takes what an on_load(:active_record) block sets on the base class" do
        result = with_config(nil) do |dir|
          FileUtils.mkdir_p(File.join(dir, "config/initializers"))
          File.write(File.join(dir, "config/initializers/ar.rb"),
                     "ActiveSupport.on_load(:active_record) do\n  self.table_name_prefix = \"app_\"\n  self.pluralize_table_names = false\nend\n")
          RailsAiContext::Introspectors::ActiveRecordSettings.for(dir)
        end

        expect(result).to eq(table_name_prefix: "app_", pluralize_table_names: false)
      end

      it "takes a prefix the class declares itself" do
        own = "class Principal < ApplicationRecord\n  self.table_name_prefix = \"p_\"\n" \
              "  self.table_name = \"\#{table_name_prefix}users\"\nend\n"

        expect(described_class.explicit(own, "Principal")).to eq("p_users")
      end

      it "answers nil for any other interpolation" do
        other = "class Principal < ApplicationRecord\n  self.table_name = \"\#{table_name_prefix}users\#{shard}\"\nend\n"

        expect(described_class.explicit(other, "Principal")).to be_nil
      end
    end

    it "answers nil when the class declares none" do
      source = "class Widget < ApplicationRecord\nend\n"

      expect(described_class.explicit(source, "Widget")).to be_nil
    end

    it "answers nil when nothing parses" do
      expect(described_class.explicit("class Widget\n  def", "Widget")).to be_nil
    end
  end

  describe "the prefix and suffix a module declares" do
    it "reads the method form" do
      source = "module Admin\n  def self.table_name_prefix\n    'admin_'\n  end\nend\n"

      expect(described_class.declarations(source, "Admin")[:table_name_prefix]).to eq("admin_")
    end

    it "reads the assignment form" do
      source = "module Web\n  self.table_name_prefix = 'web_'\nend\n"

      expect(described_class.declarations(source, "Web")[:table_name_prefix]).to eq("web_")
    end

    it "answers nil for a method that computes its value" do
      source = "module Admin\n  def self.table_name_prefix\n    ENV['PREFIX']\n  end\nend\n"

      expect(described_class.declarations(source, "Admin")[:table_name_prefix]).to be_nil
    end

    it "answers nil for a module that declares none" do
      expect(described_class.declarations("module Admin\nend\n", "Admin")[:table_name_prefix]).to be_nil
    end

    it "reads a suffix in the method form" do
      source = "module Legacy\n  def self.table_name_suffix\n    '_v1'\n  end\nend\n"

      expect(described_class.declarations(source, "Legacy")[:table_name_suffix]).to eq("_v1")
    end
  end

  describe ".declarations" do
    it "reads every declaration out of one body" do
      source = <<~RUBY
        module Legacy
          def self.table_name_prefix
            "legacy_"
          end

          def self.table_name_suffix
            "_v1"
          end

          self.table_name = "ledger"
          self.pluralize_table_names = false
          self.primary_key = [:shop_id, "id"]
        end
      RUBY

      expect(described_class.declarations(source, "Legacy")).to eq(
        table_name: "ledger", table_name_prefix: "legacy_", table_name_suffix: "_v1", pluralize_table_names: false,
        primary_key: %w[shop_id id]
      )
    end

    it "answers each as nil when the file declares no such scope" do
      expect(described_class.declarations("class Widget\nend\n", "Other")).to eq(
        table_name: nil, table_name_prefix: nil, table_name_suffix: nil, pluralize_table_names: nil, primary_key: nil
      )
    end

    it "reads a class built with Class.new from its block" do
      source = <<~RUBY
        module Admin
          Flag = Class.new(ApplicationRecord) do
            self.table_name = "admin_flags"
          end
        end
        LegacyFlag = Class.new(ApplicationRecord) { self.table_name = "legacy" }
        Other = Class.new(ApplicationRecord)
      RUBY

      expect(described_class.explicit(source, "Admin::Flag")).to eq("admin_flags")
      expect(described_class.explicit(source, "LegacyFlag")).to eq("legacy")
      expect(described_class.explicit(source, "Other")).to be_nil
    end

    it "descends the file once for all of them" do
      source = "class Widget < ApplicationRecord\n  self.table_name = 'gizmos'\nend\n"
      allow(RailsAiContext::AstCache).to receive(:parse_string).and_call_original

      described_class.declarations(source, "Widget")

      expect(RailsAiContext::AstCache).to have_received(:parse_string).once
    end
  end

  describe ".stem" do
    # Rails derives the table through the app's own inflector, and the file's
    # name already carries that inflection.
    it "pluralizes the file's basename" do
      expect(described_class.stem("/app/models/oauth_client_config.rb")).to eq("oauth_client_configs")
    end
  end

  describe ".derive" do
    it "drops the namespace, the way Rails demodulizes the model name" do
      expect(described_class.derive("Admin::ActionLog")).to eq("action_logs")
    end

    it "pluralizes a plain name" do
      expect(described_class.derive("Post")).to eq("posts")
    end
  end

  describe ".for_model_name" do
    let(:models) { { "Admin::ActionLog" => { table_name: "admin_action_logs" } } }

    it "answers the table the model tier recorded" do
      expect(described_class.for_model_name("Admin::ActionLog", models)).to eq("admin_action_logs")
    end

    it "matches the model name case-insensitively" do
      expect(described_class.for_model_name("admin::actionlog", models)).to eq("admin_action_logs")
    end

    it "falls back to the convention for a name no model carries" do
      expect(described_class.for_model_name("Widget", models)).to eq("widgets")
    end
  end
  # Rails' rule, unchanged from 7.0 through 8.1: full_table_name_prefix takes
  # the first module parent that responds to table_name_prefix, and
  # isolate_namespace defines one on the namespace as
  # "#{underscore(mod.name).tr('/', '_')}_".
  describe ".namespace_prefixes" do
    def app_with(files)
      Dir.mktmpdir do |dir|
        files.each do |rel, body|
          path = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, body)
        end
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        return yield(dir)
      end
    end

    it "reads isolate_namespace from an in-repo engine" do
      result = app_with(
        "plugins/rss/plugin.rb" => "",
        "plugins/rss/app/models/discourse_rss_polling/rss_feed.rb" => "module DiscourseRssPolling\n  class RssFeed < ActiveRecord::Base\n  end\nend\n",
        "plugins/rss/lib/discourse_rss_polling/engine.rb" =>
          "module DiscourseRssPolling\n  class Engine < ::Rails::Engine\n    isolate_namespace DiscourseRssPolling\n  end\nend\n"
      ) { |dir| described_class.namespace_prefixes(dir) }

      expect(result).to eq({ "DiscourseRssPolling" => "discourse_rss_polling_" })
    end

    it "underscores a multi-level namespace the way Rails does" do
      result = app_with(
        "modules/budgets/budgets.gemspec" => "",
        "modules/budgets/app/models/thing.rb" => "class Thing; end\n",
        "modules/budgets/lib/open_project/budgets/engine.rb" =>
          "module OpenProject\n  module Budgets\n    class Engine < ::Rails::Engine\n      isolate_namespace OpenProject::Budgets\n    end\n  end\nend\n"
      ) { |dir| described_class.namespace_prefixes(dir) }

      expect(result).to eq({ "OpenProject::Budgets" => "open_project_budgets_" })
    end

    it "prefers a literal table_name_prefix the namespace declares itself" do
      result = app_with(
        "plugins/rss/plugin.rb" => "",
        "plugins/rss/app/models/thing.rb" => "class Thing; end\n",
        "plugins/rss/lib/rss/engine.rb" =>
          "module Rss\n  def self.table_name_prefix\n    \"legacy_\"\n  end\n\n  class Engine < ::Rails::Engine\n    isolate_namespace Rss\n  end\nend\n"
      ) { |dir| described_class.namespace_prefixes(dir) }

      expect(result).to eq({ "Rss" => "legacy_" })
    end

    it "answers empty for an app that isolates no namespace" do
      result = app_with("app/models/post.rb" => "class Post < ApplicationRecord; end\n") do |dir|
        described_class.namespace_prefixes(dir)
      end

      expect(result).to eq({})
    end

    it "sees an engine added after an earlier run" do
      result = app_with("plugins/rss/plugin.rb" => "", "plugins/rss/app/models/thing.rb" => "class Thing; end\n") do |dir|
        expect(RailsAiContext::RunCache.around { described_class.namespace_prefixes(dir) }).to eq({})
        engine = File.join(dir, "plugins", "rss", "lib", "rss", "engine.rb")
        FileUtils.mkdir_p(File.dirname(engine))
        File.write(engine, "module Rss\n  class Engine < ::Rails::Engine\n    isolate_namespace Rss\n  end\nend\n")
        RailsAiContext::RunCache.around { described_class.namespace_prefixes(dir) }
      end

      expect(result).to eq({ "Rss" => "rss_" })
    end
  end

  describe ".model_for" do
    let(:models) { { "AIMatch" => {}, "Shop::Payment" => {}, "Payment" => {} } }

    it "spells a derived name as the model set does, from the owner's namespace outward" do
      expect(described_class.model_for("AiMatch", nil, models)).to eq("AIMatch")
      expect(described_class.model_for("Payment", "Shop::Order", models)).to eq("Shop::Payment")
      expect(described_class.model_for("::Payment", "Shop::Order", models)).to eq("Payment")
      expect(described_class.model_for("Missing", nil, models)).to be_nil
    end
  end
end
