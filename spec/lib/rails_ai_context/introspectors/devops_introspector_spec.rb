# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::DevOpsIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns nil for puma when no config exists" do
      expect(result[:puma]).to be_nil
    end

    it "returns empty procfile array when no Procfile exists" do
      expect(result[:procfile]).to eq([])
    end

    it "returns nil for deployment when no deploy config exists" do
      expect(result[:deployment]).to be_nil
    end

    it "returns nil for docker when no Dockerfile exists" do
      expect(result[:docker]).to be_nil
    end

    context "with a Puma config" do
      let(:puma_config) { File.join(Rails.root, "config/puma.rb") }

      before do
        File.write(puma_config, <<~RUBY)
          threads 5, 10
          workers 2
          port ENV.fetch("PORT", 3000)
        RUBY
      end

      after { FileUtils.rm_f(puma_config) }

      it "extracts Puma threads" do
        expect(result[:puma][:threads_min]).to eq(5)
        expect(result[:puma][:threads_max]).to eq(10)
      end

      it "extracts Puma workers" do
        expect(result[:puma][:workers]).to eq(2)
      end

      it "extracts Puma port" do
        expect(result[:puma][:port]).to eq(3000)
      end
    end

    context "with a Puma config the digit reader can trip over" do
      let(:puma_config) { File.join(Rails.root, "config/puma.rb") }

      after { FileUtils.rm_f(puma_config) }

      it "reads the default, not a digit out of the ENV name" do
        File.write(puma_config, %(port ENV.fetch("PORT_2", 3000)\n))

        expect(result[:puma][:port]).to eq(3000)
      end

      it "ignores a call that has a receiver" do
        File.write(puma_config, "config.port 9292\n")

        expect(result[:puma]).to be_nil
      end

      it "leaves threads unset when only one number is given" do
        File.write(puma_config, "threads 5\n")

        expect(result[:puma]).to be_nil
      end

      it "reads the numbers out of ENV fetch blocks" do
        File.write(puma_config, <<~RUBY)
          threads ENV.fetch("RAILS_MIN_THREADS") { 5 }, ENV.fetch("RAILS_MAX_THREADS") { 5 }
        RUBY

        expect(result[:puma]).to eq(threads_min: 5, threads_max: 5)
      end

      it "reads a macro called inside a block" do
        File.write(puma_config, <<~RUBY)
          on_worker_boot do
            workers 3
          end
        RUBY

        expect(result[:puma]).to eq(workers: 3)
      end
    end

    context "with a Procfile" do
      let(:procfile) { File.join(Rails.root, "Procfile") }

      before do
        File.write(procfile, <<~PROCFILE)
          web: bundle exec puma -C config/puma.rb
          worker: bundle exec sidekiq
        PROCFILE
      end

      after { FileUtils.rm_f(procfile) }

      it "parses Procfile entries" do
        entries = result[:procfile].flat_map { |p| p[:entries] }
        names = entries.map { |e| e[:name] }
        expect(names).to include("web", "worker")
      end
    end

    context "with a Dockerfile" do
      let(:dockerfile) { File.join(Rails.root, "Dockerfile") }

      before do
        File.write(dockerfile, <<~DOCKER)
          FROM ruby:3.3-slim AS base
          FROM base AS build
          RUN bundle install
        DOCKER
      end

      after { FileUtils.rm_f(dockerfile) }

      it "detects multi-stage Docker build" do
        expect(result[:docker][:multi_stage]).to be true
        expect(result[:docker][:base_images]).to include("ruby:3.3-slim AS base")
      end
    end

    context "with health check route" do
      let(:routes_file) { File.join(Rails.root, "config/routes.rb") }
      let(:original_routes) { File.read(routes_file) }

      before do
        File.write(routes_file, original_routes + "\n# get \"up\" => \"rails/health#show\"\n")
      end

      after { File.write(routes_file, original_routes) }

      it "detects health check with word boundary" do
        expect(result[:health_check]).to be true
      end
    end
  end
end
