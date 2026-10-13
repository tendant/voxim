# Releasing voxim

Releases are notarized DMGs published as GitHub Releases at <https://github.com/tendant/voxim/releases>. `scripts/release.sh` does the whole pipeline; the only manual part is a one-time credentials setup.

## One-time setup

You need, on the release Mac:

- **Developer ID Application certificate** for team `WJTDTA46K5` (Wei Labs LLC) in the login keychain. Check: `security find-identity -v -p codesigning | grep "Developer ID Application"`.
- **GitHub CLI logged in** with push access to `tendant/voxim`. Check: `gh auth status`.
- **Notarization credentials** stored in the keychain under the profile name `voxim-notary`:
  1. Create an app-specific password at **appleid.apple.com › Sign-In and Security › App-Specific Passwords** (name it e.g. "voxim notarization").
  2. Run (type the password yourself; don't paste it into chats or scripts):
     ```sh
     xcrun notarytool store-credentials voxim-notary \
       --apple-id <your Apple ID email> \
       --team-id WJTDTA46K5 \
       --password <app-specific password>
     ```
  3. Check: `xcrun notarytool history --keychain-profile voxim-notary` lists past submissions (empty is fine) instead of failing.

  An App Store Connect API key works too (`--key`, `--key-id`, `--issuer` instead of `--apple-id/--password`). Use another profile name by setting `VOXIM_NOTARY_PROFILE`.

## Each release

1. **Pick the version** (`major.minor.patch`). Pre-1.0 while the app is young: bump minor for features, patch for fixes.
2. **Update the project version** to match: `MARKETING_VERSION` in `voxim.xcodeproj` (all configurations). The script also overrides it at build time and checks the built app reports the right version. The build number is the git commit count, set automatically.
3. **Write release notes** at `docs/release-notes/v<version>.md` (see `v0.1.0.md` for the shape: highlights, requirements, install, known limitations). The SHA-256 of the DMG is appended automatically.
4. **Commit and push** everything. The script refuses to release unless the working tree is clean and `HEAD` equals `origin/main`.
5. **Optional dry run** (works without credentials and with uncommitted changes):
   ```sh
   scripts/release.sh <version> --dry-run
   ```
   Builds, packages and signs `build/release/voxim-<version>.dmg`, then stops before notarization.
6. **Release:**
   ```sh
   scripts/release.sh <version>          # asks before tagging and publishing
   scripts/release.sh <version> --yes    # no prompt (non-interactive)
   ```

### What the script does

| Stage | Details |
|---|---|
| Preflight | Clean tree at `origin/main`; tag `v<version>` doesn't exist; release notes exist; notary profile works; `gh` logged in; Developer ID identity present |
| Build | `scripts/install.sh --build-only` with `VOXIM_VERSION`: Release, Developer ID, hardened runtime, **secure timestamp**, microphone entitlement only, no `get-task-allow` |
| Package | DMG volume "voxim <version>" containing `voxim.app` and an `Applications` link (drag to install); DMG signed with timestamp |
| Notarize | `xcrun notarytool submit --wait` (usually 1–5 min); prints Apple's log if not accepted |
| Staple & verify | `xcrun stapler staple` (opens offline), `spctl --assess` must say *accepted, source=Notarized Developer ID*; SHA-256 computed |
| Publish | Annotated tag `v<version>` pushed; `gh release create` with the DMG, notes and SHA-256 |

7. **Check the release page**, download the DMG on a Mac, open it, drag to Applications and launch: there should be no "Apple could not verify…" warning.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `no notarization credentials in profile 'voxim-notary'` | Do the one-time setup above. |
| `working tree has uncommitted changes` / `HEAD is not origin/main` | Commit and push first; releases must match a pushed commit. |
| `tag vX.Y.Z already exists` | Bump the version. If a failed attempt left a tag: `git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z` (only if no release was published from it). |
| `app signature has no secure timestamp` | Network access to Apple's timestamp server is needed during signing; retry when online. |
| Notarization status `Invalid` | Read the printed log. Common causes: missing hardened runtime, missing timestamp, `get-task-allow` entitlement — `install.sh` checks all three, so look for something newly added (e.g. an unsigned embedded binary). |
| Release published but README link 404s | `releases/latest` ignores drafts and pre-releases; make sure the release is neither. |
| Notarization succeeded but publishing failed | The notarized DMG is still at `build/release/voxim-<version>.dmg`; publish manually: `git tag -a v<version> -m "voxim <version>" && git push origin v<version> && gh release create v<version> build/release/voxim-<version>.dmg --title "voxim <version>" --notes-file docs/release-notes/v<version>.md` |

## Not done yet

- **Auto-update** (e.g. Sparkle): users download new versions manually from the releases page.
- **CI releases:** the pipeline runs locally because it needs the Developer ID certificate and notary credentials.
