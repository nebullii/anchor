module Projects
  # Scans a repository using Claude AI and generates CI/CD deployment files,
  # then commits them to the user's GitHub repository.
  #
  # Broadcasts Turbo Stream updates to "project_#{id}_cicd" channel so the
  # setup wizard page can show real-time progress without polling.
  #
  class SetupCicdJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: 1

    def perform(project_id)
      project = Project.find_by(id: project_id)
      return unless project

      repo_path = "/tmp/anchor/cicd/#{project.id}"

      broadcast_status(project, "scanning", "Cloning repository…")
      clone_repo(project, repo_path)

      broadcast_status(project, "scanning", "Analyzing repository with AI…")
      result = generate_cicd_files(project, repo_path)

      if result.files.empty?
        fail_setup(project, "AI did not return any files to commit. Please try again.")
        return
      end

      # Store generated files and secrets list for the preview step.
      project.update_columns(
        cicd_setup_status: "ready",
        cicd_files: result.files,
        cicd_setup_error: nil
      )

      broadcast_ready(project, result)
    rescue => e
      Rails.logger.error("[Projects::SetupCicdJob] project=#{project_id} error=#{e.message}")
      fail_setup(project, e.message) if project
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    private

    def clone_repo(project, repo_path)
      FileUtils.rm_rf(repo_path)
      FileUtils.mkdir_p(File.dirname(repo_path))

      repository = project.repository
      branch     = project.production_branch.presence || repository.default_branch
      clone_url  = repository.authenticated_clone_url

      output = `git clone --depth=1 --branch #{Shellwords.escape(branch)} \
                #{Shellwords.escape(clone_url)} #{Shellwords.escape(repo_path)} 2>&1`

      unless $?.success?
        safe_output = output.gsub(clone_url, "[REDACTED]")
        raise "git clone failed: #{safe_output.lines.last(3).join}"
      end
    end

    def generate_cicd_files(project, repo_path)
      analysis = project.analysis_result || {}

      Ai::CicdGenerator.new(
        project:         project,
        repo_path:       repo_path,
        analysis_result: analysis
      ).call
    end

    def fail_setup(project, message)
      project.update_columns(
        cicd_setup_status: "failed",
        cicd_setup_error:  message.to_s.truncate(500)
      )

      Turbo::StreamsChannel.broadcast_replace_to(
        "project_#{project.id}_cicd",
        target:  "cicd_setup_panel",
        partial: "projects/cicd_setup_panel",
        locals:  { project: project.reload, cicd_result: nil }
      )
    end

    def broadcast_status(project, status, message)
      project.update_columns(cicd_setup_status: status)

      Turbo::StreamsChannel.broadcast_replace_to(
        "project_#{project.id}_cicd",
        target:  "cicd_setup_panel",
        partial: "projects/cicd_setup_panel",
        locals:  { project: project, cicd_result: nil, status_message: message }
      )
    end

    def broadcast_ready(project, result)
      Turbo::StreamsChannel.broadcast_replace_to(
        "project_#{project.id}_cicd",
        target:  "cicd_setup_panel",
        partial: "projects/cicd_setup_panel",
        locals:  { project: project.reload, cicd_result: result, status_message: nil }
      )
    end
  end
end
