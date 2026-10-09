# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyCv::Operation::Index, type: :operation do
  let(:current_user) { create(:user) }
  let(:vacancy)      { create(:vacancy, source: create(:source)) }
  let(:params)       { { vacancy_id: vacancy.id } }
  let(:user_profile) { create(:user_profile, user: current_user) }

  def attach_cv(record)
    record.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'cv.pdf', content_type: 'application/pdf')
    record
  end

  let!(:vacancy_cv)          { create(:vacancy_cv, vacancy:, user_profile:, created_at: 3.days.ago) }
  let!(:apply_with_cv)       { attach_cv(create(:apply, :completed, user: current_user, vacancy:, created_at: 2.days.ago)) }
  let!(:apply_generating_cv) { create(:apply, :running, user: current_user, vacancy:, created_at: 1.day.ago) }

  before do
    create(:apply, :failed, user: current_user, vacancy:)
    create(:vacancy_cv, vacancy:)
    attach_cv(create(:apply, user: create(:user), vacancy:))
    attach_cv(create(:apply, user: current_user))
    create(:vacancy_cv, user_profile:)
  end

  it "merges the user's manual CVs and apply CVs (attached or generating) for this vacancy, newest first" do
    expect(result).to be_success
    expect(model.cvs).to eq([ apply_generating_cv, apply_with_cv, vacancy_cv ])
  end
end
