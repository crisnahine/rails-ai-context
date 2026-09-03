# frozen_string_literal: true

class InvoiceJob < ActiveJob::Base
  queue_as :billing

  def perform(invoice_id)
    # no-op for testing
  end
end
