# frozen_string_literal: true

# SameSite=None is required so that the session cookie is included
# in cross-site POST requests (e.g. WayForPay returnUrl redirect).
# Requires Secure=true, which is safe since the app runs over HTTPS.
# Note: in development we do NOT set secure:true so that both localhost:3000
# and a Caddy HTTPS proxy (e.g. dev.applymate.io) work simultaneously.
if Rails.env.production? || Rails.env.staging?
  Rails.application.config.session_store :cookie_store,
                                         key: '_apply_mate_session',
                                         same_site: :none,
                                         secure: true
end
