# frozen_string_literal: true

# DOU vacancies: internal (reply form on dou.ua, over HTTP) or external (the company's application form).
#
# An external apply runs the engine pipeline (Handler::Base.engine!): DetectPlatform walks the dou.ua/goto redirect,
# a known platform is reached by its adapter, any other (`generic`) by the AI Navigator; the submit scope fills, claims
# and submits in the browser. An internal apply keeps the HTTP steps until phase 4. The two paths share no step key
# except generate_cv, and their conditions exclude each other (dou_spec.rb, 'step conditions').
class Apply::Handler::Dou < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  engine! if: ->(ctx) { ctx.apply.external? }
  add_step Apply::Operation::FetchInternalForm, if: ->(ctx) { ctx.apply.internal? }
  add_step Apply::Operation::Ai::FillForm, if: ->(ctx) { ctx.apply.internal? },
                                           prompt_class: Apply::Ai::Prompt::FillForm,
                                           schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, if: ->(ctx) { ctx.apply.internal? },
                                                prompt_class: Apply::Ai::Prompt::GenerateCv,
                                                schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Http, if: ->(ctx) { ctx.apply.internal? }
end
