# frozen_string_literal: true

require "spec_helper"

# An unregistered handler is silent, not broken. It parses, its own unit spec
# passes when the method is called directly, and the introspector it feeds
# just reports nothing - which downstream reads as "the app has none of
# these". That is how a never-wired `on_call_node_leave` shipped and static
# routes came back fabricated.
#
# So these run every listener in the gem against real source and check the
# handlers actually fire. Nothing here reads code; it all dispatches.
RSpec.describe "Listener registration properties" do
  def registration = RailsAiContext::Introspectors::ListenerRegistration

  def lib_root = File.expand_path("../../../../../lib", __FILE__)

  def listeners_dir = File.join(lib_root, "rails_ai_context", "introspectors", "listeners")

  # One occurrence of every node type any listener in the gem handles, in
  # shapes an ordinary app would contain.
  def probe_source
    <<~RUBY
      module Probe
        class Thing < Base
          SETTING = 1

          class << self
            def built
            end
          end

          macro :name, option: true

          def run
            @state = 1
            scope.where(id: 1).order(:id)

            case @state
            when 1 then :one
            else :other
            end
          end
        end
      end
    RUBY
  end

  def probe_ast = Prism.parse(probe_source).value

  def listener_classes
    Dir.glob(File.join(listeners_dir, "*.rb")).sort.filter_map { |path|
      name = File.basename(path, ".rb").split("_").map(&:capitalize).join
      klass = RailsAiContext::Introspectors::Listeners.const_get(name)
      klass unless klass == RailsAiContext::Introspectors::Listeners::BaseListener
    }
  end

  # Every listener, built. A class needing constructor arguments is reported
  # rather than skipped - a silent skip is how a listener stops being covered.
  def listeners
    @listeners ||= listener_classes.map { |klass|
      [ klass, begin
        klass.new
      rescue StandardError => e
        e
      end ]
    }
  end

  # Every method the listener declares that is shaped like a handler, however
  # it was declared. Asking `events_for` instead would only ever compare the
  # module against itself: a handler it fails to register drops out of the
  # expectation too, and the silence it causes reads as agreement.
  def declared_handlers(listener)
    base = RailsAiContext::Introspectors::Listeners::BaseListener

    listener.class.ancestors.take_while { |mod| mod != base }
      .flat_map { |mod| mod.instance_methods(false) + mod.private_instance_methods(false) }
      .grep(registration::HANDLER_PATTERN).uniq.sort
  end

  # Dispatches the probe with each handler wrapped, so a handler that never
  # runs is distinguishable from one that runs and raises.
  def probe(listener)
    events = registration.events_for(listener)
    fired = []
    errors = []

    recorder = Module.new do
      events.each do |event|
        define_method(event) do |node|
          fired << event
          super(node)
        rescue StandardError => e
          errors << "#{event}: #{e.class}: #{e.message}"
        end
      end
    end

    listener.singleton_class.prepend(recorder)
    registration.dispatcher_for(listener).dispatch(probe_ast)

    [ fired.uniq.sort, errors ]
  end

  def node_class_for(event)
    name = event.to_s.sub(/\Aon_/, "").sub(/_(enter|leave)\z/, "")
    Prism.const_get(name.split("_").map(&:capitalize).join)
  end

  def node_types_in(node, seen = Set.new)
    seen << node.class
    node.compact_child_nodes.each { |child| node_types_in(child, seen) }
    seen
  end

  it "builds every listener with no arguments" do
    broken = listeners.select { |_, listener| listener.is_a?(StandardError) }
      .map { |klass, error| "#{klass}: #{error.class}: #{error.message}" }

    expect(broken).to be_empty,
      "#{broken.size} listener(s) could not be built, so nothing below covers them:\n#{broken.join("\n")}"
  end

  # Without this the properties below pass by asking nothing. A node type no
  # probe source contains can never fail to fire.
  it "probes source containing every node type the listeners handle" do
    wanted = listeners.reject { |_, l| l.is_a?(StandardError) }
      .flat_map { |_, listener| declared_handlers(listener) }
      .uniq.select { |event| registration.known_event?(event) }
      .map { |event| node_class_for(event) }.uniq

    missing = wanted - node_types_in(probe_ast).to_a

    expect(missing).to be_empty,
      "The probe source contains no #{missing.join(', ')}, so handlers for those are never exercised"
  end

  it "fires every handler every listener defines" do
    silent = []

    listeners.reject { |_, l| l.is_a?(StandardError) }.each do |klass, listener|
      fired, = probe(listener)
      (declared_handlers(listener) - fired).each { |event| silent << "#{klass}##{event}" }
    end

    expect(silent).to be_empty,
      "#{silent.size} handler(s) never fired - they are defined but nothing dispatches to them:\n#{silent.join("\n")}"
  end

  # A method shaped like a handler that prism never dispatches is dead the
  # moment it is written. Public, `events_for` raises on it; private, nothing
  # says anything at all.
  it "names every handler after an event prism dispatches" do
    unknown = listeners.reject { |_, l| l.is_a?(StandardError) }.flat_map { |klass, listener|
      declared_handlers(listener).reject { |event| registration.known_event?(event) }
        .map { |event| "#{klass}##{event}" }
    }

    expect(unknown).to be_empty,
      "#{unknown.size} handler-shaped method(s) name no prism event:\n#{unknown.join("\n")}"
  end

  # Listeners run over whatever Ruby the user's app happens to contain, not
  # over the shapes they were written for.
  it "survives ordinary Ruby it was not written for" do
    raised = []

    listeners.reject { |_, l| l.is_a?(StandardError) }.each do |klass, listener|
      _, errors = probe(listener)
      errors.each { |error| raised << "#{klass}##{error}" }
    end

    expect(raised).to be_empty,
      "#{raised.size} handler(s) raised on ordinary Ruby:\n#{raised.join("\n")}"
  end

  it "registers at least one event for every listener" do
    dead = listeners.reject { |_, l| l.is_a?(StandardError) }
      .select { |_, listener| registration.events_for(listener).empty? }
      .map { |klass, _| klass.to_s }

    expect(dead).to be_empty,
      "#{dead.size} listener(s) register nothing, so dispatching never reaches them: #{dead.join(', ')}"
  end

  # A listener defined outside that directory is one the properties above
  # never see. Failing here is the signal to widen the glob.
  it "finds every listener in the gem" do
    handler = /^\s*def on_[a-z0-9_]+\b/

    strays = Dir.glob(File.join(lib_root, "**", "*.rb"))
      .reject { |path| path.start_with?(listeners_dir) }
      .select { |path| File.read(path).match?(handler) }
      .map { |path| path.sub("#{lib_root}/", "") }

    expect(strays).to be_empty,
      "#{strays.size} file(s) define handlers outside the listeners directory, uncovered here:\n#{strays.join("\n")}"
  end
end
