# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::TurboIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "discovers turbo frames with id and file" do
      expect(result[:turbo_frames]).to be_an(Array)
      frame = result[:turbo_frames].find { |f| f[:id] == "post" }
      expect(frame).not_to be_nil
      expect(frame[:file]).to eq("posts/show.html.erb")
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

      it "detects model broadcasts" do
        broadcast = result[:model_broadcasts].find { |b| b[:model] == "Message" }
        expect(broadcast).not_to be_nil
        expect(broadcast[:methods]).to include("broadcasts_to", "broadcasts_refreshes_to")
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
