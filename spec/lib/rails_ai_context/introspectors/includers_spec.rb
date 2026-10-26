# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::Includers do
  def of(names, files, via: :of, **options)
    Dir.mktmpdir do |dir|
      sources = files.map do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        [ path, body ]
      end
      RailsAiContext::PathResolver.clear_code_roots
      return described_class.public_send(via, dir, sources, names, **options)
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

  # `include ::Priced` is Object's Priced however near a Shop::Priced is.
  it "credits an include written from the root to the top-level module" do
    result = of(%w[Shop::Priced Priced], {
      "app/models/concerns/priced.rb" => "module Priced\nend\n",
      "app/models/concerns/shop/priced.rb" => "module Shop\n  module Priced\n  end\nend\n",
      "app/models/shop/tool.rb" => "module Shop\n  class Tool\n    include ::Priced\n  end\nend\n"
    })

    expect(result).to eq("Priced" => [ "Shop::Tool" ])
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

  # Module.nesting in `module Admin::Billing` is [Admin::Billing] alone, so its `include Helper` never reaches Admin::Helper.
  it "resolves an include in a compact namespace from that namespace alone" do
    result = of(%w[Admin::Helper Helper], {
      "app/models/admin/helper.rb" => "module Admin::Helper\nend\n",
      "app/models/helper.rb" => "module Helper\nend\n",
      "app/models/admin/billing.rb" => "class Admin::Billing\n  include Helper\nend\n"
    })

    expect(result).to eq("Helper" => [ "Admin::Billing" ])
  end

  it "names a `Target.include X` target as Ruby resolves it where the line is written" do
    result = of(%w[Taggable], {
      "app/models/concerns/taggable.rb" => "module Taggable\n  extend ActiveSupport::Concern\nend\n",
      "app/models/admin/widget.rb" => "module Admin\n  module Widget\n  end\nend\n",
      "config/initializers/tagging.rb" => "module Admin\n  Widget.include(Taggable)\nend\n"
    }, via: :kinds)

    expect(result).to eq("Taggable" => { "Admin::Widget" => :module })
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

  # Module.nesting in `module Shop; class ::Order` is [Order, Shop]: the class is the top-level Order, and Shop is still searched.
  it "names a class opened from the root inside a module by its own name, resolving through the module" do
    result = of(%w[Shop::Pricing], {
      "app/models/shop/pricing.rb" => "module Shop::Pricing\nend\n",
      "app/models/order.rb" => "module Shop\n  class ::Order\n    include Pricing\n  end\nend\n"
    })

    expect(result).to eq("Shop::Pricing" => [ "Order" ])
  end

  # A Class.new block opens no scope: inside it Module.nesting is [Shop], so `include Pricing` never reaches Shop::Draft::Pricing.
  it "resolves an include in a Class.new block from the scope around the assignment" do
    result = of(%w[Shop::Pricing Shop::Draft::Pricing], {
      "app/models/shop/pricing.rb" => "module Shop::Pricing\nend\n",
      "app/models/shop/draft/pricing.rb" => "module Shop::Draft::Pricing\nend\n",
      "app/models/shop/draft.rb" => "module Shop\n  Draft = Class.new(ApplicationRecord) do\n    include Pricing\n  end\nend\n"
    })

    expect(result).to eq("Shop::Pricing" => [ "Shop::Draft" ])
  end
end
