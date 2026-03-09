require "rails_helper"

RSpec.describe "Projects", type: :request do
  let(:user)       { create(:user) }
  let(:repository) { create(:repository, user: user) }
  let(:project)    { create(:project, user: user, repository: repository) }

  # Log in by setting session
  before do
    post "/auth/developer", params: {} rescue nil  # ignored if developer strategy absent
    # Use the session directly via a helper
    allow_any_instance_of(ApplicationController)
      .to receive(:current_user)
      .and_return(user)
    allow_any_instance_of(ApplicationController)
      .to receive(:logged_in?)
      .and_return(true)
  end

  describe "POST /projects/:id/analyze" do
    it "enqueues a RepositoryAnalysisJob" do
      expect {
        post analyze_project_path(project)
      }.to have_enqueued_job(RepositoryAnalysisJob).with(project.id)
    end

    it "sets analysis_status to analyzing" do
      post analyze_project_path(project)
      expect(project.reload.analysis_status).to eq("analyzing")
    end

    it "responds with redirect for HTML requests" do
      post analyze_project_path(project)
      expect(response).to redirect_to(project_path(project))
    end

    it "responds with Turbo Stream for turbo requests" do
      post analyze_project_path(project),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response.content_type).to include("text/vnd.turbo-stream.html")
    end

    it "returns 404 for a project that does not belong to the user" do
      other_project = create(:project)
      post analyze_project_path(other_project)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /projects (create)" do
    it "enqueues a RepositoryAnalysisJob after project is created" do
      expect {
        post projects_path, params: {
          project: {
            name:              "New App",
            repository_id:     repository.id,
            gcp_project_id:    "my-gcp-project",
            gcp_region:        "us-central1",
            production_branch: "main"
          }
        }
      }.to have_enqueued_job(RepositoryAnalysisJob)
    end

    it "does not enqueue analysis when project fails to save" do
      expect {
        post projects_path, params: {
          project: {
            name:           "",   # blank name triggers validation failure
            repository_id:  repository.id,
            gcp_project_id: "my-gcp-project",
            gcp_region:     "us-central1"
          }
        }
      }.not_to have_enqueued_job(RepositoryAnalysisJob)
    end
  end
end
