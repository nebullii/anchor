require "rails_helper"

RSpec.describe Ai::ErrorExplainer do
  let(:project)    { create(:project) }
  let(:deployment) do
    create(:deployment, :failed,
      project:       project,
      error_message: "Cloud Build failed: Dockerfile not found")
  end

  subject(:explainer) { described_class.new(deployment) }

  describe "#call" do
    context "when ANTHROPIC_API_KEY is not set" do
      before { stub_const("ENV", ENV.to_h.merge("ANTHROPIC_API_KEY" => nil)) }

      it "returns nil" do
        expect(explainer.call).to be_nil
      end
    end

    context "when ANTHROPIC_API_KEY is set" do
      before { stub_const("ENV", ENV.to_h.merge("ANTHROPIC_API_KEY" => "sk-test-key")) }

      context "when the API returns a successful explanation" do
        let(:explanation) { "The Dockerfile is missing from the repository root. Create one or let Anchor generate it by re-running the analysis." }

        before do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 200,
              body: {
                "content" => [{ "type" => "text", "text" => explanation }]
              }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "returns the explanation text" do
          expect(explainer.call).to eq(explanation)
        end
      end

      context "when the API returns a blank response" do
        before do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(
              status: 200,
              body: { "content" => [{ "type" => "text", "text" => "   " }] }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "returns nil" do
          expect(explainer.call).to be_nil
        end
      end

      context "when the API returns an error status" do
        before do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_return(status: 429, body: "Rate limited")
        end

        it "returns nil without raising" do
          expect { explainer.call }.not_to raise_error
          expect(explainer.call).to be_nil
        end
      end

      context "when the API connection times out" do
        before do
          stub_request(:post, "https://api.anthropic.com/v1/messages")
            .to_timeout
        end

        it "returns nil without raising" do
          expect { explainer.call }.not_to raise_error
          expect(explainer.call).to be_nil
        end
      end

      it "includes the error message in the request body" do
        stub = stub_request(:post, "https://api.anthropic.com/v1/messages")
          .with { |req| JSON.parse(req.body).dig("messages", 0, "content").include?("Dockerfile not found") }
          .to_return(
            status: 200,
            body: { "content" => [{ "type" => "text", "text" => "Some explanation" }] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        explainer.call
        expect(stub).to have_been_requested
      end

      it "includes the framework in the request body" do
        project.update_columns(framework: "rails")
        stub = stub_request(:post, "https://api.anthropic.com/v1/messages")
          .with { |req| JSON.parse(req.body).dig("messages", 0, "content").include?("rails") }
          .to_return(
            status: 200,
            body: { "content" => [{ "type" => "text", "text" => "Some explanation" }] }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        explainer.call
        expect(stub).to have_been_requested
      end
    end
  end
end
