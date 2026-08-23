# Apple Identity Migration

RepoPrompt CE cannot treat a Developer ID and bundle-identifier replacement as an ordinary in-place
Sparkle update. The migration must preserve the legacy signing anchor long enough to prepare secure
storage, then use a notarized transition installer to cross the application identity boundary.

## Fixed identities

| Phase | Bundle identifier | Team identifier |
| --- | --- | --- |
| Legacy and preparer | `com.pvncher.repoprompt.ce` | `648A27MST5` |
| Successor | `com.repoprompt.ce` | `69N6K965SF` |

The existing Sparkle EdDSA key and the Stable and Tip feed URLs remain unchanged. Each channel may
contain multiple update items during the transition; this does not require extra feeds.

## Release ladder

1. Ship a legacy-signed preparer (`P`) through the existing Sparkle path.
2. Before mutating bridge records, `P` writes a `preparing` journal to a dedicated Keychain service
   using the same validated dual-identity ACL as the bridge. The journal contains a random attempt
   identifier and the exact closed account catalog, allowing the successor to discover the committed
   bridge without relying on mutable preferences.
3. `P` copies every present account in the frozen version-2 migration catalog from the current
   Developer ID Keychain service into a bridge service whose name includes that attempt identifier.
   Service and account are generic-password primary-key attributes, so an orphaned earlier attempt
   cannot collide with a later attempt. New records use create-only writes so an unproven
   pre-existing ACL cannot be retained.
4. Each new bridge item receives a classic macOS Keychain ACL derived from the running legacy-signed
   executable and an embedded executable signed for the successor identity. Before creating that ACL,
   runtime code validates both executables against their exact identifiers, Team IDs, and Developer ID
   certificate requirements.
5. `P` reads back every copied value byte-for-byte. It never deletes or rewrites source items. If an
   attempt is interrupted, the next launch resumes the same journal: the source remains authoritative,
   changed source values are recopied, and attempt-scoped bridge values whose source disappeared are
   removed.
6. Only after every source and bridge value matches does `P` create and verify a committed bridge
   manifest, commit the dual-identity Keychain journal, and select the bridge as the canonical backend.
7. Later launches authenticate the journal and bridge manifest by inspecting their decrypt ACLs and
   requiring exactly the legacy and successor designated requirements before accepting the JSON.
   Later builds validate that ACL again before copying it to a new bridge item. The version-2 catalog
   remains frozen; accounts added to the app later are created in the already-authoritative bridge.
8. If any read needs interaction, validation or read-back fails, or either manifest cannot be persisted,
   the old secure-storage service remains canonical and Sparkle is paused. Settings surfaces distinguish
   a locked Keychain, cancelled access, authentication failure, and generic verification failure, then
   provide the corresponding relaunch guidance.
9. After the bridge has been proven under both real signing identities, publish a notarized transition
   package (`T`) that installs the successor app. Feeds must keep `P` and `T` available long enough for
   slow-upgrading clients; use Sparkle item eligibility/version constraints instead of new feeds.

## Packaging contract

`REPOPROMPT_IDENTITY_MIGRATION_PHASE` is `disabled` by default. A protected preparer build sets it to
`legacy-preparer` for both staging and validation. The protected signing step must also provide
`REPOPROMPT_IDENTITY_MIGRATION_ANCHOR`, pointing to a regular executable already signed with identifier
`com.repoprompt.ce` and Team ID `69N6K965SF`.

`Scripts/sign_staged_release.sh` validates the exact successor Developer ID requirement before copying
the anchor into `Contents/Resources/IdentityMigration/RepoPromptIdentityAnchor`, then validates the
embedded copy again. It does not re-sign the anchor with the legacy certificate. The outer legacy app
signature then seals the embedded file as a resource.

The protected release job builds a universal anchor from `Scripts/identity_migration_anchor.c` in the
trusted control-plane checkout. The minimal executable is never launched; it avoids embedding a second
copy of the main app binary while still giving Security.framework a successor-signed designated
requirement on both supported architectures.

Preparers are Stable-only artifacts. The rolling Tip workflow always packages, validates, and signs
with phase `disabled`; it has no migration-phase input or access to successor signing secrets.

## Required proof gate

Do not exercise the bridge against a maintainer's login Keychain. The final go/no-go proof must run in
an isolated macOS CI runner or disposable VM/account with a disposable Keychain and synthetic values
for the full account catalog. It must demonstrate:

- the legacy app can create, read, and update bridge items without authorization UI;
- the successor app can read and update the same items without authorization UI;
- interrupted writes resume from the dual-identity Keychain journal without losing a newer source value;
- a lost journal starts a collision-free attempt even when orphaned bridge records remain;
- forged journal or bridge-manifest ACLs fail closed and are never propagated to new credentials;
- inaccessible records, forged or missing manifests, invalid runtime anchors, and unknown phase values
  fail closed;
- a locked Keychain pauses updates visibly and a later unlocked relaunch retries successfully;
- originals remain intact after preparation and after a failed transition;
- rollback to the preparer can still read the bridge for the supported rollback window; and
- the preparer, transition package, and successor artifacts pass signature, notarization, and
  Sparkle EdDSA verification.

Certificate files, passwords, temporary Keychains, and synthetic credential values must remain in the
isolated environment and must never be committed, logged, or copied into a developer's login Keychain.

## Rollback

Before the transition package is published, rollback is simply removal of the eligible transition
item: clients remain on the legacy app, source Keychain items remain untouched, and a successfully
prepared client can continue using the bridge. After the successor is published, keep the preparer
and its signing material available until the supported migration window closes.
