# frozen_string_literal: true

class ArtifactsController < ApplicationController
  include ActiveStorage::SetCurrent

  def show
    endpoint Artifact::Operation::Show do |m|
      m.success do |result|
        redirect_to result.model.url, allow_other_host: true
      end
    end
  end
end
