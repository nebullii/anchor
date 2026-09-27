require "rails_helper"

RSpec.describe "GitHub webhooks", type: :request do
  include ActiveJob::TestHelper

  let(:repository) { create(:repository, full_name: "acme/shop") }
  let!(:project)   { create(:project, repository: repository, auto_deploy: true, production_branch: "main") }

  let(:payload) do
    {
      ref: "refs/heads/main",
      repository: { full_name: "acme/shop" },
      head_commit: { id: "abc123", message: "Fix checkout", author: { name: "Ada" } }
    }
  end

  def deliver(body: payload.to_json, event: "push", secret: project.webhook_secret,
              delivery: SecureRandom.uuid, query: nil, signature: :auto, content_type: "application/json")
    headers = {
      "CONTENT_TYPE"      => content_type,
      "X-GitHub-Event"    => event,
      "X-GitHub-Delivery" => delivery
    }
    headers["X-Hub-Signature-256"] =
      signature == :auto ? Security::GithubWebhookSignature.sign(body, secret) : signature
    headers.compact!

    path = query ? "/webhooks/github?#{query}" : "/webhooks/github"
    post path, params: body, headers: headers
  end

  describe "ping" do
    it "acknowledges without a signature" do
      deliver(event: "ping", body: { zen: "Keep it logically awesome." }.to_json, signature: nil)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("ok" => true)
    end
  end

  describe "other events" do
    it "are accepted and ignored" do
      expect { deliver(event: "issues") }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:accepted)
    end
  end

  describe "push with a valid project signature" do
    it "creates a queued deployment and enqueues the job" do
      expect { deliver }.to change(project.deployments, :count).by(1)
                        .and have_enqueued_job(DeploymentJob)

      expect(response).to have_http_status(:ok)
      deployment = project.deployments.last
      expect(deployment).to have_attributes(
        status: "queued", triggered_by: "webhook", branch: "main",
        commit_sha: "abc123", commit_message: "Fix checkout", commit_author: "Ada"
      )
    end

    it "accepts form-encoded deliveries" do
      body = "payload=#{CGI.escape(payload.to_json)}"
      expect {
        deliver(body: body, content_type: "application/x-www-form-urlencoded")
      }.to change(Deployment, :count).by(1)
    end

    it "ignores pushes to other branches" do
      expect {
        deliver(body: payload.merge(ref: "refs/heads/feature").to_json)
      }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:ok)
    end

    it "ignores tag pushes and branch deletions" do
      expect {
        deliver(body: payload.merge(ref: "refs/tags/main").to_json)
        deliver(body: payload.merge(deleted: true).to_json)
      }.not_to change(Deployment, :count)
    end

    it "ignores projects without auto-deploy" do
      project.update!(auto_deploy: false)
      expect { deliver }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:ok)
    end

    it "skips when a deployment is already in progress" do
      create(:deployment, project: project, status: "building")
      expect { deliver }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "signature verification" do
    it "rejects a missing signature" do
      expect { deliver(signature: nil) }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a signature made with the wrong secret" do
      expect { deliver(secret: "not-the-secret") }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a tampered body" do
      signature = Security::GithubWebhookSignature.sign(payload.to_json, project.webhook_secret)
      tampered  = payload.merge(head_commit: { id: "evil" }).to_json
      expect { deliver(body: tampered, signature: signature) }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects the legacy SHA-1 header format" do
      sha1 = "sha1=#{OpenSSL::HMAC.hexdigest('SHA1', project.webhook_secret, payload.to_json)}"
      deliver(signature: sha1)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects pushes for unknown repositories" do
      body = payload.merge(repository: { full_name: "someone/else" }).to_json
      deliver(body: body)
      expect(response).to have_http_status(:unauthorized)
    end

    context "with the global GITHUB_WEBHOOK_SECRET" do
      around do |example|
        original = ENV.to_h.slice("GITHUB_WEBHOOK_SECRET", WebhooksController::GLOBAL_SECRET_FLAG)
        ENV["GITHUB_WEBHOOK_SECRET"] = "global-secret"
        example.run
      ensure
        ENV.delete(WebhooksController::GLOBAL_SECRET_FLAG)
        ENV.delete("GITHUB_WEBHOOK_SECRET")
        original.each { |k, v| ENV[k] = v }
      end

      it "is rejected by default" do
        expect { deliver(secret: "global-secret") }.not_to change(Deployment, :count)
        expect(response).to have_http_status(:unauthorized)
      end

      it "is accepted only when explicitly enabled" do
        ENV[WebhooksController::GLOBAL_SECRET_FLAG] = "true"
        expect { deliver(secret: "global-secret") }.to change(Deployment, :count).by(1)
      end
    end

    context "with ?project=<slug> in the URL" do
      it "deploys when the project's secret signed the body" do
        expect { deliver(query: "project=#{project.slug}") }.to change(Deployment, :count).by(1)
      end

      it "verifies the signature before looking at the body" do
        deliver(query: "project=#{project.slug}", body: "{not json", secret: "wrong")
        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects a payload for a different repository" do
        other = create(:project, repository: create(:repository, full_name: "acme/other"), auto_deploy: true)
        body  = payload.merge(repository: { full_name: "acme/other" }).to_json
        expect {
          deliver(query: "project=#{project.slug}", body: body)
        }.not_to change(other.deployments, :count)
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns 401 for an unknown slug" do
        deliver(query: "project=nope")
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "picks the project whose secret signed the delivery when several share a repo" do
      staging = create(:project, repository: repository, auto_deploy: true, production_branch: "staging")
      body = payload.merge(ref: "refs/heads/staging").to_json

      expect { deliver(body: body, secret: staging.webhook_secret) }
        .to change(staging.deployments, :count).by(1)
        .and change(project.deployments, :count).by(0)
    end
  end

  describe "malformed input" do
    it "returns 400 for invalid JSON" do
      deliver(body: "{not json")
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 400 for a JSON array body" do
      deliver(body: "[1,2,3]")
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 400 for a signed but invalid body on the per-project URL" do
      deliver(query: "project=#{project.slug}", body: "{not json")
      expect(response).to have_http_status(:bad_request)
    end

    it "tolerates unexpected field types" do
      body = payload.merge(head_commit: "oops").to_json
      expect { deliver(body: body) }.to change(Deployment, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    it "returns 413 for oversized payloads" do
      stub_const("WebhooksController::MAX_PAYLOAD_BYTES", 10)
      deliver
      expect(response).to have_http_status(:content_too_large)
    end
  end

  describe "redelivery (X-GitHub-Delivery)" do
    it "creates only one deployment per delivery id" do
      delivery = SecureRandom.uuid
      deliver(delivery: delivery)
      project.deployments.update_all(status: "running") # finished, so a new one would be allowed

      expect { deliver(delivery: delivery) }.not_to change(Deployment, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("duplicate" => true)
    end

    it "treats different delivery ids independently" do
      deliver
      project.deployments.update_all(status: "running")
      expect { deliver }.to change(Deployment, :count).by(1)
    end

    it "does not record deliveries that fail verification" do
      delivery = SecureRandom.uuid
      deliver(delivery: delivery, secret: "wrong")
      expect(WebhookDelivery.where(delivery_id: delivery)).to be_empty

      expect { deliver(delivery: delivery) }.to change(Deployment, :count).by(1)
    end
  end
end
