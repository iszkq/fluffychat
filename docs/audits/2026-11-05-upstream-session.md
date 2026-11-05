# 3.0.7 upstream session comparison build

This release keeps desktop QR authorization and restores the mobile session
management behavior of krille-chan/fluffychat at the commit pinned in
`upstream-session-baseline.json`. It is a controlled comparison, not a claim
that the reported unexpected logout has been fixed.

## Restored and verified

- `onSoftLogout` calls the SDK's `refreshAccessToken()` directly, exactly as
  upstream. Removed the 3.0.6 custom exception classifier.
- The HTTP client is the upstream `CustomHttpClient` without a refresh wrapper.
- `init_with_restore.dart`, including backup serialization, restoration and
  deletion, is identical to the pinned upstream source. It was already identical
  in published 3.0.6. The proposed refresh-aware backup changes were never released.
- OIDC, SSO, HTTP transport, and Matrix SDK 14.1.0 match this upstream baseline.
- No SDK source overrides or patched Matrix dependencies are introduced.

`python3 scripts/check_upstream_session.py` checks these invariants in CI, using
normalized source hashes and the pinned SDK version. No upstream network fetch
is needed during this check.

## Deliberately retained differences

- QR account adapter, encrypted password provisioning, and key handoff remain
  feature code. Password login retains the selected discovered Client and
  captures credentials for the QR vault after successful SDK login. Changing
  a password also updates that vault. Neither hook calls logout or refresh.
- iOS sideloading support retains private Keychain fallback and the existing
  App Group container fallback. Removing them could make existing sideloaded
  installations unable to open their database. No storage keys, paths, bundle
  identity, or database formats are changed in this release.
- Existing database preservation remains: a Keychain/permission/open failure
  must not delete the database. Upstream still contains destructive recovery
  paths; those are not reintroduced into an installed app with user data.
- Read-only diagnostics record the SDK's session-cleared reason, UTC time and
  elapsed seconds since QR authorization. The last 20 records survive restart.
  No tokens, passwords, user IDs, device IDs or response bodies are recorded.
- Unrelated messaging, mention permissions, notifications and media features
  are outside this session comparison.

## Interpretation

QR password login requests a distinct PC device. The phone's access token is
not copied to the PC. Cancelling a PC login revokes only the independently
created PC token after verifying its identity. No QR path calls logout-all.

Two clients showing the login page is not proof of server-side cross-device
revocation. On Windows, independently reproduced local credential decryption
failure can show the login page without revoking the phone's server session.

If logout recurs in this comparison build, collect the preserved SDK clear
reason and correlate it with server device/token records. Remaining QR feature
code, iOS storage compatibility, upstream SDK behavior and server token policy
are all still candidates. In SDK 14.1.0, some temporary Matrix refresh failures
can themselves clear the local session even with the upstream callback.

Use the same iOS bundle identity and signing identity when updating. Reinstalling
with a different signing identity is a separate storage migration experiment
and cannot be used to establish a QR login regression.

The session comparison package skips the unchanged native camera simulator test:
the hosted Intel simulator stalled before app compilation. The normal mobile
workflow keeps that test enabled with a ten-minute timeout. This package still
runs the complete login/QR/recovery suite and verifies camera code inclusion and
the compiled iOS package identity. No camera sources changed.
