# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::ReviewForm, type: :component do
  let(:user)    { create(:user) }
  let(:vacancy) { create(:vacancy, source: create(:source)) }
  let(:detail)  { 'low_confidence' }
  let(:fields) do
    [
      answer_field(id: 'name', label: 'Full name', required: true),
      answer_field(id: 'email', label: 'Email', kind: 'email'),
      answer_field(id: 'why', label: 'Why us?', kind: 'textarea', description: 'x' * 300),
      answer_field(id: 'src', label: 'Source', kind: 'select', options: [ { 'label' => 'Friend', 'value' => 'f' }, { 'label' => 'Ad', 'value' => 'a' } ]),
      answer_field(id: 'cv', label: 'Resume', kind: 'file', semantic: 'cv', required: true),
      answer_field(id: 'tok', label: 'Token', kind: 'hidden'),
      answer_field(id: 'skipped', label: 'Never answered'),
      answer_field(id: 'terms', label: 'I agree to the terms', kind: 'checkbox', semantic: 'consent_required', required: true)
    ].map(&:to_h)
  end
  let(:answers) do
    {
      'name' => answer_entry('Ada', source: 'fact', confidence: 1.0),
      'email' => answer_entry(unique_email('ada'), source: 'user'),
      'why' => answer_entry('Because', source: 'ai', confidence: 0.82),
      'src' => answer_entry('Ad', source: 'ai', confidence: 0.5),
      'terms' => answer_entry(true, source: 'policy_pending', confidence: 1.0)
    }
  end
  let(:apply) do
    create(:apply, user:, vacancy:, state: :needs_review, failure: { code: 'review', kind: 'human', detail: },
                   fields:, answers:, form_url: 'https://jobs.ashbyhq.com/preply/abc/application')
  end

  def form(record = apply)
    render_inline(described_class.new(apply: record, user:))
    page.native
  end

  it 'renders nothing outside needs_review' do
    render_inline(described_class.new(apply: create(:apply, :failed, user:, vacancy:), user:))

    expect(page.native.text).to be_blank
  end

  it 'lists answered and required fields only, never hidden or unanswered optional ones' do
    labels = form.css('[data-test-id="apply-review-field"]').map { |row| row['data-field-id'] }

    expect(labels).to eq(%w[name email why src cv terms])
  end

  it 'renders each kind with its current value and posts answers[field_id] to approve_review' do
    html = form

    expect(html.at_css('form')['action']).to eq("/applies/#{apply.hashid}/approve_review")
    expect(html.at_css('input[name="answers[name]"]')['value']).to eq('Ada')
    expect(html.at_css('input[name="answers[email]"]')['type']).to eq('email')
    expect(html.at_css('textarea[name="answers[why]"]').text.strip).to eq('Because')
    expect(html.at_css('select[name="answers[src]"] option[selected]').text).to eq('Ad')
    expect(html.at_css('input[type="checkbox"][name="answers[terms]"]')['checked']).to be_present
  end

  context 'with a multiselect, a number and date fields' do
    let(:fields) do
      [ answer_field(id: 'cities', label: 'Locations', kind: 'multiselect', options: [ { 'label' => 'Kyiv' }, { 'label' => 'Remote' } ]),
        answer_field(id: 'years', label: 'Years', kind: 'number'),
        answer_field(id: 'start', label: 'Start date', kind: 'date'),
        answer_field(id: 'free', label: 'Available from', kind: 'date') ].map(&:to_h)
    end
    let(:answers) do
      { 'cities' => answer_entry(%w[Kyiv], source: 'ai', confidence: 0.9),
        'years' => answer_entry(3.5, source: 'ai', confidence: 0.9),
        'start' => answer_entry('2026-11-01', source: 'ai', confidence: 0.9),
        'free' => answer_entry('June 2025', source: 'ai', confidence: 0.9) }
    end

    it 'posts a blank sentinel before the multiple select, so deselecting everything clears the answer' do
      inputs = form.css('[name="answers[cities][]"]')

      expect(inputs.map(&:name)).to eq(%w[input select])
      expect(inputs.first.attributes.slice('type', 'value').transform_values(&:value)).to eq('type' => 'hidden', 'value' => '')
    end

    it 'lets a number input take fractions' do
      expect(form.at_css('input[name="answers[years]"]').attributes.slice('type', 'step', 'value').transform_values(&:value))
        .to eq('type' => 'number', 'step' => 'any', 'value' => '3.5')
    end

    it 'renders a date input only for an ISO date, a text input otherwise' do
      html = form

      expect(html.at_css('input[name="answers[start]"]')['type']).to eq('date')
      expect(html.at_css('input[name="answers[free]"]').attributes.slice('type', 'value').transform_values(&:value))
        .to eq('type' => 'text', 'value' => 'June 2025')
    end
  end

  it 'shows the CV filename read-only for a file field' do
    apply.cv.attach(io: StringIO.new('pdf'), filename: 'ada.pdf', content_type: 'application/pdf')
    html = form(Apply.find(apply.id))

    expect(html.at_css('[data-test-id="apply-review-file"]').text).to include('ada.pdf')
    expect(html.at_css('[name="answers[cv]"]')).to be_nil
  end

  it 'marks required inputs and allows a blank option only for optional selects' do
    html = form

    expect(html.at_css('input[name="answers[name]"]')['required']).to be_present
    expect(html.at_css('select[name="answers[src]"] option[value=""]')).to be_present
  end

  it 'truncates the description and keeps it in the title attribute' do
    description = form.at_css('p.truncate')

    expect(description['title']).to eq('x' * 300)
  end

  it 'shows a source chip per answer, with the AI confidence' do
    chips = form.css('[data-test-id="apply-review-source"]').map(&:text)

    expect(chips).to include(I18n.t('apply.review.source.fact'), I18n.t('apply.review.source.user'),
                             "#{I18n.t('apply.review.source.ai')} - 82%",
                             I18n.t('apply.review.source.policy_pending'))
  end

  it 'shows the consent text with the consent notice' do
    html = form

    expect(html.at_css('[data-test-id="apply-review-checkbox-label"]').text).to eq('I agree to the terms')
    expect(html.text).to include(I18n.t('apply.review.consent_notice'))
  end

  it 'lists the reasons and the origin host' do
    html = form

    expect(html.at_css('[data-test-id="apply-review-reasons"]').text).to include(I18n.t('apply.review.reason.low_confidence'))
    expect(html.at_css('[data-test-id="apply-review-origin"]').text).to include('jobs.ashbyhq.com')
    expect(html.at_css('input[name="confirm_duplicate"]')).to be_nil
  end

  context 'with a foreign origin' do
    let(:detail) { 'foreign_origin,low_confidence' }

    it 'shows the host prominently in an alert' do
      alert = form.at_css('[data-test-id="apply-review-reasons"] [role="alert"]')

      expect(alert.text).to include(I18n.t('apply.review.reason.foreign_origin'), 'jobs.ashbyhq.com')
    end
  end

  context 'with a duplicate' do
    let(:detail) { 'duplicate' }

    it 'requires the duplicate confirmation checkbox' do
      html = form

      expect(html.at_css('input[name="confirm_duplicate"]')['required']).to be_present
      expect(html.text).to include(I18n.t('apply.review.duplicate_warning'), I18n.t('apply.review.confirm_duplicate'))
    end
  end

  context 'when CheckApplyKey halted already_applied (detail = the earlier apply hashid)' do
    let(:previous) { create(:apply, :failed, user:, vacancy:) }
    let(:apply) do
      create(:apply, user:, vacancy:, state: :needs_review, fields:, answers:,
                     failure: { code: 'already_applied', kind: 'human', detail: previous.hashid },
                     form_url: 'https://jobs.ashbyhq.com/preply/abc/application')
    end

    it 'shows the duplicate reason and requires the confirmation ApproveReview asks for' do
      html = form

      expect(html.at_css('input[name="confirm_duplicate"]')['required']).to be_present
      expect(html.text).to include(I18n.t('apply.review.reason.duplicate'), I18n.t('apply.review.duplicate_warning'))
      expect(html.text).not_to include(previous.hashid, 'translation missing')
    end
  end

  it 'has the approve button and a cancel link' do
    html = form

    expect(html.at_css('button[type="submit"]').text).to include(I18n.t('apply.review.approve'))
    expect(html.at_css("a[href='/applies/#{apply.hashid}/cancel']")['data-turbo-method']).to eq('post')
  end

  it 'renders without current_user when the user is passed (broadcast context)' do
    html = ApplicationController.renderer.render_to_string(described_class.new(apply:, user:), layout: false)

    expect(html).to include(I18n.t('apply.review.title'))
  end
end
