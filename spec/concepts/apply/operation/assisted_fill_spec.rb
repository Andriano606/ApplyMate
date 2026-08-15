# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::AssistedFill, type: :operation do
  include_context 'honeytech dou'

  let(:current_user) { user }
  let(:params)       { { id: apply.hashid } }

  before do
    allow(browser).to receive(:detach).and_return(browser)
    allow(browser).to receive(:close_stale_tabs)
    allow(browser).to receive(:bring_to_front)
    allow(browser).to receive(:set_checkbox_by_handle)
    allow(Apply::AssistedSession).to receive(:store)

    apply.update!(
      status:        :needs_review,
      error:         'Сайт відхилив автоматичну відправку',
      resolved_url:  HoneytechDou::PEOPLEFORCE_URL,
      filled_inputs: filled_inputs.map { |i| i.merge('fingerprint' => fingerprint_of(i)) }
    )
  end

  it 'opens a VISIBLE browser and keeps it alive for the user' do
    expect(ApplyMate::Client::Browser).to receive(:new).with(headless: false, shared: true).and_return(browser)
    expect(Apply::AssistedSession).to receive(:store).with(apply.id, browser)

    expect(result).to be_success
    expect(browser).to have_received(:detach)
    expect(browser).not_to have_received(:quit)
  end

  it 'clears tabs left by earlier attempts and raises its own to the front' do
    expect(result).to be_success
    expect(browser).to have_received(:close_stale_tabs).with(HoneytechDou::PEOPLEFORCE_URL)
    expect(browser).to have_received(:bring_to_front)
  end

  it 'fills the form with the answers already resolved for this apply' do
    expect(result).to be_success
    expect(browser).to have_received(:fill_by_handle).with(0, 'Jane Doe', 'input')
    expect(browser).to have_received(:fill_by_handle).with(1, 'dev@example.com', 'input')
  end

  it 'never presses submit — that is the user’s job' do
    expect(result).to be_success
    expect(browser).not_to have_received(:click_by_handle).with('submit')
  end

  it 'marks the apply as waiting for the user to send it' do
    expect(result).to be_success
    reloaded = apply.reload
    expect(reloaded.status).to eq('awaiting_manual_submit')
    expect(reloaded.error).to be_nil
  end

  context 'when the form is embedded in an iframe' do
    before do
      allow(browser).to receive(:field_count).and_return(0)
      allow(browser).to receive(:iframe_sources)
        .and_return([ 'https://jobs.ashbyhq.com/preply/a9419d80?embed=js' ])
    end

    it 'follows the embed before filling' do
      expect(result).to be_success
      expect(browser).to have_received(:navigate_to)
        .with('https://jobs.ashbyhq.com/preply/a9419d80/application')
    end
  end

  context 'when the apply has no resolved answers yet' do
    before { apply.update!(filled_inputs: []) }

    it 'refuses to open a browser' do
      expect { result }.to raise_error(/заповнити відповіді/)
    end
  end

  context 'when the apply belongs to another user' do
    let(:current_user) do
      User.create!(email: 'other@example.com', name: 'Other', provider: 'google_oauth2', uid: 'uid-other-2')
    end

    it 'denies access' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
