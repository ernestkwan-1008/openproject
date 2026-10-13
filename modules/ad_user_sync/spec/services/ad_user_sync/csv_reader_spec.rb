# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe AdUserSync::CsvReader do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "user_list.csv") }
  let(:header) { "id,displayName,userPrincipalName,mail,jobTitle,department,accountEnabled" }

  after { FileUtils.remove_entry(dir) }

  def write(content, mode: "w")
    File.write(path, content, mode:)
  end

  subject(:result) { described_class.new(path).call }

  context "with a well-formed file" do
    before do
      write <<~CSV
        #{header}
        fa390b00,Felix Mak,felixmak@hshd.com.hk,felixmak@hshd.com.hk,Senior Leasing Officer,Leasing,true
        a0d79e03,MR FO (MHM),mrfo_maderagroup.com#EXT#@HSHG.onmicrosoft.com,mrfo@maderagroup.com,MR Front Office,"Front Office - Madera Residences",true
      CSV
    end

    it "returns the rows keyed by mail" do
      expect(result).to be_success

      rows = result.result[:rows]
      expect(rows.map(&:mail)).to eq(%w[felixmak@hshd.com.hk mrfo@maderagroup.com])
      expect(rows.last).to have_attributes(display_name: "MR FO (MHM)",
                                           job_title: "MR Front Office",
                                           department: "Front Office - Madera Residences")
      expect(result.result[:warnings]).to be_empty
    end
  end

  context "with a UTF-8 BOM" do
    before { write "\uFEFF#{header}\nx,Felix Mak,f@x.com,f@x.com,Officer,Leasing,true\n" }

    it "still finds the columns" do
      expect(result).to be_success
      expect(result.result[:rows].map(&:mail)).to eq(["f@x.com"])
    end
  end

  context "with a UTF-16 LE file (PowerShell export)" do
    before do
      content = "\uFEFF#{header}\r\nx,Felix Mak,f@x.com,f@x.com,Officer,Leasing,true\r\n"
      write content.encode(Encoding::UTF_16LE).b, mode: "wb"
    end

    it "is converted to UTF-8" do
      expect(result).to be_success
      expect(result.result[:rows].map(&:mail)).to eq(["f@x.com"])
    end
  end

  context "with blank, invalid and duplicate mail addresses" do
    before do
      write <<~CSV
        #{header}
        1,No Mail,x@y.com,,Officer,Leasing,true
        2,Bad Mail,x@y.com,not-a-mail,Officer,Leasing,true
        3,First,f@x.com,F@x.com,Officer,Leasing,true
        4,Second,f@x.com,f@X.com,Manager,Accounts,true
      CSV
    end

    it "skips them with warnings and keeps the first duplicate" do
      expect(result).to be_success
      expect(result.result[:rows].map(&:mail)).to eq(["F@x.com"])
      expect(result.result[:rows].first.key).to eq("f@x.com")
      expect(result.result[:warnings].size).to eq(3)
    end
  end

  context "when a required column is missing" do
    before { write "id,displayName,mail\n1,A,a@x.com\n" }

    it "fails" do
      expect(result).to be_failure
      expect(result.message).to include("jobTitle", "department")
    end
  end

  context "when the file only has a header" do
    before { write "#{header}\n" }

    it "fails" do
      expect(result).to be_failure
    end
  end

  context "when the file does not exist" do
    it "fails" do
      expect(result).to be_failure
      expect(result.message).to include("not found")
    end
  end

  context "when the file is not valid UTF-8" do
    before { write "#{header}\nx,Fe\xE9lix,f@x.com,f@x.com,Officer,Leasing,true\n".b, mode: "wb" }

    it "fails" do
      expect(result).to be_failure
    end
  end
end
