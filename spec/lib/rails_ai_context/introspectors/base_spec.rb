# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Base do
  let(:app) { double("app", root: Pathname.new("/srv/shop")) }

  it "keeps the app it was built with" do
    expect(described_class.new(app).app).to be(app)
  end

  it "gives a subclass the app root as a string" do
    subclass = Class.new(described_class) { def call = root }

    expect(subclass.new(app).call).to eq("/srv/shop")
  end

  # A subclass that forgets its declaration must not inherit a tier from here.
  it "declares no static tier for a subclass to inherit" do
    subclass = Class.new(described_class) { extend RailsAiContext::Introspectors::StaticTier }

    expect(subclass.static_tier).to be_nil
  end

  describe "the booted record base check" do
    let(:check) { described_class.new(Rails.application).send(:model_base_check) }

    it "takes a loaded abstract base a gem or initializer defines, from a nested scope too" do
      stub_const("ZzGemBase::Record", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      stub_const("ZzShop", Module.new)

      expect(check.call(%w[ZzShop::ZzGemBase::Record ZzGemBase::Record])).to be(true)
      expect(check.call(%w[ZzShop::String String])).to be(false)
    end

    # Resolving a name must not run an app file the boot never loaded.
    it "leaves a constant that is not loaded yet unloaded" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "zz_lazy.rb")
        File.write(file, "$zz_lazy_ran = true\nmodule ZzLazyNs; module ZzLazy; end; end\n")
        stub_const("ZzLazyNs", Module.new)
        ZzLazyNs.autoload(:ZzLazy, file)
        stub_const("ZzGemBase::Record", Class.new(ActiveRecord::Base) { self.abstract_class = true })
        $zz_lazy_ran = false

        expect(check.call(%w[ZzLazyNs::ZzLazy::ZzGemBase::Record ZzLazyNs::ZzGemBase::Record ZzGemBase::Record])).to be(true)
        expect(check.call(%w[ZzLazyNs::ZzLazy::Unknown Unknown])).to be(false)
        expect(check.call(%w[ZzLazyNs::ZzLazy::lowercase lowercase])).to be(false)
        expect($zz_lazy_ran).to be(false)
      end
    end
  end

  # Ruby looks up the superclass of a compact `class A::B < X` from the top level, of a nested one from A.
  describe "a model outside app/models whose base name a namespace also holds" do
    let(:domain) { Rails.root.join("app", "zz_scope_domain") }

    before do
      FileUtils.mkdir_p(domain.join("zz_ns"))
      allow(RailsAiContext::PathResolver).to receive(:extra_model_roots).and_return([ domain.to_s ])
      stub_const("ZzNs::ZzBase", Class.new)
      stub_const("ZzBase", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    end

    after { FileUtils.rm_rf(domain) }

    def listed
      described_class.new(Rails.application).send(:model_sources).map(&:path_name)
    end

    it "reads a compact declaration's base from the top level" do
      File.write(domain.join("zz_ns", "zz_item.rb"), "class ZzNs::ZzItem < ZzBase\nend\n")

      expect(listed).to include("ZzNs::ZzItem")
    end

    it "reads a nested declaration's base from its namespace" do
      File.write(domain.join("zz_ns", "zz_item.rb"), "module ZzNs\n  class ZzItem < ZzBase\n  end\nend\n")

      expect(listed).not_to include("ZzNs::ZzItem")
    end

    it "reads a base written from the root at the top level only" do
      File.write(domain.join("zz_ns", "zz_item.rb"), "module ZzNs\n  class ZzItem < ::ZzBase\n  end\nend\n")

      expect(listed).to include("ZzNs::ZzItem")
    end

    it "does not read a base written from the root in the namespace" do
      stub_const("ZzNs::ZzBase", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      stub_const("ZzBase", Class.new)
      File.write(domain.join("zz_ns", "zz_item.rb"), "module ZzNs\n  class ZzItem < ::ZzBase\n  end\nend\n")

      expect(listed).not_to include("ZzNs::ZzItem")
    end
  end
end
