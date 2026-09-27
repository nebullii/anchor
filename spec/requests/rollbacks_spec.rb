require "rails_helper"

RSpec.describe "Rollbacks", type: :request do
  let(:user)    { create(:user) }
  let(:project) { create(:project, user: user) }

  let!(:older) do
    create(:deployment, project: project, status: "running", revision_name: "rev-1",
           created_at: 2.hours.ago, finished_at: 2.hours.ago)
  end
  let!(:current) do
    create(:deployment, project: project, status: "running", revision_name: "rev-2",
           created_at: 1.hour.ago, finished_at: 1.hour.ago)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
  end

  describe "POST /projects/:project_id/rollback" do
    it "starts a rollback to the chosen deployment and redirects to it" do
      expect {
        post project_rollback_path(project, deployment_id: older.id)
      }.to have_enqueued_job(Deployments::RollbackJob)

      rollback = project.deployments.order(:id).last
      expect(rollback.triggered_by).to eq("rollback")
      expect(rollback.revision_name).to eq("rev-1")
      expect(response).to redirect_to(project_deployment_path(project, rollback))
    end

    it "defaults to the previous healthy revision" do
      post project_rollback_path(project)
      expect(project.deployments.order(:id).last.revision_name).to eq("rev-1")
    end

    it "redirects with an alert when the rollback is not allowed" do
      post project_rollback_path(project, deployment_id: current.id)
      expect(response).to redirect_to(project_path(project))
      expect(flash[:alert]).to match(/already serving/)
    end

    it "does not allow rolling back someone else's project" do
      other = create(:project)
      post project_rollback_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "rollback button partial" do
    def render_button(deployment)
      ApplicationController.render(partial: "deployments/rollback_button", locals: { deployment: deployment })
    end

    it "renders for an eligible deployment" do
      html = render_button(older)
      expect(html).to include("Roll back to this deployment")
      expect(html).to include(project_rollback_path(project, deployment_id: older.id))
    end

    it "renders nothing for the live deployment" do
      expect(render_button(current).strip).to be_empty
    end
  end
end
