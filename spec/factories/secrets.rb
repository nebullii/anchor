FactoryBot.define do
  factory :secret do
    project
    sequence(:key) { |n| "SECRET_KEY_#{n}" }
    value          { Faker::Alphanumeric.alphanumeric(number: 20) }
  end
end
