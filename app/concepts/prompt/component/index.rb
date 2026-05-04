# frozen_string_literal: true

class Prompt::Component::Index < ApplyMate::Component::Base
  def initialize(prompts:, **)
    @prompts = prompts
  end

  private

  def header_opts
    { title: I18n.t('prompt.index.title') }
  end
end
