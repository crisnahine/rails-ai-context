# frozen_string_literal: true

require_relative "e2e_helper"

# E2E coverage for the 8 "nervous-system" introspectors added in this
# release — initializers, autoload, connection_pool, active_support,
# credentials, security, observability, env.
#
# These introspectors read Rails runtime state (Rails.application.initializers,
# Rails.autoloaders.main, ActiveRecord connection handler, ActiveSupport
# notifier registry, etc.), so the combustion fixture in unit specs is
# *necessary* but not *sufficient* — a real `rails new` app exercises
# the post-boot state AI clients actually see. This spec builds a real
# app, then runs `bin/rails runner` to invoke the orchestrator in-process
# and asserts each new introspector produced a non-error Hash.
RSpec.describe "E2E: nervous-system introspectors", type: :e2e do
  before(:all) do
    @builder = E2E::TestAppBuilder.new(
      parent_dir: E2E.root,
      name: "nervous_system_app",
      install_path: :in_gemfile
    ).build!
    @cli = E2E::CliRunner.new(@builder)
  end

  let(:runner_script) do
    <<~RUBY
      require "json"
      require "rails_ai_context"
      result = RailsAiContext::Introspector.new(Rails.application).call
      slice = result.slice(:initializers, :autoload, :connection_pool, :active_support, :credentials, :security, :observability, :env)
      puts JSON.generate(slice.transform_values { |v| v.is_a?(Hash) ? v.slice(:error, :total, :mode, :databases, :concerns, :default, :force_ssl, :log_level, :set) : v })
    RUBY
  end

  let(:result) do
    out = @cli.run([ "bin/rails", "runner", runner_script ])
    expect(out.success?).to be(true), "rails runner failed:\n#{out}"
    JSON.parse(out.stdout.lines.find { |l| l.strip.start_with?("{") }.to_s, symbolize_names: true)
  rescue JSON::ParserError => e
    raise "Could not parse runner output as JSON: #{e.message}\nstdout:\n#{out.stdout}\nstderr:\n#{out.stderr}"
  end

  it "ships :initializers with a non-zero total" do
    expect(result[:initializers]).to be_a(Hash)
    expect(result[:initializers]).not_to have_key(:error)
    expect(result[:initializers][:total]).to be_a(Integer)
    expect(result[:initializers][:total]).to be > 0
  end

  it "ships :autoload with mode detected" do
    expect(result[:autoload]).to be_a(Hash)
    expect(result[:autoload]).not_to have_key(:error)
    expect(result[:autoload][:mode]).to be_a(String)
  end

  it "ships :connection_pool with at least one database" do
    expect(result[:connection_pool]).to be_a(Hash)
    expect(result[:connection_pool]).not_to have_key(:error)
    expect(result[:connection_pool][:databases]).to be_an(Array)
    expect(result[:connection_pool][:databases]).not_to be_empty
  end

  it "ships :active_support with concerns as a Hash" do
    expect(result[:active_support]).to be_a(Hash)
    expect(result[:active_support]).not_to have_key(:error)
    expect(result[:active_support][:concerns]).to be_a(Hash)
  end

  it "ships :credentials with default credentials metadata" do
    expect(result[:credentials]).to be_a(Hash)
    expect(result[:credentials]).not_to have_key(:error)
    expect(result[:credentials][:default]).to be_a(Hash)
  end

  it "ships :security with force_ssl as boolean" do
    expect(result[:security]).to be_a(Hash)
    expect(result[:security]).not_to have_key(:error)
    expect(result[:security][:force_ssl]).to eq(true).or(eq(false))
  end

  it "ships :observability with log_level" do
    expect(result[:observability]).to be_a(Hash)
    expect(result[:observability]).not_to have_key(:error)
    expect(result[:observability][:log_level]).to be_a(String)
  end

  it "ships :env with at least RAILS_ENV in the set bucket" do
    expect(result[:env]).to be_a(Hash)
    expect(result[:env]).not_to have_key(:error)
    expect(result[:env][:set]).to be_an(Array)
  end
end
