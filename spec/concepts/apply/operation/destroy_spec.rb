# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Destroy, type: :operation do
  let(:current_user) { create(:user) }
  let(:vacancy)      { create(:vacancy, source: create(:source)) }
  let!(:apply)       { create(:apply, user: current_user, vacancy:, status: :completed) }
  let(:params)       { { id: apply.hashid } }

  context 'with broadcasts stubbed' do
    before do
      allow(Apply::TurboHandler::StatusUpdate).to receive(:refresh)
      allow(VacancyCv::TurboHandler::Index).to receive(:broadcast)
      allow(VacancyQuestion::TurboHandler::Index).to receive(:broadcast)
    end

    it 'destroys the apply and refreshes the vacancy page views of its owner' do
      expect(result).to be_success
      expect(Apply.exists?(apply.id)).to be(false)
      expect(result.notice[:text]).to eq(I18n.t('apply.destroy.success'))
      expect(Apply::TurboHandler::StatusUpdate).to have_received(:refresh).with(vacancy, current_user)
      expect(VacancyCv::TurboHandler::Index).to have_received(:broadcast).with(vacancy, current_user)
      expect(VacancyQuestion::TurboHandler::Index).to have_received(:broadcast).with(vacancy, current_user)
    end

    it "does not destroy another user's apply" do
      other_apply = create(:apply, vacancy:)
      operation = described_class.new(params: { id: other_apply.hashid }, current_user:)

      expect { operation.call }.to raise_error(ActiveRecord::RecordNotFound)
      expect(Apply.exists?(other_apply.id)).to be(true)
      expect(Apply::TurboHandler::StatusUpdate).not_to have_received(:refresh)
    end
  end

  # The real broadcast path: what the vacancy page receives once the apply is gone.
  context 'with real broadcasts' do
    let(:stream)     { [ current_user, vacancy ].map(&:to_gid_param).join(':') }
    let(:cvs_stream) { "#{stream}:vacancy_cvs" }

    def messages(name)
      ActionCable.server.pubsub.broadcasts(name).map { |message| JSON.parse(message) }
    end

    it 'falls the badge, action box and applies panel back to the remaining apply' do
      older_apply = create(:apply, user: current_user, vacancy:, status: :failed_sending_cv, created_at: 1.day.ago)

      result

      badge, action_box, panel = messages(stream)
      expect(badge).to include("apply_#{older_apply.hashid}")
      expect(action_box).to include(I18n.t('apply.action_box.retry'))
      expect(panel).to include("apply_#{older_apply.hashid}")
      expect(panel).not_to include("apply_#{apply.hashid}")
    end

    it 'falls back to the "not applied" state and refreshes the CV list when no apply is left' do
      result

      badge, action_box, panel = messages(stream)
      expect(badge).to include("/applies/new?vacancy_id=#{vacancy.hashid}")
      expect(action_box).to include(I18n.t('apply.action_box.apply'))
      expect(panel).to include(I18n.t('apply.vacancy_index.empty'))
      expect(messages(cvs_stream).last).to include(%(target="vacancy_cvs_#{vacancy.hashid}"))
    end
  end
end
