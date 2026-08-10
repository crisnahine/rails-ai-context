# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::StaticTier do
  def introspector_class(&body)
    Class.new do
      extend RailsAiContext::Introspectors::StaticTier
      class_exec(&body) if body
    end
  end

  describe "declaring" do
    it "records a files-only declaration" do
      klass = introspector_class { static_tier :files_only }
      expect(klass.static_tier).to eq(:files_only)
    end

    it "records a runtime-only declaration" do
      klass = introspector_class { static_tier :runtime_only }
      expect(klass.static_tier).to eq(:runtime_only)
    end

    it "records an alternate-source declaration" do
      klass = introspector_class do
        static_tier :alternate_source
        def static_call = {}
      end
      expect(klass.static_tier).to eq(:alternate_source)
    end

    it "rejects a kind it does not know, naming it" do
      expect { introspector_class { static_tier :probably_fine } }
        .to raise_error(ArgumentError, /probably_fine/)
    end

    it "reports an undeclared class as undeclared" do
      expect(introspector_class.static_tier).to be_nil
      expect(introspector_class).not_to be_static_tier_declared
    end

    it "reports a declared class as declared" do
      expect(introspector_class { static_tier :runtime_only }).to be_static_tier_declared
    end

    it "does not leak a declaration to a sibling class" do
      introspector_class { static_tier :files_only }
      expect(introspector_class.static_tier).to be_nil
    end

    it "inherits a declaration from a superclass" do
      parent = introspector_class { static_tier :files_only }
      expect(Class.new(parent).static_tier).to eq(:files_only)
    end
  end

  # Checked on demand rather than at declaration: the macro sits at the top of
  # a class, before the methods it talks about exist.
  describe "validate_static_tier!" do
    it "passes a consistent alternate-source class" do
      klass = introspector_class do
        static_tier :alternate_source
        def static_call = {}
      end
      expect { klass.validate_static_tier! }.not_to raise_error
    end

    it "rejects an alternate-source declaration with no static_call" do
      klass = introspector_class { static_tier :alternate_source }
      expect { klass.validate_static_tier! }.to raise_error(ArgumentError, /static_call/)
    end

    it "rejects a runtime-only declaration that defines static_call" do
      klass = introspector_class do
        static_tier :runtime_only
        def static_call = {}
      end
      expect { klass.validate_static_tier! }.to raise_error(ArgumentError, /static_call/)
    end

    it "rejects a files-only declaration that defines static_call" do
      klass = introspector_class do
        static_tier :files_only
        def static_call = {}
      end
      expect { klass.validate_static_tier! }.to raise_error(ArgumentError, /static_call/)
    end

    it "rejects an undeclared class, naming it" do
      stub_const("HalfFinishedIntrospector", introspector_class)
      expect { HalfFinishedIntrospector.validate_static_tier! }
        .to raise_error(ArgumentError, /HalfFinishedIntrospector/)
    end
  end

  describe "answers_statically?" do
    it "is true for files-only" do
      expect(introspector_class { static_tier :files_only }).to be_answers_statically
    end

    it "is true for alternate-source" do
      klass = introspector_class do
        static_tier :alternate_source
        def static_call = {}
      end
      expect(klass).to be_answers_statically
    end

    it "is false for runtime-only" do
      expect(introspector_class { static_tier :runtime_only }).not_to be_answers_statically
    end
  end
end
