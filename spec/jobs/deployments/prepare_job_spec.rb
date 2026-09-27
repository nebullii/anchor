require "rails_helper"
require "open3"

# Clones a real throwaway git repo from disk (no network); the provider is a
# LocalDocker instance wired to FakeCommandRunner so nothing is built.
RSpec.describe Deployments::PrepareJob, type: :job do
  include ActiveJob::TestHelper

  let(:runner)     { FakeCommandRunner.new }
  let(:project)    { create(:project, provider: "local_docker", gcp_project_id: nil) }
  let(:deployment) { create(:deployment, project: project, status: "queued") }
  let(:provider)   { Providers::LocalDocker.new(project, runner: runner, port_allocator: -> { 49_152 }) }
  let!(:source)    { make_repo }

  def git!(*args, chdir:)
    out, status = Open3.capture2e("git", "-c", "user.email=t@example.com", "-c", "user.name=Tester", *args, chdir: chdir)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
    out
  end

  def make_repo(branch: "main")
    dir = Dir.mktmpdir("anchor-spec-src-")
    File.write(File.join(dir, "index.html"), "<h1>hi</h1>")
    git!("init", "-q", "-b", branch, chdir: dir)
    git!("add", ".", chdir: dir)
    git!("commit", "-q", "-m", "Initial page", chdir: dir)
    dir
  end

  before do
    allow(Providers).to receive(:for).and_return(provider)
    allow_any_instance_of(Repository).to receive(:authenticated_clone_url).and_return(source)
  end

  after { FileUtils.rm_rf(source) }

  it "clones, detects, generates a Dockerfile, builds via the provider and enqueues polling" do
    built_from = nil
    allow(provider).to receive(:build!).and_wrap_original do |orig, dep, dir, **kw|
      built_from = dir
      expect(File.exist?(File.join(dir, "Dockerfile"))).to be(true)
      orig.call(dep, dir, **kw)
    end

    described_class.perform_now(deployment.id)
    deployment.reload

    expect(deployment.status).to eq("building")
    expect(deployment.commit_message).to eq("Initial page")
    expect(deployment.commit_sha).to be_present
    expect(deployment.build_ref).to eq("anchor-local/#{project.service_name}:#{deployment.id}")
    expect(runner.lines).to include(a_string_starting_with("docker version"), a_string_starting_with("docker build"))
    expect(Deployments::PollBuildStatusJob).to have_been_enqueued.with(deployment.id, attempt: 1)
    expect(Deployments::BuildImageJob).not_to have_been_enqueued
    expect(Dir.exist?(built_from)).to be(false), "tmp checkout must be removed in the same job"
  end

  it "strips .git (and the tokened remote in .git/config) from the build context" do
    had_git = nil
    allow(provider).to receive(:build!) do |_dep, dir, **|
      had_git = Dir.exist?(File.join(dir, ".git"))
      "ref-1"
    end

    described_class.perform_now(deployment.id)

    expect(had_git).to be(false)
  end

  it "resumes after a transient failure instead of skipping the retry" do
    calls = 0
    allow(provider).to receive(:build!) do
      calls += 1
      raise Providers::TransientError, "503" if calls == 1
      "ref-2"
    end

    described_class.perform_now(deployment.id)
    expect(deployment.reload.status).to eq("building")
    expect(deployment.build_ref).to be_blank

    described_class.perform_now(deployment.id)
    expect(deployment.reload.build_ref).to eq("ref-2")
  end

  it "blocks the deploy before building when preflight finds an error" do
    File.write(File.join(source, "server.js"), "require('http').createServer(()=>{}).listen(3000, '127.0.0.1')\n")
    File.write(File.join(source, "package.json"), '{"name":"app","scripts":{"start":"node server.js"}}')
    git!("add", ".", chdir: source)
    git!("commit", "-q", "-m", "Bind to localhost", chdir: source)
    expect(provider).not_to receive(:build!)

    described_class.perform_now(deployment.id)

    expect(deployment.reload.status).to eq("failed")
    expect(deployment.error_message).to include("Preflight")
  end

  it "removes the tmp checkout even when the build fails" do
    built_from = nil
    runner.stub(/docker build/, output: "ERROR: failed to solve", exit_status: 1)
    allow(provider).to receive(:build!).and_wrap_original do |orig, dep, dir, **kw|
      built_from = dir
      orig.call(dep, dir, **kw)
    end

    described_class.perform_now(deployment.id)

    expect(deployment.reload.status).to eq("failed")
    expect(deployment.error_message).to include("failed to solve")
    expect(Dir.exist?(built_from)).to be(false)
    expect(Deployments::PollBuildStatusJob).not_to have_been_enqueued
  end

  it "fails the deployment when provisioning fails" do
    runner.stub(/docker version/, output: "Cannot connect to the Docker daemon", exit_status: 1)

    described_class.perform_now(deployment.id)

    expect(deployment.reload.status).to eq("failed")
    expect(deployment.error_message).to include("Docker daemon is not reachable")
  end

  it "schedules a retry on transient provider errors" do
    allow(provider).to receive(:provision!).and_raise(Providers::TransientError, "503 from API")
    expect { described_class.perform_now(deployment.id) }.to have_enqueued_job(described_class)
    expect(deployment.reload.status).not_to eq("failed")
  end

  it "skips deployments that are no longer queued" do
    deployment.update!(status: "cancelled")
    described_class.perform_now(deployment.id)
    expect(runner.calls).to be_empty
  end

  context "when the branch does not exist and the clone URL carries a token" do
    let(:tokened) { "https://user:ghp_SUPERSECRET@github.invalid/acme/app.git" }

    it "never leaks the token in the failure message" do
      allow_any_instance_of(Repository).to receive(:authenticated_clone_url).and_return(tokened)
      # git echoes the remote URL back in its errors; simulate that without touching the network.
      failed = instance_double(Process::Status, success?: false, exitstatus: 128)
      allow(Open3).to receive(:capture2e).and_call_original
      allow(Open3).to receive(:capture2e).with("git", "clone", any_args)
        .and_return([ "Cloning into '#{tokened}'...\nfatal: Remote branch main not found in upstream origin", failed ])
      allow(Open3).to receive(:capture2e).with("git", "ls-remote", any_args)
        .and_return([ "fatal: could not read from '#{tokened}'", failed ])

      described_class.perform_now(deployment.id)

      deployment.reload
      expect(deployment.status).to eq("failed")
      expect(deployment.error_message).not_to include("ghp_SUPERSECRET")
      expect(deployment.deployment_logs.pluck(:message).join("\n")).not_to include("ghp_SUPERSECRET")
    end
  end

  describe "#detect_default_branch" do
    it "redacts the tokened URL from anything it logs" do
      tokened = "https://user:ghp_SUPERSECRET@github.invalid/acme/app.git"
      failure = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture2e).and_return([ "fatal: unable to access '#{tokened}/': Could not resolve host", failure ])

      logged = []
      allow(Rails.logger).to receive(:warn) { |msg| logged << msg }

      expect(described_class.new.send(:detect_default_branch, tokened)).to be_nil
      expect(logged.join).not_to include("ghp_SUPERSECRET")
      expect(logged.join).to include("[REDACTED]")
    end

    it "falls back to the remote's real default branch" do
      other = make_repo(branch: "trunk")
      allow_any_instance_of(Repository).to receive(:authenticated_clone_url).and_return(other)

      described_class.perform_now(deployment.id)

      expect(deployment.reload.branch).to eq("trunk")
      expect(project.reload.production_branch).to eq("trunk")
    ensure
      FileUtils.rm_rf(other)
    end
  end
end
