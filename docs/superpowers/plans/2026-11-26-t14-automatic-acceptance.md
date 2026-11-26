# T14 Automatic Acceptance Plan

> **For agentic workers:** Use superpowers:executing-plans inline and verification-before-completion. This is evidence/build validation, with no production behavior change or new dependency. The user explicitly requested continuous execution of the available automatic work.

**Goal:** Complete the 48-story evidence mapping and inspect current Android candidates for #15, preserving target-device gaps.
**Architecture:** Reuse existing application tests and guarded evidence. Build ordinary Release without installation; inspect a separate Release preview with the test identity. Store machine-readable results and a readable checklist together.
**Tech Stack:** Existing Flutter/Dart, Android SDK aapt/apksigner, Python standard library, GitHub CLI.
**Spec:** GitHub issues #1 and #15; AGENTS.md; docs/mvp-design.md; docs/validation/2026-11-25-quality-review/publication.md.

## Global Constraints

No formal data, audio, credentials or device settings access. No ordinary application installation. Do not touch either existing emulator or replace the user's preview. Temporary stores only for host tests. Preserve unrelated WIP, source schema2, backup v2, dependencies and experimental defaults. No device/paid-cloud claim. This follow-up produces local reviewable evidence; do not assume the previous bounded publication request authorizes new commits or issue writes.

Subsequent authorization (2026-11-26): after reviewing the automatic results, the user explicitly requested committing/pushing this evidence and updating #15. That request supersedes the publication restriction above; formal data and outstanding device acceptance remain protected.

## Review Focus

1. Each of 48 stories has a real implementation/test reference and an explicit device gap.
2. Archived tests and fresh execution are separately identified.
3. Formal Release must not contain an active validation provider or experimental crypto library.
4. Isolated candidate must have its own application ID and label, and cannot be represented as ordinary Release.
5. Signature, ABI, permissions, backup exclusions and hashes are observed from built artifacts, not inferred from filenames.

## Tasks

- [x] A1 Capture current issue requirements, HEAD/source digest and environment; create the 48-story plus seven-criterion matrix.
- [x] A2 Build ARM64 ordinary Release without installation, inspect badging/manifest/ZIP/signature/resources and archive checksum/size/build time.
- [x] A3 Build an isolated ARM64 Release manual preview, inspect test identity and boundaries without installing or disturbing existing emulators.
- [x] A4 Run appropriate current host gates and native checks serially; verify matrix completeness and referenced files. Report observed failures honestly.
- [x] A5 One bounded independent evidence review, fix confirmed evidence defects, finalize report/candidate links and remaining human prerequisites. No speculative feature refactor.
