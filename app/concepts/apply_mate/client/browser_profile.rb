# frozen_string_literal: true

# Hands out reusable Chrome profile directories.
#
# A throwaway profile is the loudest anti-bot signal there is: no cookies, no
# history, no cf_clearance, every visit looking like a browser created a second
# ago. Keeping the directory between runs lets a solved Cloudflare challenge
# stick, which is the whole point of the persistent context.
#
# Chrome refuses to run two processes against the same profile (it holds a
# SingletonLock), and this pipeline is fiber-concurrent — so profiles come from a
# small pool, each guarded by an exclusive file lock. A caller that cannot get a
# slot gets nil and runs on a throwaway profile: slower to trust, never a crash
# and never a wait.
class ApplyMate::Client::BrowserProfile
  # Sized for the production host (4-core Raspberry Pi 5): each slot is a full
  # Chrome profile on disk, and more concurrent Chromes than cores buys nothing.
  POOL_SIZE = ENV.fetch('BROWSER_PROFILE_POOL', 4).to_i

  ROOT = Rails.root.join('tmp', 'browser_profiles')

  Slot = Struct.new(:path, :lock) do
    # Chrome only writes its cookie store on a clean profile shutdown, and Ferrum
    # launches it with --keep-alive-for-test, so it never shuts down cleanly — the
    # directory alone carries no cookies. They are dumped here instead.
    def cookies_file
      File.join(path, 'ferrum_cookies.yml')
    end

    def release
      lock.flock(File::LOCK_UN)
      lock.close
    rescue StandardError => e
      Rails.logger.warn("BrowserProfile: releasing #{path} failed: #{e.message}")
    end
  end

  class << self
    # name groups profiles by what they browse ("dou"), so a site's cookies are
    # reused only for that site. Returns a Slot or nil when the pool is busy.
    def acquire(name)
      POOL_SIZE.times do |slot|
        path = ROOT.join(name.to_s, slot.to_s)
        FileUtils.mkdir_p(path)

        lock = File.open(path.join('.lock'), File::RDWR | File::CREAT)
        next lock.close unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        return Slot.new(path.to_s, lock)
      end

      Rails.logger.info("BrowserProfile: all #{POOL_SIZE} '#{name}' profiles busy, using a throwaway one")
      nil
    rescue StandardError => e
      Rails.logger.warn("BrowserProfile: could not acquire '#{name}': #{e.message}")
      nil
    end

    # Profiles grow (cache, service workers) and a corrupted one makes Chrome
    # fail to boot — this is the escape hatch, and the pruning story for a
    # directory that only ever accumulates.
    def clear(name)
      FileUtils.rm_rf(ROOT.join(name.to_s))
    end
  end
end
