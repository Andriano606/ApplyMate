# frozen_string_literal: true

require 'json'

Rails.root.join('db/seeds/development/proxies.jsonl').each_line(chomp: true) do |line|
  proxies.upsert unique_by: %i[host port], **JSON.parse(line).symbolize_keys
end
