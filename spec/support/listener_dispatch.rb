# frozen_string_literal: true

# Runs one listener over a source string through the real dispatcher, the way an introspector does.
module ListenerDispatch
  def parse_and_dispatch(source, *args, **options)
    listener = described_class.new(*args, **options)
    result = Prism.parse(source)
    listener.comments = result.comments
    RailsAiContext::Introspectors::ListenerRegistration
      .dispatcher_for(listener)
      .dispatch(result.value)
    listener.results
  end
end

RSpec.configure { |config| config.include ListenerDispatch }
