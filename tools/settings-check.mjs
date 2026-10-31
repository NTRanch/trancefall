// settings-check.mjs — gates R-202/R-203/R-403: the settings bridge
// round-trips, and the settings screen is reachable from boot with no
// progression (safety/accessibility options are never gated).
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createGame, INPUT } from "../web/game.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmBytes = readFileSync(join(root, "zig-out/bin/trancefall.wasm"));
const game = await createGame(wasmBytes, { seed: 7, level: 0, demo: false });

function steps(n, bits = 0) { for (let i = 0; i < n; i++) game.step(bits); }
function fail(msg) { console.error(`settings-check: ${msg}`); process.exit(1); }

if (game.screen() !== 0) fail("boot screen is not the 18+ gate");
game.applySettings(true, false);
if (game.settingsBits() !== 1) fail("apply_settings(weather_reduced) did not round-trip");
game.applySettings(false, true);
if (game.settingsBits() !== 2) fail("apply_settings(text_large) did not round-trip");
game.applySettings(true, true);

// Navigate gate -> title -> settings with plain input, no play first.
steps(1, INPUT.confirm);
if (game.screen() !== 1) fail("confirm did not leave the gate");
steps(1, INPUT.down); steps(1, INPUT.down);
steps(1, INPUT.confirm);
if (game.screen() !== 5) fail(`settings not reachable from title (screen=${game.screen()})`);
steps(2);
if (!game.frameText().includes("REDUCED")) fail("settings screen does not show restored REDUCED weather");
if (!game.frameText().includes("LARGE")) fail("settings screen does not show restored LARGE text");
console.log("settings-check: bridge round-trips; settings reachable ungated; restored values render");
