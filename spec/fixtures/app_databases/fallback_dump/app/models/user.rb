class User < ApplicationRecord
  has_many :jobs
  has_many :legacy_orders
end
