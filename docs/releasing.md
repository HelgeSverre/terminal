# Release credentials and recovery

## Build and install

```sh
just release-status  # Validate local identities and notarization access
just package         # Sign the app, ZIP, and PKG
just release         # Sign, notarize, staple, and validate both app and PKG
```

Artifacts are written to `dist/release`. The bundle identifier is
`no.helgesverre.terminal`; the PKG installs to `/Applications`.
`just install` builds an optimized bundle for `~/Applications/Helge Terminal.app`.
It selects a matching notarized artifact when available. Quit the installed app
before replacing it.

The release configuration is `~/.config/terminal/release.json`. It can specify
`applicationIdentity`, `installerIdentity`, and `notaryProfile`;
`APPLE_NOTARY_PROFILE` overrides the profile. Identities are detected when one
valid Developer ID certificate exists for each role.

## Credential policy

Helge requires notarization credentials and recovery details to be saved in his
**Personal** 1Password vault. Back up new or changed credentials there before
notarizing. Read back attachments and compare them with the working originals;
validate certificate passwords and matching private keys before claiming a
usable backup. Local Keychain profiles are working copies of this configuration.

## Current backup

**Terminal Release Signing** is in Personal, item ID
`[PRIVATE_1PASSWORD_ITEM]`, vault ID `[PRIVATE_1PASSWORD_VAULT]`.
It contains:

- The `notary_api_key` attachment, verified byte-for-byte after upload.
- Notarization Key ID and concealed Issuer ID.
- Bundle ID, team ID, both Developer ID identities and the local Keychain profile.
- References to the shared certificate exports and concealed passwords in
  **Sourcefour Release Signing**, item ID `[PRIVATE_1PASSWORD_SHARED_CERTIFICATES]`.

The shared `application_p12` and `installer_p12` attachments were downloaded to a
private temporary directory. Their passwords decrypt the exports, each private
key matches its certificate, and both certificates identify Liseth Solutions AS
with team `9Z2L5FBZS3`. Temporary secret files were removed after verification.
The [verification receipt](../reports/signing-backup.json) contains identifiers
and results, without credential values.

This follows Zest's project-specific item plus shared-certificate pattern. No new
Apple key or certificate was generated. The saved API key matches the current
Splash signing key and configuration; Terminal currently reuses its validated
`splash-notary` profile, recorded in `~/.config/terminal/release.json`.

## Recover on another Mac

Use the Personal vault's Terminal item to locate the API key and the shared
certificate exports/passwords. Retrieve binary attachments with `op read
--out-file` into a directory with permissions `0700`, and set individual secret
files to `0600`. Passing binary exports through text stdout can corrupt them.
Import the application and installer certificates with their matching passwords
into the intended local signing Keychain. Existing exports use legacy PKCS#12
encryption; OpenSSL 3 inspection requires `-legacy`.

Use `xcrun notarytool store-credentials` with the saved API key, Key ID and Issuer
ID to create a local profile. Record that profile name in the local release
configuration, then run `just release-status`. Delete temporary secret files
after import and validation. Keys, passwords and populated secret files stay
outside Git and application bundles.

The CLI's restricted automation service account sees only the Automation vault.
For Personal, use the desktop-integrated account explicitly, removing
`OP_SERVICE_ACCOUNT_TOKEN` only from the credential command's child environment:

```sh
env -u OP_SERVICE_ACCOUNT_TOKEN op item get [PRIVATE_1PASSWORD_ITEM] \
  --vault [PRIVATE_1PASSWORD_VAULT] --account my.1password.com
```

That command displays item fields, so use it in a private local session. Agent
workflows should capture output in memory and print only non-secret identifiers
or verification results. Never fall back to writing credentials to Automation
when Personal is unavailable.

Build/sign/notarize commands remain in [README](../README.md#packaging); this
document owns the credential-backup and recovery policy.
