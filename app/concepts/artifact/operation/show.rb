# frozen_string_literal: true

# One authorized way to open a stored file (CV PDF, screenshot) of a record: answers with a short-lived storage
# URL the controller redirects to, instead of exposing permanent blob URLs.
class Artifact::Operation::Show < ApplyMate::Operation::Base
  OWNERS = {
    'apply' => { klass: Apply, names: %w[cv screenshot], policy_query: :show? },
    'vacancy_cv' => { klass: VacancyCv, names: %w[cv], policy_query: :show? },
    # `name` is the 1-based position of one of the step's `artifacts` (failure screenshots / HTML), resolved by
    # ApplyStep#artifact_at; URLs never carry the global attachment id.
    'apply_step' => { klass: ApplyStep, names: :artifact_at, policy_query: :show? }
  }.freeze

  URL_TTL = 5.minutes
  # Stored page snapshots (CaptureArtifact's failure HTML): always a download, never rendered on our origin, even
  # though SanitizeHtml already made them inert.
  DOWNLOAD_ONLY = %r{\A(?:text/html|application/xhtml\+xml)\b}i

  def perform!(params:, current_user:, **)
    owner = OWNERS.fetch(params[:owner].to_s) { raise ActiveRecord::RecordNotFound }
    record = policy_scope(owner[:klass]).find(params[:id])
    authorize! record, owner[:policy_query]
    attachment = find_attachment(record, owner[:names], params[:name].to_s)

    disposition = params[:disposition] == 'attachment' || DOWNLOAD_ONLY.match?(attachment.content_type.to_s) ? 'attachment' : 'inline'
    self.model = ApplyMate::Operation::Struct.new(url: attachment.url(expires_in: URL_TTL, disposition:))
  end

  private

  # A fixed list of single-attachment names, or a record method (Symbol) resolving a 1-based position.
  def find_attachment(record, names, name)
    if names.is_a?(Symbol)
      return record.public_send(names, Integer(name, 10, exception: false)) || raise(ActiveRecord::RecordNotFound)
    end

    raise ActiveRecord::RecordNotFound if names.exclude?(name)

    attachment = record.public_send(name)
    raise ActiveRecord::RecordNotFound unless attachment.attached?

    attachment
  end
end
