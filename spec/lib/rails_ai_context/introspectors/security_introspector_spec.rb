# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SecurityIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "reports force_ssl as boolean" do
      expect(result[:force_ssl]).to eq(true).or(eq(false))
    end

    it "returns ssl_options as Hash" do
      expect(result[:ssl_options]).to be_a(Hash)
    end

    it "returns host_authorization with :hosts array" do
      expect(result[:host_authorization]).to be_a(Hash)
      expect(result[:host_authorization][:hosts]).to be_an(Array)
    end

    it "returns content_security_policy with :configured key" do
      expect(result[:content_security_policy]).to be_a(Hash)
      expect(result[:content_security_policy][:configured]).to eq(true).or(eq(false))
    end

    it "returns permissions_policy with :configured key" do
      expect(result[:permissions_policy]).to be_a(Hash)
      expect(result[:permissions_policy][:configured]).to eq(true).or(eq(false))
    end

    it "returns csrf settings as Hash" do
      expect(result[:csrf]).to be_a(Hash)
    end

    it "returns cookies config as Hash" do
      expect(result[:cookies]).to be_a(Hash)
    end

    it "returns allow_browser as array" do
      expect(result[:allow_browser]).to be_an(Array)
    end

    context "when content_security_policy initializer exists" do
      let(:init_path) { File.join(Rails.root, "config/initializers/content_security_policy.rb") }

      before do
        File.write(init_path, <<~RUBY)
          Rails.application.config.content_security_policy do |policy|
            policy.default_src :self, :https
            policy.font_src    :self, :https, :data
            policy.img_src     :self, :https, :data
          end
        RUBY
      end

      after { FileUtils.rm_f(init_path) }

      it "flags CSP as configured and extracts directives" do
        expect(result[:content_security_policy][:configured]).to eq(true)
        directives = result[:content_security_policy][:directives].map { |d| d[:directive] }
        expect(directives).to include("default_src", "font_src", "img_src")
      end
    end

    context "when a controller calls allow_browser" do
      let(:controller_path) { File.join(Rails.root, "app/controllers/modern_controller.rb") }

      before do
        FileUtils.mkdir_p(File.dirname(controller_path))
        File.write(controller_path, <<~RUBY)
          class ModernController < ApplicationController
            allow_browser versions: :modern
          end
        RUBY
      end

      after { FileUtils.rm_f(controller_path) }

      it "captures the allow_browser call" do
        entry = result[:allow_browser].find { |e| e[:file] == "app/controllers/modern_controller.rb" }
        expect(entry).not_to be_nil
        expect(entry[:args]).to include("versions: :modern")
      end
    end
  end
end
