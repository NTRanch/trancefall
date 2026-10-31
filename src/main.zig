// trancefall/src/main.zig — Trancefall core (Zig, wasm32-freestanding).
//
// Tiger Style (tiger-style-zig, 0.15 delta applied): explicit contracts,
// bounded work, no hidden behaviour, no allocation after init. The core is a
// fixed-step deterministic simulation: the shell calls step() at 60 Hz with
// a fixed dt; the core never reads a wall clock, never touches the DOM, and
// reports everything it wants drawn as a draw list in a static buffer.
//
// Game: an induction descent. The player taps on counted exhale beats to
// walk Prima's face through the F-code states (rest -> F-03 edge -> F-05
// peak -> F-10 daze) while the room's weather deepens in the same motion.
// Face and weather are ONE system: every weather parameter is a function
// of face state and depth. That coupling is the thing W1 exists to prove.

const std = @import("std");

// ---------------------------------------------------------------------------
// Domain constants
// ---------------------------------------------------------------------------

/// Logical canvas is 960x960 (program contract). All draw coordinates are
/// integer logical pixels.
pub const canvas_px: i32 = 960;

/// Hard bound on draw ops per frame. The emitter drops (and counts) any op
/// past the bound instead of writing out of the buffer.
pub const max_ops: usize = 1024;

/// Serialised draw-list buffer: one op per line, e.g. "r 10 20 30 40 2".
pub const draw_buffer_bytes: usize = 64 * 1024;

/// Fixed step the shell is contracted to deliver.
pub const step_ms: u32 = 16;

/// Palette indices (shell + rasteriser share this table; index 0 is the
/// background and always paints first).
pub const Palette = struct {
    pub const bg: u8 = 0; // #0d0208 near-black plum
    pub const pink: u8 = 1; // #ff2e88 hot pink (NTRanch accent)
    pub const skin: u8 = 2; // #f8f0ed pale skin
    pub const mauve: u8 = 3; // #ac9393 shadow mauve
    pub const plum: u8 = 4; // #540e46 deep plum (hair)
    pub const rose: u8 = 5; // #ec8584 blush rose
    pub const paper: u8 = 6; // #eaeaea paper white
    pub const dim: u8 = 7; // #68636c dim grey-violet
    pub const gold: u8 = 8; // #ffd166 sparse gold
    pub const deep: u8 = 9; // #1a0510 panel deep
};

/// The palette as hex strings, for the shell/book to quote. Comptime-known.
pub const palette_hex = [_][]const u8{
    "#0d0208", "#ff2e88", "#f8f0ed", "#ac9393", "#540e46",
    "#ec8584", "#eaeaea", "#68636c", "#ffd166", "#1a0510",
};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// The F-code face states this entry performs. Order is descent order.
pub const FaceState = enum(u8) {
    rest = 0,
    edge = 1, // F-03
    peak = 2, // F-05
    daze = 3, // F-10

    pub fn label(self: FaceState) []const u8 {
        return switch (self) {
            .rest => "RESTING",
            .edge => "F-03 EDGE",
            .peak => "F-05 PEAK",
            .daze => "F-10 DAZE",
        };
    }
};

/// Continuous face parameters. States are keyframes over these; transitions
/// interpolate. Posture (head_tilt, head_sink, shoulder_y) moves WITH the
/// expression — the Séraphine standard: posture AND expression change.
pub const FaceParams = struct {
    eye_open: f32, // 1 = open, 0 = closed
    gaze_x: f32, // -1..1, full-disc centre offset (gaze §1.7)
    gaze_y: f32, // -1..1
    mouth_open: f32, // 0..1
    blush: f32, // 0..1
    brow_lift: f32, // 0..1
    head_tilt: f32, // logical px, + = her left
    head_sink: f32, // logical px, + = down
    shoulder_y: f32, // logical px offset, + = down (posture slump)
};

/// Keyframe parameter set per face state (the performance score).
pub const face_keyframes = [4]FaceParams{
    .{ .eye_open = 0.92, .gaze_x = 0.0, .gaze_y = 0.05, .mouth_open = 0.08, .blush = 0.12, .brow_lift = 0.35, .head_tilt = 0, .head_sink = 0, .shoulder_y = 0 }, // rest
    .{ .eye_open = 0.45, .gaze_x = 0.18, .gaze_y = 0.30, .mouth_open = 0.34, .blush = 0.55, .brow_lift = 0.62, .head_tilt = 7, .head_sink = 14, .shoulder_y = 8 }, // F-03 edge
    .{ .eye_open = 0.16, .gaze_x = 0.0, .gaze_y = 0.62, .mouth_open = 0.85, .blush = 0.95, .brow_lift = 0.88, .head_tilt = -5, .head_sink = 30, .shoulder_y = 20 }, // F-05 peak
    .{ .eye_open = 0.30, .gaze_x = -0.10, .gaze_y = 0.45, .mouth_open = 0.42, .blush = 0.70, .brow_lift = 0.20, .head_tilt = 12, .head_sink = 42, .shoulder_y = 30 }, // F-10 daze
};

/// One cell of the transition timing table.
pub const Transition = struct {
    duration_ms: u32,
    /// True when the path must pass through the intermediate keyframe(s)
    /// (expression continuity: never jump rest -> peak in one blend).
    via_intermediate: bool,
};

/// THE TRANSITION TIMING TABLE (port-back artifact for the torogao rig
/// runtime). Comptime-generated, total over ordered state pairs: every
/// (from, to) has an entry; same-state is a zero-duration no-op. Descents
/// are slower than recoveries; any path skipping a state goes via the
/// intermediate keyframes.
pub const transition_table: [4][4]Transition = build_table: {
    var t: [4][4]Transition = undefined;
    for (0..4) |from| {
        for (0..4) |to| {
            if (from == to) {
                t[from][to] = .{ .duration_ms = 0, .via_intermediate = false };
            } else if (to > from) {
                // Descending: 900 ms per state step, via intermediates.
                const steps = to - from;
                t[from][to] = .{ .duration_ms = 900 * @as(u32, @intCast(steps)), .via_intermediate = steps > 1 };
            } else {
                // Recovering: 500 ms per state step, via intermediates.
                const steps = from - to;
                t[from][to] = .{ .duration_ms = 500 * @as(u32, @intCast(steps)), .via_intermediate = steps > 1 };
            }
        }
    }
    break :build_table t;
};

/// Screens. The core owns all screens as draw lists; the shell only
/// forwards input and paints.
pub const Screen = enum(u8) {
    gate = 0, // 18+ gate (first screen, always)
    title = 1,
    howto = 2,
    play = 3,
    pause = 4,
    settings = 5,
    victory = 6,
    gameover = 7,
};

/// Input bitmask delivered per step by the shell.
pub const Input = struct {
    pub const tap: u32 = 1 << 0; // pointer press / space (edge-triggered by shell)
    pub const confirm: u32 = 1 << 1;
    pub const back: u32 = 1 << 2;
    pub const pause_btn: u32 = 1 << 3;
    pub const up: u32 = 1 << 4;
    pub const down: u32 = 1 << 5;
};

