# frozen_string_literal: true

# Opens a URL in the session (Session#goto: PublicAddressGuard, then navigation and the Cloudflare wait).
class Apply::Recipe::Op::Goto < Apply::Recipe::Op::Base
  def perform!(ctx)
    ctx.session.goto(url(ctx))
  end
end
