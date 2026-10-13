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

namespace :ad_user_sync do
  desc "Synchronize users and departments from $AD_IMPORT_DIR/user_list.csv " \
       "(FORCE=1 to bypass the mass-lock safety guard)"
  task run: :environment do
    force = ActiveModel::Type::Boolean.new.cast(ENV.fetch("FORCE", false))

    result = AdUserSync::SyncService.new(force:).call
    abort "ABORTED: #{result.message}" if result.failure?

    puts AdUserSync::SyncService.report_lines(result.result)
    exit 1 if result.result[:errors].any?
  end

  desc "Show what ad_user_sync:run would change without writing anything"
  task dry_run: :environment do
    result = AdUserSync::SyncService.new(dry_run: true).call
    abort "ABORTED: #{result.message}" if result.failure?

    puts AdUserSync::SyncService.report_lines(result.result)
  end
end
