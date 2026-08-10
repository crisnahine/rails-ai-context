# frozen_string_literal: true

module Api
  module V1
    class BaseController < ActionController::API
      def index
        render json: { status: "ok" }
      end
    end
  end
end
