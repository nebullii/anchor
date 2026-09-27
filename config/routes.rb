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

  # Deploy wizard — one-click deployment flow
  get  "/wizard",                          to: "deploy_wizard#index",     as: "wizard"
  post "/wizard",                          to: "deploy_wizard#create",    as: "wizard_create"
  get  "/wizard/:project_id/analyzing",    to: "deploy_wizard#analyzing", as: "wizard_analyzing"
  get  "/wizard/:project_id/configure",    to: "deploy_wizard#configure", as: "wizard_configure"
  post "/wizard/:project_id/launch",       to: "deploy_wizard#launch",    as: "wizard_launch"

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

  # ── SRE: health probes, rollback, Sidekiq dashboard ──────────────────── #
  get  "/healthz", to: "health#live",  as: :healthz
  get  "/readyz",  to: "health#ready", as: :readyz

  post "/projects/:project_id/rollback", to: "rollbacks#create", as: :project_rollback

  # Admin-only (ANCHOR_ADMIN_GITHUB_LOGINS); see config/initializers/sidekiq_web.rb
  constraints(Anchor::SidekiqAdminConstraint) do
    mount Sidekiq::Web => "/sidekiq"
  end

  # Personal API tokens (Settings page) — used by the CLI and MCP server.
  post   "/settings/api_tokens",     to: "settings#create_api_token", as: :settings_api_tokens
  delete "/settings/api_tokens/:id", to: "settings#revoke_api_token", as: :settings_api_token

  # JSON API — token auth, see Api::V1::BaseController.
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      get "me", to: "me#show"

      resources :projects, only: %i[index show] do
        member do
          get  :analysis
          post :rollback
        end
        resources :deployments, only: %i[index create]
        resources :secrets, only: %i[index]
        put    "secrets/:key", to: "secrets#update",  as: :secret, constraints: { key: /[^\/]+/ }
        delete "secrets/:key", to: "secrets#destroy",               constraints: { key: /[^\/]+/ }
      end

      resources :deployments, only: %i[show] do
        member do
          get  :logs
          post :cancel
        end
      end
    end
  end
end
