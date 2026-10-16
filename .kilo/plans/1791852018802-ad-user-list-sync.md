# Daily AD user_list.csv sync (07:30 HKT)

## Goal
A scheduled job reads `/data/AD/import/user_list.csv` (read-only mount from `docker-compose.yml`)
every day at 07:30 Hong Kong time and reconciles OpenProject users and departments with it.

## Decisions (confirmed with user)
- **Key**: `mail` (case-insensitive, trimmed, unique). Rows with blank/duplicate mail are skipped and logged.
- **Sign-in matching**: set `login = mail`. Entra OIDC must send the email as the login claim so
  `Authentication::OmniauthService#remap_existing_user` (needs `Setting.oauth_allow_remapping_of_existing_users`,
  default true) attaches the Entra identity on first sign-in. No password, no self-registration.
- **Lock protection**: never lock admins, builtin users (system/anonymous/deleted) or users holding a global role.
- **accountEnabled**: ignored. Presence in the CSV is the only signal.
- **jobTitle**: auto-create (find-or-create) a text `UserCustomField` named "Job title", write on every run.
- **Safety guard**: abort with no changes if the file is missing/empty/missing required columns, or if the run
  would newly lock more than 20% of active normal users.

## Defaults assumed (not explicitly asked; change if wrong)
- `displayName` split: first token = `firstname`, remainder = `lastname`; single token fills both.
- Departments are plain (non-LDAP-managed) organizational-unit groups, flat (no parent), created by exact CSV name.
  Departments left empty are kept, never deleted. Blank department = remove the user from their department.
- "Inactive" = `status: locked`. A locked user who reappears in the CSV is set back to `active`
  (only if it was locked by this job; see Open item 1).
- Timezone: `cron: "30 23 * * *"` (UTC, equals 07:30 HKT, no DST). This is the same minute as the existing
  `Ldap::SynchronizationJob` (`"30 23 * * *"`). The two jobs run in parallel; that is acceptable only if LDAP sync
  is not configured here. If LDAP sync is in use, keep 23:30 anyway (exact 07:30 HKT was requested).

## Code facts the implementer needs
- Departments = `Group` with detail `organizational_unit: true` (`app/models/group.rb`, `Group.organizational_units`).
  `User#department` returns the single department. Name uniqueness is per parent.
- `Groups::AddUsersService` fails with `user_already_in_department` if the user is already in a department, so a
  move must remove the user from the old department first (use `Groups::UpdateService` or delete the `GroupUser`).
- Create users through `Users::CreateService` / `Users::SetAttributesService` (run as `User.system`), not raw SQL,
  so contracts, validation and callbacks apply. Updates through `Users::UpdateService`.
- Statuses: `Principal.statuses` = active, registered, locked, invited, deleted. Use `User.not_builtin`.
- Modules register cron via `add_cron_jobs do ... end` in their engine (see
  `modules/job_status/lib/open_project/job_status/engine.rb`). Modules are listed in `Gemfile.modules`.
- Custom field: `UserCustomField` (`app/models/user_custom_field.rb`), needs a `UserCustomFieldSection`.
- Rails runs in UTC. GoodJob cron only runs if a GoodJob worker is running in the all-in-one container.

## Implementation steps
1. Create module `modules/ad_user_sync` (gem `openproject-ad_user_sync`), add one line to `Gemfile.modules`, update
   `Gemfile.lock`. Keeps the customization out of core to avoid upstream merge conflicts.
2. `AdUserSync::CsvReader`: parse with Ruby `CSV` (headers, UTF-8 with BOM stripped), validate required columns
   (`mail,displayName,jobTitle,department`), normalise mail, drop blank/duplicate-mail rows, return rows + error list.
