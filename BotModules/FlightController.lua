-- ============================================================
--  FlightController.lua
--  Owns ALL physical movement of the bot's aircraft.
--  MainBrain sends high-level commands; this module translates
--  them into smooth BodyGyro + BodyVelocity adjustments.
--
--  Design principles:
--    • Never snap heading — always lerp toward target CFrame.
--    • Maintain energy: don't lose speed during turns.
--    • All tunable constants are in CONFIG at the top.
-- ============================================================

local RunService = game:GetService("RunService")
weaveAmplitude = 40,   -- raise this for wider/taller dodges overall
weavePeriod    = 1.4,  -- lower = faster direction changes

-- ── Helpers ─────────────────────────────────────────────────
local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerpV3(a, b, t)
    return Vector3.new(lerp(a.X, b.X, t), lerp(a.Y, b.Y, t), lerp(a.Z, b.Z, t))
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- ============================================================
--  MODULE TABLE
-- ============================================================
local FlightController = {}

-- ── Shared state (set in init) ───────────────────────────────
local _cfg = {}

-- ── Per-maneuver state ───────────────────────────────────────
local _maneuver = {
    type       = "none",
    phase      = 0,
    timer      = 0,
    weaveDir   = 1,
    weaveClock = 0,
}

-- ============================================================
--  CONFIG (overridden partially by MainBrain.init)
-- ============================================================
local CONFIG = {
    -- Turning
    gyroDampening     = 0.8,
    gyroMaxTorque     = 5e5,

    -- Speed
    cruiseSpeed       = 120,
    combatSpeed       = 180,
    climbSpeed        = 140,
    diveSpeed         = 220,
    evadeSpeed        = 200,
    disengageSpeed    = 200,

    -- Turn smoothing
    headingLerpFast   = 0.12,
    headingLerpSlow   = 0.05,

    -- Altitude management
    minSafeAltitude   = 80,
    maxAltitude       = 800,
    preferredAltitude = 350,

    -- Intercept lead coefficient
    leadCoeff         = 1.2,

    -- Weave
    weaveAmplitude    = 40,
    weavePeriod       = 1.4,

    -- Split-S
    splitSDiveDepth   = -120,

    -- Bomb approach
    bombApproachAlt   = 300,
    bombRunSpeed      = 160,

    -- Stall mechanic
    stallDuration     = 1.0,    -- seconds engine stays off per stall (configurable)
    stallMinAltitude  = 120,    -- won't initiate a stall below this altitude
}

-- ── Engine control callback (injected by MainBrain.init) ─────
-- Called with true to start engine, false to stop it.
-- FlightController never fires remotes directly.
local _engineControl = nil

-- ── Stall state ──────────────────────────────────────────────
local _stall = {
    active    = false,
    timer     = 0,
    maneuver  = "none",   -- "snap" | "bait" | "brake"
}

-- ============================================================
--  INTERNAL: BodyGyro / BodyVelocity writes
--  Handles both legacy (BodyGyro/BodyVelocity) and modern
--  (AlignOrientation/LinearVelocity) constraint types.
-- ============================================================

local function setHeading(body, targetPos, lerpFactor)
    local gyro = body:FindFirstChild("BodyGyro")
    if not gyro then return end

    local desired = CFrame.new(body.Position, targetPos)

    if gyro:IsA("BodyGyro") then
        gyro.CFrame = gyro.CFrame:Lerp(desired, lerpFactor or CONFIG.headingLerpFast)
        gyro.D = CONFIG.gyroDampening
        gyro.MaxTorque = Vector3.new(
            CONFIG.gyroMaxTorque,
            CONFIG.gyroMaxTorque,
            CONFIG.gyroMaxTorque
        )
    elseif gyro:IsA("AlignOrientation") then
        gyro.CFrame = desired
        gyro.Responsiveness = 25
        gyro.MaxTorque = CONFIG.gyroMaxTorque
    end
end

local function setSpeed(body, speed)
    local vel = body:FindFirstChild("BodyVelocity")
    if not vel then return end

    local moveDir = body.CFrame.LookVector * speed

    if vel:IsA("BodyVelocity") then
        vel.Velocity = moveDir
        vel.MaxForce = Vector3.new(1e5, 1e5, 1e5)
    elseif vel:IsA("LinearVelocity") then
        vel.VectorVelocity = moveDir
        vel.MaxForce = 1e5
    end
end

