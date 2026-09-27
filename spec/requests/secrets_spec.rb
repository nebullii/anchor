require "rails_helper"

RSpec.describe "Secrets", type: :request do
  let(:user)    { create(:user) }
  let(:project) { create(:project, user: user, repository: create(:repository, user: user)) }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
  end

  describe "POST /projects/:id/secrets" do
    it "creates an encrypted secret and logs the key but never the value" do
      allow(Rails.logger).to receive(:info).and_call_original

      post project_secrets_path(project), params: { secret: { key: "STRIPE_KEY", value: "sk_live_#{'z' * 24}" } }

      expect(response).to redirect_to(project_secrets_path(project))
      expect(project.secrets.find_by!(key: "STRIPE_KEY").value).to eq("sk_live_#{'z' * 24}")
      expect(Rails.logger).to have_received(:info).with(a_string_including("secret.created", "key=STRIPE_KEY"))
      expect(Rails.logger).not_to have_received(:info).with(a_string_including("z" * 24))
    end

    it "rejects invalid keys" do
      post project_secrets_path(project), params: { secret: { key: "lower", value: "x" * 10 } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "DELETE /projects/:id/secrets/:id" do
    it "removes the secret" do
      secret = create(:secret, project: project)
      expect { delete project_secret_path(project, secret) }.to change(Secret, :count).by(-1)
    end
  end

  describe "authorization" do
    let(:other_project) { create(:project) }

    it "404s for another user's project" do
      get project_secrets_path(other_project)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot delete another user's secret" do
      secret = create(:secret, project: other_project)
      expect { delete project_secret_path(project, secret) }.not_to change(Secret, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
