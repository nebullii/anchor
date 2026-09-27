require "rails_helper"

RSpec.describe Deployments::HealthCheckJob, type: :job do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:project)  { create(:project, latest_url: "https://svc-old.a.run.app") }
  let(:provider) { instance_double(Providers::Base) }
  let(:rev_url)  { "https://tag---svc.a.run.app" }
  let(:deployment) do
    create(:deployment, project: project, status: "health_check",
           revision_name: "svc-00002-abc", revision_url: rev_url)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Providers).to receive(:for).with(project).and_return(provider)
    project.update_columns(health_check_path: "/up")
  end

  context "when the revision is healthy" do
    before { stub_request(:get, "#{rev_url}/up").to_return(status: 200, body: "ok") }

    it "promotes the revision and marks the deployment running" do
      expect(provider).to receive(:promote!).with(deployment, log: kind_of(Proc)).and_return("https://svc.a.run.app")
      described_class.new.perform(deployment.id, 1, Time.current.to_f)

      deployment.reload
      expect(deployment.status).to eq("running")
      expect(deployment.service_url).to eq("https://svc.a.run.app")
      expect(project.reload.latest_url).to eq("https://svc.a.run.app")
    end

    it "fails without reporting running when promotion fails" do
      allow(provider).to receive(:promote!).and_raise(Providers::Error, "IAM denied")
      described_class.new.perform(deployment.id, 1, Time.current.to_f)
      expect(deployment.reload.status).to eq("failed")
      expect(deployment.error_message).to include("Promotion failed")
    end
  end

  context "when the revision is unhealthy and retries remain" do
    before { stub_request(:get, "#{rev_url}/up").to_return(status: 503) }

    it "re-enqueues itself with backoff instead of sleeping" do
      started = Time.current.to_f
      expect(provider).not_to receive(:promote!)
      expect_any_instance_of(described_class).not_to receive(:sleep)

      expect { described_class.new.perform(deployment.id, 1, started) }
        .to have_enqueued_job(described_class).with(deployment.id, 2, started)
      expect(deployment.reload.status).to eq("health_check")
    end

    it "schedules the retry after the backoff delay" do
      freeze_time do
        described_class.new.perform(deployment.id, 2, Time.current.to_f)
        job = enqueued_jobs.find { |j| j["job_class"] == described_class.name }
        expect(job["scheduled_at"]).to eq((Time.current + Deployments::HealthChecker.backoff_for(2)).iso8601(9))
      end
    end
  end

  context "when the health check never passes" do
    before { stub_request(:get, "#{rev_url}/up").to_return(status: 500) }

    it "does not promote, deletes the revision and fails with category health_check" do
      expect(provider).not_to receive(:promote!)
      expect(provider).to receive(:delete_revision!).with(deployment)

      described_class.new.perform(deployment.id, Deployments::HealthChecker.max_attempts, Time.current.to_f)

      deployment.reload
      expect(deployment.status).to eq("failed")
      expect(deployment.error_category).to eq("health_check")
      expect(deployment.error_message).to include("NOT promoted", "previous revision is still serving")
      expect(project.reload.latest_url).to eq("https://svc-old.a.run.app")
      expect(Deployments::ExplainErrorJob).to have_been_enqueued.with(deployment.id)
    end

    it "gives up once the time budget is spent even if attempts remain" do
      allow(provider).to receive(:delete_revision!)
      started = (Deployments::HealthChecker.budget_seconds + 1).seconds.ago.to_f

      expect { described_class.new.perform(deployment.id, 2, started) }
        .not_to have_enqueued_job(described_class)
      expect(deployment.reload.status).to eq("failed")
    end

    it "still fails cleanly when revision cleanup errors" do
      allow(provider).to receive(:delete_revision!).and_raise(Providers::Error, "boom")
      described_class.new.perform(deployment.id, Deployments::HealthChecker.max_attempts, Time.current.to_f)
      expect(deployment.reload.status).to eq("failed")
      expect(deployment.deployment_logs.pluck(:message).join).to include("Could not delete revision")
    end
  end

  it "passes provider auth headers when the provider offers them" do
    # health_check_headers is an optional extension, so use a plain double.
    provider = double("provider", promote!: "https://svc.a.run.app")
    allow(provider).to receive(:health_check_headers).with(deployment).and_return("Authorization" => "Bearer t")
    allow(Providers).to receive(:for).with(project).and_return(provider)
    stub = stub_request(:get, "#{rev_url}/up").with(headers: { "Authorization" => "Bearer t" }).to_return(status: 200)

    described_class.new.perform(deployment.id, 1, Time.current.to_f)
    expect(stub).to have_been_requested
  end

  it "cleans up the revision if the deployment was cancelled mid-check" do
    deployment.update_columns(status: "cancelled")
    expect(provider).to receive(:delete_revision!).with(deployment)
    expect(provider).not_to receive(:promote!)
    described_class.new.perform(deployment.id, 3, Time.current.to_f)
    expect(deployment.reload.status).to eq("cancelled")
  end
end
