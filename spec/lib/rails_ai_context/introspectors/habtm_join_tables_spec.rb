# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::HabtmJoinTables do
  def declared(files, models = {})
    Dir.mktmpdir do |dir|
      files.each do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      RailsAiContext::PathResolver.clear_code_roots
      return described_class.declared(dir, models).to_a.sort
    end
  end

  let(:models) { { "Project" => { table_name: "projects" }, "Type" => { table_name: "types" }, "Status" => { table_name: "statuses" } } }

  it "reads join_table: from a concern a lib patch declares, however it is applied" do
    tables = declared({
      "modules/backlogs/backlogs.gemspec" => "",
      "modules/backlogs/app/models/sprint.rb" => "class Sprint < ApplicationRecord\nend\n",
      "modules/backlogs/lib/backlogs/patches/project_patch.rb" => <<~RUBY,
        module Backlogs::Patches::ProjectPatch
          extend ActiveSupport::Concern

          included do
            has_and_belongs_to_many :done_statuses, join_table: "done_statuses_for_project", class_name: "::Status"
            has_and_belongs_to_many :excluded, join_table: "\#{table_name_prefix}excluded_types\#{table_name_suffix}"
          end
        end
      RUBY
      "app/models/project.rb" => "class Project < ApplicationRecord\nend\n"
    }, models)

    expect(tables).to eq(%w[done_statuses_for_project excluded_types])
  end

  # A namespaced owner's habtm finds the other side in its own namespace first.
  it "derives the other side's table from the owner's namespace outward" do
    tables = declared({
      "app/models/spree/product.rb" => "module Spree\n  class Product < ApplicationRecord\n    has_and_belongs_to_many :taxons\n  end\nend\n"
    }, {
      "Spree::Product" => { table_name: "spree_products" }, "Spree::Taxon" => { table_name: "spree_taxons" },
      "Taxon" => { table_name: "legacy_taxons" }
    })

    expect(tables).to eq(%w[spree_products_taxons])
  end

  it "derives the table from the owner a patch targets, as Rails does" do
    tables = declared({
      "lib/patches/class_eval.rb" => "Project.class_eval do\n  has_and_belongs_to_many :types\nend\n",
      "lib/patches/included.rb" => <<~RUBY,
        module StatusPatch
          extend ActiveSupport::Concern
          included do
            has_and_belongs_to_many :statuses
          end
        end
        Type.include(StatusPatch)
      RUBY
      "lib/patches/prepended.rb" => "module Tagged\n  def self.prepended(base); end\n  included { has_and_belongs_to_many :projects }\nend\n",
      "app/models/status.rb" => "class Status < ApplicationRecord\n  prepend Tagged\nend\n",
      "lib/reopen.rb" => "class Status\n  has_and_belongs_to_many :types\nend\n"
    }, models)

    expect(tables).to eq(%w[projects_statuses projects_types statuses_types])
  end

  # `include Patch` inside module Admin names Admin::Patch; crediting the
  # class to every module ending in Patch derived a table for each.
  it "credits an include to the module it resolves to, not every module of that name" do
    tables = declared({
      "lib/admin/patch.rb" => "module Admin::Patch\n  included { has_and_belongs_to_many :types }\nend\n",
      "lib/patch.rb" => "module Patch\n  included { has_and_belongs_to_many :statuses }\nend\n",
      "app/models/project.rb" => "module Admin\n  class Project < ApplicationRecord\n    include Patch\n  end\nend\n"
    }, { "Admin::Project" => { table_name: "projects" }, "Type" => { table_name: "types" }, "Status" => { table_name: "statuses" } })

    expect(tables).to eq(%w[projects_types])
  end

  it "skips one whose owner it cannot place" do
    expect(declared({ "lib/loose.rb" => "module Loose\n  included { has_and_belongs_to_many :types }\nend\n" }, models)).to eq([])
  end
end