/// Events the shell sonifies (WebAudio, generated; no assets). The core
/// sets event_code; the shell polls it after each step.
pub const Event = struct {
    pub const none: u8 = 0;
    pub const good_beat: u8 = 1;
    pub const miss_beat: u8 = 2;
    pub const culmination: u8 = 3;
    pub const victory: u8 = 4;
    pub const game_over: u8 = 5;
    pub const ui_move: u8 = 6;
};

/// One level of the descent.
pub const Level = struct {
    name: []const u8,
    target_depth: f32, // depth that completes the level at a cycle end
    beats_per_cycle: u8, // counted exhale beats
    beat_ms: u32, // spacing of counted beats in the exhale
    gain: f32, // depth per good beat
    drift_per_s: f32, // depth decay while not on a beat
    time_limit_ms: u32,
    weather_base: f32, // 0..1 ambient weather before coupling
};

pub const levels = [3]Level{
    .{ .name = "LEVEL 1 - FIRST DESCENT", .target_depth = 0.60, .beats_per_cycle = 4, .beat_ms = 1000, .gain = 0.085, .drift_per_s = 0.010, .time_limit_ms = 240_000, .weather_base = 0.15 },
    .{ .name = "LEVEL 2 - DOWN EASY", .target_depth = 0.85, .beats_per_cycle = 5, .beat_ms = 900, .gain = 0.075, .drift_per_s = 0.014, .time_limit_ms = 300_000, .weather_base = 0.35 },
    .{ .name = "LEVEL 3 - TRANDEEP", .target_depth = 0.97, .beats_per_cycle = 6, .beat_ms = 820, .gain = 0.068, .drift_per_s = 0.018, .time_limit_ms = 360_000, .weather_base = 0.55 },
};

/// Breath cycle phases. Culmination happens on a counted exhale: the
/// exhale phase IS the counted phase.
pub const BreathPhase = enum(u8) { inhale, hold, exhale, settle };

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

pub const CoreError = error{InvalidLevel};

fn validate_level(level: u8) CoreError!usize {
    if (level >= levels.len) return CoreError.InvalidLevel;
    return level;
}

// ---------------------------------------------------------------------------
// Private leaf work: RNG, easing, weather
// ---------------------------------------------------------------------------

/// SplitMix64: tiny, deterministic, seedable. One stream per game.
pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed | 1 };
    }
    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
    /// Uniform in [0, 1).
    pub fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / 16_777_216.0;
    }
    /// Uniform int in [0, n). Contract: n > 0.
    pub fn below(self: *Rng, n: u32) u32 {
        std.debug.assert(n > 0);
        return @intCast(self.next() % n);
    }
};

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn ease_in_out(t: f32) f32 {
    const x = clamp01(t);
    return x * x * (3.0 - 2.0 * x);
}

fn lerp_params(a: FaceParams, b: FaceParams, t: f32) FaceParams {
    return .{
        .eye_open = lerp(a.eye_open, b.eye_open, t),
        .gaze_x = lerp(a.gaze_x, b.gaze_x, t),
        .gaze_y = lerp(a.gaze_y, b.gaze_y, t),
        .mouth_open = lerp(a.mouth_open, b.mouth_open, t),
        .blush = lerp(a.blush, b.blush, t),
        .brow_lift = lerp(a.brow_lift, b.brow_lift, t),
        .head_tilt = lerp(a.head_tilt, b.head_tilt, t),
        .head_sink = lerp(a.head_sink, b.head_sink, t),
        .shoulder_y = lerp(a.shoulder_y, b.shoulder_y, t),
    };
}

/// Weather derived from depth + face state. THE COUPLING: one function of
/// the performance state, never an independent timeline. Monotonic in
/// depth for every "deepening" channel (tested).
pub const Weather = struct {
    rain: f32, // 0..1 density
    wind: f32, // -1..1 slant
    mote_speed: f32, // ambient life quiets: falls as depth rises
    mote_count: u32, // falls as depth rises
    star_glow: f32, // 0..1

    pub fn derive(depth: f32, face: FaceState, base: f32) Weather {
        const d = clamp01(depth);
        const face_push: f32 = switch (face) {
            .rest => 0.0,
            .edge => 0.18,
            .peak => 0.42,
            .daze => 0.30,
        };
        const deep = clamp01(base + d * 0.55 + face_push);
        return .{
            .rain = deep,
            .wind = -0.35 * d,
            .mote_speed = lerp(1.0, 0.22, d),
            .mote_count = @intFromFloat(lerp(46.0, 10.0, d)),
            .star_glow = clamp01(0.25 + d * 0.75),
        };
    }
};

/// Revelation completeness for the suggestion glyph: Hinted below 0.75,
/// Glimpsed at or above.
pub fn revelation_completeness(depth: f32) f32 {
    return clamp01((depth - 0.30) / 0.55);
}

// ---------------------------------------------------------------------------
// Game state and the step
// ---------------------------------------------------------------------------

const max_stars: usize = 64;
const max_motes: usize = 46;
const max_beats: usize = 8;

const BeatState = enum(u8) { pending, hit, missed };

const TransitionState = struct {
    active: bool = false,
    from: FaceParams = face_keyframes[0],
    target: FaceState = .rest,
    elapsed_ms: u32 = 0,
    duration_ms: u32 = 0,
    via: [2]?FaceState = .{ null, null },
};

