require "rails_helper"

# Real multi-connection races. Transactional tests would hide them (every
# thread would need the same connection), so this group commits for real and
# cleans up after itself.
RSpec.describe "Deployment concurrency", type: :model do
  self.use_transactional_tests = false

  let!(:user)    { create(:user) }
  let!(:project) { create(:project, user: user, repository: create(:repository, user: user)) }

  after do
    ids = Deployment.where(project_id: project.id).pluck(:id)
    DeploymentEvent.where(deployment_id: ids).delete_all
    DeploymentLog.where(deployment_id: ids).delete_all
    Deployment.where(id: ids).delete_all
    repository_id = project.repository_id
    Project.where(id: project.id).delete_all
    Repository.where(id: repository_id).delete_all
    User.where(id: user.id).delete_all
  end

  # Runs +count+ threads that start together, each with its own DB connection.
  def race(count)
    gate = Queue.new
    threads = Array.new(count) do |i|
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection { yield i }
      end
    end
    count.times { gate << true }
    threads.map(&:value)
  end

  it "never lets concurrent requests exceed the daily quota" do
    User.where(id: user.id).update_all(deployments_today: User::DAILY_DEPLOY_LIMIT - 2,
                                       quota_reset_at: 1.hour.from_now)

    results = race(8) { User.find(user.id).consume_deploy_quota! }

    expect(results.count(true)).to eq(2)
    expect(user.reload.deployments_today).to eq(User::DAILY_DEPLOY_LIMIT)
  end

  it "serialises a cancel racing a job transition — exactly one wins" do
    deployment = create(:deployment, :building, project: project)

    results = race(2) do |i|
      d = Deployment.find(deployment.id)
      begin
        i.zero? ? d.cancel! : d.transition_to!("deploying")
        :ok
      rescue Deployment::InvalidTransition
        :rejected
      end
    end

    final = deployment.reload.status
    events = deployment.deployment_events.for_type("status_changed").pluck(:to_status)

    if final == "cancelled"
      # Either cancel won outright, or deploying won and cancel followed legally.
      expect(events.last).to eq("cancelled")
    else
      expect(final).to eq("deploying")
      expect(results).to include(:rejected)
    end
    # The row lock means no status was ever written twice from a stale read.
    expect(events.uniq).to eq(events)
  end

  it "allows only one in-progress deployment per project under a race" do
    results = race(5) do
      Deployment.create!(project_id: project.id, status: "queued", triggered_by: "manual")
      :created
    rescue ActiveRecord::RecordNotUnique
      :duplicate
    end

    expect(results.count(:created)).to eq(1)
    expect(Deployment.where(project_id: project.id).in_progress.count).to eq(1)
  end
end
