# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::TurboHandler::StatusUpdate do
  let(:user)     { create(:user) }
  let(:vacancy)  { create(:vacancy, source: create(:source)) }
  # Turbo's stream name for [user, vacancy] (Turbo::Streams::StreamName#stream_name_from is private).
  let(:stream)   { [ user, vacancy ].map(&:to_gid_param).join(':') }

  def messages
    ActionCable.server.pubsub.broadcasts(stream).map { |message| JSON.parse(message) }
  end

  def broadcast_targets
    messages.map { |message| message[/target="([^"]+)"/, 1] }
  end

  describe '.broadcast (the Runner changed one apply)' do
    let(:filled_inputs) { [ { 'tag' => 'textarea', 'label' => 'Why us?', 'value' => 'Because' } ] }

    it 'replaces the badge, the action box and only that apply card, never the whole panel' do
      create(:apply, :completed, user:, vacancy:, created_at: 1.day.ago)
      apply = create(:apply, :running, user:, vacancy:, filled_inputs:)

      described_class.broadcast(apply)

      expect(broadcast_targets).to eq([
        "apply_status_#{vacancy.hashid}_#{user.hashid}",
        "apply_action_box_#{vacancy.hashid}_#{user.hashid}",
        "apply_#{apply.hashid}"
      ])
      card = Nokogiri::HTML.fragment(messages.last).at_css("article#apply_#{apply.hashid}")
      expect(card.at_css('details[open]')).to be_present
    end

    it 'renders an older apply card collapsed, as the panel does' do
      older = create(:apply, :completed, user:, vacancy:, filled_inputs:, created_at: 1.day.ago)
      create(:apply, :completed, user:, vacancy:, created_at: 1.hour.ago)

      described_class.broadcast(older)

      card = Nokogiri::HTML.fragment(messages.last).at_css("article#apply_#{older.hashid}")
      expect(card).to be_present
      expect(card.at_css('details[open]')).to be_nil
    end
  end

  describe '.broadcast for a needs_review apply' do
    it 'renders the review form inside the card without current_user' do
      apply = create(:apply, user:, vacancy:, state: :needs_review, failure: { code: 'review', kind: 'human', detail: 'low_confidence' },
                             fields: [ answer_field(id: 'name', label: 'Full name').to_h ], answers: { 'name' => answer_entry('Ada') })

      described_class.broadcast(apply)

      card = Nokogiri::HTML.fragment(messages.last).at_css("article#apply_#{apply.hashid}")
      expect(card.at_css('form[action$="/approve_review"] input[name="answers[name]"]')['value']).to eq('Ada')
    end
  end

  describe '.refresh (applies added or removed)' do
    it 'replaces the badge, the action box and the whole applies panel' do
      apply = create(:apply, :running, user:, vacancy:, stage: 'fetch_form')

      described_class.refresh(vacancy, user)

      expect(broadcast_targets).to eq([
        "apply_status_#{vacancy.hashid}_#{user.hashid}",
        "apply_action_box_#{vacancy.hashid}_#{user.hashid}",
        "vacancy_applies_#{vacancy.hashid}_#{user.hashid}"
      ])
      expect(messages.last).to include("apply_#{apply.hashid}")
    end

    it 'refreshes to the "not applied" state once no apply is left' do
      described_class.refresh(vacancy, user)

      expect(broadcast_targets.size).to eq(3)
      expect(messages.first).to include("/applies/new?vacancy_id=#{vacancy.hashid}")
    end
  end
end
