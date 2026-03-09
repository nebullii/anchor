FactoryBot.define do
  factory :repository do
    user
    sequence(:github_id)  { |n| (2_000_000 + n).to_s }
    sequence(:name)       { |n| "repo-#{n}" }
    sequence(:full_name)  { |n| "owner/repo-#{n}" }
    owner_login           { "owner" }
    default_branch        { "main" }
    sequence(:clone_url)  { |n| "https://github.com/owner/repo-#{n}.git" }
    sequence(:html_url)   { |n| "https://github.com/owner/repo-#{n}" }
    private               { false }
  end
end
