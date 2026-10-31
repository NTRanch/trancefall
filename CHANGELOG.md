# Changelog — Trancefall

All notable changes, newest first. Format: Keep a Changelog.

## [1.0.0] — 2026-10-30

First playable release: the full W1 mechanism group, built and gated in
the sandbox under the Owner's v1.0 jam directive.

- **Face-state performance core** (Zig, wasm32-freestanding): the F-code
  set as continuous parameter keyframes (rest, F-03 edge, F-05 peak,
  F-10 daze) with a total comptime transition timing table — posture
  (head sink/tilt, shoulder slump) and expression interpolate together,
  and multi-state paths route through the intermediate keyframes.
- **Induction descent gameplay**: counted-exhale beat judging (±280 ms
  windows) across three levels — First Descent, Down Easy, Trandeep —
  with drift, time limits, culmination on the final counted exhale, and
  a daze settle into victory.
- **Weather coupling**: rain, wind, stars and ambient motes are a pure
  function of depth + face state; the room quiets as she deepens.
- **Revelation glyph**: the suggestion sigil moves Hinted → Glimpsed as
  depth crosses the revelation band.
- **Screens**: 18+ gate, title with level picker, how-to, gameplay,
  pause, settings (weather density, text size), victory, game over.
- **Persistence**: settings and per-level best depth/completion persist
  in the shell (localStorage) and restore into the core at boot; safety
  and accessibility options are reachable before any play.
- **Audio**: generated WebAudio cues answering player input only;
  nothing autoplays.
- **Previews**: `docs/previews/level-{1,2,3}-trancefall.mp4`, rendered
  from the shipped core in demo mode.
- **Gates**: 12 core tests (validation + adversarial), settings-bridge
  check, performance budget (0.048 ms/step, 24.7 KB wasm), scripted
  playtest completing all three levels.

## [0.1.0] — 2026-10-30

- Repo scaffolded 2026-10-30: bloch roadmap (kind=game, lane=restricted),
  planning, per-game skill, baseline Zig config, NTRanch-themed mdBook,
  brand assets (header + icon).
