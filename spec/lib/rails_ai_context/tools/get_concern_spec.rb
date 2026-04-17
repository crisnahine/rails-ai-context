# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetConcern do
  before { described_class.reset_cache! }

  let(:tmpdir) { Dir.mktmpdir }
  let(:model_concerns_dir) { File.join(tmpdir, "app", "models", "concerns") }
  let(:controller_concerns_dir) { File.join(tmpdir, "app", "controllers", "concerns") }
  let(:models_dir) { File.join(tmpdir, "app", "models") }

  before do
    FileUtils.mkdir_p(model_concerns_dir)
    FileUtils.mkdir_p(controller_concerns_dir)
    FileUtils.mkdir_p(models_dir)

    File.write(File.join(model_concerns_dir, "searchable.rb"), <<~RUBY)
      module Searchable
        extend ActiveSupport::Concern

        included do
          scope :search, ->(query) { where("name LIKE ?", "%\#{query}%") }
          validates :name, presence: true
        end

        def search_result_title
          name
        end

        def search_result_url
          "/\#{self.class.table_name}/\#{id}"
        end

        private

        def normalize_search_terms
          self.search_terms = name.downcase
        end
      end
    RUBY

    File.write(File.join(controller_concerns_dir, "authenticatable.rb"), <<~RUBY)
      module Authenticatable
        extend ActiveSupport::Concern

        included do
          before_action :require_login
        end

        class_methods do
          def skip_auth(*actions)
            skip_before_action :require_login, only: actions
          end
        end

        private

        def require_login
          redirect_to login_path unless current_user
        end

        def current_user
          @current_user ||= User.find_by(id: session[:user_id])
        end
      end
    RUBY

    File.write(File.join(models_dir, "post.rb"), <<~RUBY)
      class Post < ApplicationRecord
        include Searchable
      end
    RUBY

    allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
    allow(described_class).to receive(:rails_app).and_return(
      double("app", root: Pathname.new(tmpdir))
    )
    allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(1_000_000)
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe ".call" do
    context "listing all concerns" do
      it "lists both model and controller concerns" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Model Concerns")
        expect(text).to include("Searchable")
        expect(text).to include("Controller Concerns")
        expect(text).to include("Authenticatable")
      end

      it "shows method counts for each concern" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("methods")
      end

      it "includes hint to use name param for detail" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("name:")
      end
    end

    context "filtering by type" do
      it "lists only model concerns when type is model" do
        result = described_class.call(type: "model")
        text = result.content.first[:text]
        expect(text).to include("Searchable")
        expect(text).not_to include("Authenticatable")
      end

      it "lists only controller concerns when type is controller" do
        result = described_class.call(type: "controller")
        text = result.content.first[:text]
        expect(text).to include("Authenticatable")
        expect(text).not_to include("Searchable")
      end
    end

    context "showing a specific concern" do
      it "shows concern details by name" do
        result = described_class.call(name: "Searchable")
        text = result.content.first[:text]
        expect(text).to include("# Searchable")
        expect(text).to include("model concern")
        expect(text).to include("Public Methods")
      end

      it "shows public methods of the concern" do
        result = described_class.call(name: "Searchable")
        text = result.content.first[:text]
        expect(text).to include("search_result_title")
        expect(text).to include("search_result_url")
      end

      it "does not show private methods" do
        result = described_class.call(name: "Searchable")
        text = result.content.first[:text]
        expect(text).not_to include("normalize_search_terms")
      end

      it "shows macros and DSL from included block" do
        result = described_class.call(name: "Searchable")
        text = result.content.first[:text]
        expect(text).to include("Macros")
        expect(text).to include("scope")
        expect(text).to include("validates")
      end

      it "shows class methods from class_methods block" do
        result = described_class.call(name: "Authenticatable")
        text = result.content.first[:text]
        expect(text).to include("Class Methods")
        expect(text).to include("skip_auth")
      end

      it "shows which models include the concern" do
        result = described_class.call(name: "Searchable")
        text = result.content.first[:text]
        expect(text).to include("Included By")
        expect(text).to include("Post")
      end

      it "finds includers when the concern name is plural" do
        File.write(File.join(model_concerns_dir, "worksheet_imports.rb"), <<~RUBY)
          module WorksheetImports
            extend ActiveSupport::Concern

            class_methods do
              def import(file); end
            end
          end
        RUBY

        File.write(File.join(models_dir, "worksheet.rb"), <<~RUBY)
          class Worksheet < ApplicationRecord
            include WorksheetImports
          end
        RUBY

        result = described_class.call(name: "WorksheetImports")
        text = result.content.first[:text]
        expect(text).to include("Included By")
        expect(text).to include("Worksheet")
      end
    end

    context "detail levels" do
      it "shows method signatures at detail:standard" do
        result = described_class.call(name: "Searchable", detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("`search_result_title`")
        expect(text).to include("`search_result_url`")
      end

      it "shows method source code at detail:full" do
        result = described_class.call(name: "Searchable", detail: "full")
        text = result.content.first[:text]
        expect(text).to include("```ruby")
        expect(text).to include("def search_result_title")
      end
    end

    context "error cases" do
      it "returns not-found for unknown concern" do
        result = described_class.call(name: "Nonexistent")
        text = result.content.first[:text]
        expect(text).to include("not found")
        expect(text).to include("Searchable")
      end

      it "returns message when no concern directories exist" do
        allow(described_class).to receive(:rails_app).and_return(
          double("app", root: Pathname.new("/tmp/empty_app_#{SecureRandom.hex(4)}"))
        )
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("No concern directories found")
      end
    end

    context "path traversal defense" do
      it "rejects `..` components in the name parameter" do
        # String#underscore does NOT sanitize path separators. Without the
        # early path-traversal guard, `name: "../../config/initializers/devise"`
        # would resolve through File.join and read arbitrary .rb files
        # under Rails.root. This test writes a file at that relative offset
        # so File.exist? would match and proves the block fires first.
        devise_file = File.join(tmpdir, "config", "initializers")
        FileUtils.mkdir_p(devise_file)
        File.write(File.join(devise_file, "devise.rb"), "# SECRET_TOKEN = 'should-never-leak-from-traversal'")

        result = described_class.call(name: "../../config/initializers/devise")
        text = result.content.first[:text]
        expect(text).to match(/not allowed/)
        expect(text).not_to include("should-never-leak-from-traversal")
      end

      it "rejects absolute paths in the name parameter" do
        result = described_class.call(name: "/etc/passwd")
        text = result.content.first[:text]
        expect(text).to match(/not allowed/)
      end

      it "rejects null bytes in the name parameter" do
        result = described_class.call(name: "searchable\0.rb")
        text = result.content.first[:text]
        expect(text).to match(/not allowed/)
      end

      it "blocks symlinks inside concerns dir that escape to sensitive files" do
        # A symlink at app/models/concerns/sneaky.rb -> config/master.key
        # passes the bare File.exist? check and, without the post-realpath
        # recheck, would leak the secret. Fix: realpath containment +
        # sensitive_file? recheck.
        secret = File.join(tmpdir, "config", "master.key")
        FileUtils.mkdir_p(File.dirname(secret))
        File.write(secret, "should-never-leak-as-concern")

        symlink = File.join(model_concerns_dir, "sneaky.rb")
        File.symlink(secret, symlink)

        result = described_class.call(name: "Sneaky")
        text = result.content.first[:text]
        expect(text).not_to include("should-never-leak-as-concern")
      end
    end

    context "class_methods block closing" do
      before do
        File.write(File.join(model_concerns_dir, "mixed_methods.rb"), <<~RUBY)
          module MixedMethods
            extend ActiveSupport::Concern

            class_methods do
              def inside_block
                # class method inside block
              end
            end

            def self.after_block
              # class method after block
            end
          end
        RUBY
      end

      it "captures def self. methods defined after class_methods block" do
        result = described_class.call(name: "MixedMethods", detail: "standard")
        text = result.content.first[:text]
        expect(text).to include("inside_block")
        expect(text).to include("after_block")
      end
    end

    context "callbacks in concerns" do
      before do
        File.write(File.join(model_concerns_dir, "trackable.rb"), <<~RUBY)
          module Trackable
            extend ActiveSupport::Concern

            included do
              before_save :track_changes
              after_create :log_creation
            end

            def track_changes
              # tracking logic
            end

            def log_creation
              # logging logic
            end
          end
        RUBY
      end

      it "detects callbacks defined in concerns" do
        result = described_class.call(name: "Trackable")
        text = result.content.first[:text]
        expect(text).to include("Callbacks")
        expect(text).to include("before_save")
        expect(text).to include("after_create")
      end
    end
  end
end
