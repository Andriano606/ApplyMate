# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::Classify do
  def classify(platform: nil, **field)
    described_class.call(field: answer_field(**field), platform:).model
  end

  {
    'full_name' => [ 'Full name', "Повне ім'я", 'ПІБ', 'Name', 'Name *', 'Your name:', 'Ваше фио', "Ім'я та прізвище",
                     'First name, last name', 'First / last name', 'Given name and family name', "Ім'я, прізвище",
                     "Ім'я / прізвище", 'Имя, фамилия' ],
    'first_name' => [ 'First name', 'Given name', "Ім'я", 'Імʼя', 'Имя', 'First name *' ],
    'last_name' => [ 'Last name', 'Surname', 'Прізвище', 'Фамилия' ],
    'email' => [ 'Work email', 'E-mail', 'Email address', 'Електронна пошта', 'Ваша почта' ],
    'phone' => [ 'Phone number', 'Mobile', 'Mobile phone number', 'Phone number (with country code) *', 'Телефон' ],
    'linkedin' => [ 'LinkedIn profile', 'Linkedin URL' ],
    'github' => [ 'GitHub', 'Your github account' ],
    'country' => [ 'Country', 'Country of residence', 'Країна проживання', 'Страна', 'Країна *' ],
    'location' => [ 'Current location', 'City', 'Location*', 'Where are you based?', 'Місто проживання', 'Город' ],
    'salary' => [ 'Salary expectations', 'Очікувана зарплата', 'Желаемая зарплат', 'Бажана базова компенсація',
                  'Desired compensation', 'Expected pay', 'Бажаний оклад', 'Очікувана ставка' ],
    'cover_letter' => [ 'Cover letter', 'Супровідний лист', 'Сопроводительное письмо' ],
    'marketing_opt_out' => [ 'I do not want to receive the newsletter', "I don't want marketing emails", 'Unsubscribe',
                             'Opt-out of marketing emails', 'Не хочу отримувати розсилку' ],
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

  # An opt-in / consent / EEO label that merely mentions unsubscribing or opting out is never ticked as an opt-out.
  {
    "I'd like to receive the newsletter and job alerts. You can unsubscribe at any time." => 'marketing_opt_in',
    'Send me marketing emails; you may opt-out anytime' => 'marketing_opt_in',
    'I agree to the privacy policy; I can unsubscribe at any time' => 'consent_required',
    'Gender - you may opt out of answering' => 'demographic'
  }.each do |label, semantic|
    it "classifies #{label.inspect} as #{semantic}, not marketing_opt_out" do
      expect(classify(label:)).to eq(semantic)
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
    'Чи погоджуєтесь ви на релокацію?', 'Согласны ли вы на переезд?', 'Which countries have you worked in?'
  ].each do |label|
    it "does not classify #{label.inspect} by a fact or consent word inside it" do
      expect(classify(label:)).to eq('other')
    end
  end

  describe 'file fields (by label first, never "every upload is the CV")' do
    it 'classifies a cover / motivation letter upload as cover_letter, even when required' do
      [ 'Cover Letter', 'Motivation letter', 'Супровідний лист' ].each do |label|
        expect(classify(label:, kind: 'file', required: true)).to eq('cover_letter')
      end
    end

    it 'classifies an upload that names the CV as cv' do
      [ 'Resume/CV', 'Add your resume or CV', 'Резюме', 'Upload CV' ].each do |label|
        expect(classify(label:, kind: 'file')).to eq('cv')
      end
    end

    it 'classifies portfolio / additional / other attachments as other, even when required' do
      [ 'Portfolio', 'Additional files', 'Додаткові файли', 'Other attachments',
        'Need to share files with us? Attach PDF, PNG or JPG formats only.' ].each do |label|
        expect(classify(label:, kind: 'file', required: true)).to eq('other')
      end
    end

    it 'takes an unlabelled upload (no label, or only "Attach") for the CV' do
      expect(classify(label: nil, kind: 'file')).to eq('cv')
      expect(classify(label: 'Attach', kind: 'file')).to eq('cv')
    end

    it 'takes an upload with an unknown label for the CV only when the form requires it' do
      expect(classify(label: 'Anything', kind: 'file', required: true)).to eq('cv')
      expect(classify(label: 'Anything', kind: 'file')).to eq('other')
    end

    it 'names the CV slot only when the label says so (cv_file?)' do
      expect(described_class.cv_file?(answer_field(label: 'Add your resume or CV', kind: 'file'))).to be(true)
      expect(described_class.cv_file?(answer_field(label: 'Need to share files with us?', kind: 'file'))).to be(false)
    end
  end

  it 'tells resume-parse helpers apart from questions (helper_control?)' do
    expect(described_class.helper_control?(nil, 'Autofill from resume')).to be(true)
    expect(described_class.helper_control?('Resume', nil)).to be(false)
    expect([ 'Autocomplete from your resume', 'Parse resume', 'Import from LinkedIn' ])
      .to all(satisfy { |text| described_class.helper_control?(text) })
  end

  it 'never takes a resume-parse helper upload for the CV' do
    expect(classify(label: 'Autofill from resume', kind: 'file')).to eq('other')
    expect(classify(label: 'Upload file', description: 'Autofill from resume', kind: 'file')).to eq('other')
    expect(classify(label: 'Resume', kind: 'file')).to eq('cv')
  end

  it 'recognises names that say nothing about the question (generic_name?)' do
    expect([ 'Attach', 'Upload file', 'Acknowledge/Confirm', 'Type here...', 'Yes', '+380', '$' ]).to all(satisfy { |name| described_class.generic_name?(name) })
    expect([ 'Resume', 'Attach your CV', nil ]).to all(satisfy { |name| !described_class.generic_name?(name) })
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

  it 'uses the input kind before the label' do
    expect(classify(kind: 'email', label: 'Reach me')).to eq('email')
    expect(classify(kind: 'tel', label: 'Reach me')).to eq('phone')
  end

  it 'uses the autocomplete attribute before the label' do
    expect(classify(autocomplete: 'section-x given-name', label: 'Reach me')).to eq('first_name')
    expect(classify(autocomplete: 'family-name', label: 'Reach me')).to eq('last_name')
    expect(classify(autocomplete: 'new-password', label: 'Reach me')).to eq('password')
    expect(classify(autocomplete: 'country-name', label: 'Reach me')).to eq('country')
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
      expect(described_class::AFFIRM).to include('i agree', 'yes')
      expect(described_class::DECLINE).to include('prefer not to say')
    end
  end
end
