# frozen_string_literal: true

# FETCHPROXIES: Pool#retire during CONNECT teardown can clear Pipe state before the transient reader
# task finishes; async-http then hits @input.close in ensure when @input is nil (Console warning).
# Keep a local reference to the original input stream for ensure. Upstream pattern:
# https://github.com/socketry/async-http/blob/main/lib/async/http/body/pipe.rb
module ApplyMate
  module AsyncHttpPipeNilSafeReaderEnsure
    private

    def reader(task)
      @reader = task
      input = @input

      task.annotate "#{self.class} reader."

      while chunk = input.read
        @head.write(chunk)
        @head.flush
      end

      @head.close_write
    rescue StandardError => error
      nil
    ensure
      input&.close(error)

      close_head if @writer&.finished?
    end
  end
end

Rails.application.config.to_prepare do
  require 'async/http/body/pipe'

  pipe = Async::HTTP::Body::Pipe
  next if pipe.ancestors.include?(ApplyMate::AsyncHttpPipeNilSafeReaderEnsure)

  pipe.prepend(ApplyMate::AsyncHttpPipeNilSafeReaderEnsure)
end
