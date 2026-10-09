# frozen_string_literal: true

# The page-side success signals (VerifySubmit::PAGE_SIGNALS) the page shows BEFORE the submit click: Stage::Submit
# stores them on ctx.scratch.submit_baseline right before the claim, and VerifySubmit never counts a signal that
# already held here (an intro "Thank you for your interest", a URL path containing "success", a confirmation view the
# page keeps hidden in its markup). Read-only, no field probes; taken before the claim, so a browser error here is
# still resumable.
#
# model = [String] the names of the page signals that held (e.g. ['success_text']), [] when none did
class Apply::Operation::Engine::SubmitBaseline < ApplyMate::Operation::Base
  def perform!(ctx:, **)
    skip_authorize
    spec = ctx.platform.success_evidence
    evidence = Apply::Operation::Engine::CollectSubmitEvidence.call(
      ctx:, field_errors: false, success_selectors: Array(spec[:selectors]), failure_selectors: Array(spec[:failure_selectors])
    ).model
    self.model = Apply::Operation::Engine::VerifySubmit.page_signals(spec, evidence).select { |_name, held| held }.keys
  end
end
