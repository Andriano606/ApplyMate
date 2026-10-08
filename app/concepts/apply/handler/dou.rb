# frozen_string_literal: true

# DOU vacancies: internal (reply form on dou.ua, over HTTP) or external (the company's application form).
#
# External applies always run DetectPlatform first (redirect walk of the dou.ua/goto URL). A platform the registry
# knows (ctx.platform_known?: false before detection and for `generic`; a probable platform the survey's landing page
# confirms, e.g. Preply -> Ashby, becomes known there) goes through the engine stages only and never touches the
# legacy steps. Every other external apply takes the TEMPORARY legacy path below (the `!ctx.platform_known?` steps:
# Ai::FetchExternalForm, Ai::FillForm, Ai::GeneratePdfCv, SendApply::Browser), which is deleted in phase 3b together
# with the Navigator. ctx.platform_known? never turns false again within a run, so GeneratePdfCv runs once per path:
# the engine! block declares its own for known platforms (both steps share the key generate_cv; their conditions
# exclude each other, see the 'step conditions' examples in dou_spec.rb).
class Apply::Handler::Dou < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  engine! detect_if: ->(ctx) { ctx.apply.external? }, if: ->(ctx) { ctx.apply.external? && ctx.platform_known? }
  # TEMPORARY legacy external path for platforms the registry does not know: deleted in phase 3b.
  add_step Apply::Operation::Ai::FetchExternalForm, if: ->(ctx) { ctx.apply.external? && !ctx.platform_known? }
  add_step Apply::Operation::FetchInternalForm,      if: ->(ctx) { ctx.apply.internal? }
  add_step Apply::Operation::Ai::FillForm, if: ->(ctx) { ctx.apply.internal? || !ctx.platform_known? },
                                           prompt_class: Apply::Ai::Prompt::FillForm,
                                           schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, if: ->(ctx) { ctx.apply.internal? || !ctx.platform_known? },
                                                prompt_class: Apply::Ai::Prompt::GenerateCv,
                                                schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Browser, if: ->(ctx) { ctx.apply.external? && !ctx.platform_known? }
  add_step Apply::Operation::SendApply::Http,    if: ->(ctx) { ctx.apply.internal? }
end
