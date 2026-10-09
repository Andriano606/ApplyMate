# frozen_string_literal: true

class Apply::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.applies.build
    authorize! model, :create?
    form_object = Apply::FormObject::Create.new(params[:apply])
    parse_validate_sync(form_object, model)
    ensure_reapply_confirmed!(form_object, current_user)
    save_apply!(current_user)

    # A new card joins the vacancy page panel: refresh the whole list, not just one card.
    Apply::TurboHandler::StatusUpdate.refresh(model.vacancy, current_user)
    Apply::Operation::Engine::Enqueue.call(apply: model)
    model.touch_user_applies_changed_at!
    notice(I18n.t('apply.create.success'))
  end

  private

  def ensure_reapply_confirmed!(form_object, current_user)
    return if form_object.confirm_reapply.to_b
    return unless Apply.reapply_guarded(vacancy: model.vacancy, user: current_user).exists?

    reject!(I18n.t('apply.create.reapply_confirmation_required'))
  end

  # The partial unique index index_applies_one_active_per_vacancy is the real guard against a second active apply.
  def save_apply!(current_user)
    ApplicationRecord.transaction do
      model.save!
      model.source_profile.set_as_default!
      current_user.update!(
        default_profile_id: model.user_profile_id,
        default_ai_integration_id: model.ai_integration_id,
        default_fill_form_prompt_id: model.fill_form_prompt_id,
        default_generate_cv_prompt_id: model.generate_cv_prompt_id
      )
    end
  rescue ActiveRecord::RecordNotUnique
    reject!(I18n.t('apply.create.already_active'))
  end

  def reject!(message)
    add_error(:base, message)
    raise ActiveRecord::RecordInvalid
  end
end
