# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::Includers do
  def of(names, files, **options)
    Dir.mktmpdir do |dir|
      sources = files.map do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        [ path, body ]
      end
      RailsAiContext::PathResolver.clear_code_roots
      return described_class.of(dir, sources, names, **options)
    end
  end

  # Ruby resolves `include Helper` from the includer's namespace outward, so
  # Admin::Report's include names Admin::Helper and Report's names ::Helper.
  it "credits each include to the module it resolves to from the includer's namespace" do
    result = of(%w[Admin::Helper Helper], {
      "app/models/admin/helper.rb" => "module Admin::Helper\nend\n",
      "app/models/helper.rb" => "module Helper\nend\n",
      "app/models/admin/report.rb" => "module Admin\n  class Report\n    include Helper\n  end\nend\n",
      "app/models/report.rb" => "class Report\n  include Helper\nend\n"
    })

    expect(result).to eq("Admin::Helper" => [ "Admin::Report" ], "Helper" => [ "Report" ])
  end

  # A qualified name's first segment resolves from the namespace outward too.
  it "credits a relative qualified include to the module it names from the includer's namespace" do
    result = of(%w[Wiki::Concerns::Request], {
      "app/services/wiki/concerns/request.rb" => "module Wiki\n  module Concerns\n    module Request\n    end\n  end\nend\n",
      "app/services/wiki/queries/search.rb" => "module Wiki\n  module Queries\n    class Search\n      include Concerns::Request\n    end\n  end\nend\n",
      "app/services/other.rb" => "class Other\n  include ::Concerns::Request\nend\n"
    })

    expect(result).to eq("Wiki::Concerns::Request" => [ "Wiki::Queries::Search" ])
  end

  it "credits `Target.include X` and `Target.send(:include, X)` to the target" do
    result = of(%w[StatusPatch], {
      "lib/patch.rb" => "module StatusPatch\nend\nType.include(StatusPatch)\nStatus.send(:include, StatusPatch)\n"
    })

    expect(result).to eq("StatusPatch" => %w[Type Status])
  end

  it "counts only the macros asked about" do
    result = of(%w[Finder], { "app/models/post.rb" => "class Post\n  extend Finder\nend\n" }, macros: %i[include])

    expect(result).to eq({})
  end
end
