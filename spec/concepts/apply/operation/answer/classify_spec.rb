# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::Classify do
  def classify(platform: nil, **field)
    described_class.call(field: answer_field(**field), platform:).model
  end

  {
    'full_name' => [ 'Full name', "Повне ім'я", 'ПІБ', 'Name', 'Name *', 'Your name:', 'Ваше фио', "Ім'я та прізвище" ],
    'first_name' => [ 'First name', 'Given name', "Ім'я", 'Имя', 'First name *' ],
    'last_name' => [ 'Last name', 'Surname', 'Прізвище', 'Фамилия' ],
    'email' => [ 'Work email', 'E-mail', 'Email address', 'Електронна пошта', 'Ваша почта' ],
    'phone' => [ 'Phone number', 'Mobile', 'Mobile phone number', 'Phone number (with country code) *', 'Телефон' ],
    'linkedin' => [ 'LinkedIn profile', 'Linkedin URL' ],
    'github' => [ 'GitHub', 'Your github account' ],
    'location' => [ 'Current location', 'City', 'Location*', 'Where are you based?', 'Країна проживання', 'Город' ],
    'salary' => [ 'Salary expectations', 'Очікувана зарплата', 'Желаемая зарплат' ],
    'cover_letter' => [ 'Cover letter', 'Супровідний лист', 'Сопроводительное письмо' ],
    'marketing_opt_in' => [ 'Subscribe to our newsletter', 'I agree to receive marketing emails', 'Розсилка новин', 'Рассылка' ],
    'consent_required' => [ 'I agree to the privacy policy', 'GDPR consent', 'Я погоджуюсь на обробку персональних даних',
                            'Согласие на обработку', 'I acknowledge the terms' ],
    'demographic' => [ 'Gender', 'Race/Ethnicity', 'Veteran status', 'Disability status', 'Ваша стать', 'Nationality',
                       'National origin', 'Национальность' ],
    'legal_status' => [ 'Are you legally authorized to work in the US?', 'Will you require visa sponsorship?',
                        'Дозвіл на роботу', 'Разрешение на работу', 'Right to work', 'Citizenship', 'Гражданство',
                        'Громадянство' ]
  }.each do |semantic, labels|
    labels.each do |label|
      it "classifies #{label.inspect} as #{semantic}" do
        expect(classify(label:)).to eq(semantic)
      end
    end
  end

  it 'falls back to other' do
    expect(classify(label: 'Why do you want to work here?')).to eq('other')
  end

  # A profile fact is filled at confidence 1.0 and a consent affirmed under the default auto_consent, with no review:
  # a label that merely contains a fact word or "agree" must go to the AI instead.
  [
    'Are you open to relocation?', 'Which city do you want to relocate to?', 'Describe your mobile development experience',
    'Name of your current employer', 'Do you agree to work from the office 3 days a week?',
    'Do you acknowledge that the role requires travel?', 'Years of experience in performance marketing',
    'Do you have experience with GDPR compliance?', 'Phone interview availability', 'Email of your referee',
    'Чи погоджуєтесь ви на релокацію?', 'Согласны ли вы на переезд?'
  ].each do |label|
    it "does not classify #{label.inspect} by a fact or consent word inside it" do
      expect(classify(label:)).to eq('other')
    end
  end

  it 'reads the placeholder when the label says nothing' do
    expect(classify(label: 'Contact', placeholder: 'Your phone')).to eq('phone')
  end

  it 'prefers the platform key over everything else' do
    platform = instance_double(Apply::Platform::Ashby, semantic_for: 'full_name')

    expect(classify(platform:, label: 'Gender', kind: 'email')).to eq('full_name')
  end

  it 'maps the Ashby system fields' do
    ctx = engine_context(create(:apply))
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(key: 'ashby', confidence: 1.0, captures: {}, frame_path: nil,
                                                                 from_alias: false, probable: nil))
    {
      '_systemfield_name' => 'full_name', '_systemfield_email' => 'email', '_systemfield_resume' => 'cv',
      '_systemfield_phone' => 'phone'
    }.each do |key, semantic|
      expect(classify(platform: ctx.platform, id: "ashby:#{key}", label: 'x')).to eq(semantic)
    end
  end

  it 'honours the password flag set at discovery' do
    expect(classify(label: 'Create a password', semantic: 'password')).to eq('password')
    expect(classify(label: 'Email', semantic: 'password')).to eq('password')
  end

  it 'classifies a file input as the cv' do
    expect(classify(kind: 'file', label: 'Anything')).to eq('cv')
  end

  it 'uses the input kind before the label' do
    expect(classify(kind: 'email', label: 'Reach me')).to eq('email')
    expect(classify(kind: 'tel', label: 'Reach me')).to eq('phone')
  end

  it 'uses the autocomplete attribute before the label' do
    expect(classify(autocomplete: 'section-x given-name', label: 'Reach me')).to eq('first_name')
    expect(classify(autocomplete: 'family-name', label: 'Reach me')).to eq('last_name')
    expect(classify(autocomplete: 'new-password', label: 'Reach me')).to eq('password')
  end

  describe 'the lexicon' do
    it 'declares every regex under one semantic only' do
      sources = described_class::LEXICON.fetch('semantics').values.flatten

      expect(sources).to eq(sources.uniq)
    end

    it 'only names real semantics' do
      expect(described_class::LEXICON.fetch('semantics').keys - Apply::Field::SEMANTICS).to be_empty
    end

    it 'has affirm and decline phrases' do
      expect(described_class::AFFIRM).to include('i agree')
      expect(described_class::DECLINE).to include('prefer not to say')
    end
  end
end
