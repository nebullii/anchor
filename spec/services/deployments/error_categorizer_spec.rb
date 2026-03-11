require "rails_helper"

RSpec.describe Deployments::ErrorCategorizer do
  describe ".categorize" do
    {
      "PERMISSION_DENIED: caller does not have permission"  => "auth_error",
      "Error: quota exceeded for quota metric"              => "quota_exceeded",
      "manifest unknown: image not found in registry"       => "image_not_found",
      "ERROR: build exceeded deadline"                      => "build_timeout",
      "RUN npm install returned exit code 1"                => "dockerfile_error",
      "OOM: container killed"                               => "oom_killed",
      "GCP service account not configured"                  => "gcp_not_configured",
      "Repository is too large to deploy (600 MB)"          => "repo_too_large",
      "git clone failed: authentication failed"             => "git_clone_error",
      "some totally unrecognized error message"             => "unknown"
    }.each do |message, expected_category|
      it "categorizes '#{message.truncate(60)}' as '#{expected_category}'" do
        expect(described_class.categorize(message)).to eq(expected_category)
      end
    end

    it "returns 'unknown' for blank messages" do
      expect(described_class.categorize(nil)).to eq("unknown")
      expect(described_class.categorize("")).to eq("unknown")
    end
  end

  describe ".user_hint" do
    it "returns a hint for known categories" do
      hint = described_class.user_hint("auth_error")
      expect(hint).to include("service account")
    end

    it "returns a fallback hint for unknown categories" do
      hint = described_class.user_hint("unknown")
      expect(hint).to be_present
    end
  end
end
