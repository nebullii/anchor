require "rails_helper"

# Regressions found in the browser end-to-end run.
RSpec.describe "deployment page live UI", type: :view do
  let(:deployment) { create(:deployment, status: "queued") }

  def steps_html(dep)
    ApplicationController.render(partial: "deployments/pipeline_steps", locals: { deployment: dep })
  end

  it "marks only the steps before the failure as done, not the whole pipeline" do
    deployment.transition_to!("analyzing")
    deployment.transition_to!("building")
    deployment.transition_to!("failed")

    html = steps_html(deployment.reload)
    expect(html.scan("bg-emerald-900").size).to eq(2)   # Queued, Analyze repo
    expect(html.scan("bg-red-950").size).to eq(1)       # Build image
  end

  it "marks every step done once running" do
    deployment.update_columns(status: "running")
    expect(steps_html(deployment).scan("bg-emerald-900").size).to eq(6)
  end

  it "updates (not replaces) the wrappers so later broadcasts still find their targets" do
    targets = []
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) { |_s, **kw| targets << kw[:target] }
    allow(Turbo::StreamsChannel).to receive(:broadcast_remove_to)
    expect(Turbo::StreamsChannel).not_to receive(:broadcast_replace_to)

    deployment.transition_to!("analyzing")

    expect(targets).to include("deployment_#{deployment.id}_status", "deployment_actions",
                               "deployment_pipeline_wrapper", "deployment_outcome")
  end

  it "does not show the AI spinner when no AI provider is configured" do
    deployment.update_columns(status: "failed", finished_at: Time.current, error_message: "boom")
    html = ApplicationController.render(partial: "deployments/outcome", locals: { deployment: deployment })
    expect(html).not_to include("Analyzing failure")
  end
end
