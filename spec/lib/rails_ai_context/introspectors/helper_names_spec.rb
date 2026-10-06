# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::HelperNames do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  def write(rel, body)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  it "names every method the app's helper modules define" do
    write("app/helpers/users_helper.rb", "module UsersHelper\n  def full_name(user)\n  end\nend\n")
    write("app/helpers/admin/dashboard_helper.rb", "module Admin::DashboardHelper\n  def stat_card\n  end\nend\n")

    expect(described_class.for(@root)).to include("full_name", "stat_card")
  end

  it "names the methods of a module a helper includes, from lib" do
    write("app/helpers/application_helper.rb", "module ApplicationHelper\n  include Formatting\nend\n")
    write("lib/formatting.rb", "module Formatting\n  def money(cents)\n  end\nend\n")

    expect(described_class.for(@root)).to include("money")
  end

  it "leaves out the methods of a class kept under app/helpers" do
    write("app/helpers/wiki_pages/at_version.rb", "class WikiPages::AtVersion < SimpleDelegator\n  def latest_version\n  end\nend\n")
    write("app/helpers/users_helper.rb", "module UsersHelper\n  class Row\n  end\n\n  def full_name\n  end\nend\n")

    expect(described_class.for(@root)).to include("full_name")
    expect(described_class.for(@root)).not_to include("latest_version")
  end

  # abstract_controller/helpers.rb: `helper :all` loads only `**/*_helper.rb`.
  it "leaves out a module under app/helpers whose file is not named *_helper.rb" do
    write("app/helpers/wiki_pages.rb", "module WikiPages\n  def wiki_link\n  end\nend\n")
    write("app/helpers/users_helper.rb", "module UsersHelper\n  def full_name\n  end\nend\n")

    expect(described_class.for(@root)).to contain_exactly("full_name")
  end

  it "answers an empty set for an app with no helpers" do
    expect(described_class.for(@root)).to be_empty
  end

  it "reads a module a helper includes from any autoload root, and from its namespace's file under lib" do
    write("app/helpers/application_helper.rb", <<~RUBY)
      module ApplicationHelper
        include LinkHelpers
        include CanonicalURL::Helpers

        def page_title = nil
      end
    RUBY
    write("app/lib/link_helpers.rb", "module LinkHelpers\n  def self.included(base) = nil\n  def nav_link = nil\nend\n")
    write("lib/canonical_url.rb", "module CanonicalURL\n  module Helpers\n    def canonical_link_tag = nil\n  end\n\n  def self.other = nil\nend\n")

    expect(described_class.for(@root)).to contain_exactly("page_title", "nav_link", "canonical_link_tag")
  end

  it "reads no include written in a comment or a string" do
    write("app/helpers/application_helper.rb", <<~RUBY)
      module ApplicationHelper
        # include LinkHelpers
        NOTE = "include LinkHelpers"
      end
    RUBY
    write("app/lib/link_helpers.rb", "module LinkHelpers\n  def nav_link = nil\nend\n")

    expect(described_class.for(@root)).to be_empty
  end
end
