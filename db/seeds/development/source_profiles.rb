# frozen_string_literal: true

require 'json'

# External job-board accounts. `session_id` is encrypted, so `create` (not `upsert`)
# is used to route the value through Active Record encryption.
source_ids = Source.pluck(:name, :id).to_h

Rails.root.join('db/seeds/development/source_profiles.jsonl').each_line(chomp: true) do |line|
  next if line.strip.empty?

  attrs = JSON.parse(line).symbolize_keys
  source_id = source_ids.fetch(attrs.delete(:source_name))

  source_profiles.create unique_by: %i[user_id source_id name],
                         user_id: users.andrii.id,
                         source_id:,
                         **attrs
end
