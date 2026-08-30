FactoryBot.define do
  factory :saved_filter do
    user
    sequence(:name) { |n| "Filter #{n}" }
    include_tags    { [ 'embedded', 'stm32' ] }
    include_ops     { [ 'and' ] }
    exclude_tags    { [ 'junior' ] }
  end
end
