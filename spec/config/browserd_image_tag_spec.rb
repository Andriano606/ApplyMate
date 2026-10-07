# frozen_string_literal: true

require 'rails_helper'

# The browserd image tag is the pinned triple "<Camoufox version>-<release>-pw<playwright-core>". It is written in
# five places that nothing else ties together: docker/browserd (Dockerfile ARGs + package.json/package-lock.json),
# docker-compose.yml, config/deploy.staging.yml and Gemfile.lock (playwright-ruby-client must speak the same protocol
# version as browserd's playwright-core, which AcquireLease also asserts at runtime). This spec fails on any drift,
# and on the staging accessory's MAX_BROWSERS drifting from the apply worker's APPLY_SLOTS.
RSpec.describe 'browserd image tag consistency' do
  let(:browserd_dir) { Rails.root.join('docker/browserd') }
  let(:package_json) { JSON.parse(browserd_dir.join('package.json').read) }
  let(:package_lock) { JSON.parse(browserd_dir.join('package-lock.json').read) }
  let(:dockerfile) { browserd_dir.join('Dockerfile').read }
  let(:compose) { YAML.safe_load(Rails.root.join('docker-compose.yml').read, aliases: true) }
  let(:staging) do
    # Kamal renders the destination file with ERB (trim_mode '-'); an empty binding keeps spec locals out of it.
    rendered = ERB.new(Rails.root.join('config/deploy.staging.yml').read, trim_mode: '-').result(Object.new.instance_eval { binding })
    YAML.safe_load(rendered)
  end
  let(:lockfile) { Bundler::LockfileParser.new(Rails.root.join('Gemfile.lock').read) }

  let(:playwright_core) { package_json.dig('dependencies', 'playwright-core') }
  let(:expected_tag) { "#{dockerfile_arg('CAMOUFOX_VERSION')}-#{dockerfile_arg('CAMOUFOX_RELEASE')}-pw#{playwright_core}" }

  # Every `ARG NAME=value` line for NAME (the Dockerfile declares the version ARGs in more than one stage); all must
  # agree, otherwise the downloaded binary and the final stage's version check would differ.
  def dockerfile_arg(name)
    values = dockerfile.scan(/^ARG #{name}=(\S+)$/).flatten.uniq
    raise "Dockerfile: expected one value for ARG #{name}, got #{values.inspect}" unless values.one?

    values.first
  end

  def image_tag(image)
    repository, tag = image.to_s.split(':', 2)
    expect(repository).to eq('andriano606/apply_mate_browserd')
    tag
  end

  it 'pins camoufox-js 0.10.2 and playwright-core 1.63.0 exactly in package.json and package-lock.json' do
    expect(package_json['dependencies']).to eq('camoufox-js' => '0.10.2', 'playwright-core' => '1.63.0')
    expect(package_lock.dig('packages', 'node_modules/camoufox-js', 'version')).to eq('0.10.2')
    expect(package_lock.dig('packages', 'node_modules/playwright-core', 'version')).to eq(playwright_core)
  end

  it 'tags the docker-compose.yml browserd image with the pinned triple' do
    expect(image_tag(compose.dig('services', 'browserd', 'image'))).to eq(expected_tag)
  end

  it 'tags the staging browserd accessory image with the pinned triple' do
    expect(image_tag(staging.dig('accessories', 'browserd', 'image'))).to eq(expected_tag)
  end

  it 'pins playwright-ruby-client in Gemfile.lock to browserd playwright-core' do
    spec = lockfile.specs.find { |s| s.name == 'playwright-ruby-client' }
    expect(spec&.version&.to_s).to eq(playwright_core)
  end

  it 'sizes staging browserd MAX_BROWSERS to the apply worker APPLY_SLOTS' do
    apply_slots = staging.dig('servers', 'apply_worker', 'env', 'clear', 'APPLY_SLOTS')
    max_browsers = staging.dig('accessories', 'browserd', 'env', 'clear', 'MAX_BROWSERS')

    expect(apply_slots).to be_present
    expect(max_browsers).to eq(apply_slots)
  end
end