3. `AdUserSync::SyncService` (returns `ServiceResult`), single entry point with `dry_run:` flag:
   - Ensure "Job title" custom field exists.
   - Compute plan: to-create, to-update (only if displayName/jobTitle/department differ), to-lock, to-reactivate.
   - Apply safety guard before any write; abort and log if tripped.
   - Execute inside per-user transactions so one bad row does not stop the run; collect per-row errors.
   - Departments: find-or-create by name; move user if different (remove old, add new).
   - Log a summary (counts + errors) to `Rails.logger`.
4. `AdUserSync::SyncJob < ApplicationJob`, queue default, calls the service. Register cron `"30 23 * * *"`
   in the engine with `add_cron_jobs`. Path from `ENV["AD_USER_LIST_PATH"]`, default `/data/AD/import/user_list.csv`.
5. Rake task `ad_user_sync:run` and `ad_user_sync:dry_run` for manual and first-run use (dry run prints the plan).
6. Specs: CSV reader (BOM, blank mail, duplicates), service (create, update, move department, new department,
   lock, protected users, reactivate, guard trips at >20%, missing file), job enqueues the service.
7. Run `bin/dirty-rubocop --uncommitted`, module specs. Rebuild the image (`docker compose build`) since the module
   is baked into the image.

## Validation
- First deployment: run `ad_user_sync:dry_run` inside the container and review the lock list before enabling cron.
- Confirm in Admin > Background jobs (or GoodJob dashboard) that the cron entry shows `30 23 * * *`.
- Sign in with one pre-created Entra user and confirm no duplicate user is created.

## Open items
1. Reactivation: should the job re-activate any locked user who returns to the CSV, or only users it locked itself
   (manual admin locks would otherwise be overridden)? Default above reactivates only users the job locked
   (needs a marker, e.g. a hidden custom field or a note); confirm or simplify to "reactivate all".
2. Confirm the Entra OIDC provider maps the email claim to `login` (otherwise first sign-in will not attach).
3. Confirm the all-in-one image runs a GoodJob worker (otherwise the cron never fires); if not, schedule the rake
   task with the host scheduler instead.
4. Dev-environment note: `enterprise_token.rb` override and the replaced `docker-compose.yml` are unrelated to this
   job but should be revisited (see earlier review).

---

# Addendum (2026-10-16): My inbox project, `$` currency, Meetings off switch

Part 1 above is already implemented (module `modules/ad_user_sync`; new users are created `invited`, no email, path from
`AD_IMPORT_DIR`). Nothing below is implemented yet. Ruby/Docker are not available on the dev host, so all verification
happens in the container (`bundle exec rspec`, `rubocop`).

## A. "My inbox" private project per user (extends `AdUserSync::SyncService`)

Decisions (confirmed): existence is detected **by identifier**; identifier = `my-inbox-<cleaned account>` with
fallback to the cleaned full email on a clash with someone else's project.

Defaults assumed (not asked; change if wrong):
- Applies to every user in the CSV who is `active` or `invited` (not locked, not skipped). Runs on every sync, after
  the user was created/updated, so new and old users are both covered.
- Project: `name: "My inbox"`, `public: false`, created as `User.system` through `Projects::CreateService`
  (default modules/types/custom fields apply), then the user is added as member with the "new project" role
  (`ProjectRole.in_new_project`, i.e. `Setting.new_project_user_role_id`, normally *Project admin*) so they can share it.
  Creating it as the user is not possible: invited users lack the add_project permission.
- Favorite: added **only when the inbox is created** (`project.set_favorited(user, favorited: true)`, see
  `lib_static/open_project/acts/favoritable.rb`), so a user who un-favorites it is not overridden on the next run.
- No notification/email: pass through the service without sending the project-created mail
  (`Setting.new_project_send_confirmation_email` must not fire; verify).
- A user-deleted inbox is recreated on the next run (identifier is free again). An archived one counts as existing.

Identifier rules:
1. `account = mail.split("@").first.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A-+|-+\z/, "")`,
   `identifier = "my-inbox-#{account}"`, truncated to 100 chars (`Projects::Identifier::CLASSIC_IDENTIFIER_MAX_LENGTH`).
