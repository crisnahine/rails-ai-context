# frozen_string_literal: true

require "spec_helper"

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

    it "answers nil when the class declares none" do
      source = "class Widget < ApplicationRecord\nend\n"

      expect(described_class.explicit(source, "Widget")).to be_nil
    end

    it "answers nil when nothing parses" do
      expect(described_class.explicit("class Widget\n  def", "Widget")).to be_nil
    end
  end

  describe ".prefix" do
    it "reads the method form" do
      source = "module Admin\n  def self.table_name_prefix\n    'admin_'\n  end\nend\n"

      expect(described_class.prefix(source, "Admin")).to eq("admin_")
    end

    it "reads the assignment form" do
      source = "module Web\n  self.table_name_prefix = 'web_'\nend\n"

      expect(described_class.prefix(source, "Web")).to eq("web_")
    end

    it "answers nil for a method that computes its value" do
      source = "module Admin\n  def self.table_name_prefix\n    ENV['PREFIX']\n  end\nend\n"

      expect(described_class.prefix(source, "Admin")).to be_nil
    end

    it "answers nil for a module that declares none" do
      expect(described_class.prefix("module Admin\nend\n", "Admin")).to be_nil
    end
  end

  describe ".suffix" do
    it "reads the method form" do
      source = "module Legacy\n  def self.table_name_suffix\n    '_v1'\n  end\nend\n"

      expect(described_class.suffix(source, "Legacy")).to eq("_v1")
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
end
