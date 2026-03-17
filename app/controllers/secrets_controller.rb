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
      redirect_to project_secrets_path(@project), notice: "Secret added."
    else
      @secrets = @project.secrets.ordered
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @project.secrets.find(params[:id]).destroy
    redirect_to project_secrets_path(@project), notice: "Secret removed."
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  end

  def secret_params
    params.require(:secret).permit(:key, :value)
  end
end
