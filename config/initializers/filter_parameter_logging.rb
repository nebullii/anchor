# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# Anchor handles GitHub/Google OAuth tokens, GCP service-account keys and
# users' app secrets, so this list errs on the side of filtering too much.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :authorization, :bearer, :credential, :private, :cookie, :session, :value,
  # OAuth callback parameters: the authorization code is exchangeable for a
  # token until used, and `state` is the CSRF binding. Exact match only, so
  # e.g. `commit_code` or `statement` aren't swallowed.
  /\Acode\z/i, /\Astate\z/i
]
