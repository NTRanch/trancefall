# Planning — Trancefall

- **Program:** Torogao Jam Program (D-333), week 1 of 14, Wave A — Animation
- **Cast:** Prima
- **Language:** Zig (tiger-style-zig)
- **Canon core:** The F-code face set, in her induction room.

## Mechanism group (D-334: primary + coupled + persistence/revelation + feel)

- Face-state transitions (F-03 edge, F-05 peak, F-10 daze, and the paths between them)
- An induction descent beat in the Down Easy shape (culmination on a counted exhale)
- Weather coupling — her Trance-Deep weather visibly deepens as her face state does
- Revelation: hypnosis moves Hinted → Glimpsed through play
- Ambient life — the room quiets as she does

## Validates

The face machinery as performance (the Séraphine standard: posture AND expression visibly change), and whether weather and face read as one system or two pasted together.

## Port-back

Transition timing table for the torogao rig runtime; weather-coupling notes; Zig verdict (comptime tables vs hand-written state machines).

## Delivery

Compile to wasm32, inline the module (base64) in the single index.html; JS is loader and DOM bridge only. Toolchain home: sandbox.

## Open preflight items

- GJ-06-class start gate for this week's toolchain (later weeks gate their
  own preflight; only W1's gate covers the program start).
- GJ-07: 18+ flag, content warnings listed, itch ToS screen — verified live
  at entry (the NSFW allowance clause is Owner-reported; re-verify on page).
- Engine-research chapter in the book: confirm the pinned library versions
  before the first build commit.
