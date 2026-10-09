# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::SanitizeHtml do
  subject(:sanitized) { described_class.call(html:).model }

  let(:document) { Nokogiri::HTML5(sanitized) }
  let(:html) do
    <<~HTML
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Refresh" content="0; url=https://jobs.example.com/again">
          <base href="https://jobs.example.com/">
          <title>Customer Care Team Lead</title>
          <script src="https://cdn.example.com/index.js"></script>
          <link rel="stylesheet" href="https://cdn.example.com/index.css">
        </head>
        <body onload="boot()">
          <script>window.location.reload()</script>
          <noscript><img src="https://px.example.com/t.gif"></noscript>
          <div id="form" role="tabpanel">
            <div role="status" class="ashby-application-form-success-container" onclick="track()">
              <h2>Success</h2><p>Application received! Thank you.</p>
            </div>
          </div>
          <a href=" JaVa&#x09;Script:alert(1)">Back</a>
          <a href="https://jobs.example.com/preply">Jobs</a>
          <iframe src="https://www.recaptcha.net/anchor"></iframe>
          <object data="x.swf"></object><embed src="x.swf">
          <svg><script>alert(2)</script><circle r="1" onmouseover="alert(3)"></circle></svg>
          <img src="https://cdn.example.com/logo.png" onerror="alert(4)">
        </body>
      </html>
    HTML
  end

  it 'removes every script, frame, plugin, noscript and base element' do
    expect(document.xpath("//*[local-name()='script']")).to be_empty
    expect(document.css('noscript, iframe, object, embed, base')).to be_empty
  end

  it 'removes the meta refresh but keeps the charset' do
    expect(document.css('meta[http-equiv="Refresh"], meta[http-equiv="refresh"]')).to be_empty
    expect(document.at_css('meta[charset]')).to be_present
  end

  it 'removes event handlers and javascript: URLs, keeping safe attributes' do
    attributes = document.xpath('//@*').map(&:name)
    expect(attributes).not_to include(start_with('on'))
    expect(document.css('a').map { |link| link['href'] }).to eq([ nil, 'https://jobs.example.com/preply' ])
    expect(document.at_css('img')['src']).to eq('https://cdn.example.com/logo.png')
    expect(document.at_css('link[rel=stylesheet]')['href']).to eq('https://cdn.example.com/index.css')
  end

  it 'puts a restrictive CSP first in <head>' do
    meta = document.at_xpath('/html/head/*[1]')

    expect(meta.name).to eq('meta')
    expect(meta['http-equiv']).to eq('Content-Security-Policy')
    expect(meta['content']).to eq(described_class::CSP)
    expect(meta['content']).to start_with("default-src 'none'")
  end

  it 'keeps the text and the markup a reader needs' do
    container = document.at_css('.ashby-application-form-success-container[role=status]')
    expect(container.css('h2, p').map(&:text)).to eq([ 'Success', 'Application received! Thank you.' ])
    expect(document.at_css('title').text).to eq('Customer Care Team Lead')
  end

  context 'with a fragment without <head>' do
    let(:html) { '<p onclick="x()">Thank you for applying</p><script>x()</script>' }

    it 'still adds the CSP' do
      expect(document.at_css('head meta[http-equiv="Content-Security-Policy"]')).to be_present
      expect(document.at_css('p').text).to eq('Thank you for applying')
      expect(sanitized).not_to include('<script', 'onclick')
    end
  end

  it 'returns blank input as is' do
    expect(described_class.call(html: nil).model).to be_nil
    expect(described_class.call(html: '').model).to eq('')
  end
end
