# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MethodCallListener do
  def walk(source, **opts)
    RailsAiContext::Introspectors::SourceIntrospector.walk_source(source, { calls: -> { described_class.new(**opts) } })[:calls]
  end

  it "finds a call by name wherever it sits, with its line and arguments" do
    source = <<~RUBY
      class Post < ApplicationRecord
        after_create_commit -> { broadcast_append_to "posts", target: "list", partial: "posts/post" }

        def refresh = broadcast_replace_to(self)
      end
    RUBY
    calls = walk(source, pattern: /\Abroadcasts?_\w+_to\z/)

    expect(calls.map { |c| c[:name] }).to eq(%w[broadcast_append_to broadcast_replace_to])
    expect(calls.first[:line]).to eq(2)
    expect(calls.first[:arguments]).to eq([ "posts" ])
    expect(calls.first[:options]).to eq({ target: "list", partial: "posts/post" })
    expect(calls.last[:arguments]).to eq([ "self" ])
  end

  it "ignores a name inside a comment, a string or a heredoc" do
    source = <<~RUBY
      # broadcast_append_to is documented here
      NOTE = "broadcast_append_to"
      DOC = <<~TXT
        broadcast_append_to
      TXT
      broadcast_append_to :posts
    RUBY
    expect(walk(source, names: [ :broadcast_append_to ]).size).to eq(1)
  end

  it "keeps the receiver and the source slice of a non-literal argument" do
    calls = walk("turbo_stream_from @post\nhelpers.turbo_frame_tag dom_id(@post, :edit)\n", names: %i[turbo_stream_from turbo_frame_tag])

    expect(calls[0][:receiver]).to be_nil
    expect(calls[0][:arguments]).to eq([ "@post" ])
    expect(calls[1][:receiver]).to eq("helpers")
    expect(calls[1][:arguments]).to eq([ "dom_id(@post, :edit)" ])
  end
end
