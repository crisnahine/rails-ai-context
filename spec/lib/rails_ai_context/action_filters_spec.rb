# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::ActionFilters do
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

    before { allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root)) }

    it "names every filter a skip lists, when the skip applies to the action" do
      expect(described_class.for(context, "PostsController", "show")[:skipped]).to eq(%w[authenticate verify_token])
      expect(described_class.for(context, "PostsController", "index")[:skipped]).to eq(%w[track])
    end

    it "drops a skipped filter from own and inherited" do
      result = described_class.for(context, "PostsController", "show")
      expect(result[:inherited]).to eq([])
      expect(result[:own].map { |f| f[:name] }).to eq(%w[set_post track])
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
  end
end
