# frozen_string_literal: true

class AlertComponent < ViewComponent::Base
  renders_one :icon
  renders_many :actions

  def initialize(type: :info, dismissible: false)
    @type = type
    @dismissible = dismissible
  end

  private

  def type_classes
    case @type
    when :success then "bg-green-100 text-green-800 border-green-300"
    when :error   then "bg-red-100 text-red-800 border-red-300"
    when :warning then "bg-yellow-100 text-yellow-800 border-yellow-300"
    else               "bg-blue-100 text-blue-800 border-blue-300"
    end
  end
end
