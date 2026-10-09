# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Net::Operation::ResolvePublicAddress, type: :operation do
  def reason_for(url)
    described_class.call(url:)
    nil
  rescue ApplyMate::Net::UnsafeUrlError => e
    e.reason
  end

  it 'rejects localhost through the real Resolv path (/etc/hosts)' do
    expect(reason_for('http://localhost/')).to eq(:private)
  end

  [
    'http://10.1.2.3/', 'http://127.0.0.1:3000/x', 'http://169.254.169.254/latest/meta-data',
    'http://100.64.0.1/', 'http://172.16.5.5/', 'http://192.168.50.155/', 'http://0.0.0.0/',
    'http://[::1]/', 'http://[fc00::1]/', 'http://[fe80::1]/', 'http://[::ffff:10.0.0.1]/', 'http://[::]/'
  ].each do |url|
    it "rejects the private literal #{url}" do
      expect(reason_for(url)).to eq(:private)
    end
  end

  [ 'ftp://example.com/file', 'file:///etc/passwd', 'javascript:alert(1)', '/relative/path', 'http:///no-host',
    'http://exa mple.com/', nil ].each do |url|
    it "rejects #{url.inspect} as a bad scheme" do
      expect(reason_for(url)).to eq(:scheme)
    end
  end

  it 'returns a Resolution for a public literal without DNS' do
    expect(Resolv::DNS).not_to receive(:new)

    resolution = described_class.call(url: 'https://1.1.1.1/path?q=1').model

    expect(resolution).to eq(described_class::Resolution.new(url: 'https://1.1.1.1/path?q=1', host: '1.1.1.1',
                                                             port: 443, ip: '1.1.1.1'))
  end

  it 'unwraps IPv4-mapped IPv6 and accepts a public one' do
    expect(described_class.call(url: 'http://[::ffff:1.1.1.1]:8080/').model)
      .to have_attributes(host: '::ffff:1.1.1.1', port: 8080, ip: '::ffff:1.1.1.1')
  end

  context 'with a hostname' do
    let(:answers) { [] }

    before { allow_any_instance_of(Resolv).to receive(:getaddresses).with('jobs.example.com').and_return(answers) }

    context 'when every answer is public' do
      let(:answers) { [ '93.184.215.14', '2606:2800:21f:cb07:6820:80da:af6b:8b2c' ] }

      it 'returns the first address' do
        expect(described_class.call(url: 'HTTPS://jobs.example.com/apply').model)
          .to have_attributes(host: 'jobs.example.com', port: 443, ip: '93.184.215.14')
      end
    end

    context 'when the resolver lists an IPv6 answer first' do
      let(:answers) { [ '2606:4700:10::ac42:a4c8', '104.20.28.254', '172.66.164.200' ] }

      it 'pins the first IPv4 address (an IPv6 pin fails on an IPv4-only host)' do
        expect(described_class.call(url: 'https://jobs.example.com/').model.ip).to eq('104.20.28.254')
      end
    end

    context 'when the host has IPv6 answers only' do
      let(:answers) { [ '2606:4700:10::ac42:a4c8' ] }

      it 'pins the IPv6 address' do
        expect(described_class.call(url: 'https://jobs.example.com/').model.ip).to eq('2606:4700:10::ac42:a4c8')
      end
    end

    context 'when public and private answers are mixed (DNS rebinding)' do
      let(:answers) { [ '93.184.215.14', '10.0.0.7' ] }

      it 'rejects the URL' do
        expect(reason_for('https://jobs.example.com/')).to eq(:private)
      end
    end

    context 'when an answer cannot be parsed' do
      let(:answers) { [ '93.184.215.14', 'fe80::1%lo0' ] }

      it 'fails closed' do
        expect(reason_for('https://jobs.example.com/')).to eq(:private)
      end
    end

    context 'when nothing resolves' do
      it 'rejects the URL as unresolvable' do
        expect(reason_for('https://jobs.example.com/')).to eq(:unresolvable)
      end
    end
  end

  it 'names the host, not the full URL, in the error message' do
    expect { described_class.call(url: 'http://127.0.0.1/reset?token=secret') }
      .to raise_error(ApplyMate::Net::UnsafeUrlError) { |e|
        expect(e.message).not_to include('secret')
        expect(e.url).to eq('http://127.0.0.1/reset?token=secret')
      }
  end

  describe '.literal_private? (no DNS)' do
    it 'is true for localhost and literal non-public IPs, including bracketed and IPv4-mapped IPv6' do
      %w[localhost app.localhost 127.0.0.1 10.1.2.3 192.168.50.155 [::1] ::ffff:10.0.0.1 [fd00::5]].each do |host|
        expect(described_class.literal_private?(host)).to be(true), host
      end
    end

    it 'is true for the fully-qualified (trailing-dot) forms Firefox keeps in frame URLs' do
      %w[localhost. app.localhost. LOCALHOST. 127.0.0.1. 10.1.2.3.].each do |host|
        expect(described_class.literal_private?(host)).to be(true), host
      end
    end

    it 'is false for public IPs and for hostnames (those need the DNS check)' do
      allow(Resolv).to receive(:new)

      %w[93.184.215.14 93.184.215.14. [2606:4700::1] jobs.example.com jobs.example.com. intranet].each do |host|
        expect(described_class.literal_private?(host)).to be(false), host
      end
      expect(Resolv).not_to have_received(:new)
    end
  end
end
