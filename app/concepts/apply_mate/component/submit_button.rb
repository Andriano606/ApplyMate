# frozen_string_literal: true

class ApplyMate::Component::SubmitButton < ApplyMate::Component::Base
  def initialize(model:, submit_text:, form_id:)
    @model = model
    @submit_text = submit_text
    @form_id = form_id
  end

  private

  def submit_button_class
    if new_record?
      'bg-green-600 hover:bg-green-700'
    else
      'bg-blue-600 hover:bg-blue-700'
    end
  end

  def new_record?
    @model.respond_to?(:new_record?) && @model.new_record?
  end
end