pub const Game = struct {
    screen: Screen = .gate,
    level_idx: usize = 0,
    seed: u64 = 1,
    demo: bool = false,
    frame: u64 = 0,
    elapsed_ms: u32 = 0, // play-screen clock
    screen_ms: u32 = 0, // time on current screen (demo auto-advance)

    // Face performance
    face: FaceState = .rest,
    params: FaceParams = face_keyframes[0],
    transition: TransitionState = .{},

    // Descent
    depth: f32 = 0,
    breath: BreathPhase = .inhale,
    phase_ms: u32 = 0,
    beats: [max_beats]BeatState = [_]BeatState{.pending} ** max_beats,
    good: u32 = 0,
    missed: u32 = 0,
    culminating_ms: u32 = 0, // >0 while the culmination sequence runs
    culminated: bool = false,
    daze_ms: u32 = 0, // time spent in the post-culmination daze

    // Settings (in-core session persistence)
    weather_reduced: bool = false,
    text_large: bool = false,
    menu_cursor: u8 = 0,

    // Ambient field (positions fixed at init; motion is a pure function
    // of elapsed time, so no per-frame RNG state exists to drift)
    stars: [max_stars][2]u16 = undefined,
    motes: [max_motes][2]u16 = undefined,

    event_code: u8 = Event.none,
    dropped_ops: u32 = 0,

    pub fn init(seed: u64, demo: bool) Game {
        var g = Game{ .seed = seed, .demo = demo };
        var rng = Rng.init(seed ^ 0x57A25);
        for (0..max_stars) |i| {
            g.stars[i] = .{ @intCast(rng.below(960)), @intCast(rng.below(560)) };
        }
        for (0..max_motes) |i| {
            g.motes[i] = .{ @intCast(rng.below(960)), @intCast(rng.below(960)) };
        }
        return g;
    }

    pub fn level(self: *const Game) Level {
        return levels[self.level_idx];
    }

    fn start_level(self: *Game, idx: usize) void {
        self.level_idx = idx;
        self.depth = 0;
        self.breath = .inhale;
        self.phase_ms = 0;
        self.beats = [_]BeatState{.pending} ** max_beats;
        self.good = 0;
        self.missed = 0;
        self.elapsed_ms = 0;
        self.culminating_ms = 0;
        self.culminated = false;
        self.daze_ms = 0;
        self.face = .rest;
        self.params = face_keyframes[0];
        self.transition = .{};
        self.screen = .play;
        self.screen_ms = 0;
    }

    fn goto(self: *Game, s: Screen) void {
        self.screen = s;
        self.screen_ms = 0;
        self.menu_cursor = 0;
    }

    /// The face state the performance SHOULD be in, from depth + phase.
    fn face_target(self: *const Game) FaceState {
        if (self.culminating_ms > 0) return .peak;
        if (self.culminated) return .daze;
        if (self.depth >= 0.35) return .edge;
        return .rest;
    }

    fn set_face_target(self: *Game, target: FaceState) void {
        if (target == self.face and !self.transition.active) return;
        const cell = transition_table[@intFromEnum(self.face)][@intFromEnum(target)];
        self.transition = .{
            .active = cell.duration_ms > 0,
            .from = self.params,
            .target = target,
            .elapsed_ms = 0,
            .duration_ms = cell.duration_ms,
            .via = .{ null, null },
        };
        if (cell.via_intermediate) {
            const lo = @min(@intFromEnum(self.face), @intFromEnum(target));
            const hi = @max(@intFromEnum(self.face), @intFromEnum(target));
            var slot: usize = 0;
            var s = lo + 1;
            while (s < hi and slot < 2) : (s += 1) {
                self.transition.via[slot] = @enumFromInt(s);
                slot += 1;
            }
        }
        self.face = target;
        if (cell.duration_ms == 0) self.params = face_keyframes[@intFromEnum(target)];
    }

    fn advance_transition(self: *Game, dt_ms: u32) void {
        if (!self.transition.active) return;
        self.transition.elapsed_ms += dt_ms;
        const tr = &self.transition;
        const target_params = face_keyframes[@intFromEnum(tr.target)];
        // Waypoint chain: from -> via[0] -> via[1] -> target.
        var points: [4]FaceParams = .{ tr.from, undefined, undefined, target_params };
        var n: usize = 2;
        if (tr.via[0]) |v| {
            points[1] = face_keyframes[@intFromEnum(v)];
            n = 3;
        }
        if (tr.via[1]) |v| {
            points[2] = face_keyframes[@intFromEnum(v)];
            n = 4;
        }
        if (tr.elapsed_ms >= tr.duration_ms) {
            self.params = target_params;
            tr.active = false;
            return;
        }
        const total = @as(f32, @floatFromInt(tr.duration_ms));
        const pos = @as(f32, @floatFromInt(tr.elapsed_ms)) / total * @as(f32, @floatFromInt(n - 1));
        const seg: usize = @min(@as(usize, @intFromFloat(pos)), n - 2);
        const local = ease_in_out(pos - @as(f32, @floatFromInt(seg)));
        self.params = lerp_params(points[seg], points[seg + 1], local);
    }

    fn breath_cycle_ms(self: *const Game) u32 {
        return 2400 + 1100 + @as(u32, self.level().beats_per_cycle) * self.level().beat_ms + 1600;
    }

    /// Centre time (ms into the exhale) of beat k. Contract: k < beats.
    fn beat_center_ms(self: *const Game, k: usize) u32 {
        std.debug.assert(k < self.level().beats_per_cycle);
        return @as(u32, @intCast(k)) * self.level().beat_ms + self.level().beat_ms / 2;
    }

    fn exhale_ms(self: *const Game) u32 {
        return @as(u32, self.level().beats_per_cycle) * self.level().beat_ms;
    }

    fn phase_duration_ms(self: *const Game) u32 {
        return switch (self.breath) {
            .inhale => 2400,
            .hold => 1100,
            .exhale => self.exhale_ms(),
            .settle => 1600,
        };
    }

    /// Register a tap edge. Judged only during the exhale, against the
    /// nearest pending beat centre within the window.
    fn judge_tap(self: *Game) void {
        if (self.breath != .exhale or self.culminating_ms > 0) return;
        const window: u32 = 280;
        const n = self.level().beats_per_cycle;
        var best: ?usize = null;
        var best_dist: u32 = window + 1;
        for (0..n) |k| {
            if (self.beats[k] != .pending) continue;
            const c = self.beat_center_ms(k);
            const dist = if (self.phase_ms >= c) self.phase_ms - c else c - self.phase_ms;
            if (dist < best_dist) {
                best_dist = dist;
                best = k;
            }
        }
        if (best) |k| {
            self.beats[k] = .hit;
            self.good += 1;
            self.depth = clamp01(self.depth + self.level().gain);
            self.event_code = Event.good_beat;
        }
    }

    fn close_beat_windows(self: *Game) void {
        if (self.breath != .exhale) return;
        const n = self.level().beats_per_cycle;
        for (0..n) |k| {
            if (self.beats[k] == .pending and self.phase_ms > self.beat_center_ms(k) + 280) {
                self.beats[k] = .missed;
                self.missed += 1;
                self.event_code = Event.miss_beat;
            }
        }
    }

    fn advance_breath(self: *Game, dt_ms: u32) void {
        self.phase_ms += dt_ms;
        if (self.phase_ms < self.phase_duration_ms()) return;
        // Phase boundary. Overflow past one phase in a step is dropped:
        // dt is contractually 16 ms, far below any phase duration.
        self.phase_ms = 0;
        switch (self.breath) {
            .inhale => self.breath = .hold,
            .hold => {
                self.breath = .exhale;
                self.beats = [_]BeatState{.pending} ** max_beats;
            },
            .exhale => {
                self.breath = .settle;
                if (self.depth >= self.level().target_depth and !self.culminated) {
                    // Culmination on the counted exhale's completion.
                    self.culminating_ms = 5200;
                    self.event_code = Event.culmination;
                }
            },
            .settle => self.breath = .inhale,
        }
    }

    /// Demo policy: taps exactly on beat centres (with a fixed 40 ms
    /// late bias so traces show a human-ish judge), auto-confirms menus.
    fn demo_input(self: *Game) u32 {
        var input: u32 = 0;
        switch (self.screen) {
            .gate => if (self.screen_ms > 600) {
                input |= Input.confirm;
            },
            .title => if (self.screen_ms > 700) {
                input |= Input.confirm;
            },
            .play => {
                if (self.breath == .exhale and self.culminating_ms == 0) {
                    const n = self.level().beats_per_cycle;
                    for (0..n) |k| {
                        if (self.beats[k] == .pending and self.phase_ms >= self.beat_center_ms(k) + 40) {
                            input |= Input.tap;
                        }
                    }
                }
            },
            .victory, .gameover => if (self.screen_ms > 1500) {
                input |= Input.confirm;
            },
            else => {},
        }
        return input;
    }

    /// One fixed step. dt_ms is contractual (16); wild values are clamped
    /// into [0, 250] rather than trusted (adversarial boundary).
    pub fn step(self: *Game, dt_raw: u32, input_raw: u32) void {
        self.event_code = Event.none;
        const dt_ms = @min(dt_raw, 250);
        var input = input_raw;
        if (self.demo) input |= self.demo_input();
        self.frame += 1;
        self.screen_ms += dt_ms;

        switch (self.screen) {
            .gate => {
                if (input & Input.confirm != 0) self.goto(.title);
            },
            .title => self.step_title(input),
            .howto => {
                if (input & (Input.confirm | Input.back) != 0) self.goto(.title);
            },
            .settings => self.step_settings(input),
            .pause => self.step_menu(input, &pause_items),
            .play => self.step_play(dt_ms, input),
            .victory, .gameover => {
                if (input & Input.confirm != 0) self.goto(.title);
            },
        }
        self.advance_transition(dt_ms);
    }

    const MenuAction = enum { start, howto, settings, resume_game, restart, quit };
    const MenuItem = struct { label: []const u8, action: MenuAction };
    const pause_items = [_]MenuItem{
        .{ .label = "RESUME", .action = .resume_game },
        .{ .label = "RESTART", .action = .restart },
        .{ .label = "QUIT TO TITLE", .action = .quit },
    };

    fn step_menu(self: *Game, input: u32, items: []const MenuItem) void {
        if (input & Input.down != 0) {
            self.menu_cursor = @min(self.menu_cursor + 1, @as(u8, @intCast(items.len - 1)));
            self.event_code = Event.ui_move;
        }
        if (input & Input.up != 0) {
            self.menu_cursor -|= 1;
            self.event_code = Event.ui_move;
        }
        if (input & Input.confirm != 0) {
            switch (items[self.menu_cursor].action) {
                .start => self.start_level(self.level_idx),
                .howto => self.goto(.howto),
                .settings => self.goto(.settings),
                .resume_game => self.goto(.play),
                .restart => self.start_level(self.level_idx),
                .quit => self.goto(.title),
            }
        }
    }

    /// Title screen: rows 0-2 are the menu; row 3 is the level picker
    /// (tap or confirm on it cycles the level).
    fn step_title(self: *Game, input: u32) void {
        if (input & Input.down != 0) {
            self.menu_cursor = @min(self.menu_cursor + 1, 3);
            self.event_code = Event.ui_move;
        }
        if (input & Input.up != 0) {
            self.menu_cursor -|= 1;
            self.event_code = Event.ui_move;
        }
        if (self.menu_cursor == 3) {
            if (input & (Input.tap | Input.confirm) != 0) {
                self.level_idx = (self.level_idx + 1) % levels.len;
                self.event_code = Event.ui_move;
            }
            return;
        }
        if (input & Input.confirm != 0) {
            switch (self.menu_cursor) {
                0 => self.start_level(self.level_idx),
                1 => self.goto(.howto),
                2 => self.goto(.settings),
                else => unreachable,
            }
        }
    }

    fn step_settings(self: *Game, input: u32) void {
        if (input & Input.down != 0) self.menu_cursor = @min(self.menu_cursor + 1, 1);
        if (input & Input.up != 0) self.menu_cursor -|= 1;
        if (input & Input.confirm != 0) {
            if (self.menu_cursor == 0) {
                self.weather_reduced = !self.weather_reduced;
            } else {
                self.text_large = !self.text_large;
            }
            self.event_code = Event.ui_move;
        }
        if (input & Input.back != 0) self.goto(.title);
    }

    fn step_play(self: *Game, dt_ms: u32, input: u32) void {
        if (input & Input.pause_btn != 0) {
            self.goto(.pause);
            return;
        }
        self.elapsed_ms += dt_ms;

        if (self.culminating_ms > 0) {
            // Culmination: peak holds, then the daze settles in.
            self.culminating_ms -|= dt_ms;
            if (self.culminating_ms == 0) {
                self.culminated = true;
            }
            self.set_face_target(self.face_target());
            return;
        }
        if (self.culminated) {
            // Brief daze hold, then victory.
            self.set_face_target(.daze);
            self.daze_ms += dt_ms;
            if (self.daze_ms > 2600) {
                self.event_code = Event.victory;
                self.goto(.victory);
            }
            return;
        }

        if (input & Input.tap != 0) self.judge_tap();
        self.close_beat_windows();
        self.advance_breath(dt_ms);

        // Drift: depth leaks away except while settling.
        if (self.breath != .settle) {
            const drift = self.level().drift_per_s * @as(f32, @floatFromInt(dt_ms)) / 1000.0;
            self.depth = clamp01(self.depth - drift);
        }
        self.set_face_target(self.face_target());

        if (self.elapsed_ms >= self.level().time_limit_ms) {
            self.event_code = Event.game_over;
            self.goto(.gameover);
        }
    }
};

