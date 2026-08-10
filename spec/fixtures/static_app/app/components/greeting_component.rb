# frozen_string_literal: true

class GreetingComponent < BaseView
  def initialize(name: "World")
    @name = name
  end

  def view_template
    h1 { "Hello, #{@name}!" }
  end
end
