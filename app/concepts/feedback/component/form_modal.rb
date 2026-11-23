# frozen_string_literal: true

class Feedback::Component::FormModal < ApplyMate::Component::Base
  def initialize(feedback:, **)
    @feedback = feedback
  end

  private

  def scope
    @feedback.persisted? ? 'edit' : 'new'
  end

  def body_input_html
    { rows: 6, maxlength: Feedback::BODY_MAX_LENGTH, placeholder: I18n.t('feedback.form.body_placeholder') }
  end

  def rating_collection
    Feedback::RATINGS.map { |rating| [ "#{rating} — #{I18n.t("feedback.sentiments.#{Feedback.sentiment_for(rating)}")}", rating ] }.reverse
  end
end
