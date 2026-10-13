# frozen_string_literal: true

require "open_project/plugins"

module OpenProject::AdUserSync
  class Engine < ::Rails::Engine
    engine_name :openproject_ad_user_sync

    include OpenProject::Plugins::ActsAsOpEngine

    register "openproject-ad_user_sync",
             author_url: "https://github.com/opf/openproject",
             bundled: true

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
