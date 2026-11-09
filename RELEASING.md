# Releasing Simple Clipboard

How to cut a release and publish the `.dmg` that users download.

The repo is `juancarloslopez3/simple-clipboard`. Everything below runs on your Mac —
there is no CI for releases.

---

## 1. Build the disk image

```bash
scripts/make-dmg.sh
```

That single command does the whole job:

1. builds the **Release** configuration as a **universal** binary (`arm64` + `x86_64`),
2. stages `Simple Clipboard.app` next to a symlink to `/Applications`,
3. renders the window background at @1x and @2x (`scripts/dmg-background.swift`) and
   combines them into one Retina-aware `background.tiff`,
4. drives Finder to place the icons, hide the toolbar and set the background,
5. installs the volume icon (from `AppIcon.appiconset`),
6. compresses everything to `dist/Simple-Clipboard-<version>.dmg` and writes a
   matching `.sha256`.

Pass `--skip-build` to repackage the app already sitting in `build/` without
recompiling — handy while iterating on the artwork.

### The Finder step needs Automation permission

Finder is the only API that can write a volume's icon layout, so the script sends
it Apple Events. The first run pops **"<your terminal> wants access to control
Finder"** — click **Allow**. Without it the script falls back to
`scripts/dmg-assets/DS_Store`, a layout cached from a previous successful run
(checked in, which is also what lets a machine with no Finder access still produce
a styled image). If neither is available you still get a valid `.dmg`, just an
unstyled one.

Two Finder quirks the script works around, in case you ever rewrite it:

- Finder's `bounds` is the window's **outer** frame, while the background image and
  the icon coordinates are anchored to the content area. The frame is therefore made
  `TITLE_BAR_HEIGHT` (32 pt) taller than the artwork.
- Opening a **writable** volume makes Finder **delete** `.VolumeIcon.icns` and clear
  the custom-icon bit. The volume icon is installed *after* the layout step for that
  reason; on the shipped read-only image Finder can no longer touch it.

Finder's **path bar** is a global user preference and covers the bottom 28 pt of any
window, including this one. Keep artwork clear of it — `dmg-background.swift`
asserts this.

## 2. Version numbers

Both come from `project.yml` and are baked into the app at build time:

| Field | Key | Meaning |
|---|---|---|
| `MARKETING_VERSION` | `CFBundleShortVersionString` | the public version, e.g. `1.1` — names the `.dmg` and the git tag |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | build number; bump on **every** uploaded build, even a rebuild of the same version |

Edit `project.yml`, then `xcodegen generate` so the change reaches the Xcode project.

## 3. Tag and publish

```bash
git commit -am "Release 1.0"
git tag -a v1.0 -m "Simple Clipboard 1.0"
git push origin main --tags
```

Then create the GitHub release, attaching `dist/Simple-Clipboard-1.0.dmg`:

```bash
gh release create v1.0 \
  "dist/Simple-Clipboard-1.0.dmg" \
  --title "Simple Clipboard 1.0" \
  --notes-file notes.md
```

`gh` is not installed here — `brew install gh && gh auth login`, or just use the web
UI: **Releases → Draft a new release**, pick the tag, drag the `.dmg` in, publish.

Include the SHA-256 (`dist/*.dmg.sha256`) in the notes so people can verify the
download, and repeat the first-launch instructions from §4 — it is the first thing
users will hit.

## 4. Gatekeeper: what users actually see

The app is **ad-hoc signed** (`CODE_SIGN_IDENTITY: "-"`) and **not notarized**, so a
downloaded copy is rejected by Gatekeeper:

```
$ spctl --assess --type execute "Simple Clipboard.app"
Simple Clipboard.app: rejected
```

On the first launch macOS refuses to open it. Since macOS Sequoia, **Control-click →
Open no longer overrides this** — the only route is:

> **System Settings → Privacy & Security**, scroll to the blocked-app notice, click
> **Open Anyway**, then confirm.

The DMG background says exactly that. The alternative, for people comfortable in a
terminal, is `xattr -dr com.apple.quarantine "/Applications/Simple Clipboard.app"`.

Two consequences worth knowing, both caused by the ad-hoc signature changing on every
build:

- **Accessibility** permission (needed only by the *Paste previous* / *Paste as plain
  text* shortcuts, §14) must be re-granted after an update.
- **Launch at login** (`SMAppService`) may need to be toggled off and on again.

### Removing the warning properly

Only notarization fixes this, and it needs a paid **Apple Developer Program**
membership ($99/yr):

1. Set `DEVELOPMENT_TEAM` in `project.yml` and change `CODE_SIGN_IDENTITY` to
   `Developer ID Application`.
2. Sign with `--options runtime` (hardened runtime is already on) and a timestamp.
3. Submit and staple:

   ```bash
   xcrun notarytool submit "dist/Simple-Clipboard-1.0.dmg" \
       --apple-id "you@example.com" --team-id "TEAMID" \
       --password "app-specific-password" --wait
   xcrun stapler staple "dist/Simple-Clipboard-1.0.dmg"
   ```

Notarize the `.dmg` **after** it is built, then staple the ticket to it, so the image
carries its own approval and works offline. Once that lands, drop the first-launch
line from `dmg-background.swift` and from both READMEs.

## 5. Checklist

- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bumped in `project.yml`
- [ ] `xcodegen generate` run and the project change committed
- [ ] `scripts/make-dmg.sh` reports the universal architectures (`x86_64 arm64`)
- [ ] Mounted the `.dmg` and confirmed the layout, then installed and launched it once
- [ ] Release notes mention the first-launch Gatekeeper step and the SHA-256
- [ ] Tag pushed and the `.dmg` attached to the GitHub release
