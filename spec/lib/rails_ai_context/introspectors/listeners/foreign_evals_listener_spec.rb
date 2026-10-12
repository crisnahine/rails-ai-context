# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ForeignEvalsListener do
  it "records a class-body block evaluated on another receiver, with each line's calls" do
    blocks = parse_and_dispatch(<<~RUBY)
      class Budget::Investment < ApplicationRecord
        audited on: [:update, :destroy]
        translation_class.class_eval do
          audited associated_with: :globalized_model,
                  only: %i[title description]
        end
      end
    RUBY

    expect(blocks.map { |block| [ block[:receiver], block[:lines] ] }).to eq([ [ "translation_class", 3..6 ] ])
    expect(blocks.first[:calls][4].map { |call| call[:source] }).to eq([ "audited associated_with: :globalized_model, only: %i[title description]" ])
  end

  it "leaves out a block opened inside a method" do
    blocks = parse_and_dispatch(<<~RUBY)
      class Post < ApplicationRecord
        def self.tweak
          other.class_eval { scope :recent, -> { all } }
        end
      end
    RUBY

    expect(blocks).to be_empty
  end
end
