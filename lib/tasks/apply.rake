# frozen_string_literal: true

namespace :apply do
  # READ-ONLY survey of one queued apply's application form (dev/staging tooling, Apply::Operation::SmokeSurvey):
  # detection, schema, one browser lease reaching the form and listing its fields. Never fills or submits.
  # Use a THROWAWAY apply: the survey ends it in `cancelled` (engine columns restored, run_token rotated), because a
  # queued row would be picked up by the reaper or a pending job and run the full engine, submit included.
  # Needs BROWSERD_URL / BROWSERD_TOKEN like the apply worker.
  #
  #   BROWSERD_URL=http://localhost:9300 bin/rails 'apply:smoke[<apply hashid>,https://dou.ua/goto/vacancy/?id=375494]'
  #
  # entry_url is optional (default: applies.entry_url, else the vacancy's external_url).
  desc 'Read-only survey of an apply form: apply:smoke[apply_hashid,entry_url]'
  task :smoke, %i[apply_hashid entry_url] => :environment do |_task, args|
    abort 'usage: apply:smoke[apply_hashid,entry_url]' if args[:apply_hashid].blank?

    Apply::Operation::SmokeSurvey.call(apply: Apply.find(args[:apply_hashid]), entry_url: args[:entry_url].presence)
  end
end
