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
  # "Send to inbox" dialog: puts a work package into the private "My inbox" project of another user.
  class SendToInboxController < ApplicationController
    include OpTurbo::ComponentStream

    # Any signed-in user may send; what happens is decided by AdUserSync::SendToInboxService.
    no_authorization_required! :new, :create
    before_action :require_login

    def new
      respond_with_dialog(SendToInbox::DialogComponent.new(SendToInbox::FormModel.new))
    end

    def create
      form_model = SendToInbox::FormModel.new(form_params)
      call = send_to_inbox(form_model) if form_model.valid?

      if call&.success?
        render_success(call.result)
      else
        error = call&.message || form_model.errors.full_messages.to_sentence
        replace_via_turbo_stream(component: SendToInbox::FormComponent.new(form_model, error:))
      end

      respond_with_turbo_streams
    end

    private

    def send_to_inbox(form_model)
      SendToInboxService.new(sender: current_user).call(
        recipient: User.not_builtin.find_by(id: form_model.recipient_id),
        subject: form_model.subject,
        description: form_model.description,
        due_date: form_model.due_date
      )
    end

    def render_success(work_package)
      render_success_flash_message_via_turbo_stream(
        message: I18n.t("ad_user_sync.send_to_inbox.success", id: work_package.id, subject: work_package.subject)
      )
      close_dialog_via_turbo_stream("##{SendToInbox::DialogComponent::DIALOG_ID}")
    end

    def form_params
      params.fetch(:send_to_inbox, {}).permit(:recipient_id, :subject, :description, :due_date)
    end
  end
end
