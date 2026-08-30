# frozen_string_literal: true

# Builds a multipart/form-data body. Shared by the HTTP clients so the apply flow
# submits byte-identical payloads whichever transport a source uses (plain
# AsyncHttp, or ImpersonateHttp for Cloudflare-protected sources).
module ApplyMate::Client::Multipart
  private

  def build_multipart(payload)
    boundary = "----RubyMultipart#{SecureRandom.hex(12)}"
    body     = String.new(encoding: 'ASCII-8BIT')

    payload.each do |name, value|
      body << "--#{boundary}\r\n"
      if file_part?(value)
        body << %(Content-Disposition: form-data; name="#{name}"; filename="#{value.original_filename}"\r\n)
        body << "Content-Type: #{value.content_type}\r\n\r\n"
        body << value.read.b
      else
        body << %(Content-Disposition: form-data; name="#{name}"\r\n\r\n)
        body << value.to_s.b
      end
      body << "\r\n"
    end
    body << "--#{boundary}--\r\n"

    [ body, "multipart/form-data; boundary=#{boundary}" ]
  end

  def file_part?(value)
    value.respond_to?(:read) && value.respond_to?(:original_filename) && value.respond_to?(:content_type)
  end
end
