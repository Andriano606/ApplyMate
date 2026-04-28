# frozen_string_literal: true

require 'aws-sdk-s3'

Rails.application.config.after_initialize do
  next unless ENV['MINIO_ENDPOINT'].present?

  client = Aws::S3::Client.new(
    endpoint:          ENV['MINIO_ENDPOINT'],
    access_key_id:     ENV['MINIO_ACCESS_KEY_ID'],
    secret_access_key: ENV['MINIO_SECRET_ACCESS_KEY'],
    region:            'us-east-1',
    force_path_style:  true
  )
  bucket = ENV.fetch('MINIO_BUCKET', 'apply-mate-staging')
  client.create_bucket(bucket:)
rescue Aws::S3::Errors::BucketAlreadyOwnedByYou, Aws::S3::Errors::BucketAlreadyExists
  nil
rescue => e
  Rails.logger.warn "MinIO bucket setup failed: #{e.message}"
end