local function haltVelocity(body)
    local vel = body:FindFirstChild("BodyVelocity")
    if not vel then return end

    if vel:IsA("BodyVelocity") then
        vel.Velocity = Vector3.zero
    elseif vel:IsA("LinearVelocity") then
        vel.VectorVelocity = Vector3.zero
    end
end

-- ============================================================
--  INTERNAL: Heading lerpFactor from difficulty
-- ============================================================

local LERP_BY_DIFF = {
    Easy   = CONFIG.headingLerpSlow,
    Medium = 0.07,
    Hard   = 0.10,
    Elite  = CONFIG.headingLerpFast,
}

local function getLerp()
    return LERP_BY_DIFF[_cfg.difficulty] or CONFIG.headingLerpFast
end

-- ============================================================
--  INTERNAL: Predictive intercept point
-- ============================================================

local function predictIntercept(targetPos, targetVel, myPos, mySpeed)
    local relPos = targetPos - myPos
    local dist   = relPos.Magnitude
    local t      = (dist / math.max(mySpeed, 1)) * CONFIG.leadCoeff
    return targetPos + targetVel * t
end

-- ============================================================
--  INTERNAL: Altitude correction offset
-- ============================================================

local function altitudeCorrection(body)
    local alt = body.Position.Y
    if alt < CONFIG.minSafeAltitude then
        return Vector3.new(0, CONFIG.minSafeAltitude - alt + 20, 0)
    end
    return Vector3.zero
end

-- ============================================================
--  PUBLIC MANEUVERS
-- ============================================================

function FlightController.intercept(body, targetPos, targetVel)
    targetVel = targetVel or Vector3.zero
    local intercept = predictIntercept(targetPos, targetVel, body.Position, CONFIG.combatSpeed)
    local correction = altitudeCorrection(body)
    setHeading(body, intercept + correction, getLerp())
    setSpeed(body, CONFIG.combatSpeed)
end

function FlightController.approachBomb(body, targetPos)
    local bombPos = targetPos + Vector3.new(0, CONFIG.bombApproachAlt, 0)
    setHeading(body, bombPos, getLerp())
    setSpeed(body, CONFIG.bombRunSpeed)
end

function FlightController.climb(body)
    local climbTarget = body.Position + body.CFrame.LookVector * 200
                        + Vector3.new(0, 150, 0)
    climbTarget = Vector3.new(
        climbTarget.X,
        clamp(climbTarget.Y, 0, CONFIG.maxAltitude),
        climbTarget.Z
    )
    setHeading(body, climbTarget, getLerp())
    setSpeed(body, CONFIG.climbSpeed)
end

function FlightController.dive(body)
    local diveTarget = body.Position + body.CFrame.LookVector * 300
                       - Vector3.new(0, 100, 0)
    diveTarget = Vector3.new(
        diveTarget.X,
        math.max(diveTarget.Y, CONFIG.minSafeAltitude + 20),
        diveTarget.Z
    )
    setHeading(body, diveTarget, getLerp())
    setSpeed(body, CONFIG.diveSpeed)
end

function FlightController.disengage(body, percept)
    local awayDir = body.CFrame.LookVector
    if percept and percept.primaryTarget then
        awayDir = (body.Position - percept.primaryTarget.position).Unit
    end
    setHeading(body, body.Position + awayDir * 500, getLerp())
    setSpeed(body, CONFIG.disengageSpeed)
end

function FlightController.resetDistance(body, targetPos)
    if not targetPos then
        FlightController.cruise(body)
        return
    end
    local dir  = (body.Position - targetPos).Unit
    local goal = targetPos + dir * 700
    setHeading(body, goal, getLerp())
    setSpeed(body, CONFIG.combatSpeed)
end

function FlightController.ambush(body, targetPos)
    local approach = targetPos + Vector3.new(0, 250, 0)
    setHeading(body, approach, getLerp() * 0.8)
    setSpeed(body, CONFIG.combatSpeed)
end

function FlightController.bait(body, percept)
    if not percept or not percept.primaryTarget then
        FlightController.cruise(body)
        return
    end
    setHeading(body, percept.primaryTarget.position, getLerp())
    setSpeed(body, CONFIG.combatSpeed - 20)
end

function FlightController.cruise(body)
    local forward = body.Position + body.CFrame.LookVector * 300
    local alt = body.Position.Y
    if alt < CONFIG.preferredAltitude - 50 then
        forward = forward + Vector3.new(0, 60, 0)
    elseif alt > CONFIG.preferredAltitude + 50 then
        forward = forward - Vector3.new(0, 40, 0)
    end
    setHeading(body, forward, getLerp() * 0.6)
    setSpeed(body, CONFIG.cruiseSpeed)
