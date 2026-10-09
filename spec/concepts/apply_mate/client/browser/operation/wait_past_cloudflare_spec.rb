# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::WaitPastCloudflare do
  let(:clock) { ApplyMate::Client::Browser::Clock }
  let(:now) { [ 0.0 ] }
  let(:challenge) { '<html><head><title>Just a moment...</title></head><body><div id="cf-chl-widget"></div></body>' }
  let(:real_page) { '<html><head><title>Careers</title></head><body><h1>Ruby Developer</h1></body></html>' }
  let(:real_text) { 'Ruby Developer. We are looking for an engineer who writes tests first and ships every day.' }
  # Pages served poll by poll (the last one repeats). Driver primitives used by the operation only.
  let(:driver_class) do
    Struct.new(:pages, :text, :moves, :wheels) do
      def remaining_ms
        600_000
      end

      # The operation reads the title first on every poll: that read moves to the next page.
      def title
        @current = pages.size > 1 ? pages.shift : pages.first
        @current[%r{<title>(.*?)</title>}, 1].to_s
      end

      def content
        @current
      end

      def main_frame
        :main
      end

      def evaluate(_frame, _js, _arg = nil)
        text
      end

      def mouse_move(*)
        self.moves += 1
      end

      def mouse_wheel(*)
        self.wheels += 1
      end
    end
  end

  before do
    allow(clock).to receive(:now_ms) { now.first }
    allow(clock).to receive(:sleep_ms) { |milliseconds| now[0] += milliseconds }
  end

  def run(driver, max_ms: 40_000)
    described_class.call(driver:, max_ms:).model
  end

  it 'returns [true, false] after two polls on a page that was never challenged' do
    driver = driver_class.new([ real_page ], real_text, 0, 0)

    expect(run(driver)).to eq([ true, false ])
    expect(clock).to have_received(:sleep_ms).with(300).once
    expect(driver.moves).to eq(0)
  end

  it 'does not take the bot-management script of an ordinary page for a challenge' do
    page = real_page.sub('</body>', "<script>s.src='/cdn-cgi/challenge-platform/scripts/jsd/main.js'</script></body>")

    expect(run(driver_class.new([ page ], real_text, 0, 0))).to eq([ true, false ])
  end

  it 'moves the mouse while challenged and returns [true, true] once real content shows' do
    driver = driver_class.new([ challenge, challenge, challenge, real_page ], real_text, 0, 0)

    expect(run(driver)).to eq([ true, true ])
    expect(driver.moves).to eq(3)
    expect(driver.wheels).to eq(1) # every 3rd poll
  end

  it 'waits for content after the challenge clears, up to 2 s from the start' do
    driver = driver_class.new([ challenge, real_page ], 'Loading', 0, 0)

    expect(run(driver)).to eq([ true, true ])
    expect(now.first).to be > 2_000
  end

  it 'returns [false, true] at max_ms while the challenge stays' do
    driver = driver_class.new([ challenge ], '', 0, 0)

    expect(run(driver, max_ms: 10_000)).to eq([ false, true ])
    expect(now.first).to be_between(10_000, 11_400)
  end

  it 'never polls past the time left before the deadline' do
    driver = driver_class.new([ challenge ], '', 0, 0)
    allow(driver).to receive(:remaining_ms).and_return(3_000)

    expect(run(driver)).to eq([ false, true ])
    expect(now.first).to be < 3_000 + 1_400
  end

  it 'treats a read that fails mid-navigation as an empty read' do
    driver = driver_class.new([ challenge, real_page ], real_text, 0, 0)
    calls = 0
    allow(driver).to receive(:title).and_wrap_original do |original|
      calls += 1
      original.call.tap { raise Playwright::Error.new(message: 'page is navigating') if calls == 2 }
    end

    expect(run(driver)).to eq([ true, true ])
  end
end
