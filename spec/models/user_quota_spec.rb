require "rails_helper"

RSpec.describe User, "deploy quota", type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  describe "#consume_deploy_quota!" do
    it "reserves a slot and increments both counters" do
      expect(user.consume_deploy_quota!).to be true
      user.reload
      expect(user.deployments_today).to eq(1)
      expect(user.deployments_this_month).to eq(1)
    end

    it "refuses once the daily limit is reached" do
      user.update_columns(deployments_today: User::DAILY_DEPLOY_LIMIT, quota_reset_at: 1.hour.from_now)
      expect(user.consume_deploy_quota!).to be false
      expect(user.reload.deployments_today).to eq(User::DAILY_DEPLOY_LIMIT)
    end

    it "refuses once the monthly limit is reached" do
      user.update_columns(deployments_this_month: User::MONTHLY_DEPLOY_LIMIT, quota_reset_at: 1.hour.from_now)
      expect(user.consume_deploy_quota!).to be false
    end

    it "does not trust stale in-memory counters" do
      stale = User.find(user.id)
      User.where(id: user.id).update_all(deployments_today: User::DAILY_DEPLOY_LIMIT, quota_reset_at: 1.hour.from_now)
      expect(stale.consume_deploy_quota!).to be false
    end

    it "keeps increment_deploy_quota! working for existing callers" do
      user.increment_deploy_quota!
      expect(user.reload.deployments_today).to eq(1)
    end
  end

  describe "#release_deploy_quota!" do
    it "gives a slot back but never goes negative" do
      user.consume_deploy_quota!
      user.release_deploy_quota!
      user.release_deploy_quota!
      expect(user.reload.deployments_today).to eq(0)
      expect(user.deployments_this_month).to eq(0)
    end
  end

  describe "resets" do
    it "resets the daily counter after midnight but keeps the monthly one within a month" do
      travel_to Time.zone.local(2026, 5, 10, 12) do
        user.update_columns(deployments_today: 20, deployments_this_month: 50,
                            quota_reset_at: Time.zone.local(2026, 5, 10))
        expect(user.within_deploy_quota?).to be true
        expect(user.deployments_today).to eq(0)
        expect(user.deployments_this_month).to eq(50)
      end
    end

    it "resets the monthly counter even if the user did not deploy on the 1st" do
      travel_to Time.zone.local(2026, 6, 5, 12) do
        # Last reset happened on May 20 → quota_reset_at is midnight May 21.
        user.update_columns(deployments_today: 3, deployments_this_month: User::MONTHLY_DEPLOY_LIMIT,
                            quota_reset_at: Time.zone.local(2026, 5, 21))
        expect(user.consume_deploy_quota!).to be true
        expect(user.reload.deployments_this_month).to eq(1)
        expect(user.quota_reset_at).to eq(Time.zone.local(2026, 6, 6))
      end
    end
  end
end
