class UserWithAttrs < ApplicationRecord
  self.table_name = "users"

  attribute :preferences, :jsonb
  attribute :score, :float

  enum :role, { member: 0, admin: 1 }, _prefix: true

  after_commit :sync_to_crm, on: :create
  after_commit :notify_admin, on: [ :update, :destroy ]

  private def secret_method
    "hidden"
  end

  def public_method
    "visible"
  end

  private
  def sync_to_crm; end
  def notify_admin; end
end
