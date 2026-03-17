Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Auth
  get    "/auth/github/callback",       to: "auth#github_callback"
  get    "/auth/google_oauth2/callback", to: "auth#google_callback"
  get    "/auth/failure",               to: "auth#failure"
  delete "/logout",                     to: "auth#destroy",           as: :logout
  delete "/auth/google/disconnect",     to: "auth#google_disconnect", as: :google_disconnect

  # Settings
  resource :settings, only: [:show, :update] do
    patch :gcp_credentials
  end

  # Dashboard
  root "dashboard#index"
  get "/pricing", to: "dashboard#pricing", as: :pricing

  # GitHub webhook receiver
  post "/webhooks/github", to: "webhooks#github"

  resources :projects do
    member do
      post :deploy
      post :redeploy
      post :analyze
      get  :setup_cicd
      post :generate_cicd
      post :commit_cicd
      get  :dockerfile_preview
    end
    resources :deployments, only: %i[index show create] do
      member do
        post :cancel
      end
    end
    resources :secrets,     only: %i[index create destroy]
  end

  namespace :gcp do
    resources :projects, only: %i[index create]
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
