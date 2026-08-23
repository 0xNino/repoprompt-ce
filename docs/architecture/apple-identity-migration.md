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
2. `P` copies every present account in `SecureStorageAccountCatalog` from the current Developer ID
   Keychain service into the identity-migration bridge service.
3. Each new bridge item receives a classic macOS Keychain ACL derived from the running legacy-signed
   executable and an embedded executable signed for the successor identity.
4. `P` reads back every copied value byte-for-byte. It never deletes or rewrites the source items.
5. Only after every record is absent, copied, or verified does `P` persist the completion manifest and
   select the bridge as the canonical secure-storage backend.
6. If any read needs interaction, any values conflict, read-back fails, or the completion manifest
   cannot be persisted, the old secure-storage service remains canonical and Sparkle is paused.
7. After the bridge has been proven under both real signing identities, publish a notarized transition
   package (`T`) that installs the successor app. Feeds must keep `P` and `T` available long enough for
   slow-upgrading clients; use Sparkle item eligibility/version constraints instead of new feeds.

## Packaging contract

`REPOPROMPT_IDENTITY_MIGRATION_PHASE` is `disabled` by default. A protected preparer build sets it to
`legacy-preparer` for both staging and validation. The protected signing step must also provide
`REPOPROMPT_IDENTITY_MIGRATION_ANCHOR`, pointing to a regular executable already signed with identifier
`com.repoprompt.ce` and Team ID `69N6K965SF`.

`Scripts/sign_staged_release.sh` verifies that signature and identity before copying the anchor into
`Contents/Resources/IdentityMigration/RepoPromptIdentityAnchor`. It does not re-sign the anchor with
the legacy certificate. The outer legacy app signature then seals the embedded file as a resource.

## Required proof gate

Do not exercise the bridge against a maintainer's login Keychain. The final go/no-go proof must run in
an isolated macOS CI runner or disposable VM/account with a disposable Keychain and synthetic values
for the full account catalog. It must demonstrate:

- the legacy app can create, read, and update bridge items without authorization UI;
- the successor app can read and update the same items without authorization UI;
- mismatches, target-only values before commit, inaccessible records, and missing anchors fail closed;
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
