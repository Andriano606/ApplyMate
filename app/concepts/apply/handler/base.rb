# frozen_string_literal: true

require 'faraday/multipart'

class Apply::Handler::Base
  class << self
    def for(apply)
      scraper_name = apply.source_profile.source.scraper.demodulize
      "Apply::Handler::#{scraper_name}".constantize.new(apply:)
    rescue NameError
      raise "No handler defined for scraper: #{scraper_name}"
    end

    def add_step(operation, execute_condition: nil, **options)
      @steps ||= []
      @steps << { operation:, condition: execute_condition, options: }
    end

    def steps
      @steps || []
    end
  end

  def initialize(apply:)
    @apply = apply
  end

  def call
    self.class.steps.each do |step|
      next if step[:condition] && !step[:condition].call(@apply)

      step[:operation].call(apply: @apply, handler: self, **step[:options])
    end
  end

  def cv_filename
    name = @apply.user_profile.name.to_s.strip
    return 'CV.pdf' if name.blank?

    "#{name.gsub(/\s+/, '_')}_CV.pdf"
  end

  def build_payload(apply)
    inputs  = apply.filled_inputs || []
    payload = inputs.reject { |i| i['type'] == 'file' }
                    .each_with_object({}) { |i, h| h[i['name']] = i['value'].to_s }

    file_input = apply.inputs&.find { |i| i['type'] == 'file' }
    if apply.cv.attached? && file_input
      file_content = apply.cv.download
      payload[file_input['name']] = Faraday::Multipart::FilePart.new(
        StringIO.new(file_content),
        apply.cv.content_type,
        apply.cv.filename.to_s
      )
    end

    payload
  end
end
