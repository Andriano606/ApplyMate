# frozen_string_literal: true

# The conversation under one feedback: replies in posting order and, for the
# people allowed to answer (admins, the feedback's author), a collapsed reply form.
class FeedbackReply::Component::Thread < ApplyMate::Component::Base
  NEW_BADGE_CLASSES = 'rounded-full bg-indigo-600 px-1.5 py-0.5 text-[11px] font-semibold text-white'

  def initialize(feedback:, viewer:, new_reply_ids: [])
    @feedback = feedback
    @viewer = viewer
    @new_reply_ids = new_reply_ids
  end

  def render?
    replies.any? || show_form?
  end

  private

  attr_reader :feedback

  def replies
    feedback.replies
  end

  def can_reply?
    # FeedbackReply.new(feedback:) does not join the loaded replies collection.
    @can_reply = FeedbackReplyPolicy.new(@viewer, new_reply).create? if @can_reply.nil?
    @can_reply
  end

  # Admins can open a thread under anyone else's review; under your own review
  # the form appears once someone replied — otherwise it reads as replying to yourself.
  def show_form?
    can_reply? && (replies.any? || feedback.user_id != @viewer.id)
  end

  def new_reply
    @new_reply ||= FeedbackReply.new(feedback:)
  end

  def new?(reply)
    @new_reply_ids.include?(reply.id)
  end

  def bubble_classes(reply)
    base = 'min-w-0 flex-1 rounded-lg px-3 py-2'
    new?(reply) ? "#{base} bg-indigo-50 ring-1 ring-indigo-200 dark:bg-indigo-900/30 dark:ring-indigo-800" : "#{base} bg-gray-50 dark:bg-gray-900/40"
  end

  ROLE_BADGE_CLASSES = {
    admin: 'bg-indigo-100 text-indigo-700 dark:bg-indigo-900/50 dark:text-indigo-300',
    author: 'bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300'
  }.freeze

  def role_badge(reply)
    role = reply.role
    [ I18n.t("feedback_reply.thread.#{role}"), ROLE_BADGE_CLASSES.fetch(role) ] if role
  end

  def time(reply)
    helpers.l(reply.created_at, format: :long)
  end
end
