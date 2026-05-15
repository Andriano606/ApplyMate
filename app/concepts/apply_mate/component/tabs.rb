# frozen_string_literal: true

class ApplyMate::Component::Tabs < ApplyMate::Component::Base
  class Tab < ApplyMate::Component::Base
    def initialize(label:, url:, active: false)
      @label  = label
      @url    = url
      @active = active
    end

    def label
      @label
    end

    def url
      @url
    end

    def active?
      @active
    end

    def call
      content
    end
  end

  renders_many :tabs, lambda { |label:|
    @tab_index = (@tab_index || 0) + 1
    key = :"#{@frame_id}_#{@tab_index}"
    Tab.new(label: label, url: "#{@base_url}?#{@param}=#{key}", active: @current.to_s == key.to_s)
  }

  TAB_BASE     = 'border-b-2 px-3 pb-3 pt-1 text-sm font-medium whitespace-nowrap transition-colors'
  TAB_ACTIVE   = 'border-indigo-600 text-indigo-600 dark:border-indigo-400 dark:text-indigo-400'
  TAB_INACTIVE = 'border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 hover:border-gray-300'

  def initialize(base_url:, id: nil, current: nil, param: 'selected_tab')
    @base_url  = base_url
    @stable_id = id
    @current   = current
    @param     = param
  end

  def before_render
    if @stable_id
      @frame_id = @stable_id
    else
      counter = (view_context.instance_variable_get(:@__tabs_counter) || 0) + 1
      view_context.instance_variable_set(:@__tabs_counter, counter)
      @frame_id = "tabs_component_#{counter}"
    end
    @current ||= helpers.params[@param]
  end

  private

  def tab_class(tab, shown)
    "#{TAB_BASE} #{tab == shown ? TAB_ACTIVE : TAB_INACTIVE}"
  end
end
