# frozen_string_literal: true

# :browser specs of the form-filling engine (Apply::Widget::*, Engine::SetFieldValue / GuardAction / ReachForm):
# a real Session (browserd) on a FixtureSite page, opened as `ctx`'s survey scope.
#
#   on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |session, fields|
#     field = fields.find { |candidate| candidate.label == 'Full name' }
#     Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value: 'Jane Doe')
#   end
#
# `fields` come from the production discovery (Engine::FormElements.snapshot + BuildFieldInventory) after the form
# root holds at least one visible control, so a widget spec also proves that discovery picked the right widget.
# `scope:` (default :survey) is the Context scope the session is published as (:submit: the drivers type with jitter).
# `in_fixture_scope(ctx) { |session| ... }` opens the scope only (about:blank, e.g. for ReachForm).
module FixtureFormHelpers
  FIXTURE_FORM_DEADLINE = 3.minutes

  def fixture_form_owner
    "#{ApplyMate::Client::Browser::Browserd.owner_prefix}#{Process.pid}:fixture-form"
  end

  def on_fixture_form(ctx, url, form_root:, scope: :survey)
    in_fixture_scope(ctx, scope:) do |session|
      session.goto(url)
      root = ApplyMate::Client::Browser::Target.css(form_root)
      raise "#{url}: #{form_root} never rendered" unless session.ready?(root, timeout: 10)

      ctx.form_root = root
      yield session, discover_fixture_fields(ctx)
    end
  end

  # A real Session on about:blank, published as `ctx`'s `scope` like the Runner does (Context#open_scope!).
  def in_fixture_scope(ctx, scope: :survey)
    deadline = FIXTURE_FORM_DEADLINE.from_now
    ApplyMate::Client::Browser::Session.open(deadline:, owner: fixture_form_owner) do |session|
      ctx.open_scope!(scope, session, session.deadline)
      yield session
    ensure
      ctx.close_scope!
    end
  end

  FIXTURE_ASHBY_JID = FixtureAshby::JID

  # Apply::Platform::Ashby on FixtureSite (spec/support/fixture_ashby_platform.rb).
  def fixture_ashby_class
    FixtureAshby
  end

  # Adopts the FixtureSite Ashby (slug preply, the fixture posting's jid) with the schema it reads from FixtureSite,
  # so discovery merges it like in production (ids "ashby:<path>", schema kinds). The adapter instance is set on the
  # scratch directly: Context#adopt_match! would build the production class from the registry.
  def adopt_fixture_ashby!(ctx, jid: FIXTURE_ASHBY_JID)
    match = Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => jid },
                                                        frame_path: nil, from_alias: false, probable: nil)
    ctx.scratch.match = match
    ctx.scratch.platform = fixture_ashby_class.new(ctx:, match:)
    ctx.schema = ctx.platform.fetch_schema
  end

  def discover_fixture_fields(ctx)
    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    Apply::Operation::Engine::BuildFieldInventory.call(ctx:, snapshot:).model
  end

  def fixture_field(fields, label)
    fields.find { |field| field.label == label } || raise("no field #{label.inspect} in #{fields.map(&:label).inspect}")
  end
end

RSpec.configure { |config| config.include FixtureFormHelpers }
