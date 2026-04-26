# frozen_string_literal: true

module ApplyMate::Component::Helper
  extend ActiveSupport::Concern

  def header(title:, back_link: nil, back_text: nil, &block)
    render(ApplyMate::Component::Header.new(title:, back_link:, back_text:), &block)
  end

  def boolean_link(form:, name:, label: nil, icon: nil, **options)
    render(ApplyMate::Component::BooleanLink.new(form:, name:, label:, icon:, **options))
  end

  def button(label: nil, icon: nil, variant: :secondary, tag: :button, **options, &block)
    render(ApplyMate::Component::Button.new(label:, icon:, variant:, tag:, **options), &block)
  end

  def file_drop(form:, field:, accept:, hint: nil, formats_label: nil, multiple: false, **options)
    render(ApplyMate::Component::FileDrop.new(form:, field:, accept:, hint:, formats_label:, multiple:, **options))
  end

  def turbo_form_modal(model:, endpoint:, header_text:, submit_text:, size: :md, multipart: false, &block)
    render(ApplyMate::Component::TurboFormModal.new(model:, endpoint:, header_text:, submit_text:, size:, multipart:), &block)
  end

  def debug_button(path:, text:, **options)
    render(ApplyMate::Component::DebugButton.new(path:, text:, **options))
  end

  def debug_text(text:)
    render(ApplyMate::Component::DebugText.new(text:))
  end

  def badge(label:, color: :gray, variant: :pill)
    render(ApplyMate::Component::Tag.new(label:, color:, variant:))
  end

  def alert(text:, type: :error)
    render(ApplyMate::Component::Alert.new(text:, type:))
  end

  def select_option(form:, radio_attribute:, radio_value:, radio_name:, selected:, &block)
    render(ApplyMate::Component::SelectOption.new(form:, radio_attribute:, radio_value:, radio_name:, selected:), &block)
  end

  def radio_button(form:, attribute:, value:, label:, icon_name:, input_html: {})
    render(ApplyMate::Component::RadioButton.new(form:, attribute:, value:, label:, icon_name:, input_html:))
  end

  def data_test_id(value)
    return {} if Rails.env.production?

    { 'data-test-id': value }
  end
end
