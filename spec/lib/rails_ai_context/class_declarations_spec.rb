# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Each app is written to disk for the walk and loaded into this process, where Rails reflection
# says what the class declares. The walk's answer must agree.
RSpec.describe RailsAiContext::ClassDeclarations do
  around do |example|
    raise "already defined: Tracker" if Object.const_defined?(:Tracker, false)

    Dir.mktmpdir("class-declarations") do |dir|
      @dir = dir
      example.run
    ensure
      Object.send(:remove_const, :Tracker) if Object.const_defined?(:Tracker, false)
    end
  end

  # Writes the files and runs them here, in the order given; answers which file declares a constant.
  def app(files)
    @files = {}
    files.each do |relative, source|
      path = File.join(@dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      TOPLEVEL_BINDING.eval(source, path)
      RailsAiContext::Introspectors::DeclaredConstant.declarations(source, all: true).each { |d| @files[d.name] ||= path }
    end
  end

  def walk(name, keys: %i[callbacks associations])
    described_class.for(name, lookup: ->(constant) { @files[constant] }, keys: keys, file: @files[name],
                              listeners: RailsAiContext::Introspectors::ModelIntrospector::LISTENERS, root: @dir, prefer: "model")
  end

  def saves(name) = walk(name).declarations[:callbacks].map { |callback| callback[:method].to_s }

  def booted_saves(klass) = klass._save_callbacks.map { |callback| callback.filter.to_s }

  let(:record) do
    { "app/models/concerns/tracker/stamped.rb" => <<~RUBY,
        module Tracker
          module Stamped
            extend ActiveSupport::Concern
            included do
              before_save :stamp
            end
          end
        end
      RUBY
      "app/models/tracker/record.rb" => <<~RUBY }
        module Tracker
          class Record < ActiveRecord::Base
            self.abstract_class = true
            before_save :base_first
            include Stamped
          end
        end
      RUBY
  end

  it "runs a superclass's body and its concern before the class, and a concern the chain already holds not again" do
    app(record.merge("app/models/tracker/item.rb" => <<~RUBY))
      module Tracker
        class Item < Record
          before_save :own_first
          include Stamped
          before_save :own_last
        end
      end
    RUBY

    expect(booted_saves(Tracker::Item)).to eq(%w[base_first stamp own_first own_last])
    expect(saves("Tracker::Item")).to eq(booted_saves(Tracker::Item))
    expect(walk("Tracker::Item").declarations[:callbacks].map { |callback| callback[:declared_in] }).to eq([ "Tracker::Record", "Tracker::Record", nil, nil ])
  end

  it "reads one class of a file that declares two" do
    app(record.merge("app/models/tracker/item.rb" => <<~RUBY))
      module Tracker
        class Item < Record
          before_save :item
        end

        class Special < Item
          before_save :special
        end
      end
    RUBY

    expect(saves("Tracker::Item")).to eq(booted_saves(Tracker::Item))
    expect(saves("Tracker::Special")).to eq(booted_saves(Tracker::Special))
  end

  it "runs a concern's class method macro at the class's call, with the call's arguments" do
    app(record.merge(
          "app/models/concerns/tracker/watched.rb" => <<~RUBY,
            module Tracker
              module Watched
                extend ActiveSupport::Concern
                class_methods do
                  def watches(name)
                    before_save :"watch_\#{name}"
                  end
                end
              end
            end
          RUBY
          "app/models/tracker/note.rb" => <<~RUBY
            module Tracker
              class Note < Record
                include Watched
                watches :title
              end
            end
          RUBY
        ))

    expect(booted_saves(Tracker::Note)).to eq(%w[base_first stamp watch_title])
    expect(saves("Tracker::Note")).to eq(booted_saves(Tracker::Note))
  end

  it "keeps a parent's skip where the parent declares it" do
    app(record.merge("app/models/tracker/middle.rb" => <<~RUBY, "app/models/tracker/leaf.rb" => <<~RUBY))
      module Tracker
        class Middle < Record
          self.abstract_class = true
          skip_callback :save, :before, :base_first
        end
      end
    RUBY
      module Tracker
        class Leaf < Middle
          before_save :leaf
        end
      end
    RUBY

    declared = walk("Tracker::Leaf").declarations[:callbacks]
    expect(declared.map { |callback| [ callback[:method].to_s, callback[:skip] || false, callback[:declared_in] ] })
      .to eq([ [ "base_first", false, "Tracker::Record" ], [ "stamp", false, "Tracker::Record" ], [ "base_first", true, "Tracker::Middle" ], [ "leaf", false, nil ] ])
    static = RailsAiContext::Introspectors::ModelIntrospector.new(RailsAiContext::StaticApp.new(@dir)).static_call
    expect(static["Tracker::Leaf"][:callbacks]).to eq("before_save" => booted_saves(Tracker::Leaf))
  end

  it "keeps a prepended callback's declaration where it is written, for the chain to put first" do
    app(record.merge("app/models/tracker/item.rb" => <<~RUBY))
      module Tracker
        class Item < Record
          before_save :own
          before_save :early, prepend: true
        end
      end
    RUBY

    expect(saves("Tracker::Item")).to eq(%w[base_first stamp own early])
    static = RailsAiContext::Introspectors::ModelIntrospector.new(RailsAiContext::StaticApp.new(@dir)).static_call
    expect(booted_saves(Tracker::Item)).to eq(%w[early base_first stamp own])
    expect(static["Tracker::Item"][:callbacks]).to eq("before_save" => booted_saves(Tracker::Item))
  end

  it "says which superclass and which concern it could not read" do
    path = File.join(@dir, "app/models/tracker/item.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "module Tracker\n  class Item < Record\n    include Lost\n  end\nend\n")
    @files = { "Tracker::Item" => path, "Tracker::Record" => File.join(@dir, "app/models/tracker/record.rb") }

    found = walk("Tracker::Item")
    expect(found.unread.map { |entry| [ entry.name, entry.reason ] }).to eq([ [ "Lost", :concern ], [ "Tracker::Record", :base ] ])
  end
end
