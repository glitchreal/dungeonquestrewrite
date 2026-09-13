# Project Workflow

- This repository is the source of truth for Dungeon Quest Obsidian work.
- Keep the repository limited to the Obsidian hub, its loader, source, generated
  runtime bundles, and project documentation. Do not add unrelated local files.
- Make future changes here, commit them, and push to rewrite (glitchreal/dungeonquestrewrite).
- After editing runtime source, run `lua build.lua` and include both generated
  bundles in the same commit.
- The user does not want extra test runs solely for committing. Do not add a
  pre-commit test gate. Use focused verification only when the implementation
  change itself warrants it.
- Preserve level checks, target-facing behavior, and settings continuation
  through the main loader after teleporting. Dodge teleports stay tactical
  (8 studs max per blink, budgeted per rolling window) — never large snaps,
  which trip the game's movement anticheat.
