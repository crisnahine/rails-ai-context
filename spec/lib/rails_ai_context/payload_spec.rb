# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Payload do
  describe "key pinning" do
    # Every reader's key pair, checked against what the producing
    # introspector actually emits for the static fixture app. A payload
    # rename now fails here, loudly, instead of silently emptying a section
    # in every consumer (the #144/#145 class).
    it "names only keys the producing introspector emits" do
      fixture_root = File.expand_path("../../fixtures/static_app", __dir__)
      static_app = RailsAiContext::StaticApp.new(fixture_root)

      emitted = {}
      described_class::LISTS.each do |reader, (section_key, key)|
        emitted[section_key] ||= begin
          klass = RailsAiContext::Introspector::INTROSPECTOR_MAP.fetch(section_key)
          result = case klass.static_tier
          when RailsAiContext::Introspectors::StaticTier::ALTERNATE_SOURCE
            klass.new(static_app).send(:static_call)
          when RailsAiContext::Introspectors::StaticTier::RUNTIME_ONLY
            # No static answer to walk, so the walk stays honest by asking
            # the booted app instead of skipping the row.
            klass.new(Rails.application).call
          else
            klass.new(static_app).call
          end
          result.keys
        end

        expect(emitted[section_key]).to include(key),
          "Payload.#{reader} reads #{section_key}[:#{key}], but the introspector emits: #{emitted[section_key].join(', ')}"
      end
    end
  end

  describe ".architecture and .patterns" do
    it "answer the conventions lists the booted app emits" do
      conventions = RailsAiContext::Introspectors::ConventionIntrospector.new(Rails.application).call
      ctx = { conventions: conventions }

      expect(described_class.architecture(ctx)).to eq(conventions[:architecture])
      expect(described_class.patterns(ctx)).to eq(conventions[:patterns])
    end

    it "answer an empty list for a failed conventions section" do
      expect(described_class.architecture({ conventions: { error: "boom" } })).to eq([])
      expect(described_class.patterns({ conventions: { error: "boom" } })).to eq([])
    end
  end

  describe ".section" do
    it "answers the section only when it is a healthy hash" do
      expect(described_class.section({ turbo: { turbo_frames: [] } }, :turbo)).to eq({ turbo_frames: [] })
      expect(described_class.section({ turbo: { error: "boom" } }, :turbo)).to be_nil
      expect(described_class.section({ turbo: [] }, :turbo)).to be_nil
      expect(described_class.section({}, :turbo)).to be_nil
      expect(described_class.section(nil, :turbo)).to be_nil
    end
  end

  describe ".list" do
    it "always answers an array" do
      expect(described_class.list({ turbo: { turbo_frames: %w[f] } }, :turbo, :turbo_frames)).to eq(%w[f])
      expect(described_class.list({ turbo: {} }, :turbo, :turbo_frames)).to eq([])
      expect(described_class.list({}, :turbo, :turbo_frames)).to eq([])
    end
  end
  describe ".view_ivars" do
    it "reads the ivars a template uses from the view templates section" do
      ctx = IntrospectedFixture.context
      expect(described_class.view_ivars(ctx, "posts/index")).to include("posts")
      expect(described_class.view_ivars(ctx, "nope/nope")).to eq(Set.new)
    end
  end

  describe ".controller_route_key" do
    def ctx(file)
      { controllers: { controllers: { "InvoicesController" => { file: file } } } }
    end

    it "reads the route key from the file the controller was read from" do
      expect(described_class.controller_route_key(ctx("app/controllers/admin/invoices_controller.rb"), "InvoicesController"))
        .to eq("admin/invoices")
    end

    # A pack or an in-repo engine puts the controllers root somewhere other
    # than the start of the path, and Rails still routes by what follows it.
    it "strips a controllers root that is not at the start of the path" do
      expect(described_class.controller_route_key(ctx("packs/billing/app/controllers/invoices_controller.rb"), "InvoicesController"))
        .to eq("invoices")
    end

    # Rails does not require the _controller suffix on the filename, and
    # leaving .rb on the key sent every path derived from it one directory
    # deep into a file.
    it "strips a plain .rb from a file that does not carry the suffix" do
      expect(described_class.controller_route_key(ctx("app/controllers/invoices.rb"), "InvoicesController"))
        .to eq("invoices")
    end

    # The name is all there is for a controller reflection found and the
    # filesystem did not - and it is right whenever no inflection is involved.
    it "falls back to the underscored name when no file was carried" do
      expect(described_class.controller_route_key({}, "Admin::InvoicesController")).to eq("admin/invoices")
    end
  end
  # A view directory is the route key: app/views/activitypub/ is rendered by
  # whatever controller Rails routes as activitypub, and camelizing that back
  # gives Activitypub, which is not the name Mastodon declares.
  describe ".controller_for_route_key" do
    let(:context) do
      {
        controllers: {
          controllers: {
            "ActivityPub::InboxesController" => { file: "app/controllers/activitypub/inboxes_controller.rb" },
            "Admin::BadgesController" => { file: "app/controllers/admin/badges_controller.rb" }
          }
        }
      }
    end

    it "finds a controller whose declared name does not camelize from its path" do
      name, data = described_class.controller_for_route_key(context, "activitypub/inboxes")
      expect(name).to eq("ActivityPub::InboxesController")
      expect(data[:file]).to eq("app/controllers/activitypub/inboxes_controller.rb")
    end

    it "finds a namespaced controller by its path" do
      expect(described_class.controller_for_route_key(context, "admin/badges").first)
        .to eq("Admin::BadgesController")
    end

    it "returns nil for a directory no controller serves" do
      expect(described_class.controller_for_route_key(context, "nope")).to be_nil
    end

    # The index is one slot. A second context must not be answered from the
    # first one's controllers.
    it "reindexes when the context changes" do
      described_class.controller_for_route_key(context, "admin/badges")
      other = { controllers: { controllers: { "OrdersController" => { file: "app/controllers/orders_controller.rb" } } } }

      expect(described_class.controller_for_route_key(other, "orders").first).to eq("OrdersController")
      expect(described_class.controller_for_route_key(other, "admin/badges")).to be_nil
    end

    # Two ivars checked and read apart let a thread pass the identity check
    # and then read an index another thread had already rebuilt.
    it "holds the hash it indexed and the index in a single slot" do
      described_class.controller_for_route_key(context, "admin/badges")

      expect(described_class.instance_variables.grep(/route_key|indexed/))
        .to contain_exactly(:@route_key_memo)
    end

    it "never answers a name from a context it was not asked about" do
      other = { controllers: { controllers: { "OrdersController" => { file: "app/controllers/orders_controller.rb" } } } }
      answers = Queue.new

      threads = [
        Thread.new { 200.times { answers << described_class.controller_for_route_key(context, "admin/badges")&.first } },
        Thread.new { 200.times { answers << described_class.controller_for_route_key(other, "orders")&.first } }
      ]
      threads.each(&:join)

      expect(Array.new(answers.size) { answers.pop }.uniq.sort)
        .to eq([ "Admin::BadgesController", "OrdersController" ])
    end
  end
  # The reverse trip: a checker walking app/models/oauth_client_config.rb has
  # to find the model it declares, and camelizing the path gives
  # OauthClientConfig - a constant the app does not have.
  describe ".model_for_file" do
    let(:context) do
      { models: { "OAuthClientConfig" => { file: "app/models/oauth_client_config.rb", table_name: "oauth_client_configs" } } }
    end

    it "finds the model a file declares" do
      name, data = described_class.model_for_file(context, "app/models/oauth_client_config.rb")
      expect(name).to eq("OAuthClientConfig")
      expect(data[:table_name]).to eq("oauth_client_configs")
    end

    it "returns nil for a file no model was read from" do
      expect(described_class.model_for_file(context, "app/models/nope.rb")).to be_nil
    end
  end

  # A model's file is carried for the same reason a controller's is: rebuilding
  # app/models/<underscored>.rb misses a pack, an engine, and any inflection.
  describe ".model_file" do
    let(:context) { { models: { "Invoice" => { file: "packs/billing/app/models/invoice.rb" } } } }

    it "reads the file the model was read from" do
      expect(described_class.model_file(context, "Invoice")).to eq("packs/billing/app/models/invoice.rb")
    end

    it "falls back to the conventional path for a model that carried none" do
      expect(described_class.model_file({ models: { "Order" => {} } }, "Order")).to eq("app/models/order.rb")
    end
  end

  describe ".section on an unavailable section" do
    it "answers nil for a section the static tier refused" do
      expect(described_class.section({ config: { unavailable: "requires a booted Rails app" } }, :config)).to be_nil
    end
  end

  describe ".controllers and .app_controllers" do
    let(:context) do
      { controllers: { controllers: {
        "PostsController" => { actions: %w[index] },
        "DeviseController" => { actions: %w[new] },
        "Admin::BaseController" => { actions: [] }
      } } }
    end

    it "reads the wrapped controllers hash" do
      expect(described_class.controllers(context).keys).to contain_exactly("PostsController", "DeviseController", "Admin::BaseController")
      expect(described_class.controllers({})).to eq({})
      expect(described_class.controllers({ controllers: { error: "boom" } })).to eq({})
    end

    it "drops the configured framework controllers, default and user-added" do
      expect(described_class.app_controllers(context).keys).to contain_exactly("PostsController", "Admin::BaseController")

      RailsAiContext.configuration.excluded_controllers += %w[Admin::BaseController]
      expect(described_class.app_controllers(context).keys).to eq(%w[PostsController])
    ensure
      RailsAiContext.configuration.excluded_controllers -= %w[Admin::BaseController]
    end
  end

  describe ".models" do
    it "reads the bare models hash and answers {} for a failed one" do
      expect(described_class.models({ models: { "Post" => {} } })).to eq({ "Post" => {} })
      expect(described_class.models({ models: { error: "boom" } })).to eq({})
      expect(described_class.models({})).to eq({})
    end
  end

  describe ".gem?" do
    it "answers from the notable gems the introspector emits" do
      ctx = { gems: { notable_gems: [ { name: "devise", version: "4.9.4" } ] } }
      expect(described_class.gem?(ctx, "devise")).to be true
      expect(described_class.gem?(ctx, "sorcery")).to be false
      expect(described_class.gem?({}, "devise")).to be false
    end
  end

  # A job in a pack has no conventional path to fall back to, so these
  # answer only what the tier recorded.
  describe ".job_file and .mailer_file" do
    let(:context) do
      { jobs: {
        jobs: [ { name: "InvoiceJob", file: "packs/billing/app/jobs/invoice_job.rb" }, { name: "PlacelessJob" } ],
        mailers: [ { name: "UserMailer", file: "app/mailers/user_mailer.rb" } ]
      } }
    end

    it "reads the file a job was read from" do
      expect(described_class.job_file(context, "InvoiceJob")).to eq("packs/billing/app/jobs/invoice_job.rb")
    end

    it "reads the file a mailer was read from" do
      expect(described_class.mailer_file(context, "UserMailer")).to eq("app/mailers/user_mailer.rb")
    end

    it "answers nil for an entry that carried none, and for a name nobody recorded" do
      expect(described_class.job_file(context, "PlacelessJob")).to be_nil
      expect(described_class.job_file(context, "Nope")).to be_nil
      expect(described_class.mailer_file({}, "UserMailer")).to be_nil
    end
  end
end
