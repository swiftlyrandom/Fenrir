-- ============================================================
--  MainBrain.lua
--  Top-level orchestrator. Runs the Sense→Analyze→Score→
--  Execute→Reevaluate loop and wires all subsystems together.
--
--  USAGE (from a LocalScript on the bot's client):
--    local Brain = require(path.to.MainBrain)
--    Brain.init({ difficulty = "Hard" })
--    Brain.start()
-- ============================================================

local RunService   = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players      = game:GetService("Players")

-- ── Subsystem requires — resolved via loader registry ────────
-- When running from an executor, _Modules is populated by the
-- loader before MainBrain is loaded. When running inside Roblox
-- Studio normally, fall back to script.Parent requires.
local function _req(name)
    if _G._Modules and _G._Modules[name] then
        return _G._Modules[name]
    end
    return require(script.Parent[name])
end

local FlightController     = _req("FlightController")
local PerceptionSystem     = _req("PerceptionSystem")
local OpponentModel        = _req("OpponentModel")
local TacticalEvaluator    = _req("TacticalEvaluator")
local WeaponSystem         = _req("WeaponSystem")
local DefenseSystem        = _req("DefenseSystem")
local LearningSystem       = _req("LearningSystem")
local DifficultyController = _req("DifficultyController")
local BotState             = _req("BotState")

-- ── Remote ──────────────────────────────────────────────────
local Event = ReplicatedStorage:WaitForChild("Event")
local function fireEvent(...)
    Event:FireServer(...)
end

-- ============================================================
--  MODULE TABLE
-- ============================================================
local MainBrain = {}

-- ── Runtime state ───────────────────────────────────────────
local _running       = false
local _loopConn      = nil
local _accumulator   = 0          -- seconds since last decision tick
local _config        = {}

-- ── Default config ──────────────────────────────────────────
local DEFAULTS = {
    difficulty      = "Hard",     -- Easy | Medium | Hard | Elite
    vehicleName     = "Large Bomber",
    teamName        = nil,        -- set to your team name; nil = auto-detect
    fovRadius       = 2000,       -- stud sphere for perception
    tickMin         = 0.10,       -- fastest decision rate (seconds)
    tickMax         = 0.25,       -- slowest  decision rate (seconds)
    engineSpeed     = 8652.419607067108, -- from your startEngine args
    engineThrottle  = 1.2,
    engineAltitude  = 40,
    debugPrint      = false,
}

-- ============================================================
--  INTERNAL HELPERS
-- ============================================================

local function log(...)
    if _config.debugPrint then
        print("[MainBrain]", ...)
    end
end

--- Derive tick interval from difficulty + situation urgency (0-1).
local function getTickInterval(urgency)
    local diff     = DifficultyController.get(_config.difficulty)
    local baseMin  = _config.tickMin  * diff.reactionMult
    local baseMax  = _config.tickMax  * diff.reactionMult
    -- High urgency → tick faster
    return baseMin + (baseMax - baseMin) * (1 - urgency)
end

-- ============================================================
--  ENGINE MANAGEMENT
-- ============================================================

local _engineRunning = false

local function startEngine()
    if _engineRunning then return end
    fireEvent("startEngine", {
        _config.engineSpeed,
        _config.engineThrottle,
        _config.engineAltitude,
    })
    _engineRunning = true
    log("Engine started.")
end

local function stopEngine()
    if not _engineRunning then return end
    fireEvent("stopEngine")
    _engineRunning = false
    log("Engine stopped.")
end

-- ============================================================
--  DECISION LOOP PHASES
-- ============================================================

--[[
    Phase 1 – SENSE
    Ask PerceptionSystem to snapshot the world around us.
    Returns a `percept` table:
      {
        selfBody      : BasePart,
        selfPos       : Vector3,
        selfVel       : Vector3,
        selfAltitude  : number,
        targets       : { [i] = TargetInfo },
        primaryTarget : TargetInfo | nil,
        threats       : { [i] = ThreatInfo },
        ammoReady     : bool,
        bombReady     : bool,
      }
--]]
local function sense()
    return PerceptionSystem.snapshot({
        vehicleName = _config.vehicleName,
        fovRadius   = _config.fovRadius,
        teamName    = _config.teamName,
    })
end

--[[
    Phase 2 – ANALYZE
    Update the opponent model with fresh observations.
    Returns the enriched percept (adds opponentProfile field).
--]]
local function analyze(percept)
    if percept.primaryTarget then
        OpponentModel.observe(percept.primaryTarget)
        percept.opponentProfile = OpponentModel.getProfile(percept.primaryTarget.player)
    end
    return percept
end

--[[
    Phase 3 – SCORE ACTIONS
    TacticalEvaluator returns a sorted list:
      { { action="attack", score=0.9 }, { action="climb", score=0.6 }, ... }
--]]
local function scoreActions(percept)
    local diff = DifficultyController.get(_config.difficulty)
    return TacticalEvaluator.evaluate(percept, diff)
end

--[[
    Phase 4 – CHOOSE
    Pick the highest-scoring action, applying difficulty noise.
    Elite  → always picks best.
    Hard   → 90 % best, 10 % second-best.
    Medium → 75 % best.
    Easy   → 60 % best.
--]]
local function chooseAction(ranked, difficulty)
    local noise = DifficultyController.get(difficulty).choiceNoise
    if #ranked == 0 then return "idle" end
    if #ranked >= 2 and math.random() < noise then
        return ranked[2].action   -- intentional sub-optimal choice
    end
    return ranked[1].action
end

--[[
    Phase 5 – EXECUTE
    Route the chosen action to the right subsystem.
--]]
local function execute(action, percept)
    local body = percept.selfBody
    if not body then return end

    -- ── Movement actions ──────────────────────────────────
    if action == "attack" then
        FlightController.intercept(body, percept.primaryTarget.position)

    elseif action == "bomb_run" then
        FlightController.approachBomb(body, percept.primaryTarget.position)
        WeaponSystem.tryBomb(percept)

    elseif action == "climb" then
        FlightController.climb(body, _config.difficulty)

    elseif action == "dive" then
        FlightController.dive(body, _config.difficulty)

    elseif action == "disengage" then
        FlightController.disengage(body, percept)

    elseif action == "reset_distance" then
        FlightController.resetDistance(body, percept.primaryTarget and percept.primaryTarget.position)

    elseif action == "ambush" then
        FlightController.ambush(body, percept.primaryTarget.position)

    elseif action == "bait" then
        FlightController.bait(body, percept)

    elseif action == "evade" then
        DefenseSystem.evade(body, percept)

    elseif action == "idle" then
        FlightController.cruise(body)
    end

    -- ── Shooting (independent of movement action) ────────
    if percept.primaryTarget and action ~= "evade" and action ~= "disengage" then
        WeaponSystem.tryShoot(percept, DifficultyController.get(_config.difficulty))
    end

    -- ── Persistent defense checks ─────────────────────────
    DefenseSystem.checkPassive(body, percept)
end

--[[
    Phase 6 – REEVALUATE
    Feed outcome data back into LearningSystem and BotState.
--]]
local function reevaluate(action, percept)
    LearningSystem.record(action, percept)
    BotState.update(action, percept)
end

-- ============================================================
--  MAIN TICK (called every Heartbeat, gated by accumulator)
-- ============================================================

local function tick(dt)
    -- ── Urgency: how pressed are we? (0 = calm, 1 = critical)
    local urgency = BotState.getUrgency()
    local interval = getTickInterval(urgency)

    _accumulator = _accumulator + dt
    if _accumulator < interval then return end
    _accumulator = 0

    -- ── 6-phase loop ────────────────────────────────────────
    local ok, err = pcall(function()
        local percept = sense()
        if not percept.selfBody then return end  -- not in a vehicle yet

        percept  = analyze(percept)
        local ranked = scoreActions(percept)
        local action = chooseAction(ranked, _config.difficulty)

        log("Action:", action, "| Target:", percept.primaryTarget and percept.primaryTarget.player.Name or "none")

        execute(action, percept)
        reevaluate(action, percept)
    end)

    if not ok then
        warn("[MainBrain] tick error:", err)
    end
end

-- ============================================================
--  PUBLIC API
-- ============================================================

--- Initialize the bot with optional config overrides.
--- Call once before start().
function MainBrain.init(cfg)
    _config = setmetatable(cfg or {}, { __index = DEFAULTS })

    -- Seed RNG for difficulty noise
    math.randomseed(tick())

    -- Init subsystems
    DifficultyController.init(_config.difficulty)
    FlightController.init(_config)
    WeaponSystem.init(_config, fireEvent)
    DefenseSystem.init(_config)
    PerceptionSystem.init(_config)
    OpponentModel.init()
    TacticalEvaluator.init(_config)
    LearningSystem.init()
    BotState.init()

    log("Initialized. Difficulty:", _config.difficulty)
end

--- Start the decision loop and engine.
function MainBrain.start()
    if _running then return end
    _running = true

    startEngine()

    _loopConn = RunService.Heartbeat:Connect(function(dt)
        tick(dt)
    end)

    log("Bot started.")
end

--- Stop the decision loop and cut engine.
function MainBrain.stop()
    if not _running then return end
    _running = false

    if _loopConn then
        _loopConn:Disconnect()
        _loopConn = nil
    end

    stopEngine()
    -- Ensure guns stop
    WeaponSystem.stopFiring()

    log("Bot stopped.")
end

--- Hard-set difficulty at runtime (useful for adaptive challenge).
function MainBrain.setDifficulty(level)
    _config.difficulty = level
    DifficultyController.init(level)
    log("Difficulty changed to:", level)
end

--- Expose config for external reads (read-only pattern).
function MainBrain.getConfig()
    return _config
end

return MainBrain
