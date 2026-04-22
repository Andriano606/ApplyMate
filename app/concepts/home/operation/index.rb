# frozen_string_literal: true

class Home::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize
    result = run_operation Vacancy::Operation::Index, { params:, current_user: }
    self.model = ApplyMate::Operation::Struct.new(vacancies: result.model)
  end
end
