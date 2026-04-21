# frozen_string_literal: true

class ApplyMate::FormObject::Base
  include ActiveModel::Model

  attr_reader :model
  attr_writer :user

  delegate :id, :hashid, :persisted?, to: :model, allow_nil: true

  Property = Data.define(:name, :default_value, :virtual, :required_privilege, :attachment)
  Subform = Data.define(:name, :form, :collection)

  MAX_INTEGER_SIZE = 2_147_483_647

  def initialize(params = {}, model = nil)
    @model = model

    params = normalize_params(params)

    assign_properties_from_model if model.present?
    assign_subforms_from_model if model.present?

    assign_properties(params)
    assign_subforms(params)
  end

  def normalize_params(params)
    if params.instance_of?(ActionController::Parameters)
      params.to_unsafe_h
    else
      ActiveSupport::HashWithIndifferentAccess.new(params)
    end
  end

  def assign_properties_from_model
    defined_properties.each do |property|
      next unless model.respond_to?(property.name)

      value = model.public_send(property.name)
      next if value.is_a?(ActiveStorage::Attached::One) || value.is_a?(ActiveStorage::Attached::Many)

      public_send("#{property.name}=", value)
    end
  end

  def assign_properties(params)
    defined_properties.each do |property|
      next unless params.key?(property.name)

      value = params[property.name]
      # Use nil? + empty? instead of blank? so that false and 0 are treated as valid values
      next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      public_send("#{property.name}=", value)
    end

    apply_default_values
  end

  def apply_default_values
    defined_properties.each do |property|
      next if property.default_value.nil?
      next unless public_send(property.name).nil?

      public_send("#{property.name}=", property.default_value)
    end
  end

  def assign_subforms_from_model
    defined_subforms.each do |subform|
      name = subform.name

      if subform.collection
        items = model.public_send(name)

        arr = items.map do |item|
          subform.form.new({}, item)
        end

        public_send("#{name}=", arr)
      else
        item = model.public_send(name)
        next unless item

        public_send("#{name}=", subform.form.new({}, item))
      end
    end
  end

  def assign_subforms(params)
    defined_subforms.each_with_index do |subform, index|
      subform_attrs_name = "#{subform.name}_attributes"

      next unless params.key?(subform_attrs_name)

      if subform.collection
        order_counter = 0
        arr = if params[subform_attrs_name].is_a?(Array)
                params[subform_attrs_name].map do |attrs|
                  model = @model&.public_send(subform.name)&.[](order_counter)
                  order_counter += 1
                  if attrs.values.all?(&:blank?)
                    subform.form.new({}, model)
                  else
                    subform.form.new(attrs, model)
                  end
                end.compact
        else
                params[subform_attrs_name].values.map do |attrs|
                  model = @model&.public_send(subform.name)&.[](order_counter)
                  order_counter += 1
                  if attrs.values.all?(&:blank?)
                    subform.form.new({}, model)
                  else
                    subform.form.new(attrs, model)
                  end
                end.compact
        end

        if @model&.respond_to?(subform.name)
          collection = @model.public_send(subform.name)
          if collection && order_counter < collection.size
            remaining_models = collection[order_counter..]
            remaining_models.each do |mod|
              arr << subform.form.new({}, mod)
            end
          end
        end

        public_send("#{subform.name}=", arr)
      else
        attrs = params[subform_attrs_name]

        model = if @model&.respond_to?(subform.name)
                  @model.public_send(subform.name)
        end

        public_send("#{subform.name}=", subform.form.new(attrs, model))
      end
    end
  end

  def self.property(name, virtual: false, attachment: false, default_value: nil, required_privilege: nil)
    name = name.to_sym

    if name == :id
      raise Application::AssertionError,
            'The property `id` is forbidden as a property, use `hashid` instead'
    end

    define_method(name) { instance_variable_get "@#{name}" }
    define_method("#{name}=") { |val| instance_variable_set("@#{name}", val) }

    defined_properties << Property.new(name:, virtual:, attachment:, default_value:, required_privilege:)
  end

  def self.properties(*attrs)
    attrs.each { |attr| property attr }
  end

  def self.has_many(name, form:, reject_if: nil) # rubocop:disable Naming/PredicatePrefix
    name = name.to_sym

    define_method(name) { instance_variable_get "@#{name}" }
    define_method("#{name}=") do |val|
      val = val.reject { |item| reject_if.call(item) } if reject_if
      instance_variable_set("@#{name}", val)
    end
    define_method("#{name}_attributes=") { |val| instance_variable_set("@#{name}", val) }

    # Remove existing subform with the same name if it exists
    # to prevent duplicates in the collection during validation/syncing.
    defined_subforms.delete_if { |subform| subform.name == name }

    defined_subforms << Subform.new(name:, form:, collection: true)
  end

  def self.has_one(name, form:) # rubocop:disable Naming/PredicatePrefix
    name = name.to_sym

    define_method(name) { instance_variable_get "@#{name}" }
    define_method("#{name}=") { |val| instance_variable_set("@#{name}", val) }
    define_method("#{name}_attributes=") { |val| instance_variable_set("@#{name}", val) }

    # Remove existing subform with the same name if it exists
    # to prevent duplicates in the collection during validation/syncing.
    defined_subforms.delete_if { |subform| subform.name == name }

    defined_subforms << Subform.new(name:, form:, collection: false)
  end
  class << self
    alias belongs_to has_one
  end

  def valid?(context = nil)
    a = super

    bs = defined_subforms.flat_map do |subform|
      if subform.collection
        subforms = public_send(subform.name)
        subforms&.map do |subform_item|
          subform_item.valid?(context)
        end
      else
        subform = public_send(subform.name)
        subform.nil? || subform.valid?(context)
      end
    end.compact

    a && bs.all?
  end

  # The parent class defines #validate as an alias. If we don't redefine
  # the alias then #validate will point to the old implementation of #valid?.
  alias validate valid?

  def sorted_properties(properies)
    properies.sort_by { |p| p.name.match?(/\Acompany(_id)?\z/) ? 0 : 1 }
  end

  def sync_to(model)
    # We sort properties so that we can sync the company first. If we sync any of the other relations first the
    # company_id safety check will fail.
    sorted_properties(dirty_properties).each do |property|
      next if property.virtual

      validate_required_privilege! property

      if property.attachment && transaction_closed?
        raise Application::AssertionError, 'Must be in a database transaction when form object has attachments'
      end

      if association_from_property(model:, property:)
        sync_association(model:, property:)
      elsif model.respond_to?("#{property.name}=")
        model.public_send("#{property.name}=", public_send(property.name.to_s))
      elsif property.name == :_destroy && public_send(property.name.to_s).to_b
        model.mark_for_destruction
      end
    end

    # Key attributes for syncing to an existing model are:
    # hashid - If not present, a new record will be created
    # _destroy - If present, the model will be deleted
    defined_subforms.each { |subform| sync_subform subform, model }

    errors.each { |error| model.errors.add(error.attribute, error.message) }
  end

  def association_from_property(model:, property:)
    return unless model.is_a?(ApplicationRecord)

    # We only find belongs_to associations, if it is a has_one or has_many, it should be a subform not a property.
    model.class.reflect_on_all_associations(:belongs_to).find do |association|
      association_name_or_foreign_key = property.name.ends_with?('_id') ? association.foreign_key : association.name
      association_name_or_foreign_key.to_sym == property.name
    end
  end

  def class_from_association(association:, value:)
    return association.klass if !association.polymorphic?

    # Reflection does not support getting the class for polymorphic relations.
    # When assigning a polymorphic relation either the model itself
    # needs to be set. E.g. `property :source` or both the _type and _id properties.
    if value.is_a?(ApplicationRecord)
      value.class
    else
      public_send(association.foreign_type).constantize
    end
  end

  def sync_association(model:, property:)
    association = association_from_property(model:, property:)
    value = public_send(property.name)
    return if value == model.public_send(association.name)

    # Handle clearing the association when value is nil
    if value.nil?
      model.public_send("#{association.name}=", nil)
      return
    end

    associated_class = class_from_association(association:, value:)
    associated_model = value if value.is_a?(ApplicationRecord)
    associated_model ||= find_associated_by_id_or_hashid(associated_class, value)
    return if associated_model.nil?

    # verify_same_company!(model:, associated_model:) if associated_class != Company

    model.public_send("#{association.name}=", associated_model)
  end

  # def verify_same_company!(model:, associated_model:)
  #   return if [ model, associated_model ].any? do |r|
  #     !r.respond_to?(:company_id) && r.class.base_class.association_with_company_id.nil?
  #   end
  #
  #   model_company_id = company_id_from_model(model:)
  #   associated_model_company_id = company_id_from_model(model: associated_model)
  #
  #   return if model_company_id == associated_model_company_id
  #
  #   raise ApplyMate::ActiveRecordAssociationError,
  #         "Expected company_id to eq #{model_company_id.inspect} (#{model.class}), " \
  #           "was #{associated_model_company_id.inspect} (#{associated_model.class})"
  # end

  def company_id_from_model(model:)
    return model.id if model.is_a?(Company)
    return model.company_id if model.respond_to?(:company_id)

    assoc_name = model.class.base_class.association_with_company_id
    return unless assoc_name

    assoc = model.public_send(assoc_name)
    return unless assoc

    assoc.respond_to?(:company_id) ? assoc.company_id : company_id_from_model(model: assoc)
  end

  def sync_subform(subform, parent_model)
    name = subform.name
    if subform.collection
      subform_items = public_send(name)
      items_to_remove = []
      subform_items&.each do |subform_item|
        submodel = find_or_build_submodel(subform_item:, parent_model:, collection_name: name)
        assign_company_id_from_parent(parent_model, submodel)
        subform_item.sync_to(submodel)

        if submodel.new_record? && submodel.marked_for_destruction?
          items_to_remove << subform_item
          parent_model.public_send(name).delete(submodel)
        end
      end
      items_to_remove.each { subform_items.delete(it) }
    else
      # If subform does not exist the has_one relation is optional.
      subform = public_send(name)
      if subform
        submodel = parent_model.public_send(name) || parent_model.public_send("build_#{name}")
        assign_company_id_from_parent(parent_model, submodel)
        subform.sync_to(submodel)
      end
    end
  end

  def find_or_build_submodel(subform_item:, parent_model:, collection_name:)
    if subform_item.respond_to?(:hashid) && subform_item.hashid.present?
      children = parent_model.public_send(collection_name)
      submodel = children.find { |child| child.hashid == subform_item.hashid }
      return submodel if submodel

      raise ApplyMate::ActiveRecordAssociationError,
            "Expected #{collection_name} with hashid #{subform_item.hashid} to belong to " \
              "#{parent_model.class}##{collection_name}, but it was not found"
    end
    parent_model.public_send(collection_name).build
  end

  def assign_company_id_from_parent(parent, child)
    return if !parent.respond_to?(:company_id) || !child.respond_to?(:company_id)
    return if child.company_id.present? || parent.company_id.nil?

    child.company_id = parent.company_id
  end

  def validate_required_privilege!(property)
    return if property.required_privilege.nil?

    if @user.nil?
      raise 'Trying to set a privileged property with user equal to nil. ' \
              'Remember to pass in user to the form if you want to set privileged properties'
    end

    return if SuperUserMethods.available_for? @user, property.required_privilege

    raise "User not allowed to send in this property User: #{@user.hashid}, requirement: #{property.required_privilege}"
  end

  def to_h
    dirty_properties.map { |property| [ property.name, public_send(property.name.to_s) ] }.to_h
  end

  def dirty_properties
    defined_properties.select { |property| instance_variable_defined? "@#{property.name}" }
  end

  def transaction_closed?
    ActiveRecord::Base.with_connection { |connection| connection.open_transactions == 0 }
  end

  # Resolves a record by numeric id or hashid (when using hashid-rails). Returns nil if not found.
  def find_associated_by_id_or_hashid(associated_class, value)
    return nil if value.blank?

    associated_class.find(value)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def self.inherited(subclass)
    subclass.class_attribute :defined_properties, instance_accessor: true, default: try(:defined_properties).dup || []
    subclass.class_attribute :defined_subforms, instance_accessor: true, default: try(:defined_subforms).dup || []
  end

  def self.validate_attachment(name, attachment_type:, max_size_mb: nil, required: false, base_error: false)
    include ApplyMate::FormObject::AttachmentValidator

    raise 'Attachment name is not defined' if name.nil?
    raise 'Attachment type is not defined' if attachment_type.nil?

    at  = attachment_type
    max = max_size_mb
    be  = base_error

    define_method(:"validate_#{name}_format") { run_attachment_format_check(name, at, be) }
    validate :"validate_#{name}_format"

    if required
      define_method(:"validate_#{name}_presence") { run_attachment_presence_check(name, be) }
      validate :"validate_#{name}_presence"
    end

    if max_size_mb
      define_method(:"validate_#{name}_size") { run_attachment_size_check(name, max, be) }
      validate :"validate_#{name}_size"
    end
  end
end
