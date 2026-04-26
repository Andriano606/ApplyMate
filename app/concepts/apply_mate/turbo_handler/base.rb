# frozen_string_literal: true

class ApplyMate::TurboHandler::Base
  def self.stream_from(_record, _view_context)
    raise NotImplementedError, "#{self.class}#stream_from is not implemented"
  end

  def self.frame_tag(_record, _view_context, &_block)
    raise NotImplementedError, "#{self.class}#frame_tag is not implemented"
  end

  def self.broadcast(_record)
    raise NotImplementedError, "#{self.class}#broadcast is not implemented"
  end
end
