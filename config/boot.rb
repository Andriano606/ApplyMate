# frozen_string_literal: true

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)

require 'bundler/setup' # Set up gems listed in the Gemfile.

# Load env files before anything else reads ENV. `dotenv/load` only reads `.env`,
# so load env-specific files explicitly (later files don't overwrite earlier ones).
# This is what makes per-workspace isolation (APP_DB_NAME / PORT / ES_INDEX_NAMESPACE
# in .env.development.local) actually take effect.
rails_env = ENV['RAILS_ENV'] || 'development'
require 'dotenv'
Dotenv.load(*[
  ".env.#{rails_env}.local",
  ('.env.local' unless rails_env == 'test'),
  ".env.#{rails_env}",
  '.env'
].compact)

require 'bootsnap/setup' # Speed up boot time by caching expensive operations.
