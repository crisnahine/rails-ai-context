# frozen_string_literal: true

class CardComponent < ViewComponent::Base
  renders_one :header
  renders_one :footer
  renders_many :badges

  def initialize(variant: :default, padding: true)
    @variant = variant
    @padding = padding
  end

  private

  def card_classes
    classes = [ "rounded-xl shadow-sm border" ]
    classes << (@variant == :elevated ? "shadow-lg" : "shadow-sm")
    classes << "p-6" if @padding
    classes.join(" ")
  end
end
