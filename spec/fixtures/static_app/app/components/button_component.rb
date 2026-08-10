class ButtonComponent < ViewComponent::Base
  renders_one :icon
  renders_many :badges

  VARIANTS = %w[primary secondary danger].freeze

  def initialize(label:, variant: "primary", size: "md", **html_options)
    @label = label
    @variant = variant
    @size = size
    @html_options = html_options
  end
end
