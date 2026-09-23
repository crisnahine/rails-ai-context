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

        app = double("app", root: Pathname.new(tmpdir))
        introspected = RailsAiContext::Introspectors::ActiveSupportIntrospector
                         .new(app).send(:extract_concerns).values.flatten.size

        expect(listed).to eq(introspected)
      end
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
      File.write(File.join(validator_dir, "address_validator.rb"), <<~RUBY)
        class AddressValidator < ActiveModel::Validator
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

          validates_with AddressValidator
        end
      RUBY
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(tmpdir))
    end

    it "calls it a validator rather than a model concern" do
      text = described_class.call(name: "AddressValidator").content.first[:text]

      expect(text).to include("**Type:** validator")
      expect(text).not_to include("**Type:** model concern")
    end

    it "names the model that wires it with validates_with" do
      text = described_class.call(name: "AddressValidator").content.first[:text]

      expect(text).to include("Order")
      expect(text).not_to include("Nothing in app/models includes this concern")
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
            validates_with AddressValidator
          end
        end
      RUBY

      text = described_class.call(name: "AddressValidator").content.first[:text]

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