2. Lookup: `Project.unscoped.where("LOWER(identifier) = ?", identifier)` (includes archived), also check FriendlyId history
   (`Project.identifier_slugs.for_identifier`) so a renamed/reserved slug is not reused by another person.
3. If the project exists and the user is a member -> it is theirs, done (no create, no favorite).
4. If it exists/is reserved but the user is not a member (clash with another person's account name) ->
   retry with `my-inbox-<cleaned full email>` (`@` and `.` become `-`), apply the same lookup. If that clashes too,
   record an error for that user and continue.
5. Guard: only valid in classic identifier mode. If `Setting[:work_packages_identifier] == "semantic"` the identifier
   format is different (2-10 uppercase chars): skip inbox creation and add a warning to the run summary.

Code changes:
- `sync_service.rb`: add `ensure_inbox(user, row)` called for each CSV row after create/update (also for newly created
  users, whose `call.result` is the user); extend the summary with `inboxes_created` and `report_lines`; dry run only
  reports the planned inboxes. Per-user failures go to `errors` (job then fails visibly, as today).
- Do not touch locked users. The lock logic is unchanged.
- Specs: creates inbox + membership + favorite; second run creates nothing; dot/plus in account is cleaned; clash with
  another user's inbox falls back to full email; archived inbox is not duplicated; user-deleted inbox is recreated;
  existing user without inbox gets one; locked/absent user gets none; dry run writes nothing; semantic mode skipped.

## B. Default currency `$`

Decision (confirmed): change code defaults and use a prefix format.
- `modules/costs/lib/costs/engine.rb:175-176`: `costs_currency` default `"$"`, `costs_currency_format` default `"%u %n"`
  (shows `$ 100`).
- A value already stored in the database overrides the default, so on the existing instance set it once:
  `Setting.costs_currency = "$"` and `Setting.costs_currency_format = "%u %n"` (rails runner, or Administration >
  Costs). Document this in the final summary; do not add a migration.
- Check specs that assume `"€"` / `"%n %u"` (`modules/costs/spec`, `modules/xls_export/spec`, `modules/budgets`) and
  update them. Locale `number.currency.format` in `config/locales` is unaffected.

## C. System setting to switch Meetings off (modules/meeting)

Decision (confirmed): **fully block**, data is kept.

Setting:
- New boolean `meetings_enabled`, default `true`, registered in the meeting engine with
  `::Settings::Definition.add "meetings_enabled", default: true, format: :boolean` (initializer, like
  `costs.settings` in the costs engine).
- Admin UI: new page in Administration, modelled on `Admin::Settings::IcalendarSettingsController`
  (controller with `menu_item`, route `resource :meetings, controller: "/admin/settings/meetings_settings"` in
  `config/routes.rb` ~line 890 or in the module's `config/routes.rb`, admin menu entry like `menus.rb:526`, a form with
  one checkbox, en locale strings). Admin only.
- Do **not** try to flip permissions with `Permission#disable!`: `AccessControl` memoizes permissions per process and the
  all-in-one image runs several workers, so a runtime toggle would not take effect everywhere. Gate explicitly instead.

Gate points (all read `Setting.meetings_enabled?`):
1. `project_module :meetings, if: -> { Setting.meetings_enabled? }` in `engine.rb:43` (hides the module from Project
   settings > Modules and from `available_project_modules`).
2. Menus in `engine.rb`: project_menu `:meetings` / `:meetings_query_select`, work_package_split_view `:meetings`,
   and `should_render_global_menu_item` (top_menu + global_menu) get the setting added to their `if:` conditions.
3. Controllers (all in `modules/meeting/app/controllers`): a shared concern with
   `before_action { render_404 unless Setting.meetings_enabled? }` included in meetings, recurring_meetings (+schedule),
   meeting_templates, meeting_sections, meeting_agenda_items, meeting_outcomes, meeting_participants,
   meeting_presentation, work_package_meetings_tab, meetings/menus, meetings/ical, meetings/filters.
4. API v3: `Meetings`, `RecurringMeetings` and `MeetingAgendaItemsByWorkPackage` endpoints return 404/403 when off
   (find the right hook in `API::V3` base classes during implementation); hide the meeting links/embeds added to the
   work package representer (`Patches::API::WorkPackageRepresenter`) when off.
5. Core spots that probe `:view_meetings`: the activities-tab "hide meetings" filter
   (`filter_and_sorting_component.rb:69`) and the invitable-to-meeting principal filter; add the setting there.
6. Defaults: remove `"meetings"` from `default_projects_modules`. `Patches::SettingSeederPatch` re-adds it on seed;
   make it add it only when enabled, and drop `"meetings"` from the stored value of `default_projects_modules` when the
   setting is switched off, because `default_projects_modules` has `allowed:` = `available_project_modules` and a stored
   value containing a now-unavailable module can fail validation on the next save of that settings page.
7. iCal feeds / reminder and invite jobs for meetings: skip when off (check `modules/meeting/app/workers`).
- Re-enabling restores everything; existing projects keep `meetings` in their enabled modules, only hidden.
- Specs: setting off -> module absent from `available_project_modules`, menus hidden, controller returns 404, API 404,
  default modules exclude it; setting on -> unchanged behavior.

## Order of work
1. B (currency, smallest). 2. C (meetings setting + gates). 3. A (inbox in the sync service + specs).
Then run `bundle exec rspec modules/ad_user_sync/spec modules/meeting/spec modules/costs/spec` and
`bin/dirty-rubocop --uncommitted` in the container, rebuild the image, run `ad_user_sync:dry_run`.

## Open items (addendum)
1. Confirm the Project admin role is what the "new project" role setting points to on this instance (Administration >
   Projects > New project settings); otherwise the user cannot share the inbox.
2. Confirm `work_packages_identifier` is `classic` on this instance (Administration > Work packages > Identifier).
3. Whether sending the "project created" email is enabled (`new_project_send_confirmation_email`); inbox creation must
   stay silent.

---

# Addendum 2 (2026-10-16): lock the identifier of "My inbox" projects

Decision (confirmed): reject identifier changes on inbox projects for **everybody, admins included**.
Parts A-C above are implemented; this is a small follow-up. Ruby/Docker are not available on the dev host, so all
verification happens in the container.

## Rule
- An inbox is any project whose **original** identifier (`model.identifier_was`) starts with `my-inbox-`
  (constant `AdUserSync::INBOX_IDENTIFIER_PREFIX`, see below). Do NOT also require the name "My inbox": a user could
  otherwise rename the project first and change the identifier afterwards.
- If an inbox project's identifier changed, add an error on `:identifier`; the update is rejected (422 in the API,
  error shown in the identifier dialog). The name, description and other settings stay editable.
