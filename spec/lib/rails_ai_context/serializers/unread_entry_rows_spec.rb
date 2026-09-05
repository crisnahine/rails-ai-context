# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The generated files, driven by the real generator over a real app directory
# holding one model and one controller the walk cannot read. An entry rendered
# with its facts missing and no reason reads as an entry that declares nothing,
# which is a different answer from the one the tools give.
RSpec.describe "Generated files over an app with unreadable files" do
  # A local, not a constant: a constant assigned in a describe block lands on
  # Object and is visible to every later example in the run.
  let(:unreadable) { %w[app/models/vehicle.rb app/controllers/trucks_controller.rb] }

  def build_app(dir)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "routes.rb"), "Rails.application.routes.draw do\n  resources :cars\nend\n")
    File.write(File.join(dir, "app", "models", "car.rb"), <<~RUBY)
      class Car < ApplicationRecord
        belongs_to :owner
        validates :name, presence: true
      end
    RUBY
    File.write(File.join(dir, "app", "models", "vehicle.rb"), <<~RUBY)
      class Vehicle < ApplicationRecord
        belongs_to :owner
        validates :vin, presence: true
      end
    RUBY
    File.write(File.join(dir, "app", "controllers", "cars_controller.rb"), <<~RUBY)
      class CarsController < ApplicationController
        def index; end
      end
    RUBY
    File.write(File.join(dir, "app", "controllers", "trucks_controller.rb"), <<~RUBY)
      class TrucksController < ApplicationController
        def index; end
      end
    RUBY
    unreadable.each { |rel| make_unreadable(File.join(dir, rel)) }
  end

  # Every prose file the generator wrote, as path => contents. The JSON dump
  # is left out: it carries the error under its own key.
  def generated_files
    Dir.mktmpdir do |dir|
      build_app(dir)
      previous_tier = RailsAiContext.tier
      RailsAiContext.tier = :static
      allow(RailsAiContext.configuration).to receive(:output_dir_for).and_return(dir)

      result = RailsAiContext.generate_context(RailsAiContext::StaticApp.new(dir), format: :all)
      result[:written]
        .reject { |path| path.end_with?(".json") }
        .to_h { |path| [ path.sub("#{dir}/", ""), File.read(path) ] }
    ensure
      RailsAiContext.tier = previous_tier
      unreadable.each do |rel|
        path = File.join(dir, rel)
        File.chmod(0o644, path) if File.exist?(path)
      end
    end
  end

  def rows_naming(files, name)
    files.flat_map do |path, content|
      content.lines(chomp: true).select { |line| line.include?(name) }.map { |line| "#{path}: #{line}" }
    end
  end

  it "names the reason on every row for an entry the walk could not read" do
    files = generated_files

    model_rows = rows_naming(files, "Vehicle")
    controller_rows = rows_naming(files, "TrucksController")

    expect(model_rows).not_to be_empty
    expect(controller_rows).not_to be_empty
    (model_rows + controller_rows).each do |row|
      expect(row).to include("[UNAVAILABLE:")
    end
  end

  it "leaves no name of its own on Object" do
    expect(Object.const_defined?(:UNREADABLE)).to be(false)
  end
end
