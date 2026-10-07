# Result of Session#goto: HTTP status of the navigation response (nil for same-document navigations), the URL after
# redirects/challenge, and the Cloudflare wait outcome (Operation::WaitPastCloudflare).
ApplyMate::Client::Browser::NavResult = Data.define(:status, :final_url, :challenge_passed, :was_challenge)
