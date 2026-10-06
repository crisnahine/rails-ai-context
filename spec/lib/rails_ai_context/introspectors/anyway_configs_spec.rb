# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Introspectors::AnywayConfigs do
  around { |example| Dir.mktmpdir { |dir| @root = File.realpath(dir); example.run } }

  def write(rel, body)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  it "reads each class's attributes with the env names it reads, its own macros only" do
    write("app/configs/c_config.rb", <<~RUBY)
      class CConfig < ::Anyway::Config
        config_name :my_service
        attr_config :url
      end

      class Other < Anyway::Config
        env_prefix :zzz
        attr_config :token
        required :token
      end
    RUBY

    expect(described_class.scan(@root)).to eq([
      { name: "CConfig", file: "app/configs/c_config.rb", attributes: [ { name: "url", env: "MY_SERVICE_URL", required: false } ] },
      { name: "Other", file: "app/configs/c_config.rb", attributes: [ { name: "token", env: "ZZZ_TOKEN", required: true } ] }
    ])
  end

  # anyway_config cannot infer a name for Billing::PaymentConfig, so it names no env variable.
  it "keeps a nested class's macros out of the class around it" do
    write("config/configs/payment_config.rb", <<~RUBY)
      module Billing
        class PaymentConfig < ApplicationConfig
          attr_config :api_key, timeout: 30

          class Inner < Anyway::Config
            env_prefix :inner
            attr_config :x
          end
        end
      end
    RUBY

    expect(described_class.scan(@root)).to eq([
      { name: "Billing::PaymentConfig", file: "config/configs/payment_config.rb",
        attributes: [ { name: "api_key", env: nil, required: false }, { name: "timeout", env: nil, required: false } ] },
      { name: "Billing::PaymentConfig::Inner", file: "config/configs/payment_config.rb",
        attributes: [ { name: "x", env: "INNER_X", required: false } ] }
    ])
  end
end
