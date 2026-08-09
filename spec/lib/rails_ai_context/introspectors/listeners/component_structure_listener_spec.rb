# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ComponentStructureListener do
  def structure(source)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, {
      structure: described_class
    })[:structure]
  end

  describe "slot methods" do
    it "detects a method taking a block parameter" do
      results = structure(<<~RUBY)
        class CardComponent < Phlex::HTML
          def header(&block)
            div { yield }
          end
        end
      RUBY

      expect(results).to include(a_hash_including(kind: :slot, name: "header"))
    end

    it "detects an anonymous block parameter" do
      results = structure("class C < Phlex::HTML; def footer(&); end; end")

      expect(results.map { |r| r[:name] }).to include("footer")
    end

    it "ignores lifecycle hooks and methods without a block" do
      results = structure(<<~RUBY)
        class CardComponent < Phlex::HTML
          def initialize(&block)
          end

          def view_template(&block)
          end

          def title
          end
        end
      RUBY

      expect(results.select { |r| r[:kind] == :slot }).to be_empty
    end
  end

  describe "slot macros" do
    it "covers renders_one and renders_many" do
      results = structure(<<~RUBY)
        class CardComponent < ViewComponent::Base
          renders_one :header
          renders_many :items
        end
      RUBY

      expect(results.select { |r| r[:kind] == :slot_macro }.map { |r| [ r[:name], r[:type] ] })
        .to eq([ [ "header", :one ], [ "items", :many ] ])
    end

    it "records the renderer argument when one is given" do
      results = structure("class C < ViewComponent::Base; renders_one :header, HeaderComponent; end")

      expect(results.first[:renderer]).to eq("HeaderComponent")
    end

    it "omits the renderer key when there is none" do
      results = structure("class C < ViewComponent::Base; renders_many :items; end")

      expect(results.first).not_to have_key(:renderer)
    end
  end

  describe "constant tables" do
    it "extracts hash constant keys" do
      results = structure('VARIANTS = { primary: "a", secondary: "b" }')

      expect(results).to include(
        a_hash_including(kind: :constant_table, name: "VARIANTS", values: %w[primary secondary])
      )
    end

    it "extracts array constant elements" do
      results = structure("SIZES = [:sm, :md, :lg]")

      expect(results.first[:values]).to eq(%w[sm md lg])
    end

    it "extracts multi-line and string-keyed tables" do
      results = structure(<<~RUBY)
        THEMES = {
          "light" => "bg-white",
          "dark"  => "bg-black"
        }
      RUBY

      expect(results.first[:values]).to eq(%w[light dark])
    end

    it "ignores constants that are not tables" do
      expect(structure('DEFAULT = "primary"')).to be_empty
    end
  end

  describe "variant branching" do
    it "detects a case on an instance variable" do
      results = structure(<<~RUBY)
        class ButtonComponent < ViewComponent::Base
          def classes
            case @variant
            when :primary then "bg-blue"
            when :danger, :warning then "bg-red"
            else "bg-gray"
            end
          end
        end
      RUBY

      expect(results).to include(
        a_hash_including(kind: :variant_branch, ivar: "variant", values: %w[primary danger warning])
      )
    end

    it "ignores a case on anything else" do
      results = structure("case value\nwhen :a then 1\nend")

      expect(results.select { |r| r[:kind] == :variant_branch }).to be_empty
    end
  end

  describe "constant indexing" do
    it "links an instance variable to the constant table it indexes" do
      results = structure("class C; def size_class = SIZES[@size]; end")

      expect(results).to include(
        a_hash_including(kind: :constant_index, constant: "SIZES", ivar: "size")
      )
    end
  end
end
