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
      return described_class.for(dir)
    end
  end

  # Rails copies config.active_record.schema_format onto ActiveRecord in an after_initialize hook.
  it "lets config.active_record.schema_format win over a later ActiveRecord.schema_format" do
    result = settings("config/application.rb" => "class Application < Rails::Application\n  config.active_record.schema_format = :sql\nend\n",
                      "config/initializers/zz.rb" => "ActiveRecord.schema_format = :ruby\n")

    expect(result[:schema_format]).to eq(:sql)
  end

  it "takes ActiveRecord.schema_format when config sets none" do
    expect(settings("config/initializers/zz.rb" => "ActiveRecord.schema_format = :sql\n")[:schema_format]).to eq(:sql)
  end

  # The base's load hook copies config first; a direct assignment runs after it.
  it "lets a direct ActiveRecord::Base affix win over config.active_record" do
    result = settings("config/application.rb" => "class Application < Rails::Application\n  config.active_record.table_name_prefix = \"cfg_\"\nend\n",
                      "config/initializers/a.rb" => "ActiveRecord::Base.table_name_prefix = \"base_\"\n")

    expect(result[:table_name_prefix]).to eq("base_")
  end
end
