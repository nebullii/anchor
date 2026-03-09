require "rails_helper"

RSpec.describe FrameworkDetector do
  let(:project) { create(:project) }
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  subject { described_class.new(repo_path, project) }

  def touch(filename)
    FileUtils.touch(File.join(repo_path, filename))
  end

  def write(filename, content)
    File.write(File.join(repo_path, filename), content)
  end

  describe "#call" do
    it "detects docker when Dockerfile exists" do
      touch("Dockerfile")
      result = subject.call
      expect(result.framework).to eq("docker")
    end

    it "detects rails when Gemfile contains rails" do
      write("Gemfile", 'gem "rails", "~> 8.0"')
      result = subject.call
      expect(result.framework).to eq("rails")
      expect(result.port).to eq(3000)
    end

    it "detects node when package.json exists" do
      write("package.json", "{}")
      result = subject.call
      expect(result.framework).to eq("node")
    end

    it "detects python when requirements.txt exists" do
      touch("requirements.txt")
      result = subject.call
      expect(result.framework).to eq("python")
    end

    it "detects static when index.html exists" do
      touch("index.html")
      result = subject.call
      expect(result.framework).to eq("static")
    end

    it "falls back to static when nothing detected" do
      result = subject.call
      expect(result.framework).to eq("static")
    end

    it "prefers docker over rails when both exist" do
      touch("Dockerfile")
      write("Gemfile", 'gem "rails"')
      result = subject.call
      expect(result.framework).to eq("docker")
    end

    it "persists framework onto the project" do
      touch("Dockerfile")
      subject.call
      expect(project.reload.framework).to eq("docker")
    end

    it "returns a Result struct with framework, runtime, port" do
      touch("index.html")
      result = subject.call
      expect(result).to respond_to(:framework, :runtime, :port)
    end
  end
end
