# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AdUserSync::SendToInboxService, with_ee: %i[work_package_sharing] do
  let(:owner_role) { create(:project_role, permissions: %i[view_work_packages add_work_packages edit_work_packages]) }
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

  subject(:result) do
    described_class.new(sender:).call(recipient:, subject: "Please check", description: "Details", due_date: nil)
  end

  it "creates the work package in the recipient's inbox, authored by the sender and assigned to the recipient" do
    expect(result).to be_success

    work_package = result.result
    expect(work_package).to have_attributes(project: inbox, subject: "Please check", author: sender,
                                            assigned_to: recipient)
  end

  it "shares only this work package with the sender as commenter" do
    work_package = result.result
    other = create(:work_package, project: inbox, author: recipient)

    expect(WorkPackage.allowed_to(sender, :view_work_packages)).to contain_exactly(work_package)
    expect(WorkPackage.allowed_to(sender, :view_work_packages)).not_to include(other)
    expect(WorkPackage.allowed_to(sender, :add_work_package_comments)).to contain_exactly(work_package)
    expect(WorkPackage.allowed_to(sender, :edit_work_packages)).to be_empty
    expect(inbox.reload.users).not_to include(sender)
  end

  it "sends no mail to the sender" do
    expect { perform_enqueued_jobs { result } }
      .not_to change { ActionMailer::Base.deliveries.select { |mail| mail.to.include?(sender.mail) }.size }
  end

  it "adds the work package module when the inbox lacks it" do
    inbox.enabled_modules.destroy_all

    expect(result).to be_success
    expect(inbox.reload.module_enabled?("work_package_tracking")).to be(true)
  end

  context "when sending to oneself" do
    let(:recipient) { sender }

    it "is rejected" do
      expect(result).to be_failure
    end
  end

  context "when the recipient is locked" do
    let(:recipient) { create(:locked_user, mail: "a@x.com", login: "a@x.com") }

    it "is rejected" do
      expect(result).to be_failure
    end
  end

  context "when the recipient has no inbox" do
    before { Member.where(project: inbox).destroy_all }

    it "is rejected and creates nothing" do
      expect { result }.not_to change(WorkPackage, :count)
      expect(result).to be_failure
    end
  end

  context "when the subject is blank" do
    subject(:result) { described_class.new(sender:).call(recipient:, subject: " ") }

    it "is rejected" do
      expect(result).to be_failure
    end
  end

  context "when the sender is not logged in" do
    let(:sender) { User.anonymous }

    it "is rejected" do
      expect(result).to be_failure
    end
  end

  context "when the commenter role is missing" do
    before { commenter_role.destroy }

    it "fails before creating anything" do
      expect { result }.not_to change(WorkPackage, :count)
      expect(result).to be_failure
    end
  end

  context "when sharing cannot be created" do
    before do
      allow_any_instance_of(described_class::SilentShareService) # rubocop:disable RSpec/AnyInstance
        .to receive(:call).and_return(ServiceResult.failure(message: "boom"))
    end

    it "rolls the work package back" do
      expect { result }.not_to change(WorkPackage, :count)
      expect(result).to be_failure
      expect(result.message).to eq("boom")
    end
  end

  describe ".recipients" do
    let!(:without_inbox) { create(:user) }

    it "lists active users with an inbox, not the sender, not users without one" do
      recipients = described_class.recipients(sender)

      expect(recipients).to contain_exactly(recipient)
      expect(recipients).not_to include(without_inbox)
    end
  end
end
