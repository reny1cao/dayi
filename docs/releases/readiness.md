# First public preview: release readiness

Assessment date: 2026-09-11. Proposed tag: **v0.2.4-preview.1** (app 0.2.4, build 7). This is release preparation, not approval to publish third-party material or expose the private repository.

## Platform decision

**Use GitHub Releases first**, in the existing private `reny1cao/dayi` repository as a draft. A release binds version notes and downloadable assets to a source commit, alongside issues and pull requests. Prepare a ZIP and SHA-256 checksums; keep the draft unpublished until all assets and gates are verified. GitHub recommends drafting first when release immutability is enabled. Immutability can be considered before the first public publication; it has not been enabled by this task.

The Mac App Store requires App Sandbox. Apple's documentation lists Accessibility APIs in assistive apps among incompatible functionality. Dayi currently uses those APIs and cross-application paste, so an App Store launch would require a separate compatibility/design effort. A Homebrew Cask is a later convenience once public, stable download URLs and notarized artifacts exist. Product Hunt or other launch sites are discovery channels, not the initial binary/source host. No automatic updater is being added for the first preview.

Sources: [GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository), [immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases), [Apple Sandbox constraints](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

## Skills and best practices

| Capability | Required deliverable / practice | Approach here |
|---|---|---|
| macOS asset packaging | Exact original artwork, 16–1024 iconset, .icns, Info.plist binding, template menu-bar mark | System sips/iconutil; no logo regeneration |
| Swift/AppKit release engineering | Pin toolchain expectations; validate code, package resources, and actual clients separately | Swift tests, app bundle checks; macOS GitHub Actions with read-only permissions |
| Signing and notarization | Developer ID, hardened runtime, notarytool submission, ticket stapling, clean-machine Gatekeeper check | Signed local preview; notarization credentials not configured for this task |
| License/provenance review | Owner-selected license, preserved dependency notices, rights to bundled assets and prompt, history review | MIT adopted; notices added; public release still blocked on brand-asset review and the fresh public history |
| Product documentation | Honest features/limits, installation, API-key setup, data flow and retention | Rewritten README plus contribution/security/issue templates |
| Release management | Commit-bound artifact, architecture/version labels, checksums, draft release, no secrets in CI | Preview manifest and packaging receipt; no automatic public publication |

The installed **find-skills** skill was used to search the skill directory. Community candidates were checked rather than blindly installed:

- [jamesrochabrun/skills — releasing-macos-apps](https://skills.sh/jamesrochabrun/skills/releasing-macos-apps): observed 192 installs, 208 repository stars, MIT, repository last pushed 2026-01-14. Covers notarization, GitHub, DMG and Sparkle. Its adoption is modest and its Sparkle/DMG scope exceeds this preview. Optional reference only, not installed or treated as release authority. The directory showed mixed automated audit results, so no security endorsement is made. Installation, if explicitly chosen later: `npx skills add jamesrochabrun/skills --skill releasing-macos-apps`.
- `fayazara/macos-app-skills — macos-release`: observed 407 installs and 665 stars; last pushed 2026-05-27. GitHub did not report a repository license in this inspection. Not installed or copied.

No new skill installation is necessary for the current work: Apple/GitHub documentation and existing CLI tools cover the required steps. Popularity counts are a dated discovery signal, not a correctness or safety guarantee.

Sources: [Apple Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [open-source launch checklist](https://opensource.guide/starting-a-project/).

## Public-release gates

| Gate | Current evidence / remaining work |
|---|---|
| Brand selected | Supplied PNG copied unchanged; original hash recorded in Assets/README.md; .icns generated; README dark variant from matching R6 source |
| Project license | Cleared 2026-09-15: MIT adopted for project-owned code in `LICENSE`. README, CONTRIBUTING, SECURITY and notices updated. |
| Default prompt rights | Current bundled template replaced with newly written `dayi-default-1`; old extracted resource and boundary-quote stripping removed. Private provenance archive retained. Old Git history still contains retired material; this replacement does not clear that history for public distribution. See docs/default-prompt.md. |
| Other notices | GRDB and CC Switch MIT notices included. Provider marks and Dayi artwork still need final redistribution/brand-policy review. |
| Repository visibility/history | Remains private. Making the current repository public exposes history as well as HEAD; the retired template is present in two commits (2d48977 import, 3cf52d7 removal). Done 2026-09-15: the private repository was renamed `reny1cao/dayi-private`, and the public `reny1cao/dayi` was created from the squashed `public-history` branch (checked for retired material). Draft releases go on the public repository. |
| Signing | Existing local Developer ID identity is available; packaging enforces hardened runtime and verifies the signature. Signing alone is not notarization. |
| Notarization | **Blocked.** Current bundle has no stapled ticket; no notarization profile was supplied or configured in this task. No credentials were extracted from another project. |
| Supported devices | arm64 preview; deployment target macOS 14, local checks on macOS 26. Intel and minimum-macOS acceptance are outstanding. |
| UI/client acceptance | See docs/status.md: model configuration and core flows exercised; real browser hotkey-to-new-icon and complex rich text remain unaccepted. |
| CI | Workflow for macos-26 / Xcode 26.6 (documented hosted image). Since 2026-09-15 it runs on the public repository `reny1cao/dayi` only: macOS minutes on the private repository hit the account's Actions budget, so Actions is disabled there. The public run on the synced commit is the recorded validation. CI ad-hoc bundles are never uploaded as release assets. |
| Automatic updates | Sparkle 2.10.0 embedded from build 9 (2026-09-15): feed `https://reny1cao.github.io/dayi/appcast.xml` on GitHub Pages, EdDSA public key in Info.plist, private key only in the owner's login keychain, system profiling off. Appcast entries are added per release by `scripts/update-appcast.sh`. |
| Final public publication | Source is public. A public binary still requires the notarization gate and brand-asset review, then an explicit owner publication decision. |

[Current runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) was checked before choosing Xcode 26.6. Pinned third-party Actions use verified upstream commit references. The workflow has no deployment credentials, no pull_request_target trigger, and no publish step.
