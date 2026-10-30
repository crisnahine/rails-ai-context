module Api
  module V1
    class BaseController < ActionController::API
      include ActionController::HttpAuthentication::Token::ControllerMethods

      before_action :authenticate!

      private

      def authenticate!
        authenticate_or_request_with_http_token do |token, _options|
          @current_user = User.active.find_by(api_token: token)
        end
      end
    end
  end
end
