# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyCv::TurboHandler::Index do
  let(:user)         { create(:user) }
  let(:vacancy)      { create(:vacancy, source: create(:source)) }
  let(:user_profile) { create(:user_profile, user:) }
  let(:stream)       { "#{[ user, vacancy ].map(&:to_gid_param).join(':')}:vacancy_cvs" }

  def attach_cv(record)
    record.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'cv.pdf', content_type: 'application/pdf')
    record
  end

  # [action, target] of every turbo-stream sent on the CV list stream.
  def streams
    ActionCable.server.pubsub.broadcasts(stream).map do |message|
      html = JSON.parse(message)
      [ html[/action="([^"]+)"/, 1], html[/target="([^"]+)"/, 1] ]
    end
  end

  describe '.broadcast_row' do
    let(:list_target) { "vacancy_cvs_#{vacancy.hashid}" }

    it 'replaces the whole list when the row is the only CV (the empty state goes away)' do
      apply = create(:apply, user:, vacancy:, user_profile:, status: :generating_cv)

      described_class.broadcast_row(apply)

      expect(streams).to eq([ [ 'replace', list_target ] ])
    end

    context 'with other CVs in the list' do
      let!(:newer_cv) { attach_cv(create(:vacancy_cv, vacancy:, user_profile:, created_at: 1.hour.ago)) }
      let!(:older_cv) { attach_cv(create(:vacancy_cv, vacancy:, user_profile:, created_at: 3.days.ago)) }

      it 're-inserts only that row before the next older one, leaving the other rows untouched' do
        apply = create(:apply, user:, vacancy:, user_profile:, status: :generating_cv, created_at: 1.day.ago)

        described_class.broadcast_row(apply)

        expect(streams).to eq([
          [ 'remove', "cv_apply_#{apply.hashid}" ],
          [ 'before', "cv_vacancy_cv_#{older_cv.hashid}" ]
        ])
        expect(JSON.parse(ActionCable.server.pubsub.broadcasts(stream).last)).to include(%(id="cv_apply_#{apply.hashid}"))
      end

      it 'inserts the oldest row after the previous one' do
        apply = attach_cv(create(:apply, user:, vacancy:, user_profile:, status: :completed, created_at: 1.week.ago))

        described_class.broadcast_row(apply)

        expect(streams).to eq([
          [ 'remove', "cv_apply_#{apply.hashid}" ],
          [ 'after', "cv_vacancy_cv_#{older_cv.hashid}" ]
        ])
      end

      it 'only removes the row of an apply whose CV generation failed' do
        apply = create(:apply, user:, vacancy:, user_profile:, status: :failed_generating_cv)

        described_class.broadcast_row(apply)

        expect(streams).to eq([ [ 'remove', "cv_apply_#{apply.hashid}" ] ])
      end
    end

    it 'replaces the whole list with the empty state when the failed row was the last one' do
      apply = create(:apply, user:, vacancy:, user_profile:, status: :failed_generating_cv)

      described_class.broadcast_row(apply)

      expect(streams).to eq([ [ 'replace', list_target ] ])
      expect(JSON.parse(ActionCable.server.pubsub.broadcasts(stream).last)).to include(I18n.t('vacancy_cv.empty'))
    end
  end
end
