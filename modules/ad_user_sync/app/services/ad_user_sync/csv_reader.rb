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

require "csv"

module AdUserSync
  # Reads the AD / Entra ID user export.
  #
  # Expected header: id,displayName,userPrincipalName,mail,jobTitle,department,accountEnabled
  # Only mail, displayName, jobTitle and department are used. The mail address is the unique key.
  #
  # On success the ServiceResult#result is a Hash:
  #   rows:     Array<AdUserSync::CsvReader::Row>, de-duplicated by (case-insensitive) mail
  #   warnings: Array<String>, rows that were skipped and why
  class CsvReader
    REQUIRED_HEADERS = %w[mail displayName jobTitle department].freeze

    Row = Struct.new(:mail, :display_name, :job_title, :department, :line, keyword_init: true) do
      def key
        mail.downcase
      end
    end

    attr_reader :path

    def initialize(path)
      @path = path.to_s
    end

    def call
      return failure("CSV file not found or not readable: #{path}") unless File.file?(path) && File.readable?(path)

      table = CSV.parse(read_utf8, headers: true, skip_blanks: true, header_converters: ->(h) { h.to_s.strip })
      missing = REQUIRED_HEADERS - table.headers.compact
      return failure("CSV is missing required column(s): #{missing.join(', ')}") if missing.any?

      rows, warnings = build_rows(table)
      return failure("CSV contains no usable rows (#{warnings.size} skipped)") if rows.empty?

      ServiceResult.success(result: { rows:, warnings: })
    rescue CSV::MalformedCSVError, EncodingError, ArgumentError, SystemCallError => e
      failure("CSV could not be parsed: #{e.class}: #{e.message}")
    end

    private

    def failure(message)
      ServiceResult.failure(message:)
    end

    # Handles UTF-8 (with or without BOM) and UTF-16 (the default of some PowerShell exports).
    def read_utf8
      data = File.binread(path)

      if data.start_with?("\xFF\xFE".b, "\xFE\xFF".b)
        data.force_encoding(Encoding::UTF_16).encode(Encoding::UTF_8).delete_prefix("\uFEFF")
      else
        data.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF").tap do |text|
          raise EncodingError, "file is not valid UTF-8" unless text.valid_encoding?
        end
      end
    end

    def build_rows(table)
      rows = {}
      warnings = []

      table.each.with_index(2) do |record, line| # line 1 is the header
        row = to_row(record, line)

        if row.is_a?(String)
          warnings << row
        elsif rows.key?(row.key)
          warnings << "line #{line}: duplicate mail #{row.mail}, first occurrence (line #{rows[row.key].line}) wins"
        else
          rows[row.key] = row
        end
      end

      [rows.values, warnings]
    end

    # Returns a Row, or a String describing why the record was skipped.
    def to_row(record, line)
      mail = record["mail"].to_s.strip
      return "line #{line}: blank mail, skipped" if mail.empty?
      return "line #{line}: '#{mail}' is not a valid mail address, skipped" unless mail.match?(/\A[^@\s]+@[^@\s]+\z/)

      Row.new(
        mail:,
        display_name: record["displayName"].to_s.strip,
        job_title: record["jobTitle"].to_s.strip,
        department: record["department"].to_s.strip,
        line:
      )
    end
  end
end
