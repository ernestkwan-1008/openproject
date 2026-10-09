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

RSpec.describe "Accepting a forum reply as solution", :skip_csrf, type: :rails_request do
  shared_let(:forum) { create(:forum) }
  shared_let(:topic_author) { create(:user, member_with_permissions: { forum.project => %i[view_messages add_messages] }) }
  shared_let(:topic) { create(:message, forum:, author: topic_author) }

  let(:reply) { create(:message, forum:, parent: topic) }
  let(:message) { reply }

  current_user { topic_author }

  describe "POST create" do
    subject(:accept) { post project_forum_topic_accepted_solution_path(forum.project, forum, message), as: :turbo_stream }

    it "accepts the reply and refreshes its card, the opening post and the summary", :aggregate_failures do
      accept

      expect(response).to have_http_status(:ok)
      expect(reply.reload).to be_accepted_solution
      expect(response.body).to include(%(action="replace" target="messages-post-component-#{reply.id}"))
      expect(response.body).to include(%(action="replace" target="messages-post-component-#{topic.id}"))
      expect(response.body).to include(%(action="replace" target="messages-topic-summary-component-#{topic.id}"))
    end

    it "brings focus back to the reply, whose menu the stream replaced", :aggregate_failures do
      accept

      streamed = Capybara.string(response.body.scan(%r{<template>(.*?)</template>}m).join)
      expect(streamed).to have_css("#message-#{reply.id}[autofocus]")
      expect(streamed).to have_no_css("#message-#{topic.id}[autofocus]")
    end

    it "keeps an accepted reply accepted when accepted again" do
      reply.update_column(:accepted_solution, true)

      accept

      expect(response).to have_http_status(:ok)
    end

    it "writes no journal entry" do
      reply

      expect { accept }.not_to change(Journal, :count)
    end

    context "for a member who neither started the topic nor moderates" do
      current_user { create(:user, member_with_permissions: { forum.project => %i[view_messages add_messages] }) }

      it "forbids it and leaves the reply as it was", :aggregate_failures do
        accept

        expect(response).to have_http_status(:forbidden)
        expect(reply.reload).not_to be_accepted_solution
      end
    end

    context "on the opening post" do
      let(:message) { topic }

      it "forbids it" do
        accept

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "when the project has forums turned off" do
      before { forum.project.update!(enabled_module_names: %w[work_package_tracking]) }

      it "answers not found" do
        accept

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE destroy" do
    subject(:unaccept) { delete project_forum_topic_accepted_solution_path(forum.project, forum, message), as: :turbo_stream }

    it "unaccepts the reply", :aggregate_failures do
      reply.update_column(:accepted_solution, true)

      unaccept

      expect(response).to have_http_status(:ok)
      expect(reply.reload).not_to be_accepted_solution
    end
  end
end
