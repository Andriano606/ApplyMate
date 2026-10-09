# frozen_string_literal: true

# Is this really an application form? (design §6.4, rule R2) The ONE implementation, asked by Engine::Navigate (an
# AI form_reached claim), Recipe::Interpret (a recipe's terminal wait_for) and Stage::DiscoverFields (a Generic form).
#
# `elements`: snapshot element hashes already scoped to the candidate form by the caller (Engine::FormElements, or a
# snapshot_all(regions: [root]) filtered to the root's frame); `root:` (a CSS selector) narrows them further to the
# elements whose 'regions' include it.
#
#   rejected 'password'           a RENDERED (visible) password field: a sign-in form, the same rule as the SignInWall
#                                 gate. A hidden one (a closed login dropdown in the site header under a broad SPA
#                                 root) says nothing about the form
#   dropped from the count        search-like elements (snapshot.js marks type=search, role=search, header / footer /
#                                 nav as search_like: the site chrome) and everything that is not a fillable control
#                                 (BuildFieldInventory.control?)
#   accepted 'file_input'         a file input, visible or hidden (a CV upload)
#   accepted 'identity_field'     >= MIN_FILLABLE visible fillable units (a radio / option group is one unit) and one
#                                 of them classifies (Answer::Classify) as full_name / first_name / email
#   rejected 'no_identity_field'  enough fields, none of them asks who the candidate is
#   rejected 'too_few_fields'     fewer than MIN_FILLABLE (an email-only newsletter / subscription box)
#
# `evident` is the stricter rule Engine::Navigate applies to a page BEFORE it asks the AI (a form rendered on load needs
# no navigation, so an AI outage must not halt it): a file input AND >= MIN_FILLABLE visible units with an identity
# field AND a visible submit button (snapshot.js submit_like) among the elements. A contact form has no upload, an
# upload-only landing widget has no identity fields: either still goes to the AI.
#
# model = Verdict(accepted, reason, fillable (visible fillable units), file_inputs, evident).
class Apply::Operation::Engine::AssessFormLikeness < ApplyMate::Operation::Base
  Verdict = Data.define(:accepted, :reason, :fillable, :file_inputs, :evident)

  MIN_FILLABLE = 3
  IDENTITY_SEMANTICS = %w[full_name first_name email].freeze
  BLANK_FIELD = Apply::Field.members.index_with(nil).freeze

  def perform!(elements:, root: nil, **)
    skip_authorize
    elements = elements.select { |element| Array(element['regions']).include?(root) } if root
    return self.model = verdict(false, 'password', 0, 0, false) if elements.any? { |element| element['password'] && element['visible'] }

    controls = elements.select { |element| Apply::Operation::Engine::BuildFieldInventory.control?(element) }
    files = controls.count { |element| element['type'] == 'file' }
    units = controls.select { |element| element['visible'] && element['type'] != 'file' }
                    .uniq { |element| element['group_key'].presence || element['ref'] }
    self.model = verdict(*decide(files, units), units.size, files, evident?(elements, files, units))
  end

  private

  def decide(files, units)
    return [ true, 'file_input' ] if files.positive?
    return [ false, 'too_few_fields' ] if units.size < MIN_FILLABLE
    return [ true, 'identity_field' ] if units.any? { |element| identity?(element) }

    [ false, 'no_identity_field' ]
  end

  def evident?(elements, files, units)
    files.positive? && units.size >= MIN_FILLABLE && elements.any? { |element| element['submit_like'] && element['visible'] } &&
      units.any? { |element| identity?(element) }
  end

  def identity?(element)
    kind = Apply::Operation::Engine::BuildFieldInventory::INPUT_KINDS.fetch(element['type'].to_s, 'text')
    field = Apply::Field.new(**BLANK_FIELD.merge(kind:, label: element['name'].presence || element['question'],
                                                 placeholder: element.dig('attrs', 'placeholder'),
                                                 autocomplete: element.dig('attrs', 'autocomplete')))
    IDENTITY_SEMANTICS.include?(Apply::Operation::Answer::Classify.call(field:, platform: nil).model)
  end

  def verdict(accepted, reason, fillable, file_inputs, evident)
    Verdict.new(accepted:, reason:, fillable:, file_inputs:, evident:)
  end
end
