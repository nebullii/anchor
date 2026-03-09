FactoryBot.define do
  factory :project do
    user
    repository
    sequence(:name)    { |n| "Project #{n}" }
    gcp_project_id     { "my-gcp-project" }
    gcp_region         { "us-central1" }
    production_branch  { "main" }
    status             { "inactive" }
  end
end
