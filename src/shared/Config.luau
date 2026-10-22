--!strict
--[[
CursedGems :: Config
--------------------------------------------------------------------
The single source of truth for every tunable value in the game.

Rules:
  1. Logic files must never contain magic numbers - they read from here.
  2. Changing how the game FEELS should require editing only this file.
  3. Values marked [SIM] were derived from an offline simulation of the
     economy (docs/PHASE1_DESIGN.md) and are NOT yet playtest-validated.

Core identity: gems are simultaneously your currency and your life.
Capturing a creature permanently raises your upkeep, so the collection
mechanic doubles as a player-chosen difficulty dial.
]]

local Config = {}

Config.VERSION = "0.1.0-phase1"

Config.Economy = {
    -- A new player can afford the discounted first summon immediately, which
    -- teaches "this number pays for things" inside the first 30 seconds.
    STARTING_GEMS = 15,

    -- [SIM] Base drain of the curse, in gems per minute while actively playing.
    -- Re-derived rather than re-guessed, twice. The Phase 1 pass modelled income
    -- at 13.0 gems/min; the playtest pass then widened the pockets from 34 to 50
    -- studs and pushed them from 86 to 108 studs out, which adds travel time and
    -- pulls income down to 12.5. Seven point five keeps the published net column
    -- below intact (0 creatures = +5/min, 2 = break even, 4+ = losing).
    --
    -- Why the base moved instead of income: the +5 column is the promise, and
    -- the upkeep curve (2.5/creature) is what makes it legible. Both survive a
    -- uniform shift; what does NOT survive is halving income and keeping the
    -- drain, which would have made the curse a 7-minute wait.
    BASE_DECAY_PER_MINUTE = 7.5,

    -- [SIM] Each owned creature eats gems continuously. This is the core
    -- risk/reward lever: 0 creatures = net +5/min, 2 = break even, 4+ = losing.
    UPKEEP_PER_CREATURE_PER_MINUTE = 2.5,

    -- Onboarding safety net: no drain at all for this long after spawning.
    SPAWN_GRACE_SECONDS = 60,

    -- Anti-frustration: below this balance the drain halves, so a player always
    -- gets a "one more gem" window instead of a death spiral they cannot read.
    MERCY_THRESHOLD = 5,
    MERCY_MULTIPLIER = 0.5,

    -- The shrine is a safe zone. It doubles as the natural social hub where new
    -- players first see other players, which is where co-play starts.
    SHRINE_SAFE_RADIUS = 48,
    SHRINE_DECAY_MULTIPLIER = 0.25,

    -- Display cap only, so the HUD number never becomes unreadable.
    MAX_GEMS = 9999,
}

Config.Gems = {
    COMMON_VALUE = 1,
    CURSED_VALUE = 5,
    -- [SIM] 92/8 keeps jackpots rare enough to stay special (about one cursed
    -- gem per 12 pickups) while still appearing in most first sessions.
    COMMON_WEIGHT = 92,
    CURSED_WEIGHT = 8,

    -- Collection: ProximityPrompt instead of Touched because a server-side
    -- Touched check is trivially spoofed by a client-moved character.
    -- The prompt itself is validated by server-side distance in GemSystem.
    PROMPT_MAX_DISTANCE = 9,
    PROMPT_HOLD_SECONDS = 0.15,
    COLLECT_RADIUS = 7,

    -- Presentation (client-side only, never affects state).
    SPIN_SPEED = 12,
    BOB_HEIGHT = 0.6,
    BOB_SPEED = 2,
    GEM_HEIGHT = 3,

    -- Respawn: randomized delay AND randomized location, drawn from all four
    -- zones. A fixed respawn turns farming into a memorized route (a chore);
    -- a global draw also stops one pocket from feeding its own camper.
    --
    -- The delay is real: a collected slot is RESERVED for 8-12 s (was 5-8), so
    -- the field visibly thins and the gem does not come straight back (see
    -- GemSystem). It is still non-binding for a player walking the circuit -
    -- sixteen gems take about 100 s of walking to turn over, and the first
    -- refills land in ten - and binding for a player standing in one pocket,
    -- which is the point. The longer window costs about 0.55 live gems at the
    -- tuned pickup rate (14.4 of 16 visible instead of 15.0): density absorbs
    -- the change, so pool size and the drain were deliberately left alone.
    --
    -- Pool size is now an INCOME knob, not just a liveliness knob. Gem density
    -- is what the economy model depends on, so widening the pockets without
    -- adding gems would have cut income by about 45%. Sixteen live gems is four
    -- per pocket, which holds 12.5 gems/min at the published +5.
    POOL_BASE = 12,
    POOL_PER_PLAYER = 4,
    POOL_MIN = 16,
    POOL_MAX = 44,
    RESPAWN_MIN_SECONDS = 8,
    RESPAWN_MAX_SECONDS = 12,

    -- Placement constraints: no two gems crowd one spot, and nothing spawns on
    -- top of a player. Spacing defines a POCKET rather than a field cell: at 13
    -- studs four live gems inside one 50-stud pocket read as a cluster you can
    -- walk through, instead of a single pile in the middle of it.
    MIN_GEM_SPACING = 13,
    MIN_SPAWN_DISTANCE_FROM_PLAYER = 25,
    MAX_SPAWN_ATTEMPTS = 24,
}

