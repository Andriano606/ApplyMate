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
end
