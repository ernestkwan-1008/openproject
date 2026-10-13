# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AdUserSync::SyncJob, type: :job do
  let(:service) { instance_double(AdUserSync::SyncService, call: service_result) }
  let(:summary) { { errors: [] } }
  let(:service_result) { ServiceResult.success(result: summary) }

  before { allow(AdUserSync::SyncService).to receive(:new).and_return(service) }

  it "runs the sync" do
    described_class.perform_now

    expect(service).to have_received(:call)
  end

  context "when the run is aborted" do
    let(:service_result) { ServiceResult.failure(message: "CSV file not found") }

    it "fails the job" do
      expect { described_class.perform_now }.to raise_error(/aborted: CSV file not found/)
    end
  end

  context "when single users failed" do
    let(:summary) { { errors: ["create a@x.com: invalid"] } }

    it "fails the job so it is visible" do
      expect { described_class.perform_now }.to raise_error(/1 error/)
    end
  end

  describe "cron registration" do
    it "runs daily at 07:30 Hong Kong time (23:30 UTC)" do
      entry = Rails.application.config.good_job.cron[:"AdUserSync::SyncJob"]

      expect(entry).to include(cron: "30 23 * * *", class: "AdUserSync::SyncJob")
    end
  end
end
