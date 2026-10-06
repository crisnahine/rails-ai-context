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

  # What rails_get_active_support prints in its Concerns header: the
  # directories' modules, less the validator classes sitting among them.
  def active_support_total
    RailsAiContext::Introspectors::ActiveSupportIntrospector
      .new(RailsAiContext::StaticApp.new(tmpdir)).send(:extract_concerns)
      .values.flatten.count { |m| !m[:validator] }
  end

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
      # The key hid a concern from a model's own concern list and nowhere
      # else, so the catalogue kept listing and counting it.
      it "leaves an excluded concern out of the listing and the count" do
        original = RailsAiContext.configuration.excluded_concerns
        RailsAiContext.configuration.excluded_concerns = [ /Searchable/ ]

        text = described_class.call.content.first[:text]

        expect(text).not_to include("Searchable")
        expect(text).to include("# Concerns (1)")
        expect(text).to include("1 concern hidden by `excluded_concerns`")
      ensure
        RailsAiContext.configuration.excluded_concerns = original
      end

      # An empty listing and a fully excluded one read the same, so the
      # answer blamed the app for a setting the user chose.
      it "says the exclusions emptied the listing rather than that the app has none" do
        original = RailsAiContext.configuration.excluded_concerns
        RailsAiContext.configuration.excluded_concerns = [ /Searchable/, /Authenticatable/ ]

        text = described_class.call.content.first[:text]

        # The same fact as the listing's own line, so it is worded the same.
        expect(text).to include("2 concerns hidden by `excluded_concerns`")
        expect(text).not_to include("No concerns found in")
      ensure
        RailsAiContext.configuration.excluded_concerns = original
      end

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

      it "does not follow a symlink out of app/models when listing includers" do
        outside = File.join(tmpdir, "outside")
        FileUtils.mkdir_p(outside)
        File.write(File.join(outside, "smuggled.rb"), <<~RUBY)
          class Smuggled
            include Searchable
          end
        RUBY
        File.symlink(File.join(outside, "smuggled.rb"), File.join(models_dir, "smuggled.rb"))

        text = described_class.call(name: "Searchable").content.first[:text]
        expect(text).not_to include("Smuggled")
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

      it "omits the dangling 'Available:' line when no concerns exist to suggest" do
        empty_dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(empty_dir, "app", "models", "concerns"))
        FileUtils.mkdir_p(File.join(empty_dir, "app", "controllers", "concerns"))
        allow(described_class).to receive(:rails_app).and_return(
          double("app", root: Pathname.new(empty_dir))
        )

        result = described_class.call(name: "Nonexistent")
        text = result.content.first[:text]

        expect(text).to include("not found")
        expect(text).not_to include("Available:")
      ensure
        FileUtils.remove_entry(empty_dir) if empty_dir
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

      # The refusal belongs to the name, not to any directory, so an app with
      # no concern directory to loop over must still answer with it.
      it "rejects a traversal even with no concern directories to search" do
        empty_dir = Dir.mktmpdir
        allow(described_class).to receive(:rails_app).and_return(
          double("app", root: Pathname.new(empty_dir))
        )

        text = described_class.call(name: "../../config/master.key").content.first[:text]
        expect(text).to match(/not allowed/)
      ensure
        FileUtils.remove_entry(empty_dir) if empty_dir
      end

      # The name is benign, so only the post-realpath check catches it; the
      # directory loop has to render that refusal rather than search on.
      it "rejects a concern file symlinked to a sensitive path" do
        skip "symlinks unavailable" unless File.respond_to?(:symlink?)

        secret = File.join(model_concerns_dir, "buried.key")
        File.write(secret, "should-never-leak-from-symlink")
        link = File.join(model_concerns_dir, "secret_helper.rb")
        File.symlink(secret, link)

        text = described_class.call(name: "secret_helper").content.first[:text]
        expect(text).to match(/not allowed/)
        expect(text).to include("sensitive file")
        expect(text).not_to include("should-never-leak-from-symlink")
      ensure
        FileUtils.rm_f([ link, secret ].compact)
      end

      it "rejects null bytes in the name parameter" do
        result = described_class.call(name: "searchable\0.rb")
        text = result.content.first[:text]
        expect(text).to match(/not allowed/)
      end
    end

    context "a def inside a heredoc or behind an inline private" do
      before do
        File.write(File.join(model_concerns_dir, "documented.rb"), <<~RUBY)
          module Documented
            extend ActiveSupport::Concern

            USAGE = <<~USAGE
              def example_usage
              end
            USAGE

            def visible; end

            private def hidden_helper; end
          end
        RUBY
      end

      it "lists only the methods the module really defines as public" do
        text = described_class.call(name: "Documented", detail: "standard").content.first[:text]

        expect(text).to include("- `visible`")
        expect(text).not_to include("example_usage")
        expect(text).not_to include("hidden_helper")
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

      # The listed name is `x` where the source says `def self.x`; the body
      # is looked up under both.
      it "renders the body of a def self. class method at detail:full" do
        text = described_class.call(name: "MixedMethods", detail: "full").content.first[:text]

        expect(text).to include("def self.after_block")
        expect(text).to include("def inside_block")
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

      # The section used to spell its own macro list, so a callback the
      # Macros section named was missing from the Callbacks section.
      it "names every callback the macros section names" do
        File.write(File.join(model_concerns_dir, "rate_limitable.rb"), <<~RUBY)
          module RateLimitable
            extend ActiveSupport::Concern

            included do
              before_save :normalize
              after_commit :announce, on: :create
              after_rollback :undo
              after_touch :bust
              after_initialize :seed
              after_find :log
              after_create_commit :ping
              skip_callback :save, :before, :stamp_audit, if: :draft?
              skip_callback :commit, :after, AuditTrail
              around_create Some::CallbackObject
              after_update do
                bump!
              end
            end
          end
        RUBY

        text = described_class.call(name: "RateLimitable").content.first[:text]
        callbacks = text.split("## Callbacks").last

        expect(callbacks).to include("before_save :normalize")
        expect(callbacks).to include("after_commit :announce, on: :create")
        expect(callbacks).to include("after_rollback :undo")
        expect(callbacks).to include("after_touch :bust")
        expect(callbacks).to include("after_initialize :seed")
        expect(callbacks).to include("after_find :log")
        expect(callbacks).to include("after_create_commit :ping")
        expect(callbacks).to include("around_create Some::CallbackObject")
        expect(callbacks).to include("skip_callback :save, :before, :stamp_audit, if: :draft?")
        expect(callbacks).to include("skip_callback :commit, :after, AuditTrail")
        expect(callbacks).to include("after_update do")
      end
    end

    context "with concerns outside app/models and app/controllers" do
      let(:mailer_concerns_dir) { File.join(tmpdir, "app", "mailers", "concerns") }
      let(:serializer_concerns_dir) { File.join(tmpdir, "app", "serializers", "concerns") }

      before do
        FileUtils.mkdir_p(mailer_concerns_dir)
        FileUtils.mkdir_p(serializer_concerns_dir)

        File.write(File.join(mailer_concerns_dir, "bulk_mail_settings_concern.rb"), <<~RUBY)
          module BulkMailSettingsConcern
            extend ActiveSupport::Concern

            def bulk_headers
              { "Precedence" => "bulk" }
            end
          end
        RUBY

        File.write(File.join(serializer_concerns_dir, "cacheable.rb"), <<~RUBY)
          module Cacheable
            extend ActiveSupport::Concern

            def cache_key_for(record)
              record.id
            end
          end
        RUBY
      end

      it "counts mailer concerns in the total" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("# Concerns (4)")
      end

      it "lists the mailer concern under its own heading" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Mailer Concerns")
        expect(text).to include("BulkMailSettingsConcern")
      end

      it "finds a mailer concern asked for by name" do
        result = described_class.call(name: "BulkMailSettingsConcern")
        text = result.content.first[:text]
        expect(text).to include("BulkMailSettingsConcern")
        expect(text).to include("bulk_headers")
      end

      it "types a mailer concern as a mailer concern, not a controller one" do
        text = described_class.call(name: "BulkMailSettingsConcern").content.first[:text]
        expect(text).to include("**Type:** mailer concern")
      end

      it "finds the mailer that includes it" do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers"))
        File.write(File.join(tmpdir, "app", "mailers", "digest_mailer.rb"), <<~RUBY)
          class DigestMailer < ApplicationMailer
            include BulkMailSettingsConcern
          end
        RUBY

        text = described_class.call(name: "BulkMailSettingsConcern").content.first[:text]
        expect(text).to include("Included By")
        expect(text).to include("DigestMailer")
      end

      it "does not claim a mailer concern is included by no one" do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers"))
        File.write(File.join(tmpdir, "app", "mailers", "digest_mailer.rb"),
                   "class DigestMailer\n  include BulkMailSettingsConcern\nend\n")

        text = described_class.call(name: "BulkMailSettingsConcern").content.first[:text]
        expect(text).not_to include("_No models or controllers found")
      end

      it "picks up a non-stock app/*/concerns directory too" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Cacheable")
      end

      it "filters to mailer concerns only" do
        result = described_class.call(type: "mailer")
        text = result.content.first[:text]
        expect(text).to include("BulkMailSettingsConcern")
        expect(text).not_to include("Searchable")
      end

      it "filters to a concern directory outside app/*/concerns" do
        FileUtils.mkdir_p(File.join(tmpdir, "lib", "concerns"))
        File.write(File.join(tmpdir, "lib", "concerns", "auditable.rb"),
                   "module Auditable\n  def audit; end\nend\n")
        allow(RailsAiContext.configuration).to receive(:concern_paths)
          .and_return(%w[app/models/concerns lib/concerns])

        text = described_class.call(type: "other").content.first[:text]
        expect(text).to include("Auditable")
        expect(text).not_to include("Searchable")
      end

      it "still filters models and controllers the way it always did" do
        text = described_class.call(type: "model").content.first[:text]
        expect(text).to include("Searchable")
        expect(text).not_to include("BulkMailSettingsConcern")
      end

      context "when one name sits in two concern directories" do
        before do
          File.write(File.join(model_concerns_dir, "trackable.rb"),
                     "module Trackable\n  def model_track; end\nend\n")
          File.write(File.join(controller_concerns_dir, "trackable.rb"),
                     "module Trackable\n  def controller_track; end\nend\n")
          described_class.reset_cache!
        end

        it "lists the shared name once in the not-found list" do
          text = described_class.call(name: "NoSuchConcern").content.first[:text]

          expect(text).to include("Available:")
          expect(text.scan("Trackable").size).to eq(1)
        end

        it "names the file it did not read" do
          text = described_class.call(name: "Trackable").content.first[:text]

          expect(text).to include("**File:** `app/controllers/concerns/trackable.rb`")
          expect(text).to include("**Also at:** `app/models/concerns/trackable.rb` (model concern)")
        end
      end

      # The includer search resolves packs and engines; the listing and the
      # lookup globbed the root only, so one tool answered from two app
      # layouts at once.
      context "on an app whose concerns live in a pack" do
        let(:pack_concerns_dir) { File.join(tmpdir, "packs", "billing", "app", "models", "concerns") }

        before do
          FileUtils.mkdir_p(pack_concerns_dir)
          File.write(File.join(pack_concerns_dir, "auditable.rb"), <<~RUBY)
            module Auditable
              extend ActiveSupport::Concern

              def audit!
              end
            end
          RUBY
          File.write(File.join(tmpdir, "packs", "billing", "app", "models", "invoice.rb"), <<~RUBY)
            class Invoice < ApplicationRecord
              include Auditable
            end
          RUBY
          described_class.reset_cache!
        end

        it "lists, reads and finds the includers of the pack's concern" do
          listing = described_class.call.content.first[:text]
          expect(listing).to include("Auditable")

          text = described_class.call(name: "Auditable").content.first[:text]
          expect(text).to include("packs/billing/app/models/concerns/auditable.rb")
          expect(text).to include("audit!")
          expect(text).to include("Invoice")
        end
      end

      it "agrees with the ActiveSupport introspector on the total" do
        listed = described_class.call.content.first[:text][/# Concerns \((\d+)\)/, 1].to_i

        expect(listed).to eq(active_support_total)
      end
    end
  end
  # An app inflection makes a directory segment an acronym, so the constant
  # the file declares is not the one the path camelizes to. Listing the
  # camelized path named a constant the app does not have, and the two
  # spellings answered under two names.
  context "on an app that keeps its concerns in app/concerns" do
    before do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "concerns"))
      File.write(File.join(tmpdir, "app", "concerns", "email_concern.rb"), <<~RUBY)
        module EmailConcern
          extend ActiveSupport::Concern

          def deliver_digest
          end
        end
      RUBY
      File.write(File.join(models_dir, "agent.rb"), <<~RUBY)
        class Agent < ApplicationRecord
          include EmailConcern
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
      described_class.reset_cache!
    end

    it "lists, reads and finds the includers of a concern there" do
      listing = described_class.call.content.first[:text]
      expect(listing).to include("**EmailConcern**")
      expect(listing).to include("app/concerns/email_concern.rb")

      text = described_class.call(name: "EmailConcern").content.first[:text]
      expect(text).to include("deliver_digest")
      expect(text).to include("Agent")
    end
  end

  # A module that extends ActiveSupport::Concern is a concern wherever it
  # lives: the services listing leaves one under app/services out as a
  # concern, and this tool said the app had none.
  context "on an app that keeps a concern outside every concerns directory" do
    before do
      csv = File.join(tmpdir, "app", "services", "reports", "csv")
      FileUtils.mkdir_p(csv)
      File.write(File.join(csv, "row_helpers.rb"), <<~RUBY)
        module Reports
          module Csv
            module RowHelpers
              extend ActiveSupport::Concern

              def to_row
              end
            end
          end
        end
      RUBY
      File.write(File.join(csv, "exporter.rb"), <<~RUBY)
        module Reports
          module Csv
            class Exporter
              include RowHelpers
            end
          end
        end
      RUBY
      nested = File.join(tmpdir, "app", "services", "accessibility", "concerns")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "queueable.rb"), "module Accessibility\n  module Concerns\n    module Queueable\n    end\n  end\nend\n")
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
      described_class.reset_cache!
    end

    it "lists it where it lives, under a type that says where" do
      text = described_class.call.content.first[:text]

      expect(text).to include("## Service Concerns (2)")
      expect(text).to include("**Reports::Csv::RowHelpers** - 1 method (`app/services/reports/csv/row_helpers.rb`)")
      expect(text).to include("**Accessibility::Concerns::Queueable**")
      expect(text).not_to include("Exporter")
    end

    it "answers it by name, and counts it as the ActiveSupport introspector does" do
      text = described_class.call(name: "Reports::Csv::RowHelpers").content.first[:text]

      expect(text).to include("# Reports::Csv::RowHelpers")
      expect(text).to include("**Type:** service concern")
      expect(text).to include("to_row")

      listed = described_class.call.content.first[:text][/# Concerns \((\d+)\)/, 1].to_i
      expect(listed).to eq(active_support_total)
    end

    it "is not a service in the services listing" do
      expect(RailsAiContext::Introspectors::ServiceClasses.names(tmpdir)).to eq([ "Reports::Csv::Exporter" ])
    end

    # Every type a heading prints is a value the filter takes, spelled as the
    # heading spells it or as the directory does; a closed enum refused
    # `service`, and the CLI then fell back to listing everything.
    it "filters to the type a heading prints, in either spelling" do
      %w[service Service].each do |type|
        text = described_class.call(type: type).content.first[:text]
        expect(text).to include("## Service Concerns (2)")
        expect(text).not_to include("Searchable")
      end
      expect(described_class.input_schema.to_h.dig(:properties, :type)).not_to have_key(:enum)
    end

    it "names the types the app has for a type it does not have" do
      text = described_class.call(type: "widget").content.first[:text]

      expect(text).to include("No concerns of type `widget`")
      expect(text).to include("`controller`, `model`, `service`")
    end

    it "names only the types that hold a concern, not a directory holding .keep" do
      FileUtils.rm_rf(controller_concerns_dir)
      FileUtils.mkdir_p(controller_concerns_dir)
      File.write(File.join(controller_concerns_dir, ".keep"), "")

      text = described_class.call(type: "widget").content.first[:text]

      expect(text).to include("`model`, `service`.")
      expect(text).not_to include("`controller`")
    end
  end

  # Huginn's LiquidDroppable defines nothing of its own: every method and the
  # `include Enumerable` belong to nested Drop classes, which the answer
  # credited to the concern.
  context "on a concern whose nested classes carry the methods and includes" do
    before do
      File.write(File.join(model_concerns_dir, "liquid_droppable.rb"), <<~RUBY)
        module LiquidDroppable
          extend ActiveSupport::Concern

          included do
            include Comparable
          end

          def to_liquid
          end

          class Drop
            include Enumerable

            def each
            end
          end
        end
      RUBY
      described_class.reset_cache!
    end

    it "reads includes and methods off the module's own body" do
      text = described_class.call(name: "LiquidDroppable").content.first[:text]

      expect(text).to include("**Includes:** Comparable")
      expect(text).not_to include("Enumerable")
      expect(text).to include("to_liquid")
      expect(text).not_to include("`each`")
      expect(described_class.call.content.first[:text]).to include("**LiquidDroppable** - 1 method")
    end
  end

  # Mastodon's Cacheable writes its class methods in `module ClassMethods`,
  # which ActiveSupport::Concern extends the includer with.
  it "reads a concern's module ClassMethods as its class methods" do
    File.write(File.join(model_concerns_dir, "cacheable.rb"), <<~RUBY)
      module Cacheable
        extend ActiveSupport::Concern

        module ClassMethods
          def cache_associated(*associations); end

          def cache_ids; end
        end
      end
    RUBY
    described_class.reset_cache!

    expect(described_class.call.content.first[:text]).to include("**Cacheable** - 2 methods")
    text = described_class.call(name: "Cacheable").content.first[:text]
    expect(text).to include("## Class Methods")
    expect(text).to include("cache_ids")
  end

  # A full listing prints each method's own body: a same-named def elsewhere
  # in the file (a private instance twin, a delegate) is a different method.
  it "prints a ClassMethods method's own body under its heading" do
    File.write(File.join(model_concerns_dir, "xwiki_request.rb"), <<~RUBY)
      module XwikiRequest
        extend ActiveSupport::Concern

        delegate :fields, to: :class

        module ClassMethods
          def fetch_json(json_hash, *keys)
            keys.inject(json_hash) { |json, key| json.fetch(key) }
          end

          def fields
            _fields
          end
        end

        private

        def fetch_json(json_hash, key)
          self.class.fetch_json(json_hash, key)
        end
      end
    RUBY
    described_class.reset_cache!

    text = described_class.call(name: "XwikiRequest", detail: "full").content.first[:text]
    class_section = text[/## Class Methods\n(.*)/m, 1]

    expect(class_section).to include("### fetch_json(json_hash, *keys)\n```ruby\n    def fetch_json(json_hash, *keys)")
    expect(class_section).not_to include("self.class.fetch_json")
    expect(class_section).to include("### fields\n```ruby\n    def fields\n      _fields")
  end

  # A concern that only adds private helpers read as an empty module.
  context "on a concern whose methods are all private" do
    before do
      File.write(File.join(model_concerns_dir, "sanitizable.rb"), <<~RUBY)
        module Sanitizable
          extend ActiveSupport::Concern

          private

          def sanitize_body
          end

          def strip_tags
          end
        end
      RUBY
      described_class.reset_cache!
    end

    it "says how many private methods it has, and lists them" do
      expect(described_class.call.content.first[:text]).to include("**Sanitizable** - 0 public methods (2 private)")

      text = described_class.call(name: "Sanitizable").content.first[:text]
      expect(text).to include("## Private Methods")
      expect(text).to include("- `sanitize_body`")
    end
  end

  # plugins/discourse-subscriptions/app/controllers/concerns/group.rb
  # declares DiscourseSubscriptions::Group; named "Group" it collided with
  # the core model and could not be asked for by its real name.
  context "on a plugin concern that declares a namespace its path does not carry" do
    before do
      plugin = File.join(tmpdir, "plugins", "discourse-subscriptions")
      FileUtils.mkdir_p(File.join(plugin, "app", "controllers", "concerns"))
      File.write(File.join(plugin, "plugin.rb"), "# name: discourse-subscriptions\n")
      File.write(File.join(plugin, "app", "controllers", "concerns", "group.rb"), <<~RUBY)
        module DiscourseSubscriptions
          module Group
            extend ActiveSupport::Concern

            def plan_group; end
          end
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
      described_class.reset_cache!
    end

    it "lists it and answers it under the constant the file declares" do
      expect(described_class.call.content.first[:text]).to include("**DiscourseSubscriptions::Group**")

      text = described_class.call(name: "DiscourseSubscriptions::Group").content.first[:text]
      expect(text).to include("# DiscourseSubscriptions::Group")
      expect(text).to include("plan_group")
    end
  end

  # Mastodon keeps Admin::ExportControllerConcern and
  # Settings::ExportControllerConcern; matching the last segment credited
  # every includer of either to both.
  context "on two concerns of one short name in two namespaces" do
    before do
      %w[admin settings].each do |ns|
        FileUtils.mkdir_p(File.join(controller_concerns_dir, ns))
        File.write(File.join(controller_concerns_dir, ns, "export_controller_concern.rb"),
                   "module #{ns.camelize}::ExportControllerConcern\n  extend ActiveSupport::Concern\nend\n")
        FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers", ns))
      end
      File.write(File.join(tmpdir, "app", "controllers", "admin", "export_domain_blocks_controller.rb"), <<~RUBY)
        module Admin
          class ExportDomainBlocksController < BaseController
            include ExportControllerConcern
            include ExportControllerConcern
          end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "controllers", "settings", "exports_controller.rb"), <<~RUBY)
        module Settings
          class ExportsController < BaseController
            include ExportControllerConcern

            class Helper
            end
          end
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
      described_class.reset_cache!
    end

    it "credits each includer to the concern its include resolves to, once, by its constant" do
      admin = described_class.call(name: "Admin::ExportControllerConcern").content.first[:text]
      expect(admin).to include("## Included By (1)")
      expect(admin).to include("- Admin::ExportDomainBlocksController")

      settings = described_class.call(name: "Settings::ExportControllerConcern").content.first[:text]
      expect(settings).to include("## Included By (1)")
      expect(settings).to include("- Settings::ExportsController")
    end
  end

  # OpenProject::StaticRouting lives in lib_static; the answer searched
  # app/lib_statics, which does not exist, and said nothing included it while
  # a model does. Huginn's lib/location.rb includes a concern from app/concerns.
  context "on concerns whose includers live outside the concern's own kind" do
    before do
      FileUtils.mkdir_p(File.join(tmpdir, "lib_static", "open_project"))
      FileUtils.mkdir_p(File.join(tmpdir, "config"))
      File.write(File.join(tmpdir, "config", "application.rb"),
                 "module App\n  class Application < Rails::Application\n    config.autoload_once_paths << Rails.root.join(\"lib_static\").to_s\n    config.autoload_paths << Rails.root.join(\"lib\").to_s\n  end\nend\n")
      File.write(File.join(tmpdir, "lib_static", "open_project", "static_routing.rb"),
                 "module OpenProject\n  module StaticRouting\n    extend ActiveSupport::Concern\n  end\nend\n")
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "activities"))
      File.write(File.join(tmpdir, "app", "models", "activities", "base_activity_provider.rb"),
                 "class Activities::BaseActivityProvider\n  include OpenProject::StaticRouting\nend\n")
      FileUtils.mkdir_p(File.join(tmpdir, "app", "concerns"))
      File.write(File.join(tmpdir, "app", "concerns", "liquid_droppable.rb"), "module LiquidDroppable\n  extend ActiveSupport::Concern\nend\n")
      FileUtils.mkdir_p(File.join(tmpdir, "lib"))
      File.write(File.join(tmpdir, "lib", "location.rb"), "class Location\n  include LiquidDroppable\nend\n")
      File.write(File.join(tmpdir, "lib", "orphan.rb"), "module Orphan\n  extend ActiveSupport::Concern\nend\n")
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
      RailsAiContext::PathResolver.clear_code_roots
      described_class.reset_cache!
    end

    it "finds the includers wherever the app's code lives" do
      static_routing = described_class.call(name: "OpenProject::StaticRouting").content.first[:text]
      expect(static_routing).to include("## Included By (1)")
      expect(static_routing).to include("- Activities::BaseActivityProvider")

      expect(described_class.call(name: "LiquidDroppable").content.first[:text]).to include("- Location")
    end

    it "says what it searched when nothing includes the concern" do
      text = described_class.call(name: "Orphan").content.first[:text]

      expect(text).to include("_Nothing under app/, lib/ or lib_static/ includes this concern._")
      expect(text).not_to include("app/libs")
    end
  end

  # Ruby runs a mixin hook on the module itself; no includer gains it.
  it "lists the class methods an includer gains, and not the module's own mixin hooks" do
    File.write(File.join(model_concerns_dir, "trackable.rb"), <<~RUBY)
      module Trackable
        def self.included(base)
          base.extend(ClassMethods)
        end

        def self.extended(base); end

        module ClassMethods
          def tracked_since(date) = where("created_at > ?", date)
        end

        def track!; end
      end
    RUBY
    allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
    described_class.reset_cache!

    text = described_class.call(name: "Trackable").content.first[:text]
    class_methods = text[/## Class Methods\n(?:- .*\n?)*/]

    expect(class_methods).to eq("## Class Methods\n- `tracked_since(date)`\n")
  end

  # Only class_methods and ClassMethods reach an includer; `def self.x` stays on the module,
  # and one written inside class_methods stays on ClassMethods, which neither lists.
  it "lists the module's own singleton methods apart from the class methods an includer gains" do
    File.write(File.join(model_concerns_dir, "sluggable.rb"), <<~RUBY)
      module Sluggable
        extend ActiveSupport::Concern

        def self.normalize(text) = text.parameterize

        class << self
          def separator = "-"
        end

        class_methods do
          def find_by_slug(slug) = find_by(slug: slug)
          def self.on_class_methods_only; end
          class << self
            def also_on_class_methods_only; end
          end
        end

        def self.included(base)
          super
        end
      end
    RUBY
    allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
    described_class.reset_cache!

    text = described_class.call(name: "Sluggable").content.first[:text]

    expect(text[/## Class Methods\n(?:- .*\n?)*/]).to eq("## Class Methods\n- `find_by_slug(slug)`\n")
    expect(text[/## Module Methods\n(?:- .*\n?)*/]).to eq("## Module Methods\n- `normalize(text)`\n- `separator`\n")
  end

  # ActiveSupport::Concern supports prepend, with its own prepended block.
  describe "a concern a model prepends" do
    before do
      File.write(File.join(model_concerns_dir, "archivable.rb"), <<~RUBY)
        module Archivable
          extend ActiveSupport::Concern

          prepended do
            scope :archived, -> { where(archived: true) }
          end

          def archive!; end
        end
      RUBY
      File.write(File.join(models_dir, "part.rb"), "class Part < ApplicationRecord\n  prepend Archivable\nend\n")
      File.write(File.join(models_dir, "badge.rb"), "class Badge < ApplicationRecord\n  extend Archivable\nend\n")
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
      described_class.reset_cache!
    end

    it "names the model under Included By, and not one that extends the concern" do
      text = described_class.call(name: "Archivable").content.first[:text]

      expect(text).to include("## Included By (1)")
      expect(text).to include("- Part")
      expect(text).not_to include("- Badge")
    end
  end

  describe "a concern whose namespace the path does not camelize to" do
    before do
      FileUtils.mkdir_p(File.join(model_concerns_dir, "sdg"))
      File.write(File.join(model_concerns_dir, "sdg", "tag_list.rb"), <<~RUBY)
        module SDG::TagList
          extend ActiveSupport::Concern

          def tag_list
          end
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
      described_class.reset_cache!
    end

    it "lists it under the constant the file declares" do
      text = described_class.call.content.first[:text]

      expect(text).to include("**SDG::TagList**")
      expect(text).not_to include("Sdg::TagList")
    end

    it "answers the camelized spelling under the declared name" do
      text = described_class.call(name: "Sdg::TagList").content.first[:text]

      expect(text).to include("# SDG::TagList")
      expect(text).to include("app/models/concerns/sdg/tag_list.rb")
    end

    it "answers the declared spelling under the same name" do
      text = described_class.call(name: "SDG::TagList").content.first[:text]

      expect(text).to include("# SDG::TagList")
    end

    it "suggests the declared name for a partial one" do
      text = described_class.call(name: "TagList").content.first[:text]

      expect(text).to include("SDG::TagList")
      expect(text).not_to include("Sdg::TagList")
    end

    it "is named the same way by the ActiveSupport introspector" do
      names = RailsAiContext::Introspectors::ActiveSupportIntrospector
                .new(RailsAiContext::StaticApp.new(tmpdir)).send(:extract_concerns)
                .values.flatten.map { |m| m[:name] }

      expect(names).to include("SDG::TagList")
      expect(names).not_to include("Sdg::TagList")
    end
  end

  # A class under app/models/concerns that subclasses ActiveModel::Validator
  # is not a concern: nothing includes it, and `validates_with` is how it is
  # wired. The type came from the directory alone, so 37 validators on one app
  # were reported as model concerns used by nothing.
  describe "a validator class in the concerns directory" do
    let(:validator_dir) { File.join(tmpdir, "app", "models", "concerns") }

    before do
      described_class.reset_cache!
      FileUtils.mkdir_p(validator_dir)
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models"))
      File.write(File.join(validator_dir, "zip_code_validator.rb"), <<~RUBY)
        class ZipCodeValidator < ActiveModel::Validator
          def validate(record); end
        end
      RUBY
      File.write(File.join(validator_dir, "email_validator.rb"), <<~RUBY)
        class EmailValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value); end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "models", "order.rb"), <<~RUBY)
        class Order < ApplicationRecord
          validates :email, email: true

          validates_with ZipCodeValidator
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
    end

    # A concern that nests its own validator class declares both, and the
    # file is named for the concern. Reading every declaration in the file
    # filed the concern as a validator, and the two tools then disagreed on
    # how many concerns the app has.
    context "when the file is a concern that nests a validator class" do
      before do
        File.write(File.join(validator_dir, "date_validation.rb"), <<~RUBY)
          module DateValidation
            extend ActiveSupport::Concern

            included do
              validates_with DateValidator
            end

            class DateValidator < ActiveModel::Validator
              def validate(record); end
            end
          end
        RUBY
        described_class.reset_cache!
      end

      it "reads it as a concern" do
        text = described_class.call(name: "DateValidation").content.first[:text]

        expect(text).to include("**Type:** model concern")
        expect(text).not_to include("**Type:** validator")
      end

      it "lists it among the concerns, counted as the ActiveSupport introspector counts it" do
        listing = described_class.call.content.first[:text]
        listed = listing[/# Concerns \((\d+)\)/, 1].to_i

        expect(listing).to include("**DateValidation**")
        expect(listed).to eq(active_support_total)
      end
    end

    it "calls it a validator rather than a model concern" do
      text = described_class.call(name: "ZipCodeValidator").content.first[:text]

      expect(text).to include("**Type:** validator")
      expect(text).not_to include("**Type:** model concern")
    end

    # The name arrives in whatever spelling the caller has, and the chain
    # walk compares it against the constant the file declares.
    it "calls it a validator when asked for by its file name" do
      text = described_class.call(name: "zip_code_validator").content.first[:text]

      expect(text).to include("**Type:** validator")
    end

    it "names the model that wires it with validates_with" do
      text = described_class.call(name: "ZipCodeValidator").content.first[:text]

      expect(text).to include("Order")
      expect(text).not_to include("Nothing in app/models includes this concern")
    end

    # The pre-parse filter skips a file naming neither the class nor its key;
    # these shapes name them only partly and still wire the validator.
    it "finds the namespaced and hash-rocket wirings" do
      File.write(File.join(tmpdir, "app", "models", "order.rb"), <<~RUBY)
        class Order < ApplicationRecord
          validates_with Checks::ZipCodeValidator
        end
      RUBY
      File.write(File.join(tmpdir, "app", "models", "account.rb"), <<~RUBY)
        class Account < ApplicationRecord
          validates :email, :email => true
        end
      RUBY

      expect(described_class.call(name: "ZipCodeValidator").content.first[:text]).to include("- Order")
      expect(described_class.call(name: "EmailValidator").content.first[:text]).to include("- Account")
    end

    it "names the model that wires an EachValidator by its option key" do
      text = described_class.call(name: "EmailValidator").content.first[:text]

      expect(text).to include("Order")
    end

    # A concern that wires the validator in its `included` block is how a
    # validator shared by several models is usually attached.
    it "names a concern that wires it, as a concern" do
      File.write(File.join(tmpdir, "app", "models", "order.rb"), "class Order < ApplicationRecord\nend\n")
      File.write(File.join(validator_dir, "addressable.rb"), <<~RUBY)
        module Addressable
          extend ActiveSupport::Concern

          included do
            validates_with ZipCodeValidator
          end
        end
      RUBY

      text = described_class.call(name: "ZipCodeValidator").content.first[:text]

      expect(text).to include("- Addressable (concern)")
      expect(text).not_to include("No model or concern in app/models wires this validator")
    end

    # An app with its own validator base class is the ordinary shape, and one
    # level of compare called every such validator a concern used by nothing.
    it "follows the app's own validator base class" do
      File.write(File.join(validator_dir, "application_validator.rb"), <<~RUBY)
        class ApplicationValidator < ActiveModel::EachValidator
        end
      RUBY
      File.write(File.join(validator_dir, "postcode_validator.rb"), <<~RUBY)
        class PostcodeValidator < ApplicationValidator
          def validate_each(record, attribute, value); end
        end
      RUBY

      text = described_class.call(name: "PostcodeValidator").content.first[:text]

      expect(text).to include("**Type:** validator")
      expect(text).not_to include("**Type:** model concern")
    end

    # `presence:` names ActiveModel's own validator, which the model's
    # ancestry reaches before any app class, so an app PresenceValidator is
    # not what `validates :x, presence: true` runs.
    it "does not claim a framework option key for an app validator of the same name" do
      File.write(File.join(validator_dir, "presence_validator.rb"), <<~RUBY)
        class PresenceValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value); end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "models", "post.rb"), <<~RUBY)
        class Post < ApplicationRecord
          validates :title, presence: true
        end
      RUBY

      text = described_class.call(name: "PresenceValidator").content.first[:text]

      expect(text).not_to include("- Post")
    end

    # `on:`, `if:` and the other keys `validates` reads for itself never look
    # up a validator class.
    it "does not claim one of validates' own option keys" do
      File.write(File.join(validator_dir, "on_validator.rb"), <<~RUBY)
        class OnValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value); end
        end
      RUBY
      File.write(File.join(tmpdir, "app", "models", "post.rb"), <<~RUBY)
        class Post < ApplicationRecord
          validates :title, presence: true, on: :create
        end
      RUBY

      text = described_class.call(name: "OnValidator").content.first[:text]

      expect(text).not_to include("- Post")
    end

    it "lists validators apart from concerns" do
      text = described_class.call.content.first[:text]

      expect(text).to include("## Validators (2)")
      expect(text).not_to include("## Model Concerns (2)")
    end
  end
end
