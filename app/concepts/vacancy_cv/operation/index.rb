# frozen_string_literal: true

# Every CV the current user has for a vacancy, newest first: manual VacancyCvs plus CVs generated during
# an apply (attached, or still generating). Both respond to cv, user_profile, ai_integration,
# generate_cv_prompt, vacancy, created_at and hashid, which is all VacancyCv::Component::CvContent reads.
# Also called by VacancyCv::TurboHandler::Index.broadcast so live updates render the same list.
class VacancyCv::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.find(params[:vacancy_id])
    authorize! VacancyCv.new, :index?
    # Both ride their *_on_vacancy_id index; a vacancy has a handful of CVs/applies per user.
    vacancy_cvs = policy_scope(VacancyCv).where(vacancy:)
                                         .includes(:user_profile, :ai_integration, :generate_cv_prompt)
                                         .with_attached_cv
    apply_cvs   = policy_scope(Apply).where(vacancy:)
                                     .with_cv_or_generating_cv
                                     .includes(:user_profile, :ai_integration, :generate_cv_prompt)
                                     .with_attached_cv
    cvs = (vacancy_cvs.to_a + apply_cvs.to_a).sort_by(&:created_at).reverse

    self.model = ApplyMate::Operation::Struct.new(vacancy:, cvs:)
  end
end
