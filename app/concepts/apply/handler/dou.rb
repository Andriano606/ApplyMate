# frozen_string_literal: true

class Apply::Handler::Dou < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  add_step Apply::Operation::External::Resolve,       execute_condition: ->(apply) { apply.external? }
  add_step Apply::Operation::External::ReplayRecipe,  execute_condition: ->(apply) { apply.external? }
  # ReplayRecipe sets fields_source on a fingerprint match — FetchFields (and its
  # CheckFormPage AI call) runs only when no recipe matched.
  add_step Apply::Operation::External::FetchFields, execute_condition: ->(apply) { apply.external? && apply.fields_source.blank? }
  add_step Apply::Operation::FetchInternalForm,      execute_condition: ->(apply) { apply.internal? }
  add_step Apply::Operation::Ai::MapFields
  add_step Apply::Operation::ResolveValues, prompt_class: Apply::Ai::Prompt::FillForm, schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::External::Submit, execute_condition: ->(apply) { apply.external? }
  add_step Apply::Operation::SendApply::Http, execute_condition: ->(apply) { apply.internal? }
  add_step Apply::Operation::External::SaveRecipe, execute_condition: ->(apply) { apply.external? }
end
