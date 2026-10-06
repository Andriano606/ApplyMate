# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::TurboHandler::Index do
  let(:user)    { create(:user) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }
  let(:stream)  { "#{[ user, vacancy ].map(&:to_gid_param).join(':')}:vacancy_questions" }

  it "replaces the questions frame with the suggestions of the user's latest scraped form" do
    create(:apply, user:, vacancy:, inputs: [ { 'name' => 'why', 'tag' => 'textarea', 'label' => 'Why us?' } ])

    described_class.broadcast(vacancy, user)

    message = JSON.parse(ActionCable.server.pubsub.broadcasts(stream).last)
    expect(message).to include(%(action="replace"), %(target="vacancy_questions_#{vacancy.hashid}"), 'Why us?')
  end
end
