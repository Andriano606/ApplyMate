# frozen_string_literal: true

# One authorized way to open a stored file (CV PDF, screenshot) of a record: answers with a short-lived storage
# URL the controller redirects to, instead of exposing permanent blob URLs.
class Artifact::Operation::Show < ApplyMate::Operation::Base
  OWNERS = {
    'apply' => { klass: Apply, names: %w[cv screenshot], policy_query: :show? },
    'vacancy_cv' => { klass: VacancyCv, names: %w[cv], policy_query: :show? }
  }.freeze

  URL_TTL = 5.minutes

  def perform!(params:, current_user:, **)
    owner = OWNERS.fetch(params[:owner].to_s) { raise ActiveRecord::RecordNotFound }
    record = policy_scope(owner[:klass]).find(params[:id])
    authorize! record, owner[:policy_query]
    raise ActiveRecord::RecordNotFound if owner[:names].exclude?(params[:name].to_s)

    attachment = record.public_send(params[:name])
    raise ActiveRecord::RecordNotFound unless attachment.attached?

    disposition = params[:disposition] == 'attachment' ? 'attachment' : 'inline'
    self.model = ApplyMate::Operation::Struct.new(url: attachment.url(expires_in: URL_TTL, disposition:))
  end
end
