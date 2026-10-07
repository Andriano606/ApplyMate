# frozen_string_literal: true

class Apply::Handler::Dou < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  add_step Apply::Operation::Ai::FetchExternalForm, if: ->(ctx) { ctx.apply.external? }
  add_step Apply::Operation::FetchInternalForm,      if: ->(ctx) { ctx.apply.internal? }
  add_step Apply::Operation::Ai::FillForm, prompt_class: Apply::Ai::Prompt::FillForm, schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Browser, if: ->(ctx) { ctx.apply.external? }
  add_step Apply::Operation::SendApply::Http, if: ->(ctx) { ctx.apply.internal? }
end
