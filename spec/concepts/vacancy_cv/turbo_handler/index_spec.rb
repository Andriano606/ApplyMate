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

  describe '.broadcast' do
    it 'replaces the whole list, so a newly appeared row needs no rendered neighbour' do
      first  = create(:apply, user:, vacancy:, user_profile:, status: :generating_cv, created_at: 1.hour.ago)
      second = create(:apply, user:, vacancy:, user_profile:, status: :generating_cv)

      described_class.broadcast(vacancy, user)

      expect(streams).to eq([ [ 'replace', "vacancy_cvs_#{vacancy.hashid}" ] ])
      html = Nokogiri::HTML.fragment(JSON.parse(ActionCable.server.pubsub.broadcasts(stream).last))
      expect(html.css('turbo-frame[id^="cv_apply_"]').pluck('id')).to eq([ "cv_apply_#{second.hashid}", "cv_apply_#{first.hashid}" ])
    end
  end

  describe '.broadcast_row' do
    let(:list_target) { "vacancy_cvs_#{vacancy.hashid}" }

    it "replaces only the row's own frame when it is the only CV" do
      apply = attach_cv(create(:apply, user:, vacancy:, user_profile:, status: :completed))

      described_class.broadcast_row(apply)

      expect(streams).to eq([ [ 'replace', "cv_apply_#{apply.hashid}" ] ])
    end

    context 'with other CVs in the list' do
      let!(:newer_cv) { attach_cv(create(:vacancy_cv, vacancy:, user_profile:, created_at: 1.hour.ago)) }
      let!(:older_cv) { attach_cv(create(:vacancy_cv, vacancy:, user_profile:, created_at: 3.days.ago)) }

      it "replaces only the row's own frame, leaving the other rows untouched" do
        apply = attach_cv(create(:apply, user:, vacancy:, user_profile:, status: :completed, created_at: 1.day.ago))

        described_class.broadcast_row(apply)

        expect(streams).to eq([ [ 'replace', "cv_apply_#{apply.hashid}" ] ])
        expect(JSON.parse(ActionCable.server.pubsub.broadcasts(stream).last)).to include(%(id="cv_apply_#{apply.hashid}"))
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
