# Port-Back — Trancefall

Filed 2026-10-30 at the v1.0 build. The full filing lives in
`docs/PORT-BACK.md`; this chapter carries the verdict and the numbers.

- **Verdict:** plays. The face machinery performs: posture and
  expression move as one interpolated parameter set, the counted-exhale
  grammar carries a full descent in all three levels, and weather reads
  as the same system as the face because it is a pure function of it.
- **Numbers:** transition timing table — descent 900 ms/state step,
  recovery 500 ms/state step, multi-state paths via intermediate
  keyframes, smoothstep easing. Beat grammar — inhale 2.4 s, hold
  1.1 s, counted exhale (4/5/6 beats at 1000/900/820 ms), settle 1.6 s,
  judge window ±280 ms. Revelation ramp — clamp((depth − 0.30)/0.55),
  Glimpsed at ≥ 0.75. Performance — 0.048 ms/step, wasm 24,726 bytes.
- **Language verdict (Zig):** comptime tables over hand-written state
  machines, decisively: totality by construction, testable as data.
  The bounded draw-list writer made the wasm boundary boring. Costs
  were trivial (one keyword collision, strict integer division).
- **Breakage:** `docs/BREAKAGE-LOG.md` B-1…B-5 (two fixed, three
  filed as held/ruling).
- **§9 transfer filing:** items 1–5 of `docs/PORT-BACK.md` (transition
  table, keyframe shape, weather coupling, beat grammar, revelation
  ramp) are SFW-labelled technique and may transfer to the SFW lane.
  The game's NSFW-pure design content stays in this lane.