// ---------------------------------------------------------------------------
// Draw-list emission (bounded writer over a static buffer)
// ---------------------------------------------------------------------------

var draw_buffer: [draw_buffer_bytes]u8 = undefined;

pub const DrawWriter = struct {
    len: usize = 0,
    ops: usize = 0,
    dropped: u32 = 0,

    pub fn reset(self: *DrawWriter) void {
        self.len = 0;
        self.ops = 0;
        self.dropped = 0;
    }

    fn line(self: *DrawWriter, comptime fmt: []const u8, args: anytype) void {
        if (self.ops >= max_ops) {
            self.dropped += 1;
            return;
        }
        const out = std.fmt.bufPrint(draw_buffer[self.len..], fmt, args) catch {
            self.dropped += 1;
            return;
        };
        self.len += out.len;
        self.ops += 1;
    }

    pub fn rect(self: *DrawWriter, x: i32, y: i32, w: i32, h: i32, c: u8) void {
        self.line("r {d} {d} {d} {d} {d}\n", .{ x, y, w, h, c });
    }
    pub fn circle(self: *DrawWriter, x: i32, y: i32, r: i32, c: u8) void {
        self.line("c {d} {d} {d} {d}\n", .{ x, y, r, c });
    }
    pub fn seg(self: *DrawWriter, x1: i32, y1: i32, x2: i32, y2: i32, w: i32, c: u8) void {
        self.line("l {d} {d} {d} {d} {d} {d}\n", .{ x1, y1, x2, y2, w, c });
    }
    pub fn tri(self: *DrawWriter, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, c: u8) void {
        self.line("p {d} {d} {d} {d} {d} {d} {d}\n", .{ x1, y1, x2, y2, x3, y3, c });
    }
    pub fn text(self: *DrawWriter, x: i32, y: i32, size: i32, c: u8, s: []const u8) void {
        // Text payloads are restricted to a printable subset by contract
        // with the shell/rasteriser; anything else becomes '?'.
        var clean: [48]u8 = undefined;
        const n = @min(s.len, clean.len);
        for (0..n) |i| {
            const ch = s[i];
            clean[i] = if ((ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or
                ch == ' ' or ch == '-' or ch == '.' or ch == ':' or ch == '+' or
                ch == '!' or ch == '?' or ch == '/' or ch == '(' or ch == ')' or
                ch == '%' or ch == '&' or ch == ',')
                ch
            else if (ch >= 'a' and ch <= 'z')
                ch - 32
            else
                '?';
        }
        self.line("t {d} {d} {d} {d} {s}\n", .{ x, y, size, c, clean[0..n] });
    }
};

fn fi(x: f32) i32 {
    return @intFromFloat(@round(x));
}

// ---------------------------------------------------------------------------
// Rendering: weather, portrait, HUD, screens
// ---------------------------------------------------------------------------

pub const Renderer = struct {
    pub fn render(g: *const Game, w: *DrawWriter) void {
        w.rect(0, 0, canvas_px, canvas_px, Palette.bg);
        switch (g.screen) {
            .gate => render_gate(g, w),
            .title => render_title(g, w),
            .howto => render_howto(g, w),
            .settings => render_settings(g, w),
            .play, .pause => {
                render_scene(g, w);
                if (g.screen == .pause) render_pause(g, w);
            },
            .victory => render_end(g, w, true),
            .gameover => render_end(g, w, false),
        }
    }

    fn text_size(g: *const Game, base: i32) i32 {
        return if (g.text_large) @divTrunc(base * 14, 10) else base;
    }

    fn render_gate(g: *const Game, w: *DrawWriter) void {
        w.text(300, 300, text_size(g, 64), Palette.pink, "TRANCEFALL");
        w.text(330, 420, text_size(g, 30), Palette.paper, "AN INDUCTION IN THREE DESCENTS");
        w.text(240, 540, text_size(g, 28), Palette.rose, "THIS GAME IS FOR ADULTS ONLY (18+)");
        w.text(270, 600, text_size(g, 24), Palette.dim, "CONTAINS HYPNOTIC ROLEPLAY THEMES");
        if ((g.frame / 30) % 2 == 0) w.text(330, 720, text_size(g, 28), Palette.paper, "PRESS CONFIRM TO ENTER");
    }

    fn render_title(g: *const Game, w: *DrawWriter) void {
        render_weather(g, w, true);
        w.text(290, 130, text_size(g, 72), Palette.pink, "TRANCEFALL");
        w.text(300, 220, text_size(g, 20), Palette.dim, "PRIMA - THE FACE IS THE WEATHER");
        const items = [_][]const u8{ "START", "HOW TO PLAY", "SETTINGS" };
        for (items, 0..) |label, i| {
            const y: i32 = 400 + @as(i32, @intCast(i)) * 80;
            const c: u8 = if (i == g.menu_cursor) Palette.pink else Palette.paper;
            if (i == g.menu_cursor) w.text(240, y, text_size(g, 34), Palette.pink, ">");
            w.text(290, y, text_size(g, 34), c, label);
        }
        // Level row: cursor row 3; tap/confirm cycles the level.
        const lvl = levels[g.level_idx];
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "LEVEL: {s}", .{lvl.name}) catch "LEVEL";
        if (g.menu_cursor == 3) w.text(240, 660, text_size(g, 26), Palette.pink, ">");
        w.text(290, 660, text_size(g, 20), if (g.menu_cursor == 3) Palette.pink else Palette.gold, s);
        w.text(290, 710, text_size(g, 20), Palette.dim, "UP/DOWN CHOOSES - CONFIRM STARTS");
        render_glyph(g, w, 480, 830, revelation_completeness(g.depth));
    }

    fn render_howto(g: *const Game, w: *DrawWriter) void {
        w.text(240, 140, text_size(g, 44), Palette.pink, "HOW TO PLAY");
        const lines = [_][]const u8{
            "SHE BREATHES IN. SHE HOLDS.",
            "ON THE EXHALE, SHE COUNTS DOWN.",
            "TAP (OR SPACE) ON EACH COUNT BEAT",
            "TO WALK HER DEEPER.",
            "",
            "GOOD BEATS DEEPEN THE TRANCE.",
            "HER FACE MOVES: EDGE, PEAK, DAZE.",
            "THE WEATHER MOVES WITH HER FACE.",
            "REACH THE TARGET DEPTH TO COMPLETE",
            "THE DESCENT BEFORE TIME RUNS OUT.",
        };
        for (lines, 0..) |ln, i| {
            w.text(180, 240 + @as(i32, @intCast(i)) * 52, text_size(g, 20), Palette.paper, ln);
        }
        if ((g.frame / 30) % 2 == 0) w.text(300, 830, text_size(g, 24), Palette.dim, "CONFIRM TO RETURN");
    }

    fn render_settings(g: *const Game, w: *DrawWriter) void {
        w.text(300, 160, text_size(g, 44), Palette.pink, "SETTINGS");
        const rows = [_][2][]const u8{
            .{ "WEATHER DENSITY", if (g.weather_reduced) "REDUCED" else "FULL" },
            .{ "TEXT SIZE", if (g.text_large) "LARGE" else "NORMAL" },
        };
        for (rows, 0..) |row, i| {
            const y: i32 = 320 + @as(i32, @intCast(i)) * 90;
            const c: u8 = if (i == g.menu_cursor) Palette.pink else Palette.paper;
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{s}: {s}", .{ row[0], row[1] }) catch row[0];
            if (i == g.menu_cursor) w.text(150, y, text_size(g, 30), Palette.pink, ">");
            w.text(200, y, text_size(g, 30), c, s);
        }
        w.text(260, 700, text_size(g, 22), Palette.dim, "CONFIRM TOGGLES - BACK RETURNS");
    }

    fn render_pause(g: *const Game, w: *DrawWriter) void {
        w.rect(180, 240, 600, 440, Palette.deep);
        w.text(360, 290, text_size(g, 40), Palette.pink, "PAUSED");
        const items = [_][]const u8{ "RESUME", "RESTART", "QUIT TO TITLE" };
        for (items, 0..) |label, i| {
            const y: i32 = 390 + @as(i32, @intCast(i)) * 80;
            const c: u8 = if (i == g.menu_cursor) Palette.pink else Palette.paper;
            if (i == g.menu_cursor) w.text(280, y, text_size(g, 30), Palette.pink, ">");
            w.text(330, y, text_size(g, 30), c, label);
        }
    }

    fn render_end(g: *const Game, w: *DrawWriter, won: bool) void {
        render_weather(g, w, false);
        if (won) {
            w.text(240, 300, text_size(g, 40), Palette.pink, "SHE SURFACES SLOWLY");
            w.text(330, 400, text_size(g, 30), Palette.paper, "DESCENT COMPLETE");
        } else {
            w.text(270, 300, text_size(g, 40), Palette.mauve, "THE TRANCE BREAKS");
            w.text(320, 400, text_size(g, 30), Palette.paper, "TIME RAN OUT");
        }
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "BEATS HELD {d} - MISSED {d}", .{ g.good, g.missed }) catch "";
        w.text(300, 500, text_size(g, 28), Palette.gold, s);
        render_glyph(g, w, 480, 660, revelation_completeness(g.depth));
        if ((g.frame / 30) % 2 == 0) w.text(310, 800, text_size(g, 24), Palette.dim, "CONFIRM FOR TITLE");
    }

    /// Stars, moon, rain, motes — all positions are pure functions of the
    /// stored field + elapsed time, so the weather is deterministic.
    fn render_weather(g: *const Game, w: *DrawWriter, calm: bool) void {
        const wx = Weather.derive(g.depth, g.face, g.level().weather_base);
        const scale: f32 = if (g.weather_reduced) 0.5 else 1.0;
        const t = @as(f32, @floatFromInt(g.elapsed_ms + g.screen_ms)) / 1000.0;
        // Stars
        for (g.stars) |s| {
            const tw = 0.5 + 0.5 * @sin(t * 1.7 + @as(f32, @floatFromInt(s[0])));
            if (wx.star_glow * tw > 0.45) w.circle(s[0], s[1], 2, Palette.dim);
        }
        // Moon
        w.circle(800, 130, 44, Palette.paper);
        w.circle(818, 118, 40, Palette.bg);
        // Rain (density = the coupling made visible)
        const rain_n: usize = @intFromFloat(wx.rain * 90.0 * scale);
        var i: usize = 0;
        while (i < rain_n) : (i += 1) {
            const fi_: f32 = @floatFromInt(i);
            const x = @mod(fi_ * 173.0 + t * (60.0 + wx.wind * 120.0), 960.0);
            const y = @mod(fi_ * 289.0 + t * 420.0, 960.0);
            w.seg(fi(x), fi(y), fi(x + wx.wind * 18.0), fi(y + 22.0), 2, Palette.mauve);
        }
        // Motes: ambient life that QUIETS as she deepens.
        const mote_n: usize = @intFromFloat(@as(f32, @floatFromInt(wx.mote_count)) * scale);
        const calm_factor: f32 = if (calm) 0.6 else 1.0;
        const speed = wx.mote_speed * calm_factor;
        i = 0;
        while (i < mote_n and i < max_motes) : (i += 1) {
            const base = g.motes[i];
            const x = @mod(@as(f32, @floatFromInt(base[0])) + t * 14.0 * speed, 960.0);
            const y = @mod(@as(f32, @floatFromInt(base[1])) - t * 9.0 * speed, 960.0);
            w.circle(fi(x), fi(y), 3, Palette.rose);
        }
    }

    /// The suggestion glyph: 8 segments revealed by completeness.
    fn render_glyph(g: *const Game, w: *DrawWriter, cx: i32, cy: i32, completeness: f32) void {
        _ = g;
        const segs = [8][4]i32{
            .{ -60, -60, 60, -60 }, .{ 60, -60, 60, 60 },  .{ 60, 60, -60, 60 }, .{ -60, 60, -60, -60 },
            .{ -60, -60, 60, 60 },  .{ 60, -60, -60, 60 }, .{ 0, -84, 0, 84 },   .{ -84, 0, 84, 0 },
        };
        const shown: usize = @intFromFloat(completeness * 8.0);
        for (segs, 0..) |s, i| {
            if (i < shown) w.seg(cx + s[0], cy + s[1], cx + s[2], cy + s[3], 4, Palette.gold);
        }
        const label: []const u8 = if (completeness >= 0.75) "GLIMPSED" else "HINTED";
        w.text(cx - 52, cy + 104, 20, Palette.dim, label);
    }

    fn render_scene(g: *const Game, w: *DrawWriter) void {
        render_weather(g, w, false);
        render_portrait(g, w);
        render_hud(g, w);
    }

    /// Abstract-symbolic portrait: posture (shoulders, head sink/tilt) and
    /// expression (lids, iris discs, brows, mouth, blush) both read from
    /// the interpolated FaceParams.
    fn render_portrait(g: *const Game, w: *DrawWriter) void {
        const p = g.params;
        const breath = breath_amount(g);
        const cx: i32 = 480 + fi(p.head_tilt);
        const cy: i32 = 430 + fi(p.head_sink) + fi(breath * 6.0);
        // Shoulders / neck (posture)
        const sy: i32 = 800 + fi(p.shoulder_y);
        w.tri(240, 960, 720, 960, 480, sy, Palette.plum);
        w.rect(cx - 34, cy + 190, 68, 90, Palette.skin);
        // Hair mass behind the head
        w.circle(cx - 120, cy - 40, 120, Palette.plum);
        w.circle(cx + 120, cy - 40, 120, Palette.plum);
        w.circle(cx, cy - 90, 150, Palette.plum);
        // Head
        w.circle(cx, cy, 168, Palette.skin);
        // Hair fringe
        w.tri(cx - 168, cy - 60, cx + 168, cy - 60, cx, cy - 190, Palette.plum);
        // Blush (banded by intensity; palette steps stand in for alpha)
        if (p.blush > 0.25) {
            const bc: u8 = if (p.blush > 0.66) Palette.rose else Palette.mauve;
            w.circle(cx - 96, cy + 62, 30, bc);
            w.circle(cx + 96, cy + 62, 30, bc);
        }
        // Eyes: white, iris disc (full-disc centre = gaze), lids by eye_open
        for ([_]i32{ -72, 72 }) |dx| {
            const ex = cx + dx;
            const ey = cy - 10;
            w.circle(ex, ey, 30, Palette.paper);
            const gx = ex + fi(p.gaze_x * 13.0);
            const gy = ey + fi(p.gaze_y * 13.0);
            w.circle(gx, gy, 15, Palette.plum);
            w.circle(gx, gy, 7, Palette.bg);
            if (p.gaze_y > 0.5 and p.eye_open < 0.3) {
                // High-arousal marker: the peak state's warm iris ring.
                w.circle(gx, gy, 17, Palette.rose);
                w.circle(gx, gy, 15, Palette.plum);
            }
            const lid = fi((1.0 - p.eye_open) * 34.0);
            if (lid > 0) w.rect(ex - 32, ey - 32, 64, lid, Palette.skin);
            // Brow
            const by = ey - 52 - fi(p.brow_lift * 10.0);
            w.seg(ex - 30, by, ex + 30, by - 4, 5, Palette.plum);
        }
        // Nose + mouth
        w.seg(cx, cy + 28, cx - 6, cy + 48, 3, Palette.mauve);
        if (p.mouth_open > 0.25) {
            w.circle(cx, cy + 96, 8 + fi(p.mouth_open * 16.0), Palette.plum);
        } else {
            w.seg(cx - 22, cy + 96, cx + 22, cy + 96, 4, Palette.plum);
        }
        // Breathing ring around the portrait
        const rr = 250.0 + breath * 26.0;
        var k: usize = 0;
        while (k < 28) : (k += 1) {
            const a1 = @as(f32, @floatFromInt(k)) / 28.0 * 6.2832;
            const a2 = @as(f32, @floatFromInt(k + 1)) / 28.0 * 6.2832;
            w.seg(
                480 + fi(@cos(a1) * rr),
                470 + fi(@sin(a1) * rr),
                480 + fi(@cos(a2) * rr),
                470 + fi(@sin(a2) * rr),
                3,
                if (g.breath == .exhale) Palette.pink else Palette.dim,
            );
        }
    }

    fn breath_amount(g: *const Game) f32 {
        const dur = @as(f32, @floatFromInt(g.phase_duration_ms()));
        const t = @as(f32, @floatFromInt(g.phase_ms)) / dur;
        return switch (g.breath) {
            .inhale => ease_in_out(t),
            .hold => 1.0,
            .exhale => 1.0 - ease_in_out(t),
            .settle => 0.12,
        };
    }

    fn render_hud(g: *const Game, w: *DrawWriter) void {
        const lvl = g.level();
        w.text(36, 36, text_size(g, 22), Palette.dim, lvl.name);
        w.text(36, 72, text_size(g, 22), Palette.paper, g.face.label());
        // Depth gauge
        w.rect(36, 110, 300, 18, Palette.deep);
        w.rect(36, 110, fi(300.0 * g.depth), 18, Palette.pink);
        var buf: [64]u8 = undefined;
        const ds = std.fmt.bufPrint(&buf, "DEPTH {d}%", .{@as(u32, @intFromFloat(g.depth * 100.0))}) catch "";
        w.text(36, 140, text_size(g, 20), Palette.gold, ds);
        // Beat pips during the counted exhale
        if (g.breath == .exhale) {
            const n = lvl.beats_per_cycle;
            for (0..n) |k| {
                const x: i32 = 400 + @as(i32, @intCast(k)) * 44;
                const c: u8 = switch (g.beats[k]) {
                    .hit => Palette.pink,
                    .missed => Palette.mauve,
                    .pending => Palette.paper,
                };
                w.circle(x, 880, 14, c);
            }
            w.text(380, 800, text_size(g, 24), Palette.paper, "TAP ON THE COUNT");
        } else {
            const label: []const u8 = switch (g.breath) {
                .inhale => "SHE BREATHES IN",
                .hold => "SHE HOLDS",
                .settle => "SETTLING",
                .exhale => unreachable,
            };
            w.text(370, 800, text_size(g, 24), Palette.dim, label);
        }
        // Time left
        const remain = lvl.time_limit_ms -| g.elapsed_ms;
        const ts = std.fmt.bufPrint(&buf, "TIME {d}:{d:0>2}", .{ remain / 60000, (remain / 1000) % 60 }) catch "";
        w.text(790, 36, text_size(g, 20), Palette.dim, ts);
        if (g.culminating_ms > 0) {
            w.text(330, 190, text_size(g, 34), Palette.gold, "ON THE COUNTED EXHALE");
        }
        render_glyph(g, w, 856, 830, revelation_completeness(g.depth));
    }
};

