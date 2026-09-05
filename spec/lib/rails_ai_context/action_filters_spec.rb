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

  it "answers empty lists for an unknown controller" do
    expect(described_class.for(context, "Nope", "show")).to eq({ own: [], inherited: [], skipped: [] })
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
end
