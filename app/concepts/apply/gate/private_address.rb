# frozen_string_literal: true

# A page or hop on a non-public address (design §9.3). Every HTTP hop already went through GuardedFetch (a private
# one raised UnsafeUrlError before the request) and Session#goto guards top-level navigation; this gate catches what
# neither saw, without DNS: a current URL or hop whose host is localhost or a literal private IP (a frame the browser
# loaded, evidence rebuilt from elsewhere). -> Halt(:private_address).
class Apply::Gate::PrivateAddress < Apply::Gate::Base
  def self.events
    %i[http_resolved after_goto]
  end

  def call(_ctx, evidence:, **)
    url = (evidence.current_urls + evidence.hops).find do |candidate|
      ApplyMate::Net::Operation::ResolvePublicAddress.literal_private?(host(candidate))
    end
    halt!(:private_address, detail: url) if url
  end
end
