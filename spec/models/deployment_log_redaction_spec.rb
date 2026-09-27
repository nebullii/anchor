require "rails_helper"

RSpec.describe Deployment, "#append_log redaction" do
  let(:deployment) { create(:deployment) }

  it "never stores project secret values" do
    create(:secret, project: deployment.project, key: "DB_PASSWORD", value: "hunter2-very-secret")
    log = deployment.append_log("connecting with hunter2-very-secret")
    expect(log.reload.message).not_to include("hunter2-very-secret")
  end

  it "strips tokens embedded in URLs" do
    log = deployment.append_log("fatal: https://x-access-token:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/a/b.git")
    expect(log.reload.message).not_to include("ghp_abcdefghijklmnopqrstuvwxyz0123456789")
  end
end

RSpec.describe Deployment, "log and timing hygiene" do
  it "strips ANSI colour codes from log lines" do
    log = create(:deployment).append_log("\e[33m1 warning found\e[0m")
    expect(log.reload.message).to eq("1 warning found")
  end

  it "starts the clock for rollbacks that go straight to deploying" do
    deployment = create(:deployment, status: "queued", triggered_by: "rollback")
    deployment.transition_to!("deploying")
    expect(deployment.reload.started_at).to be_present
  end
end