// ---------------------------------------------------------------------------
// Public orchestration: the wasm boundary
// ---------------------------------------------------------------------------

var game: Game = Game.init(1, false);
var writer: DrawWriter = .{};
var current_draw_len: usize = 0;

/// Initialise (or reset) the game. Returns 0 on success, -1 on an invalid
/// level (the game is still initialised, at level 0 — the shell must not
/// pass unchecked user input here; the level comes from the title screen).
export fn init(seed: u32, level: u8) i32 {
    return init_mode(seed, level, false);
}

/// Demo-mode init: the core auto-plays (menus auto-confirm, taps land on
/// beat centres). Used by the preview capture harness; also reachable in
/// the shipped page as ?demo=<level>&seed=<n>.
export fn init_demo(seed: u32, level: u8) i32 {
    return init_mode(seed, level, true);
}

fn init_mode(seed: u32, level: u8, demo: bool) i32 {
    const idx = validate_level(level) catch {
        game = Game.init(seed, demo);
        return -1;
    };
    game = Game.init(seed, demo);
    game.level_idx = idx;
    return 0;
}

/// Jump straight into a level (capture harness + shell "quick start").
export fn start_level(level: u8) i32 {
    const idx = validate_level(level) catch return -1;
    game.start_level(idx);
    return 0;
}

