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

module McpTools
  # Lets an external program hand a work package to a user: into the assignee's private "My inbox" project,
  # or, with project_id, into a regular project. Author and assignee are both set.
  class AssignWorkPackage < Base
    default_title "Assign work package"
    default_description "Creates a work package and assigns it to a user. Without project_id it is created in the " \
                        "assignee's private 'My inbox' project (the author can follow it and comment, nothing more). " \
                        "With project_id it is created in that project. The author defaults to the calling user; " \
                        "only administrators can set another author."

    name "assign_work_package"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      required: %w[assignee subject],
      properties: {
        assignee: {
          type: "string",
          description: "The user the work package is assigned to: user id or e-mail address."
        },
        subject: { type: "string", description: "The subject of the work package." },
        description: { type: "string", description: "Optional description (markdown)." },
        due_date: { type: "string", description: "Optional due date, format YYYY-MM-DD." },
        author: {
          type: "string",
          description: "Optional author as user id or e-mail address. Defaults to the calling user. " \
                       "Only administrators can set a different author."
        },
        project_id: {
          type: "number",
          description: "Optional id of the project to create the work package in. " \
                       "If omitted, the assignee's 'My inbox' project is used."
        }
      }
    )

    class InvalidInput < StandardError; end

    def call(assignee:, subject:, description: nil, due_date: nil, author: nil, project_id: nil)
      author_user = resolve_author(author)
      assignee_user = resolve_user(assignee, "assignee")
      date = parse_date(due_date)
      raise InvalidInput, "subject can't be blank." if subject.to_s.strip.empty?

      Rails.logger.info("[MCP assign_work_package] caller=#{current_user.id} author=#{author_user.id} " \
                        "assignee=#{assignee_user.id} project_id=#{project_id.inspect}")

      work_package = if project_id.present?
                       create_in_project(project_id, author_user, assignee_user, subject, description, date)
                     else
                       create_in_inbox(author_user, assignee_user, subject, description, date)
                     end

      summary(work_package)
    rescue InvalidInput => e
      { error: e.message }
    end

    private

    def resolve_author(author)
      return current_user if author.blank?

      user = resolve_user(author, "author")
      return user if user.id == current_user.id
      raise InvalidInput, "Only administrators can set a different author." unless current_user.admin?

      user
    end

    # Accepts a numeric id or an e-mail address. Non-admins only reach users they can see.
    def resolve_user(value, label)
      scope = User.not_builtin.where(status: [User.statuses[:active], User.statuses[:invited]])
      scope = scope.merge(User.visible(current_user)) unless current_user.admin?

      value = value.to_s.strip
      user = if value.match?(/\A\d+\z/)
               scope.find_by(id: value)
             else
               scope.find_by("LOWER(users.mail) = ?", value.downcase)
             end

      user || raise(InvalidInput, "The #{label} '#{value}' could not be found or is not active.")
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidInput, "due_date must have the format YYYY-MM-DD."
    end

    def create_in_inbox(author, assignee, subject, description, due_date)
      call = AdUserSync::SendToInboxService
               .new(sender: author)
               .call(recipient: assignee, subject:, description:, due_date:)
      raise InvalidInput, call.message unless call.success?

      call.result
    end

    def create_in_project(project_id, author, assignee, subject, description, due_date)
      project = Project.visible(current_user).find_by(id: project_id)
      raise InvalidInput, "The project could not be found." if project.nil?

      attributes = { project:, subject: subject.to_s.strip, description:, assigned_to: assignee }
      attributes[:due_date] = due_date if due_date

      call = if author.id == current_user.id
               WorkPackages::CreateService.new(user: current_user).call(**attributes)
             else
               create_as_other_author(project, author, assignee, attributes)
             end
      raise InvalidInput, call.message unless call.success?

      call.result
    end

    # Administrators only (checked in resolve_author). The standard contract does not let the author be
    # written, so the checks the contract would do are repeated here before it is skipped.
    def create_as_other_author(project, author, assignee, attributes)
      unless author.allowed_in_project?(:add_work_packages, project)
        raise InvalidInput, "The author is not allowed to add work packages in this project."
      end
      unless Principal.possible_assignee(project).exists?(id: assignee.id)
        raise InvalidInput, "The assignee cannot be assigned work packages in this project."
      end

      WorkPackages::CreateService
        .new(user: author, contract_class: EmptyContract)
        .call(**attributes, author:)
    end

    def summary(work_package)
      {
        id: work_package.id,
        subject: work_package.subject,
        href: API::V3::Utilities::PathHelper::ApiV3Path.work_package(work_package.id),
        project: work_package.project.slice(:id, :identifier, :name),
        author: { id: work_package.author_id, name: work_package.author.name },
        assignee: { id: work_package.assigned_to_id, name: work_package.assigned_to&.name }
      }
    end
  end
end
