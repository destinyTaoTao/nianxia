# Offline indexed search implementation plan

**Goal:** Replace per-query whole-library text/vector scans with local indexes while preserving Chinese substring keywords, offline semantic search, raw data and recoverable backups.
**Architecture:** A rebuildable SQLite sidecar owns exact character n-gram postings and a disk-backed HNSW graph. The existing storage isolate owns queries and incremental maintenance; raw records/embeddings remain authoritative. HNSW supplies bounded approximate candidates, followed by revision/model checks and exact cosine reranking. No production dependency or raw schema/backup version change.
**Sources:** SQLite FTS5 documentation (trigram cannot itself preserve 1–2 character substring queries), Malkov/Yashunin HNSW paper (arXiv:1603.09320). Use a portable B-tree postings index instead of requiring system FTS5 support.

## Contracts

- Chinese 1-character, 2-character and longer substring matching, punctuation, width and case normalization retain exact contains verification; no server/network calls.
- Index files are disposable, excluded from backup; startup reconciles source IDs/revisions and changed embeddings. Raw edits are committed independently of cache writes. Failed cache maintenance cannot roll back saved user content.
- Cascade deletion, delayed inference, model change, restore commit/rollback and worker close must not expose stale/deleted records.
- Cold build/rebuild may scan source once; normal selective queries must not scan/normalize the whole library or decode every vector.
- Approximate semantic recall is measured against exhaustive exact neighbors; disclose approximate and bounded semantic results. Keyword results stay exact. Date filters and source snippets remain correct.

## Tasks

- [x] Pure disk-agnostic HNSW module + in-memory test adapter: query recall, bounded distance evaluations, deletion, stable topology restore, numerical validation.
- [x] SQLite sidecar: character postings, source reconciliation, disk graph adapter with bounded LRU, corruption/reset handling and incremental invalidation.
- [x] Storage/Notebook search integration: keep source/model CAS, fallback and edit/delete/restore semantics; move all maintenance/ranking off UI and constrain semantic candidate count.
- [x] Regression/scale/recall/native offline validation; fresh independent review; full tool/check.sh and Android Release build; preserve formal data hashes. Update storage/retrieval contracts and measurements.

No commits/push, dependency installation, formal app upgrade or destructive cleanup. Existing branch and uncommitted work preserved at /tmp/nianxia-search-before. Work may be split between independent module implementers under subagent-driven-development; main agent owns integration and validation. Flutter commands run serially.

## Execution evidence (2026-11-13)

- Full host gate: 188 Flutter + 15 Python, analyzer clean. Persistent 10k/64D Recall@10=1.0, mean 292.92 distances; warm keyword scan/index p95 57.699/0.496ms; semantic p95 10.461ms. Text cold 3010ms, graph first 29586ms, warm reopen 460ms. These are synthetic host measurements, not device acceptance.
- Text preparation and durable graph queue separated after measuring a 32s combined cold build. Graph batches yield after 8 nodes; keyword queries can bypass graph-only work, but never incomplete text reconciliation. SQL access paths validated for narrow dates and same-day tuple paging.
- Independent reviews found and fixed whole-terms scans, malformed/missing graph recovery, overflow reconciliation bypass and date access paths; final scoped re-review accepted the tuple pagination fix.
- Protected Android native search 2 business scenarios (real offline BGE + 1000 same-day records) and storage 4 business scenarios passed. Official DB/WAL/audio hashes: 8 files unchanged. No microphone capture or HTTP in new search target.
- Android ARM64 Release built (51.2MB), main application ID verified, no official app installation. Final diff/whitespace checks passed; dependency manifests/lock unchanged. Existing work preserved, no commits/push. Evidence logs: `/tmp/nianxia-search-final-gate.log`, `/tmp/nianxia-search-android-final.log`, `/tmp/nianxia-search-android-storage.log`, `/tmp/nianxia-search-release.log`; official hashes `/tmp/nianxia-search-official-before.sha256` and `after.sha256` match.
