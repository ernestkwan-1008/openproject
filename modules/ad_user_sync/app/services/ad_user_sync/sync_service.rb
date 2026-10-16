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
  # Reconciles OpenProject users and departments with the AD / Entra ID user list CSV.
  #
  # * The mail address is the key (case-insensitive).
  # * Users in the CSV but not in OpenProject are created as invited users (login = mail, no password,
  #   no invitation email). They register on their first Entra sign-in, where the OIDC login is matched
  #   to them by login, so there is no self-registration.
  # * Users in both get displayName (first/last name), jobTitle and department refreshed.
  # * Departments are plain (non-LDAP-managed) organizational units created by name when missing.
  # * Normal users that are not in the CSV are locked. Admins, builtin users and users holding a
  #   global role are never locked.
  # * A run that would lock more than +max_lock_percent+ of the normal users is aborted unless
  #   +force+ is set. With +dry_run+ nothing is written.
  #
  # Returns a ServiceResult. On success the result is a Hash with the keys
  # :created, :updated, :reactivated, :locked, :departments_created (Arrays) and :errors, :warnings.
  class SyncService
    CSV_FILE_NAME = "user_list.csv"
    DEFAULT_MAX_LOCK_PERCENT = 20
    JOB_TITLE_FIELD_NAME = "Job title"
    TEXT_FORMATS = %w[string text].freeze
    LOG_PREFIX = "[AD user sync]"

    # user_list.csv inside the directory given by AD_IMPORT_DIR (set in .env, passed on by docker-compose.yml).
    def self.default_path
      File.join(ENV.fetch("AD_IMPORT_DIR") { raise "AD_IMPORT_DIR is not set" }, CSV_FILE_NAME)
    end

    def self.default_max_lock_percent
      Float(ENV.fetch("AD_USER_SYNC_MAX_LOCK_PERCENT", DEFAULT_MAX_LOCK_PERCENT))
    end

    def self.default_reactivate
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("AD_USER_SYNC_REACTIVATE", "true"))
    end

    # Human-readable lines for the summary Hash returned by #call (used by the rake tasks).
    def self.report_lines(summary)
      lines = []
      lines << "DRY RUN - no changes written" if summary[:dry_run]
      %i[created updated reactivated locked departments_created inboxes_created].each do |key|
        lines << "#{key.to_s.tr('_', ' ')}: #{summary[key].size}"
        summary[key].each { |entry| lines << "  #{entry}" }
      end
      summary[:warnings].each { |warning| lines << "warning: #{warning}" }
      summary[:errors].each { |error| lines << "error: #{error}" }
      lines
    end

    attr_reader :path, :dry_run, :force, :max_lock_percent, :reactivate

    def initialize(path: self.class.default_path,
                   dry_run: false,
                   force: false,
                   max_lock_percent: self.class.default_max_lock_percent,
                   reactivate: self.class.default_reactivate)
      @path = path
      @dry_run = dry_run
      @force = force
      @max_lock_percent = max_lock_percent
      @reactivate = reactivate
    end

    def call
      read = CsvReader.new(path).call
      return abort_run(read.message) if read.failure?

      rows = read.result[:rows]
      @summary = new_summary(read.result[:warnings])

      load_state
      plan = build_plan(rows)

      guard = lock_guard_message(plan[:to_lock])
      if guard && dry_run
        @summary[:warnings] << "a real run would be ABORTED by the safety guard: #{guard}"
      elsif guard
        return abort_run(guard)
      end

      execute(plan)
      log_summary
      ServiceResult.success(result: @summary)
    end

    private

    def new_summary(warnings)
      { created: [], updated: [], reactivated: [], locked: [], departments_created: [], inboxes_created: [],
        errors: [], warnings: warnings.dup, dry_run: }
    end

    def abort_run(message)
      Rails.logger.error("#{LOG_PREFIX} aborted, no changes made: #{message}")
      ServiceResult.failure(message:)
    end

    # --- State -----------------------------------------------------------------------------

    def load_state
      @users = User.not_builtin.to_a
      @users_by_key = @users.select { |u| u.mail.present? }.index_by { |u| key_for(u.mail) }
      @protected_ids = protected_user_ids
      @departments = Group.with_detail.organizational_units.to_a
    end

    def key_for(mail)
      mail.to_s.strip.downcase
    end

    # Admins and users holding a global role (directly or through a group) are never locked.
    def protected_user_ids
      principal_ids = Member.global.distinct.pluck(:user_id)
      group_ids = Group.where(id: principal_ids).pluck(:id)
      member_ids = GroupUser.where(group_id: group_ids).pluck(:user_id)

      (principal_ids + member_ids + User.not_builtin.admin.pluck(:id)).to_set
    end

    def normal_user?(user)
      !user.admin? && @protected_ids.exclude?(user.id)
    end

    # --- Plan ------------------------------------------------------------------------------

    def build_plan(rows)
      csv_keys = rows.to_set(&:key)

      {
        rows:,
        to_lock: @users.select { |u| normal_user?(u) && !u.locked? && csv_keys.exclude?(key_for(u.mail)) }
      }
    end

    def lock_guard_message(to_lock)
      return if force || to_lock.empty?

      candidates = @users.count { |u| normal_user?(u) && !u.locked? }
      allowed = candidates * max_lock_percent / 100.0
      return if to_lock.size <= allowed

      "would lock #{to_lock.size} of #{candidates} normal users, above the #{max_lock_percent}% safety limit " \
        "(check #{path}, or run with force to override)"
    end

    # --- Execution -------------------------------------------------------------------------

    def execute(plan)
      @job_title_field = job_title_field
      @inbox_supported = inbox_supported?
      warn_when_owner_role_cannot_share if @inbox_supported

      plan[:rows].each do |row|
        user = @users_by_key[row.key]
        user ? update_existing(user, row) : create_new(row)
      end

      plan[:to_lock].each { |user| lock(user) }
    end

    def guarded(label)
      yield
    rescue StandardError => e
      record_error("#{label}: #{e.class}: #{e.message}")
    end

    def record_error(message)
      Rails.logger.error("#{LOG_PREFIX} #{message}")
      @summary[:errors] << message
    end

    def record_call_error(label, call)
      record_error("#{label}: #{call.message.presence || call.errors.full_messages.to_sentence}")
    end

    # --- Create ----------------------------------------------------------------------------

    def create_new(row)
      @summary[:created] << row.mail

      if dry_run
        dry_run_new_department(row.department) if row.department.present? && find_department(row.department).nil?
        @summary[:inboxes_created] << row.mail if @inbox_supported
        return
      end

      user = nil
      guarded("create #{row.mail}") do
        user = create_invited_user(row)
        if user
          assign_department(user, row)
        else
          @summary[:created].delete(row.mail)
        end
      end
      ensure_inbox(user, row) if user
    end

    # Creates the user in the "invited" state, like an invitation, but without sending the invitation
    # email: the user never sets a password and registers on the first Entra sign-in, where
    # OmniauthService matches the invited user by login (= mail) and activates it.
    def create_invited_user(row)
      call = Users::SetAttributesService
               .new(user: User.system, model: User.new, contract_class: Users::CreateContract)
               .call(create_attributes(row))

      unless call.success?
        record_call_error("create #{row.mail}", call)
        return nil
      end

      invited = UserInvitation.invite_user!(call.result, send_notification: false)
      record_error("create #{row.mail}: #{call.result.errors.full_messages.to_sentence}") if invited.nil?
      invited
    end

    def create_attributes(row)
      first, last = split_name(row.display_name) || fallback_name(row.mail)

      attrs = {
        login: row.mail, mail: row.mail, firstname: first, lastname: last,
        status: User.statuses[:invited]
      }
      attrs[:custom_field_values] = { @job_title_field.id => row.job_title } if @job_title_field && row.job_title.present?
      attrs
    end

    # --- Update ----------------------------------------------------------------------------

    def update_existing(user, row)
      changed = false

      changed |= update_attributes(user, row)
      changed |= reactivate_user(user, row)
      changed |= update_department(user, row)

      @summary[:updated] << row.mail if changed
      ensure_inbox(user, row) unless user.locked? && !reactivate
    end

    def update_attributes(user, row)
      attrs = changed_attributes(user, row)
      return false if attrs.empty?
      return true if dry_run

      guarded("update #{row.mail}") do
        call = Users::UpdateService.new(user: User.system, model: user).call(attrs)
        return true if call.success?

        record_call_error("update #{row.mail}", call)
      end
      false
    end

    def changed_attributes(user, row)
      attrs = {}

      first, last = split_name(row.display_name)
      attrs[:firstname] = first if first && user.firstname != first
      attrs[:lastname] = last if last && user.lastname != last

      if @job_title_field && current_job_title(user) != row.job_title
        attrs[:custom_field_values] = { @job_title_field.id => row.job_title }
      end

      attrs
    end

    def current_job_title(user)
      user.custom_value_for(@job_title_field)&.value.to_s
    end

    # The CSV is authoritative: a locked user that is listed again becomes active.
    def reactivate_user(user, row)
      return false unless reactivate && user.locked?

      @summary[:reactivated] << row.mail
      return true if dry_run

      guarded("reactivate #{row.mail}") do
        call = Users::UpdateService.new(user: User.system, model: user).call(status: User.statuses[:active])
        return true if call.success?

        @summary[:reactivated].delete(row.mail)
        record_call_error("reactivate #{row.mail}", call)
      end
      false
    end

    # --- Lock ------------------------------------------------------------------------------

    def lock(user)
      @summary[:locked] << (user.mail.presence || user.login)
      return if dry_run

      guarded("lock #{user.login}") do
        call = Users::UpdateService.new(user: User.system, model: user).call(status: User.statuses[:locked])
        unless call.success?
          @summary[:locked].pop
          record_call_error("lock #{user.login}", call)
        end
      end
    end

    # --- Departments -----------------------------------------------------------------------

    def update_department(user, row)
      current = user.department
      return false if row.department.blank? && current.nil?

      if row.department.blank?
        remove_department(user, current, row)
      else
        move_to_department(user, current, row)
      end
    end

    def move_to_department(user, current, row)
      target = find_department(row.department)

      if dry_run
        return dry_run_new_department(row.department) if target.nil?

        return current&.id != target.id
      end

      return false if target && current&.id == target.id

      assign_department(user, row, target:)
    end

    def assign_department(user, row, target: nil)
      return false if row.department.blank?

      target ||= find_or_create_department(row.department)
      return false unless target

      call = Departments::AddUserService
               .new(target, user: User.system)
               .call(user_id: user.id, remove_from_previous_department: true)
      return true if call.success?

      record_call_error("department of #{row.mail}", call)
      false
    rescue StandardError => e
      record_error("department of #{row.mail}: #{e.class}: #{e.message}")
      false
    end

    def remove_department(user, current, row)
      return true if dry_run

      call = Departments::RemoveUserService.new(current, user: User.system).call(user_id: user.id)
      return true if call.success?

      record_call_error("remove department of #{row.mail}", call)
      false
    end

    # In dry-run mode a missing department is only reported, never created.
    def dry_run_new_department(name)
      return false unless dry_run

      @summary[:departments_created] |= [name]
      true
    end

    def find_department(name)
      matches = @departments.select { |group| group.name.casecmp?(name) }
      matches.find { |group| group.parent_id.nil? } || matches.min_by(&:id)
    end

    def find_or_create_department(name)
      find_department(name) || create_department(name)
    end

    def create_department(name)
      call = Groups::CreateService.new(user: User.system).call(lastname: name, organizational_unit: true)

      if call.success?
        @summary[:departments_created] << name
        @departments << call.result
        call.result
      else
        record_call_error("create department '#{name}'", call)
        nil
      end
    end

    # --- Job title custom field --------------------------------------------------------------

    # Finds, or in a real run creates, a text user custom field for the job title.
    def job_title_field
      candidates = UserCustomField.where(name: JOB_TITLE_FIELD_NAME).to_a
      semantic = UserCustomField.for_semantic_key(:job_title)
      candidates.unshift(semantic) if semantic && candidates.exclude?(semantic)

      field = candidates.find { |cf| TEXT_FORMATS.include?(cf.field_format) }
      return field if field

      if candidates.any?
        @summary[:warnings] << "Job title custom field exists but is not a text field " \
                               "(#{candidates.first.field_format}); job titles are not synchronized"
        return nil
      end

      create_job_title_field unless dry_run
    end

    def create_job_title_field
      UserCustomField.create!(
        name: JOB_TITLE_FIELD_NAME,
        field_format: "string",
        editable: false,
        custom_field_section_id: user_custom_field_section.id,
        semantic_key: "job_title"
      )
    rescue StandardError => e
      @summary[:warnings] << "Could not create the Job title custom field: #{e.message}"
      nil
    end

    # Mirrors the fallback of the development seeder: not every edition seeds the default section.
    def user_custom_field_section
      UserCustomFieldSection.order(:position).first ||
        UserCustomFieldSection.new(position: 1, attribute_order: UserCustomFieldSection::BUILT_IN_ATTRIBUTES)
                              .tap { |section| section.save!(validate: false) }
    end

    # --- "My inbox" private project --------------------------------------------------------

    # Inbox identifiers are classic-format slugs, so the feature is skipped in semantic identifier mode.
    def inbox_supported?
      return true unless Setting::WorkPackageIdentifier.semantic?

      @summary[:warnings] << "Project identifiers are in semantic mode; the 'My inbox' projects are not created"
      false
    end

    # Makes sure the user owns a private "My inbox" project, favorited for them. Only checked for users who
    # are (or become) active. The inbox is recognised by its identifier; see Inbox.identifiers_for.
    def ensure_inbox(user, row)
      return unless @inbox_supported
      return if user.locked? && !dry_run

      Inbox.identifiers_for(row.mail).each do |identifier|
        project = Project.unscoped.where("LOWER(identifier) = ?", identifier).first

        if project
          # Existing inbox of this user (also when archived): nothing to create; repair the module if needed.
          return repair_inbox(project) if project.members.exists?(user_id: user.id)
        elsif !identifier_reserved?(identifier)
          return create_inbox(user, row, identifier)
        end
        # The identifier belongs to someone else (same account name on another domain): try the next one.
      end

      record_error("inbox of #{row.mail}: no free project identifier found")
    end

    # Inboxes created before work packages were part of the idea may lack the work package module.
    def repair_inbox(project)
      return if dry_run || project.module_enabled?(Inbox::REQUIRED_MODULE)

      guarded("repair inbox #{project.identifier}") { Inbox.ensure_work_package_tracking(project) }
    end

    # The owner needs to share single work packages, which two permissions allow.
    def warn_when_owner_role_cannot_share
      role = ProjectRole.in_new_project
      return unless role

      missing = %w[share_work_packages view_shared_work_packages] - role.permissions.map(&:to_s)
      return if missing.empty?

      @summary[:warnings] << "The 'new project' role '#{role.name}' lacks #{missing.join(', ')}: inbox owners " \
                             "cannot share single work packages (Administration > Roles and permissions)"
    end

    # Identifiers of deleted/renamed projects stay reserved by FriendlyId and cannot be reused.
    def identifier_reserved?(identifier)
      Project.identifier_slugs.for_identifier(identifier).exists?
    end

    def create_inbox(user, row, identifier)
      @summary[:inboxes_created] << row.mail
      return if dry_run

      errors_before = @summary[:errors].size

      guarded("inbox of #{row.mail}") do
        # One transaction: when the membership cannot be created, no half-built inbox is left behind.
        Project.transaction do
          project = create_inbox_project(identifier)
          add_inbox_owner(project, user)
          project.set_favorited(user, favorited: true)
        end
      end

      @summary[:inboxes_created].delete(row.mail) if @summary[:errors].size > errors_before
    end

    def create_inbox_project(identifier)
      modules = (Setting.default_projects_modules.to_a | [Inbox::REQUIRED_MODULE]).map(&:to_s)
      call = Projects::CreateService
               .new(user: User.system)
               .call(name: Inbox::NAME, identifier:, public: false, enabled_module_names: modules)
      raise failure_message("create project #{identifier}", call) unless call.success?

      call.result
    end

    # Created by the system user, so the project creator's "new project" role has to be granted explicitly.
    # Without a project-admin like role the user could not share the inbox.
    def add_inbox_owner(project, user)
      role = ProjectRole.in_new_project
      raise "no role available for the owner of #{project.identifier} (see Administration > Projects)" unless role

      call = Members::CreateService
               .new(user: User.system, contract_class: EmptyContract)
               .call(roles: [role], project:, principal: user, send_notifications: false)
      raise failure_message("add #{user.mail} to #{project.identifier}", call) unless call.success?
    end

    def failure_message(label, call)
      "#{label}: #{call.message.presence || call.errors.full_messages.to_sentence}"
    end

    # --- Names -----------------------------------------------------------------------------

    # OpenProject stores first and last name separately, the CSV has a single display name:
    # the first word becomes the first name, the rest the last name (a single word fills both).
    def split_name(display_name)
      cleaned = display_name.to_s.gsub(User::INVALID_NAME_REGEX, "").squish
      return nil if cleaned.empty?

      first, rest = cleaned.split(" ", 2)
      [first, rest.presence || first]
    end

    def fallback_name(mail)
      local, domain = mail.split("@", 2)
      [local, domain]
    end

    # --- Reporting -------------------------------------------------------------------------

    def log_summary
      s = @summary
      Rails.logger.info(
        "#{LOG_PREFIX} #{'dry run ' if dry_run}done: created=#{s[:created].size} updated=#{s[:updated].size} " \
        "reactivated=#{s[:reactivated].size} locked=#{s[:locked].size} " \
        "departments_created=#{s[:departments_created].size} inboxes_created=#{s[:inboxes_created].size} " \
        "errors=#{s[:errors].size} warnings=#{s[:warnings].size}"
      )
    end
  end
end
