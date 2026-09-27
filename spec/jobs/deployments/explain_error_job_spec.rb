require "rails_helper"

RSpec.describe Deployments::ExplainErrorJob, type: :job do
  let(:project)    { create(:project) }
  let(:deployment) { create(:deployment, :failed, project: project, error_message: "Build failed") }

  let(:structured) do
    {
      "summary"      => "The build failed because the Gemfile.lock is missing.",
      "likely_cause" => "Gemfile.lock is not committed.",
      "fix_steps"    => ["Run bundle install", "Commit Gemfile.lock"],
      "confidence"   => "high",
      "category"     => "build_error"
    }
  end

  describe "#perform" do
    context "when no AI provider is configured" do
      it "does not update the deployment" do
        expect {
          described_class.new.perform(deployment.id)
        }.not_to change { deployment.reload.ai_error_explanation }
      end
    end

    context "when an AI provider is configured" do
      before do
        enable_anthropic!
        stub_anthropic(structured.to_json)
      end

      it "stores a readable explanation on the deployment" do
        described_class.new.perform(deployment.id)
        text = deployment.reload.ai_error_explanation
        expect(text).to start_with("The build failed because the Gemfile.lock is missing.")
        expect(text).to include("Fix: 1. Run bundle install 2. Commit Gemfile.lock")
      end

      it "stores structured + raw output when the ai_error_details column exists" do
        allow(Deployment).to receive(:column_names).and_return(Deployment.column_names + ["ai_error_details"])
        allow_any_instance_of(Deployment).to receive(:update_columns) do |_record, attrs|
          expect(attrs[:ai_error_details]).to include("structured" => true, "category" => "build_error",
                                                      "raw" => structured.to_json)
        end
        described_class.new.perform(deployment.id)
      end

      it "stores plain text when the model ignores the JSON format" do
        stub_anthropic("Commit your Gemfile.lock.")
        described_class.new.perform(deployment.id)
        expect(deployment.reload.ai_error_explanation).to eq("Commit your Gemfile.lock.")
      end

      it "broadcasts a Turbo Stream update to the deployment outcome" do
        expect(Turbo::StreamsChannel).to receive(:broadcast_update_to)
          .with("deployment_#{deployment.id}", hash_including(target: "deployment_outcome"))
        described_class.new.perform(deployment.id)
      end

      context "when the deployment is not in failed state" do
        let(:deployment) { create(:deployment, project: project, status: "success") }

        it "does nothing" do
          described_class.new.perform(deployment.id)
          expect(deployment.reload.ai_error_explanation).to be_nil
        end
      end

      context "when the deployment does not exist" do
        it "returns without raising" do
          expect { described_class.new.perform(0) }.not_to raise_error
        end
      end
    end
  end
end
