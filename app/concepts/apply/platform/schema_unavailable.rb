# frozen_string_literal: true

# A platform's schema endpoint answered nothing usable (non-2xx, invalid JSON, no form). The adapter traces it and
# returns nil: the engine falls back to discovering the fields in the DOM (design §18 item 6).
class Apply::Platform::SchemaUnavailable < StandardError; end
