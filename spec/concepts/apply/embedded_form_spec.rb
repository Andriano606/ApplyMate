# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::EmbeddedForm do
  describe '.locate' do
    it 'rewrites an Ashby embed iframe to its standalone application URL' do
      srcs = [
        'https://jobs.ashbyhq.com/preply/a9419d80-5cf1-4dba-a3d3-e90e5c464495?embed=js',
        'https://web.cmp.usercentrics.eu/cdcs/v/1.0.0/index.html'
      ]
      expect(described_class.locate(srcs))
        .to eq('https://jobs.ashbyhq.com/preply/a9419d80-5cf1-4dba-a3d3-e90e5c464495/application')
    end

    it 'leaves an already-standalone Ashby application URL untouched' do
      url = 'https://jobs.ashbyhq.com/preply/a9419d80/application'
      expect(described_class.locate([ url ])).to eq(url)
    end

    it 'returns a Greenhouse embed iframe as-is (it renders standalone)' do
      url = 'https://boards.greenhouse.io/embed/job_app?for=acme&token=123'
      expect(described_class.locate([ url ])).to eq(url)
    end

    it 'skips consent, analytics and ad iframes' do
      srcs = [
        'https://web.cmp.usercentrics.eu/cdcs/index.html',
        'https://www.googletagmanager.com/ns.html?id=GTM-X',
        'https://googleads.g.doubleclick.net/pagead/x',
        'https://www.youtube.com/embed/abc'
      ]
      expect(described_class.locate(srcs)).to be_nil
    end

    it 'picks the application iframe even when noise comes first' do
      srcs = [
        'https://consent.cookiebot.com/x.html',
        'https://apply.workable.com/embed/acme/j/ABC123/'
      ]
      expect(described_class.locate(srcs)).to eq('https://apply.workable.com/embed/acme/j/ABC123/')
    end

    it 'ignores blank, relative and javascript sources' do
      expect(described_class.locate([ '', nil, 'about:blank', '/local/frame.html' ])).to be_nil
    end

    it 'returns nil when there are no iframes' do
      expect(described_class.locate([])).to be_nil
      expect(described_class.locate(nil)).to be_nil
    end
  end
end
