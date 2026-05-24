# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::GemfileDslListener do
  def parse_and_dispatch(source)
    result     = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener   = described_class.new
    events = []
    events << :on_call_node_enter if listener.respond_to?(:on_call_node_enter)
    events << :on_call_node_leave if listener.respond_to?(:on_call_node_leave)
    dispatcher.register(listener, *events)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects gem with name only" do
    results = parse_and_dispatch('gem "rails"')
    gems = results.select { |r| r[:type] == :gem }
    expect(gems.size).to eq(1)
    expect(gems.first).to include(name: "rails", version: nil)
  end

  it "detects gem with version" do
    results = parse_and_dispatch('gem "rails", "~> 7.1"')
    gems = results.select { |r| r[:type] == :gem }
    expect(gems.first).to include(name: "rails", version: "~> 7.1")
  end

  it "detects gem with path option" do
    results = parse_and_dispatch('gem "my_engine", path: "../engines/my_engine"')
    gems = results.select { |r| r[:type] == :gem }
    expect(gems.first[:options]).to include(path: "../engines/my_engine")
  end

  it "detects gem with git and branch options" do
    results = parse_and_dispatch('gem "devise", git: "https://github.com/heartcombo/devise", branch: "main"')
    gems = results.select { |r| r[:type] == :gem }
    expect(gems.first[:options]).to include(git: "https://github.com/heartcombo/devise", branch: "main")
  end

  it "detects gem with require: false" do
    results = parse_and_dispatch('gem "bootsnap", require: false')
    gems = results.select { |r| r[:type] == :gem }
    expect(gems.first[:options]).to include(require: false)
  end

  it "detects group block and tags gems within" do
    results = parse_and_dispatch(<<~RUBY)
      group :development, :test do
        gem "rspec-rails"
        gem "factory_bot_rails"
      end
    RUBY

    gems = results.select { |r| r[:type] == :gem }
    expect(gems.size).to eq(2)
    gems.each do |g|
      expect(g[:groups]).to contain_exactly(:development, :test)
    end

    groups = results.select { |r| r[:type] == :group }
    expect(groups.size).to eq(1)
    expect(groups.first[:groups]).to contain_exactly(:development, :test)
  end

  it "does not leak group context after block ends" do
    results = parse_and_dispatch(<<~RUBY)
      group :test do
        gem "rspec"
      end
      gem "rails"
    RUBY

    gems = results.select { |r| r[:type] == :gem }
    rspec = gems.find { |g| g[:name] == "rspec" }
    rails = gems.find { |g| g[:name] == "rails" }

    expect(rspec[:groups]).to eq([ :test ])
    expect(rails[:groups]).to eq([])
  end

  it "detects gem with inline group option" do
    results = parse_and_dispatch('gem "web-console", group: :development')
    gems = results.select { |r| r[:type] == :gem }
    expect(gems.first[:groups]).to eq([ :development ])
  end

  it "detects source declarations" do
    results = parse_and_dispatch('source "https://rubygems.org"')
    sources = results.select { |r| r[:type] == :source }
    expect(sources.size).to eq(1)
    expect(sources.first[:url]).to eq("https://rubygems.org")
  end

  it "includes line locations" do
    results = parse_and_dispatch(<<~RUBY)
      source "https://rubygems.org"
      gem "rails"
    RUBY

    expect(results[0][:location]).to eq(1)
    expect(results[1][:location]).to eq(2)
  end
end
