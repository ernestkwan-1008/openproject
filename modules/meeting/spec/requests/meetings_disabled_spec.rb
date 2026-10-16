# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe "Meetings switched off system-wide",
               :skip_csrf,
               type: :rails_request,
               with_settings: { meetings_enabled: false } do
  shared_let(:project) { create(:project, enabled_module_names: %i[meetings]) }
  shared_let(:user) do
    create(:user, member_with_permissions: { project => %i[view_meetings create_meetings edit_meetings] })
  end
  shared_let(:meeting) { create(:meeting, project:, author: user) }
  shared_let(:admin) { create(:admin) }

  before { login_as user }

  it "removes meetings from the available project modules" do
    expect(OpenProject::AccessControl.available_project_modules).not_to include(:meetings)
  end

  it "answers 404 for the project meetings page even though the module is enabled in the project" do
    get "/projects/#{project.identifier}/meetings"

    expect(response).to have_http_status(:not_found)
  end

  it "answers 404 for the global meetings page" do
    get "/meetings"

    expect(response).to have_http_status(:not_found)
  end

  it "answers 404 for a single meeting" do
    get "/meetings/#{meeting.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "answers 404 for the work package meetings tab" do
    work_package = create(:work_package, project:)

    get "/work_packages/#{work_package.id}/meetings/tab"

    expect(response).to have_http_status(:not_found)
  end

  context "with the API" do
    include API::V3::Utilities::PathHelper

    it "answers 404 for the meetings collection" do
      get api_v3_paths.meetings

      expect(response).to have_http_status(:not_found)
    end

    it "answers 404 for a single meeting" do
      get api_v3_paths.meeting(meeting.id)

      expect(response).to have_http_status(:not_found)
    end

    it "answers 404 for recurring meetings" do
      get api_v3_paths.recurring_meetings

      expect(response).to have_http_status(:not_found)
    end
  end

  context "when the setting is on again", with_settings: { meetings_enabled: true } do
    it "serves the project meetings page" do
      get "/projects/#{project.identifier}/meetings"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the administration page" do
    before { login_as admin }

    it "stays reachable so that it can be switched on again" do
      get "/admin/meetings"

      expect(response).to have_http_status(:ok)
    end
  end
end
