# frozen_string_literal: true

require "spec_helper"

# Secrets planted across the static fixture app must reach no part of what the
# gem hands out: the introspected payload, its JSON file, the files `context`
# writes, or any tool's default answer.
module PayloadRedactionPlants
  # Built from parts so no file in this repo holds a live-looking token.
  def self.github(char) = %w[gh p_].join + (char * 36)
  STRIPE = %w[sk_ live_].join + ("V" * 24)
  AWS = %w[AK IA].join + ("M" * 16)

  PLANTS = {
    "app/views/posts/show.html.erb" => [
      %(<%= turbo_frame_tag "feed", src: "/feed?api_key=#{STRIPE}" %>),
      %(<%= turbo_stream_from "room", token: "#{github('a')}" %>),
      %(<% password = "ViewPassw0rdQ9" %>)
    ],
    "app/models/vault.rb" => [
      "class Vault < ApplicationRecord",
      %(  broadcasts_to ->(vault) { [vault, token: "#{github('b')}"] }),
      %(  after_save { self.client_token = "#{github('c')}" }),
      %(  before_validation :seal, unless: -> { Gate.open?(token: "#{github('l')}") }),
      %(  scope :sealed, -> { where(api_key: "#{AWS}") }),
      %(  default_scope { where.not(token: "#{github('m')}") }),
      %(  validate :gate_open, if: -> { Gate.open?(token: "#{github('r')}") }),
      %(  validate { errors.add(:base, "closed") unless Gate.open?(token: "#{github('n')}") }),
      %(  validates :name, presence: true, if: -> { Gate.ok?(password: "IfPassw0rdQ9") }),
      %(  validates :code, format: { with: /x/, message: "#{github('z')}" }),
      %(  attribute :seal_code, default: -> { Seal.new(password: "SealPassw0rdQ9") }),
      %(  broadcasts_to ->(vault) { [vault, "#{github('x')}"] }),
      "  def seal",
      %(    self.password = "ModelPassw0rdQ9"),
      "  end",
      "end"
    ],
    "app/controllers/vaults_controller.rb" => [
      "class VaultsController < ApplicationController",
      %(  before_action -> { @client = Client.new(token: "#{github('d')}") }),
      %(  rescue_from KeyError, with: -> { Alert.new(token: "#{github('o')}").ping }),
      %(  http_basic_authenticate_with name: "admin", password: "BasicPassw0rdQ9"),
      "  def show",
      %(    Turbo::StreamsChannel.broadcast_replace_to "vault", token: "#{github('e')}"),
      %(    @password = "CtrlPassw0rdQ9"),
      "  end",
      "end"
    ],
    "app/jobs/vault_job.rb" => [
      "class VaultJob < ApplicationJob",
      %(  queue_as { Gate.ok?(password: "QueuePassw0rdQ9") ? :critical : :default }),
      %(  retry_on KeyError, wait: ->(n) { Backoff.new(token: "#{github('p')}").call(n) }),
      "  discard_on StandardError do |job, _error|",
      %(    Notifier.new(token: "#{github('f')}").ping),
      "  end",
      "  def perform",
      %(    Turbo::StreamsChannel.broadcast_append_to "jobs", token: "#{github('g')}"),
      "  end",
      "end"
    ],
    "app/jobs/hook_job.rb" => [
      "class HookJob < ApplicationJob",
      %(  queue_as "#{github('w')}"),
      "end"
    ],
    "db/schema.rb" => [
      "ActiveRecord::Schema.define(version: 2024_01_15_000000) do",
      %(  create_table "vaults" do |t|),
      %(    t.string "client_token", default: "#{github('y')}"),
      "  end",
      "end"
    ],
    "config/initializers/vault.rb" => [
      %(Rails.application.config.x.vault_token = "#{github('h')}"),
      %(Rails.application.config.x.client = Client.new(api_key: "#{github('q')}")),
      %(Rails.application.config.action_mailer.smtp_settings = { user_name: "a", password: "InitPassw0rdQ9" })
    ],
    "config/routes.rb" => [
      "Rails.application.routes.draw do",
      %(  get "/vault", to: "vaults#show", constraints: ->(r) { r.params[:token] == "#{github('i')}" }),
      %(  get "/hook/#{github('v')}", to: "vaults#show"),
      %(  get "/old", to: redirect("https://bot:#{github('j')}@example.com/new")),
      "end"
    ]
  }.freeze

  TOKENS = [ STRIPE, AWS, *"abcdefghijklmnopqrvwxyz".chars.map { |c| github(c) }, *%w[View Model Ctrl Init Basic If Seal Queue].map { |w| "#{w}Passw0rdQ9" } ].freeze
