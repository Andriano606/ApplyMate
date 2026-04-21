# frozen_string_literal: true

OmniAuth.config.test_mode = true
OmniAuth.config.allowed_request_methods = [ :post, :get ]
OmniAuth.config.silence_get_warning = true

OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
  provider: 'google_oauth2',
  uid: '101581344228860591082',
  info: {
    email: 'andreykuluev96@gmail.com',
    name: 'Andrey Kuluev',
    image: 'https://lh3.googleusercontent.com/a/ACg8ocJUcQIYp-G_Wi7TLgPd8NgGYfXABa7XPDOu7evkGLpPIvspYkkI'
  }
)
