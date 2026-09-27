# Rack::Attack counts requests in Redis, which persists between runs and is
# shared by every checkout on the machine. Left on, request specs start
# returning 429 once the shared per-IP budget is used up — a flaky signal.
# Use a per-process memory store and keep throttling off by default; specs
# that exercise throttling opt back in with `rack_attack: true` (or enable it
# themselves, as spec/requests/rack_attack_spec.rb does).
Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
Rack::Attack.enabled = false

RSpec.configure do |config|
  config.before { Rack::Attack.cache.store.clear }

  config.around(:each, :rack_attack) do |example|
    Rack::Attack.enabled = true
    Rack::Attack.reset!
    example.run
  ensure
    Rack::Attack.enabled = false
  end
end
