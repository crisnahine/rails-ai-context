# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # Prism Dispatcher listener that detects model references in controller source.
      # Extracts constant names used as method receivers (Post.find, Post.new),
      # params.require(:post) keys, and instance variable write targets.
      #
      # Not registered in SourceIntrospector::LISTENER_MAP — used standalone
      # by ControllerHydrator since model references are controller-specific.
      class ModelReferenceListener < BaseListener
        attr_reader :constant_references, :require_keys, :ivar_models

        def initialize
          super
          @constant_references = []
          @require_keys = []
          @ivar_models = {}
        end

        # Detect: Post.find, Post.where, Post.new, Post.create, etc.
        # Detect: params.require(:post)
        def on_call_node_enter(node)
          extract_constant_receiver(node)
          extract_params_require(node)
        end

        # Detect: @post = Post.new(...), @post = Post.find(...)
        def on_instance_variable_write_node_enter(node)
          extract_ivar_model(node)
        end

        def results
          model_names = Set.new

          # Constant receivers: Post.find → "Post"
          @constant_references.each { |name| model_names << name }

          # params.require(:post) → "Post"
          @require_keys.each { |key| model_names << key.to_s.classify }

          # @post = Post.new → "Post"
          @ivar_models.each_value { |name| model_names << name }

          model_names.reject { |n| framework_constant?(n) }.sort
        end

        private

        def extract_constant_receiver(node)
          receiver = node.receiver
          return unless receiver

          case receiver
          when Prism::ConstantReadNode
            @constant_references << receiver.name.to_s
          when Prism::ConstantPathNode
            # Handles Namespaced::Model.find
            @constant_references << constant_path_string(receiver)
          end
        end

        def extract_params_require(node)
          return unless node.name == :require
          receiver = node.receiver
          return unless receiver.is_a?(Prism::CallNode) && receiver.name == :params && receiver.receiver.nil?

          arg = node.arguments&.arguments&.first
          case arg
          when Prism::SymbolNode then @require_keys << arg.value
          when Prism::StringNode then @require_keys << arg.unescaped
          end
        end

        def extract_ivar_model(node)
          value = node.value
          return unless value.is_a?(Prism::CallNode)

          receiver = value.receiver
          name = case receiver
          when Prism::ConstantReadNode then receiver.name.to_s
          when Prism::ConstantPathNode then constant_path_string(receiver)
          end
          return unless name

          @ivar_models[node.name.to_s] = name
        end

        FRAMEWORK_CONSTANTS = %w[
          ApplicationController ActionController ActionDispatch
          ActiveRecord ActiveSupport Rails ApplicationRecord
          ActionView ActionMailer ActiveJob ActiveStorage
          ActionCable ActionMailbox ActionText Turbo
        ].to_set.freeze

        def framework_constant?(name)
          root = name.split("::").first
          FRAMEWORK_CONSTANTS.include?(root)
        end
      end
    end
  end
end
