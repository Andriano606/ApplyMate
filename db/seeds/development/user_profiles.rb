# frozen_string_literal: true

require 'json'

attrs = JSON.parse(Rails.root.join('db/seeds/development/user_profile.json').read).symbolize_keys

profile = user_profiles.create :andrii_profile,
                               unique_by: %i[user_id name],
                               user_id: users.andrii.id,
                               **attrs

users.andrii.update!(default_profile_id: profile.id)
