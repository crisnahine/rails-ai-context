# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActionSource do
  def find_in(files, controller, action, file: nil)
    Dir.mktmpdir do |root|
      files.each do |relative, body|
        FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
        File.write(File.join(root, relative), body)
      end
      allow(RailsAiContext::PathResolver).to receive(:project_dirs).and_return([ File.realpath(root) ])
      yield described_class.find(File.realpath(root), controller, action, file: file)
    end
  end

  let(:app_base) { { "app/controllers/application_controller.rb" => "class ApplicationController < ActionController::Base\nend\n" } }

  it "reads the controller's own def" do
    files = app_base.merge("app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n  def index\n    @posts = []\n  end\nend\n")
    find_in(files, "PostsController", "index", file: "app/controllers/posts_controller.rb") do |found|
      expect(found).to include(file: "app/controllers/posts_controller.rb", start_line: 2, end_line: 4)
      expect(found[:code]).to include("@posts = []")
    end
  end

  it "reads an action a concern gives, from the concern's file" do
    files = app_base.merge(
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n  include Exportable\nend\n",
      "app/controllers/concerns/exportable.rb" => "module Exportable\n  extend ActiveSupport::Concern\n\n  def export\n    head :ok\n  end\nend\n"
    )
    find_in(files, "PostsController", "export") do |found|
      expect(found).to include(file: "app/controllers/concerns/exportable.rb", start_line: 4, end_line: 6)
    end
  end

  it "reads an action a parent controller defines, and a concern named from inside a namespace" do
    files = app_base.merge(
      "app/controllers/admin/base_controller.rb" => "module Admin\n  class BaseController < ApplicationController\n    def index; end\n  end\nend\n",
      "app/controllers/admin/posts_controller.rb" => "module Admin\n  class PostsController < BaseController\n    include Searchable\n  end\nend\n",
      "app/controllers/concerns/admin/searchable.rb" => "module Admin\n  module Searchable\n    def search\n      render :index\n    end\n  end\nend\n"
    )
    find_in(files, "Admin::PostsController", "index") do |found|
      expect(found[:file]).to eq("app/controllers/admin/base_controller.rb")
    end
    find_in(files, "Admin::PostsController", "search") do |found|
      expect(found).to include(file: "app/controllers/concerns/admin/searchable.rb", start_line: 3, end_line: 5)
    end
  end

  it "does not take another class's def of the same name from a parent's file" do
    files = app_base.merge(
      "app/controllers/posts_controller.rb" => "class PostsController < BaseController\nend\n",
      "app/controllers/base_controller.rb" => "class BaseController < ApplicationController\n  class Helper\n    def index; end\n  end\nend\n"
    )
    find_in(files, "PostsController", "index") { |found| expect(found).to be_nil }
  end

  it "is nil for an action no app file defines" do
    files = app_base.merge("app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\nend\n")
    find_in(files, "PostsController", "show") { |found| expect(found).to be_nil }
  end
end
