require "rails_helper"

RSpec.describe Deployments::BaseJob, type: :job do
  include ActiveJob::TestHelper

  # Defines Deployments::FakeStepJob, a minimal pipeline step that runs
  # +behaviour+ (a lambda receiving the deployment, which may raise).
  def define_step(behaviour)
    klass = Class.new(described_class) do
      define_method(:perform) do |deployment_id|
        catch(:skip) do
          with_deployment(deployment_id) do |deployment|
            guard_status!(deployment, "analyzing", "building")
            behaviour.call(deployment)
          end
        end
      end
    end
    stub_const("Deployments::FakeStepJob", klass)
    # No real waiting between retries in tests.
    allow(Deployments::FakeStepJob).to receive(:retry_delay).and_return(0)
  end

  let(:behaviour)  { ->(_deployment) { } }
  let(:deployment) { create(:deployment, :building) }

  before { define_step(behaviour) }

  describe ".retry_delay" do
    it "grows exponentially and is capped" do
      allow(described_class).to receive(:rand).and_return(0)
      delays = (1..8).map { |n| described_class.retry_delay(n) }
      expect(delays.first(4)).to eq([ 15, 30, 60, 120 ])
      expect(delays.max).to eq(described_class::RETRY_MAX_SECONDS)
    end

    it "adds bounded jitter" do
      50.times { expect(described_class.retry_delay(2)).to be_between(30, 34) }
    end
  end

  context "when a step raises a transient error" do
    let(:behaviour) { ->(_d) { raise Deployments::TransientError, "registry 503" } }

    it "schedules a retry and leaves the deployment in progress" do
      expect {
        Deployments::FakeStepJob.perform_now(deployment.id)
      }.to have_enqueued_job(Deployments::FakeStepJob).with(deployment.id)

      deployment.reload
      expect(deployment.status).to eq("building")
      expect(deployment.deployment_logs.pluck(:message).join).to include("attempt 1/5")
      expect(deployment.deployment_events.for_type("retry_scheduled")).to exist
    end

    it "fails the deployment after the final retry" do
      perform_enqueued_jobs(only: Deployments::FakeStepJob) do
        Deployments::FakeStepJob.perform_later(deployment.id)
      end

      deployment.reload
      expect(deployment.status).to eq("failed")
      expect(deployment.error_message).to include("registry 503")
      expect(deployment.error_message).to include("gave up after 5 attempts")
      expect(deployment.deployment_events.for_type("retry_scheduled").count).to eq(4)
      expect(Deployments::ExplainErrorJob).to have_been_enqueued.with(deployment.id)
    end
  end

  context "when a later attempt succeeds" do
    let(:calls) { [] }
    let(:behaviour) do
      lambda do |_d|
        calls << 1
        raise Deployments::TransientError, "blip" if calls.size < 3
      end
    end

    it "stops retrying and does not fail the deployment" do
      perform_enqueued_jobs(only: Deployments::FakeStepJob) do
        Deployments::FakeStepJob.perform_later(deployment.id)
      end

      expect(calls.size).to eq(3)
      expect(deployment.reload.status).to eq("building")
    end
  end

  context "when the provider raises Providers::TransientError" do
    let(:behaviour) { ->(_d) { raise Providers::TransientError, "rate limited" } }

    before do
      stub_const("Providers", Module.new)
      stub_const("Providers::Error", Class.new(StandardError))
      stub_const("Providers::TransientError", Class.new(Providers::Error))
    end

    it "is treated as transient and retried" do
      expect {
        Deployments::FakeStepJob.perform_now(deployment.id)
      }.to have_enqueued_job(Deployments::FakeStepJob)
      expect(deployment.reload.status).to eq("building")
    end
  end

  context "when a step raises a permanent DeploymentError" do
    let(:behaviour) { ->(_d) { raise Deployments::DeploymentError, "Dockerfile error: bad syntax" } }

    it "fails immediately without retrying" do
      expect {
        Deployments::FakeStepJob.perform_now(deployment.id)
      }.not_to have_enqueued_job(Deployments::FakeStepJob)

      deployment.reload
      expect(deployment.status).to eq("failed")
      expect(deployment.error_category).to eq("dockerfile_error")
    end
  end

  context "when a step raises an unexpected error" do
    let(:behaviour) { ->(_d) { raise ArgumentError, "nil" } }

    it "fails the deployment and re-raises for Sidekiq visibility" do
      expect { Deployments::FakeStepJob.perform_now(deployment.id) }.to raise_error(ArgumentError)
      expect(deployment.reload.status).to eq("failed")
    end
  end

  context "when the deployment is cancelled while the job runs" do
    let(:behaviour) do
      lambda do |d|
        Deployment.find(d.id).cancel!   # user clicks Cancel mid-step
        d.transition_to!("deploying")   # the job then tries to move on
      end
    end

    it "stops cleanly and keeps the deployment cancelled" do
      expect { Deployments::FakeStepJob.perform_now(deployment.id) }.not_to raise_error
      deployment.reload
      expect(deployment.status).to eq("cancelled")
      expect(deployment.error_message).to be_nil
    end
  end

  context "when a transient error hits a deployment that was cancelled" do
    let(:behaviour) do
      lambda do |d|
        Deployment.find(d.id).cancel! unless Deployment.find(d.id).status == "cancelled"
        raise Deployments::TransientError, "late blip"
      end
    end

    it "does not flip it to failed" do
      Deployments::FakeStepJob.perform_now(deployment.id)
      # The retry sees a terminal deployment and skips (guard_status!).
      perform_enqueued_jobs(only: Deployments::FakeStepJob)
      expect(deployment.reload.status).to eq("cancelled")
    end
  end

  context "when the deployment is already terminal" do
    let(:behaviour) { ->(_d) { raise "should not run" } }

    it "skips the step" do
      done = create(:deployment, :cancelled)
      expect { Deployments::FakeStepJob.perform_now(done.id) }.not_to raise_error
      expect(done.reload.status).to eq("cancelled")
    end
  end

  it "discards jobs for deleted deployments" do
    expect { Deployments::FakeStepJob.perform_now(-1) }.not_to raise_error
  end
end
