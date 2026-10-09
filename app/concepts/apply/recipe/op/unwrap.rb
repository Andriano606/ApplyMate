# frozen_string_literal: true

# A goto of the platform's canonical form URL (the form outside its embed / description page). Recorded separately
# from `goto` so a stored navigation says WHY the URL was opened. Marks the platform in
# ctx.scratch.canonical_unwrapped: Engine::ReachForm opens a platform's canonical URL at most once per session, whoever
# ran the unwrap (its own canonical path or a replayed navigation).
class Apply::Recipe::Op::Unwrap < Apply::Recipe::Op::Goto
  def perform!(ctx)
    result = super
    unwrapped = ctx.scratch.canonical_unwrapped
    key = ctx.platform.class.key
    unwrapped << key unless unwrapped.include?(key)
    result
  end
end
