# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Tools::GetModelDetails do
  def structure_of(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "widget.rb")
      File.write(path, source)
      allow(described_class).to receive(:resolved_model_path).and_return(path)
      allow(described_class).to receive(:relative_model_path).and_return("app/models/widget.rb")
      described_class.send(:extract_model_structure, "Widget")[:sections].map { |s| [ s[:label], s[:start] ] }
    end
  end

  it "labels a def by the method it defines, not by how the line starts" do
    sections = structure_of(<<~RUBY)
      class Widget < ApplicationRecord
        def Widget.beta; end

        private_class_method def self.zeta; end

        def theta; end

        private

        class << self
          def iota; end
        end
      end
    RUBY

    expect(sections).to eq([
      [ "class definition", 1 ], [ "class methods", 2 ], [ "instance methods", 6 ],
      [ "private", 8 ], [ "class methods", 11 ]
    ])
  end

  it "labels a class built with Class.new as its definition" do
    sections = structure_of(<<~RUBY)
      Widget = Class.new(ApplicationRecord) do
        self.table_name = "gizmos"
      end
    RUBY

    expect(sections).to eq([ [ "class definition", 1 ] ])
  end

  it "does not count a def in a scope's block as a method of the model" do
    sections = structure_of(<<~RUBY)
      class Widget < ApplicationRecord
        scope :recent, -> { order(:id) } do
          def first_two = limit(2)
        end
      end
    RUBY

    expect(sections).to eq([ [ "class definition", 1 ], [ "scopes", 2 ] ])
  end
end
