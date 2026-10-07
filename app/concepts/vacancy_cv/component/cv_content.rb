# frozen_string_literal: true

# One CV card. record: a VacancyCv (generated manually) or an Apply (generated during an apply).
class VacancyCv::Component::CvContent < ApplyMate::Component::Base
  def initialize(record:)
    @record  = record
    @vacancy = record.vacancy
  end

  private

  def title
    "#{@record.user_profile.name} · #{I18n.l(@record.created_at, format: :short)}"
  end

  def generating?
    !@record.cv.attached?
  end

  def from_apply?
    @record.is_a?(Apply)
  end

  # Artifact owner segment: ArtifactsController resolves apply/vacancy_cv records through policy_scope.
  def artifact_owner
    from_apply? ? 'apply' : 'vacancy_cv'
  end

  def cv_path(disposition)
    helpers.artifact_path(artifact_owner, @record, 'cv', disposition:)
  end

  def apply_anchor
    "##{Apply::Component::VacancyApplyCard.anchor_id(@record)}"
  end
end
