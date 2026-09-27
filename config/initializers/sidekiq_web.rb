require "sidekiq/web"

# Sidekiq Web UI, mounted at /sidekiq in config/routes.rb behind
# Anchor::SidekiqAdminConstraint.
#
# Access is limited to signed-in users whose GitHub login appears in
# ANCHOR_ADMIN_GITHUB_LOGINS (comma-separated, case-insensitive), e.g.
#
#   ANCHOR_ADMIN_GITHUB_LOGINS=alice,bob
#
# When the variable is unset or empty nobody gets in (the route 404s), so the
# dashboard is closed by default in every environment.
module Anchor
  class SidekiqAdminConstraint
    def self.admin_logins
      ENV.fetch("ANCHOR_ADMIN_GITHUB_LOGINS", "").split(",").map { |l| l.strip.downcase }.reject(&:empty?)
    end

    def self.matches?(request)
      logins = admin_logins
      return false if logins.empty?

      user_id = request.session[:user_id]
      return false if user_id.blank?

      login = User.where(id: user_id).pick(:github_login)
      login.present? && logins.include?(login.downcase)
    end
  end
end
