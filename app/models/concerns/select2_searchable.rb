# frozen_string_literal: true

module Select2Searchable
  extend ActiveSupport::Concern

  class_methods do
    # Declares the text method used to build the select2 result.
    # Generates #select2_search_result automatically.
    #
    # Usage:
    #   class Material < ApplicationRecord
    #     include Select2Searchable
    #     select2_text_method :name
    #   end
    def select2_text_method(method_name)
      define_method(:select2_search_result) do
        { id:, text: public_send(method_name) }
      end
    end
  end

  def select2_search_result
    raise NotImplementedError, "#{self.class} must implement #select2_search_result or call select2_text_method :your_method"
  end
end
