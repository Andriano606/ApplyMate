# frozen_string_literal: true

# An upload button / drop area that opens the file chooser itself, with no file input in the DOM until it is clicked
# (snapshot.js `chooser`; BuildFieldInventory stores widget 'dropzone' for it explicitly, so a stored field keeps this
# driver: the kind alone, `file`, would pick FileInput). Session#upload(via_chooser: true) clicks it and answers the
# chooser (:required resolution: the button must be visible). Read-back: the text of the field root (read_value.js
# `displayed` for a button), which must contain the file's name.
class Apply::Widget::Dropzone < Apply::Widget::Base
  def self.handles?(field)
    field.kind == 'file' && field.widget == key
  end

  def settle_kind
    :file
  end

  def write(path)
    session.upload(target, path.to_s, via_chooser: true)
  end

  def expected_display(path)
    File.basename(path.to_s)
  end

  def accepts?(read_back, path)
    !read_back.invalid && read_back.displayed.to_s.include?(expected_display(path))
  end
end
