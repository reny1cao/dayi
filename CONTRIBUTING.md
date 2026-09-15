# Contributing to Dayi

The project is preparing its first public preview. Project-owned code is under the MIT License (see `LICENSE`); contributions are accepted under the same terms. Please discuss substantial contributions with the maintainer first.

- Read `AGENTS.md`, `docs/requirements.md`, and the relevant verification notes.
- Keep changes focused. Preserve captured targets, UTF-16 boundaries, read-back verification, and conflict-aware undo.
- Use synthetic, unsent drafts in tests. Do not commit API keys, personal history, model configuration exports, databases, `outputs/`, or `work/`.
- Run `swift test` and `zsh scripts/package-app.sh`, then verify the app bundle signature and resources. Explain which real applications were exercised and which remain unverified.
- Include the trigger, expected behavior, actual behavior, macOS/Dayi version, and minimal reproduction in bug reports. Screenshots should be redacted.
- Describe validation in pull requests. A successful mock-host test is not evidence that a named browser or desktop client works.

Current areas needing acceptance include real rich-text editors, minimum macOS support, browser hotkey-to-icon flow, and clean-machine installation. Prompt redesign remains a separate discussion.
