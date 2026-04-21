# frozen_string_literal: true

class ApplyMate::Component::FileDrop < ApplyMate::Component::Base
  def initialize(form:, field:, accept:, hint: nil, formats_label: nil, multiple: false, **options)
    @form = form
    @field = field
    @accept = accept
    @hint = hint
    @formats_label = formats_label
    @multiple = multiple
    @options = options
    super()
  end

  private

  attr_reader :form, :field, :accept, :hint, :formats_label, :multiple, :options

  def errors
    form.object.errors[field]
  end
end
