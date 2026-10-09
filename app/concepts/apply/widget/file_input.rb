# frozen_string_literal: true

# A file input, visible or not (Ashby's resume input is clipped to 1x1 px behind an "Upload File" button):
# Session#upload sets the file directly (attached-only resolution, no file chooser). `value` is the local path (the
# CV file FillFields wrote). Read-back: the selected file names.
class Apply::Widget::FileInput < Apply::Widget::Base
  def self.handles?(field)
    field.kind == 'file'
  end

  def settle_kind
    :file
  end

  def write(path)
    session.upload(target, path.to_s)
  end

  def expected_display(path)
    File.basename(path.to_s)
  end
end
