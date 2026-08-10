# frozen_string_literal: true

class BadgeComponent < ViewComponent::Base
  VARIANTS = {
    primary: "bg-blue-100 text-blue-800",
    secondary: "bg-gray-100 text-gray-800",
    success: "bg-green-100 text-green-800"
  }

  SIZES = [ :sm, :md, :lg ]

  def initialize(variant: :primary, size: :md)
    @variant = variant
    @size = size
  end

  private

  def badge_classes
    VARIANTS[@variant]
  end
end
