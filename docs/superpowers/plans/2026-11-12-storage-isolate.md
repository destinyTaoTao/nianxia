# Storage isolate implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline. User explicitly requested direct implementation; no commits or push.

**Goal:** Move all production SQLite execution off the UI isolate, paginate the library, and keep existing raw data and atomic restore behavior intact.
**Architecture:** A persistent storage isolate owns RecordRepository and its SQLite connection. Typed asynchronous requests return bounded list projections or detail records; archive merge, cancellation checks and cleanup run beside that same connection. UI uses loading/error/pagination state and rejects stale completions.
**Tech Stack:** Existing Flutter/Dart, sqlite3, Dart isolates. No new dependencies, no raw schema/backup version change.
**Spec:** docs/architecture-review.md (remaining storage execution issue) and current user request.

## Constraints and review focus

- Protect existing uncommitted work and device data; baseline copied to /tmp/nianxia-storage-isolate-before. Work in the existing codex/notecard-ui branch because it contains the authorized uncommitted implementation. Do not stash, reset, commit or deploy.
- Preserve migration snapshots, frozen v1 fixtures, CAS, durable media cleanup, and one-transaction restore.
- Cover stable pagination with equal timestamps and concurrent mutation, worker startup/close/error, edits/deletions during inference, cancelled/failed restore, and UI stale results.
- Measure event-loop responsiveness during actual large restore, not just total duration.

## Task 1: Worker ownership and typed reads

Files: lib/data/storage.dart, lib/data/record_repository.dart, lib/domain/record_page.dart, test/storage_isolate_test.dart.
Produces: Storage.open(Directory), async get/all/page/children/count/model/preferences/mutations/snapshot/close; RecordPage with bounded summaries, child counts, cursor and content generation.
- [x] Add failing tests for keyset pagination, actor ownership, ordered writes/close and unchanged reopen data.
- [x] Implement isolate request/reply lifecycle and repository indexed read projections. Open/migrate/check/snapshot only inside worker.
- [x] Run targeted storage tests.

## Task 2: Async application and atomic archive operations

Files: lib/app/notebook.dart, record_search.dart, background_tasks.dart, notebook_session.dart; lib/app/backup.dart, lib/data/restore_store.dart; affected tests/integration fixtures.
Produces: async Notebook get/records/children/page/detail/prepareOrganization/model changes and awaitable close; worker restore with durable media intent, cancellation before commit, unchanged conflict mapping.
- [x] Add failing actual restore responsiveness/cancel/queued edit tests.
- [x] Move preparation, deduplication and final transaction to worker; keep source codec in its existing isolate. Move ranking to storage worker and pending-job queries to bounded pages.
- [x] Migrate tests to awaited reads and test-only external SQLite inspection, keeping assertions and frozen fixtures intact.
- [x] Run application/storage/backup tests.

## Task 3: UI async state and pagination

Files: lib/ui/home.dart, detail.dart, app.dart, settings.dart; widget tests and visual tests.
Produces: first page of 40 bounded summaries, scroll-to-load, exact child counts; async detail/append reads; awaited theme persistence.
- [x] Add pagination/loading/error/stale completion tests.
- [x] Preserve existing design tokens and flows; add accessible retry/load-more states. Do not fetch all records from build or row builders.
- [x] Run widget and screenshot validation.

## Task 4: Independent review and complete validation

Files: docs/data-storage.md, docs/architecture-review.md, README.md only as needed for lasting contracts.
- [x] Request fresh independent review of final storage ownership, restore, UI async state and failure paths.
- [x] Fix confirmed issues using regression tests.
- [x] Run full Flutter tests, tool tests, analyze, Android ARM64 Release build; inspect diff and preserve existing data. Report iOS/real-device limitations explicitly.

## Outcome

154 Flutter tests, 14 tool tests and analyze passed. Protected Android storage runner passed four business cases; 8 formal data file hashes (database/WAL/audio) unchanged. Screenshots checked. No new dependencies or raw format versions, no commits/push or formal app installation. Review findings received regression tests; cancellation marker cleanup race was caught by the full suite and fixed. See README and docs/data-storage.md for persistent contracts.
