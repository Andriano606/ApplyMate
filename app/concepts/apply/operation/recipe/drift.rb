# frozen_string_literal: true

# A recipe op no longer works on the page (a stale locator, a tab that never opened, a terminal wait_for whose root
# never filled or failed R2). `performed`: the op hashes Interpret ran before it (the page the session is on now came
# from them; Engine::ReachForm keeps them in front of the Navigator's heal ops).
class Apply::Operation::Recipe::Drift < StandardError
  attr_reader :op, :detail, :performed

  def initialize(op:, detail: nil, performed: [])
    @op = op
    @detail = detail
    @performed = performed
    super("recipe op #{op&.class&.op || '?'} drifted#{": #{detail}" if detail}")
  end
end
