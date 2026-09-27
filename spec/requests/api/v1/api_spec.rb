require "rails_helper"

RSpec.describe "API v1", type: :request do
  let(:user)       { create(:user) }
  let(:repository) { create(:repository, user: user, full_name: "acme/web") }
  let(:project)    { create(:project, user: user, repository: repository) }
  let(:api_token)  { ApiToken.generate!(user: user, name: "test") }
  let(:headers)    { { "Authorization" => "Bearer #{api_token.plaintext_token}" } }

  let(:other_user)    { create(:user) }
  let(:other_project) { create(:project, user: other_user) }

  def json
    JSON.parse(response.body)
  end

  # ------------------------------------------------------------------ #
  # Authentication                                                       #
  # ------------------------------------------------------------------ #
  describe "authentication" do
    it "rejects requests without a token" do
      get "/api/v1/me"
      expect(response).to have_http_status(:unauthorized)
      expect(json.dig("error", "code")).to eq("unauthorized")
      expect(response.headers["WWW-Authenticate"]).to include("Bearer")
    end

    it "rejects unknown tokens" do
      get "/api/v1/me", headers: { "Authorization" => "Bearer anc_nope" }
      expect(response).to have_http_status(:unauthorized)
      expect(json.dig("error", "message")).to match(/invalid or has been revoked/)
    end

    it "rejects revoked tokens" do
      api_token.revoke!
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "does not accept session cookies in place of a token" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      get "/api/v1/me"
      expect(response).to have_http_status(:unauthorized)
    end

    it "records last_used_at" do
      expect { get "/api/v1/me", headers: headers }
        .to change { api_token.reload.last_used_at }.from(nil)
    end
  end

  describe "GET /api/v1/me" do
    it "returns the token owner and quota" do
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json.dig("user", "github_login")).to eq(user.github_login)
      expect(json.dig("user", "quota", "daily_limit")).to eq(User::DAILY_DEPLOY_LIMIT)
      expect(json.dig("token", "name")).to eq("test")
    end
  end

  # ------------------------------------------------------------------ #
  # Projects                                                             #
  # ------------------------------------------------------------------ #
  describe "GET /api/v1/projects" do
    it "lists only the current user's projects with their latest deployment" do
      create(:deployment, :success, project: project)
      other_project

      get "/api/v1/projects", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json["projects"].map { |p| p["id"] }).to eq([ project.id ])
      expect(json["projects"].first["repository"]).to eq("acme/web")
      expect(json["projects"].first.dig("latest_deployment", "status")).to eq("success")
    end

    it "honours limit" do
      create_list(:project, 3, user: user)
      get "/api/v1/projects", params: { limit: 2 }, headers: headers
      expect(json["projects"].size).to eq(2)
    end
  end

  describe "GET /api/v1/projects/:id" do
    it "finds by id and by slug" do
      get "/api/v1/projects/#{project.id}", headers: headers
      expect(json.dig("project", "slug")).to eq(project.slug)

      get "/api/v1/projects/#{project.slug}", headers: headers
      expect(json.dig("project", "id")).to eq(project.id)
    end

    it "404s for another user's project" do
      get "/api/v1/projects/#{other_project.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(json.dig("error", "code")).to eq("not_found")
    end
  end

  describe "GET /api/v1/projects/:id/analysis" do
    it "returns the analysis with preflight findings lifted out" do
      finding = { "id" => "no_port", "severity" => "error", "message" => "No PORT", "file" => "Dockerfile",
                  "line" => 3, "fix" => "EXPOSE 8080" }
      project.update_columns(analysis_status: "complete", framework: "rails",
                             analysis_result: { "framework" => "rails", "preflight" => [ finding ] })

      get "/api/v1/projects/#{project.id}/analysis", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json.dig("analysis", "status")).to eq("complete")
      expect(json.dig("analysis", "preflight")).to eq([ finding ])
      expect(json.dig("analysis", "result", "framework")).to eq("rails")
    end

    it "returns an empty preflight list when not analysed" do
      get "/api/v1/projects/#{project.id}/analysis", headers: headers
      expect(json.dig("analysis", "preflight")).to eq([])
    end
  end

  # ------------------------------------------------------------------ #
  # Deployments                                                          #
  # ------------------------------------------------------------------ #
  describe "POST /api/v1/projects/:id/deployments" do
    it "queues a deployment and returns 202" do
      expect {
        post "/api/v1/projects/#{project.id}/deployments", params: { branch: "feature/x" }, headers: headers, as: :json
      }.to have_enqueued_job(DeploymentJob)

      expect(response).to have_http_status(:accepted)
      deployment = json["deployment"]
      expect(deployment["status"]).to eq("queued")
      expect(deployment["branch"]).to eq("feature/x")
      expect(deployment.keys).to include(*%w[id project_id status triggered_by branch commit_sha commit_message
                                             service_url revision_name error_message error_category
                                             ai_explanation started_at finished_at created_at])
      expect(user.reload.deployments_today).to eq(1)
    end

    it "defaults to the production branch" do
      post "/api/v1/projects/#{project.id}/deployments", headers: headers
      expect(json.dig("deployment", "branch")).to eq("main")
    end

    it "409s when a deployment is already in progress" do
      create(:deployment, :building, project: project)
      post "/api/v1/projects/#{project.id}/deployments", headers: headers
      expect(response).to have_http_status(:conflict)
      expect(json.dig("error", "code")).to eq("deploy_in_progress")
    end

    it "429s when the quota is exhausted" do
      user.update_columns(deployments_today: User::DAILY_DEPLOY_LIMIT, quota_reset_at: 1.hour.from_now)
      post "/api/v1/projects/#{project.id}/deployments", headers: headers
      expect(response).to have_http_status(:too_many_requests)
      expect(json.dig("error", "code")).to eq("quota_exceeded")
    end

    it "422s with the missing secret names" do
      project.update_columns(analysis_status: "complete",
                             analysis_result: { "detected_env_vars" => [ { "key" => "DATABASE_URL", "required" => true } ] })
      post "/api/v1/projects/#{project.id}/deployments", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("missing_secrets")
      expect(json.dig("error", "missing_secrets")).to eq([ "DATABASE_URL" ])
    end

    it "rejects option-like branch names" do
      post "/api/v1/projects/#{project.id}/deployments", params: { branch: "--upload-pack=evil" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("invalid_branch")
    end

    it "404s for another user's project" do
      expect {
        post "/api/v1/projects/#{other_project.id}/deployments", headers: headers
      }.not_to have_enqueued_job(DeploymentJob)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/projects/:id/deployments" do
    it "lists newest first and honours limit" do
      old = create(:deployment, :failed, project: project, created_at: 2.hours.ago)
      new = create(:deployment, :success, project: project, created_at: 1.hour.ago)

      get "/api/v1/projects/#{project.id}/deployments", headers: headers
      expect(json["deployments"].map { |d| d["id"] }).to eq([ new.id, old.id ])

      get "/api/v1/projects/#{project.id}/deployments", params: { limit: 1 }, headers: headers
      expect(json["deployments"].size).to eq(1)
    end
  end

  describe "GET /api/v1/deployments/:id" do
    it "returns the deployment" do
      deployment = create(:deployment, :failed, project: project, ai_error_explanation: "Missing gem")
      get "/api/v1/deployments/#{deployment.id}", headers: headers
      expect(json.dig("deployment", "status")).to eq("failed")
      expect(json.dig("deployment", "ai_explanation")).to eq("Missing gem")
    end

    it "404s for another user's deployment" do
      deployment = create(:deployment, project: other_project)
      get "/api/v1/deployments/#{deployment.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/deployments/:id/logs" do
    let(:deployment) { create(:deployment, :building, project: project) }

    it "pages through logs with after_id" do
      first  = deployment.deployment_logs.create!(message: "one", level: "info", source: "system", logged_at: Time.current)
      second = deployment.deployment_logs.create!(message: "two", level: "warn", source: "cloud_build", logged_at: Time.current)

      get "/api/v1/deployments/#{deployment.id}/logs", headers: headers
      expect(json["logs"].map { |l| l["message"] }).to eq(%w[one two])
      expect(json["logs"].first.keys).to match_array(%w[id message level source logged_at])
      expect(json["next_after_id"]).to eq(second.id)

      get "/api/v1/deployments/#{deployment.id}/logs", params: { after_id: first.id }, headers: headers
      expect(json["logs"].map { |l| l["message"] }).to eq(%w[two])

      get "/api/v1/deployments/#{deployment.id}/logs", params: { after_id: second.id }, headers: headers
      expect(json["logs"]).to eq([])
      expect(json["next_after_id"]).to eq(second.id)
    end

    it "404s for another user's deployment" do
      foreign = create(:deployment, project: other_project)
      get "/api/v1/deployments/#{foreign.id}/logs", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/deployments/:id/cancel" do
    it "cancels an in-progress deployment" do
      deployment = create(:deployment, :building, project: project)
      post "/api/v1/deployments/#{deployment.id}/cancel", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json.dig("deployment", "status")).to eq("cancelled")
      expect(deployment.reload.status).to eq("cancelled")
    end

    it "uses Deployment#cancel! when available" do
      deployment = create(:deployment, :building, project: project)
      cancelled  = false
      # cancel! may not exist yet (Backend adds it), so skip verification.
      without_partial_double_verification do
        allow_any_instance_of(Deployment).to receive(:respond_to?).and_call_original
        allow_any_instance_of(Deployment).to receive(:respond_to?).with(:cancel!).and_return(true)
        allow_any_instance_of(Deployment).to receive(:cancel!) do |d|
          cancelled = true
          d.update_columns(status: "cancelled")
        end

        post "/api/v1/deployments/#{deployment.id}/cancel", headers: headers
      end
      expect(cancelled).to be(true)
      expect(json.dig("deployment", "status")).to eq("cancelled")
    end

    it "409s for a finished deployment" do
      deployment = create(:deployment, :success, project: project)
      post "/api/v1/deployments/#{deployment.id}/cancel", headers: headers
      expect(response).to have_http_status(:conflict)
      expect(json.dig("error", "code")).to eq("not_cancellable")
    end
  end

  describe "POST /api/v1/projects/:id/rollback" do
    it "501s while Deployments::Rollback is unavailable" do
      hide_const("Deployments::Rollback") if defined?(Deployments::Rollback)
      post "/api/v1/projects/#{project.id}/rollback", headers: headers
      expect(response).to have_http_status(:not_implemented)
      expect(json.dig("error", "code")).to eq("not_implemented")
    end

    context "when Deployments::Rollback exists" do
      let(:fake_rollback) do
        Class.new do
          class << self
            attr_accessor :calls
          end

          def initialize(project:, target:, user:)
            @project, @target, @user = project, target, user
          end

          def call
            self.class.calls << { project: @project, target: @target, user: @user }
            @project.deployments.create!(status: "queued", triggered_by: "manual", branch: "main")
          end
        end.tap { |k| k.calls = [] }
      end

      before { stub_const("Deployments::Rollback", fake_rollback) }

      it "delegates with the target deployment and returns 202" do
        target = create(:deployment, :success, project: project)
        post "/api/v1/projects/#{project.id}/rollback", params: { deployment_id: target.id }, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(json.dig("deployment", "status")).to eq("queued")
        expect(fake_rollback.calls.last).to include(project: project, target: target, user: user)
      end

      it "passes a nil target when none is given" do
        post "/api/v1/projects/#{project.id}/rollback", headers: headers
        expect(fake_rollback.calls.last[:target]).to be_nil
      end

      it "404s for a target deployment in another project" do
        foreign = create(:deployment, :success, project: other_project)
        post "/api/v1/projects/#{project.id}/rollback", params: { deployment_id: foreign.id }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ------------------------------------------------------------------ #
  # Secrets                                                              #
  # ------------------------------------------------------------------ #
  describe "secrets" do
    it "lists names only, never values" do
      create(:secret, project: project, key: "API_KEY", value: "super-secret-value")
      get "/api/v1/projects/#{project.id}/secrets", headers: headers
      expect(json["secrets"].map { |s| s["key"] }).to eq([ "API_KEY" ])
      expect(response.body).not_to include("super-secret-value")
    end

    it "creates (201) then updates (200) a secret with PUT" do
      put "/api/v1/projects/#{project.id}/secrets/API_KEY", params: { value: "one" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(response.body).not_to include("one\"")

      put "/api/v1/projects/#{project.id}/secrets/API_KEY", params: { value: "two" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(project.secrets.find_by(key: "API_KEY").value).to eq("two")
    end

    it "422s on an invalid key" do
      put "/api/v1/projects/#{project.id}/secrets/PORT", params: { value: "1" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("validation_failed")
    end

    it "400s when value is missing" do
      put "/api/v1/projects/#{project.id}/secrets/API_KEY", params: {}, headers: headers, as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "deletes a secret, then 404s" do
      create(:secret, project: project, key: "API_KEY")
      delete "/api/v1/projects/#{project.id}/secrets/API_KEY", headers: headers
      expect(response).to have_http_status(:no_content)

      delete "/api/v1/projects/#{project.id}/secrets/API_KEY", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "cannot touch another user's secrets" do
      put "/api/v1/projects/#{other_project.id}/secrets/API_KEY", params: { value: "x" }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
      expect(other_project.secrets.count).to eq(0)
    end
  end
end
