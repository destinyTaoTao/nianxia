# First semantic query and 100k search implementation plan

**Goal:** Return useful complete offline results without waiting for the whole HNSW build, and measure 100k records for latency, RSS and sidecar bytes.
**Architecture:** Pending vectors use paged exact retrieval until incorporated into the approximate graph; graph maintenance runs as owned, yielding background work with a durable queue. Batch graph writes, immutable vector storage and compact graph identifiers reduce construction overhead. Main schema 2, backup 2 and original media remain unchanged; cache-only upgrades are rebuildable.
**Spec:** User request in this chat; existing local-first/data invariants in AGENTS.md and docs/data-storage.md. Implementation is inline; final independent review under executing-plans. No commit/push or official app upgrade.

## Tasks and acceptance

- [x] Establish red tests for first semantic results while the graph remains pending; close/reopen, edit/delete/model change and cache failure must stay safe. Query status must disclose ongoing indexing; no silently truncated pending-vector coverage.
- [x] Implement owned background maintenance, query prioritization and shutdown; exact pending pages validate source/model/revision and bound query workspace. Warm retrieval still uses HNSW.
- [x] Reduce graph writes and identifier overhead without lowering construction/search recall parameters; preserve existing cache recovery or rebuild only known cache versions. Compare 10k construction and recall against the current snapshot.
- [x] Add a standalone reproducible benchmark: separate seed/run processes, generated UUID IDs, deterministic 100k x 512D data, bounded ground truth/top-k, cold/while-building/warm/reopen phases, p50/p95/max query latency, RSS baseline/current/OS peak and DB/WAL/SHM bytes. No raw content logged. Temporary marked fixtures only; clean only owned fixture directories.
- [x] Run benchmark and functional/full host gate, protected Android native search+storage, ARM64 Release, fresh review and final diff. Hash official data before/after; document limits and actual evidence.

## Review focus

Background work must stop before DB close; asynchronous failures must not become unhandled errors or invalidate raw saves. Queries cannot race incomplete text reconciliation or mix graph and pending versions. Pending matches must not balloon into unbounded semantic output/workspace. RSS includes the whole benchmark process (VM, heap, SQLite/native pages); it is not a Dart heap measurement or a phone limit. Large benchmarks run separately from the regular quick test suite.

## Progress

Baseline preserved in `/tmp/nianxia-cold-search-before`; all prior uncommitted changes retained. Previous measured 10k/64D graph preparation ~30s; pending-vector queries currently await all graph batches.

Implemented and verified before long measurement: 195 Flutter + 15 Python tests and analyzer pass; Android native real-offline-BGE search 2 business cases + source/backup storage 4 pass; ARM64 Release built (51.2MB), never installed into official app. All benchmark work stays in marked temporary fixtures. 100k/512D exploratory first query exposed 46.457s text-index wait; final cold source fallback has returned in 2.213s without waiting for that build.

Independent review fixes were proven RED→GREEN: self-wait during source reconciliation, fallback close/semantic workspace, compaction clearing the graph under a paged query, and steady same-model embedding writes starving cold query. Reviewed cache-only v2 with integer postings, alias/app-ID checks; preserved source/backup versions. An existing sidecar is now rejected by the cold benchmark entrypoint; exploratory cache was removed only from the marked synthetic fixture before final run. Final benchmark measurement is running in a standalone AOT process without concurrent builds/tests.

100k cold run complete: first=2212.752ms, full background=987890ms, sidecar=795275264 bytes, process peak=107347968 bytes. Initial warm Recall@10=0.9167 failed acceptance, ef512 alone also failed. Actual graph upper-route trace and tiny deterministic RED→GREEN showed a greedy local minimum; query-only upper beam8 fixed it without changing construction/graph. Same-graph ef200/beam8 warm repeat: Recall=1.0 on all12 queries, p95=29.553ms, mean distances1045.08, process peak93323264 bytes. Keyword p95=.349ms; broad all100k query=3656.204ms, peak104087552 bytes. Source DB SHA unchanged. Raw failed/passing artifacts preserved under docs/performance/search-100k-2026-11-13/. Final whole host gate after beam fix:196 Flutter+15 Python, analyzer clean. Android native search2/storage4 business scenarios and Release51.2MB pass after final query change; official8 data hashes match, official installation unchanged. Final diff/whitespace and dependency locks/metric JSON checked, no commits/push.
