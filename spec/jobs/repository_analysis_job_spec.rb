require "rails_helper"

RSpec.describe RepositoryAnalysisJob, type: :job do
  let(:user)       { create(:user) }
  let(:repository) { create(:repository, user: user) }
  let(:project)    { create(:project, user: user, repository: repository) }
  let(:repo_path)  { Dir.mktmpdir }

  # Stub the git clone so we never hit the network,
  # and populate a real temp directory for the analyzer to inspect.
  before do
    allow_any_instance_of(described_class).to receive(:clone_repo) do |_job, _repository, _project, path|
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "requirements.txt"), "fastapi\nuvicorn\npsycopg2-binary\n")
      File.write(File.join(path, "main.py"), "import os\nkey = os.getenv('OPENAI_API_KEY')")
    end

    # Skip AI enrichment — those calls are tested in spec/services/ai/.
    allow_any_instance_of(described_class).to receive(:enrich_with_ai) { |_job, hash, _path| hash }
  end

  describe "#perform" do
    it "transitions project analysis_status to analyzing then complete" do
      described_class.new.perform(project.id)
      expect(project.reload.analysis_status).to eq("complete")
    end

    it "persists analysis_result as a hash" do
      described_class.new.perform(project.id)
      result = project.reload.analysis_result
      expect(result).to be_a(Hash)
      expect(result["framework"]).to eq("fastapi")
    end

    it "sets analyzed_at timestamp" do
      described_class.new.perform(project.id)
      expect(project.reload.analyzed_at).to be_within(5.seconds).of(Time.current)
    end

    it "detects env vars in analysis_result" do
      described_class.new.perform(project.id)
      keys = project.reload.analysis_result["detected_env_vars"].map { |v| v["key"] }
      expect(keys).to include("OPENAI_API_KEY")
    end

    it "detects database in analysis_result" do
      described_class.new.perform(project.id)
      db = project.reload.analysis_result["detected_database"]
      expect(db["adapter"]).to eq("postgresql")
    end

    it "is a no-op for a non-existent project_id" do
      expect { described_class.new.perform(0) }.not_to raise_error
    end

    context "when clone fails" do
      before do
        allow_any_instance_of(described_class).to receive(:clone_repo)
          .and_raise(RuntimeError, "git clone failed: not found")
      end

      it "marks analysis_status as failed" do
        described_class.new.perform(project.id)
        expect(project.reload.analysis_status).to eq("failed")
      end

      it "does not raise an unhandled error" do
        expect { described_class.new.perform(project.id) }.not_to raise_error
      end
    end

    context "when analyzer raises an unexpected error" do
      before do
        allow(RepositoryAnalyzer).to receive(:new).and_raise(StandardError, "unexpected")
      end

      it "marks analysis_status as failed" do
        described_class.new.perform(project.id)
        expect(project.reload.analysis_status).to eq("failed")
      end
    end

    it "cleans up the temp directory after completion" do
      captured_path = nil
      allow_any_instance_of(described_class).to receive(:clone_repo) do |_job, _repo, _proj, path|
        captured_path = path
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "requirements.txt"), "fastapi")
      end

      described_class.new.perform(project.id)
      expect(File.exist?(captured_path)).to be false
    end

    it "cleans up the temp directory even when analysis fails" do
      captured_path = nil
      allow_any_instance_of(described_class).to receive(:clone_repo) do |_job, _repo, _proj, path|
        captured_path = path
        FileUtils.mkdir_p(path)
      end
      allow(RepositoryAnalyzer).to receive(:new).and_raise(StandardError, "boom")

      described_class.new.perform(project.id)
      expect(File.exist?(captured_path)).to be false
    end
  end

  describe "enqueuing" do
    it "is enqueued on the default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end

    it "can be enqueued with perform_later" do
      expect {
        described_class.perform_later(project.id)
      }.to have_enqueued_job(described_class).with(project.id)
    end
  end
end
