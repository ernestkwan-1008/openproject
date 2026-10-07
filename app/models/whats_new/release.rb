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

module WhatsNew
  class Release
    Item = Data.define(:key, :title, :description, :url)

    attr_reader :major, :minor

    def self.current
      new(major: OpenProject::VERSION::MAJOR, minor: OpenProject::VERSION::MINOR)
    end

    def initialize(major:, minor:)
      @major = major
      @minor = minor
    end

    def version
      "#{major}.#{minor}"
    end

    def version_key
      "#{major}_#{minor}"
    end

    def items
      @items ||= I18n.t("#{i18n_scope}.items", default: {}).map do |key, attributes|
        Item.new(key: key.to_s, title: attributes[:title], description: attributes[:description], url: attributes[:url])
      end
    end

    def visible_to?(user)
      OpenProject::FeatureDecisions.whats_new_menu_active? && user.logged? && items.any?
    end

    def item?(key)
      items.any? { |item| item.key == key.to_s }
    end

    def video_url
      I18n.t("#{i18n_scope}.video_url", default: nil).presence
    end

    def unread_keys(user)
      items.map(&:key) - user.pref.whats_new_read_keys(version_key)
    end

    def unread?(user)
      unread_keys(user).any?
    end

    private

    def i18n_scope
      "homescreen.blocks.new_features.#{version_key}.whats_new"
    end
  end
end
