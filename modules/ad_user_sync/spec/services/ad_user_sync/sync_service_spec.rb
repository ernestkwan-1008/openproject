# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AdUserSync::SyncService do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "user_list.csv") }
  let(:header) { "id,displayName,userPrincipalName,mail,jobTitle,department,accountEnabled" }
  let(:csv_rows) { [] }
  let(:options) { { max_lock_percent: 100 } }

  subject(:result) { described_class.new(path:, **options).call }

  let(:summary) { result.result }

  before do
    lines = csv_rows.map do |row|
      row = { name: "Some Body", title: "Officer", department: "Leasing" }.merge(row)
      %(id,"#{row[:name]}",upn,#{row.fetch(:mail)},"#{row[:title]}","#{row[:department]}",true)
    end
    File.write(path, ([header] + lines).join("\n"))
  end

  after { FileUtils.remove_entry(dir) }

  context "with a user that does not exist yet" do
    let(:csv_rows) { [{ mail: "Felix.Mak@hshd.com.hk", name: "Felix Mak", title: "Senior Leasing Officer" }] }

    it "creates an invited user with login = mail, no password and a split display name" do
      expect(result).to be_success
      expect(summary[:created]).to eq(["Felix.Mak@hshd.com.hk"])

      user = User.find_by!(mail: "Felix.Mak@hshd.com.hk")
      expect(user).to have_attributes(login: "Felix.Mak@hshd.com.hk", firstname: "Felix", lastname: "Mak")
      expect(user).to be_invited
      expect(user.passwords).to be_empty
    end

    it "does not send an invitation email" do
      expect { perform_enqueued_jobs { result } }.not_to change { ActionMailer::Base.deliveries.size }
    end

    it "creates the department as a plain organizational unit and assigns the user" do
      expect { result }.to change { Group.organizational_units.count }.by(1)

      department = User.find_by!(mail: "Felix.Mak@hshd.com.hk").department
      expect(department).to have_attributes(name: "Leasing", organizational_unit: true)
      expect(department).not_to be_ldap_managed
      expect(summary[:departments_created]).to eq(["Leasing"])
    end

    it "creates the Job title custom field and stores the job title" do
      expect { result }.to change(UserCustomField, :count).by(1)

      field = UserCustomField.find_by!(name: "Job title")
      user = User.find_by!(mail: "Felix.Mak@hshd.com.hk")
      expect(user.custom_value_for(field).value).to eq("Senior Leasing Officer")
    end

    it "does not create the same user twice when run again" do
      described_class.new(path:, **options).call

      second = described_class.new(path:, **options).call

      expect(second).to be_success
      expect(second.result).to include(created: [], updated: [], locked: [], departments_created: [])
      expect(User.where(mail: "Felix.Mak@hshd.com.hk").count).to eq(1)
    end
  end

  context "with a single-word display name" do
    let(:csv_rows) { [{ mail: "madonna@x.com", name: "Madonna" }] }

    it "uses it for first and last name" do
      result

      expect(User.find_by!(mail: "madonna@x.com")).to have_attributes(firstname: "Madonna", lastname: "Madonna")
    end
  end

  context "with an existing user" do
    let!(:old_department) { create(:department, lastname: "Old Dept") }
    let!(:user) do
      create(:user, mail: "felixmak@hshd.com.hk", login: "felixmak@hshd.com.hk", firstname: "Old", lastname: "Name")
    end
    let(:csv_rows) do
      [{ mail: "FelixMak@hshd.com.hk", name: "Felix Mak", title: "Leasing Manager", department: "Leasing" }]
    end

    before do
      Groups::AddUsersService.new(old_department, current_user: User.system).call(ids: [user.id])
      create(:user_custom_field, :string, name: "Job title", editable: false)
    end

    it "matches the mail case-insensitively and refreshes name, job title and department" do
      expect(result).to be_success
      expect(summary[:created]).to be_empty
      expect(summary[:updated]).to eq(["FelixMak@hshd.com.hk"])

      user.reload
      expect(user).to have_attributes(firstname: "Felix", lastname: "Mak", login: "felixmak@hshd.com.hk")
      expect(user.custom_value_for(UserCustomField.find_by!(name: "Job title")).value).to eq("Leasing Manager")
      expect(user.department.name).to eq("Leasing")
      expect(old_department.reload.users).to be_empty
    end

    it "reuses an existing department of the same name" do
      existing = create(:department, lastname: "leasing")

      expect { result }.not_to change { Group.organizational_units.count }
      expect(user.reload.department).to eq(existing)
    end

    context "when the CSV department is blank" do
      let(:csv_rows) { [{ mail: "felixmak@hshd.com.hk", name: "Felix Mak", department: "" }] }

      it "removes the user from the department" do
        result

        expect(user.reload.department).to be_nil
      end
    end
  end

  context "with users that are not in the CSV" do
    let(:csv_rows) { [{ mail: "listed@x.com" }] }
    let!(:listed) { create(:user, mail: "listed@x.com", login: "listed@x.com") }
    let!(:missing) { create(:user) }
    let!(:admin) { create(:admin) }
    let!(:global_role_user) do
      create(:user).tap { |u| create(:global_member, user: u, roles: [create(:global_role)]) }
    end
    let!(:already_locked) { create(:locked_user) }

    it "locks only normal users" do
      expect(result).to be_success
      expect(summary[:locked]).to eq([missing.mail])

      expect(missing.reload).to be_locked
      expect(listed.reload).to be_active
      expect(admin.reload).to be_active
      expect(global_role_user.reload).to be_active
      expect(already_locked.reload).to be_locked
    end

    it "does not touch builtin users" do
      result

      expect(User.system.reload).not_to be_locked
      expect(User.anonymous.reload).not_to be_locked
    end
  end

  context "with a locked user that is listed in the CSV" do
    let!(:user) { create(:locked_user, mail: "back@x.com", login: "back@x.com") }
    let(:csv_rows) { [{ mail: "back@x.com" }] }

    it "reactivates the user" do
      expect(result).to be_success
      expect(summary[:reactivated]).to eq(["back@x.com"])
      expect(user.reload).to be_active
    end

    context "when reactivation is disabled" do
      let(:options) { { max_lock_percent: 100, reactivate: false } }

      it "leaves the user locked" do
        result

        expect(user.reload).to be_locked
      end
    end
  end

  context "when the run would lock too many users" do
    let(:csv_rows) { [{ mail: "kept@x.com" }] }
    let(:options) { { max_lock_percent: 20 } }
    let!(:users) { create_list(:user, 4) }
    let!(:kept) { create(:user, mail: "kept@x.com", login: "kept@x.com") }

    it "aborts without changing anything" do
      expect(result).to be_failure
      expect(result.message).to include("safety limit")

      expect(User.where(id: users.map(&:id)).map(&:status).uniq).to eq(["active"])
      expect(User.find_by(mail: "kept@x.com")).to be_present
    end

    context "with force" do
      let(:options) { { max_lock_percent: 20, force: true } }

      it "locks the users anyway" do
        expect(result).to be_success
        expect(User.where(id: users.map(&:id)).map(&:status).uniq).to eq(["locked"])
      end
    end

    context "as a dry run" do
      let(:options) { { max_lock_percent: 20, dry_run: true } }

      it "reports the guard as a warning" do
        expect(result).to be_success
        expect(summary[:warnings].join).to include("ABORTED by the safety guard")
      end
    end
  end

  context "when the file is missing" do
    before { FileUtils.rm_f(path) }

    it "fails without changing anything" do
      create(:user)

      expect(result).to be_failure
      expect(User.not_builtin.map(&:status).uniq).to eq(["active"])
    end
  end

  context "with a dry run" do
    let(:options) { { dry_run: true, max_lock_percent: 100 } }
    let(:csv_rows) { [{ mail: "new@x.com", department: "Brand New" }] }
    let!(:missing) { create(:user) }

    it "reports the planned changes but writes nothing" do
      expect { result }.not_to change { [User.count, Group.count, UserCustomField.count] }

      expect(result).to be_success
      expect(summary).to include(dry_run: true, created: ["new@x.com"], locked: [missing.mail],
                                 departments_created: ["Brand New"])
      expect(missing.reload).to be_active
    end
  end

  describe ".default_path" do
    it "is user_list.csv inside AD_IMPORT_DIR" do
      stub_const("ENV", ENV.to_h.merge("AD_IMPORT_DIR" => "/data/AD/import"))

      expect(described_class.default_path).to eq("/data/AD/import/user_list.csv")
    end

    it "raises when AD_IMPORT_DIR is not set" do
      stub_const("ENV", ENV.to_h.except("AD_IMPORT_DIR"))

      expect { described_class.default_path }.to raise_error(/AD_IMPORT_DIR/)
    end
  end

  describe ".report_lines" do
    it "renders counts and entries" do
      lines = described_class.report_lines(
        { dry_run: false, created: ["a@x.com"], updated: [], reactivated: [], locked: [], departments_created: [],
          warnings: ["w"], errors: [] }
      )

      expect(lines).to include("created: 1", "  a@x.com", "warning: w")
    end
  end
end
