# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::ActiveRecordSettings do
  def settings(files)
    Dir.mktmpdir do |dir|
      files.each do |path, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), body)
      end
      return [ described_class.for(dir), described_class.unread(dir) ]
    end
  end

  # Rails copies config.active_record.schema_format onto ActiveRecord in an after_initialize hook.
  it "lets config.active_record.schema_format win over a later ActiveRecord.schema_format" do
    result = settings("config/application.rb" => "class Application < Rails::Application\n  config.active_record.schema_format = :sql\nend\n",
                      "config/initializers/zz.rb" => "ActiveRecord.schema_format = :ruby\n")

    expect(result.first[:schema_format]).to eq(:sql)
  end

  it "keeps a literal schema_format when a later one is computed, since only the table settings are judged that way" do
    result = settings("config/application.rb" => "class Application < Rails::Application\n  config.active_record.schema_format = :sql\nend\n",
                      "config/initializers/a.rb" => "Rails.application.config.active_record.schema_format = ENV.fetch(\"SF\", \"sql\").to_sym\n")

    expect(result).to eq([ { schema_format: :sql }, [] ])
  end

  it "takes ActiveRecord.schema_format when config sets none" do
    expect(settings("config/initializers/zz.rb" => "ActiveRecord.schema_format = :sql\n").first[:schema_format]).to eq(:sql)
  end

  # The base's load hook copies config first; a direct assignment runs after it.
  it "lets a direct ActiveRecord::Base affix win over config.active_record" do
    result = settings("config/application.rb" => "class Application < Rails::Application\n  config.active_record.table_name_prefix = \"cfg_\"\nend\n",
                      "config/initializers/a.rb" => "ActiveRecord::Base.table_name_prefix = \"base_\"\n")

    expect(result.first[:table_name_prefix]).to eq("base_")
  end

  it "keeps a value only the running app computes out of the settings, and names it as unread", :aggregate_failures do
    computed = "ActiveRecord::Base.table_name_prefix = ENV.fetch(\"P\", \"\")\n"
    literal = "ActiveRecord::Base.table_name_prefix = \"z_\"\n"
    config = "class Application < Rails::Application\n  config.active_record.table_name_prefix = \"cfg_\"\nend\n"

    expect(settings("config/initializers/a.rb" => computed)).to eq([ {}, [ :table_name_prefix ] ])
    # Each runs after the one before it, so the last decides.
    expect(settings("config/initializers/a.rb" => computed, "config/initializers/b.rb" => literal)).to eq([ { table_name_prefix: "z_" }, [] ])
    expect(settings("config/initializers/a.rb" => literal, "config/initializers/b.rb" => computed)).to eq([ {}, [ :table_name_prefix ] ])
    expect(settings("config/application.rb" => config, "config/initializers/a.rb" => computed)).to eq([ {}, [ :table_name_prefix ] ])
    expect(settings("config/application.rb" => config.sub("\"cfg_\"", "ENV[\"P\"]"), "config/initializers/a.rb" => literal))
      .to eq([ { table_name_prefix: "z_" }, [] ])
  end
end
