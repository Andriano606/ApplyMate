# frozen_string_literal: true

require 'faraday/multipart'

# A job board's apply pipeline: an ordered list of steps (Apply::Operation::Base subclasses), run by
# Apply::Operation::Engine::Run. See .ai/docs/apply_handlers.md and .ai/docs/apply_engine.md.
class Apply::Handler::Base
  # operation  Apply::Operation::Base subclass (declares `stage`)
  # condition  nil or a lambda called with the run's Apply::Operation::Engine::Context; falsy skips the step
  # options    keyword arguments forwarded to the operation's run!
  # position   index in the handler's step list (apply_steps.position)
  Step = Data.define(:operation, :condition, :options, :position) do
    def key
      operation.stage.to_s
    end
  end

  class << self
    def for(apply)
      scraper_name = apply.source_profile.source.scraper.demodulize
      "Apply::Handler::#{scraper_name}".constantize.new(apply:)
    rescue NameError
      raise "No handler defined for scraper: #{scraper_name}"
    end

    def add_step(operation, if: nil, **options)
      steps << Step.new(operation:, condition: binding.local_variable_get(:if), options:, position: steps.size)
    end

    def steps
      @steps ||= []
    end
  end

  def initialize(apply:)
    @apply = apply
  end

  def call
    Apply::Operation::Engine::Run.call(apply: @apply, handler: self)
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
