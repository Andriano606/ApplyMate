# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::ConfirmManualSubmit, type: :operation do
  include_context 'honeytech dou'

  let(:current_user) { user }
  let(:params)       { { id: apply.hashid } }

  before do
    apply.update!(status: :awaiting_manual_submit)
    allow(Apply::AssistedSession).to receive(:fetch).with(apply.id).and_return(browser)
    allow(Apply::AssistedSession).to receive(:close)
  end

  context 'when the page shows no refusal' do
    it 'completes the apply and releases the session' do
      expect(result).to be_success
      expect(apply.reload.status).to eq('completed')
      expect(Apply::AssistedSession).to have_received(:close).with(apply.id)
    end

    it 'keeps a screenshot of the finished page as evidence' do
      allow(browser).to receive(:screenshot).and_return('png-bytes')
      expect(result).to be_success
      expect(apply.reload.screenshot).to be_attached
    end
  end

  context 'when the site refused the submission after all' do
    before do
      allow(browser).to receive(:observe_state).and_return(
        browser_observe_state.merge(
          'alerts' => [ 'Your application submission was flagged as possible spam' ]
        )
      )
    end

    it 'does not mark it completed and explains why' do
      expect(result).to be_success
      reloaded = apply.reload
      expect(reloaded.status).to eq('needs_review')
      expect(reloaded.error).to include('flagged as possible spam')
    end
  end

  context 'when the user already closed the browser' do
    before { allow(Apply::AssistedSession).to receive(:fetch).with(apply.id).and_return(nil) }

    it 'trusts the confirmation' do
      expect(result).to be_success
      expect(apply.reload.status).to eq('completed')
    end
  end
end
