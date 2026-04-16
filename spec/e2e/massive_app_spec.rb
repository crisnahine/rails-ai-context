# frozen_string_literal: true

require_relative "e2e_helper"

# Massive Rails app — programmatically generate 1500 models + 1500 tables
# in a single migration, then exercise representative tools to verify they
# don't crash, hang, or OOM. Catches: unbounded output, unbounded memory
# use, tools that forgot to cap their Dir.glob / introspection work, and
# tools that don't truncate large payloads before returning.
#
# Running all 38 tools against 1500 models would take 10-30 minutes. We
# sample the tools most likely to scale poorly: schema (DB walk),
# model_details (model walk), routes (routes walk), context/onboard
# (aggregate), analyze_feature (multi-dir scans), turbo_map (model +
# view scan), get_env (app tree scan).
RSpec.describe "E2E: massive Rails app (1500 models)", type: :e2e do
  MODEL_COUNT = 1500
  # Bumped timeout — tools that introspect every model file or every
  # schema table need more than the default 60 s on a cold-boot Rails app.
  PER_TOOL_TIMEOUT = 180

  before(:all) do
    @builder = build_massive_app
    @cli = E2E::CliRunner.new(@builder)
  end

  # Representative sample of tools that scale with model / table / file count.
  SCALE_CRITICAL_TOOLS = %w[
    schema
    model_details
    routes
    context
    onboard
    analyze_feature
    get_turbo_map
    get_env
  ].freeze

  SCALE_CRITICAL_TOOLS.each do |short|
    it "#{short} completes without crashing on a 1500-model app" do
      args = short == "analyze_feature" ? [ "--feature", "thing" ] : []
      result = @cli.cli_tool(short, args, timeout: PER_TOOL_TIMEOUT)
      expect(result.status.signaled?).to be(false), "#{short} received a signal:\n#{result}"
      expect(result.exit_status).to be < 2, "#{short} crashed (exit #{result.exit_status}):\n#{result}"
      expect(result.stdout.strip).not_to be_empty, "#{short} produced no stdout"
      # Output must be within the configured response cap. A tool that forgot
      # to truncate would blow past this and we'd fail here loudly rather
      # than silently overwhelm an AI client's context window.
      expect(result.stdout.bytesize).to be < 2_000_000, "#{short} returned #{result.stdout.bytesize} bytes — tools must cap response size"
    end
  end

  it "the migration actually created all 1500 tables" do
    # Query a specific table from the middle of the range. The default
    # `rails_get_schema` response caps output at first-~25 tables (correct
    # behavior for AI-client context windows), so query a single table
    # to verify the fixture built all 1500.
    result = @cli.cli_tool("schema", [ "--table", "thing_0750s" ])
    expect(result.success?).to be(true), result.to_s
    expect(result.stdout).to match(/thing_0750/)
    expect(result.stdout).to match(/name.*string|value.*integer/)
  end

  it "rails_get_schema reports the correct total table count in its truncation hint" do
    # The default response includes "all N tables" in a hint — proves
    # the tool knows about every table, even when displaying only the
    # first page.
    result = @cli.cli_tool("schema")
    expect(result.success?).to be(true)
    expect(result.stdout).to match(/1501 tables|1500 tables/)  # +1 for posts
  end

  private

  def build_massive_app
    builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "massive_app",
      install_path: :in_gemfile
    )
    # Override the default scaffold step with: scaffold ONE Post model for
    # realism + programmatically generate 1500 more tables + 1500 model
    # files. Generating via `rails g model` 1500 times would take 30+ min;
    # writing files directly takes seconds.
    count = MODEL_COUNT
    builder.define_singleton_method(:scaffold_sample_model!) do
      in_app("bin/rails", "generate", "scaffold", "Post", "title:string", "body:text", "published:boolean")
      generate_many_models!(count)
      in_app("bin/rails", "db:migrate")
    end
    builder.define_singleton_method(:generate_many_models!) do |n|
      models_dir = File.join(app_path, "app", "models")
      migrate_dir = File.join(app_path, "db", "migrate")
      FileUtils.mkdir_p(models_dir)
      FileUtils.mkdir_p(migrate_dir)

      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      migration_path = File.join(migrate_dir, "#{timestamp}_create_many_tables.rb")

      File.open(migration_path, "w") do |f|
        f.puts "class CreateManyTables < ActiveRecord::Migration[7.1]"
        f.puts "  def change"
        (1..n).each do |i|
          num = i.to_s.rjust(4, "0")
          f.puts "    create_table :thing_#{num}s do |t|"
          f.puts "      t.string :name"
          f.puts "      t.integer :value"
          f.puts "      t.timestamps"
          f.puts "    end"
        end
        f.puts "  end"
        f.puts "end"
      end

      (1..n).each do |i|
        num = i.to_s.rjust(4, "0")
        File.write(File.join(models_dir, "thing_#{num}.rb"), <<~RUBY)
          class Thing#{num} < ApplicationRecord
          end
        RUBY
      end
    end
    builder.build!
  end
end
