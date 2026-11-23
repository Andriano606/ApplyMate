# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedbackReply::Component::Thread, type: :component do
  let(:feedback) { create(:feedback) }
  let(:author)   { feedback.user }
  let(:admin)    { create(:user, :admin) }
  let(:other)    { create(:user) }
  let(:form)     { '[data-test-id="feedback-reply-form"]' }

  def render_thread(viewer)
    render_inline(described_class.new(feedback: Feedback.includes(replies: :user).find(feedback.id), viewer:))
  end

  context 'without replies' do
    it 'shows an admin the reply form under someone else\'s review' do
      render_thread(admin)

      expect(page).to have_css(form)
      expect(page).to have_text(I18n.t('feedback_reply.form.toggle'))
    end

    it 'renders nothing for the author under their own review' do
      render_thread(author)

      expect(page).to have_no_css('[data-test-id="feedback-thread"]')
      expect(page).to have_no_css(form)
    end

    it 'renders nothing for a regular user or a guest' do
      [ other, nil ].each do |viewer|
        render_thread(viewer)

        expect(page).to have_no_css('[data-test-id="feedback-thread"]')
      end
    end
  end

  context 'with replies' do
    before do
      create(:feedback_reply, feedback:, user: admin, body: 'Admin says hi', created_at: 2.hours.ago)
      create(:feedback_reply, feedback:, user: author, body: 'Author answers', created_at: 1.hour.ago)
    end

    it 'lists them in order with Admin and Author badges' do
      render_thread(other)

      expect(page.all('[data-test-id="feedback-reply"]').map(&:text)).to match(
        [ /Admin says hi.*/m, /Author answers.*/m ]
      )
      expect(page).to have_css('[data-test-id="feedback-reply"]', text: I18n.t('feedback_reply.thread.admin'), count: 1)
      expect(page).to have_css('[data-test-id="feedback-reply"]', text: I18n.t('feedback_reply.thread.author'), count: 1)
    end

    it 'shows a non-participant the thread but no form' do
      render_thread(other)

      expect(page).to have_css('[data-test-id="feedback-thread"]')
      expect(page).to have_no_css(form)
    end

    it 'shows a guest the thread but no form' do
      render_thread(nil)

      expect(page).to have_css('[data-test-id="feedback-reply"]', count: 2)
      expect(page).to have_no_css(form)
    end

    it 'shows the author the form once somebody replied' do
      render_thread(author)

      expect(page).to have_css(form)
    end

    it 'shows an admin the form' do
      render_thread(admin)

      expect(page).to have_css(form)
    end

    it 'escapes markup in replies' do
      create(:feedback_reply, feedback:, user: admin, body: '<img src="https://evil.example/p.gif">')

      render_thread(other)

      expect(page).to have_no_css('img[src*="evil"]')
    end
  end
end
