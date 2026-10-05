# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::AdminResources do
  around { |example| Dir.mktmpdir { |dir| @root = File.realpath(dir); example.run } }

  def write(path, source)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, source)
  end

  it "reads each admin gem's resources from its generator's folder" do
    write("app/admin/users.rb", <<~RUBY)
      ActiveAdmin.register User do
        permit_params :email, :name
        index do
          column :email
        end
      end
    RUBY
    write("app/admin/dashboard.rb", "ActiveAdmin.register_page \"Dashboard\" do\nend\n")
    write("app/dashboards/user_dashboard.rb", <<~RUBY)
      class UserDashboard < Administrate::BaseDashboard
        ATTRIBUTE_TYPES = { id: Field::Number, email: Field::String }.freeze
      end
    RUBY
    write("app/avo/resources/user.rb", <<~RUBY)
      class Avo::Resources::User < Avo::BaseResource
        def fields
          field :email, as: :text
        end
      end
    RUBY
    write("app/avo/resources/member.rb", <<~RUBY)
      class Avo::Resources::Member < Avo::BaseResource
        self.model_class = ::Account
      end
    RUBY
    write("app/madmin/resources/post_resource.rb", "class PostResource < Madmin::Resource\n  attribute :id\nend\n")
    write("app/admin/comments_admin.rb", "Trestle.resource(:comments) do\nend\n")
    write("app/admin/people_admin.rb", "Trestle.resource(:people, model: Person) do\nend\n")

    found = described_class.call(@root).map { |r| r.values_at(:framework, :model, :file, :params) }

    expect(found).to contain_exactly(
      [ "ActiveAdmin", "User", "app/admin/users.rb", %w[email name] ],
      [ "Administrate", "User", "app/dashboards/user_dashboard.rb", [] ],
      [ "Avo", "User", "app/avo/resources/user.rb", [] ],
      [ "Avo", "Account", "app/avo/resources/member.rb", [] ],
      [ "Madmin", "Post", "app/madmin/resources/post_resource.rb", [] ],
      [ "Trestle", "Comment", "app/admin/comments_admin.rb", [] ],
      [ "Trestle", "Person", "app/admin/people_admin.rb", [] ]
    )
  end

  it "survives a file that does not parse and a directory symlinked out of the app" do
    write("app/admin/broken.rb", "ActiveAdmin.register User do\n  permit_params :a,\n")
    write("app/dashboards/garbage.rb", "\xFF\xFE class".b)
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "secret.rb"), "ActiveAdmin.register Secret do\nend\n")
      File.symlink(outside, File.join(@root, "app/admin/linked"))

      expect(described_class.call(@root).map { |r| r[:model] }).not_to include("Secret")
    end
  end

  it "answers empty for an app without admin folders" do
    expect(described_class.call(@root)).to eq([])
  end
end
