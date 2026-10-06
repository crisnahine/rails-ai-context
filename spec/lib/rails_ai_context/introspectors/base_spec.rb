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

      expect(check.call("ZzShop::Item", "ZzGemBase::Record")).to be(true)
      expect(check.call("ZzShop::Item", "String")).to be(false)
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

        expect(check.call("ZzLazyNs::ZzLazy::Item", "ZzGemBase::Record")).to be(true)
        expect(check.call("ZzLazyNs::ZzLazy::Item", "Unknown")).to be(false)
        expect(check.call("ZzLazyNs::ZzLazy::Item", "lowercase")).to be(false)
        expect($zz_lazy_ran).to be(false)
      end
    end
  end
end
