require "rails_helper"

RSpec.describe Deployment, "#supersede_previous!" do
  let(:project) { create(:project) }

  it "leaves exactly one running deployment per project" do
    older = create(:deployment, project: project, status: "running", revision_name: "rev-1")
    newer = create(:deployment, project: project, status: "running", revision_name: "rev-2")

    newer.supersede_previous!

    expect(older.reload.status).to eq("superseded")
    expect(newer.reload.status).to eq("running")
  end

  it "keeps superseded deployments eligible as rollback targets" do
    older = create(:deployment, project: project, status: "superseded", revision_name: "rev-1")
    create(:deployment, project: project, status: "running", revision_name: "rev-2")

    expect(Deployments::Rollback.default_target(project)).to eq(older)
    expect(Deployments::Rollback.eligible?(older)).to be(true)
  end

  it "does not count superseded deployments as in progress" do
    create(:deployment, project: project, status: "superseded")
    expect { create(:deployment, project: project, status: "queued") }.not_to raise_error
  end
end

RSpec.describe Deployment, "project status sync" do
  let(:project) { create(:project, latest_url: "https://live.example") }

  it "keeps the project active when a new deploy fails but the old one still serves" do
    create(:deployment, project: project, status: "running", service_url: "https://live.example")
    failing = create(:deployment, project: project, status: "health_check")

    failing.transition_to!("failed")

    expect(project.reload.status).to eq("active")
    expect(project.latest_url).to eq("https://live.example")
  end

  it "marks the project errored when nothing has ever gone live" do
    create(:deployment, project: project, status: "building").transition_to!("failed")
    expect(project.reload.status).to eq("error")
  end
end

RSpec.describe Deployment, "finish time" do
  it "keeps the original finished_at when a live deployment is superseded" do
    finished = 2.hours.ago.change(usec: 0)
    older = create(:deployment, status: "running", finished_at: finished)
    older.transition_to!("superseded")
    expect(older.reload.finished_at).to eq(finished)
  end
end
