# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "openproject-ad_user_sync"
  s.version     = "1.0.0"
  s.authors     = "OpenProject GmbH"
  s.email       = "info@openproject.com"
  s.homepage    = "https://github.com/opf/openproject"
  s.summary     = "OpenProject AD user list synchronization"
  s.description = "Daily synchronization of users and departments from an Active Directory / Entra ID CSV export"
  s.license     = "GPL-3"

  s.files = Dir["{app,config,db,lib}/**/*"]
  s.metadata["rubygems_mfa_required"] = "true"
end
