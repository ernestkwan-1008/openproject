# frozen_string_literal: true

require "spec_helper"
require "contracts/shared/model_contract_shared_context"

RSpec.describe Projects::UpdateContract, "inbox identifier lock" do
  include_context "ModelContract shared context"

  let(:inbox_identifier) { "my-inbox-hedy-wu" }
  let(:project) { create(:project, name: "My inbox", identifier: inbox_identifier, public: false) }
  let(:current_user) do
    create(:user, member_with_permissions: { project => %i[view_project edit_project edit_project_attributes] })
  end

  subject(:contract) { described_class.new(project, current_user) }

  context "when the identifier of an inbox project is changed" do
    before { project.identifier = "something-else" }

    it_behaves_like "contract is invalid", identifier: %i[inbox_locked]
  end

  context "when the identifier of an inbox project is changed by an administrator" do
    let(:current_user) { create(:admin) }

    before { project.identifier = "something-else" }

    it_behaves_like "contract is invalid", identifier: %i[inbox_locked]
  end

  context "when the inbox is renamed first and the identifier is changed afterwards" do
    before do
      project.update_column(:name, "Renamed")
      project.identifier = "something-else"
    end

    it_behaves_like "contract is invalid", identifier: %i[inbox_locked]
  end

  context "when only the name of an inbox project is changed" do
    before { project.name = "Hedy's private inbox" }

    it_behaves_like "contract is valid"
  end

  context "when the identifier of a normal project is changed" do
    let(:inbox_identifier) { "normal-project" }

    before { project.identifier = "renamed-project" }

    it_behaves_like "contract is valid"
  end
end