end

-- ============================================================
--  EVASIVE MANEUVERS
-- ============================================================

function FlightController.weave(body, dt)
    _maneuver.weaveClock = (_maneuver.weaveClock or 0) + (dt or 0.05)
    local c = _maneuver.weaveClock
    local freq = (2 * math.pi / CONFIG.weavePeriod)

    -- Horizontal sine wave (left-right)
    local sideOffset = math.sin(c * freq) * CONFIG.weaveAmplitude

    -- Vertical cosine wave at half frequency — creates a figure-8
    -- style path so the bot isn't locked to a flat Y plane.
    -- Clamped so it never weaves into the ground.
    local vertOffset = math.cos(c * freq) * (CONFIG.weaveAmplitude * 1.2)
    local projectedY = body.Position.Y + vertOffset
    if projectedY < CONFIG.minSafeAltitude + 30 then
        vertOffset = math.abs(vertOffset)   -- force upward near ground
    end

    local weaveTarget = body.Position
        + body.CFrame.LookVector * 200
        + body.CFrame.RightVector * sideOffset
        + Vector3.new(0, vertOffset, 0)

    -- Use a human-feeling lerp speed — not too snappy, not laggy.
    -- getLerp() * 0.9 keeps it slightly slower than attack turns
    -- so the motion looks intentional rather than robotic.
    setHeading(body, weaveTarget, getLerp() * 0.9)
    setSpeed(body, CONFIG.evadeSpeed)
end

function FlightController.splitS(body, dt)
    local m = _maneuver
    m.timer = (m.timer or 0) + (dt or 0.05)

    if m.phase == 0 then
        -- Begin rolling — smooth gradual bank, not a snap
        local rollTarget = body.Position
            + body.CFrame.RightVector * 120
            + body.CFrame.LookVector * 80
            - Vector3.new(0, 40, 0)
        setHeading(body, rollTarget, getLerp() * 0.85)  -- was hardcoded 0.18 (too snappy)
        setSpeed(body, CONFIG.evadeSpeed)
        if m.timer > 0.6 then m.phase = 1; m.timer = 0 end

    elseif m.phase == 1 then
        -- Pull through into steep dive — smooth pull, not instant
        local diveTarget = body.Position + body.CFrame.LookVector * 200
                           + Vector3.new(0, CONFIG.splitSDiveDepth, 0)
        diveTarget = Vector3.new(
            diveTarget.X,
            math.max(diveTarget.Y, CONFIG.minSafeAltitude + 30),
            diveTarget.Z
        )
        setHeading(body, diveTarget, getLerp() * 0.75)  -- was hardcoded 0.14
        setSpeed(body, CONFIG.diveSpeed)
        if m.timer > 1.4 then m.phase = 2; m.timer = 0 end

    elseif m.phase == 2 then
        -- Recover — gentle pull back to level
        local recoverTarget = body.Position + body.CFrame.LookVector * 300
                              + Vector3.new(0, 80, 0)
        setHeading(body, recoverTarget, getLerp() * 0.7)
        setSpeed(body, CONFIG.combatSpeed)
        if m.timer > 1.2 then
            m.phase = 0; m.timer = 0; m.type = "none"
        end
    end
end

function FlightController.barrelOffset(body, side, dt)
    _maneuver.weaveClock = (_maneuver.weaveClock or 0) + (dt or 0.05)
    local t = _maneuver.weaveClock
    local offsetRight = body.CFrame.RightVector * (math.sin(t * 3) * CONFIG.weaveAmplitude * (side or 1))
    local offsetUp    = body.CFrame.UpVector    * (math.cos(t * 3) * CONFIG.weaveAmplitude * 0.6)
    local helixTarget = body.Position + body.CFrame.LookVector * 200 + offsetRight + offsetUp
    -- Match human smoothness — slightly slower than combat turns
    setHeading(body, helixTarget, getLerp() * 0.85)
    setSpeed(body, CONFIG.evadeSpeed)
end

-- ============================================================
--  STALL MANEUVERS
--  All three cut the engine, manipulate heading only, then
--  restart. BodyVelocity is zeroed during the stall window so
--  the plane actually bleeds speed instead of coasting.
-- ============================================================

