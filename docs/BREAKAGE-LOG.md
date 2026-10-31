# Breakage log — Trancefall

Every breakage found in playtest or build lands here with: what broke, the
evidence, the bloch attempt id, and the fix or the filed finding. Copied to
bloch at the week's close (the log is the input, bloch is the record).

## 2026-10-30 — v1.0 build (sandbox)

- **B-1: Level 3 could not culminate.** Playtest: demo policy hovered at
  depth 0.99 for the full 6-minute limit. Cause: target_depth 1.00 with
  drift applied between the final counted beat and the cycle-end check —
  the clamp at 1.00 wastes the last beat's gain, so depth at the check
  was structurally < 1.00. Fix: L3 target 0.97 (the check now sits inside
  what a perfect cycle can hold). Playtest green on all three levels.
- **B-2: Preview text rendered vertically mirrored.** D-221 frame
  inspection of the first captures: every string upside down. Cause: the
  shared draw-list rasteriser's 5×7 font is column-major with bit 0 =
  bottom row; the rasteriser drew bit 0 at the top. Fix in the program's
  shared `tools/raster.mjs` (bit b → row 6−b); all three previews
  re-captured and re-inspected PASS. The shipped page was never affected
  (canvas uses native text).
- **B-3 (held, not a defect): seahawk playtest pass not run.** Primo is
  unreachable from the sandbox tonight (tunnel outage since 03:15 PDT).
  The sandbox automated playtest (`docs/PLAYTEST-2026-10-30.md`) is the
  record of the moment; the seahawk pass runs when primo returns.
  R-905's verify names the sandbox playtest for this reason.
- **B-4 (held, by design of the jam): GJ-07 live itch checks open.**
  The 18+ flag / content-warning / ToS verification happens live at
  entry time; the entry is not being submitted tonight. R-904 stays
  open. The game's own 18+ gate ships as the first screen regardless.
- **B-5 (design ruling): no mid-run save.** A descent is one sitting.
  What persists (shell localStorage): settings + per-level best
  depth/completion. R-202/R-203 are gated on that bridge
  (`tools/settings-check.mjs`), and the scoping is recorded here rather
  than silently narrowing the items.
- **B-6: menu/end-screen text clipped in the raster (post-tag fix).**
  An estate-wide raster-advance audit (run during the Exposure build)
  measured every screen's text against the preview rasteriser's font
  advance (unit = round(size/14); the advance doubles at size >= 21):
  the title subtitle and level line, the how-to lines, both end
  titles, and the play HUD clock all ran past the right edge in the
  rendered surface. The browser's real font fits them; the preview
  videos are the deliverable that clips. Fix: those lines set at
  size 20 (end titles 40), audit now CLEAN on all screens, previews
  re-captured. Landed as a fix commit on top of v1.0.0 before any
  push; the tag moves with it.
