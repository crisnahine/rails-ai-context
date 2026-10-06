# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::RakeTaskDslListener do
  it "detects namespace" do
    results = parse_and_dispatch("namespace :db do; end")
    ns = results.find { |r| r[:type] == :namespace }
    expect(ns).to include(type: :namespace, name: "db")
  end

  it "detects desc" do
    results = parse_and_dispatch('desc "Load seed data"')
    expect(results.size).to eq(1)
    expect(results.first).to include(type: :desc, description: "Load seed data")
  end

  it "detects simple task" do
    results = parse_and_dispatch("task :seed")
    tasks = results.select { |r| r[:type] == :task }
    expect(tasks.size).to eq(1)
    expect(tasks.first).to include(name: "seed", deps: [], args: [])
  end

  it "detects task with hash-rocket dependency" do
    results = parse_and_dispatch("task seed: :environment")
    tasks = results.select { |r| r[:type] == :task }
    expect(tasks.size).to eq(1)
    expect(tasks.first).to include(name: "seed", deps: [ "environment" ])
  end

  it "detects task with array dependencies" do
    results = parse_and_dispatch("task seed: [:environment, :setup]")
    tasks = results.select { |r| r[:type] == :task }
    expect(tasks.first[:deps]).to eq([ "environment", "setup" ])
  end

  it "detects task with arguments and dependency" do
    results = parse_and_dispatch("task :import, [:limit, :offset] => :environment")
    tasks = results.select { |r| r[:type] == :task }
    expect(tasks.first).to include(name: "import", args: [ "limit", "offset" ], deps: [ "environment" ])
  end

  it "reads arguments given without dependencies" do
    tasks = parse_and_dispatch("task :go, [:a, :b] do |t, args|; end\ntask :old, :x, :y").select { |r| r[:type] == :task }
    expect(tasks.map { |t| [ t[:name], t[:args], t[:deps] ] }).to eq([ [ "go", %w[a b], [] ], [ "old", %w[x y], [] ] ])
  end

  it "detects a full rake file with namespace, desc, and task" do
    results = parse_and_dispatch(<<~RUBY)
      namespace :db do
        desc "Seed the database"
        task seed: :environment
      end
    RUBY

    types = results.map { |r| r[:type] }
    expect(types).to include(:namespace, :desc, :task)
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY)
      desc "Do something"
      task :something
    RUBY

    expect(results[0][:location]).to eq(1)
    expect(results[1][:location]).to eq(2)
  end

  it "reads a string-named task and a multitask" do
    results = parse_and_dispatch(%(task "string:named"\nmultitask parallel: %w[a b]\n))
    tasks = results.select { |r| r[:type] == :task }
    expect(tasks.map { |t| [ t[:name], t[:deps] ] }).to eq([ [ "string:named", [] ], [ "parallel", %w[a b] ] ])
  end

  it "gives a namespace the offsets its block spans" do
    source = "namespace(:beta) { task :inside }; task :after\n"
    ns, inside, after = parse_and_dispatch(source)
    expect(ns[:end_offset]).to eq(source.index(";"))
    expect(inside[:offset]).to be < ns[:end_offset]
    expect(after[:offset]).to be >= ns[:end_offset]
  end
end
