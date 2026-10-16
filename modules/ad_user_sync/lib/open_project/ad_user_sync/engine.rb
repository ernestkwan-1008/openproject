# frozen_string_literal: true

require "open_project/plugins"

module OpenProject::AdUserSync
  class Engine < ::Rails::Engine
    engine_name :openproject_ad_user_sync

    include OpenProject::Plugins::ActsAsOpEngine

    register "openproject-ad_user_sync",
             author_url: "https://github.com/opf/openproject",
             bundled: true do
      # "+" menu entry: put a work package into another user's private "My inbox" project.
      menu :quick_add_menu,
           :send_to_inbox,
           { controller: "/ad_user_sync/send_to_inbox", action: :new },
           caption: :"ad_user_sync.send_to_inbox.menu_label",
           icon: "inbox",
           html: { target: nil, data: { turbo_stream: true } },
           skip_permissions_check: true,
           if: ->(_project) { User.current.logged? && !User.current.locked? }
    end

    # MCP tool for external programs; its McpConfiguration row is created by McpConfigurationSeeder (db:seed).
    config.after_initialize do
      McpTools.register McpTools::AssignWorkPackage
    end

    # Rails (and thus GoodJob cron) runs in UTC. Hong Kong is UTC+8 without DST, so
    # 07:30 HKT is 23:30 UTC. Override with AD_USER_SYNC_CRON if needed.
    DEFAULT_CRON = "30 23 * * *"

    add_cron_jobs do
      {
        "AdUserSync::SyncJob": {
          cron: ENV.fetch("AD_USER_SYNC_CRON", DEFAULT_CRON),
          class: ::AdUserSync::SyncJob.name
        }
      }
    end
  end
end
