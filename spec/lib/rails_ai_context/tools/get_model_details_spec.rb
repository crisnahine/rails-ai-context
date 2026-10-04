# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetModelDetails do
  before { described_class.reset_cache! }

  let(:models) do
    {
      "User" => {
        table_name: "users",
        associations: [
          { type: "has_many", name: "posts", dependent: "destroy" },
          { type: "has_many", name: "comments", dependent: "destroy" }
        ],
        validations: [
          { kind: "presence", attributes: [ "email" ], options: {} }
        ],
        enums: { "role" => { "member" => 0, "admin" => 1 } },
        scopes: [
          { name: "active", body: "where(active: true)" },
          { name: "admins", body: "where(role: :admin)" }
        ],
        callbacks: {}
      },
      "Post" => {
        table_name: "posts",
        associations: [
          { type: "belongs_to", name: "user" },
          { type: "has_many", name: "comments", dependent: "destroy" }
        ],
        validations: [
          { kind: "presence", attributes: [ "title" ], options: {} }
        ]
      },
      "Comment" => {
        table_name: "comments",
        associations: [
          { type: "belongs_to", name: "post" },
          { type: "belongs_to", name: "user" }
        ],
        validations: [
          { kind: "presence", attributes: [ "body" ], options: {} }
        ]
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ models: models })
  end

  describe ".call with no params" do
    it "reads a junk detail as standard" do
      text = described_class.call(detail: "verbose").content.first[:text]

      expect(text).to include("Models (3)")
      expect(text).not_to include("Available models")
    end

    it "defaults to standard detail level" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Models (3)")
      expect(text).to include("**User**")
      expect(text).to include("associations")
    end

    # Every model tying on association count is normal once plugin models
    # land, and with no tie-break the page order followed the payload's.
    it "breaks a tie on association count by name" do
      tied = %w[Zebra Alpha Mango Beta].each_with_object({}) do |name, h|
        h[name] = { table_name: name.downcase, associations: [ { type: "belongs_to", name: "user" } ], validations: [] }
      end
      allow(described_class).to receive(:cached_context).and_return({ models: tied })

      text = described_class.call(detail: "summary").content.first[:text]
      listed = text.lines.grep(/\A- \w+$/).map(&:strip)

      expect(listed).to eq([ "- Alpha", "- Beta", "- Mango", "- Zebra" ])
    end

    it "sorts models by association count descending" do
      result = described_class.call
      text = result.content.first[:text]
      # User has 2 associations, Post has 2, Comment has 2 - all tied but User should appear
      expect(text).to include("**User**")
      expect(text).to include("**Post**")
      expect(text).to include("**Comment**")
    end
  end

  describe ".call with model not found" do
    it "returns a not-found response with available models" do
      result = described_class.call(model: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("Available:")
      expect(text).to include("User")
    end

    it "provides a recovery tool hint" do
      result = described_class.call(model: "Nonexistent")
      text = result.content.first[:text]
      expect(text).to include("rails_get_model_details")
    end

    it "suggests a close match via fuzzy matching" do
      result = described_class.call(model: "Userr")
      text = result.content.first[:text]
      expect(text).to include("Did you mean")
      expect(text).to include("User")
    end
  end

  describe ".call with specific model" do
    it "returns full detail including associations section" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("# User")
      expect(text).to include("## Associations")
      expect(text).to include("has_many")
      expect(text).to include("posts")
    end

    it "shows enums when present" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("## Enums")
      expect(text).to include("role")
      expect(text).to include("member")
      expect(text).to include("admin")
    end

    it "shows scopes when present" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("## Scopes")
      expect(text).to include("active")
    end

    it "shows cross-reference hints" do
      result = described_class.call(model: "User")
      text = result.content.first[:text]
      expect(text).to include("rails_get_schema")
      expect(text).to include("rails_get_controllers")
    end

    it "handles model with error in data" do
      models_with_error = models.merge("Broken" => { error: "could not load" })
      allow(described_class).to receive(:cached_context).and_return({ models: models_with_error })
      result = described_class.call(model: "Broken")
      text = result.content.first[:text]
      expect(text).to include("Error inspecting")
      expect(text).to include("could not load")
    end

    # The count includes it either way, so a listing that skips it reads as
    # a count that does not match its own rows.
    it "names a model whose file it could not read in the listing" do
      models_with_error = models.merge("Broken" => { error: "file is unreadable" })
      allow(described_class).to receive(:cached_context).and_return({ models: models_with_error })

      %w[standard full].each do |detail|
        text = described_class.call(detail: detail).content.first[:text]
        expect(text).to include("- **Broken** [UNAVAILABLE: file is unreadable]")
      end
    end

    it "strips whitespace from model name input" do
      result = described_class.call(model: "  User  ")
      text = result.content.first[:text]
      expect(text).to include("# User")
    end
  end

  # Only the validator Rails adds carries the label; a presence rule the
  # model writes on the same name is its own declaration.
  describe "the implicit belongs_to presence" do
    it "labels the implicit record and not a declared one on the same name" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Comment" => {
          associations: [ { type: "belongs_to", name: "post" } ],
          validations: [ { kind: "presence", attributes: [ "post" ], options: {}, implicit: true },
                         { kind: "presence", attributes: [ "post" ], options: { on: :create } } ]
        }
      })

      text = described_class.call(model: "Comment").content.first[:text]

      expect(text).to include("- `presence` on post _(implicit from belongs_to)_")
      expect(text).to include("- `presence` on post (on: :create)\n")
    end
  end

  # Diaspora's Comment: lib/diaspora/fields/author.rb writes
  # `validates :author, presence: true` on the belongs_to Rails already guards.
  describe "a hand-written presence on a belongs_to name" do
    it "shows the hand-written rule and drops the implicit duplicate" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Comment" => { associations: [ { type: "belongs_to", name: "author" } ], validations: [
          { kind: "presence", attributes: [ "author" ], options: {}, implicit: true },
          { kind: "presence", attributes: [ "author" ], options: {} }
        ] }
      })

      text = described_class.call(model: "Comment").content.first[:text]

      expect(text).to include("- `presence` on author\n")
      expect(text).not_to include("implicit from belongs_to")
    end
  end

  describe "a belongs_to whose optional: is an expression" do
    it "prints the expression and a presence conditional on it" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Comment" => { associations: [ { type: "belongs_to", name: "maybe", optional: "!Rails.env.test?" } ],
                       validations: [ { kind: "presence", attributes: [ "maybe" ], options: {}, implicit: true,
                                        implicit_if: "optional: !Rails.env.test? is false" } ] }
      })

      text = described_class.call(model: "Comment").content.first[:text]

      expect(text).to include("- `belongs_to` **maybe** [optional: !Rails.env.test?]")
      expect(text).to include("- `presence` on maybe _(implicit from belongs_to when optional: !Rails.env.test? is false)_")
    end
  end

  describe "a validation whose attribute is computed" do
    it "names the expression, and the attributes it ran for when known" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Form" => { associations: [], validations: [
          { kind: "length", attributes: [], computed_attributes: %w[field], options: { maximum: "limit" } },
          { kind: "length", attributes: %w[title], computed_attributes: %w[field], options: { maximum: 5 } }
        ] }
      })

      text = described_class.call(model: "Form").content.first[:text]

      expect(text).to include("- `length` on `field` (computed) (maximum: limit)")
      expect(text).to include("- `length` on title (from `field`) (maximum: 5)")
    end
  end

  describe "a custom validate method with a condition" do
    it "prints the condition" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Form" => { associations: [], validations: [], custom_validates: %w[uses_left always],
                    custom_validate_conditions: { "uses_left" => { on: :create } } }
      })

      text = described_class.call(model: "Form").content.first[:text]

      expect(text).to include("- **Custom:** `uses_left` (on: :create)")
      expect(text).to include("- **Custom:** `always`")
    end
  end

  describe "a concern a macro includes" do
    it "says which macro" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Account" => { associations: [], validations: [], concerns: %w[Trackable Devise::Models::Lockable WidgetGem::Widget],
                       concern_sources: { "Devise::Models::Lockable" => "devise", "WidgetGem::Widget" => "a gem macro (booted only)" } }
      })

      text = described_class.call(model: "Account").content.first[:text]

      expect(text).to include("- Trackable\n", "- Devise::Models::Lockable (from devise)",
                              "- WidgetGem::Widget (from a gem macro (booted only))")
    end
  end

  describe "a validation a macro or gem adds" do
    it "names what added it" do
      allow(described_class).to receive(:cached_context).and_return(models: {
        "Account" => { associations: [], validations: [
          { kind: "confirmation", attributes: [ "password" ], options: {}, added_by: "has_secure_password" },
          { kind: "length", attributes: [ "title" ], options: { maximum: 5 }, reflection_only: true }
        ] }
      })

      text = described_class.call(model: "Account").content.first[:text]

      expect(text).to include("- `confirmation` on password _(added by has_secure_password)_")
      expect(text).to include("- `length` on title (maximum: 5) _(reflection only: no line the source reader parses declares it)_")
    end
  end

  describe ".call with a Mongoid model" do
    let(:mongoid_models) do
      {
        "Customer" => {
          mongoid: true,
          fields: [ { name: :name, type: "String" }, { name: :active, type: "Boolean" } ],
          embeds: [ { type: :embeds_many, name: :orders } ],
          associations: [],
          validations: []
        }
      }
    end

    before do
      allow(described_class).to receive(:cached_context).and_return({ models: mongoid_models })
    end

    it "renders declared fields since there is no AR table/columns" do
      result = described_class.call(model: "Customer")
      text = result.content.first[:text]
      expect(text).to include("## Fields")
      expect(text).to include("name")
      expect(text).to include("String")
    end

    it "renders embedded relations" do
      result = described_class.call(model: "Customer")
      text = result.content.first[:text]
      expect(text).to include("## Embedded relations")
      expect(text).to include("embeds_many")
      expect(text).to include("orders")
    end
  end

  describe ".call with pagination" do
    it "respects limit parameter" do
      result = described_class.call(limit: 1)
      text = result.content.first[:text]
      expect(text).to include("Showing 1-1 of 3")
    end

    it "returns empty-pagination message when offset exceeds total" do
      result = described_class.call(offset: 100)
      text = result.content.first[:text]
      expect(text).to include("No items at offset 100")
      expect(text).to include("Total: 3")
    end

    it "normalizes limit of 0 to minimum of 1" do
      result = described_class.call(limit: 0)
      text = result.content.first[:text]
      # paginate clamps limit to minimum of 1
      expect(text).to include("Models")
    end
  end

  describe ".call when introspection data is missing" do
    it "returns not-available when models key is nil" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "returns error message when models data has an error" do
      allow(described_class).to receive(:cached_context).and_return({
        models: { error: "database unreachable" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("database unreachable")
    end
  end

  describe "detail levels with simple model data" do
    before do
      simple_models = {
        "User" => {
          table_name: "users",
          associations: [ { type: "has_many", name: "posts" }, { type: "has_one", name: "profile" } ],
          validations: [ { kind: "presence", attributes: [ "email" ], options: {} } ]
        },
        "Post" => {
          table_name: "posts",
          associations: [ { type: "belongs_to", name: "user" } ],
          validations: []
        }
      }
      allow(described_class).to receive(:cached_context).and_return({ models: simple_models })
    end

    it "returns names only with detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("- Post")
      expect(text).to include("- User")
      expect(text).not_to include("associations")
    end

    it "returns names with association list for detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("**User**")
      expect(text).to include("has_many :posts")
    end

    it "supports case-insensitive model lookup" do
      result = described_class.call(model: "user")
      text = result.content.first[:text]
      expect(text).to include("# User")
    end
  end
  # A model in a pack does not live under app/models, so rebuilding the path
  # from the name found nothing and every source-read section went quietly
  # missing from an answer that otherwise looked complete.
  describe "a model whose file is not under app/models" do
    around do |example|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "packs", "billing", "app", "models", "invoice.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~RUBY)
          class Invoice < ApplicationRecord
            USAGE = <<~USAGE
              def example_usage
              end
            USAGE

            def self.overdue
            end

            def overdue_by(days)
            end

            private

            def internal
            end
          end
        RUBY
        @root = dir
        example.run
      end
    end

    it "reads the source from the file the model carries" do
      described_class.reset_cache!
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Invoice" => { table_name: "invoices", file: "packs/billing/app/models/invoice.rb" } }
      )

      text = described_class.call(model: "Invoice", detail: "full").content.first[:text]

      expect(text).to include("- `overdue_by(days)`")
      expect(text).to include("## Class methods")
      expect(text).to include("- `overdue`")
      expect(text).not_to include("example_usage")
      expect(text).not_to include("- `internal`")
    end
  end

  describe "callbacks" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Status" => {
            table_name: "statuses",
            callbacks: { "after_create" => [ "set_poll_id", "[inline_block]" ] }
          }
        }
      )
    end

    it "names the condition a callback runs under" do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Reaction" => {
            table_name: "reactions",
            callbacks: { "after_create" => [ "notify_slack", "bust_cache" ], "before_save" => [ "stamp" ] },
            callback_conditions: { "after_create" => [ { if: '-> { category == "vomit" }' }, nil ],
                                   "before_save" => [ { if: :published? } ] }
          }
        }
      )

      text = described_class.call(model: "Reaction", detail: "full").content.first[:text]

      expect(text).to include(%(:notify_slack (if: -> { category == "vomit" })))
      # `published?` reads as an expression; the line names a method.
      expect(text).to include(":stamp (if: :published?)")
      expect(text).to include("bust_cache")
      expect(text).not_to include("bust_cache (")
    end

    # Rails keeps the two declarations apart, and a lookup keyed by name alone
    # gave both rows the condition of whichever was read last.
    it "keeps one condition per declaration when the same method is declared twice" do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Order" => {
            table_name: "orders",
            callbacks: { "after_save" => %w[sync sync] },
            callback_conditions: { "after_save" => [ { if: :a? }, { if: :b? } ] }
          }
        }
      )

      text = described_class.call(model: "Order", detail: "full").content.first[:text]

      expect(text).to include("- `after_save`: :sync (if: :a?), :sync (if: :b?)")
    end

    it "says when the config leaves transaction callbacks in declaration order" do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Order" => { table_name: "orders", callbacks: { "after_commit" => %w[a b] }, commit_order_unread: true } }
      )

      text = described_class.call(model: "Order", detail: "standard").content.first[:text]

      expect(text).to include("_after_commit and after_rollback for Order are in declaration order")
    end

    # A list of targets is a list of names, so the block keyword read there
    # as a callback named `do`.
    it "names a block callback with the payload's marker" do
      text = described_class.call(model: "Status", detail: "full").content.first[:text]

      expect(text).to include("- `after_create`: :set_poll_id, [inline_block]")
      expect(text).not_to include(", do")
    end
  end

  describe "repeated validations" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Account" => {
            table_name: "accounts",
            validations: [
              { kind: "length", attributes: [ "username" ], options: { maximum: "HARD_LIMIT" } },
              { kind: "length", attributes: [ "username" ], options: { maximum: "LOCAL_LIMIT" } },
              { kind: "length", attributes: [ "username" ], options: { maximum: "HARD_LIMIT" } }
            ]
          }
        }
      )
    end

    # A model can validate one attribute twice under different conditions;
    # collapsing on kind and attribute alone dropped the second rule.
    it "keeps a second declaration on the same attribute and kind" do
      text = described_class.call(model: "Account", detail: "full").content.first[:text]

      expect(text).to include("- `length` on username (maximum: HARD_LIMIT)")
      expect(text).to include("- `length` on username (maximum: LOCAL_LIMIT)")
      expect(text.scan("- `length` on username (maximum: HARD_LIMIT)").size).to eq(1)
    end
  end

  describe "a validation carrying a condition" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Edition" => {
            table_name: "editions",
            validations: [
              { kind: "presence", attributes: [ "title" ], options: { if: :title_required? } },
              { kind: "presence", attributes: [ "body" ], options: { unless: "->(record) { record.is_a?(StandardEdition) }" } },
              { kind: "associated", attributes: [ "unpublishing" ], options: { on: :publish } }
            ]
          }
        }
      )
    end

    # `title_required?` reads as an expression where the file names a method.
    it "keeps a symbol option spelled as the symbol it is" do
      text = described_class.call(model: "Edition", detail: "full").content.first[:text]

      expect(text).to include("- `presence` on title (if: :title_required?)")
      expect(text).to include("- `associated` on unpublishing (on: :publish)")
    end

    it "prints a condition with no literal value as the line the file wrote" do
      text = described_class.call(model: "Edition", detail: "full").content.first[:text]

      expect(text).to include("- `presence` on body (unless: ->(record) { record.is_a?(StandardEdition) })")
    end
  end

  # `belongs_to owner_name` passes a local; printed bare it read as the
  # literal `belongs_to :owner_name`.
  describe "an association whose name is computed" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Group" => {
            table_name: "users",
            associations: [ { type: "belongs_to", name: "owner_name", computed_name: true },
                            { type: "has_many", name: "users" } ]
          }
        }
      )
    end

    it "says the name is computed" do
      text = described_class.call(model: "Group").content.first[:text]

      expect(text).to include("- `belongs_to` **owner_name** (computed)")
      expect(text).to include("- `has_many` **users**")
      expect(text).not_to include("**users** (computed)")
    end
  end

  # `validates_with RecordValidator` has no attributes, so the line read
  # "`document` on " with nothing after it.
  describe "a validates_with and a plugin validation macro" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Document" => {
            table_name: "documents",
            validations: [
              { kind: "validates_date", attributes: [ "date_of_birth" ], options: { presence: true, if: "->(d) { d.approved? }" } },
              { kind: "validates_with", attributes: [], validator: "RecordValidator", options: { on: :create } }
            ]
          }
        }
      )
    end

    it "names the validator class and the macro, each with its options" do
      text = described_class.call(model: "Document").content.first[:text]

      expect(text).to include("- `validates_with` RecordValidator (on: :create)")
      expect(text).to include("- `validates_date` on date_of_birth (presence: true, if: ->(d) { d.approved? })")
      expect(text).not_to match(/on \n/)
    end
  end

  describe "an inclusion list of mixed types" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Edition" => {
            table_name: "editions",
            validations: [
              { kind: "inclusion", attributes: [ "image_display_option" ],
                options: { in: [ "no_image", "organisation_image", "custom_image", nil ] } },
              { kind: "inclusion", attributes: [ "other_display_option" ],
                options: { in: [ "no_image", "organisation_image", "custom_image", nil ] } },
              { kind: "inclusion", attributes: [ "state" ],
                options: { in: [ :draft, 1, "published", nil ] } }
            ]
          }
        }
      )
    end

    it "compresses a repeat of a list whose members are not comparable" do
      text = described_class.call(model: "Edition", detail: "full").content.first[:text]

      expect(text).to include("- `inclusion` on image_display_option (in: [\"no_image\", \"organisation_image\", \"custom_image\", nil])")
      expect(text).to include("(same as image_display_option)")
      expect(text).to include("- `inclusion` on state")
    end
  end

  describe "a model whose only validation is a custom validate method" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Widget" => {
            table_name: "widgets",
            associations: [ { type: "belongs_to", name: "account", optional: true } ],
            validations: [],
            custom_validates: [ "price_is_sane" ]
          }
        }
      )
    end

    it "prints the Validations heading above the custom bullets" do
      text = described_class.call(model: "Widget", detail: "full").content.first[:text]

      expect(text).to include("## Validations")
      expect(text).to match(/## Validations\n- \*\*Custom:\*\* `price_is_sane`/)
    end
  end

  # The builder emits `field:` and `transformation:`; the renderer read
  # `attribute:` and `with:`, so both blocks printed "- **** ...".
  describe "detailed macro blocks" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Keypair" => {
            table_name: "keypairs",
            encryption_details: [ { field: "private_key", options: { deterministic: true } },
                                  { field: "ssn", options: {} } ],
            normalizes_details: [
              { field: "email", transformation: "strip" },
              { field: "phone", transformation: RailsAiContext::Confidence::INFERRED }
            ]
          }
        }
      )
    end

    it "names the encrypted field and its options" do
      text = described_class.call(model: "Keypair", detail: "full").content.first[:text]

      expect(text).to include("## Encryption Details")
      expect(text).to include("- **private_key** (deterministic: true)")
    end

    # Interpolating the options hash printed Hash#to_s, whose format changed
    # in Ruby 3.4, so the same app rendered two different lines.
    it "renders the options as pairs rather than a Ruby hash" do
      text = described_class.call(model: "Keypair", detail: "full").content.first[:text]

      expect(text).not_to include("options: {")
    end

    it "leaves out the parenthesis when the macro carried no options" do
      text = described_class.call(model: "Keypair", detail: "full").content.first[:text]

      expect(text).to include("- **ssn**\n")
      expect(text).not_to include("- **ssn** (")
    end

    it "names the normalized field and its transformation" do
      text = described_class.call(model: "Keypair", detail: "full").content.first[:text]

      expect(text).to include("## Normalizes Details")
      expect(text).to include("- **email** - strip")
    end

    # A transformation the parser could not resolve is a marker, not the name
    # of a transformation, so it never follows the dash.
    it "marks an unresolved transformation instead of naming one" do
      text = described_class.call(model: "Keypair", detail: "full").content.first[:text]

      expect(text).to include("- **phone** [INFERRED]")
      expect(text).not_to include("- **phone** - [INFERRED]")
    end
  end

  # Diaspora's Fetchable defines only `module ClassMethods`; its methods are
  # the concern's, and a nested class's are not.
  it "lists a concern's ClassMethods when it has no instance methods of its own" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns", "federated"))
      File.write(File.join(dir, "app", "models", "concerns", "federated", "fetchable.rb"), <<~RUBY)
        module Federated
          module Fetchable
            module ClassMethods
              def find_or_fetch_by(guid); end
            end

            class Drop
              def each; end
            end
          end
        end
      RUBY
      described_class.reset_cache!
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(dir))
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Post" => { table_name: "posts", concerns: %w[Federated::Fetchable] } }
      )

      text = described_class.call(model: "Post", detail: "full").content.first[:text]

      expect(text).to include("- **Federated::Fetchable** - find_or_fetch_by")
    end
  end

  it "names a declaration a called method makes on another receiver, apart from the model's" do
    described_class.reset_cache!
    allow(described_class).to receive(:cached_context).and_return(
      models: { "Proposal" => { table_name: "proposals",
                                foreign_declarations: [ { declaration: "validates :title, length: { maximum: 80 }",
                                                          receiver: "translation_class", from_concern: "Globalizable" },
                                                        { declaration: "validates :description, presence: true",
                                                          receiver: "translation_class", condition: "options.many?" } ] } }
    )

    text = described_class.call(model: "Proposal", detail: "full").content.first[:text]

    expect(text).to include("## Declared on another class")
    expect(text).to include("- `validates :title, length: { maximum: 80 }` on `translation_class` _(Globalizable)_")
    expect(text).to include("- `validates :description, presence: true` on `translation_class` if `options.many?`")
  end

  it "names a declaration a condition holds back, apart from the counted ones" do
    described_class.reset_cache!
    allow(described_class).to receive(:cached_context).and_return(
      models: { "WorkPackage" => { table_name: "work_packages", associations: [ { type: "has_many", name: "journals" } ],
                                   conditional_declarations: [ { declaration: "has_many :custom_comments",
                                                                 condition: "can_have_custom_comments?",
                                                                 from_concern: "Redmine::Acts::Customizable" } ] } }
    )

    text = described_class.call(model: "WorkPackage", detail: "full").content.first[:text]

    expect(text).to include("## Only under a condition the source does not decide")
    expect(text).to include("- `has_many :custom_comments` if `can_have_custom_comments?` _(Redmine::Acts::Customizable)_")
    expect(text).not_to include("custom_comments (computed)")
  end

  # The footer promises runtime-only data is marked; a concern whose file
  # cannot be found is not runtime-only, it is unread.
  describe "concerns the static tier could not read" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Widget" => {
            table_name: "widgets",
            concerns: %w[Wired Discard::Model],
            concerns_unread: %w[Discard::Model]
          }
        }
      )
    end

    it "names them under the Concerns section" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)

      text = described_class.call(model: "Widget", detail: "full").content.first[:text]

      expect(text).to include("## Concerns")
      expect(text).to include("[UNAVAILABLE] 1 concern not read: Discard::Model")
    end

    # Reflection already answered associations, validations and enums for the
    # concern, so the bare line overstates the gap on this tier.
    it "names the keys the gap covers on the booted tier" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(false)

      text = described_class.call(model: "Widget", detail: "full").content.first[:text]

      expect(text).to include(
        "[UNAVAILABLE] 1 concern not read for scopes, callbacks and macros: Discard::Model"
      )
    end
  end

  # The key hides a concern's declarations along with its name, so a reader
  # comparing the model file against this answer would otherwise call the
  # difference a bug.
  describe "concerns excluded_concerns hid" do
    before { described_class.reset_cache! }

    it "says how many, beside the concerns it did list" do
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Widget" => { table_name: "widgets", concerns: %w[Wired], concerns_hidden: 2 } }
      )

      text = described_class.call(model: "Widget", detail: "full").content.first[:text]

      expect(text).to include("## Concerns")
      expect(text).to include("- Wired")
      expect(text).to include("_2 concerns hidden by `excluded_concerns`._")
    end

    # The section is keyed off the concerns it can name, so a model whose only
    # concern was hidden had nowhere to say so.
    it "says so when every concern was hidden" do
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Widget" => { table_name: "widgets", concerns: [], concerns_hidden: 1 } }
      )

      text = described_class.call(model: "Widget", detail: "full").content.first[:text]

      expect(text).to include("_1 concern hidden by `excluded_concerns`._")
    end

    it "says nothing when the key hid none" do
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Widget" => { table_name: "widgets", concerns: %w[Wired] } }
      )

      text = described_class.call(model: "Widget", detail: "full").content.first[:text]

      expect(text).not_to include("excluded_concerns")
    end
  end

  # An STI child carries its base's declarations, so a base the walk could not
  # read is a gap the reader has to be told about even when the child includes
  # no concern at all.
  describe "a base class the tier could not read" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Article" => { table_name: "posts", concerns: [], bases_unread: %w[Post] } }
      )
    end

    it "names it outside the Concerns section" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)

      text = described_class.call(model: "Article", detail: "full").content.first[:text]

      expect(text).to include("[UNAVAILABLE] 1 base class not read: Post")
      # The chain link is written in the file the walk could not open, so the
      # classes above it are out of reach too, and the line says so.
      expect(text).to include("cannot follow the chain past a file it could not read")
      expect(text).not_to include("## Concerns")
    end

    it "names the keys the gap covers on the booted tier" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(false)

      text = described_class.call(model: "Article", detail: "full").content.first[:text]

      expect(text).to include(
        "[UNAVAILABLE] 1 base class not read for scopes, callbacks and macros: Post"
      )
    end
  end

  # The path a gem-owned model carries names the gem, not the app, so joining
  # it to the app root opened nothing and the model lost its structure.
  describe "a model whose file belongs to a gem" do
    let(:gem_file) do
      File.join(Gem.loaded_specs["activesupport"].full_gem_path,
                "lib", "active_support", "notifications.rb")
    end

    it "reads the file the gem marker names" do
      marked = RailsAiContext::PortablePath.relativize_marked(gem_file, Rails.root.to_s)
      allow(described_class).to receive(:cached_context).and_return({
        models: { "Doorkeeper::AccessGrant" => {
          name: "Doorkeeper::AccessGrant", table_name: "oauth_access_grants",
          file: marked, associations: [], validations: []
        } }
      })

      text = described_class.call(model: "Doorkeeper::AccessGrant").content.first[:text]

      expect(marked).to start_with("gem:")
      expect(text).to include("**File:** `#{marked}`")
      expect(text).to match(/\*\*Structure:\*\* .+/)
    end
  end
  # Two caps sit between the model's methods and the page: the payload lists
  # thirty, and the renderer prints twenty-five. A reader who takes the list
  # as the model's whole interface gets it wrong, and diagnose did.
  describe "a model with more methods than the page lists" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Widget" => {
            table_name: "widgets",
            associations: [],
            instance_methods: (1..30).map { |i| "step_#{format('%02d', i)}" },
            instance_method_count: 72
          }
        },
        schema: { tables: { "widgets" => { columns: [ { name: "title", type: "string" } ] } } }
      )
    end

    it "says how many of the listed methods it is showing" do
      text = described_class.call(model: "Widget").content.first[:text]

      expect(text).to include("## Key instance methods (25 of 30)")
    end

    # The heading's two numbers describe the filtered list; the model's own
    # total is a different set and says so on its own line.
    it "says the same about the class-method list" do
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Widget" => {
            table_name: "widgets", associations: [],
            class_methods: %w[search_by import_from_csv],
            class_method_count: 41
          }
        },
        schema: { tables: { "widgets" => { columns: [ { name: "title", type: "string" } ] } } }
      )

      text = described_class.call(model: "Widget").content.first[:text]

      expect(text).to include("## Class methods")
      expect(text).to include("41 class methods")
    end

    it "names the model's whole method count apart from the list" do
      text = described_class.call(model: "Widget").content.first[:text]

      expect(text).to include("72 instance methods")
      # Markdown folds a line straight after a bullet into that bullet.
      expect(text).to include("`\n\n_Reflection reports 72 instance methods")
    end

    # The static count comes from the source parse, so crediting it to
    # reflection claims a boot that never happened.
    it "credits the count to the source on the static tier" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)

      text = described_class.call(model: "Widget").content.first[:text]

      expect(text).to include("The source defines 72 instance methods on Widget")
      expect(text).not_to include("Reflection reports")
    end
  end
end
