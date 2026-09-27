# One-click rollback from the web UI.
#
#   POST /projects/:project_id/rollback               → roll back to previous healthy revision
#   POST /projects/:project_id/rollback?deployment_id=42 → roll back to deployment #42's revision
#
class RollbacksController < ApplicationController
  before_action :set_project

  def create
    target     = params[:deployment_id].presence
    deployment = Deployments::Rollback.new(project: @project, target: target, user: current_user).call

    redirect_to project_deployment_path(@project, deployment),
                notice: "Rollback started — shifting traffic to revision #{deployment.revision_name}."
  rescue Deployments::Rollback::Error => e
    redirect_back_or_to project_path(@project), alert: e.message
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  end
end
