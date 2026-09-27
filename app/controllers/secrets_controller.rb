class SecretsController < ApplicationController
  before_action :set_project

  def index
    @secrets        = @project.secrets.ordered
    @secret         = @project.secrets.new(key: params[:prefill_key])
    @detected_vars  = @project.detected_env_vars
  end

  def create
    @secret = @project.secrets.new(secret_params)
    if @secret.save
      audit("created", @secret.key)
      redirect_to project_secrets_path(@project), notice: "Secret added."
    else
      @secrets       = @project.secrets.ordered
      @detected_vars = @project.detected_env_vars
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    secret = @project.secrets.find(params[:id])
    secret.destroy
    audit("deleted", secret.key)
    redirect_to project_secrets_path(@project), notice: "Secret removed."
  end

  private

  # Scoped through current_user, so another user's project is a 404.
  def set_project
    @project = current_user.projects.find(params[:project_id])
  end

  def secret_params
    params.require(:secret).permit(:key, :value)
  end

  # Audit trail: who changed which secret. Key names only — never values.
  def audit(action, key)
    Rails.logger.info(
      "[audit] secret.#{action} user_id=#{current_user.id} project_id=#{@project.id} key=#{key}"
    )
  end
end
