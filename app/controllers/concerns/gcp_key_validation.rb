# frozen_string_literal: true

# Shared validation for GCP service account JSON keys.
# Used by SettingsController and DeployWizardController.
module GcpKeyValidation
  extend ActiveSupport::Concern

  REQUIRED_SA_FIELDS = %w[type client_email project_id private_key].freeze

  # Returns nil if valid, or an error string describing the problem.
  def validate_service_account_key(parsed)
    # Must be a service_account type (not Firebase, OAuth, etc.)
    unless parsed["type"] == "service_account"
      return "This is not a service account key (type: #{parsed['type'].presence || 'missing'}). " \
             "Download a Service Account JSON key, not a Firebase or OAuth credential."
    end

    # Block Firebase Admin SDK accounts — they lack Cloud Run / Cloud Build permissions
    if parsed["client_email"].to_s.include?("firebase-adminsdk")
      return "Firebase Admin SDK service accounts cannot deploy to Cloud Run. " \
             "Create a dedicated service account in IAM & Admin → Service Accounts " \
             "and grant it the Editor role (or Cloud Build, Cloud Run, Artifact Registry roles)."
    end

    # Ensure all required fields are present
    missing = REQUIRED_SA_FIELDS.reject { |f| parsed[f].present? }
    return "Invalid service account key — missing fields: #{missing.join(', ')}." if missing.any?

    nil
  end
end
