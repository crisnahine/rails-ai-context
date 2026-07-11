# frozen_string_literal: true

require_relative "e2e_helper"
require "open3"

# Nonstandard app shapes: packwerk packs/, in-repo engines/, Rails 8
# multi-database schema dumps, Mongoid apps, and auto_mount from a user
# initializer. One shared app, mutated per example group and cleaned up,
# plus a bare fake directory for the Mongoid case (static tier needs no
# bootable app at all).
RSpec.describe "E2E: app shapes", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "shapes_app",
      install_path: :in_gemfile
    ).build!
    @cli = E2E::CliRunner.new(@builder)
  end

  describe "packs and engines code discovery (static tier)" do
    before(:all) do
      pack_models = File.join(@builder.app_path, "packs", "billing", "app", "models")
      engine_controllers = File.join(@builder.app_path, "engines", "store", "app", "controllers", "store")
      FileUtils.mkdir_p(pack_models)
      FileUtils.mkdir_p(engine_controllers)
      File.write(File.join(pack_models, "invoice.rb"),
                 "class Invoice < ApplicationRecord\n  belongs_to :customer\nend\n")
      File.write(File.join(engine_controllers, "orders_controller.rb"),
                 "class Store::OrdersController < ActionController::Base\n  def index; end\nend\n")
    end

    after(:all) do
      FileUtils.rm_rf(File.join(@builder.app_path, "packs"))
      FileUtils.rm_rf(File.join(@builder.app_path, "engines"))
    end

    it "finds a packs model" do
      # model_details takes the model name via --model (see
      # spec/e2e/tool_edge_cases_spec.rb), not a bare positional arg.
      result = @cli.cli_tool("model_details", [ "--model", "Invoice", "--no-boot" ])
      expect(result.exit_status).to eq(0), result.to_s
      expect(result.stdout).to include("Invoice")
      expect(result.stdout).to include("customer")
    end

    it "finds an in-repo engine controller" do
      result = @cli.cli_tool("controllers", [ "--no-boot" ])
      expect(result.exit_status).to eq(0), result.to_s
      expect(result.stdout).to include("Store::OrdersController")
    end
  end

  describe "multi-database schema dumps" do
    before(:all) do
      File.write(File.join(@builder.app_path, "db", "queue_schema.rb"), <<~RUBY)
        ActiveRecord::Schema[7.2].define(version: 1) do
          create_table "solid_queue_jobs" do |t|
            t.string "queue_name", null: false
          end
        end
      RUBY
    end

    after(:all) do
      FileUtils.rm_f(File.join(@builder.app_path, "db", "queue_schema.rb"))
    end

    it "reports the queue database alongside the primary schema" do
      result = @cli.cli_tool("schema", [ "--no-boot" ])
      expect(result.exit_status).to eq(0), result.to_s
      expect(result.stdout).to include("Secondary databases")
      expect(result.stdout).to include("queue")
      expect(result.stdout).to include("solid_queue_jobs")
    end
  end

  describe "Mongoid app (bare directory, --app-path, no boot possible)" do
    before(:all) do
      @mongoid_dir = Dir.mktmpdir("mongoid_app")
      FileUtils.mkdir_p(File.join(@mongoid_dir, "config"))
      FileUtils.mkdir_p(File.join(@mongoid_dir, "app", "models"))
      File.write(File.join(@mongoid_dir, "config", "mongoid.yml"), "development:\n  clients: {}\n")
      File.write(File.join(@mongoid_dir, "app", "models", "customer.rb"), <<~RUBY)
        class Customer
          include Mongoid::Document
          field :name, type: String
          embeds_many :orders
        end
      RUBY
    end

    after(:all) { FileUtils.rm_rf(@mongoid_dir) }

    # CliRunner#run always chdirs into the *primary* test app before running
    # a command, so it can't target a second, unrelated directory. Build the
    # same command line CliRunner would build and run it directly via Open3
    # from outside both app directories - the only way to prove --app-path
    # (not an ambient cwd match) resolves this bare Mongoid dir. cli_prefix
    # is private (see spec/e2e/static_tier_spec.rb's "--app-path from
    # outside the app directory" example for the same pattern). Flag order
    # matters: --app-path/--no-boot must precede the tool name because
    # `stop_on_unknown_option! :tool` only starts passing tokens straight
    # through as tool args once it hits the first positional (the name).
    def run_against_mongoid(*tool_args)
      cmd = @cli.send(:cli_prefix) + [ "tool", "--app-path", @mongoid_dir, "--no-boot", *tool_args ]
      stdout, stderr, status = Open3.capture3(@builder.env, *cmd, chdir: Dir.tmpdir)
      [ stdout, stderr, status ]
    end

    it "schema reports the honest Mongoid signal" do
      stdout, stderr, status = run_against_mongoid("schema")
      expect(status.exitstatus).to eq(0), stderr
      expect(stdout).to include("UNAVAILABLE")
      expect(stdout).to include("Mongoid")
    end

    it "model details show fields and embeds" do
      stdout, stderr, status = run_against_mongoid("model_details", "--model", "Customer")
      expect(status.exitstatus).to eq(0), stderr
      expect(stdout).to include("name")
      expect(stdout).to match(/embeds_many|orders/)
    end
  end

  describe "auto_mount from a user initializer" do
    it "registers the middleware when config.auto_mount = true" do
      initializer = File.join(@builder.app_path, "config", "initializers", "zz_auto_mount.rb")
      File.write(initializer, <<~RUBY)
        RailsAiContext.configure { |config| config.auto_mount = true }
      RUBY
      begin
        stdout, stderr, status = Open3.capture3(
          @builder.env, "bin/rails", "middleware", chdir: @builder.app_path
        )
        expect(status.exitstatus).to eq(0), stderr
        expect(stdout).to include("RailsAiContext::Middleware")
      ensure
        File.delete(initializer) if File.exist?(initializer)
      end
    end
  end
end
