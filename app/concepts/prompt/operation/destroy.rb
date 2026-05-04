# frozen_string_literal: true

class Prompt::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.prompts.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('prompt.destroy.success'))
  end
end
