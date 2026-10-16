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

module Costs::Patches::SettingSeederPatch
  SEEDED_CURRENCY = "$"
  SEEDED_CURRENCY_FORMAT = "%u %n"

  def self.included(base) # :nodoc:
    base.prepend InstanceMethods
  end

  module InstanceMethods
    def data
      original_data = super

      if original_data["default_projects_modules"]&.exclude? "costs"
        original_data["default_projects_modules"] << "costs"
      end

      # This installation uses "$" (shown before the number, e.g. "$ 100") instead of the "€" of the
      # setting definition. Seeded only while the setting is not yet stored, so later changes made in
      # the administration are kept.
      original_data["costs_currency"] = SEEDED_CURRENCY if original_data.key?("costs_currency")
      original_data["costs_currency_format"] = SEEDED_CURRENCY_FORMAT if original_data.key?("costs_currency_format")

      original_data
    end
  end
end
