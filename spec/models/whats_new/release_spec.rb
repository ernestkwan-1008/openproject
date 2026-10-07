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

require "spec_helper"

RSpec.describe WhatsNew::Release do
  subject(:release) { described_class.new(major: 99, minor: 1) }

  let(:user) { create(:user) }

  before do
    I18n.backend.store_translations(
      :en,
      homescreen: {
        blocks: {
          new_features: {
            "99_1": {
              whats_new: {
                video_url: "https://example.com/video",
                items: {
                  first: { title: "First", description: "The first one", url: "https://example.com/first" },
                  second: { title: "Second", description: "The second one", url: "https://example.com/second" }
                }
              }
            }
          }
        }
      }
    )
  end

  it "reads the items of its version from the translations" do
    expect(release.items).to eq(
      [
        described_class::Item.new(key: "first", title: "First", description: "The first one",
                                  url: "https://example.com/first"),
        described_class::Item.new(key: "second", title: "Second", description: "The second one",
                                  url: "https://example.com/second")
      ]
    )
    expect(release.video_url).to eq("https://example.com/video")
    expect(release.version).to eq("99.1")
  end

  it "has no items for a version without translations" do
    expect(described_class.new(major: 99, minor: 2).items).to be_empty
  end

  it "tracks the read items of a user" do
    expect(release.unread_keys(user)).to eq(%w[first second])

    user.pref.mark_whats_new_read(release.version_key, "first")
    user.pref.mark_whats_new_read(release.version_key, "first")

    expect(release.unread_keys(user)).to eq(%w[second])
    expect(release).to be_unread(user)

    user.pref.mark_whats_new_read(release.version_key, "second")

    expect(release).not_to be_unread(user)
  end

  describe "#visible_to?" do
    it "is visible to a logged in user", with_flag: { whats_new_menu: true } do
      expect(release).to be_visible_to(user)
    end

    it "is not visible to the anonymous user", with_flag: { whats_new_menu: true } do
      expect(release).not_to be_visible_to(User.anonymous)
    end

    it "is not visible without the feature flag", with_flag: { whats_new_menu: false } do
      expect(release).not_to be_visible_to(user)
    end

    it "is not visible without items", with_flag: { whats_new_menu: true } do
      expect(described_class.new(major: 99, minor: 2)).not_to be_visible_to(user)
    end
  end
end
