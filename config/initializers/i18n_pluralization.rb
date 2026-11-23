# frozen_string_literal: true

# Lets locales define their own plural rules (config/locales/plurals.rb):
# without it I18n only knows one/other, so Ukrainian `few`/`many` keys were
# never picked ("6 відгуку" instead of "6 відгуків").
require 'i18n/backend/pluralization'

I18n::Backend::Simple.include(I18n::Backend::Pluralization)
