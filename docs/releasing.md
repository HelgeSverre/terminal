# Releases

The [Release workflow](../.github/workflows/release.yml) tests, builds, signs,
and notarizes the app. A version tag publishes the ZIP, checksums, and artifact manifest to GitHub Releases, then updates
`Casks/helge-terminal.rb` in [homebrew-tap](https://github.com/HelgeSverre/homebrew-tap).
That cask update also refreshes [tap.helgesver.re](https://tap.helgesver.re/).

## Publish a version

Set `CFBundleShortVersionString` and increment `CFBundleVersion` in
`Resources/Terminal/Info.plist`. Commit the tested changes to `main`, then tag that commit:

```shell
git tag vX.Y.Z
git push origin vX.Y.Z
```

The tag must match the bundle version and point to a commit on `main`.
The workflow verifies both before using credentials. It creates a draft,
uploads and checks the assets, publishes the release, then updates the cask's
version, download URL, checksum, and livecheck source. It refuses to replace
different assets under an existing version or downgrade a newer cask.

To test signing and notarization without publishing, run the workflow manually:

```shell
gh workflow run release.yml --ref main
```

Manual runs upload signed artifacts to the workflow run and skip GitHub Releases
and Homebrew. Rerunning a failed tag run resumes publication when the uploaded
assets match; a changed build needs a new version.

## Credentials

Recovery copies live in Helge's **Personal** 1Password vault:

- **Terminal Release Signing** holds the notarization API key, its identifiers,
  signing metadata, and the dedicated `terminal-homebrew-tap` token.
- **Sourcefour Release Signing** holds the shared application
  certificate export and its password.

The fine-grained Homebrew token is restricted to `homebrew-tap`, with Contents
read/write and Metadata read permissions. It follows the other project tap
tokens' no-expiry setup. The workflow uses it only in the publication job to
update the tap. The release repository's own token publishes its assets.

Repository secrets contain working copies:

| Secret | Value |
| --- | --- |
| `APPLE_APPLICATION_CERTIFICATE_BASE64` | Base64 application PKCS#12 export |
| `APPLE_APPLICATION_CERTIFICATE_PASSWORD` | Export password |
| `APPLE_APPLICATION_SIGNING_IDENTITY` | Developer ID Application identity |
| `APPLE_NOTARY_KEY_BASE64` | Base64 notarization API private key |
| `APPLE_NOTARY_KEY_ID` | API key ID |
| `APPLE_NOTARY_ISSUER_ID` | API issuer ID |
| `APPLE_TEAM_ID` | Apple developer team ID |
| `HOMEBREW_TAP_TOKEN` | Dedicated tap token |

Back up new or changed credentials in Personal before updating these secrets.
Read back attachments and compare them with the originals; verify the export
passwords and matching private keys. Never store populated credential files,
passwords, or private keys in Git, build artifacts, or caches.

The signing job imports credentials into a temporary Keychain, deletes the
import files, and stores the notarization profile in that Keychain. Cleanup
restores the runner's search list and deletes the temporary Keychain even if
the build fails. Only the app ZIP, checksums, and release metadata are
uploaded as workflow artifacts.

## Build and install locally

```shell
just release-status  # Check signing identities and notarization access
just package         # Sign the app and ZIP
just release         # Also notarize, staple, and validate the app and ZIP
just install         # Install an optimized build in ~/Applications
```

Artifacts go to `dist/release`. The bundle ID is `no.helgesverre.terminal`;
the Homebrew cask installs the ZIP to `/Applications`. Quit the installed app before
replacing it. `just install` selects a matching notarized artifact when available.

Local configuration is `~/.config/terminal/release.json`, with optional
`applicationIdentity` and `notaryProfile` fields.
`APPLE_NOTARY_PROFILE` overrides the profile; `APPLE_SIGNING_KEYCHAIN` selects an
explicit Keychain. When there is one valid Developer ID Application certificate, the
identity is detected automatically.

Releases no longer include a PKG: the installer certificate and its repository
secrets are no longer used and can be removed.

## Recover on another Mac

Retrieve the API key and shared certificate attachments into a temporary
directory with permissions `0700`, with each secret file set to `0600`.
Use `op read --out-file` for binary attachments. Import both certificates with
their matching passwords, then create a local profile with
`xcrun notarytool store-credentials`. Record its name in the local release
configuration and run `just release-status`. Delete the temporary secret files.
Existing certificate exports require OpenSSL 3's `-legacy` option for inspection.

The restricted automation service account sees only the Automation vault. Use
the desktop-integrated account explicitly for Personal, removing the service
token only from that command's child environment:

```shell
env -u OP_SERVICE_ACCOUNT_TOKEN op item get 'Terminal Release Signing' \
  --vault Personal --account my.1password.com
```

That command displays item fields; run it only in a private local session.
Automated recovery should capture values in memory and report verification
results without printing credentials. Local Keychain profiles are working
copies; Personal remains the recovery source.

Tag a tested code commit whose message does not contain `[skip ci]` or another
Actions skip marker. Such markers also suppress tag-push release workflows.
