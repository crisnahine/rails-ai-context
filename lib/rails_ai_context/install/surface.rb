# frozen_string_literal: true

module RailsAiContext
  module Install
    # How the install program talks to the entry that started it: generator, rake task or binary.
    #
    # `place` is the app root as the person running it names it from where
    # they stand, when that is outside the app (`init --app-path X` typed in
    # X's parent): every path the program reports is named from there, so
    # `X/.mcp.json` says where the file went. Nil names paths from the root.
    Surface = Struct.new(:sayer, :asker, :place) do
      def say(text = "", level = :plain)
        sayer.call(text, level)
      end

      def ask(prompt)
        asker.call(prompt)
      end
    end
  end
end
