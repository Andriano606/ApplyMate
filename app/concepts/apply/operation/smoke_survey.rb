# frozen_string_literal: true

# Dev/staging tooling (`bin/rails 'apply:smoke[<apply hashid>,<entry url>]'`): a READ-ONLY survey of one throwaway
# queued apply's application form through the real engine stages, printed to `out`. Never fills, answers or submits: only
# the four survey stages below are referenced (no AnswerFields / FillFields / ClaimSubmit / Submit), and the lease is
# opened with humanize: false like the Runner's survey scope.
#
#   StartContext (the apply must be startable: queued / waiting_capacity / stale running)
#   -> Stage::DetectPlatform (entry_url overrides applies.entry_url / vacancy.external_url) -> Stage::FetchSchema
#   -> ONE Session lease: Stage::ReachForm (for an unknown platform the AI Navigator: it may click, press, scroll,
#      switch tabs and follow links to REACH the form, never types or submits), then Stage::DiscoverFields whenever a
#      form root was set (Generic included)
#   -> report: platform, confidence, captures, probable, http hops, schema size, canonical form URL, navigation ops,
#      form reached?, AI calls of the attempt, navigator actions, form URL + frame, readiness time (ReachForm), the
#      field table, the trace events and the halt (a gate firing, the Navigator giving up)
#   The run's HTTP client is ApplyMate::Client::ImpersonateHttp::ReadOnly: every Ruby-side POST is refused before
#   curl runs, so the adapter's fetch_schema (for Ashby the ApiJobPosting GraphQL POST) fails like an unreachable
#   endpoint, is traced as schema_unavailable and the fields come from the DOM. The survey never POSTs to a
#   third-party site itself; only the page the browser loads does what it does on any visit.
#   -> ONE FencedUpdate ends the survey in `cancelled` (stage nil, run_token rotated) with every engine column the
#      stages persisted restored. No apply_steps rows are written (the Runner is not involved); attempt keeps its +1.
#
# Why cancelled and never back to queued: queued is an IN_PROGRESS state, so a queued row would be picked up by
# ReapStale (verdict lost -> auto-resume -> Engine::Enqueue) or by the job Create enqueued, and the FULL engine would
# then fill and submit a real application (review_policy never + auto_consent true pass ReviewGate). cancelled is not
# startable (StartContext refuses it) and the rotated run_token fences any job already in flight. So the survey must
# be pointed at a THROWAWAY apply; create a new one to apply for real.
#
# The Runner's Heartbeat ticker runs for the whole survey (shut down before the cancelling write): the row is `running`
# with no Solid Queue job behind it, and a Navigator alone may take MAX_SECONDS (= STALE_AFTER) plus its slow-AI
# allowance. Without the beat ReapStale would judge a long survey lost and auto-resume it, i.e. enqueue the FULL engine
# (fill + submit) on this throwaway row.
class Apply::Operation::SmokeSurvey < ApplyMate::Operation::Base
  RESTORED_COLUMNS = %w[platform platform_match apply_key entry_url landing_url fields form_url navigation].freeze
  STAGES = Apply::Operation::Stage
  FIELD_COLUMNS = %w[id kind widget label required options frame].freeze

  def perform!(apply:, entry_url: nil, out: $stdout, **)
    skip_authorize
    original = apply.slice(*RESTORED_COLUMNS)
    ctx = Apply::Operation::Engine::StartContext.call(apply:).model
    ctx.scratch.http = ApplyMate::Client::ImpersonateHttp::ReadOnly.new(
      request_timeout: Apply::Operation::Engine::Context::HTTP_TIMEOUT
    )
    ticker = Apply::Operation::Engine::Heartbeat.call(ctx:).model
    begin
      ctx.persist!(entry_url:) if entry_url.present?
      survey(ctx)
    rescue Apply::Operation::Engine::Halt => e
      report[:halt] = { code: e.code, detail: e.detail }
    ensure
      ticker.shutdown
      report[:trace] = ctx.scratch.trace.map { |entry| entry['event'] }
      restore!(ctx, original)
    end
    print_report(out)
    self.model = report
  end

  private

  def report
    @report ||= {}
  end

  def survey(ctx)
    STAGES::DetectPlatform.call(ctx:)
    record_detection(ctx)
    STAGES::FetchSchema.call(ctx:)
    report[:schema_api] = Array(ctx.schema).size
    in_lease(ctx) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      STAGES::ReachForm.call(ctx:)
      report[:readiness_seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
      record_detection(ctx)
      report[:schema_api] = Array(ctx.schema).size
      report[:form_url] = ctx.form_url
      report[:navigation] = ctx.apply.navigation
      report[:form_frame] = frame_of(ctx.form_root)
      STAGES::DiscoverFields.call(ctx:) if ctx.form_root
    end
  ensure
    report[:form_reached] = !ctx.form_root.nil?
    report[:ai_calls] = ctx.apply.reload.ai_calls
    report[:navigator_actions] = ctx.scratch.trace.count { |entry| entry['event'] == 'navigate' }
    report[:fields] = Array(ctx.fields).map { |field| field_row(field) }
  end

  # The same lease the Runner opens for the :survey scope.
  def in_lease(ctx)
    ApplyMate::Client::Browser::Session.open(deadline: ctx.scope_deadline, owner: ApplyMate::Client::Browser::Session.owner_for(ctx.apply),
                                             humanize: false, identity: ctx.apply.hashid) do |session|
      ctx.open_scope!(:survey, session, session.deadline)
      yield
    end
  ensure
    ctx.close_scope!
  end

  def record_detection(ctx)
    match = ctx.match
    report[:platform] = match&.key
    report[:confidence] = match&.confidence
    report[:captures] = match&.captures
    report[:probable] = match&.probable&.key
    report[:hops] = ctx.evidence&.hops
    report[:canonical_form_url] = ctx.platform&.canonical_form_url
  end

  def field_row(field)
    options = field.options
    { 'id' => field.id, 'kind' => field.kind, 'widget' => field.widget, 'label' => field.label.to_s.truncate(60),
      'required' => field.required ? 'yes' : 'no', 'options' => options.is_a?(Array) ? options.size : options.to_s,
      'frame' => frame_of(field.target) }
  end

  def frame_of(target)
    path = target.respond_to?(:frame_path) ? Array(target.frame_path) : []
    path.empty? ? 'top' : path.join(' > ')
  end

  def restore!(ctx, original)
    attributes = original.symbolize_keys.merge(state: :cancelled, stage: nil, run_token: SecureRandom.uuid)
    Apply::Operation::Engine::FencedUpdate.call(ctx:, attributes:)
  end

  def print_report(out)
    out.puts "platform:   #{report[:platform] || '-'} (confidence #{report[:confidence] || '-'}, " \
             "probable #{report[:probable] || '-'})"
    out.puts "captures:   #{report[:captures].to_json}"
    out.puts "http hops:  #{Array(report[:hops]).join(' -> ')}"
    out.puts "schema api: #{report[:schema_api].to_i} field(s)"
    out.puts "canonical:  #{report[:canonical_form_url] || '-'}"
    out.puts "navigation: #{Array(report[:navigation]).map { |op| op['op'] }.join(' -> ').presence || '-'}"
    out.puts "navigator:  #{report[:navigator_actions].to_i} action(s), form reached #{report[:form_reached] ? 'yes' : 'no'}"
    out.puts "ai calls:   #{report[:ai_calls].to_i}"
    out.puts "form url:   #{report[:form_url] || '-'} (frame #{report[:form_frame] || '-'})"
    out.puts "readiness:  #{report[:readiness_seconds] ? "#{report[:readiness_seconds]} s" : '-'}"
    out.puts "halt:       #{report[:halt] ? "#{report[:halt][:code]} (#{report[:halt][:detail]})" : 'none'}"
    out.puts "trace:      #{report[:trace].join(', ')}"
    print_fields(out, Array(report[:fields]))
  end

  def print_fields(out, rows)
    out.puts "fields (#{rows.size}):"
    return if rows.empty?

    widths = FIELD_COLUMNS.to_h { |column| [ column, ([ column ] + rows.map { |row| row[column].to_s }).map(&:size).max ] }
    line = ->(values) { FIELD_COLUMNS.map { |column| values[column].to_s.ljust(widths[column]) }.join(' | ') }
    out.puts line.call(FIELD_COLUMNS.to_h { |column| [ column, column ] })
    rows.each { |row| out.puts line.call(row) }
  end
end
