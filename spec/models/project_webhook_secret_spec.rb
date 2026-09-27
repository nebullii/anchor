require "rails_helper"

RSpec.describe Project, "webhook secret" do
  it "is encrypted at rest but readable in Ruby" do
    project = create(:project)
    raw = Project.connection.select_value("SELECT webhook_secret FROM projects WHERE id = #{project.id}")

    expect(project.reload.webhook_secret).to match(/\A\h{48}\z/)
    expect(raw).not_to eq(project.webhook_secret)
  end
end

require Rails.root.join("db/migrate/20260927170001_encrypt_project_webhook_secrets")

RSpec.describe EncryptProjectWebhookSecrets do
  it "encrypts legacy plaintext secrets in place, preserving their value" do
    project = create(:project)
    Project.connection.execute("UPDATE projects SET webhook_secret = 'legacy-plain-secret' WHERE id = #{project.id}")

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    raw = Project.connection.select_value("SELECT webhook_secret FROM projects WHERE id = #{project.id}")
    expect(raw).to start_with('{"p":')
    expect(project.reload.webhook_secret).to eq("legacy-plain-secret")
  end
end
