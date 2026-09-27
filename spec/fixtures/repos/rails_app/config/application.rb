require_relative "boot"
require "rails/all"

module RailsApp
  class Application < Rails::Application
    config.load_defaults 8.0
  end
end
