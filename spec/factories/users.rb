FactoryBot.define do
  factory :user do
    sequence(:github_id)    { |n| (1_000_000 + n).to_s }
    sequence(:github_login) { |n| "user#{n}" }
    name       { Faker::Name.name }
    email      { Faker::Internet.email }
    avatar_url { Faker::Internet.url }
    github_token { Faker::Alphanumeric.alphanumeric(number: 40) }
    default_gcp_region { "us-central1" }
  end
end
