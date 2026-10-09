# frozen_string_literal: true

# Parks the run until the user types a code the site asked for (design §10.4, Gate::EmailCode). The submit is already
# claimed; this only waits for the confirmation step.
#
#   1. expires_at = now + min(MAX_WAIT, ctx.remaining - RESERVE); nothing left -> Halt(:email_code, 'no time to wait').
#   2. persist stage 'awaiting_input' + input_request {kind, requested_at, expires_at}, input_response nil, broadcast:
#      the UI shows the code box (Apply::Operation::ProvideInput stores the answer).
#   3. every POLL_INTERVAL: check the fence and read input_response of THIS run (id AND run_token, primary key).
#      The apply thread is parked here (one thread per browser slot); the heartbeat TimerTask keeps the row alive.
#   4. no answer by expires_at -> clear the request, back to stage 'submit', Halt(:email_code): the claim rule turns it
#      into submit_unverified.
#   5. code received -> clear request + response, write it through SetFieldValue (read-back; a Mismatch is
#      Halt(:email_code, 'code not accepted')), click the ONE visible submit_like button of the frame (else press
#      Enter in the input), settle(:submit). Verify then runs as usual.
# Termination: the loop ends at expires_at <= MAX_WAIT; every pass checks the fence. The code never reaches the trace.
class Apply::Operation::Engine::AwaitInput < ApplyMate::Operation::Base
  POLL_INTERVAL = 3
  MAX_WAIT = 5.minutes
  RESERVE = 60

  def perform!(ctx:, kind:, field_element:, frame:, **)
    skip_authorize
    @ctx = ctx
    code = wait_for_code(kind)
    enter(code, field_element, frame)
    ctx.trace(:email_code_entered, kind:)
    self.model = true
  end

  private

  attr_reader :ctx

  def wait_for_code(kind)
    now = Time.current
    window = [ MAX_WAIT, ctx.remaining - RESERVE ].min
    halt!('no time to wait') if window <= 0

    expires_at = now + window
    ctx.persist!(stage: 'awaiting_input', input_response: nil,
                 input_request: { 'kind' => kind, 'requested_at' => now.iso8601, 'expires_at' => expires_at.iso8601 })
    broadcast
    code = poll(expires_at)
    ctx.persist!(input_request: nil, input_response: nil, stage: 'submit')
    broadcast
    halt! if code.nil?
    code
  end

  def poll(expires_at)
    while Time.current < expires_at
      ctx.check_fence!
      response = Apply.where(id: ctx.apply.id, run_token: ctx.run_token).pick(:input_response)
      return response['code'].to_s if response.present? && response['code'].present?

      sleep POLL_INTERVAL
    end
    nil
  end

  def broadcast
    Apply::Operation::Engine::Broadcast.call(apply: ctx.apply)
  end

  def enter(code, element, frame)
    field = Apply::Field.new(**Apply::Field.members.index_with(nil), id: 'email_code', kind: 'text', label: element['name'].to_s,
                                                                  required: true, target: element['target'])
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value: code)
    confirm(element, frame)
    ctx.session.settle(:submit)
  rescue Apply::Widget::Mismatch
    halt!('code not accepted')
  end

  def confirm(element, frame)
    snapshot = ctx.session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
    buttons = snapshot.elements.select do |candidate|
      candidate['frame'] == frame['ref'] && candidate['submit_like'] && candidate['visible']
    end
    if buttons.one?
      ctx.session.click(buttons.first['target'])
    else
      ctx.session.press(element['target'], 'Enter')
    end
  end

  def halt!(detail = nil)
    raise Apply::Operation::Engine::Halt.new(:email_code, detail:)
  end
end
