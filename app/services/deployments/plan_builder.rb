module Deployments
  class PlanBuilder
    TARGET = "Google Cloud Run".freeze

    def initialize(project:, analysis_result:, user:)
      @project = project
      @analysis_result = analysis_result || {}
      @user = user
    end

    def call
      required_keys = required_env_keys
      optional_keys = optional_env_keys
      configured_keys = @project.secrets.pluck(:key).to_set

      missing_required = required_keys - configured_keys.to_a

      {
        "framework" => @analysis_result["framework"] || @project.framework || "unknown",
        "runtime" => @analysis_result["runtime"] || @project.runtime || "unknown",
        "port" => @analysis_result["port"] || @project.port || 8080,
        "container" => @analysis_result["has_dockerfile"] ? "Repository Dockerfile" : "Generated Dockerfile",
        "target" => TARGET,
        "required_env_vars" => required_keys,
        "optional_env_vars" => optional_keys,
        "missing_required_env_vars" => missing_required,
        "deployment_readiness" => readiness_score(required_keys.size, missing_required.size),
        "risks" => Array(@analysis_result["warnings"]).compact.uniq.first(5),
        "ai_env_var_suggestions" => Array(@analysis_result["ai_env_var_suggestions"]).first(12)
      }
    end

    private

    def required_env_keys
      detected = Array(@analysis_result["detected_env_vars"]).select { |v| v["required"] }
      from_ai = Array(@analysis_result["ai_env_var_suggestions"]).select do |v|
        v["required"] && v["confidence"].to_s.downcase == "high"
      end

      (detected + from_ai).map { |v| v["key"].to_s.upcase }.reject(&:blank?).uniq.sort
    end

    def optional_env_keys
      detected = Array(@analysis_result["detected_env_vars"]).reject { |v| v["required"] }
      from_ai = Array(@analysis_result["ai_env_var_suggestions"]).reject do |v|
        v["required"] && v["confidence"].to_s.downcase == "high"
      end

      (detected + from_ai).map { |v| v["key"].to_s.upcase }.reject(&:blank?).uniq.sort
    end

    def readiness_score(required_count, missing_required_count)
      env_score =
        if required_count.zero?
          40
        else
          ((required_count - missing_required_count) * 40.0 / required_count).round
        end

      gcp_score = @user.google_connected? ? 20 : 0
      provisioning_score = @project.gcp_provisioned? ? 20 : 10
      analysis_score = @project.analysis_complete? ? 20 : 0

      (env_score + gcp_score + provisioning_score + analysis_score).clamp(0, 100)
    end
  end
end
