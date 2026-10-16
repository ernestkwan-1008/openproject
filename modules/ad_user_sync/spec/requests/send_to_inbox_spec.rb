# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Send to inbox", :skip_csrf, type: :rails_request, with_ee: %i[work_package_sharing] do
  let(:owner_role) { create(:project_role, permissions: %i[view_work_packages add_work_packages]) }
  let!(:commenter_role) { create(:comment_work_package_role) }
  let!(:status) { create(:default_status) }
  let!(:priority) { create(:default_priority) }
  let!(:type) { create(:type_standard) }
  let(:sender) { create(:user, mail: "b@x.com", login: "b@x.com") }
  let(:recipient) { create(:user, mail: "a@x.com", login: "a@x.com") }
  let!(:inbox) do
    create(:project, name: "My inbox", identifier: "my-inbox-a", public: false,
                     enabled_module_names: %w[work_package_tracking], types: [type]).tap do |project|
      create(:member, project:, principal: recipient, roles: [owner_role])
    end
  end

  describe "GET /send_to_inbox" do
    it "renders the dialog with the recipients for a signed-in user" do
      login_as sender

      get "/send_to_inbox", as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("send-to-inbox-dialog")
    end

    it "does not serve anonymous users" do
      get "/send_to_inbox", as: :turbo_stream

      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "POST /send_to_inbox" do
    let(:params) do
      { send_to_inbox: { recipient_id: recipient.id, subject: "Please check", description: "Details" } }
    end

    before { login_as sender }

    it "creates the work package and shares it with the sender" do
      expect { post "/send_to_inbox", params:, as: :turbo_stream }.to change(WorkPackage, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(WorkPackage.last).to have_attributes(project: inbox, assigned_to: recipient, author: sender)
    end

    it "re-renders the form with the error when nothing was entered" do
      params[:send_to_inbox][:subject] = ""

      expect { post "/send_to_inbox", params:, as: :turbo_stream }.not_to change(WorkPackage, :count)

      expect(response.body).to include("Subject")
    end
  end
end
