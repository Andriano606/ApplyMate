# frozen_string_literal: true

module ApplyMate::FormObject::AttachmentValidator
  XLS_MIME_TYPE = %w[application/zip application/octet-stream].freeze
  XML_TYPE = %w[text/xml].freeze

  # We have a max message size limit of 10 MB on Postmark
  # (https://postmarkapp.com/support/article/1056-what-are-the-attachment-and-email-size-limits)
  # The Max size of the email attachments is calculated by:
  # message_size_limit - Base64.encode64(customer_invoice_with_big_logo).bytesize - mailchimp_invoice_email.bytesize
  # which rounds to 9.9.megabytes.
  # Base64 encoding usually adds about 33% of the original size
  # 9.9 / 1.33 = 7.4 - Give a bit of a buffer
  ATTACHMENTS_MAX_SIZE = 7.megabytes

  def self.detect_mime_type(file)
    Marcel::MimeType.for file, name: Pathname.new(file.path).basename
  end

  def self.attachments_max_size
    ATTACHMENTS_MAX_SIZE
  end

  private

  def run_attachment_format_check(name, attachment_type, base_error)
    attached = public_send(name)
    return if attached.blank?

    Array.wrap(attached).each do |file|
      next if valid_attachment_format?(file, attachment_type)

      error_key = base_error ? :base : name
      errors.add(error_key, I18n.t('error_messages.file.incorrect_format', formats: display_formats_for(attachment_type)))
    end
  end

  def valid_attachment_format?(file, attachment_type)
    if attachment_type.is_a?(Array)
      filename  = file.try(:original_filename) || File.basename(file.path.to_s)
      extension = File.extname(filename).downcase
      attachment_type.include?(extension)
    else
      valid_formats_for(attachment_type).any? do |val|
        ApplyMate::FormObject::AttachmentValidator.detect_mime_type(file).include?(val)
      end
    end
  end

  def run_attachment_presence_check(name, base_error)
    return if public_send(name).present?

    error_key = base_error ? :base : name
    errors.add(error_key, I18n.t('error_messages.file.must_be_attached'))
  end

  def run_attachment_size_check(name, max_size_mb, base_error)
    attached = public_send(name)
    return if attached.blank?

    max_bytes = max_size_mb * 1024 * 1024
    Array.wrap(attached).each do |file|
      next if file.size <= max_bytes

      error_key = base_error ? :base : name
      errors.add(error_key, I18n.t('error_messages.file.too_large', size: max_size_mb))
    end
  end

  def type_formats
    {
      image: { valid_formats: %w[png jpeg webp] },
      pdf:   { valid_formats: %w[png jpeg pdf] },
      xls:   {
        valid_formats:    %w[csv application/vnd.ms-excel vnd.openxmlformats-officedocument.spreadsheetml.sheet],
        humanize_formats: %w[csv xls xlsx]
      },
      xml:   { valid_formats: %w[xml plain] },
      csv:   { valid_formats: %w[csv plain], humanize_formats: %w[csv] },
      glb:   { valid_formats: %w[model/gltf-binary octet-stream], humanize_formats: %w[glb] }
    }.stringify_keys
  end

  def valid_formats_for(attachment_type)
    type_formats.fetch(attachment_type.to_s).fetch(:valid_formats)
  end

  def display_formats_for(attachment_type)
    if attachment_type.is_a?(Array)
      attachment_type.map { |ext| ext.delete_prefix('.') }.join(', ')
    else
      entry = type_formats.fetch(attachment_type.to_s)
      (entry.fetch(:humanize_formats, nil) || entry.fetch(:valid_formats)).join(', ')
    end
  end
end
