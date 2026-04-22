# frozen_string_literal: true

class Admin::Source::Component::Form < ApplyMate::Component::Base
  def initialize(form:, **)
    @form = form
  end

  private

  attr_reader :form

  def jsonb_sections
    model_class = form.object.class
    model_class.methods
      .grep(/\Ajsonb_store_key_mapping_for_/)
      .map { |m| m.to_s.delete_prefix('jsonb_store_key_mapping_for_') }
      .each_with_object({}) do |column, hash|
        hash[column] = model_class.public_send(:"jsonb_store_key_mapping_for_#{column}").keys
      end
  end
end