- Admins are not exempt (user's choice). Recovery for a wrongly named inbox is a console change
  (`Project.find(..).update_column(:identifier, ...)`), which bypasses contracts; document this in the final summary.

## Where
- `app/contracts/projects/update_contract.rb` (core, applies to every route that goes through the contract: the identifier
  dialog `Projects::IdentifierController#update`, API v3 `PATCH /projects/:id`, bulk/other updates). Add
  `validate :validate_inbox_identifier_unchanged` and a private method:
  `errors.add(:identifier, :inbox_locked) if model.identifier_changed? && model.identifier_was.to_s.start_with?("my-inbox-")`.
  Keep the check out of `BaseContract` so project creation (used by the sync job) is untouched.
- Constant: core must not depend on the module, so put the prefix literal in core
  (`Projects::Identifier::INBOX_IDENTIFIER_PREFIX = "my-inbox-"` in `app/models/projects/identifier.rb`) and make
  `AdUserSync::SyncService::INBOX_IDENTIFIER_PREFIX` reference it, so there is one source of truth.
- Locale: `config/locales/en.yml`, next to `identifier: must_start_with_letter` (~line 705, under the project attributes
  errors): `inbox_locked: "of a private inbox project cannot be changed"`. Check the surrounding key path when editing.
- Not affected on purpose: `ProjectIdentifiers::RevertProjectToClassicService` and `ConvertProjectToSemanticService`
  use `project.update!` (no contract). In semantic mode inbox identifiers are not created by the job, so no conflict.

## Specs
- `spec/contracts/projects/update_contract_spec.rb`: inbox project (`identifier: "my-inbox-hedy-wu"`) with a user who has
  `edit_project` -> changing `identifier` is invalid with `identifier: %i[inbox_locked]`; same for an admin; changing the
  name of an inbox stays valid; changing the identifier of a normal project stays valid; an unchanged inbox is valid.
- API/request spec (optional): `PATCH /api/v3/projects/:id` with a new identifier on an inbox returns 422.

## Known gaps (state in the final summary, do not silently expand scope)
- Anyone with `add_project` can create a normal project whose identifier starts with `my-inbox-` (e.g. `my-inbox-hedy-wu`)
  before the sync runs, which makes the job fall back to the longer `my-inbox-<full-email>` identifier. Blocking that
  needs a rule in `Projects::CreateContract` that exempts the system user; not included unless the user asks.
- The user can still rename the project (name) or delete it; the job recreates a deleted inbox with a fresh identifier
  only if the old one is free, otherwise falls back to the full-email identifier.
- The lock does not stop sharing the inbox (owner is project admin): that is by design (see requirement 1).

---

# Addendum 3 (2026-10-16): inbox as personal work package space + "Send to inbox"

Parts A-C and Addendum 2 are implemented. This addendum refines what the inbox is for. Nothing below is implemented yet.
Ruby/Docker are not available on the dev host; verify in the container.

## Clarified intent (corrects the earlier "private" reading)
- The inbox stays a **private** project (`public: false`, only the owner is a member). It is the owner's personal space
  for work packages that belong to no real project.
- Fact that shapes everything: a work package **must** belong to a project (`belongs_to :project`, required). "Not
  associated with any project" therefore means "lives only in the owner's inbox".
- Visibility is project-wide: `add_work_packages` depends on `view_work_packages`, so a "may create but not view" role
  is impossible. Per-work-package access exists only through **work package sharing** (entity-level `Member` rows with a
  `WorkPackageRole`), which is an Enterprise feature (`work_package_sharing`); the local `enterprise_token.rb` override
  currently enables it. If that override is ever removed, sharing (and this feature) stops working.

## Requirement 1: owner creates and shares own work packages (no new code, verify only)
- The owner is project admin of the inbox (role = `Setting.new_project_user_role_id`), so creating work packages in the
  inbox works with the standard screens (project picker: "My inbox"; it is also in the owner's favorites).
- Sharing a single work package with other users uses the standard Share dialog. Needs on the owner's role:
  `share_work_packages` and `view_shared_work_packages`. Verify in Administration > Roles that the "new project" role
  has both; if not, add them to that role (or fix in `ad_user_sync` spec setup). Document the check, no migration.
- Make sure each inbox has the module `work_package_tracking` enabled and at least one active type. Project creation uses
  the defaults (`default_projects_modules`, default types); add an explicit
  `enabled_module_names: Setting.default_projects_modules | ["work_package_tracking"]` to the inbox creation call in
  `SyncService#create_inbox_project`, and a sync step that repairs existing inboxes missing the module (idempotent).

## Requirement 2: "Send to inbox" (decision: dedicated dialog; standard form untouched)
Decisions (confirmed): dedicated dialog; the sender gets the seeded **"Work package commenter"** role on that one work
package; the inbox stays private (no project membership for the sender).

Behavior:
- New entry in the quick-add "+" menu: **"Send to inbox"** (precedent: `:invite_user` in `config/initializers/menus.rb`
  `:quick_add_menu`, opens a Turbo dialog via `Users::InviteController#start_dialog`). Visible to every logged-in,
  non-locked user (`User.current.logged?`), registered from the module engine with `menu :quick_add_menu`.
- Dialog fields: recipient (user autocompleter, only active/invited non-builtin users who own an inbox, excluding the
  sender), subject (required), description (optional), due date (optional). Type/priority/status use project defaults.
- On submit a service creates, in **one transaction**:
  1. the work package in the recipient's inbox, `author = sender`, `assigned_to = recipient`; created as `User.system`
     with `contract_class: EmptyContract` (author is not writable for non-admins, and the sender has no rights in the
     inbox); journal attributed to the sender via `User.execute_as(sender)`;
  2. a work package share for the sender with the seeded "Work package commenter" role
     (`Shares::CreateService.new(user: User.system, contract_class: EmptyContract).call(entity:, project:, principal:
     sender, roles: [commenter], send_notifications: false)`; pattern: `WorkPackages::CopyService#create_share`,
     `app/services/work_packages/copy_service.rb:154`).
- Notifications: the recipient gets the normal "assigned to you" notification; the sender gets none (no share mail).
- Tracking for the sender: the work package appears in "Created by me" and "Shared with me"; the success flash links to it.
- If the recipient has no inbox (e.g. created before the sync ran) they are simply not offered; if the commenter role or
  the Enterprise sharing feature is missing the service fails, rolls back, and shows a clear error to the sender.

Where: module `modules/ad_user_sync` (it already owns the inbox concept).
- Extract inbox lookup into `AdUserSync::Inbox` (`.identifiers_for(mail)` moved from `SyncService#inbox_identifiers`,
  `.for(user)` returns the project whose identifier is one of the candidates AND where the user is a member). The identifier
  is locked, so this is stable. `SyncService` calls the shared helper.
- `app/services/ad_user_sync/send_to_inbox_service.rb` (returns `ServiceResult`), params: sender, recipient, subject,
  description, due_date.
- `app/controllers/ad_user_sync/send_to_inbox_controller.rb`: `new` (renders the dialog, turbo stream) and `create`
  (calls the service, closes the dialog, flash). `before_action :require_login`; add `no_authorization_required!` for the
  two actions like `Users::InviteController`; reject locked/anonymous senders and recipients without an inbox (404/422).
- `app/forms/ad_user_sync/send_to_inbox_form.rb` + dialog component under `app/components/ad_user_sync/` following
  `app/components/users/invitation*` (autocompleter pattern: `app/forms/users/invitation/principal_step/form.rb`).
  The recipient autocompleter must query only inbox owners: add a small JSON endpoint in the controller
  (`recipients`, filtered by name, limited) instead of widening the global principal API.
- `config/routes.rb` of the module, `config/locales/en.yml` of the module (all UI strings via keys), engine
  `menu :quick_add_menu, :send_to_inbox, ..., icon: "inbox"` (pick an existing Octicon name).
- Respect the Meetings-style kill switch? Not needed; no new setting.

## Specs (container)
- Service: creates the work package in the recipient's inbox with author = sender and assignee = recipient; sender gets the
  commenter share; sender can view it (`WorkPackage.allowed_to(sender, :view_work_packages)`) but cannot view another
  work package in the same inbox; sender cannot edit it; no mail to the sender; transaction rolls back when the share
  fails (no orphan work package); sending to self or to a user without inbox is rejected.
- Request spec: dialog renders for a logged-in user, anonymous is redirected, create returns the success turbo stream,
  recipients endpoint returns only inbox owners and never the sender.
- Inbox repair: sync enables `work_package_tracking` on an inbox that lacks it; second run is a no-op.

## Risks and open checks
1. Enterprise sharing dependency (see above). Fail loudly, do not silently create unshared work packages.
2. Recipient list reveals who has an inbox (= all staff); acceptable, same visibility as the user list. If it should be
   limited to users the sender may already see (`User.visible`), say so.
3. The recipient (project admin) can remove the sender's share or delete the work package; then the sender loses
   tracking. By design: the recipient owns the inbox.
4. Notification volume: every send triggers one assignee notification to the recipient.
5. Verify `WorkPackages::CreateService` accepts `author`/`assigned_to` with `EmptyContract` and `User.system`, and that
   `Shares::CreateService` needs no `view_shared_work_packages` on the acting user when run as system.

---

# Addendum 4 (2026-10-16): MCP tool `assign_work_package` (external programs -> inbox or project)

Parts A-C, Addenda 2-3 are implemented ("Send to inbox" dialog + `AdUserSync::SendToInboxService` + `AdUserSync::Inbox`).
This adds the same capability for external programs through the MCP server. Not implemented yet. Ruby/Docker are not
available on the dev host; verify in the container.

## Verified facts (no code change needed)
- Auth: `API::Mcp` (`lib/api/mcp.rb`) uses `authentication_scope :mcp`; `RootAPI#authenticate` does
  `User.current = warden.authenticate!(scope: :mcp)` (`lib/api/root_api.rb:73`), strategies `user_api_token oauth jwt_oidc
  user_basic_auth ...` (`config/initializers/warden.rb:57`). The endpoint passes `server_context: { current_user: User.current }`
  (`lib/api/mcp.rb:60`); tools read it via `Base#current_user` (`mcp_tools/base.rb:200`). So a tool acts as the
  authenticated user, locked users cannot authenticate. Existing proof: `spec/requests/mcp/mcp_tools/create_work_package_spec.rb`
  (Bearer token with scope `mcp`).
- Exposure: a tool is only served when an `McpConfiguration` row with identifier `tools/<name>` exists and is enabled
  (`McpTools.enabled_mcp_tools`). `McpConfigurationSeeder` creates missing rows at each `db:seed` (container start runs it),
  using `default_title` / `default_description`. Admins can later disable/rename it in Administration > MCP.
- Requires Enterprise `mcp_server` (already granted by the local `enterprise_token.rb`) and the server enabled in admin.
- The existing `create_work_package` tool cannot target another user's inbox (needs `add_work_packages` in the private
  project) and cannot set the author (read-only for non-admins, `create_contract.rb:38`).

## Decisions (confirmed)
- One new tool, `assign_work_package`, in `modules/ad_user_sync` (keeps core untouched).
- `project_id` given -> create **in that project** (normal rules); omitted -> create in the **assignee's My inbox**.
- **Author**: optional, defaults to the caller. Setting an author other than the caller is allowed for **administrators only**
  (typically a dedicated service account); others get an error. No new settings.

## Tool contract (`McpTools::AssignWorkPackage`, name `assign_work_package`)
Registered as `tools/assign_work_package`; annotations read_only false, idempotent false, destructive false.
Input schema (all strings/numbers, no nested HAL):
- `assignee` (required): user id or e-mail address of the person the work package is assigned to.
- `subject` (required), `description` (optional, markdown), `due_date` (optional, `YYYY-MM-DD`).
- `author` (optional): user id or e-mail; default = caller; other than caller needs admin.
- `project_id` (optional): numeric project id. Absent = assignee's inbox.
Output (small hash, not the HAL representer, because in the inbox case the caller may only hold a comment share):
`{ id, subject, url, project: { id, identifier, name }, author: { id, name }, assignee: { id, name } }`, or
`{ error: "<message>" }` on failure (same convention as the other tools: errors are returned, not raised).

## Behavior
1. Resolve users: `assignee` and `author` by id or case-insensitive mail among `User.not_builtin` with status active or
   invited. Resolve through `User.visible(current_user)` for non-admin callers so the tool does not enumerate hidden users.
   Unknown/locked -> error naming the argument.
2. Author rule: `author` present and not the caller -> `current_user.admin?` else error
   "Only administrators can set a different author."
3. **Without `project_id` (inbox)**: call `AdUserSync::SendToInboxService.new(sender: author).call(recipient: assignee,
   subject:, description:, due_date:)`. This reuses all checks (self-send rejected, assignee needs an inbox, Enterprise
   sharing + commenter role present, one transaction). The author gets the commenter share, so he can track it; the journal
   and `author_id` are the author. Notification goes to the assignee only.
4. **With `project_id`**: `project = Project.visible(current_user).find_by(id:)` else error "project not found".
   - Author == caller: `WorkPackages::CreateService.new(user: current_user).call(project:, subject:, description:,
     assigned_to: assignee, due_date:)` with the standard contract (needs `add_work_packages` in the project; assignee must be
     assignable there; type/status/priority defaults apply). Errors come back as `{ error: result.message }`.
   - Author != caller (admin): the standard contract refuses to write the author unless `apiv3_write_readonly_attributes`
     is on, so instead check explicitly that the author may add work packages in the project
     (`author.allowed_in_project?(:add_work_packages, project)`) and that the assignee is in
     `Principal.possible_assignee(project)`, then run `WorkPackages::CreateService.new(user: author,
     contract_class: EmptyContract)` with `author: author`. If the author cannot even view the project afterwards, fail
     instead of creating an invisible work package.
5. `due_date` parsed with `Date.iso8601`; invalid -> error. Empty subject -> error.
6. No new enterprise or setting dependency beyond the above; inbox branch inherits the `work_package_sharing` requirement.

## Files
- `modules/ad_user_sync/app/services/mcp_tools/assign_work_package.rb` (Zeitwerk merges into the core `McpTools` namespace;
  confirm that the module's `app/services` is autoloaded, which it already is for `AdUserSync::*`).
- Registration in `OpenProject::AdUserSync::Engine`: `config.after_initialize { McpTools.register McpTools::AssignWorkPackage }`
  (core registers its own tools in `config/initializers/mcp.rb` the same way; do not edit that file).
- Small refactor: extract user lookup (`id or mail`) into a private helper of the tool; no change to `SendToInboxService`.
- No migration; the `McpConfiguration` row appears through the seeder on next container start. For an already running
  instance, run `bundle exec rake db:seed` or restart the container, then check Administration > MCP lists
  "Assign work package".

## Specs (container) `modules/ad_user_sync/spec/requests/mcp/assign_work_package_spec.rb`
Pattern: `spec/requests/mcp/mcp_tools/create_work_package_spec.rb` (OAuth token, scope `mcp`, `with_ee: %i[mcp_server work_package_sharing]`,
`McpConfiguration` rows for server and tool, shared example "MCP text tool").
- Inbox: caller non-admin, `assignee` by mail -> work package in assignee's inbox, author = caller, assignee set, caller
  can view it, cannot view another inbox work package.
- Admin caller with `author` = other user -> author is that user, journal user is the author, author has the commenter share.
- Non-admin caller with another `author` -> error, nothing created.
- `project_id`: caller with `add_work_packages` -> created in the project, assignee set; caller without permission -> error;
  unknown/invisible project -> error; admin with other `author` -> author set, no contract bypass for assignees who are
  not assignable (error).
- Assignee without inbox / locked / unknown -> error; assigning to self in inbox mode -> error; invalid date -> error.
- Tool is listed by `tools/list` only when its configuration row is enabled.

## Risks
1. An admin-token program can write as any user (accepted, admins only). Log the effective author and the caller in the
   rails log for traceability (`Rails.logger.info`).
2. Inbox deliveries need `work_package_sharing`; if the Enterprise override is removed the inbox branch fails with the
   service's "sharing unavailable" message while the `project_id` branch keeps working.
3. The project branch with a different author uses `EmptyContract`; the explicit checks above replace what the contract
   would validate (permission, assignable assignee). Keep them in one private method and cover with the specs.
4. Notification volume: one assignee notification per call; callers that loop over many items will spam the assignee.
