# frozen_string_literal: true

# For all actions available see:
# https://github.com/hotwired/turbo-rails/blob/main/app/models/turbo/streams/tag_builder.rb

# Custom actions added:
ActiveSupport.on_load :turbo_streams_tag_builder do
  def create_element_if_not_exist(target:, parent_id:)
    turbo_stream_action_tag :create_element_if_not_exist, target:, template: nil, parent_id:
  end

  def flash(flash)
    html = if flash.first
             ApplicationController.renderer.render(
               ApplyMate::Component::Flash.new(type: flash.first.first, message: flash.first.second),
               layout: false,
             )
    else
             ''
    end
    action :append, 'flash-list', html:
  end

  def remove_by_id(target)
    action :remove_by_id, target
  end
end
