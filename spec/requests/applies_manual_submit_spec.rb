# frozen_string_literal: true

require 'rails_helper'

# Covers the web path the button actually takes (route → controller → endpoint →
# operation → redirect).
RSpec.describe 'Manual submit confirmation', type: :request do
  include_context 'honeytech dou'

  before do
    apply.update!(
      status:        :needs_review,
      resolved_url:  HoneytechDou::PEOPLEFORCE_URL,
      filled_inputs: filled_inputs.map { |i| i.merge('fingerprint' => fingerprint_of(i)) }
    )
  end

  describe 'POST /applies/:id/confirm_manual_submit' do
    before do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    end

    it 'completes the apply and redirects back' do
      post confirm_manual_submit_apply_path(apply), headers: { 'HTTP_ACCEPT' => 'text/html' }
      expect(response).to redirect_to(apply_path(apply))
      expect(apply.reload.status).to eq('completed')
    end
  end
end