-- CollectionService tags. Shared, so the server that applies them and the client
-- that animates them can never disagree about the string. A typo in a tag name
-- is otherwise a silent failure: the world looks completely normal and simply
-- never moves.
Config.Tags = {
    GEM = "CursedGem",
    PEN_MARKER = "CursedGemsPenMarker",
}

Config.Summon = {
    COST = 25,
    -- Retention hook: the first summon of a LIFETIME is cheap, so every new
    -- player finishes their first session owning a visible pet.
    FIRST_SUMMON_COST = 10,
    -- Long enough for a real reveal, short enough to feel snappy.
    REVEAL_SECONDS = 2.2,
    ACTION_COOLDOWN_SECONDS = 1.5,
    -- Deliberately a longer hold than a gem pickup. A summon spends currency,
    -- so press-and-hold is the accidental-spend guard.
    PROMPT_MAX_DISTANCE = 11,
    PROMPT_HOLD_SECONDS = 0.35,
    -- The authoritative server radius, deliberately wider than the prompt: an
    -- honest player is never rejected, a teleporting one still is.
    INTERACT_RADIUS = 9,
    -- Summoning is the social moment. A shared pen field only works if other
    -- players actually notice, so everyone in range gets the reveal flash.
    BROADCAST_RADIUS = 120,
}

Config.Curse = {
    -- Absolute gem balances at which the client escalates its warnings.
    -- Expressed in gems rather than percent, because gems ARE the meter.
    WARN_AT = { 25, 10 },

    -- Tuned in the Phase 1 pass. 22 cuts the average gem hop (about 58 studs)
    -- from 3.8 s to 2.8 s while staying under the speed at which the default
    -- walk animation starts to read as sliding. Cursed speed is scaled to keep
    -- the FELT penalty identical (14/22 = 0.636 vs the old 10/16 = 0.625);
    -- leaving it at 10 would have silently made the curse far harsher.
    NORMAL_WALK_SPEED = 22,
    CURSED_WALK_SPEED = 14,
    NORMAL_JUMP_POWER = 50,
    CURSED_JUMP_POWER = 38,

    -- Deliberately NO periodic damage. Timer-death reads as unfair to a young
    -- audience, and a soft curse that clears the instant you grab one gem
    -- produces a much better feedback loop.
    CLEAR_ABOVE_GEMS = 0,
}

