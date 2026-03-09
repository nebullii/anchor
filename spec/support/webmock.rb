require "webmock/rspec"

# Disable real HTTP connections during tests — use stub_request instead.
WebMock.disable_net_connect!(allow_localhost: true)
