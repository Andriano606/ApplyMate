# frozen_string_literal: true

# The one HTTP fetch of an untrusted URL (one that came from a page, an AI or a redirect): ResolvePublicAddress
# (raises ApplyMate::Net::UnsafeUrlError before any request), then ONE request over ImpersonateHttp pinned to the
# checked address (curl --resolve). Redirects are not followed: the 3xx comes back as the model, and a caller that
# walks redirects (DetectPlatform) sends every Location through GuardedFetch again, so every hop is checked and
# pinned. model = ApplyMate::Client::Response.
#
# `http` must be an ImpersonateHttp without a proxy: AsyncHttp cannot pin an address (its `**` would silently drop
# `resolve:`), and a proxy resolves the host itself.
class ApplyMate::Net::Operation::GuardedFetch < ApplyMate::Operation::Base
  METHODS = %i[get post].freeze

  def perform!(url:, http:, method: :get, body: nil, headers: {}, **)
    skip_authorize
    raise ArgumentError, "GuardedFetch needs ImpersonateHttp (it pins the address), got #{http.class}" \
      unless http.is_a?(ApplyMate::Client::ImpersonateHttp)
    raise ArgumentError, "unknown method #{method.inspect}" unless METHODS.include?(method)

    resolve = ApplyMate::Net::Operation::ResolvePublicAddress.call(url:).model
    self.model = if method == :get
                   http.get(url, headers:, follow_redirects: false, resolve:)
    else
                   http.post(url, body:, headers:, resolve:)
    end
  end
end
