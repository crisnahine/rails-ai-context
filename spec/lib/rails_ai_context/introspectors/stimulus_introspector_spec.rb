# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::StimulusIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    context "with permanent Stimulus controller fixtures" do
      it "discovers all controllers" do
        result = introspector.call
        names = result[:controllers].map { |c| c[:name] }
        expect(names).to include("hello", "search", "tabs")
      end

      it "extracts targets from hello controller" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:targets]).to contain_exactly("output", "input", "counter")
      end

      it "extracts complex values with defaults" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:values]["greeting"]).to include("String")
        expect(hello[:values]["greeting"]).to include("Hello")
        expect(hello[:values]["count"]).to eq("Number")
      end

      it "extracts actions" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:actions]).to include("greet", "clear", "toggle")
      end

      it "records the lifecycle hooks the controller defines" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:lifecycle]).to eq(%w[connect])
      end

      it "extracts outlets" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:outlets]).to contain_exactly("search", "results")
      end

      it "extracts classes" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:classes]).to contain_exactly("active", "hidden")
      end

      it "extracts async methods as actions" do
        result = introspector.call
        search = result[:controllers].find { |c| c[:name] == "search" }
        expect(search[:actions]).to include("search", "clear")
      end

      it "does not include control flow keywords" do
        result = introspector.call
        search = result[:controllers].find { |c| c[:name] == "search" }
        expect(search[:actions]).not_to include("if", "for", "while")
      end

      it "extracts outlets from search controller" do
        result = introspector.call
        search = result[:controllers].find { |c| c[:name] == "search" }
        expect(search[:outlets]).to contain_exactly("filter-form", "results-list")
      end

      it "extracts values from tabs controller" do
        result = introspector.call
        tabs = result[:controllers].find { |c| c[:name] == "tabs" }
        expect(tabs[:values]["activeIndex"]).to include("Number")
      end

      describe "import_graph" do
        it "extracts imports from hello controller" do
          result = introspector.call
          hello = result[:controllers].find { |c| c[:name] == "hello" }
          expect(hello[:import_graph]).to include("@hotwired/stimulus")
        end

        it "extracts multiple imports from search controller" do
          result = introspector.call
          search = result[:controllers].find { |c| c[:name] == "search" }
          expect(search[:import_graph]).to include("@hotwired/stimulus", "lodash/debounce")
        end
      end

      describe "complexity" do
        it "returns loc and method_count for hello controller" do
          result = introspector.call
          hello = result[:controllers].find { |c| c[:name] == "hello" }
          expect(hello[:complexity]).to be_a(Hash)
          expect(hello[:complexity][:loc]).to be > 0
          expect(hello[:complexity][:method_count]).to eq(4)
        end

        it "returns loc and method_count for search controller" do
          result = introspector.call
          search = result[:controllers].find { |c| c[:name] == "search" }
          expect(search[:complexity][:method_count]).to eq(4)
        end
      end

      describe "turbo_event_listeners" do
        it "detects turbo event listeners in tabs controller" do
          result = introspector.call
          tabs = result[:controllers].find { |c| c[:name] == "tabs" }
          expect(tabs[:turbo_event_listeners]).to include("turbo:before-fetch-request")
        end

        it "returns empty array for controllers without turbo events" do
          result = introspector.call
          hello = result[:controllers].find { |c| c[:name] == "hello" }
          expect(hello[:turbo_event_listeners]).to eq([])
        end
      end

      describe "cross_controller_composition" do
        it "detects multi-controller elements in views" do
          result = introspector.call
          compositions = result[:cross_controller_composition]
          expect(compositions).to be_an(Array)
          multi = compositions.find { |c| c[:controllers].include?("search") && c[:controllers].include?("tabs") }
          expect(multi).not_to be_nil
        end

        it "includes file path for multi-controller elements" do
          result = introspector.call
          compositions = result[:cross_controller_composition]
          multi = compositions.find { |c| c[:controllers].size > 1 }
          expect(multi[:file]).to be_a(String)
        end
      end
    end
  end
end
