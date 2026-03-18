# frozen_string_literal: true

class GcpProjectIdValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.blank?

    # Check that project_id matches the users configured GCP project
    user_project_id = record.user.gcp_project_from_key
    
    if user_project_id.present? && value != user_project_id
      record.errors.add(attribute, "must match your configured GCP project (#{user_project_id}). " \
        "You can find your GCP project ID in your service account key or Google Cloud Console.")
    end
  end
end
