# frozen_string_literal: true

require 'rails_helper'
require 'open3'

RSpec.describe 'bin/install-curl-impersonate' do # rubocop:disable RSpec/DescribeClass
  let(:script) { Rails.root.join('bin/install-curl-impersonate').to_s }
  let(:tmp) { Pathname(Dir.mktmpdir('install-curl-impersonate')) }
  let(:dest) { tmp.join('dest') }
  let(:fake_bin) { tmp.join('bin') }

  # Stands in for curl: copies the tarball named by FAKE_TARBALL to the `-o` path,
  # or fails like `curl -f` on a 404 when FAKE_TARBALL is unset.
  let(:fake_curl) do
    <<~BASH
      #!/usr/bin/env bash
      out=""
      while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; shift; fi
        shift
      done
      [ -n "${FAKE_TARBALL:-}" ] || { echo "curl: (22) 404" >&2; exit 22; }
      cp "$FAKE_TARBALL" "$out"
    BASH
  end

  before do
    fake_bin.mkpath
    write_executable(fake_bin.join('curl'), fake_curl)
  end

  after { FileUtils.rm_rf(tmp) }

  def write_executable(path, body)
    path.write(body)
    path.chmod(0o755)
  end

  # Builds a release-shaped tarball; `files` maps a file name to its script body.
  def tarball(name, files)
    src = tmp.join("src-#{name}")
    src.mkpath
    files.each { |file, body| write_executable(src.join(file), body) }
    archive = tmp.join("#{name}.tar.gz")
    _out, err, status = Open3.capture3('tar', 'czf', archive.to_s, '-C', src.to_s, '.')
    raise "tar failed: #{err}" unless status.success?

    archive
  end

  def run_installer(archive)
    env = {
      'PATH' => "#{fake_bin}:#{ENV.fetch('PATH')}",
      'CURL_IMPERSONATE_DEST' => dest.to_s,
      'FAKE_TARBALL' => archive&.to_s
    }
    Open3.capture3(env, script)
  end

  let(:good_binary) { "#!/bin/sh\necho 'curl 8.13.0-DEV (curl-impersonate)'\n" }
  let(:broken_binary) { "#!/bin/sh\nexit 1\n" }

  it 'installs into CURL_IMPERSONATE_DEST and prints OK when curl_chrome136 runs' do
    archive = tarball('good', 'curl_chrome136' => good_binary, 'curl-impersonate' => good_binary)

    stdout, stderr, status = run_installer(archive)

    expect(status.exitstatus).to eq(0), stderr
    expect(stdout).to include("OK — installed to #{dest}")
    expect(dest.join('curl_chrome136')).to be_executable
    expect(dest.join('curl-impersonate')).to be_executable
    expect(dest.join('ci.tar.gz')).not_to exist
  end

  it 'exits non-zero with ERROR when curl_chrome136 is not runnable' do
    archive = tarball('broken', 'curl_chrome136' => broken_binary)

    stdout, stderr, status = run_installer(archive)

    expect(status.exitstatus).not_to eq(0)
    expect(stderr).to include('ERROR: curl_chrome136 is not runnable on this host')
    expect(stdout).not_to include('OK')
    expect(dest.join('curl_chrome136')).not_to exist
  end

  it 'exits non-zero with ERROR when the archive lacks curl_chrome136' do
    archive = tarball('missing', 'curl_chrome120' => good_binary)

    stdout, stderr, status = run_installer(archive)

    expect(status.exitstatus).not_to eq(0)
    expect(stderr).to include('ERROR: curl_chrome136 missing after extracting https://github.com/lexiforest/')
    expect(stdout).not_to include('OK')
  end

  it 'exits non-zero when the download fails' do
    _stdout, stderr, status = run_installer(nil)

    expect(status.exitstatus).not_to eq(0)
    expect(stderr).to include('404')
  end

  it 'keeps a working install when a later archive is broken' do
    dest.mkpath
    write_executable(dest.join('curl_chrome136'), good_binary)
    archive = tarball('broken', 'curl_chrome136' => broken_binary)

    _stdout, _stderr, status = run_installer(archive)

    expect(status.exitstatus).not_to eq(0)
    expect(dest.join('curl_chrome136').read).to eq(good_binary)
  end
end
