# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# A file under sensitive_patterns contributes no name, structure or value to any answer, whichever
# reader reaches it: a directory walk, a base class, a concern, a migration or a job.
RSpec.describe "files under sensitive_patterns" do
  FILES = {
    "config/application.rb" => "module Shop\n  class Application < Rails::Application\n    config.autoload_lib(ignore: %w[assets tasks])\n  end\nend\n",
    "config/routes.rb" => "Rails.application.routes.draw do\n  resources :posts\nend\n",
    "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n",
    "app/models/post.rb" => "class Post < Vault::BaseRecord\n  include Vault::Conc\n  has_many :comments\nend\n",
    "app/models/comment.rb" => "class Comment < ApplicationRecord\nend\n",
    "app/models/vault/base_record.rb" => "module Vault\n  class BaseRecord < ApplicationRecord\n    self.abstract_class = true\n    has_many :planted_assoc\n    validates :planted_val, presence: true\n  end\nend\n",
    "app/models/vault/secret.rb" => "module Vault\n  class Secret < ApplicationRecord\n    def reveal_secret_method; end\n  end\nend\n",
    "app/models/concerns/vault/conc.rb" => "module Vault\n  module Conc\n    extend ActiveSupport::Concern\n    included do\n      before_save :conc_planted_cb\n    end\n  end\nend\n",
    "app/controllers/application_controller.rb" => "class ApplicationController < ActionController::Base\nend\n",
    "app/controllers/posts_controller.rb" => "class PostsController < Vault::BaseController\n  def index; end\nend\n",
    "app/controllers/vault/base_controller.rb" => "module Vault\n  class BaseController < ApplicationController\n    before_action :vault_base_planted_filter\n  end\nend\n",
    "app/jobs/application_job.rb" => "class ApplicationJob < ActiveJob::Base\nend\n",
    "app/jobs/vault/rotate_job.rb" => "module Vault\n  class RotateJob < ApplicationJob\n    def perform; end\n  end\nend\n",
    "db/migrate/20240101000001_create_vault_secrets.rb" => "class CreateVaultSecrets < ActiveRecord::Migration[7.1]\n  def change\n    create_table :vault_secrets do |t|\n      t.string :hidden_col_planted\n    end\n  end\nend\n",
    "db/migrate/20240101000002_create_posts.rb" => "class CreatePosts < ActiveRecord::Migration[7.1]\n  def change\n    create_table :posts do |t|\n      t.string :title\n    end\n    create_table :comments do |t|\n      t.integer :post_id\n    end\n  end\nend\n"
  }.freeze
  VIEW_FILES = {
    "app/views/posts/index.html.erb" => "<h1>Posts</h1>\n<%= render \"vault/card\", post: nil %>\n<div data-controller=\"vault-secret\"></div>\n<%= turbo_frame_tag \"shown_frame\" do %>x<% end %>\n",
    "app/views/vault/show.html.erb" => "<h2>VAULT_SHOW_TITLE</h2><%= render \"vault/card\", post: @post %>\n",
    "app/views/vault/_card.html.erb" => "<%# locals: (post:) %>\n<p><%= post&.planted_view_method %></p>\n<%= turbo_frame_tag \"vault_planted_frame\" do %>y<% end %>\n",
    "app/javascript/controllers/vault/secret_controller.js" => "import { Controller } from \"@hotwired/stimulus\"\nexport default class extends Controller {\n  static targets = [\"planted_target\"]\n}\n",
    "app/javascript/controllers/index.js" => "import SecretController from \"./vault/secret_controller\"\napplication.register(\"vault-secret\", SecretController)\n"
  }.freeze
  VIEW_PLANTED = %w[vault_planted_frame planted_view_method planted_target vault/_card.html.erb vault/show].freeze
  PLANTED = %w[planted_assoc planted_val conc_planted_cb vault_base_planted_filter reveal_secret_method RotateJob hidden_col_planted].freeze

  def answers(dir)
    previous = [ RailsAiContext.tier, RailsAiContext.configuration.app_root, RailsAiContext.configuration.sensitive_patterns ]
    RailsAiContext.tier = :static
    RailsAiContext.configuration.app_root = dir
    RailsAiContext.configuration.sensitive_patterns = previous.last + yield
    RailsAiContext::Tools::BaseTool.reset_all_caches!
    tools = RailsAiContext::Tools
    {
      model_details: tools::GetModelDetails.call(model: "Post"), models: tools::GetModelDetails.call(detail: "full"),
      context: tools::GetContext.call(model: "Post"), onboard: tools::Onboard.call,
      controllers: tools::GetControllers.call(controller: "PostsController"), routes: tools::GetRoutes.call(controller: "posts"),
      feature: tools::AnalyzeFeature.call(feature: "post"), jobs: tools::GetJobPattern.call, schema: tools::GetSchema.call(detail: "full"),
      callbacks: tools::GetCallbacks.call(model: "Post"), views: tools::GetView.call, views_of: tools::GetView.call(controller: "vault"),
      turbo: tools::GetTurboMap.call, stimulus: tools::GetStimulus.call, vault_feature: tools::AnalyzeFeature.call(feature: "vault")
    }.transform_values { |response| response.content.map { |part| part[:text] }.join("\n") }
  ensure
    RailsAiContext.tier, RailsAiContext.configuration.app_root, RailsAiContext.configuration.sensitive_patterns = previous
    RailsAiContext::Tools::BaseTool.reset_all_caches!
  end

  around do |example|
    Dir.mktmpdir("sensitive-source") do |dir|
      @dir = File.realpath(dir)
      FILES.merge(VIEW_FILES).each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(@dir, path))) && File.write(File.join(@dir, path), source) }
      example.run
    end
  end

  it "shows the planted names in every answer when no pattern covers them" do
    shown = answers(@dir) { [] }.values.join("\n")

    expect(PLANTED.select { |name| shown.include?(name) }).to include("planted_assoc", "vault_base_planted_filter", "hidden_col_planted", "RotateJob")
  end

  it "shows none of them, in any tool, once a pattern covers their files" do
    hidden = answers(@dir) { %w[vault/ db/migrate/*vault*] }

    hidden.each { |tool, text| expect((PLANTED + VIEW_PLANTED).select { |name| text.include?(name) }).to eq([]), "#{tool} shows a sensitive file's names" }
    expect(hidden[:turbo]).to include("shown_frame")
  end

  it "leaves a file out of a directory walk and a constant lookup inside a run, and only inside one" do
    allow(RailsAiContext.configuration).to receive(:sensitive_patterns).and_return(RailsAiContext.configuration.sensitive_patterns + [ "vault/" ])
    app = RailsAiContext::StaticApp.new(@dir)
    walk = -> { RailsAiContext::FileWalk.each_file(File.join(@dir, "app"), root: @dir).map { |path| path.delete_prefix("#{@dir}/") } }

    inside = RailsAiContext::RunCache.around_app(app) { [ walk.call, RailsAiContext::PathResolver.file_for_constant(@dir, "Vault::BaseRecord") ] }

    expect(inside.first).to include("app/models/post.rb")
    expect(inside.first.grep(/vault/)).to eq([])
    expect(inside.last).to be_nil
    expect(walk.call).to include("app/models/vault/base_record.rb")
  end

  it "hides a model file under a pattern on the booted tier too" do
    config = RailsAiContext.configuration
    previous = [ RailsAiContext.tier, config.sensitive_patterns ]
    RailsAiContext.tier = :runtime
    config.sensitive_patterns = previous.last + [ "app/models/post.rb" ]
    RailsAiContext::Tools::BaseTool.reset_all_caches!
    tools = RailsAiContext::Tools
    text = [ tools::GetModelDetails.call(model: "Post"), tools::GetModelDetails.call(detail: "full"), tools::GetCallbacks.call(model: "Post") ]
           .map { |response| response.content.map { |part| part[:text] }.join("\n") }.join("\n")

    expect(text).not_to include("display_url", "app/models/post.rb", "where(published")
    expect(text).to include("Comment")
  ensure
    RailsAiContext.tier, config.sensitive_patterns = previous
    RailsAiContext::Tools::BaseTool.reset_all_caches!
  end

  it "keeps a model listed, unread, when the base it inherits from is under a pattern" do
    {
      "app/models/legacy_base.rb" => "class LegacyBase < ApplicationRecord\n  self.table_name = \"legacy_records\"\n  def legacy_planted_method; end\nend\n",
      "app/models/account.rb" => "class Account < LegacyBase\n  after_save :own_cb\nend\n",
      "db/schema.rb" => "ActiveRecord::Schema[7.1].define(version: 1) do\n  create_table \"legacy_records\" do |t|\n    t.string \"type\"\n    t.string \"name\"\n  end\nend\n"
    }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(@dir, path))) && File.write(File.join(@dir, path), source) }

    text = answers(@dir) { %w[legacy_base.rb] }.slice(:models, :schema).values.join("\n")

    expect(text).to include("Account")
    expect(text).not_to include("legacy_planted_method", "Tables with no model file")
  end

  it "keeps hiding when the default app cannot be built, using the configured root" do
    allow(RailsAiContext.configuration).to receive(:sensitive_patterns).and_return(RailsAiContext.configuration.sensitive_patterns + [ "vault/" ])
    allow(RailsAiContext.configuration).to receive(:app_root).and_return(@dir)
    allow(RailsAiContext).to receive(:default_app).and_raise("no app")

    hidden = RailsAiContext::RunCache.around_app { RailsAiContext::PathResolver.hidden?(File.join(@dir, "app/models/vault/secret.rb")) }

    expect(hidden).to be(true)
  end

  it "leaves out a view of every handler, a GraphQL file and a custom directory under a pattern" do
    files = {
      "Gemfile" => "source 'https://rubygems.org'\ngem 'rails'\ngem 'graphql'\n",
      "app/views/vault/planted_b.json.rabl" => "x", "app/views/vault/planted_c.html.arb" => "x",
      "app/views/vault/planted_d.html" => "x", "app/views/vault/planted_e.md" => "x",
      "app/views/vault/planted_i.html.liquid" => "x", "app/views/vault/planted_p.pdf.prawn" => "x",
      "app/graphql/vault/planted_resolver.rb" => "module Vault\n  class PlantedResolver\n  end\nend\n",
      "app/graphql/vault/subscriptions/planted_sub.rb" => "module Vault\n  module Subscriptions\n    class PlantedSub\n    end\n  end\nend\n",
      "app/graphql/vault/loaders/planted_loader.rb" => "module Vault\n  module Loaders\n    class PlantedLoader\n    end\n  end\nend\n",
      "app/vault/planted_dir.rb" => "x", "app/billing/other.rb" => "x"
    }
    files.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(@dir, path))) && File.write(File.join(@dir, path), source) }
    allow(RailsAiContext.configuration).to receive(:sensitive_patterns).and_return(RailsAiContext.configuration.sensitive_patterns + [ "vault/" ])
    app = RailsAiContext::StaticApp.new(@dir)

    shown = RailsAiContext::RunCache.around_app(app) do
      api = RailsAiContext::Introspectors::ApiIntrospector.new(app)
      [ api.send(:extract_graphql_details).to_json, api.send(:detect_serializers).to_json,
        RailsAiContext::Introspectors::ConventionIntrospector.new(app).send(:detect_custom_directories).to_json,
        RailsAiContext::ViewFile.each(@dir).map(&:last).join(" ") ].join("\n")
    end

    expect(shown.scan(/planted_?\w*|Planted\w*|"vault"/i)).to eq([])
    expect(shown).to include("billing")
  end
end
