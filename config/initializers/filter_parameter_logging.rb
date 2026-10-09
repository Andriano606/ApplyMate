# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# /\Acode\z/: the one-time code an apply waits for (Apply::Operation::ProvideInput's `code` param) - an exact key match,
# because a partial :code would also hide postal_code / country_code and the like.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc, /\Acode\z/
]
