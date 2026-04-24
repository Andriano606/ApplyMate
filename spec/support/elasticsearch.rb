# frozen_string_literal: true

RSpec.shared_context "with elasticsearch index" do
  before(:all) { Vacancy.__elasticsearch__.create_index! force: true }
  after(:all)  { Vacancy.__elasticsearch__.delete_index! }
end
