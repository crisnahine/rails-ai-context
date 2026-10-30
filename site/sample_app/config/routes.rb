Rails.application.routes.draw do
  devise_for :users

  root "articles#index"

  resources :articles do
    resources :comments, only: :create
  end

  namespace :admin do
    resources :articles, only: %i[index show] do
      post :publish, on: :member
    end
  end

  namespace :api do
    namespace :v1 do
      resources :articles, only: %i[index show]
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
