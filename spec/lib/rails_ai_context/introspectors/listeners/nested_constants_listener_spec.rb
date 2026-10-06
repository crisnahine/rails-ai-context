# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::NestedConstantsListener do
  it "records the offset range of each module and class a class body nests, not the class itself" do
    source = <<~RUBY
      class PostsController < ApplicationController
        module Helpers
          def x; end
        end
        class Inner
        end
      end
      module TopLevel
      end
    RUBY

    ranges = RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { nested: described_class })[:nested]

    expect(ranges.map { |range| source[range].lines.first.strip }).to eq([ "module Helpers", "class Inner" ])
  end
end
