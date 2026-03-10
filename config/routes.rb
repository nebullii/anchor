Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Auth
  get    "/auth/github/callback", to: "auth#callback"
  get    "/auth/failure",         to: "auth#failure"
  delete "/logout",               to: "auth#destroy", as: :logout

  # Settings
  resource :settings, only: [:show, :update] do
    patch :gcp_credentials
  end

  # Dashboard
  root "dashboard#index"

  resources :projects do
    member do
      post :deploy
      post :analyze
    end
    resources :deployments, only: %i[index show create] do
      member do
        post :cancel
      end
    end
    resources :secrets,     only: %i[index create destroy]
  end

  resources :repositories, only: %i[index create] do
    collection do
      post :sync
    end
  end

  # Sidekiq web UI (admin only in production — wire up auth before enabling)
  # require "sidekiq/web"
  # mount Sidekiq::Web => "/sidekiq"

  mount ActionCable.server => "/cable"
end
