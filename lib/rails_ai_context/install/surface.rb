# frozen_string_literal: true

module RailsAiContext
  module Install
    # How the install program talks to the entry that started it: generator, rake task or binary.
    Surface = Struct.new(:sayer, :asker) do
      def say(text = "", level = :plain)
        sayer.call(text, level)
      end

      def ask(prompt)
        asker.call(prompt)
      end
    end
  end
end