Config.World = {
    SEED = 20261017,
    MAP_SIZE = 520,
    GROUND_Y = 0,

    PLAYER_SPAWN = Vector3.new(0, 4, 44),
    SHRINE_POSITION = Vector3.new(0, 0, 0),
    SHRINE_PAD_RADIUS = 26,

    CAVE_CENTER = Vector3.new(-150, 0, -150),
    CAVE_SIZE = Vector3.new(96, 32, 96),

    TREE_COUNT = 90,
    ROCK_COUNT = 55,

    -- Gems live in four pockets rather than a uniform 60-240 ring. The ring made
    -- the player sweep a 170-stud-wide annulus hunting for the next gem; four
    -- known pockets turn travel into a route. Centres sit on the axes at 108
    -- studs with a 50-stud radius, so the near edge is 58 studs from the shrine
    -- (clear of the 48-stud safe radius and well clear of the pad), the player
    -- spawn at 44 stays outside every pocket, and neighbouring centres are 152.7
    -- studs apart (6.9 s at the new walk speed).
    --
    -- The 34-stud pocket at 86 studs was the Phase 1 shape. Playtesting read it
    -- as a tight pile next to the shrine, so it grew 47% and moved out 26%. The
    -- base drain moved with it - see BASE_DECAY_PER_MINUTE above for the link.
    --
    -- Respawn is deliberately NOT zone-bound: a zone that refilled itself would
    -- make standing still the best income in the game (see GemSystem).
    GEM_ZONES = {
        { center = Vector3.new(0, 0, -108), radius = 50 },
        { center = Vector3.new(108, 0, 0), radius = 50 },
        { center = Vector3.new(0, 0, 108), radius = 50 },
        { center = Vector3.new(-108, 0, 0), radius = 50 },
    },
    -- 4 zones x 16 = 64 legal positions: POOL_MAX (44) plus headroom, so even a
    -- full server keeps at least five free points in every pocket.
    GEM_POINTS_PER_ZONE = 16,

    -- Prop scatter bounds. These used to be the gem field; gems no longer use
    -- them, and the new names say what they actually control.
    PROP_FIELD_INNER_RADIUS = 60,
    PROP_FIELD_OUTER_RADIUS = 240,
}

Config.Follower = {
    UPDATE_HZ = 20,
    -- Showing every creature would cost one model and one CFrame write per
    -- creature per tick, and eight pets trailing a player is visual noise. The
    -- newest few follow; the rest live in the collection panel.
    MAX_VISIBLE_FOLLOWERS = 3,
    TRAIL_SPACING = 5.5,
    -- Alternating side offset, so a trail of followers reads as a group
    -- rather than a single-file queue.
    TRAIL_SIDE_OFFSET = 2.5,
    FOLLOW_DISTANCE = 6.5,
    FOLLOW_HEIGHT = 2.6,
    LERP_ALPHA = 0.28,
    -- Creatures are anchored and CFramed by the server: zero physics cost per
    -- creature, which is what keeps this affordable as collections grow.
}

Config.Net = {
    STATE_SYNC_HZ = 4,
    MIN_SECONDS_BETWEEN_COLLECTS = 0.15,
    -- How far a client-claimed interaction may disagree with server truth.
    MAX_POSITION_SLACK = 6,
}

Config.Data = {
    DATASTORE_NAME = "CursedGems_PlayerData_v1",
    KEY_PREFIX = "Player_",
    -- Batched, never per-change. Roblox rate-limits, and per-change writes are
    -- the classic way to silently lose player progress.
    AUTOSAVE_SECONDS = 90,
    LOCK_TIMEOUT_SECONDS = 60,
    MAX_SAVE_RETRIES = 5,
    RETRY_BASE_SECONDS = 1.5,
    -- Studio has no DataStore access until the place is published with API
    -- access enabled. This keeps playtesting possible before then.
    ALLOW_MEMORY_FALLBACK = true,
}

Config.Debug = {
    VERBOSE = false,
    LOG_ECONOMY = true,
    -- Playtest instrumentation: one JOIN line per player and one SESSION SUMMARY
    -- line per session, shaped for the recording sheet in
    -- docs/PHASE1_PLAYTEST.md. Nothing else depends on it, so it is safe to set
    -- false for a clean release build.
    LOG_SESSION_SUMMARY = true,
}

return Config
