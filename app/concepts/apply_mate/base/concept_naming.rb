# frozen_string_literal: true

module ApplyMate::Base::ConceptNaming
  CONCEPT_MODULES = %w[Operation FormObject Component].freeze

  # Gives the following result when called from concepts
  # Salary::Employee::Component::New => Employee
  # Sale::Product::Operation::Update => Sale::Product
  def concept_class_name(clazz = self.class)
    concept_full_class_name(clazz).split('::').last
  end

  # Usable for .new etc. Examples:
  # Salary::Employee::Component::New => Salary::Employee
  # Sale::Product::Operation::Update => Sale::Product
  def concept_full_class_name(clazz = self.class)
    re = Regexp.union(CONCEPT_MODULES.map { |w| /\s*\b#{Regexp.escape(w)}\b\s*/i })
    left = clazz.name.split(re).first
    left.delete_suffix('::')
  end

  # Usable for paths etc. Examples:
  # Salary::Employee::Component::New => salary_employee
  # Sale::Product::Operation::Update => product
  def concept_underscored_full_class_name(clazz = self.class)
    concept_full_class_name(clazz).split('::').map(&:underscore).join('_')
  end

  # Usable for ids in html etc. Examples:
  # Salary::Employee::Component::New => salary-employee
  # Sale::Product::Operation::Update => product
  def concept_hyphenated_full_class_name(clazz = self.class)
    concept_underscored_full_class_name(clazz).tr('_', '-')
  end

  ## Usable for variables. Examples
  # Salary::Employee::Component::New => employee
  # Sale::Product::Operation::Update => product
  def concept_underscored_class_name(clazz = self.class)
    concept_class_name(clazz).underscore
  end

  # Usable for i18n-keys Examples:
  # Salary::Employee::Component::New => salary/employee
  # Sale::Invoice::Operation::Update => sale/invoice
  def concept_i18n_path(clazz = self.class)
    concept_full_class_name(clazz).split('::').map(&:underscore).join('/')
  end
end
