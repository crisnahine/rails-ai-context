# frozen_string_literal: true

require "spec_helper"
require "shellwords"

RSpec.describe RailsAiContext::ActionFilters do
  # The gem is required on its own by the standalone binary and by any
  # consumer outside a booted app, so no entry point may reach for `Rails`
  # before a payload asks for a file.
  it "answers without a Rails constant in the process" do
    root = File.expand_path("../../..", __dir__)
    script = [
      "$LOAD_PATH.unshift #{File.join(root, 'lib').inspect}",
      'require "rails_ai_context"',
      'puts RailsAiContext::ActionFilters.for({}, "Nope", :show).inspect'
    ].join("\n")

    output = `ruby -e #{script.shellescape} 2>&1`

    expect(output).to include("{own: [], inherited: [], skipped: []}").or include("{:own=>[], :inherited=>[], :skipped=>[]}")
    expect($?.exitstatus).to eq(0)
  end

  let(:context) do
    { controllers: { controllers: {
      "ApplicationController" => { filters: [ { kind: "before_action", name: "authenticate" } ], file: "app/controllers/application_controller.rb" },
      "PostsController" => {
        parent_class: "ApplicationController",
        filters: [
          { kind: "before_action", name: "authenticate" },
          { kind: "before_action", name: "set_post", only: %w[show edit] },
          { kind: "after_action", name: "track", except: %w[index] }
        ],
        file: "app/controllers/posts_controller.rb"
      }
    } } }
  end

  it "applies only and except to the action" do
    result = described_class.for(context, "PostsController", "show")
    expect(result[:own].map { |f| f[:name] }).to eq(%w[set_post track])
    expect(described_class.for(context, "PostsController", "index")[:own].map { |f| f[:name] }).to eq([])
  end

  it "reports the parent's filters as inherited, not own" do
    result = described_class.for(context, "PostsController", "show")
    expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate])
  end

  # An ancestor's own skip record joined the dropped set only after its own
  # filters had been selected, so the skip was reported as a filter the child
  # runs. Mastodon's Api::BaseController skips require_functional! and every
  # Api::V1 controller listed it as inherited.
  it "never reports an ancestor's skip as a filter the child runs" do
    ctx = { controllers: { controllers: {
      "ApplicationController" => { filters: [ { kind: "before", name: "require_functional!" } ] },
      "Api::BaseController" => {
        parent_class: "ApplicationController",
        filters: [ { kind: "before", name: "require_functional!", skipped: true } ]
      },
      "Api::V1::AccountsController" => { parent_class: "Api::BaseController", filters: [] }
    } } }

    result = described_class.for_controller(ctx, "Api::V1::AccountsController")

    expect(result[:inherited].map { |f| f[:name] }).to eq([])
    expect(result[:own]).to eq([])
  end

  # A skip record carries the skip's own only:/except:, so it covers those
  # actions only. Reading the flag without the constraint hid the filter
  # from every action of the class.
  describe "a skip record constrained to some actions" do
    let(:constrained_context) do
      { controllers: { controllers: {
        "AdminController" => { filters: [ { kind: "before", name: "authenticate_admin!" } ] },
        "ReportsController" => {
          parent_class: "AdminController",
          actions: %w[index show],
          filters: [ { kind: "before", name: "authenticate_admin!", skipped: true, only: %w[index] } ]
        }
      } } }
    end

    it "reports the filter skipped for an action the skip names" do
      result = described_class.for(constrained_context, "ReportsController", "index")

      expect(result[:skipped]).to eq(%w[authenticate_admin!])
      expect(result[:own]).to eq([])
      expect(result[:inherited]).to eq([])
    end

    it "still inherits the filter for an action the skip does not cover" do
      result = described_class.for(constrained_context, "ReportsController", "show")

      expect(result[:skipped]).to eq([])
      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[authenticate_admin! AdminController] ])
    end
  end

  # The payload the CLI builds without booting, from real files, through the
  # introspector that sets the skip flag.
  describe "a constrained skip in a payload the static tier built" do
    it "keeps the filter for the action the skip leaves alone" do
      Dir.mktmpdir("action-filters-static") do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/reports_controller.rb"), <<~RUBY)
          class ReportsController < ApplicationController
            before_action :authenticate_admin!
            skip_before_action :authenticate_admin!, only: [ :index ]

            def index; end

            def show; end
          end
        RUBY

        payload = RailsAiContext::Introspectors::ControllerIntrospector
          .new(RailsAiContext::StaticApp.new(dir)).static_call
        ctx = { controllers: payload }

        show = described_class.for(ctx, "ReportsController", "show", root: dir)
        index = described_class.for(ctx, "ReportsController", "index", root: dir)

        expect(show[:skipped]).to eq([])
        expect(show[:own].map { |f| f[:name] }).to eq(%w[authenticate_admin!])
        expect(index[:skipped]).to eq(%w[authenticate_admin!])
        expect(index[:own]).to eq([])
      end
    end
  end

  it "answers empty lists for an unknown controller" do
    expect(described_class.for(context, "Nope", "show")).to eq({ own: [], inherited: [], skipped: [] })
  end

  # An ancestor's skip joined the dropped set only after that ancestor's own
  # list had been collected, so the class that skips a filter still handed it
  # down. In the booted tier that list is the reflection list, which carries
  # every inherited name, so the skipping class itself contributed it.
  describe "an ancestor that skips a filter it also carries" do
    around do |example|
      Dir.mktmpdir("action-filters-own-skip") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers/admin"))
        File.write(File.join(dir, "app/controllers/admin/base_controller.rb"), <<~RUBY)
          module Admin
            class BaseController < ApplicationController
              skip_before_action :authenticate!, only: [ :index ]
              before_action :require_admin
            end
          end
        RUBY
        example.run
      end
    end

    let(:skipping_context) do
      { controllers: { controllers: {
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [
            { kind: "before", name: "authenticate!" },
            { kind: "before", name: "require_admin" }
          ],
          file: "app/controllers/admin/base_controller.rb"
        },
        "Admin::ReportsController" => { parent_class: "Admin::BaseController", filters: [] }
      } } }
    end

    it "does not hand the filter to a child on an action the skip covers" do
      result = described_class.for(skipping_context, "Admin::ReportsController", "index", root: @root)

      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[require_admin])
    end

    it "still hands it down on an action the skip leaves alone" do
      result = described_class.for(skipping_context, "Admin::ReportsController", "show", root: @root)

      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate! require_admin])
    end

    # The booted tier gives every class the whole chain by reflection, so the
    # child's own list carries the name its parent skipped. Subtracting the
    # skip from the walk alone left it in the child's own filters.
    it "does not report it as the child's own filter either" do
      skipping_context[:controllers][:controllers]["Admin::ReportsController"][:filters] =
        [ { kind: "before", name: "authenticate!" }, { kind: "before", name: "require_admin" } ]

      result = described_class.for(skipping_context, "Admin::ReportsController", "index", root: @root)

      expect(result[:own].map { |f| f[:name] }).to eq([])
      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[require_admin])
    end

    # A class that declares the filter again in its own body runs it, whatever
    # an ancestor skipped.
    it "keeps a filter the child declares itself" do
      skipping_context[:controllers][:controllers]["Admin::ReportsController"][:filters] =
        [ { kind: "before", name: "authenticate!", declared: true } ]

      result = described_class.for(skipping_context, "Admin::ReportsController", "index", root: @root)

      expect(result[:own].map { |f| f[:name] }).to eq(%w[authenticate!])
    end
  end

  # Ruby resolves a bare superclass from the enclosing namespace outward, so
  # `class ReportsController < BaseController` inside `module Admin` carries
  # the parent as written. Looking that up verbatim found nothing and the
  # whole inherited chain vanished from the answer.
  describe "a parent spelled relatively to its namespace" do
    let(:relative_context) do
      { controllers: { controllers: {
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before", name: "require_admin" }, { kind: "after", name: "audit" } ]
        },
        "Admin::ReportsController" => {
          parent_class: "BaseController",
          filters: [ { kind: "before", name: "load_report", except: %w[index] } ]
        }
      } } }
    end

    it "resolves it against the enclosing namespace" do
      result = described_class.for_controller(relative_context, "Admin::ReportsController")

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[require_admin Admin::BaseController], %w[audit Admin::BaseController] ])
    end
  end

  describe ".for_controller" do
    it "keeps every declared filter, whatever action it constrains itself to" do
      result = described_class.for_controller(context, "PostsController")
      expect(result[:own].map { |f| f[:name] }).to eq(%w[set_post track])
      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[authenticate])
    end

    it "answers empty lists for an unknown controller" do
      expect(described_class.for_controller(context, "Nope")).to eq({ own: [], inherited: [], skipped: [] })
    end
  end

  describe "source: keyword" do
    it "reads the skips from the source it is handed instead of the file" do
      source = "class PostsController\n  skip_before_action :authenticate\nend\n"
      result = described_class.for(context, "PostsController", "show", source: source)
      expect(result[:skipped]).to eq(%w[authenticate])
      expect(result[:inherited]).to eq([])
    end

    it "names a filter a skip lists as a string" do
      source = %(class PostsController\n  skip_before_action "authenticate"\nend\n)
      expect(described_class.for_controller(context, "PostsController", source: source)[:skipped]).to eq(%w[authenticate])
    end
  end

  context "skips read from the carried file" do
    around do |example|
      Dir.mktmpdir("action-filters") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/posts_controller.rb"), <<~RUBY)
          class PostsController < ApplicationController
            skip_before_action :authenticate, :verify_token, only: %i[show]
            skip_after_action :track, except: %i[show]
          end
        RUBY
        example.run
      end
    end

    it "names every filter a skip lists, when the skip applies to the action" do
      expect(described_class.for(context, "PostsController", "show", root: @root)[:skipped]).to eq(%w[authenticate verify_token])
      expect(described_class.for(context, "PostsController", "index", root: @root)[:skipped]).to eq(%w[track])
    end

    it "drops a skipped filter from own and inherited" do
      result = described_class.for(context, "PostsController", "show", root: @root)
      expect(result[:inherited]).to eq([])
      expect(result[:own].map { |f| f[:name] }).to eq(%w[set_post track])
    end
  end

  # SourceScan carries the spelling the app uses, not the realpath, so a
  # symlinked pack's file is outside the root by realpath and only a reader
  # that trusts the carried path can open it.
  context "a controller in a pack symlinked out of the root" do
    it "reads the skips out of the carried file" do
      skip "symlinks unavailable" unless File.respond_to?(:symlink?)

      Dir.mktmpdir("outside-pack") do |outside|
        Dir.mktmpdir("pack-root") do |root|
          FileUtils.mkdir_p(File.join(outside, "billing", "app", "controllers"))
          File.write(File.join(outside, "billing", "app", "controllers", "billing_controller.rb"), <<~RUBY)
            class BillingController < ApplicationController
              skip_before_action :authenticate
            end
          RUBY
          File.symlink(outside, File.join(root, "packs"))

          ctx = { controllers: { controllers: {
            "ApplicationController" => { filters: [ { kind: "before_action", name: "authenticate" } ] },
            "BillingController" => {
              parent_class: "ApplicationController",
              filters: [],
              file: "packs/billing/app/controllers/billing_controller.rb"
            }
          } } }

          expect(described_class.for_controller(ctx, "BillingController", root: root)[:skipped]).to eq(%w[authenticate])
        end
      end
    end
  end

  # In the static tier each controller's list holds only its own
  # declarations, so a filter two levels up is reached only by walking.
  describe "an ancestor chain deeper than one level" do
    let(:deep_context) do
      { controllers: { controllers: {
        "ApplicationController" => { filters: [ { kind: "before_action", name: "authenticate" } ] },
        "Admin::BaseController" => {
          parent_class: "ApplicationController",
          filters: [ { kind: "before_action", name: "require_admin" } ]
        },
        "Admin::PostsController" => { parent_class: "Admin::BaseController", filters: [] }
      } } }
    end

    it "carries the grandparent's filter into inherited" do
      result = described_class.for_controller(deep_context, "Admin::PostsController")

      expect(result[:inherited].map { |f| f[:name] }).to eq(%w[require_admin authenticate])
    end

    it "lists a filter the closer ancestor redeclares once" do
      deep_context[:controllers][:controllers]["Admin::BaseController"][:filters] <<
        { kind: "before_action", name: "authenticate", only: %w[index] }

      names = described_class.for_controller(deep_context, "Admin::PostsController")[:inherited].map { |f| f[:name] }
      expect(names.count("authenticate")).to eq(1)
      expect(names).to eq(%w[require_admin authenticate])
    end

    it "stops at the first ancestor the payload does not carry" do
      deep_context[:controllers][:controllers].delete("ApplicationController")

      expect(described_class.for_controller(deep_context, "Admin::PostsController")[:inherited].map { |f| f[:name] })
        .to eq(%w[require_admin])
    end

    it "names the ancestor each inherited filter was found on" do
      result = described_class.for_controller(deep_context, "Admin::PostsController")

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[require_admin Admin::BaseController], %w[authenticate ApplicationController] ])
    end

    # A booted ancestor's list carries every inherited name, so the nearest
    # entry holding a filter is not the one that declared it. The record the
    # class declared in its own body says which.
    it "names the ancestor that declared it over one that only carries it" do
      deep_context[:controllers][:controllers]["ApplicationController"][:filters] =
        [ { kind: "before_action", name: "authenticate", declared: true } ]
      deep_context[:controllers][:controllers]["Admin::BaseController"][:filters] =
        [ { kind: "before_action", name: "authenticate" },
          { kind: "before_action", name: "require_admin", declared: true } ]

      result = described_class.for_controller(deep_context, "Admin::PostsController")

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[authenticate ApplicationController], %w[require_admin Admin::BaseController] ])
    end

    # A skip in a class between the child and the declaring ancestor stops
    # the filter as surely as one in the child's own body.
    context "when an intermediate ancestor skips the grandparent's filter" do
      around do |example|
        Dir.mktmpdir("action-filters-chain") do |dir|
          @root = dir
          FileUtils.mkdir_p(File.join(dir, "app/controllers/admin"))
          File.write(File.join(dir, "app/controllers/admin/base_controller.rb"), <<~RUBY)
            class Admin::BaseController < ApplicationController
              skip_before_action :authenticate
            end
          RUBY
          example.run
        end
      end

      before do
        deep_context[:controllers][:controllers]["Admin::BaseController"][:file] =
          "app/controllers/admin/base_controller.rb"
      end

      it "does not carry it into the child's inherited list" do
        result = described_class.for_controller(deep_context, "Admin::PostsController", root: @root)

        expect(result[:inherited].map { |f| f[:name] }).to eq(%w[require_admin])
      end
    end
  end

  # Rails removes the callback at the skip and re-adds it at the next line, so
  # the later record decides. Reporting the name as skipped said an auth
  # filter does not run on an action where it does.
  describe "a class body that skips a filter and then declares it again" do
    around do |example|
      Dir.mktmpdir("action-filters-redeclare") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/public_controller.rb"), <<~RUBY)
          class PublicController < ApplicationController
            skip_before_action :authenticate_user!
            before_action :authenticate_user!, only: [ :admin ]

            def index; end
            def admin; end
          end
        RUBY
        example.run
      end
    end

    let(:redeclare_context) do
      { controllers: { controllers: {
        "PublicController" => {
          parent_class: "ApplicationController",
          filters: [
            { kind: "before", name: "authenticate_user!", skipped: true },
            { kind: "before", name: "authenticate_user!", only: %w[admin] }
          ],
          file: "app/controllers/public_controller.rb"
        },
        "ChildController" => { parent_class: "PublicController", filters: [] }
      } } }
    end

    it "runs the re-declared filter on the action it names" do
      result = described_class.for(redeclare_context, "PublicController", "admin", root: @root)

      expect(result[:own].map { |f| f[:name] }).to eq(%w[authenticate_user!])
      expect(result[:skipped]).to eq([])
    end

    it "still reports the skip on an action the re-declaration leaves out" do
      result = described_class.for(redeclare_context, "PublicController", "index", root: @root)

      expect(result[:own]).to eq([])
      expect(result[:skipped]).to eq(%w[authenticate_user!])
    end

    it "hands the re-declared filter down to a child" do
      result = described_class.for(redeclare_context, "ChildController", "admin", root: @root)

      expect(result[:inherited].map { |f| [ f[:name], f[:from] ] })
        .to eq([ %w[authenticate_user! PublicController] ])
    end

    it "keeps a plain skip of a filter it never re-declares out of the child" do
      redeclare_context[:controllers][:controllers]["PublicController"][:filters] =
        [ { kind: "before", name: "authenticate_user!", skipped: true } ]

      result = described_class.for(redeclare_context, "ChildController", "admin")

      expect(result[:inherited]).to eq([])
    end
  end
end
