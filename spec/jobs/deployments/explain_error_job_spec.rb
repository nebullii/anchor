require "rails_helper"

RSpec.describe Deployments::ExplainErrorJob, type: :job do
  let(:project)    { create(:project) }
  let(:deployment) { create(:deployment, :failed, project: project, error_message: "Build failed") }

  describe "#perform" do
    context "when ANTHROPIC_API_KEY is not set" do
      before { stub_const("ENV", ENV.to_h.merge("ANTHROPIC_API_KEY" => nil)) }

      it "does not update the deployment" do
        expect {
          described_class.new.perform(deployment.id)
        }.not_to change { deployment.reload.ai_error_explanation }
      end
    end

    context "when ANTHROPIC_API_KEY is set" do
      let(:explanation) { "The build failed because the Gemfile.lock is missing." }

      before do
        stub_const("ENV", ENV.to_h.merge("ANTHROPIC_API_KEY" => "sk-test-key"))
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: { "content" => [{ "type" => "text", "text" => explanation }] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "stores the AI explanation on the deployment" do
        described_class.new.perform(deployment.id)
        expect(deployment.reload.ai_error_explanation).to eq(explanation)
      end

      it "broadcasts a Turbo Stream update to the deployment outcome" do
        expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
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
