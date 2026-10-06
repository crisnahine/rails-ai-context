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
      described_class.clear
      return described_class.for(dir)
    end
  end

  # The base's load hook copies config first; a direct assignment runs after it.
  it "lets a direct ActiveRecord::Base affix win over config.active_record" do
    result = settings("config/application.rb" => "class Application < Rails::Application\n  config.active_record.table_name_prefix = \"cfg_\"\nend\n",
                      "config/initializers/a.rb" => "ActiveRecord::Base.table_name_prefix = \"base_\"\n")

    expect(result[:table_name_prefix]).to eq("base_")
  end
end
