# frozen_string_literal: true

class ApplyMate::Component::Accordion < ApplyMate::Component::Base
  renders_one :actions

  def initialize(title:, open: false, loading: false)
    @title   = title
    @open    = open
    @loading = loading
  end
end
