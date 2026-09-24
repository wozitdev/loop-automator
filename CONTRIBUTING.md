# Contributing to Loop Automator

Thanks for your interest! Loop Automator aims to be the go-to open-source
solution for visual loop automation, and contributions of all sizes are
welcome — bug reports, docs, new backends, UI polish, everything.

## Getting started

1. Install [Godot 4.7](https://godotengine.org/download) (standard build).
2. Fork + clone the repo.
3. Open the project folder in Godot and press **F5** to run.

No build step, no dependencies — it's pure GDScript.

CI exports Windows and Linux binaries for every pull request; grab them from
the workflow run's artifacts if you want to try a branch without the editor.
Releases are cut by pushing a `vX.Y.Z` tag — see the
[README](README.md#releases).

## Project layout

See the [README](README.md#project-layout) for a map of the codebase. The
short version:

- `scripts/model/` — pure data classes (`LoopProject` → `LoopLayer` → `LoopAction`) with JSON (de)serialization.
- `scripts/autoload/` — app state (`ProjectData`) and the loop runner (`Playback`).
- `scripts/input/` — pluggable `InputBackend` implementations.
- `scripts/main.gd` — the builder GUI (built in code, no scene editing needed).
- `scripts/overlay*.gd` — the transparent, click-through overlay window.

## What we'd love help with

- **Native input backends** — a GDExtension implementing the `InputBackend`
  API for fast, robust input on Windows / Linux / macOS is the single most
  impactful contribution. The interface is small; nothing else needs to change.
- **New action types** (OCR, text detect, conditionals beyond Wait / Skip).
- **Cross-platform testing** of the overlay window behaviour.
- **Docs and examples** — share `.loop` files in `examples/`.

## Guidelines

- Keep PRs focused: one feature or fix per PR.
- Match the existing GDScript style (typed GDScript, `snake_case`, docstring
  comments on classes).
- Backends must implement the full `InputBackend` interface and never touch
  the OS unless explicitly selected by the user.
- The **Preview backend must stay 100% safe** — it may never send real input.
- Test with the Preview backend first; note in the PR if you tested real input.

## Reporting bugs

Open an issue with:
- Godot version, OS, and backend used,
- steps to reproduce (a minimal `.loop` file helps a lot),
- what you expected vs. what happened.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
