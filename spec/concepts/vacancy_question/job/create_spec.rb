# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Job::Create, type: :job do
  it 'runs on the apply queue' do
    expect(described_class.new(9).queue_name).to eq('apply')
  end

  it 'limits concurrency to one run per VacancyQuestion for 10 minutes' do
    job = described_class.new(9)

    expect(job.concurrency_key).to eq('VacancyQuestion::Job::Create/vacancy_question:9')
    expect(job.concurrency_limit).to eq(1)
    expect(job.concurrency_duration).to eq(10.minutes)
  end

  it 'enqueues on the apply queue' do
    expect { described_class.perform_later(9) }
      .to have_enqueued_job(described_class).with(9).on_queue('apply')
  end

  describe '#perform' do
    let(:vacancy)          { create(:vacancy, source: create(:source)) }
    let(:vacancy_question) { create(:vacancy_question, vacancy:) }

    before do
      stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
        .to_return(gemini_json_response('{"answer":"Маю 8 років досвіду з Ruby."}'))
      allow(VacancyQuestion::TurboHandler::AnswerReady).to receive(:broadcast)
    end

    it 'persists the AI answer and broadcasts it' do
      described_class.perform_now(vacancy_question.id)

      expect(vacancy_question.reload.answer).to eq('Маю 8 років досвіду з Ruby.')
      expect(VacancyQuestion::TurboHandler::AnswerReady).to have_received(:broadcast).with(vacancy_question)
    end
  end
end
