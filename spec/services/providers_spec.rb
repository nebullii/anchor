require "rails_helper"

RSpec.describe Providers do
  describe ".for" do
    it "defaults to Cloud Run" do
      expect(described_class.for(build(:project))).to be_a(Providers::GcpCloudRun)
    end

    it "returns the local docker provider when configured" do
      expect(described_class.for(build(:project, provider: "local_docker"))).to be_a(Providers::LocalDocker)
    end

    it "forwards an injected runner" do
      runner = FakeCommandRunner.new
      expect(described_class.for(build(:project), runner: runner).runner).to be(runner)
    end

    it "raises for unknown providers" do
      expect { described_class.for(build(:project, provider: "heroku")) }.to raise_error(Providers::Error, /Unknown provider/)
    end
  end

  describe ".translate_errors" do
    it "maps TransientError to Deployments::TransientError" do
      expect { described_class.translate_errors { raise Providers::TransientError, "503" } }
        .to raise_error(Deployments::TransientError, "503")
    end

    it "maps Error to Deployments::DeploymentError" do
      expect { described_class.translate_errors { raise Providers::Error, "bad" } }
        .to raise_error(an_instance_of(Deployments::DeploymentError).and(having_attributes(message: "bad")))
    end

    it "returns the block value" do
      expect(described_class.translate_errors { :ok }).to eq(:ok)
    end
  end
end

RSpec.describe Providers::BuildStatus do
  it "exposes predicates" do
    expect(described_class.new(state: :pending)).to be_pending
    expect(described_class.new(state: "success")).to be_success
    expect(described_class.new(state: :failure, detail: "x")).to be_failure
  end

  it "rejects unknown states" do
    expect { described_class.new(state: :weird) }.to raise_error(ArgumentError)
  end
end

RSpec.describe Providers::CommandRunner do
  subject(:runner) { described_class.new }

  it "runs argv without a shell, streams lines and redacts secrets" do
    lines  = []
    result = runner.call([ "ruby", "-e", "puts 'hello s3cr3t'; puts ENV['X']" ],
                         env: { "X" => "from-env" }, log: ->(l) { lines << l }, redact: [ "s3cr3t" ])

    expect(result).to be_success
    expect(lines).to eq([ "hello [REDACTED]", "from-env" ])
  end

  it "does not interpret shell metacharacters" do
    result = runner.call([ "echo", "a; rm -rf /" ])
    expect(result.output).to eq("a; rm -rf /")
  end

  it "reports non-zero exits and missing binaries" do
    expect(runner.call([ "ruby", "-e", "exit 3" ]).exit_status).to eq(3)
    expect(runner.call([ "definitely-not-a-binary-xyz" ]).exit_status).to eq(127)
  end

  it "reports the child pid via on_spawn" do
    pid = nil
    runner.call([ "ruby", "-e", "1" ], on_spawn: ->(p) { pid = p })
    expect(pid).to be_a(Integer)
  end
end
