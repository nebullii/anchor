require "rails_helper"

# Every gcloud call goes through FakeCommandRunner — nothing is executed.
RSpec.describe Providers::GcpCloudRun do
  let(:runner)     { FakeCommandRunner.new }
  let(:user)       { create(:user, google_access_token: "ya29.secret-token", google_token_expires_at: 1.hour.from_now) }
  let(:project)    { create(:project, user: user, gcp_project_id: "acme-prod", gcp_region: "us-east1", port: 8080) }
  let(:deployment) { create(:deployment, :building, project: project) }
  let(:provider)   { described_class.new(project, runner: runner) }
  let(:log_lines)  { [] }
  let(:log)        { ->(line) { log_lines << line } }

  def deploy_json(tag:, revision:, service_url: "https://cl-app-abc-ue.a.run.app")
    {
      "metadata" => { "name" => project.service_name },
      "status" => {
        "url" => service_url,
        "latestCreatedRevisionName" => revision,
        "traffic" => [
          { "revisionName" => "#{project.service_name}-00001-old", "percent" => 100 },
          { "revisionName" => revision, "tag" => tag, "url" => "https://#{tag}---cl-app-abc-ue.a.run.app" }
        ]
      }
    }.to_json
  end

  it "is what Providers.for returns for gcp_cloud_run projects" do
    expect(Providers.for(project)).to be_a(described_class)
  end

  describe "credentials" do
    it "runs gcloud with the user's OAuth token in the environment, never in argv" do
      runner.stub(/builds describe/, output: { status: "WORKING" }.to_json)
      deployment.update!(build_ref: "b-1")
      provider.build_status(deployment)

      call = runner.calls.last
      expect(call.env["CLOUDSDK_AUTH_ACCESS_TOKEN"]).to eq("ya29.secret-token")
      expect(call.line).not_to include("ya29.secret-token")
      expect(call.redact).to include("ya29.secret-token")
    end

    it "raises a permanent error when Google is not connected" do
      user.update!(google_access_token: nil)
      deployment.update!(build_ref: "b-1")
      expect { provider.build_status(deployment) }.to raise_error(Providers::Error, /not connected/)
      expect(runner.calls).to be_empty
    end
  end

  describe "#provision!" do
    it "enables APIs, creates the registry when missing and marks the project provisioned" do
      runner.stub(/artifacts repositories describe/, output: "NOT_FOUND", exit_status: 1)
      provider.provision!(log: log)

      expect(runner.lines).to include(a_string_starting_with("gcloud services enable cloudbuild.googleapis.com run.googleapis.com"))
      expect(runner.find(/artifacts repositories create anchor/).argv)
        .to include("--location=us-east1", "--project=acme-prod", "--repository-format=DOCKER")
      expect(project.reload.gcp_provisioned).to be(true)
    end

    it "is a no-op once provisioned" do
      project.update!(gcp_provisioned: true)
      provider.provision!(log: log)
      expect(runner.calls).to be_empty
    end

    it "stores the error and raises Providers::Error on failure" do
      runner.stub(/services enable/, output: "PERMISSION_DENIED: caller lacks permission", exit_status: 1)
      expect { provider.provision!(log: log) }.to raise_error(Providers::Error, /GCP setup failed/)
      expect(project.reload.gcp_provision_error).to include("PERMISSION_DENIED")
    end

    it "raises TransientError when the API is rate limited" do
      runner.stub(/services enable/, output: "RESOURCE_EXHAUSTED: Quota exceeded", exit_status: 1)
      expect { provider.provision!(log: log) }.to raise_error(Providers::TransientError)
    end
  end

  describe "#build!" do
    it "submits the source asynchronously to Cloud Build and returns the build id" do
      runner.stub(/builds submit/, output: "Creating temporary archive...\nbuild-abc-123\n")

      ref = provider.build!(deployment, "/tmp/src", log: log)

      expect(ref).to eq("build-abc-123")
      image = "us-east1-docker.pkg.dev/acme-prod/anchor/#{project.service_name}:#{deployment.id}"
      expect(runner.commands.last).to eq([
        "gcloud", "builds", "submit", "/tmp/src",
        "--project=acme-prod", "--tag=#{image}", "--timeout=30m", "--async", "--format=value(id)"
      ])
      expect(deployment.reload.image_url).to eq(image)
    end

    it "raises when no build id comes back" do
      runner.stub(/builds submit/, output: "")
      expect { provider.build!(deployment, "/tmp/src", log: log) }.to raise_error(Providers::Error, /build ID/)
    end
  end

  describe "#build_status" do
    before { deployment.update!(build_ref: "build-abc-123") }

    it "maps SUCCESS to :success with the log url" do
      runner.stub(/builds describe/, output: { status: "SUCCESS", logUrl: "https://console/logs" }.to_json)
      status = provider.build_status(deployment)
      expect(status).to be_success
      expect(status.log_url).to eq("https://console/logs")
      expect(runner.commands.last).to eq(%w[gcloud builds describe build-abc-123 --project=acme-prod --format=json])
    end

    it "maps FAILURE to :failure with the failure detail" do
      runner.stub(/builds describe/, output: { status: "FAILURE", failureInfo: { detail: "step 0 exited 1" } }.to_json)
      status = provider.build_status(deployment)
      expect(status).to be_failure
      expect(status.detail).to eq("Cloud Build failure: step 0 exited 1")
    end

    it "maps WORKING / QUEUED to :pending" do
      runner.stub(/builds describe/, output: { status: "QUEUED" }.to_json)
      expect(provider.build_status(deployment)).to be_pending
    end

    it "raises TransientError on a 503 from the API" do
      runner.stub(/builds describe/, output: "ERROR: (gcloud.builds.describe) HTTPError 503: Service Unavailable", exit_status: 1)
      expect { provider.build_status(deployment) }.to raise_error(Providers::TransientError)
    end

    it "raises permanent Error when the build does not exist" do
      runner.stub(/builds describe/, output: "ERROR: NOT_FOUND: Requested entity was not found.", exit_status: 1)
      expect { provider.build_status(deployment) }.to raise_error(Providers::Error) { |e|
        expect(e).not_to be_a(Providers::TransientError)
      }
    end
  end

  describe "#cancel_build!" do
    it "cancels the Cloud Build" do
      deployment.update!(build_ref: "build-abc-123")
      expect(provider.cancel_build!(deployment)).to be(true)
      expect(runner.commands.last).to eq(%w[gcloud builds cancel build-abc-123 --project=acme-prod])
    end

    it "does nothing without a build ref" do
      expect(provider.cancel_build!(deployment)).to be(false)
      expect(runner.calls).to be_empty
    end

    it "treats an already-finished build as nothing to cancel" do
      deployment.update!(build_ref: "build-abc-123")
      runner.stub(/builds cancel/, output: "FAILED_PRECONDITION: build is not running", exit_status: 1)
      expect(provider.cancel_build!(deployment)).to be(false)
    end
  end

  describe "#deploy_revision!" do
    let(:tag) { "d#{deployment.id}" }

    before do
      deployment.update!(image_url: "us-east1-docker.pkg.dev/acme-prod/anchor/app:1")
      runner.stub(/run deploy/, output: ->(_) { deploy_json(tag: tag, revision: "cl-app-00002-new") })
    end

    it "deploys a tagged revision with --no-traffic and returns the tagged URL" do
      revision = provider.deploy_revision!(deployment, env: {}, log: log)

      expect(revision).to eq(Providers::Revision.new(name: "cl-app-00002-new", url: "https://#{tag}---cl-app-abc-ue.a.run.app"))
      argv = runner.find(/run deploy/).argv
      expect(argv.first(4)).to eq([ "gcloud", "run", "deploy", project.service_name ])
      expect(argv).to include(
        "--project=acme-prod", "--region=us-east1", "--image=us-east1-docker.pkg.dev/acme-prod/anchor/app:1",
        "--no-traffic", "--tag=#{tag}", "--port=8080", "--memory=512Mi", "--allow-unauthenticated",
        "--clear-env-vars", "--format=json"
      )
    end

    it "honours public_access: false and a custom memory size" do
      project.update!(public_access: false, memory: "1Gi")
      provider.deploy_revision!(deployment, env: {}, log: log)

      argv = runner.find(/run deploy/).argv
      expect(argv).to include("--no-allow-unauthenticated", "--memory=1Gi")
      expect(argv).not_to include("--allow-unauthenticated")
    end

    it "omits --no-traffic when the service does not exist yet (Cloud Run rejects it on create)" do
      runner.stub(/run services describe/, output: "ERROR: Cannot find service [x]: could not be found", exit_status: 1)
      provider.deploy_revision!(deployment, env: {}, log: log)
      expect(runner.find(/run deploy/).argv).not_to include("--no-traffic")
    end

    it "passes secrets via an env-vars file, never in argv, and redacts them from logs" do
      seen_yaml = nil
      runner.stub(/run deploy/, output: lambda { |argv|
        path = argv.find { |a| a.start_with?("--env-vars-file=") }.delete_prefix("--env-vars-file=")
        seen_yaml = YAML.safe_load(File.read(path))
        deploy_json(tag: tag, revision: "cl-app-00002-new")
      })

      provider.deploy_revision!(deployment, env: { "API_KEY" => "s3cr3t,=value" }, log: log)

      call = runner.find(/run deploy/)
      expect(seen_yaml).to eq("API_KEY" => "s3cr3t,=value")
      expect(call.line).not_to include("s3cr3t")
      expect(call.redact).to include("s3cr3t,=value")
    end

    it "falls back to deriving the tagged URL from the service URL" do
      runner.stub(/run deploy/, output: { status: { url: "https://svc-xyz.a.run.app", latestCreatedRevisionName: "svc-3" } }.to_json)
      revision = provider.deploy_revision!(deployment, env: {}, log: log)
      expect(revision.url).to eq("https://#{tag}---svc-xyz.a.run.app")
      expect(revision.name).to eq("svc-3")
    end

    it "maps quota/rate-limit failures to TransientError" do
      runner.stub(/run deploy/, output: "ERROR: 429 Too Many Requests", exit_status: 1)
      expect { provider.deploy_revision!(deployment, env: {}, log: log) }.to raise_error(Providers::TransientError)
    end

    it "maps bad configuration to a permanent Error" do
      runner.stub(/run deploy/, output: "ERROR: Invalid value for [--memory]", exit_status: 1)
      expect { provider.deploy_revision!(deployment, env: {}, log: log) }
        .to raise_error(an_instance_of(Providers::Error))
    end
  end

  describe "#promote! / #rollback!" do
    before do
      runner.stub(/update-traffic/, output: { status: { url: "https://cl-app-abc-ue.a.run.app" } }.to_json)
    end

    it "routes 100% of traffic to the deployment's revision" do
      deployment.update!(revision_name: "cl-app-00002-new")
      url = provider.promote!(deployment, log: log)

      expect(url).to eq("https://cl-app-abc-ue.a.run.app")
      expect(runner.commands.last).to eq([
        "gcloud", "run", "services", "update-traffic", project.service_name,
        "--project=acme-prod", "--region=us-east1", "--platform=managed",
        "--to-revisions=cl-app-00002-new=100", "--format=json"
      ])
    end

    it "refuses to promote a deployment without a revision" do
      expect { provider.promote!(deployment, log: log) }.to raise_error(Providers::Error, /no revision/)
    end

    it "rolls back by routing traffic to an older revision" do
      provider.rollback!(project, "cl-app-00001-old", log: log)
      expect(runner.commands.last).to include("--to-revisions=cl-app-00001-old=100")
    end

    it "falls back to describing the service when update-traffic prints no URL" do
      runner.stub(/update-traffic/, output: "Done.")
      runner.stub(/services describe/, output: "https://cl-app-abc-ue.a.run.app\n")
      expect(provider.rollback!(project, "rev-1", log: log)).to eq("https://cl-app-abc-ue.a.run.app")
    end
  end

  describe "#delete_revision!" do
    it "deletes the revision quietly" do
      deployment.update!(revision_name: "cl-app-00002-new")
      expect(provider.delete_revision!(deployment)).to be(true)
      expect(runner.commands.last).to eq(%w[gcloud run revisions delete cl-app-00002-new --project=acme-prod
                                            --region=us-east1 --platform=managed --quiet])
    end

    it "swallows failures (best effort)" do
      deployment.update!(revision_name: "cl-app-00002-new")
      runner.stub(/revisions delete/, output: "FAILED_PRECONDITION: revision is serving traffic", exit_status: 1)
      expect(provider.delete_revision!(deployment)).to be(false)
    end
  end
end