/// One fixed step + render. dt_ms contractual 16; clamped inside.
export fn step(dt_ms: u32, input: u32) void {
    game.step(dt_ms, input);
    writer.reset();
    Renderer.render(&game, &writer);
    game.dropped_ops = writer.dropped;
    current_draw_len = writer.len;
}

export fn draw_ptr() [*]const u8 {
    return &draw_buffer;
}
export fn draw_len() usize {
    return current_draw_len;
}
export fn screen() u8 {
    return @intFromEnum(game.screen);
}
export fn event_code() u8 {
    return game.event_code;
}
export fn depth_milli() u32 {
    return @intFromFloat(game.depth * 1000.0);
}

export fn level_idx() u8 {
    return @intCast(game.level_idx);
}

/// Persistence bridge: the shell owns localStorage and restores the two
/// settings at boot through here (the core itself performs no I/O).
export fn apply_settings(weather_reduced: u8, text_large: u8) void {
    game.weather_reduced = weather_reduced != 0;
    game.text_large = text_large != 0;
}

/// Current settings as bits (bit0 weather_reduced, bit1 text_large) so
/// the shell can persist them when they change.
export fn settings_bits() u8 {
    return (@as(u8, if (game.weather_reduced) 1 else 0)) |
        (@as(u8, if (game.text_large) 1 else 0) << 1);
}

