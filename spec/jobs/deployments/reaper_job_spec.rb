require "rails_helper"

RSpec.describe Deployments::ReaperJob, type: :job do
  include ActiveJob::TestHelper

  # In-memory stand-in for Redis SET NX / DEL so specs need no Redis server.
  let(:fake_redis) { {} }

  before do
    store = fake_redis
    allow(described_class).to receive(:redis_set_nx) do |key, value, _ttl|
      next false if store.key?(key)
      store[key] = value
      true
    end
    allow(described_class).to receive(:redis_del) { |key| store.delete(key) }
  end

  def stuck(status, age, project: create(:project))
    create(:deployment, project: project, status: status).tap do |d|
      d.update_columns(status_changed_at: age.ago, updated_at: age.ago)
    end
  end

  describe "#reap!" do
    it "fails deployments stuck past their status timeout" do
      building = stuck("building", 46.minutes)
      queued   = stuck("queued", 16.minutes)

      reaped = described_class.new.reap!

      expect(reaped).to contain_exactly(building, queued)
      building.reload
      expect(building.status).to eq("failed")
      expect(building.error_message).to include("stuck in 'building' for more than 45 minutes")
      expect(building.error_category).to eq("timeout")
      expect(building.deployment_events.for_type("timed_out")).to exist
      expect(queued.reload.status).to eq("failed")
    end

    it "leaves deployments that are within their timeout" do
      building  = stuck("building", 30.minutes)   # build limit is 45m
      analyzing = stuck("analyzing", 5.minutes)

      expect(described_class.new.reap!).to be_empty
      expect(building.reload.status).to eq("building")
      expect(analyzing.reload.status).to eq("analyzing")
    end

    it "never touches terminal deployments" do
      running = create(:deployment, :running)
      running.update_columns(status_changed_at: 3.days.ago, updated_at: 3.days.ago)

      described_class.new.reap!
      expect(running.reload.status).to eq("running")
    end

    it "falls back to updated_at for rows without status_changed_at" do
      legacy = create(:deployment, :deploying)
      legacy.update_columns(status_changed_at: nil, updated_at: 1.hour.ago)

      described_class.new.reap!
      expect(legacy.reload.status).to eq("failed")
    end

    it "frees the project so a new deployment can start" do
      project = create(:project)
      stuck("health_check", 25.minutes, project: project)

      described_class.new.reap!
      expect(project.reload.has_active_deployment?).to be false
    end

    it "asks the provider to cancel a hung build" do
      provider = double("provider")
      stub_const("Providers", Module.new { def self.for(_project) = nil })
      allow(Providers).to receive(:for).and_return(provider)
      building = stuck("building", 2.hours)
      expect(provider).to receive(:cancel_build!).with(building)

      described_class.new.reap!
    end
  end

  describe "#perform" do
    it "reaps and schedules the next run" do
      building = stuck("building", 2.hours)

      expect {
        described_class.perform_now
      }.to have_enqueued_job(described_class).with(true)

      expect(building.reload.status).to eq("failed")
      expect(fake_redis).to have_key(described_class::SCHEDULE_KEY)
      expect(fake_redis).not_to have_key(described_class::RUN_LOCK_KEY)
    end

    it "does not start a second chain when one is already scheduled" do
      fake_redis[described_class::SCHEDULE_KEY] = "1"
      expect { described_class.perform_now }.not_to have_enqueued_job(described_class)
    end

    it "lets the scheduled chain job re-schedule itself" do
      fake_redis[described_class::SCHEDULE_KEY] = "1"
      expect { described_class.perform_now(true) }.to have_enqueued_job(described_class).with(true)
    end

    it "skips reaping while another run holds the lock" do
      fake_redis[described_class::RUN_LOCK_KEY] = "other-jid"
      building = stuck("building", 2.hours)

      described_class.perform_now
      expect(building.reload.status).to eq("building")
      expect(fake_redis[described_class::RUN_LOCK_KEY]).to eq("other-jid")
    end

    it "schedules the next run and releases the lock even if reaping raises" do
      allow_any_instance_of(described_class).to receive(:reap!).and_raise("db blip")
      expect {
        expect { described_class.perform_now }.to raise_error("db blip")
      }.to have_enqueued_job(described_class).with(true)
      expect(fake_redis).not_to have_key(described_class::RUN_LOCK_KEY)
    end
  end

  describe ".ensure_scheduled" do
    it "enqueues an immediate run" do
      expect { described_class.ensure_scheduled }.to have_enqueued_job(described_class)
    end
  end

  describe "Redis helpers", :redis do
    before do
      allow(described_class).to receive(:redis_set_nx).and_call_original
      allow(described_class).to receive(:redis_del).and_call_original
    end

    it "returns false instead of raising when Redis is down" do
      allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError)
      expect(described_class.redis_set_nx("k", "v", 10)).to be false
      expect(described_class.redis_del("k")).to be_nil
    end
  end
end

RSpec.describe Deployments::ReaperJob, "resuming lost health checks" do
  include ActiveJob::TestHelper

  let(:deployment) do
    create(:deployment, status: "health_check", revision_url: "http://localhost:5000",
                        status_changed_at: 10.minutes.ago)
  end

  it "re-enqueues the health check once when the job went silent, instead of failing" do
    deployment.deployment_logs.update_all(logged_at: 10.minutes.ago)

    expect { described_class.new.reap! }
      .to have_enqueued_job(Deployments::HealthCheckJob).with(deployment.id)
    expect(deployment.reload.status).to eq("health_check")
    expect(deployment.deployment_events.for_type("resumed").count).to eq(1)

    expect { described_class.new.reap! }.not_to have_enqueued_job(Deployments::HealthCheckJob)
  end

  it "leaves an active health check alone" do
    deployment.append_log("Health check 2/8 failed; retrying in 10s.")
    expect { described_class.new.reap! }.not_to have_enqueued_job(Deployments::HealthCheckJob)
  end
end
