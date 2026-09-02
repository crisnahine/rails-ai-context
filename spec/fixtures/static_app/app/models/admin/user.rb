# frozen_string_literal: true

class Admin::User < ApplicationRecord
  devise :database_authenticatable
end
