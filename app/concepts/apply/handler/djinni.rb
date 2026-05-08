# frozen_string_literal: true

class Apply::Handler::Djinni < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  add_step Apply::Operation::FetchDetails
  add_step Apply::Operation::FetchInternalForm
  add_step Apply::Operation::Ai::FillForm, prompt_class: Apply::Ai::Prompt::FillForm, schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Http
end
