# frozen_string_literal: true

andrii = users.create :andrii,
                      unique_by: %i[provider uid],
                      name: 'Andrey Kuluev',
                      email: 'andreykuluev96@gmail.com',
                      provider: 'google_oauth2',
                      uid: '101581344228860591082',
                      admin: true,
                      avatar_url: 'https://lh3.googleusercontent.com/a/ACg8ocJUcQIYp-G_Wi7TLgPd8NgGYfXABa7XPDOu7evkGLpPIvspYkkI'

andrii.download_avatar! unless andrii.avatar.attached?
