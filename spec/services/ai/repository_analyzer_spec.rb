require "rails_helper"

RSpec.describe Ai::RepositoryAnalyzer do
  let(:base_result) do
    {
      "framework"       => "rails",
      "runtime"         => "ruby:3.3",
      "port"            => 3000,
      "detected_env_vars" => [{ "key" => "STRIPE_SECRET_KEY", "required" => true, "source" => "stripe" }],
      "warnings"        => ["Missing Dockerfile"],
      "confidence"      => "medium"
    }
  end

  subject(:analyzer) { described_class.new(base_result, file_tree: ["app/models/user.rb"], readme: "A web app") }

  describe "#call" do
    context "when OPENAI_API_KEY is not set" do
      before { stub_const("ENV", ENV.to_h.merge("OPENAI_API_KEY" => nil)) }

      it "returns the original analysis result unchanged" do
        expect(analyzer.call).to eq(base_result)
      end
    end

    context "when OPENAI_API_KEY is set" do
      before { stub_const("ENV", ENV.to_h.merge("OPENAI_API_KEY" => "sk-test-key")) }

      context "when the API returns a successful enrichment" do
        let(:api_response) do
          {
            "app_description"     => "A Rails e-commerce app",
            "confidence"          => "high",
            "framework_notes"     => "Standard Rails with ActiveRecord",
            "additional_env_vars" => [
              { "key" => "SENDGRID_API_KEY", "required" => true, "source" => "sendgrid", "description" => "Email delivery" }
            ],
            "warnings" => ["Consider adding a health check endpoint"]
          }
        end

        before do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              body: {
                "choices" => [{ "message" => { "content" => api_response.to_json } }]
              }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "merges app_description into the result" do
          expect(analyzer.call["app_description"]).to eq("A Rails e-commerce app")
        end

        it "merges ai_confidence from the API response" do
          expect(analyzer.call["ai_confidence"]).to eq("high")
        end

        it "merges framework_notes into the result" do
          expect(analyzer.call["framework_notes"]).to eq("Standard Rails with ActiveRecord")
        end

        it "appends additional_env_vars without duplicating existing keys" do
          result = analyzer.call
          keys = result["env_vars"].map { |v| v["key"] }
          expect(keys).to include("SENDGRID_API_KEY")
          expect(keys.count("STRIPE_SECRET_KEY")).to eq(0) # moved to detected_env_vars, not env_vars
        end

        it "merges additional warnings without duplicating" do
          result = analyzer.call
          expect(result["warnings"]).to include("Missing Dockerfile")
          expect(result["warnings"]).to include("Consider adding a health check endpoint")
          expect(result["warnings"].uniq.length).to eq(result["warnings"].length)
        end

        it "preserves all original result keys" do
          result = analyzer.call
          expect(result["framework"]).to eq("rails")
          expect(result["runtime"]).to eq("ruby:3.3")
          expect(result["port"]).to eq(3000)
        end
      end

      context "when the API returns an error" do
        before do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(status: 500, body: "Internal Server Error")
        end

        it "returns the original result unchanged" do
          expect(analyzer.call).to eq(base_result)
        end
      end

      context "when the API times out" do
        before do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_timeout
        end

        it "returns the original result without raising" do
          expect { analyzer.call }.not_to raise_error
          expect(analyzer.call).to eq(base_result)
        end
      end

      context "when the API returns malformed JSON" do
        before do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              body: { "choices" => [{ "message" => { "content" => "not json at all" } }] }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "returns the original result unchanged" do
          expect(analyzer.call).to eq(base_result)
        end
      end

      context "when the API wraps JSON in prose" do
        before do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              body: {
                "choices" => [{ "message" => { "content" => 'Here is my analysis: {"app_description":"A simple app"}' } }]
              }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "extracts the JSON object from the prose response" do
          expect(analyzer.call["app_description"]).to eq("A simple app")
        end
      end

      context "when additional_env_vars contains a key already in detected_env_vars" do
        let(:api_response) do
          {
            "additional_env_vars" => [
              { "key" => "STRIPE_SECRET_KEY", "required" => true }  # already in base_result
            ]
          }
        end

        before do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              body: { "choices" => [{ "message" => { "content" => api_response.to_json } }] }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "does not duplicate the key in env_vars" do
          result = analyzer.call
          all_keys = (result["env_vars"] || []).map { |v| v["key"] }
          # STRIPE_SECRET_KEY is already in detected_env_vars, not in env_vars, so it won't be duplicated
          expect(all_keys.count("STRIPE_SECRET_KEY")).to eq(0)
        end
      end
    end
  end
end
