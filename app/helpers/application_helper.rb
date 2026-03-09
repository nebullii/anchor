module ApplicationHelper
  def active_nav_class(resource)
    controller_name == resource ? "text-white" : ""
  end

  def status_badge_class(status)
    case status.to_s
    when "success"                       then "bg-emerald-500/10 text-emerald-400 ring-emerald-500/20"
    when "failed"                        then "bg-red-500/10 text-red-400 ring-red-500/20"
    when "building", "deploying"         then "bg-yellow-500/10 text-yellow-400 ring-yellow-500/20"
    when "cloning",  "detecting"         then "bg-blue-500/10 text-blue-400 ring-blue-500/20"
    when "pending"                       then "bg-gray-500/10 text-gray-400 ring-gray-500/20"
    when "cancelled"                     then "bg-gray-500/10 text-gray-500 ring-gray-500/20"
    when "active"                        then "bg-emerald-500/10 text-emerald-400 ring-emerald-500/20"
    when "error"                         then "bg-red-500/10 text-red-400 ring-red-500/20"
    else                                      "bg-gray-500/10 text-gray-400 ring-gray-500/20"
    end
  end

  def status_spinning?(status)
    %w[pending cloning detecting building deploying].include?(status.to_s)
  end

  def log_level_class(level)
    case level.to_s
    when "error" then "text-red-400"
    when "warn"  then "text-yellow-400"
    when "debug" then "text-gray-500"
    else              "text-gray-300"
    end
  end

  def framework_icon(framework)
    case framework.to_s
    when "rails"   then "&#x1F48E;"   # gem
    when "node"    then "&#x1F7E9;"   # green square
    when "nextjs"  then "&#x25B2;"    # triangle (Vercel-ish)
    when "python"  then "&#x1F40D;"   # snake
    when "fastapi" then "&#x26A1;"    # lightning (fast)
    when "flask"   then "&#x1F9EA;"   # flask/beaker
    when "django"  then "&#x1F3B8;"   # guitar (Django logo vibe)
    when "static"  then "&#x1F4C4;"   # page
    when "docker"  then "&#x1F433;"   # whale
    else                "&#x1F4E6;"   # package
    end
  end
end
