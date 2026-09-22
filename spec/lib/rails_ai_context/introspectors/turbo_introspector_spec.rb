# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::TurboIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "discovers turbo frames with id, file and line" do
      expect(result[:turbo_frames]).to be_an(Array)
      frame = result[:turbo_frames].find { |f| f[:id] == "post" }
      expect(frame).not_to be_nil
      expect(frame[:file]).to eq("app/views/posts/show.html.erb")
      expect(frame[:line]).to eq(1)
    end

    it "discovers turbo stream templates" do
      expect(result[:turbo_streams]).to include("posts/create.turbo_stream.erb")
    end

    it "returns model_broadcasts as empty when no broadcasts in models" do
      expect(result[:model_broadcasts]).to eq([])
    end

    describe "morph_meta" do
      it "detects turbo-refresh-method morph meta tag in layouts" do
        expect(result[:morph_meta]).to be true
      end
    end

    describe "permanent_elements" do
      it "returns an array of elements with data-turbo-permanent" do
        expect(result[:permanent_elements]).to be_an(Array)
        expect(result[:permanent_elements].size).to be >= 2
      end

      it "extracts id from permanent elements" do
        element_with_id = result[:permanent_elements].find { |e| e[:id] == "main-content" }
        expect(element_with_id).not_to be_nil
      end

      it "includes permanent elements from view templates" do
        show_element = result[:permanent_elements].find { |e| e[:file] == "posts/show.html.erb" }
        expect(show_element).not_to be_nil
      end
    end

    describe "turbo_drive_settings" do
      it "returns a hash of turbo drive attribute counts" do
        expect(result[:turbo_drive_settings]).to be_a(Hash)
      end

      it "counts data-turbo-action occurrences" do
        expect(result[:turbo_drive_settings][:"data-turbo-action"]).to be >= 1
      end

      it "counts an attribute in a layout once, not twice" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app/views/layouts"))
          File.write(File.join(dir, "app/views/layouts/application.html.erb"),
                     %(<body data-turbo-action="advance"><%= yield %></body>))

          counts = described_class.new(double(root: dir)).send(:extract_turbo_drive_settings)

          expect(counts[:"data-turbo-action"]).to eq(1)
        end
      end
    end

    describe "turbo_stream_responses" do
      it "returns an array of controller actions with turbo_stream responses" do
        expect(result[:turbo_stream_responses]).to be_an(Array)
      end

      it "detects format.turbo_stream in PostsController#create" do
        response = result[:turbo_stream_responses].find { |r| r[:controller] == "PostsController" && r[:action] == "create" }
        expect(response).not_to be_nil
      end
    end

    context "with a model that uses broadcasts" do
      let(:fixture_model) { File.join(Rails.root, "app/models/message.rb") }

      before do
        File.write(fixture_model, <<~RUBY)
          class Message < ApplicationRecord
            broadcasts_to :room
            broadcasts_refreshes_to :room
          end
        RUBY
      end

      after { FileUtils.rm_f(fixture_model) }

      it "detects model broadcasts, one entry per macro" do
        broadcasts = result[:model_broadcasts].select { |b| b[:model] == "Message" }
        expect(broadcasts.map { |b| b[:macro] }).to eq(%w[broadcasts_to broadcasts_refreshes_to])
        expect(broadcasts.map { |b| b[:stream] }).to eq(%w[room room])
        expect(broadcasts.map { |b| b[:line] }).to eq([ 2, 3 ])
        expect(broadcasts.first[:file]).to eq("app/models/message.rb")
      end
    end

    describe "turbo_native" do
      it "returns a hash with turbo native keys" do
        native = result[:turbo_native]
        expect(native).to be_a(Hash)
        expect(native).to have_key(:detected)
        expect(native).to have_key(:native_helpers)
        expect(native).to have_key(:native_navigation)
        expect(native).to have_key(:native_conditionals)
      end

      it "returns false for detected when no native include" do
        expect(result[:turbo_native][:detected]).to be false
      end

      it "returns empty arrays and zero when no native usage" do
        native = result[:turbo_native]
        expect(native[:native_helpers]).to eq([])
        expect(native[:native_navigation]).to eq([])
        expect(native[:native_conditionals]).to eq(0)
      end

      context "with Turbo Native controllers" do
        let(:native_controller) { File.join(Rails.root, "app/controllers/native_controller.rb") }

        before do
          File.write(native_controller, <<~RUBY)
            class NativeController < ApplicationController
              include Turbo::Native::Navigation

              def show
                if turbo_native_app?
                  recede_or_redirect_to root_path
                else
                  redirect_to root_path
                end
              end

              def update
                resume_or_redirect_back_or_to root_path
              end
            end
          RUBY
        end

        after { FileUtils.rm_f(native_controller) }

        it "detects Turbo::Native::Navigation include" do
          expect(result[:turbo_native][:detected]).to be true
        end

        it "detects native helper usage in controllers" do
          expect(result[:turbo_native][:native_helpers]).to include("app/controllers/native_controller.rb")
        end

        it "detects native navigation methods" do
          nav = result[:turbo_native][:native_navigation]
          expect(nav).to include(
            { file: "app/controllers/native_controller.rb", method: "recede_or_redirect_to" },
            { file: "app/controllers/native_controller.rb", method: "resume_or_redirect_back_or_to" }
          )
        end
      end

      context "with hotwire_native_app? in views" do
        let(:view_file) { File.join(Rails.root, "app/views/posts/_native_check.html.erb") }

        before do
          File.write(view_file, <<~ERB)
            <% if hotwire_native_app? %>
              <p>Native app detected</p>
            <% end %>
            <% if turbo_native_app? %>
              <p>Turbo native detected</p>
            <% end %>
          ERB
        end

        after { FileUtils.rm_f(view_file) }

        it "counts native conditionals in views" do
          expect(result[:turbo_native][:native_conditionals]).to be >= 2
        end
      end
    end
  end

  describe "against the static fixture" do
    let(:app) { RailsAiContext::StaticApp.new(IntrospectedFixture::ROOT) }

    it "records the fixture's frames and model broadcasts" do
      result = described_class.new(app).call

      expect(result[:turbo_frames]).to eq([
        { id: "dom_id(@post, :edit)", src: nil, file: "app/views/posts/edit.html.erb", line: 1, snippet: "<%= turbo_frame_tag dom_id(@post, :edit) do %>" },
        { id: "dom_id(@post, :edit)", src: nil, file: "app/views/posts/index.html.erb", line: 2, snippet: "<%= turbo_frame_tag dom_id(@post, :edit) %>" },
        { id: "post", src: nil, file: "app/views/posts/show.html.erb", line: 1, snippet: "<%= turbo_frame_tag :post do %>" }
      ])
      expect(result[:model_broadcasts]).to eq([
        { model: "Comment", macro: "broadcasts_to", stream: nil, file: "app/models/comment.rb", line: 7,
          snippet: "broadcasts_to ->(comment) { [comment.post, :comments] }" }
      ])
    end

    it "records every broadcast, subscription and frame with its file and line" do
      result = described_class.new(app).call

      expect(result[:model_broadcasts]).to include(a_hash_including(model: "Comment", macro: "broadcasts_to", file: "app/models/comment.rb", line: an_instance_of(Integer)))
      expect(result[:stream_subscriptions]).to include(a_hash_including(stream: "@post", file: "app/views/posts/index.html.erb"))
      expect(result[:turbo_frames]).to include(a_hash_including(id: "dom_id(@post, :edit)", file: "app/views/posts/index.html.erb"))
    end

    it "keeps the subscription's line and source" do
      result = described_class.new(app).call

      expect(result[:stream_subscriptions]).to eq([
        { stream: "@post", file: "app/views/posts/index.html.erb", line: 1, snippet: "<%= turbo_stream_from @post %>" }
      ])
      expect(result[:explicit_broadcasts]).to eq([])
    end
  end

  describe "a subscription whose argument carries its own commas" do
    def streams_for(view)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "views", "posts"))
        File.write(File.join(dir, "app", "views", "posts", "index.html.erb"), view)
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        result[:stream_subscriptions].map { |s| s[:stream] }
      end
    end

    it "keeps an array argument whole" do
      expect(streams_for("<%= turbo_stream_from [current_user, :notifications] %>\n"))
        .to eq([ "[current_user, :notifications]" ])
    end

    it "keeps a call argument whole" do
      expect(streams_for("<%= turbo_stream_from dom_id(@post, :x) %>\n")).to eq([ "dom_id(@post, :x)" ])
    end

    it "strips the colon from a whole symbol argument" do
      expect(streams_for("<%= turbo_stream_from :posts %>\n")).to eq([ "posts" ])
    end

    it "still splits two top-level arguments" do
      expect(streams_for("<%= turbo_stream_from \"posts\", :comments %>\n")).to eq([ "posts, comments" ])
    end
  end

  describe "concerns and the model walk" do
    def app_in(dir)
      RailsAiContext::StaticApp.new(dir)
    end

    it "reports broadcasts declared in a model concern and a controller concern under the concern's name" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        File.write(File.join(dir, "app", "models", "concerns", "commentable.rb"), <<~RUBY)
          module Commentable
            extend ActiveSupport::Concern
            included do
              broadcasts_to :comments
              after_create_commit -> { broadcast_append_to "comments" }
            end
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "concerns", "streamy.rb"), <<~RUBY)
          module Streamy
            def refresh = broadcast_replace_to(:x)
          end
        RUBY

        result = described_class.new(app_in(dir)).call

        expect(result[:model_broadcasts]).to include(
          a_hash_including(model: "Commentable", macro: "broadcasts_to", stream: "comments", file: "app/models/concerns/commentable.rb", line: 4)
        )
        expect(result[:explicit_broadcasts]).to include(
          a_hash_including(method: "broadcast_append_to", stream: "comments", file: "app/models/concerns/commentable.rb", line: 5),
          a_hash_including(method: "broadcast_replace_to", stream: "x", file: "app/controllers/concerns/streamy.rb", line: 2)
        )
      end
    end

    it "parses each model file once for both lists" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        source = "class Post < ApplicationRecord\n  broadcasts\n  after_update_commit -> { broadcast_replace_to \"posts\" }\nend\n"
        File.write(File.join(dir, "app", "models", "post.rb"), source)
        allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk_source).and_call_original

        result = described_class.new(app_in(dir)).call

        expect(result[:model_broadcasts].size).to eq(1)
        expect(result[:explicit_broadcasts].size).to eq(1)
        expect(RailsAiContext::Introspectors::SourceIntrospector).to have_received(:walk_source).with(source, anything).once
      end
    end

    it "carries one entry per macro hit" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "room.rb"), "class Room < ApplicationRecord\n  broadcasts_to :lobby\n  broadcasts_refreshes\nend\n")

        broadcasts = described_class.new(app_in(dir)).call[:model_broadcasts]

        expect(broadcasts.map { |b| [ b[:macro], b[:stream], b[:line] ] }).to eq([
          [ "broadcasts_to", "lobby", 2 ], [ "broadcasts_refreshes", "self (model plural, refreshes)", 3 ]
        ])
      end
    end

    it "reads a frame tag with no argument as dynamic" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "views", "posts"))
        File.write(File.join(dir, "app", "views", "posts", "show.html.erb"), "<%= turbo_frame_tag %>\n<%= turbo_frame_tag do %>\n<% end %>\n")

        frames = described_class.new(app_in(dir)).call[:turbo_frames]

        expect(frames.map { |f| f[:id] }).to eq([ "(dynamic)", "(dynamic)" ])
      end
    end
  end

  describe "explicit broadcasts" do
    it "records each broadcast_*_to call with its stream, target and partial, wherever it sits" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
        File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            # broadcast_append_to is documented here, not called
            after_create_commit -> { broadcast_append_to "posts", target: "list", partial: "posts/post" }
          end
        RUBY
        File.write(File.join(dir, "app", "jobs", "refresh_job.rb"), <<~RUBY)
          class RefreshJob < ApplicationJob
            def perform(post) = broadcast_replace_to("post_\#{post.id}")
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call

        expect(result[:explicit_broadcasts]).to eq([
          { method: "broadcast_append_to", stream: "posts", target: "list", partial: "posts/post",
            file: "app/models/post.rb", line: 3, snippet: 'broadcast_append_to "posts", target: "list", partial: "posts/post"' },
          { method: "broadcast_replace_to", stream: "post_{id}", target: nil, partial: nil,
            file: "app/jobs/refresh_job.rb", line: 2, snippet: 'broadcast_replace_to("post_#{post.id}")' }
        ])
        expect(result[:model_broadcasts]).to eq([])
      end
    end
  end

  describe "one controller scan feeding four lists" do
    it "keeps the other lists when a controller's class line names no matching path" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "controllers", "posts_controller.rb"), <<~RUBY)
          class SomethingElse < ApplicationController
            def create
              respond_to { |format| format.turbo_stream }
            end
          end
        RUBY
        File.write(File.join(dir, "app", "controllers", "notes_controller.rb"), <<~RUBY)
          class NotesController < ApplicationController
            include Turbo::Native::Navigation

            def show
              recede_or_redirect_to root_path if turbo_native_app?
            end
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).call
        expect(result).not_to have_key(:error)
        expect(result[:turbo_native][:detected]).to be true
        expect(result[:turbo_native][:native_helpers]).to eq([ "app/controllers/notes_controller.rb" ])
        expect(result[:turbo_native][:native_navigation].map { |r| r[:method] }).to eq([ "recede_or_redirect_to" ])
        expect(result[:turbo_stream_responses]).to eq([ { controller: "PostsController", action: "create" } ])
      end
    end
  end

  describe "model broadcasts across every model directory" do
    it "names a pack model and a namespaced model by their declared names" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "admin"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        File.write(File.join(dir, "app", "models", "admin", "note.rb"),
                   "class Admin::Note < ApplicationRecord\n  broadcasts\nend\n")
        File.write(File.join(dir, "packs", "billing", "app", "models", "invoice.rb"),
                   "class Invoice < ApplicationRecord\n  broadcasts_to :account\nend\n")

        broadcasts = described_class.new(RailsAiContext::StaticApp.new(dir)).call[:model_broadcasts]
        expect(broadcasts.map { |b| b[:model] }).to contain_exactly("Admin::Note", "Invoice")
      end
    end
  end
end
