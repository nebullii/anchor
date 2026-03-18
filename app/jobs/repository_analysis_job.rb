class RepositoryAnalysisJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 2

  def perform(project_id)
    project    = Project.find_by(id: project_id)
    return unless project

    repository = project.repository
    repo_path  = "/tmp/cloudlaunch/analysis/#{project.id}"

    mark_analyzing(project)

    clone_repo(repository, project, repo_path)

    result      = RepositoryAnalyzer.new(repo_path, project).call
    enriched    = enrich_with_ai(result.to_h, repo_path)

    project.update_columns(
      analysis_status: "complete",
      analysis_result: enriched,
      analyzed_at:     Time.current
    )

    broadcast_complete(project)
  rescue => e
    Rails.logger.error("RepositoryAnalysisJob failed for project #{project_id}: #{e.message}")
    project&.update_columns(analysis_status: "failed")
    broadcast_failed(project) if project
  ensure
    FileUtils.rm_rf(repo_path) if repo_path
  end

  private

  def mark_analyzing(project)
    project.update_columns(analysis_status: "analyzing")
    Turbo::StreamsChannel.broadcast_replace_to(
      "project_#{project.id}_analysis",
      target:  "analysis_panel",
      partial: "projects/analysis_panel",
      locals:  { project: project }
    )
  end

  def enrich_with_ai(analysis_hash, repo_path)
    file_tree = Dir.glob("#{repo_path}/**/*", File::FNM_DOTMATCH)
                   .reject { |f| File.directory?(f) }
                   .map    { |f| f.sub("#{repo_path}/", "") }
                   .reject { |f| f.start_with?(".git/", "node_modules/", "vendor/") }

    readme_path = Dir.glob("#{repo_path}/README{,.md,.txt}", File::FNM_CASEFOLD).first
    readme      = File.read(readme_path) if readme_path && File.exist?(readme_path)

    Ai::RepositoryAnalyzer.new(analysis_hash, file_tree: file_tree, readme: readme).call
  rescue => e
    Rails.logger.warn("RepositoryAnalysisJob AI enrichment failed: #{e.message}")
    analysis_hash
  end

  def clone_repo(repository, project, repo_path)
    FileUtils.rm_rf(repo_path)
    FileUtils.mkdir_p(File.dirname(repo_path))

    branch    = project.production_branch.presence || repository.default_branch
    clone_url = repository.authenticated_clone_url

    output = `git clone --depth=1 --branch #{Shellwords.escape(branch)} \
              #{Shellwords.escape(clone_url)} #{Shellwords.escape(repo_path)} 2>&1`

    # If the branch wasn't found, clone without specifying one (use repo default)
    if !$?.success? && output.include?("Remote branch") && output.include?("not found")
      FileUtils.rm_rf(repo_path)
      actual_branch = detect_default_branch(clone_url)
      output = `git clone --depth=1 #{actual_branch ? "--branch #{Shellwords.escape(actual_branch)}" : ""} \
                #{Shellwords.escape(clone_url)} #{Shellwords.escape(repo_path)} 2>&1`

      if $?.success? && actual_branch
        project.update_columns(production_branch: actual_branch)
        repository.update_columns(default_branch: actual_branch)
      end
    end

    unless $?.success?
      safe_output = output.gsub(clone_url, "[REDACTED]")
      raise "git clone failed: #{safe_output.lines.last(3).join}"
    end
  end

  def detect_default_branch(clone_url)
    out = `git ls-remote --symref #{Shellwords.escape(clone_url)} HEAD 2>&1`
    match = out.match(%r{ref: refs/heads/(\S+)\s+HEAD})
    match&.captures&.first
  rescue
    nil
  end

  def broadcast_complete(project)
    Turbo::StreamsChannel.broadcast_replace_to(
      "project_#{project.id}_analysis",
      target:  "analysis_panel",
      partial: "projects/analysis_panel",
      locals:  { project: project }
    )
  end

  def broadcast_failed(project)
    Turbo::StreamsChannel.broadcast_replace_to(
      "project_#{project.id}_analysis",
      target:  "analysis_panel",
      partial: "projects/analysis_panel",
      locals:  { project: project }
    )
  end
end
