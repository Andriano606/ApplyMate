# frozen_string_literal: true

require 'async/http/internet'

class ApplyMate::Client::AsyncHttp < ApplyMate::Client::Base
  def initialize(timeout: 15)
    @timeout = timeout
    @internet = Async::HTTP::Internet.new
  end

  def get(url, headers: {}, error_handler: default_error_handler, **)
    error_handler.run do
      response = @internet.get(url, build_headers(headers))
      Response.new(response.read, extract_headers(response.headers), response.status)
    end
  end

  def fetch_body(url, error_handler: default_error_handler, **)
    get(url, error_handler: error_handler)&.body
  end

  def post(url, body:, headers: {}, error_handler: default_error_handler, **)
    error_handler.run do
      response = @internet.post(url, build_headers(headers), body)
      Response.new(response.read, extract_headers(response.headers), response.status)
    end
  end

  def post_xhr(url, body, headers = {}, error_handler: default_error_handler)
    post(url, body: body, headers: headers, error_handler: error_handler)&.body
  end

  def close
    @internet.close
  end

  private

  def default_error_handler
    ApplyMate::Client::ErrorHandler.new(max_retries: 5, base_delay: 1)
  end

  def build_headers(extra = {})
    [ [ 'User-Agent', USER_AGENT ] ] + extra.map { |k, v| [ k.to_s, v.to_s ] }
  end

  def extract_headers(headers)
    result = {}
    headers.each { |k, v| result[k.to_s.downcase] ||= v.to_s }
    result
  end
end
