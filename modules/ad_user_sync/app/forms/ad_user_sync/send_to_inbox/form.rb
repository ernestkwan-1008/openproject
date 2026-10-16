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
  module SendToInbox
    class Form < ApplicationForm
      form do |f|
        f.autocompleter(
          name: :recipient_id,
          label: I18n.t("ad_user_sync.send_to_inbox.recipient"),
          required: true,
          include_blank: false,
          autocomplete_options: {
            multiple: false,
            decorated: true,
            clearable: false,
            focusDirectly: false,
            appendTo: "##{DialogComponent::DIALOG_ID}"
          }
        ) do |list|
          SendToInboxService.recipients(User.current).each do |user|
            list.option(label: user.name, value: user.id)
          end
        end

        f.text_field(
          name: :subject,
          label: I18n.t("ad_user_sync.send_to_inbox.subject"),
          required: true,
          maxlength: 255
        )

        f.text_area(
          name: :description,
          label: I18n.t("ad_user_sync.send_to_inbox.description"),
          rows: 5,
          style: "resize: none"
        )

        f.single_date_picker(
          name: :due_date,
          label: I18n.t("ad_user_sync.send_to_inbox.due_date"),
          input_width: :xsmall,
          leading_visual: { icon: :calendar }
        )
      end
    end
  end
end
