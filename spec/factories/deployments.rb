FactoryBot.define do
  factory :deployment do
    project
    status       { "pending" }
    branch       { "main" }
    triggered_by { "manual" }

    trait :cloning    do status { "cloning" }    end
    trait :building   do status { "building" }   end
    trait :deploying  do status { "deploying" }  end
    trait :success    do
      status      { "success" }
      service_url { "https://example-abc123-uc.a.run.app" }
      started_at  { 5.minutes.ago }
      finished_at { Time.current }
    end
    trait :failed do
      status        { "failed" }
      error_message { "Build failed" }
      started_at    { 5.minutes.ago }
      finished_at   { Time.current }
    end
  end
end
