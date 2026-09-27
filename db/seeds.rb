# Development seed data: a demo user and a demo project that deploys a tiny
# public sample app to the Local Docker provider — no GitHub OAuth app and no
# cloud account needed. Sign in as the demo user with ANCHOR_DEV_LOGIN=1.
#
# Idempotent: re-running updates the same rows instead of duplicating them.
# Never runs in production (demo users must not exist there).

return if Rails.env.production?

module DemoSeed
  module_function

  # Must match DashboardController::DEV_LOGIN_GITHUB_ID (the dev login).
  def user_github_id = "anchor-demo"

  # Tiny public repo (busybox httpd + one HTML file, honours $PORT): builds in
  # a few seconds. Swap in your own public repo by editing the Repository row.
  def sample_repo
    {
      github_id:      "anchor-demo-sample",
      name:           "docker-hello-world",
      full_name:      "crccheck/docker-hello-world",
      owner_login:    "crccheck",
      description:    "Tiny public sample app used by the Anchor local demo",
      default_branch: "master",
      clone_url:      "https://github.com/crccheck/docker-hello-world.git",
      html_url:       "https://github.com/crccheck/docker-hello-world",
      private:        false,
      language:       "Dockerfile"
    }
  end

  def user
    User.find_or_initialize_by(github_id: user_github_id).tap do |u|
      u.assign_attributes(
        github_login: "demo",
        name:         "Demo User",
        email:        "demo@anchor.local",
        # No real token: the sample repo is public, and GitHub serves public
        # repos even when the clone URL carries an empty password.
        github_token: ""
      )
      u.save!
    end
  end

  def repository(owner)
    Repository.find_or_initialize_by(github_id: sample_repo[:github_id]).tap do |r|
      r.assign_attributes(sample_repo.merge(user: owner, last_synced_at: Time.current))
      r.save!
    end
  end

  # Provider columns land with the Platform migration; until then the project
  # is created without them and still renders fine.
  def provider_attributes
    return {} unless Project.column_names.include?("provider")

    { provider: "local_docker" }
  end

  def project(owner, repo)
    existing = owner.projects.find_by(repository: repo)
    return existing.tap { |p| p.update_columns(provider_attributes) if provider_attributes.any? } if existing

    project = owner.projects.new(
      repository:        repo,
      name:              "hello-anchor",
      production_branch: repo.default_branch,
      # Placeholder that satisfies the GCP project-id validator; the Local
      # Docker provider never reads it.
      gcp_project_id:    "anchor-local-demo",
      gcp_region:        "us-central1",
      framework:         "docker",
      runtime:           "docker",
      port:              8000,
      analysis_status:   "complete",
      analyzed_at:       Time.current,
      analysis_result:   {
        "framework"         => "docker",
        "runtime"           => "docker",
        "port"              => 8000,
        "has_dockerfile"    => true,
        "detected_env_vars" => [],
        "warnings"          => []
      },
      # Created as a draft so the after_create GCP provisioning hook is
      # skipped, then promoted to a normal project below.
      draft:             true,
      **provider_attributes
    )
    project.save!
    project.update_columns(draft: false)
    project
  end
end

user    = DemoSeed.user
repo    = DemoSeed.repository(user)
project = DemoSeed.project(user, repo)

puts "Seeded demo user '#{user.github_login}' and project '#{project.name}' " \
     "(#{project.respond_to?(:provider) ? project.provider : 'provider column pending'})."
