# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::BaseMixins do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def write(rel, body)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def mixins
    described_class.models(@root).map { |mixin| [ mixin.name, mixin.macro, mixin.path&.delete_prefix("#{@root}/") ] }
  end

  it "finds a module an on_load(:active_record) hook includes into every model" do
    write("config/initializers/auditing.rb", "ActiveSupport.on_load(:active_record) do\n  include Auditable\nend\n")
    write("app/models/concerns/auditable.rb", "module Auditable\nend\n")

    expect(mixins).to eq([ [ "Auditable", :include, "app/models/concerns/auditable.rb" ] ])
  end

  # `watch` and the MCP server run again in one process after an edit.
  it "answers once per run, and a later run reads an initializer added since" do
    write("config/initializers/soft_delete.rb", "ActiveRecord::Base.send(:include, SoftDelete)\n")
    first = RailsAiContext::RunCache.around do
      before = mixins
      write("config/initializers/auditing.rb", "ActiveRecord::Base.include Auditable\n")
      [ before, mixins ]
    end
    later = RailsAiContext::RunCache.around { mixins }

    expect(first).to eq([ [ [ "SoftDelete", :include, nil ] ] ] * 2)
    expect(later).to contain_exactly([ "SoftDelete", :include, nil ], [ "Auditable", :include, nil ])
  end

  it "finds a module sent to ActiveRecord::Base" do
    write("config/initializers/soft_delete.rb", "ActiveRecord::Base.send(:include, SoftDelete)\n")

    expect(mixins).to eq([ [ "SoftDelete", :include, nil ] ])
  end

  it "finds a module written into a reopened ApplicationRecord" do
    write("lib/extensions.rb", "class ApplicationRecord\n  extend Searchable\nend\n")

    expect(mixins).to eq([ [ "Searchable", :extend, nil ] ])
  end

  it "finds a module written into a class_eval block, and reads the class methods that block defines" do
    write("config/initializers/i18n.rb", "ActiveRecord::Base.class_eval do\n  include Localized\n  class << self\n    def validates_locale; end\n  end\nend\n")

    expect(mixins).to eq([ [ "Localized", :include, nil ] ])
    defs = described_class.bodies(@root).flat_map { |scope| RailsAiContext::ConcernMacros::SingletonLookup.own_defs(scope, 1) }
    expect(defs.map(&:name)).to eq(%w[validates_locale])
  end

  it "does not read a model file's own includes" do
    write("app/models/user.rb", "class User < ApplicationRecord\n  include Auditable\nend\n")

    expect(mixins).to eq([])
  end
end
