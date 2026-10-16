# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe McpTools::AssignWorkPackage, with_ee: %i[mcp_server work_package_sharing] do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: caller_user) }
  let(:caller_user) { create(:user, mail: "b@x.com", login: "b@x.com") }
  let(:assignee) { create(:user, mail: "a@x.com", login: "a@x.com") }
  let(:request_body) do
    { jsonrpc: "2.0", id: "Test-Request", method: "tools/call",
      params: { name: "assign_work_package", arguments: call_args } }
  end
  let(:call_args) { { assignee: "a@x.com", subject: "Please check", description: "Details" } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:owner_role) { create(:project_role, permissions: %i[view_work_packages add_work_packages work_package_assigned]) }
  let!(:commenter_role) { create(:comment_work_package_role) }
  let!(:status) { create(:default_status) }
  let!(:priority) { create(:default_priority) }
  let!(:type) { create(:type_standard) }
  let!(:inbox) do
    create(:project, name: "My inbox", identifier: "my-inbox-a", public: false,
                     enabled_module_names: %w[work_package_tracking], types: [type]).tap do |project|
      create(:member, project:, principal: assignee, roles: [owner_role])
    end
  end

  before do
    create(:mcp_configuration, identifier: "mcp_server")
    create(:mcp_configuration, identifier: described_class.qualified_name)
    # the recipient must be visible to the caller (shared project, or all principals visible)
    allow(User).to receive(:visible).and_return(User.all)
  end

  it_behaves_like "MCP text tool"

  context "without project_id" do
    it "creates the work package in the assignee's inbox with author and assignee set" do
      expect { mcp_request }.to change(WorkPackage, :count).by(1)

      work_package = WorkPackage.last
      expect(work_package).to have_attributes(project: inbox, author: caller_user, assigned_to: assignee)
      expect(result_item).to include("id" => work_package.id)
      expect(result_item.fetch("project")).to include("identifier" => "my-inbox-a")
    end

    it "lets the caller follow only this work package" do
      mcp_request
      other = create(:work_package, project: inbox, author: assignee)

      visible = WorkPackage.allowed_to(caller_user, :view_work_packages)
      expect(visible).to contain_exactly(WorkPackage.where.not(id: other.id).last)
    end

    context "when the assignee has no inbox" do
      let(:call_args) { { assignee: create(:user).mail, subject: "x" } }

      it "returns an error and creates nothing" do
        expect { mcp_request }.not_to change(WorkPackage, :count)
        expect(result_item.fetch("error")).to be_present
      end
    end

    context "when the assignee is unknown" do
      let(:call_args) { { assignee: "nobody@x.com", subject: "x" } }

      it "returns an error" do
        mcp_request
        expect(result_item.fetch("error")).to include("assignee")
      end
    end

    context "when the due date is invalid" do
      let(:call_args) { { assignee: "a@x.com", subject: "x", due_date: "31/12/2026" } }

      it "returns an error" do
        mcp_request
        expect(result_item.fetch("error")).to include("YYYY-MM-DD")
      end
    end
  end

  context "with another author" do
    let(:author) { create(:user, mail: "c@x.com", login: "c@x.com") }
    let(:call_args) { { assignee: "a@x.com", subject: "Please check", author: "c@x.com" } }

    context "when the caller is not an administrator" do
      it "is rejected" do
        expect { mcp_request }.not_to change(WorkPackage, :count)
        expect(result_item.fetch("error")).to include("administrators")
      end
    end

    context "when the caller is an administrator" do
      let(:caller_user) { create(:admin, mail: "b@x.com", login: "b@x.com") }

      before { author }

      it "creates the work package for that author" do
        mcp_request

        expect(WorkPackage.last).to have_attributes(project: inbox, author:, assigned_to: assignee)
      end
    end
  end

  context "with project_id" do
    let(:project) { create(:project, types: [type]) }
    let(:call_args) { { assignee: "a@x.com", subject: "Project task", project_id: project.id } }

    before do
      create(:member, project:, principal: assignee, roles: [owner_role])
    end

    context "when the caller may add work packages there" do
      before { create(:member, project:, principal: caller_user, roles: [owner_role]) }

      it "creates it in the project, assigned to the assignee" do
        expect { mcp_request }.to change(WorkPackage, :count).by(1)

        expect(WorkPackage.last).to have_attributes(project:, author: caller_user, assigned_to: assignee)
      end
    end

    context "when the caller may not add work packages there" do
      before do
        create(:member, project:, principal: caller_user,
                        roles: [create(:project_role, permissions: %i[view_work_packages])])
      end

      it "returns an error" do
        expect { mcp_request }.not_to change(WorkPackage, :count)
        expect(result_item.fetch("error")).to be_present
      end
    end

    context "when the project does not exist" do
      let(:call_args) { { assignee: "a@x.com", subject: "x", project_id: 0 } }

      it "returns an error" do
        mcp_request
        expect(result_item.fetch("error")).to include("project")
      end
    end

    context "when an administrator sets another author" do
      let(:caller_user) { create(:admin, mail: "b@x.com", login: "b@x.com") }
      let(:author) { create(:user, mail: "c@x.com", login: "c@x.com") }
      let(:call_args) { { assignee: "a@x.com", subject: "x", project_id: project.id, author: "c@x.com" } }

      it "creates it when the author may add work packages" do
        create(:member, project:, principal: author, roles: [owner_role])

        mcp_request

        expect(WorkPackage.last).to have_attributes(project:, author:, assigned_to: assignee)
      end

      it "returns an error when the author may not add work packages" do
        author

        expect { mcp_request }.not_to change(WorkPackage, :count)
        expect(result_item.fetch("error")).to include("author")
      end
    end
  end
end