end

RSpec.describe "payload redaction" do
  def leaks(text)
    PayloadRedactionPlants::TOKENS.select { |token| text.include?(token) }
  end

  def strings(value, path = [], &block)
    case value
    when Hash then value.each { |key, inner| strings(inner, path + [ key ], &block) }
    when Array then value.each_with_index { |inner, i| strings(inner, path + [ i ], &block) }
    when String then yield path.join("."), value
    end
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.join(dir, "app")
      FileUtils.cp_r(IntrospectedFixture::ROOT, @root)
      PayloadRedactionPlants::PLANTS.each do |relative, lines|
        path = File.join(@root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{lines.join("\n")}\n", mode: File.exist?(path) ? "a" : "w")
      end
      example.run
    end
  end

  # Each plant is a shape source redaction filters, so a leak below is a capture that skipped it.
  it "plants only secrets that source redaction filters" do
    PayloadRedactionPlants::PLANTS.each do |relative, lines|
      expect(leaks(RailsAiContext::Redaction.redact_source(lines.join("\n"), path: relative))).to be_empty, relative
    end
  end

  # The static tier the CLI and the plugin's server run in, in one child process.
  def static_run
    @static_run ||= begin
      driver = File.join(File.dirname(@root), "driver.rb")
      File.write(driver, <<~RUBY)
        require "rails_ai_context/cli/entry_boot"
        outcome = RailsAiContext::CLI::EntryBoot.call(root: ARGV[0], allow_static: true, no_boot: true)
        abort outcome.messages.join("\\n") unless outcome.tier == :static
        RailsAiContext::Server.builtin_tools.each do |tool|
          short = RailsAiContext::CLI::ToolRunner.short_name(tool.tool_name)
          puts "=== \#{short}", RailsAiContext::CLI::ToolRunner.new(short, []).run
        end
        puts "=== payload", RailsAiContext::Serializers::JsonSerializer.new(RailsAiContext.introspect).call
      RUBY
      out, status = Open3.capture2e("ruby", "-I", LIB, driver, @root, stdin_data: "")
      expect(status).to be_success, out
      out.split(/^=== /).reject(&:empty?).to_h { |answer| answer.split("\n", 2) }
    end
  end

  LIB = File.expand_path("../../../lib", __dir__)

  it "keeps every planted secret out of every string of the payload and its JSON" do
    json = static_run.fetch("payload")
    found = []
    strings(JSON.parse(json)) { |path, text| found << "#{path}: #{leaks(text).join(', ')}" if leaks(text).any? }

    expect(found.join("\n")).to eq("")
    expect(leaks(json)).to be_empty
  end

  it "keeps every planted secret out of every tool's default answer" do
    answers = static_run.except("payload")
    expect(answers.size).to eq(RailsAiContext::Server.builtin_tools.size)

    expect(answers.filter_map { |tool, text| "#{tool}: #{leaks(text).join(", ")}" if leaks(text).any? }.join("\n")).to eq("")
  end

  it "keeps every planted secret out of every file context writes" do
    exe = File.expand_path("../../../exe/rails-ai-context", __dir__)
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).to_set
    out, status = Open3.capture2e("ruby", "-I", LIB, exe, "context", "--app-path", @root, "--no-boot", "--format", "all", stdin_data: "")
    expect(status).to be_success, out

    written = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).reject { |f| before.include?(f) || File.directory?(File.join(@root, f)) }
    expect(written).to include(".ai-context.json", "CLAUDE.md")
    expect(written.select { |f| leaks(File.read(File.join(@root, f))).any? }).to be_empty
  end
end
