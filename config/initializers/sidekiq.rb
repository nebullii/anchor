Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

  # Start the stuck-deployment reaper on every worker boot. ReaperJob uses a
  # Redis SET NX marker, so however many processes boot there is only one
  # recurring chain (every 5 minutes).
  config.on(:startup) do
    Deployments::ReaperJob.ensure_scheduled
  rescue => e
    Sidekiq.logger.error("Could not schedule Deployments::ReaperJob: #{e.class}: #{e.message}")
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
