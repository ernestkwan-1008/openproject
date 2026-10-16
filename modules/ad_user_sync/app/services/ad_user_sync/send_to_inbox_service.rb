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
  # "Send to inbox": the sender puts a work package into the private "My inbox" project of the recipient,
  # assigned to the recipient. The sender is not a member of that project; instead the sender is shared on this
  # one work package with the "Work package commenter" role, so the sender can follow the progress and
  # comment, but never sees anything else in the inbox.
  #
  # Everything happens in one transaction. Returns a ServiceResult whose result is the new work package.
  class SendToInboxService
    # Shares::CreateService always mails the shared user; the sender created the work package himself,
    # so no "work package shared with you" mail is wanted.
    class SilentShareService < Shares::CreateService
      private

      def send_notification(_share); end
    end

    attr_reader :sender

    def initialize(sender:)
      @sender = sender
    end

    def call(recipient:, subject:, description: nil, due_date: nil)
      error = precondition_error(recipient, subject)
      return ServiceResult.failure(message: error) if error

      result = nil

      ActiveRecord::Base.transaction do
        result = create_work_package(recipient, subject, description, due_date)
        result = share_with_sender(result) if result.success?

        raise ActiveRecord::Rollback if result.failure?
      end

      result
    end

    # Users who can receive work packages: active/invited, not the sender, with an inbox.
    def self.recipients(sender)
      users = User
                .not_builtin
                .where(status: [User.statuses[:active], User.statuses[:invited]])
                .where.not(id: sender.id)
                .order(:firstname, :lastname)
                .to_a

      # One query for all inboxes instead of one per user (about the size of the company).
      identifiers_by_user = Member
                              .joins(:project)
                              .where(projects: { active: true })
                              .where("LOWER(projects.identifier) LIKE ?", "#{Inbox::IDENTIFIER_PREFIX}%")
                              .where(user_id: users.map(&:id))
                              .pluck(:user_id, "LOWER(projects.identifier)")
                              .group_by(&:first)

      users.select do |user|
        owned = identifiers_by_user.fetch(user.id, []).map(&:last)
        (owned & Inbox.identifiers_for(user.mail)).any?
      end
    end

    private

    def precondition_error(recipient, subject)
      if !sender.logged? || sender.locked?
        I18n.t("ad_user_sync.send_to_inbox.errors.not_allowed")
      elsif recipient.nil? || recipient.id == sender.id || recipient.builtin? || recipient.locked?
        I18n.t("ad_user_sync.send_to_inbox.errors.invalid_recipient")
      elsif subject.to_s.strip.empty?
        I18n.t("ad_user_sync.send_to_inbox.errors.subject_blank")
      elsif !EnterpriseToken.allows_to?(:work_package_sharing)
        I18n.t("ad_user_sync.send_to_inbox.errors.sharing_unavailable")
      elsif commenter_role.nil?
        I18n.t("ad_user_sync.send_to_inbox.errors.role_missing")
      elsif Inbox.for(recipient).nil?
        I18n.t("ad_user_sync.send_to_inbox.errors.no_inbox", name: recipient.name)
      end
    end

    def commenter_role
      @commenter_role ||= WorkPackageRole.find_by(builtin: Role::BUILTIN_WORK_PACKAGE_COMMENTER)
    end

    # Runs as the sender (journal, author, watcher) without a contract: the sender has no rights in the
    # recipient's inbox, and this service has just checked everything that matters.
    def create_work_package(recipient, subject, description, due_date)
      inbox = Inbox.for(recipient)
      Inbox.ensure_work_package_tracking(inbox)

      attributes = { project: inbox, subject: subject.to_s.strip, description:, author: sender, assigned_to: recipient }
      attributes[:due_date] = due_date if due_date.present?

      WorkPackages::CreateService.new(user: sender, contract_class: EmptyContract).call(attributes)
    end

    def share_with_sender(create_result)
      work_package = create_result.result

      share = SilentShareService
                .new(user: User.system, contract_class: EmptyContract)
                .call(user_id: sender.id, role_ids: [commenter_role.id], entity: work_package)

      if share.success?
        create_result
      else
        ServiceResult.failure(message: share.message.presence || share.errors.full_messages.to_sentence)
      end
    end
  end
end