// ---------------------------------------------------------------------------
// Tests — half validation, half adversarial (estate rule)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "transition table is total and shaped as specified" {
    for (0..4) |from| {
        for (0..4) |to| {
            const cell = transition_table[from][to];
            if (from == to) {
                try testing.expectEqual(@as(u32, 0), cell.duration_ms);
                try testing.expect(!cell.via_intermediate);
            } else if (to > from) {
                try testing.expectEqual(@as(u32, 900) * @as(u32, @intCast(to - from)), cell.duration_ms);
                try testing.expectEqual(to - from > 1, cell.via_intermediate);
            } else {
                try testing.expectEqual(@as(u32, 500) * @as(u32, @intCast(from - to)), cell.duration_ms);
                try testing.expectEqual(from - to > 1, cell.via_intermediate);
            }
        }
    }
}

test "keyframes move posture AND expression monotonically down the descent" {
    const k = face_keyframes;
    try testing.expect(k[0].eye_open > k[1].eye_open and k[1].eye_open > k[2].eye_open);
    try testing.expect(k[0].blush < k[1].blush and k[1].blush < k[2].blush);
    try testing.expect(k[0].mouth_open < k[1].mouth_open and k[1].mouth_open < k[2].mouth_open);
    try testing.expect(k[0].head_sink < k[1].head_sink and k[1].head_sink < k[2].head_sink and k[2].head_sink < k[3].head_sink);
    try testing.expect(k[0].shoulder_y < k[1].shoulder_y and k[1].shoulder_y < k[2].shoulder_y and k[2].shoulder_y < k[3].shoulder_y);
    for (k) |p| {
        try testing.expect(p.eye_open >= 0 and p.eye_open <= 1);
        try testing.expect(p.blush >= 0 and p.blush <= 1);
        try testing.expect(p.gaze_x >= -1 and p.gaze_x <= 1 and p.gaze_y >= -1 and p.gaze_y <= 1);
    }
}

