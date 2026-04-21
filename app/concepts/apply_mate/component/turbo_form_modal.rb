# frozen_string_literal: true

class ApplyMate::Component::TurboFormModal < ApplyMate::Component::Base
  attr_reader :model, :endpoint, :header_text, :submit_text, :size, :multipart
  attr_accessor :form

  def initialize(model:, endpoint:, header_text:, submit_text:, size: :md, multipart: false)
    @model = model
    @endpoint = endpoint
    @header_text = header_text
    @submit_text = submit_text
    @size = size
    @multipart = multipart
  end

  def modal_id
    "#{helpers.dom_id(model)}_modal"
  end

  def form_id
    "#{helpers.dom_id(model)}_form"
  end
end
