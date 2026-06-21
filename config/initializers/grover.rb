# frozen_string_literal: true

# grover рендерить HTML -> PDF через puppeteer-core, який не завантажує власний
# Chromium, тому йому треба явно вказати шлях до встановленого Chrome.
chrome_path = ENV['GROVER_CHROME_PATH'].presence ||
              %w[
                /usr/bin/google-chrome
                /usr/bin/google-chrome-stable
                /usr/bin/chromium
                /usr/bin/chromium-browser
              ].find { |path| File.executable?(path) }

Grover.configure do |config|
  config.options = {
    executable_path: chrome_path,
    launch_args: [ '--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage' ]
  }
end