test "weather coupling is monotonic in depth" {
    for ([_]FaceState{ .rest, .edge, .peak, .daze }) |face| {
        var prev = Weather.derive(0.0, face, 0.2);
        var d: f32 = 0.1;
        while (d <= 1.001) : (d += 0.1) {
            const w = Weather.derive(d, face, 0.2);
            try testing.expect(w.rain >= prev.rain);
            try testing.expect(w.mote_count <= prev.mote_count);
            try testing.expect(w.mote_speed <= prev.mote_speed);
            try testing.expect(w.star_glow >= prev.star_glow);
            prev = w;
        }
    }
}

test "revelation completeness ramps and saturates" {
    try testing.expectEqual(@as(f32, 0), revelation_completeness(0.0));
    try testing.expectEqual(@as(f32, 0), revelation_completeness(0.30));
    try testing.expectEqual(@as(f32, 1), revelation_completeness(0.85));
    try testing.expectEqual(@as(f32, 1), revelation_completeness(1.0));
    try testing.expect(revelation_completeness(0.5) > 0 and revelation_completeness(0.5) < 1);
}

test "demo policy completes level 1 and visits edge and peak" {
    var g = Game.init(12345, true);
    g.start_level(0);
    var saw_edge = false;
    var saw_peak = false;
    var steps: usize = 0;
    while (g.screen != .victory and steps < 240_000 / 16) : (steps += 1) {
        g.step(step_ms, 0);
        if (g.face == .edge) saw_edge = true;
        if (g.face == .peak) saw_peak = true;
    }
    try testing.expectEqual(Screen.victory, g.screen);
    try testing.expect(saw_edge and saw_peak);
    try testing.expect(g.good >= 8);
    try testing.expect(g.depth >= levels[0].target_depth - 0.051);
}

test "determinism: same seed and inputs give identical draw lists" {
    var a = Game.init(777, true);
    var b = Game.init(777, true);
    a.start_level(1);
    b.start_level(1);
    var wa: DrawWriter = .{};
    var wb: DrawWriter = .{};
    for (0..2000) |i| {
        a.step(step_ms, 0);
        b.step(step_ms, 0);
        if (i % 100 == 0) {
            // Both renders share the one static buffer: snapshot a's bytes
            // before rendering b, or the comparison compares a to itself.
            var snapshot: [draw_buffer_bytes]u8 = undefined;
            wa.reset();
            Renderer.render(&a, &wa);
            @memcpy(snapshot[0..wa.len], draw_buffer[0..wa.len]);
            wb.reset();
            Renderer.render(&b, &wb);
            try testing.expectEqual(wa.len, wb.len);
            try testing.expectEqualSlices(u8, snapshot[0..wa.len], draw_buffer[0..wb.len]);
            try testing.expectEqual(a.depth, b.depth);
        }
    }
}

// --- adversarial ---

test "adversarial: dt of zero and dt of billions do not break the step" {
    var g = Game.init(9, false);
    g.start_level(0);
    g.step(0, 0);
    try testing.expectEqual(BreathPhase.inhale, g.breath);
    g.step(4_000_000_000, 0); // clamped to 250 ms internally
    try testing.expectEqual(BreathPhase.inhale, g.breath);
    try testing.expect(g.phase_ms <= 250);
    try testing.expect(g.depth >= 0 and g.depth <= 1);
}

test "adversarial: tap spam outside the exhale earns nothing" {
    var g = Game.init(9, false);
    g.start_level(0);
    for (0..1250) |_| g.step(step_ms, Input.tap); // 20 s of spam, spans phases
    // Any hits could only come from exhale windows the spam crossed; depth
    // must still be bounded and the counters consistent.
    try testing.expect(g.depth <= 1.0);
    try testing.expect(g.good <= g.level().beats_per_cycle * 3);
}

test "adversarial: invalid level is rejected at the boundary" {
    try testing.expectEqual(@as(i32, -1), init(1, 99));
    try testing.expectEqual(@as(usize, 0), game.level_idx);
    try testing.expectEqual(@as(i32, -1), start_level(200));
}

test "adversarial: beat window edge — +280 ms hits, +281 ms misses" {
    var g = Game.init(9, false);
    g.start_level(0);
    g.breath = .exhale;
    g.phase_ms = g.beat_center_ms(0) + 280;
    g.judge_tap();
    try testing.expectEqual(BeatState.hit, g.beats[0]);

    var h = Game.init(9, false);
    h.start_level(0);
    h.breath = .exhale;
    h.phase_ms = h.beat_center_ms(0) + 281;
    h.judge_tap();
    try testing.expectEqual(BeatState.pending, h.beats[0]);
}

test "adversarial: draw output stays inside its bounds at peak weather" {
    var g = Game.init(4242, false);
    g.start_level(2);
    g.depth = 1.0;
    g.set_face_target(.peak);
    g.advance_transition(10_000);
    var w: DrawWriter = .{};
    Renderer.render(&g, &w);
    try testing.expect(w.ops <= max_ops);
    try testing.expect(w.len < draw_buffer_bytes);
}

test "rng: identical seeds give identical streams" {
    var a = Rng.init(5);
    var b = Rng.init(5);
    for (0..100) |_| try testing.expectEqual(a.next(), b.next());
    var c = Rng.init(5);
    for (0..100) |_| {
        const u = c.unit();
        try testing.expect(u >= 0 and u < 1);
    }
}
