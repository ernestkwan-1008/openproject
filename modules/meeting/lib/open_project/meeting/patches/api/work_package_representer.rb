# frozen_string_literal: true
module OpenProject::Meeting
  module Patches
    module API
      module WorkPackageRepresenter
        module_function

        def extension
          ->(*) do
            link :meetings,
                 cache_if: -> { Setting.meetings_enabled? && current_user.allowed_in_any_project?(:view_meetings) } do
              next unless Setting.meetings_enabled?
              next if represented.new_record?

              {
                href: "#{work_package_path(id: represented.id)}/tabs/meetings",
                title: "meetings"
              }
            end
          end
        end
      end
    end
  end
end
