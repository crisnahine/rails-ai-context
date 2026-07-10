# frozen_string_literal: true

# Backport of the Ruby 3.2+ immutable value class Data for Ruby 3.1, which
# ships no Data at all. Inert on Ruby >= 3.2: the guard sees the built-in
# Data.define and defines nothing, so every runtime from 3.2 up keeps the real
# implementation and only 3.1 gets this shim.
#
# The value-setting initialize lives on this base class so a block-defined
# initialize on a subclass can call super into it (the HydrationResult idiom).
# Members are keyword- or positionally-constructable, instances are frozen, and
# equality is by value, matching how Doctor::Check, SchemaHint, and
# HydrationResult are built and compared.
unless defined?(Data) && Data.respond_to?(:define)
  class Data
    class << self
      def define(*members, &block)
        members = members.map(&:to_sym)
        raise ArgumentError, "duplicate member" if members.uniq.length != members.length

        subclass = ::Class.new(self)
        subclass.instance_variable_set(:@members, members.freeze)
        members.each do |name|
          subclass.define_method(name) { instance_variable_get(:"@#{name}") }
        end
        subclass.class_eval(&block) if block
        subclass
      end

      def members
        @members || []
      end
    end

    def initialize(*args, **kwargs)
      members = self.class.members
      if kwargs.empty?
        unless args.length == members.length
          raise ArgumentError, "wrong number of arguments (given #{args.length}, expected #{members.length})"
        end

        members.each_with_index { |m, i| instance_variable_set(:"@#{m}", args[i]) }
      else
        unless args.empty?
          raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 0)"
        end

        extra = kwargs.keys - members
        unless extra.empty?
          raise ArgumentError, "unknown keyword#{extra.length > 1 ? 's' : ''}: #{extra.map(&:inspect).join(', ')}"
        end

        missing = members - kwargs.keys
        unless missing.empty?
          raise ArgumentError, "missing keyword#{missing.length > 1 ? 's' : ''}: #{missing.map(&:inspect).join(', ')}"
        end

        members.each { |m| instance_variable_set(:"@#{m}", kwargs[m]) }
      end
      freeze
    end

    def members
      self.class.members
    end

    def to_h(&block)
      pairs = self.class.members.map { |m| [ m, instance_variable_get(:"@#{m}") ] }
      return pairs.to_h unless block

      pairs.each_with_object({}) do |(k, v), acc|
        nk, nv = block.call(k, v)
        acc[nk] = nv
      end
    end

    def with(**kwargs)
      extra = kwargs.keys - self.class.members
      unless extra.empty?
        raise ArgumentError, "unknown keyword#{extra.length > 1 ? 's' : ''}: #{extra.map(&:inspect).join(', ')}"
      end

      self.class.new(**to_h.merge(kwargs))
    end

    def deconstruct
      self.class.members.map { |m| instance_variable_get(:"@#{m}") }
    end

    def deconstruct_keys(keys)
      return to_h if keys.nil?

      keys.each_with_object({}) do |k, acc|
        acc[k] = instance_variable_get(:"@#{k}") if self.class.members.include?(k)
      end
    end

    def ==(other)
      other.class == self.class && other.to_h == to_h
    end
    alias_method :eql?, :==

    def hash
      [ self.class, to_h ].hash
    end

    def inspect
      pairs = self.class.members.map { |m| "#{m}=#{instance_variable_get(:"@#{m}").inspect}" }
      "#<data #{self.class.name}#{pairs.empty? ? '' : " #{pairs.join(', ')}"}>"
    end
    alias_method :to_s, :inspect
  end
end
