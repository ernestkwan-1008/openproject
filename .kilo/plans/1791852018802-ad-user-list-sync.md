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
