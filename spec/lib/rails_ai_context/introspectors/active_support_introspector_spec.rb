# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ActiveSupportIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "returns a Hash without error" do
      expect(result).to be_a(Hash)
      expect(result).not_to have_key(:error)
    end

    it "returns concerns as a Hash keyed by directory" do
      expect(result[:concerns]).to be_a(Hash)
    end

    it "returns deprecators as array" do
      expect(result[:deprecators]).to be_an(Array)
    end

    it "returns message_verifier_usage as array" do
      expect(result[:message_verifier_usage]).to be_an(Array)
    end

    it "returns tagged_logging as Hash with :configured" do
      expect(result[:tagged_logging]).to be_a(Hash)
      expect(result[:tagged_logging][:configured]).to eq(true).or(eq(false))
    end

    it "returns common on_load hooks as array" do
      expect(result[:on_load_hooks]).to be_an(Array)
    end

    it "returns cache_usage with a :store key" do
      expect(result[:cache_usage]).to be_a(Hash)
      expect(result[:cache_usage][:store]).to be_a(String)
    end

    context "when a concern file exists" do
      let(:concerns_dir) { File.join(Rails.root, "app/models/concerns") }
      let(:concern_path) { File.join(concerns_dir, "test_trackable.rb") }

      before do
        FileUtils.mkdir_p(concerns_dir)
        File.write(concern_path, <<~RUBY)
          module TestTrackable
            extend ActiveSupport::Concern

            included do
              scope :tracked, -> { where.not(tracked_at: nil) }
            end

            class_methods do
              def track_all!
              end
            end
          end
        RUBY
      end

      after { FileUtils.rm_f(concern_path) }

      it "lists the concern under app/models/concerns with expected flags" do
        entries = result[:concerns]["app/models/concerns"]
        expect(entries).to be_an(Array)
        concern = entries.find { |e| e[:name] == "TestTrackable" }
        expect(concern).not_to be_nil
        expect(concern[:uses_active_support_concern]).to eq(true)
        expect(concern[:class_methods_block]).to eq(true)
      end

      # Two concerns of the same basename in different namespaces printed as
      # one name, and a reader could not tell which module was meant.
      it "names a namespaced concern by its path below the concerns directory" do
        nested = File.join(concerns_dir, "test_edition")
        FileUtils.mkdir_p(nested)
        File.write(File.join(nested, "test_trackable.rb"), <<~RUBY)
          module TestEdition
            module TestTrackable
              extend ActiveSupport::Concern
            end
          end
        RUBY

        names = result[:concerns]["app/models/concerns"].map { |e| e[:name] }

        expect(names).to include("TestEdition::TestTrackable", "TestTrackable")
      ensure
        FileUtils.rm_rf(nested)
      end

      # Some apps keep every ActiveModel validator in app/models/concerns.
      # None of them is a module, and all of them read as "plain module".
      it "says a class in the concerns directory is a class" do
        validator_path = File.join(concerns_dir, "email_validator.rb")
        File.write(validator_path, <<~RUBY)
          class EmailValidator < ActiveModel::Validator
            def validate(record); end
          end
        RUBY

        entry = described_class.new(Rails.application).call[:concerns]["app/models/concerns"]
          .find { |e| e[:name] == "EmailValidator" }

        expect(entry[:kind]).to eq("class")
        expect(entry[:superclass]).to eq("ActiveModel::Validator")
      ensure
        FileUtils.rm_f(validator_path)
      end

      it "leaves an excluded concern out of the registry" do
        original = RailsAiContext.configuration.excluded_concerns
        RailsAiContext.configuration.excluded_concerns = [ /TestTrackable/ ]

        entries = described_class.new(Rails.application).call[:concerns]["app/models/concerns"]

        expect(Array(entries).map { |e| e[:name] }).not_to include("TestTrackable")
      ensure
        RailsAiContext.configuration.excluded_concerns = original
      end
    end
  end
  # Deprecators, load hooks and the cache store live in a running process.
  # Returning [] for them without a boot rendered as "this app has none".
  describe "#static_call" do
    subject(:result) { described_class.new(RailsAiContext::StaticApp.new(Dir.pwd)).static_call }

    it "marks the deprecators registry unavailable" do
      expect(result[:deprecators]).to eq({ unavailable: RailsAiContext::Introspectors::StaticTier.unavailable_reason })
    end

    it "marks the on_load hooks unavailable" do
      expect(result[:on_load_hooks]).to eq({ unavailable: RailsAiContext::Introspectors::StaticTier.unavailable_reason })
    end

    it "marks the cache store unavailable" do
      expect(result[:cache_usage]).to eq({ unavailable: RailsAiContext::Introspectors::StaticTier.unavailable_reason })
    end

    it "still reads the concerns off disk" do
      expect(result[:concerns]).to be_a(Hash)
    end

    it "reads a TaggedLogging initializer in a subfolder and marks the tags unavailable" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config/initializers/log"))
        File.write(File.join(dir, "config/initializers/log/tagged.rb"), "Rails.logger = ActiveSupport::TaggedLogging.new(Logger.new(STDOUT))\n")
        tagged = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:tagged_logging]
        expect(tagged).to eq(configured: true, initializer: "config/initializers/log/tagged.rb",
                             tags: { unavailable: RailsAiContext::Introspectors::StaticTier.unavailable_reason })
      end
    end
  end

  describe "message verifier usage" do
    it "lists Rails.application.message_verifier calls and skips a file that only rescues InvalidSignature" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        FileUtils.mkdir_p(File.join(dir, "lib/crypto"))
        File.write(File.join(dir, "app/models/user.rb"), <<~RUBY)
          class User < ApplicationRecord
            def unsubscribe_token
              Rails.application.message_verifier(:unsubscribe).generate(id)
            end

            def reset_token = Rails.application.message_verifiers["reset"].generate(id)
          end
        RUBY
        File.write(File.join(dir, "app/controllers/passwords_controller.rb"), <<~RUBY)
          class PasswordsController < ApplicationController
            def edit
            rescue ActiveSupport::MessageVerifier::InvalidSignature
              redirect_to root_path
            end
          end
        RUBY
        File.write(File.join(dir, "lib/crypto/box.rb"), "BOX = ActiveSupport::MessageEncryptor.new(KEY)\n")
        File.write(File.join(dir, "lib/crypto/blob_key.rb"), "def blob(key) = ActiveStorage.verifier.verified(key, purpose: :blob_key)\n")
        File.write(File.join(dir, "app/models/note.rb"),
                   "# MessageVerifier later, and message_verifier too\nclass Note\n  LABEL = \"MessageEncryptor\"\nend\n")
        allow(introspector).to receive(:root).and_return(dir)

        expect(introspector.send(:extract_message_verifier_usage)).to eq([
          { file: "lib/crypto/blob_key.rb", encryptor: false, verifier: true },
          { file: "lib/crypto/box.rb", encryptor: true, verifier: false },
          { file: "app/models/user.rb", encryptor: false, verifier: true }
        ])
      end
    end
  end

  describe "notification subscriptions" do
    def subscriptions(files)
      Dir.mktmpdir do |dir|
        files.each do |path, body|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), body)
        end
        app = RailsAiContext::StaticApp.new(dir)
        booted = described_class.new(app).send(:scan_sources)[:notification_subscriptions]
        static = described_class.new(app).static_call[:notification_subscriptions]
        expect(static).to eq(booted)
        static
      end
    end

    it "lists each event the app subscribes to, with the file and line" do
      result = subscriptions(
        "config/initializers/notifications.rb" => <<~RUBY,
          ActiveSupport::Notifications.subscribe("process_action.action_controller") { |event| }
          ActiveSupport::Notifications.monotonic_subscribe(/cache_.*/) { |event| }
        RUBY
        "app/subscribers/request_subscriber.rb" => <<~RUBY
          class RequestSubscriber < ActiveSupport::Subscriber
            attach_to :action_controller
            def process_action(event); end
            private
            def helper; end
          end
        RUBY
      )

      expect(result).to eq([
        { event: "process_action.action_controller", via: "RequestSubscriber.attach_to", file: "app/subscribers/request_subscriber.rb", line: 2 },
        { event: "process_action.action_controller", via: "subscribe", file: "config/initializers/notifications.rb", line: 1 },
        { event: "/cache_.*/", via: "monotonic_subscribe", file: "config/initializers/notifications.rb", line: 2 }
      ])
    end

    it "reads attach_to called on the class after it, one event per public method the file defines" do
      result = subscriptions(
        "app/subscribers/ar_subscriber.rb" => <<~RUBY,
          class ArSubscriber < ActiveSupport::LogSubscriber
            def sql(event); end
            def instantiation(event); end
          end
          ArSubscriber.attach_to :active_record
        RUBY
        "config/initializers/remote.rb" => "Audit::RemoteSubscriber.attach_to :action_mailer\n",
        "app/subscribers/self_subscriber.rb" => <<~RUBY
          class SelfSubscriber < ActiveSupport::Subscriber
            self.attach_to :x
            def a(event); end
          end
        RUBY
      )

      expect(result).to eq([
        { event: "instantiation.active_record", via: "ArSubscriber.attach_to", file: "app/subscribers/ar_subscriber.rb", line: 5 },
        { event: "sql.active_record", via: "ArSubscriber.attach_to", file: "app/subscribers/ar_subscriber.rb", line: 5 },
        { event: "a.x", via: "SelfSubscriber.attach_to", file: "app/subscribers/self_subscriber.rb", line: 2 },
        { event: "every public method of Audit::RemoteSubscriber, as <method>.action_mailer", via: "Audit::RemoteSubscriber.attach_to", file: "config/initializers/remote.rb", line: 1 }
      ])
    end

    it "ignores a subscribe call on anything but Notifications, and survives a file it cannot parse" do
      result = subscriptions(
        "app/models/newsletter.rb" => "class Newsletter\n  def go = Mailchimp.subscribe(\"x\")\nend\n",
        "lib/broken.rb" => "ActiveSupport::Notifications.subscribe(\"a.b\") {\n",
        "lib/all.rb" => "ActiveSupport::Notifications.subscribe { |e| }\n"
      )

      expect(result.map { |r| r[:event] }).not_to include("x")
      expect(result).to include({ event: "every event", via: "subscribe", file: "lib/all.rb", line: 1 })
    end
  end
end
