# frozen_string_literal: true

require 'rails_helper'

# Covers the web path the buttons actually take (route → controller → endpoint →
# operation → redirect). The operation specs stub the browser but never proved
# a click reaches them.
RSpec.describe 'Assisted apply', type: :request do
  include_context 'honeytech dou'

  before do
    allow(browser).to receive(:detach).and_return(browser)
    allow(browser).to receive(:close_stale_tabs)
    allow(browser).to receive(:bring_to_front)
    allow(browser).to receive(:set_checkbox_by_handle)
    allow(Apply::AssistedSession).to receive(:store)
    allow(Apply::AssistedSession).to receive(:fetch).and_return(browser)
    allow(Apply::AssistedSession).to receive(:close)

    apply.update!(
      status:        :needs_review,
      resolved_url:  HoneytechDou::PEOPLEFORCE_URL,
      filled_inputs: filled_inputs.map { |i| i.merge('fingerprint' => fingerprint_of(i)) }
    )
  end

  describe 'POST /applies/:id/assisted_fill' do
    subject(:send_request) do
      post assisted_fill_apply_path(apply), headers: { 'HTTP_ACCEPT' => 'text/html' }
    end

    context 'when signed in as the owner' do
      before { allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user) }

      it 'redirects back to the apply page' do
        send_request
        expect(response).to redirect_to(apply_path(apply))
      end

      it 'fills the form and marks the apply as waiting for a manual submit' do
        send_request
        expect(browser).to have_received(:type_by_handle).with(0, 'Jane Doe')
        expect(apply.reload.status).to eq('awaiting_manual_submit')
      end
    end

    # No rescue_from for Pundit in ApplicationController — an unauthorized POST
    # raises rather than redirecting. Asserted so the behaviour is deliberate.
    context 'when signed out' do
      it 'refuses to touch the browser or the apply' do
        expect { send_request }.to raise_error(Pundit::NotAuthorizedError)
        expect(browser).not_to have_received(:type_by_handle)
        expect(apply.reload.status).to eq('needs_review')
      end
    end
  end

  describe 'POST /applies/:id/confirm_manual_submit' do
    before do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      apply.update!(status: :awaiting_manual_submit)
    end

    it 'completes the apply and redirects back' do
      post confirm_manual_submit_apply_path(apply), headers: { 'HTTP_ACCEPT' => 'text/html' }
      expect(response).to redirect_to(apply_path(apply))
      expect(apply.reload.status).to eq('completed')
    end
  end
end
