# frozen_string_literal: true

require "spec_helper"

RSpec.describe BasicData::SettingSeeder, "currency" do
  include_context "with basic seed data"

  subject(:setting_seeder) { described_class.new(basic_seed_data) }

  it "seeds $ shown before the number" do
    expect(setting_seeder.data).to include("costs_currency" => "$", "costs_currency_format" => "%u %n")
  end

  it "does not overwrite a currency that is already stored" do
    Setting.costs_currency = "EUR"

    setting_seeder.seed!

    expect(Setting.costs_currency).to eq("EUR")
  end
end
