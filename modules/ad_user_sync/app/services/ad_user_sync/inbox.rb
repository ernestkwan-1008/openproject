# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module AdUserSync
  # The private "My inbox" project every user owns: the user's personal space for work packages that
  # belong to no real project. Shared by the sync (creates inboxes) and "Send to inbox" (finds them).
  module Inbox
    NAME = "My inbox"
    IDENTIFIER_PREFIX = Projects::Identifier::INBOX_IDENTIFIER_PREFIX
    REQUIRED_MODULE = "work_package_tracking"

    # Candidate identifiers of the inbox of a mail address, in order of preference:
    # my-inbox-<account> (hedy.wu@hshd.com.hk => my-inbox-hedy-wu) and, when that belongs to somebody
    # else, my-inbox-<whole address> (my-inbox-hedy-wu-hshd-com-hk).
    def self.identifiers_for(mail)
      mail = mail.to_s.downcase
      account = mail.split("@", 2).first.to_s

      [account, mail].filter_map do |source|
        slug = source.gsub(/[^a-z0-9_]+/, "-").gsub(/\A-+|-+\z/, "")
        next if slug.empty?

        "#{IDENTIFIER_PREFIX}#{slug}".first(Projects::Identifier::CLASSIC_IDENTIFIER_MAX_LENGTH).sub(/-+\z/, "")
      end.uniq
    end

    # The active inbox that +user+ owns (is a member of), or nil. The identifier of an inbox is locked
    # (Projects::UpdateContract), so the lookup is stable.
    def self.for(user)
      identifiers = identifiers_for(user.mail)
      return nil if identifiers.empty?

      Project
        .unscoped
        .where(active: true)
        .where("LOWER(projects.identifier) IN (?)", identifiers)
        .joins(:members)
        .where(members: { user_id: user.id })
        .order(Arel.sql("LENGTH(projects.identifier)"))
        .first
    end

    # Idempotent: makes sure work packages can be created in the inbox.
    def self.ensure_work_package_tracking(project)
      EnabledModule.find_or_create_by!(project_id: project.id, name: REQUIRED_MODULE)
    end
  end
end
