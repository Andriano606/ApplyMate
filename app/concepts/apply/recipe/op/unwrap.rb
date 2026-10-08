# frozen_string_literal: true

# A goto of the platform's canonical form URL (the form outside its embed / description page). Recorded separately
# from `goto` so a stored navigation says WHY the URL was opened; ReachForm opens it at most once per platform per
# session.
class Apply::Recipe::Op::Unwrap < Apply::Recipe::Op::Goto
end
