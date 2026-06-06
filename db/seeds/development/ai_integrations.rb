# frozen_string_literal: true

require 'json'

# Only the Gemini scraping integration (no API key/model required).
# `create` is used (not `upsert`) so encrypted columns go through Active Record encryption.
attrs = JSON.parse(Rails.root.join('db/seeds/development/ai_integration.json').read).symbolize_keys

ai = ai_integrations.create :gemini_scraping,
                            unique_by: %i[user_id provider],
                            user_id: users.andrii.id,
                            **attrs

users.andrii.update!(default_ai_integration_id: ai.id)
