require "rails_helper"

# Docker is never invoked: FakeCommandRunner records the argv instead.
RSpec.describe Providers::LocalDocker do
  let(:runner)     { FakeCommandRunner.new }
  let(:project)    { create(:project, provider: "local_docker", gcp_project_id: nil, port: 8080, memory: "1Gi") }
  let(:deployment) { create(:deployment, :building, project: project) }
  let(:provider)   { described_class.new(project, runner: runner, port_allocator: -> { 49_152 }) }
  let(:log_lines)  { [] }
  let(:log)        { ->(line) { log_lines << line } }
  let(:container)  { "anchor-#{project.service_name}-#{deployment.id}" }

  it "is what Providers.for returns for local_docker projects" do
    expect(Providers.for(project)).to be_a(described_class)
  end

  it "does not require a GCP project or enqueue GCP provisioning" do
    expect(project).to be_valid
    expect(Gcp::ProvisionProjectJob).not_to have_been_enqueued.with(project.id)
  end

  describe "#provision!" do
    it "checks the Docker daemon is reachable" do
      runner.stub(/docker version/, output: "27.0.1")
      provider.provision!(log: log)
      expect(log_lines.last).to include("27.0.1")
    end

    it "raises a helpful error when the daemon is down" do
      runner.stub(/docker version/, output: "Cannot connect to the Docker daemon", exit_status: 1)
      expect { provider.provision!(log: log) }.to raise_error(Providers::Error, /start Docker/)
    end
  end

  describe "#build!" do
    it "builds synchronously with docker build and returns the image tag" do
      ref = provider.build!(deployment, "/tmp/src", log: log)

      image = "anchor-local/#{project.service_name}:#{deployment.id}"
      expect(ref).to eq(image)
      expect(runner.commands.last).to eq([
        "docker", "build",
        "--label", "anchor.project=#{project.id}",
        "--label", "anchor.deployment=#{deployment.id}",
        "-t", image, "/tmp/src"
      ])
      expect(deployment.reload.image_url).to eq(image)
    end

    it "raises a permanent error when the build fails and cleans up its pid file" do
      runner.stub(/docker build/, output: "ERROR: failed to solve: npm ci exited 1", exit_status: 1)
      expect { provider.build!(deployment, "/tmp/src", log: log) }.to raise_error(Providers::Error, /npm ci/)
      expect(File.exist?(Rails.root.join("tmp/anchor_builds/#{deployment.id}.pid"))).to be(false)
    end
  end

  describe "#build_status" do
    it "is :success when the built image exists" do
      deployment.update!(build_ref: "anchor-local/x:1")
      runner.stub(/image inspect/, output: "sha256:abc")
      expect(provider.build_status(deployment)).to be_success
      expect(runner.commands.last).to eq([ "docker", "image", "inspect", "--format", "{{.Id}}", "anchor-local/x:1" ])
    end

    it "is :failure when the image is missing" do
      deployment.update!(build_ref: "anchor-local/x:1")
      runner.stub(/image inspect/, output: "No such image", exit_status: 1)
      expect(provider.build_status(deployment)).to be_failure
    end
  end

  describe "#cancel_build!" do
    it "kills the recorded docker build process" do
      path = Rails.root.join("tmp/anchor_builds/#{deployment.id}.pid")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "98765")
      expect(Process).to receive(:kill).with("TERM", 98_765)

      expect(provider.cancel_build!(deployment)).to be(true)
      expect(File.exist?(path)).to be(false)
    end

    it "returns false when no build is running" do
      expect(provider.cancel_build!(deployment)).to be(false)
    end
  end

  describe "#deploy_revision!" do
    before { deployment.update!(image_url: "anchor-local/app:#{deployment.id}") }

    it "runs the image detached on a free localhost port and returns its URL" do
      revision = provider.deploy_revision!(deployment, env: {}, log: log)

      expect(revision).to eq(Providers::Revision.new(name: container, url: "http://localhost:49152"))
      expect(runner.commands.first).to eq([ "docker", "rm", "-f", container ])
      argv = runner.commands.last
      expect(argv.first(3)).to eq(%w[docker run -d])
      expect(argv).to include("--name", container, "-p", "127.0.0.1:49152:8080", "--memory", "1g", "PORT=8080")
      expect(argv.last).to eq("anchor-local/app:#{deployment.id}")
    end

    it "passes secrets by name only; values travel in the process env" do
      provider.deploy_revision!(deployment, env: { "API_KEY" => "s3cr3t" }, log: log)

      call = runner.calls.last
      expect(call.argv.each_cons(2)).to include([ "-e", "API_KEY" ])
      expect(call.line).not_to include("s3cr3t")
      expect(call.env).to eq("API_KEY" => "s3cr3t")
      expect(call.redact).to include("s3cr3t")
    end
  end

  describe "#promote!" do
    it "starts the new container and stops the project's other containers" do
      deployment.update!(revision_name: container, revision_url: "http://localhost:49152")
      runner.stub(/docker ps/, output: "#{container}\nanchor-old-1\n")

      expect(provider.promote!(deployment, log: log)).to eq("http://localhost:49152")
      expect(runner.commands).to include(
        [ "docker", "start", container ],
        [ "docker", "ps", "--filter", "label=anchor.project=#{project.id}", "--format", "{{.Names}}" ],
        [ "docker", "stop", "anchor-old-1" ]
      )
      expect(runner.commands).not_to include([ "docker", "stop", container ])
    end
  end

  describe "#rollback!" do
    it "restarts the older container and returns its published URL" do
      runner.stub(/docker ps/, output: "#{container}\nanchor-old-1\n")
      runner.stub(/docker port/, output: "8080/tcp -> 127.0.0.1:50001\n")

      expect(provider.rollback!(project, "anchor-old-1", log: log)).to eq("http://localhost:50001")
      expect(runner.commands).to include([ "docker", "start", "anchor-old-1" ], [ "docker", "stop", container ])
    end

    it "raises when the old container is gone" do
      runner.stub(/docker start/, output: "Error: No such container: anchor-old-1", exit_status: 1)
      expect { provider.rollback!(project, "anchor-old-1", log: log) }.to raise_error(Providers::Error, /redeploy/)
    end
  end

  describe "#delete_revision!" do
    it "force-removes the container" do
      deployment.update!(revision_name: container)
      expect(provider.delete_revision!(deployment)).to be(true)
      expect(runner.commands.last).to eq([ "docker", "rm", "-f", container ])
    end
  end
end
