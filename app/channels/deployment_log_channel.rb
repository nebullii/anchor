class DeploymentLogChannel < ApplicationCable::Channel
  def subscribed
    deployment = Deployment.find_by(id: params[:deployment_id])

    if deployment && deployment.project.user == current_user
      stream_from "deployment_#{params[:deployment_id]}_logs"
    else
      reject
    end
  end
end
