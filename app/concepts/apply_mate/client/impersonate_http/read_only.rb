# frozen_string_literal: true

# An ImpersonateHttp that only reads: every POST raises RequestError before curl runs. For tooling that must never
# send anything to a third-party site: Apply::Operation::SmokeSurvey puts it into ctx.scratch.http, so an adapter's
# schema read (a POST to the ATS) fails like an unreachable endpoint, the adapter traces it (schema_unavailable) and
# the engine falls back to the DOM. GETs (the redirect walk) are unchanged and still go through GuardedFetch's
# address pinning.
class ApplyMate::Client::ImpersonateHttp::ReadOnly < ApplyMate::Client::ImpersonateHttp
  def post(url, **)
    refuse!(url)
  end

  def post_multipart(url, **)
    refuse!(url)
  end

  private

  def refuse!(url)
    raise RequestError, "read-only client: POST #{url} refused"
  end
end