--- Internal: begin a stall. Cuts engine, zeroes velocity.
local function beginStall(body, maneuverTag)
    if _stall.active then return end
    if body.Position.Y < CONFIG.stallMinAltitude then return end
    if not _engineControl then return end

    _stall.active   = true
    _stall.timer    = 0
    _stall.maneuver = maneuverTag

    _engineControl(false)   -- cut engine
    haltVelocity(body)      -- zero thrust so plane actually slows
end

--- Internal: end a stall. Restarts engine.
local function endStall()
    if not _stall.active then return end
    _stall.active   = false
    _stall.timer    = 0
    _stall.maneuver = "none"
    if _engineControl then
        _engineControl(true)
    end
end

--- Must be called every tick (from DefenseSystem or MainBrain Heartbeat).
--- Advances stall timer and ends stall when duration expires.
--- Returns true while a stall is active so callers can suppress
--- normal speed writes.
function FlightController.stallTick(body, dt)
    if not _stall.active then return false end

    _stall.timer = _stall.timer + (dt or 0.05)

    -- Keep velocity zeroed every tick during stall —
    -- without this, BodyVelocity drifts back up from physics.
    haltVelocity(body)

    if _stall.timer >= CONFIG.stallDuration then
        endStall()
    end

    return true  -- stall still active (or just ended this tick)
end

--- Snap turn: cut engine, flick nose onto target, restart.
--- Best used when enemy has just overshot — their momentum
--- carries them into our sights during the stall window.
function FlightController.snapTurn(body, targetPos, dt)
    if not _stall.active then
        beginStall(body, "snap")
    end

    if _stall.active then
        -- Aggressive heading snap toward target during stall —
        -- faster than normal combat lerp since we have no momentum drag
        setHeading(body, targetPos, getLerp() * 1.4)
        haltVelocity(body)
    end
end

--- Stall bait: bleed speed to force an enemy overshoot.
--- Bot slows dramatically then snaps heading as enemy flies past.
--- Transitions automatically into a snap turn at mid-stall.
function FlightController.stallBait(body, targetPos, dt)
    if not _stall.active then
        beginStall(body, "bait")
    end

    if _stall.active then
        local halfDuration = CONFIG.stallDuration * 0.5

        if _stall.timer < halfDuration then
            -- Phase 1: hold heading steady, just bleed speed
            -- Gentle drift forward so we don't look frozen
            local holdTarget = body.Position + body.CFrame.LookVector * 300
            setHeading(body, holdTarget, getLerp() * 0.5)
        else
            -- Phase 2: enemy should be overshooting — snap onto them
            setHeading(body, targetPos, getLerp() * 1.4)
        end

        haltVelocity(body)
    end
end

--- Emergency brake: hard stop when enemy is very close behind.
--- Causes enemy to overshoot, then restart and engage.
function FlightController.emergencyBrake(body, dt)
    if not _stall.active then
        beginStall(body, "brake")
    end

    if _stall.active then
        -- During brake: maintain current heading — don't turn,
        -- just let momentum die. Enemy flies past on their own.
        local holdTarget = body.Position + body.CFrame.LookVector * 300
        setHeading(body, holdTarget, getLerp() * 0.4)  -- barely moving heading
        haltVelocity(body)
    end
end

--- Returns whether a stall is currently active.
function FlightController.isStalling()
    return _stall.active
end

-- ============================================================
--  STATE RESET
-- ============================================================

function FlightController.resetManeuver()
    _maneuver.type       = "none"
    _maneuver.phase      = 0
    _maneuver.timer      = 0
    _maneuver.weaveClock = 0
    -- Also end any active stall cleanly
    if _stall.active and _engineControl then
        _engineControl(true)
    end
    _stall.active   = false
    _stall.timer    = 0
    _stall.maneuver = "none"
end

-- ============================================================
--  INIT
-- ============================================================

function FlightController.init(cfg, engineControl)
    _cfg = cfg or {}
    if _cfg.cruiseSpeed    then CONFIG.cruiseSpeed    = _cfg.cruiseSpeed    end
    if _cfg.combatSpeed    then CONFIG.combatSpeed    = _cfg.combatSpeed    end
    if _cfg.stallDuration  then CONFIG.stallDuration  = _cfg.stallDuration  end
    if _cfg.stallMinAltitude then CONFIG.stallMinAltitude = _cfg.stallMinAltitude end

    -- engineControl(bool) callback — provided by MainBrain
    _engineControl = engineControl or nil

    FlightController.resetManeuver()
end

return FlightController
