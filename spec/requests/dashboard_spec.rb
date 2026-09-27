require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:user) { create(:user) }

  def env(name)
    ActiveSupport::EnvironmentInquirer.new(name)
  end

  def with_dev_login_flag(value)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ANCHOR_DEV_LOGIN").and_return(value)
  end

  describe ".dev_login_enabled?" do
    it "is enabled only in development with ANCHOR_DEV_LOGIN=1" do
      expect(DashboardController.dev_login_enabled?(env: "development", flag: "1")).to be(true)
    end

    it "is disabled in development without the flag" do
      expect(DashboardController.dev_login_enabled?(env: "development", flag: nil)).to be(false)
      expect(DashboardController.dev_login_enabled?(env: "development", flag: "true")).to be(false)
    end

    it "is never enabled in production, even with the flag" do
      expect(DashboardController.dev_login_enabled?(env: "production", flag: "1")).to be(false)
    end

    it "is never enabled in test or staging, even with the flag" do
      expect(DashboardController.dev_login_enabled?(env: "test", flag: "1")).to be(false)
      expect(DashboardController.dev_login_enabled?(env: "staging", flag: "1")).to be(false)
    end
  end

  describe "GET /?dev_login=1" do
    let!(:demo_user) { create(:user, github_id: DashboardController::DEV_LOGIN_GITHUB_ID, github_login: "demo") }

    context "in development with ANCHOR_DEV_LOGIN=1" do
      before do
        allow(Rails).to receive(:env).and_return(env("development"))
        with_dev_login_flag("1")
      end

      it "signs in as the seeded demo user" do
        get root_path(dev_login: 1)

        expect(response).to redirect_to(root_path)
        expect(session[:user_id]).to eq(demo_user.id)
      end

      it "shows the dev login button on the landing page" do
        get root_path
        expect(response.body).to include("Continue as demo user")
      end

      it "explains how to fix a missing demo user" do
        demo_user.destroy!
        get root_path(dev_login: 1)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("db:seed")
        expect(session[:user_id]).to be_nil
      end
    end

    context "in production, even with ANCHOR_DEV_LOGIN=1" do
      before do
        allow(Rails).to receive(:env).and_return(env("production"))
        with_dev_login_flag("1")
      end

      it "refuses to sign anyone in" do
        get root_path(dev_login: 1)

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end

      it "does not render the dev login button" do
        get root_path
        expect(response.body).not_to include("Continue as demo user")
      end
    end

    context "in the test environment (flag unset)" do
      it "refuses to sign anyone in" do
        get root_path(dev_login: 1)

        expect(response).to have_http_status(:not_found)
        expect(session[:user_id]).to be_nil
      end
    end
  end

  describe "GET / (signed in)" do
    before { sign_in_via_github(user) }

    it "shows a first-run empty state with next steps when there are no projects" do
      get root_path

      page = Nokogiri::HTML(response.body)
      empty = page.at_css("[data-testid=empty-state]")
      expect(empty).to be_present
      expect(empty.text).to include("Deploy your first app", "Local Docker", "Pick a repository")
      expect(empty.at_css("a[href='#{wizard_path}']")).to be_present
    end

    it "does not list unfinished wizard drafts as projects" do
      create(:project, user: user, repository: create(:repository, user: user), name: "half-done", draft: true)

      get root_path

      expect(response.body).not_to include("half-done")
      expect(response.body).to include("Deploy your first app")
    end

    it "tells the user how to ship when projects exist but nothing was deployed" do
      project = create(:project, user: user, repository: create(:repository, user: user))

      get root_path

      hint = Nokogiri::HTML(response.body).at_css("[data-testid=no-deployments]")
      expect(hint.text).to include("Deploy")
      expect(hint.at_css("a[href='#{project_path(project)}']")).to be_present
    end

    context "when the latest deployment failed" do
      let(:project) { create(:project, user: user, repository: create(:repository, user: user)) }

      it "shows the failed-deploy panel with category, hint, AI explanation and Retry" do
        create(:deployment, :failed, project: project,
               error_message: "PERMISSION_DENIED: caller lacks run.services.create",
               error_category: "auth_error",
               ai_error_explanation: "The service account is missing the Cloud Run Admin role.")

        get root_path

        panel = Nokogiri::HTML(response.body).at_css("[data-testid=failed-deploy-panel]")
        expect(panel).to be_present
        expect(panel.at_css("[data-testid=error-category]").text.strip).to eq("Auth error")
        expect(panel.text).to include(Deployments::ErrorCategorizer.user_hint("auth_error"))
        expect(panel.text).to include("missing the Cloud Run Admin role")
        retry_form = panel.at_css("form[action='#{deploy_project_path(project)}']")
        expect(retry_form).to be_present
        expect(retry_form.at_css("button").text).to eq("Retry")
      end

      it "categorizes on the fly and explains the missing AI explanation" do
        create(:deployment, :failed, project: project, error_message: "Build failed",
               error_category: nil, finished_at: 10.minutes.ago)

        get root_path

        panel = Nokogiri::HTML(response.body).at_css("[data-testid=failed-deploy-panel]")
        expect(panel.at_css("[data-testid=error-category]").text.strip).to eq("Dockerfile error")
        expect(panel.text).to include("No AI explanation")
      end

      it "offers a shortcut to add a missing env var" do
        create(:deployment, :failed, project: project,
               error_message: "KeyError: key not found: STRIPE_API_KEY", error_category: "missing_env_var")

        get root_path

        expect(response.body).to include("Add STRIPE_API_KEY")
      end
    end

    it "hides the failed-deploy panel when the latest deployment succeeded" do
      project = create(:project, user: user, repository: create(:repository, user: user))
      create(:deployment, :failed, project: project, created_at: 1.hour.ago)
      create(:deployment, :success, project: project)

      get root_path

      expect(response.body).not_to include("failed-deploy-panel")
    end
  end

  describe "GET /pricing" do
    it "makes no paid-plan or trial claims Anchor cannot honour" do
      get pricing_path

      expect(response).to have_http_status(:success)
      expect(response.body).not_to match(/14-day trial|\$19|\$49|Cancel anytime|hello@anchor\.dev/)
      expect(response.body).to include("free and open source")
    end
  end

  describe "GET / (landing)" do
    it "does not claim Claude powers error explanations" do
      get root_path
      expect(response.body).not_to include("Claude reads")
    end
  end
end
