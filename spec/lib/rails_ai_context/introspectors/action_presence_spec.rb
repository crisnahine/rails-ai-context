# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActionPresence do
  def chain_for(files)
    Dir.mktmpdir do |root|
      files.each do |relative, body|
        FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
        File.write(File.join(root, relative), body)
      end
      source = File.read(File.join(root, "app/controllers/orders_controller.rb"))
      chain = described_class.read(root, "OrdersController", source, prefix: "orders")
      yield chain, root
    end
  end

  let(:app_base) { { "app/controllers/application_controller.rb" => "class ApplicationController < ActionController::Base\n  def ping; end\nend\n" } }

  it "reads the controller, its ancestors and the modules they include" do
    files = app_base.merge(
      "app/controllers/orders_controller.rb" => "class OrdersController < ApplicationController\n  include Managing\n  def index; end\n  private\n  def secret; end\nend\n",
      "app/controllers/concerns/managing.rb" => "module Managing\n  def managed?; end\nend\n"
    )
    chain_for(files) do |chain|
      expect(chain.names).to include("index", "ping", "managed?")
      expect(chain.defines?("secret")).to be false
      expect(chain.defs.keys).to include(:index, :secret, :ping)
      expect(chain.unread).to eq([])
      expect(chain.prefixes).to eq(%w[orders application])
    end
  end

  it "follows a compact controller's bare superclass to the top-level class" do
    Dir.mktmpdir do |root|
      {
        "app/controllers/base_controller.rb" => "class BaseController < ActionController::Base\n  def web_only; end\nend\n",
        "app/controllers/api/base_controller.rb" => "module Api\n  class BaseController < ActionController::Base\n    def token_only; end\n  end\nend\n",
        "app/controllers/api/users_controller.rb" => "class Api::UsersController < BaseController\nend\n"
      }.each do |relative, body|
        FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
        File.write(File.join(root, relative), body)
      end
      source = File.read(File.join(root, "app/controllers/api/users_controller.rb"))
      chain = described_class.read(root, "Api::UsersController", source, prefix: "api/users")

      expect(chain.defines?("web_only")).to be true
      expect(chain.defines?("token_only")).to be false
    end
  end

  it "counts what an extended module's class macro builds with define_method" do
    files = app_base.merge(
      "app/controllers/orders_controller.rb" => "class OrdersController < ApplicationController\n  extend Listing\n  listing_for :orders\nend\n",
      "app/controllers/concerns/listing.rb" => "module Listing\n  def listing_for(name)\n    define_method(:reorder) { head :ok }\n  end\nend\n"
    )
    chain_for(files) { |chain| expect(chain.defines?("reorder")).to be true }
  end

  it "names an ancestor or included module no app source holds as unread" do
    files = {
      "app/controllers/orders_controller.rb" => "class OrdersController < ApplicationController\n  include Pagy::Backend\nend\n",
      "app/controllers/application_controller.rb" => "class ApplicationController < Spree::BaseController\nend\n"
    }
    chain_for(files) { |chain| expect(chain.unread).to eq(%w[Pagy::Backend Spree::BaseController]) }
  end

  it "finds a template at the controller's prefix or an ancestor's" do
    files = app_base.merge("app/controllers/orders_controller.rb" => "class OrdersController < ApplicationController\nend\n",
                           "app/views/application/show.html.erb" => "")
    chain_for(files) do |chain, root|
      expect(described_class.template?(root, chain, "show")).to be true
      expect(described_class.template?(root, chain, "edit")).to be false
    end
  end
end
