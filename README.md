# Trancefall

**Nice Thoughts Ranch** · Torogao Jam Program week 1 (Wave A — Animation) · Prima · **Zig**

The F-code face set, in her induction room.

An 18+ game built for the weekly Gameotron jam on itch.io (NTRanch), as one
rung of the 14-week Torogao system-validation program (D-333/D-334/D-335/D-336).
The full planning book lives in [`book/`](book/) (mdBook, NTRanch theme);
this repo's bloch roadmap is [`.ai/roadmap.md`](.ai/roadmap.md).

- **Delivery:** one self-contained `index.html` (see `docs` in the book).
- **Cast/art law (D-292):** existing keeper art only; a missing asset is an
  abstract stand-in, logged — never a generation job.
- **Quality bar:** Laplace3D-class animation or the medium's equivalent
  (book chapter: Quality Bar).
- **Audio:** nothing is ever played aloud by an agent; the Owner presses play.

## Play

Open [`web/index.html`](web/index.html) in a browser — it runs fully
offline. She breathes in, she holds, and on the exhale she counts: tap
(click or SPACE) on each count beat to walk her deeper. Her face moves
through the F-code states as the room's weather deepens with her.

- **Level 1 — First Descent:** learn the count (4 beats, target 60%).
- **Level 2 — Down Easy:** the full descent (5 beats, target 85%),
  culmination on the counted exhale.
- **Level 3 — Trandeep:** faster counts, heavier weather (6 beats,
  target 97%).

Settings (weather density, text size) and your best depth per level
persist in the browser. Settings are reachable before any play.

## Preview videos (rendered from the shipped core, demo mode)

- [Level 1 — First Descent](docs/previews/level-1-trancefall.mp4)
- [Level 2 — Down Easy](docs/previews/level-2-trancefall.mp4)
- [Level 3 — Trandeep](docs/previews/level-3-trancefall.mp4)

## Build & verify

```sh
just build   # zig build + assemble web/index.html
just check   # fmt, 12 core tests, settings bridge, perf budget, playtest
just previews
```

Status: **v1.0.0** (2026-10-30) — playable, gated, tagged. The seahawk
playtest pass on primo and the live itch.io entry checks (GJ-07) remain
scheduled follow-ups; both are recorded in `docs/BREAKAGE-LOG.md`.
