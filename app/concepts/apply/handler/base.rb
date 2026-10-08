# frozen_string_literal: true

require 'faraday/multipart'

# A job board's apply pipeline: an ordered list of steps (Apply::Operation::Base subclasses), run by
# Apply::Operation::Engine::Run. See .ai/docs/apply_handlers.md and .ai/docs/apply_engine.md.
class Apply::Handler::Base
  # operation  Apply::Operation::Base subclass (declares `stage`)
  # condition  nil or a lambda called with the run's Apply::Operation::Engine::Context; falsy skips the step
  # options    keyword arguments forwarded to the operation's run!
  # scope      nil, or the name of the session_scope the step is declared in (one browser lease per scope)
  # position   index in the handler's step list (apply_steps.position)
  #
  # key (apply_steps.key, unique per attempt): "<stage>[:replay][:<scope>]", e.g. navigate:survey,
  # navigate:replay:submit; a scope-less step's key is just its stage.
  Step = Data.define(:operation, :condition, :options, :scope, :position) do
    def key
      [ operation.stage, options[:replay] ? 'replay' : nil, scope ].compact.join(':')
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
      steps << Step.new(operation:, condition: binding.local_variable_get(:if), options:, scope: @current_scope,
                        position: steps.size)
    end

    # Steps declared in the block share ONE browser session (one lease) and run as a unit: the Runner skips the
    # unit only when every step in it can be restored, otherwise it re-runs all of them. `if:` is checked once
    # before the session is opened (a falsy scope leaves no rows).
    def session_scope(name, if: nil)
      raise ArgumentError, 'session scopes do not nest' if @current_scope

      scope_conditions[name] = binding.local_variable_get(:if)
      @current_scope = name
      yield
    ensure
      @current_scope = nil
    end

    # The engine pipeline of design §10.1 (phase 3a stages). `detect_if` guards DetectPlatform; FetchSchema and the
    # survey's ReachForm run under `detect_if` AND `ctx.platform_reachable?` (a known platform, or a generic match
    # with a probable one that the landing page may confirm: the platform is not settled before them); `if` is AND-ed
    # into DiscoverFields and every later step and scope (Handler::Dou: external AND platform_known?, so an
    # unidentified platform falls through to its legacy path). The recipe-learning stage arrives in phase 6.
    def engine!(detect_if: nil, if: nil)
      guard = binding.local_variable_get(:if)
      stages = Apply::Operation::Stage
      reachable = all_of(detect_if, ->(ctx) { ctx.platform_reachable? })
      add_step stages::DetectPlatform, if: detect_if
      add_step stages::FetchSchema, if: reachable
      session_scope(:survey, if: all_of(reachable, ->(ctx) { ctx.survey_needed? })) do
        add_step stages::ReachForm
        add_step stages::DiscoverFields, if: guard
      end
      add_step stages::AnswerFields, if: guard
      add_step Apply::Operation::Ai::GeneratePdfCv, if: guard, prompt_class: Apply::Ai::Prompt::GenerateCv,
                                                    schema_class: Apply::Ai::ResponseSchema::GenerateCv
      add_step stages::ReviewGate, if: guard
      add_step stages::AcquireHostSlot, if: guard
      session_scope(:submit, if: guard) do
        add_step stages::ReachForm, replay: true
        add_step stages::DiscoverFields, reconcile: true
        add_step stages::FillFields
        add_step stages::Submit
        add_step stages::Verify
      end
    end

    def steps
      @steps ||= []
    end

    # { scope name => condition lambda or nil }
    def scope_conditions
      @scope_conditions ||= {}
    end

    private

    def all_of(*conditions)
      conditions = conditions.compact
      return nil if conditions.empty?

      ->(ctx) { conditions.all? { |condition| condition.call(ctx) } }
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
