module Providers
  # Result of Providers::Base#build_status.
  #
  #   state  — :pending, :success or :failure
  #   detail — human-readable detail (failure reason, raw provider state)
  #   log_url — optional link to the provider's build logs
  class BuildStatus
    STATES = %i[pending success failure].freeze

    attr_reader :state, :detail, :log_url

    def initialize(state:, detail: nil, log_url: nil)
      state = state.to_sym
      raise ArgumentError, "Unknown build state: #{state.inspect}" unless STATES.include?(state)

      @state   = state
      @detail  = detail
      @log_url = log_url
    end

    def pending?  = state == :pending
    def success?  = state == :success
    def failure?  = state == :failure
    def terminal? = !pending?

    def ==(other)
      other.is_a?(BuildStatus) && other.state == state && other.detail == detail && other.log_url == log_url
    end
  end
end
