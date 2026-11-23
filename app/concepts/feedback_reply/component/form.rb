# frozen_string_literal: true

# Inline reply form under a feedback, collapsed behind a "Reply" toggle until
# used; re-rendered open with the error when a reply is rejected.
class FeedbackReply::Component::Form < ApplyMate::Component::Base
  TOGGLE_CLASSES = '-mx-2 inline-flex min-h-11 cursor-pointer list-none items-center gap-1.5 rounded-md px-2 ' \
                   'text-sm font-medium text-indigo-600 hover:bg-indigo-50 hover:text-indigo-700 sm:min-h-9 ' \
                   'group-open:hidden dark:text-indigo-400 dark:hover:bg-gray-700 [&::-webkit-details-marker]:hidden'

  def self.dom_id_for(feedback)
    "feedback_#{feedback.id}_reply_form"
  end

  def initialize(reply:)
    @reply = reply
  end

  private

  attr_reader :reply

  def feedback
    reply.feedback
  end

  def open?
    reply.errors.any?
  end

  def error
    reply.errors.full_messages.first
  end

  def textarea_classes
    'block w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 ' \
      'focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500 ' \
      'dark:border-gray-600 dark:bg-gray-800 dark:text-gray-100'
  end
end
