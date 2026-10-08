# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Operation::Index, type: :operation do
  let(:current_user) { create(:user) }
  let(:source)       { create(:source) }
  let(:vacancy)      { create(:vacancy, source:) }
  let(:params)       { { vacancy_id: vacancy.id } }
  let(:user_profile) { create(:user_profile, user: current_user) }

  let!(:own_question) do
    create(:vacancy_question, vacancy:, user_profile:, question: 'Why us?', created_at: 2.days.ago)
  end
  let!(:other_question) do
    create(:vacancy_question, vacancy:, user_profile: create(:user_profile, user: create(:user)))
  end

  it 'returns only questions of the current user for the vacancy' do
    expect(result).to be_success
    expect(model.vacancy_questions).to contain_exactly(own_question)
  end

  it 'orders questions newest first' do
    newer = create(:vacancy_question, vacancy:, user_profile:, created_at: 1.day.ago)

    expect(model.vacancy_questions).to eq([ newer, own_question ])
  end

  describe 'question suggestions' do
    let(:inputs) do
      [
        { 'name' => 'about', 'tag' => 'textarea', 'label' => 'Tell us about yourself' },
        { 'name' => 'why', 'tag' => 'textarea', 'label' => '  why us? ' },
        { 'name' => 'notes', 'tag' => 'textarea', 'placeholder' => 'Salary expectations' },
        { 'name' => 'cover_letter', 'tag' => 'textarea' },
        { 'name' => 'email', 'tag' => 'input', 'type' => 'email', 'label' => 'Email' }
      ]
    end

    before do
      create(:apply, :failed, user: current_user, vacancy:, inputs:, created_at: 2.days.ago)
      create(:apply, :completed, user: current_user, vacancy:, created_at: 1.day.ago)
      create(:apply, user: create(:user), vacancy:,
                     inputs: [ { 'tag' => 'textarea', 'label' => 'Someone else question' } ])
    end

    it 'lists unasked open questions of the latest scraped form, label then placeholder' do
      expect(model.question_suggestions).to eq([ 'Tell us about yourself', 'Salary expectations' ])
    end

    context 'when the latest apply has discovered fields' do
      before do
        fields = [ Apply::Field.from_h(id: 'q', kind: 'textarea', label: 'Why Preply?').to_h,
                   Apply::Field.from_h(id: 'n', kind: 'text', label: 'Name').to_h ]
        create(:apply, :failed, user: current_user, vacancy:, fields:, created_at: 1.hour.ago)
      end

      it 'prefers the fields over legacy inputs' do
        expect(model.question_suggestions).to eq([ 'Why Preply?' ])
      end
    end
  end
end
