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
    type      = "none",   -- current maneuver tag
    phase     = 0,        -- step counter within maneuver
    timer     = 0,        -- elapsed time in current maneuver
    weaveDir  = 1,        -- oscillation direction for weave
    weaveClock = 0,
}

-- ============================================================
--  CONFIG (overridden partially by MainBrain.init)
-- ============================================================
local CONFIG = {
    -- Turning
    gyroDampening     = 0.8,    -- BodyGyro D (smoothness)
    gyroMaxTorque     = 5e5,

    -- Speed
    cruiseSpeed       = 120,    -- studs/s during patrol
    combatSpeed       = 180,    -- studs/s during engagement
    climbSpeed        = 140,
    diveSpeed         = 220,
    evadeSpeed        = 200,
    disengageSpeed    = 200,

    -- Turn smoothing (lerp factor per Heartbeat at 60 fps)
    headingLerpFast   = 0.12,   -- snappy turns (Elite)
    headingLerpSlow   = 0.05,   -- smooth turns (Easy)

    -- Altitude management
    minSafeAltitude   = 80,     -- below this → pull up
    maxAltitude       = 800,
    preferredAltitude = 350,

    -- Intercept lead coefficient (larger = more lead)
    leadCoeff         = 1.2,

    -- Weave
    weaveAmplitude    = 40,     -- stud offset side-to-side
    weavePeriod       = 1.4,    -- seconds per full weave cycle

    -- Barrel roll / Split-S
    splitSDiveDepth   = -120,   -- stud drop in split-S

    -- Bomb approach
    bombApproachAlt   = 300,    -- altitude above target for bomb run
    bombRunSpeed      = 160,
}

-- ============================================================
--  INTERNAL: BodyGyro / BodyVelocity writes
-- ============================================================

--- Set heading toward a world-space target position.
--- lerpFactor (0-1): how fast to rotate each frame.
local function setHeading(body, targetPos, lerpFactor)
	local gyro = body:FindFirstChild("BodyGyro")
	if not gyro then return end

	local desired = CFrame.new(body.Position, targetPos)

	if gyro:IsA("BodyGyro") then
		gyro.CFrame = gyro.CFrame:Lerp(
			desired,
			lerpFactor or CONFIG.headingLerpFast
		)

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

--- Set forward thrust speed.
local function setSpeed(body, speed)
	local vel = body:FindFirstChild("BodyVelocity")
	if not vel then return end

	local moveDir = body.CFrame.LookVector * speed

	if vel:IsA("BodyVelocity") then
		vel.Velocity = moveDir
		vel.MaxForce = Vector3.new(1e5,1e5,1e5)

	elseif vel:IsA("LinearVelocity") then
		vel.VectorVelocity = moveDir
		vel.MaxForce = 1e5
	end
end

--- Stop all thrust.
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

--- Returns where to aim / fly to intercept a moving target.
--- targetPos : Vector3 (current target position)
--- targetVel : Vector3 (target velocity, studs/s)
--- myPos     : Vector3
--- mySpeed   : number (studs/s)
local function predictIntercept(targetPos, targetVel, myPos, mySpeed)
    local relPos = targetPos - myPos
    local dist   = relPos.Magnitude
    local t      = (dist / math.max(mySpeed, 1)) * CONFIG.leadCoeff
    return targetPos + targetVel * t
end

-- ============================================================
--  INTERNAL: Altitude correction offset
-- ============================================================

--- Returns a vertical correction nudge to keep bot above min altitude.
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

--- Intercept and chase a target with predictive lead.
--- Called every tick while in "attack" phase.
function FlightController.intercept(body, targetPos, targetVel)
    targetVel = targetVel or Vector3.zero
    local intercept = predictIntercept(
        targetPos, targetVel, body.Position, CONFIG.combatSpeed
    )
    -- Altitude correction blended in
    local correction = altitudeCorrection(body)
    local aimPos = intercept + correction
    setHeading(body, aimPos, getLerp())
    setSpeed(body, CONFIG.combatSpeed)
end

--- Approach for a bomb run at high altitude above target.
function FlightController.approachBomb(body, targetPos)
    local bombPos = targetPos + Vector3.new(0, CONFIG.bombApproachAlt, 0)
    setHeading(body, bombPos, getLerp())
    setSpeed(body, CONFIG.bombRunSpeed)
end

--- Climb to regain energy / altitude advantage.
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

--- Power dive — lose altitude fast, gain speed.
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

--- Disengage: turn away from enemy and build distance.
function FlightController.disengage(body, percept)
    local awayDir = body.CFrame.LookVector  -- default: keep heading
    if percept and percept.primaryTarget then
        awayDir = (body.Position - percept.primaryTarget.position).Unit
    end
    local fleeTarget = body.Position + awayDir * 500
    setHeading(body, fleeTarget, getLerp())
    setSpeed(body, CONFIG.disengageSpeed)
end

--- Reset to optimal engagement distance (~600-800 studs from target).
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

--- Ambush approach: low/high angle attack from outside FOV cone.
--- Tries to approach from above or behind.
function FlightController.ambush(body, targetPos)
    -- Come from high above and slightly behind target's assumed heading
    local offset  = Vector3.new(0, 250, 0)
    local approach = targetPos + offset
    setHeading(body, approach, getLerp() * 0.8)   -- slightly slower turn = sneakier
    setSpeed(body, CONFIG.combatSpeed)
end

--- Bait: fly past the enemy to bait an overshoot, then reverse.
function FlightController.bait(body, percept)
    if not percept or not percept.primaryTarget then
        FlightController.cruise(body)
        return
    end
    -- Fly directly at enemy to bait, then a subsequent tick will pick evade/attack
    local toward = percept.primaryTarget.position
    setHeading(body, toward, getLerp())
    setSpeed(body, CONFIG.combatSpeed - 20)   -- slightly slower = more believable
end

--- Gentle cruise (idle / no target).
function FlightController.cruise(body)
    local forward = body.Position + body.CFrame.LookVector * 300
    local alt = body.Position.Y
    -- Drift toward preferred altitude if too low/high
    if alt < CONFIG.preferredAltitude - 50 then
        forward = forward + Vector3.new(0, 60, 0)
    elseif alt > CONFIG.preferredAltitude + 50 then
        forward = forward - Vector3.new(0, 40, 0)
    end
    setHeading(body, forward, getLerp() * 0.6)
    setSpeed(body, CONFIG.cruiseSpeed)
end

-- ============================================================
--  EVASIVE MANEUVERS (called by DefenseSystem too)
-- ============================================================

--- Oscillating weave — side-to-side to throw off aim.
--- Call every tick while threat is behind.
function FlightController.weave(body, dt)
    _maneuver.weaveClock = (_maneuver.weaveClock or 0) + (dt or 0.05)
    local sideOffset = math.sin(_maneuver.weaveClock * (2 * math.pi / CONFIG.weavePeriod))
                       * CONFIG.weaveAmplitude
    local right = body.CFrame.RightVector
    local forward = body.Position + body.CFrame.LookVector * 200
    local weaveTarget = forward + right * sideOffset

    setHeading(body, weaveTarget, getLerp() * 1.2)   -- slightly snappier than normal
    setSpeed(body, CONFIG.evadeSpeed)
end

--- Split-S: half roll and pull through into a dive.
--- Phases: 0=roll, 1=pull, 2=recover
function FlightController.splitS(body, dt)
    local m = _maneuver
    m.timer = (m.timer or 0) + (dt or 0.05)

    if m.phase == 0 then
        -- Roll 180° (simulate with a sharp right/left heading twist)
        local rollTarget = body.Position + body.CFrame.RightVector * 100
                           - Vector3.new(0, 30, 0)
        setHeading(body, rollTarget, 0.18)
        setSpeed(body, CONFIG.evadeSpeed)
        if m.timer > 0.5 then m.phase = 1; m.timer = 0 end

    elseif m.phase == 1 then
        -- Pull through into steep dive
        local diveTarget = body.Position + body.CFrame.LookVector * 200
                           + Vector3.new(0, CONFIG.splitSDiveDepth, 0)
        diveTarget = Vector3.new(
            diveTarget.X,
            math.max(diveTarget.Y, CONFIG.minSafeAltitude + 30),
            diveTarget.Z
        )
        setHeading(body, diveTarget, 0.14)
        setSpeed(body, CONFIG.diveSpeed)
        if m.timer > 1.2 then m.phase = 2; m.timer = 0 end

    elseif m.phase == 2 then
        -- Recover to level flight
        local recoverTarget = body.Position + body.CFrame.LookVector * 300
                              + Vector3.new(0, 60, 0)
        setHeading(body, recoverTarget, getLerp())
        setSpeed(body, CONFIG.combatSpeed)
        if m.timer > 1.0 then
            -- Maneuver complete — reset
            m.phase = 0; m.timer = 0; m.type = "none"
        end
    end
end

--- Barrel roll style offset (not a true roll — CFrame offset weave).
--- Pass `side`: 1 or -1 for direction.
function FlightController.barrelOffset(body, side, dt)
    _maneuver.weaveClock = (_maneuver.weaveClock or 0) + (dt or 0.05)
    local t = _maneuver.weaveClock
    local right   = body.CFrame.RightVector
    local up      = body.CFrame.UpVector
    local forward = body.CFrame.LookVector

    -- Helix-like offset
    local offsetRight = right * (math.sin(t * 3) * CONFIG.weaveAmplitude * (side or 1))
    local offsetUp    = up    * (math.cos(t * 3) * CONFIG.weaveAmplitude * 0.5)

    local helixTarget = body.Position + forward * 200 + offsetRight + offsetUp
    setHeading(body, helixTarget, getLerp() * 1.1)
    setSpeed(body, CONFIG.evadeSpeed)
end

-- ============================================================
--  STATE RESET
-- ============================================================

--- Reset maneuver state (call when switching tactics).
function FlightController.resetManeuver()
    _maneuver.type      = "none"
    _maneuver.phase     = 0
    _maneuver.timer     = 0
    _maneuver.weaveClock = 0
end

-- ============================================================
--  INIT
-- ============================================================

function FlightController.init(cfg)
    _cfg = cfg or {}

    -- Override CONFIG from passed-in config keys if present
    if _cfg.cruiseSpeed   then CONFIG.cruiseSpeed   = _cfg.cruiseSpeed   end
    if _cfg.combatSpeed   then CONFIG.combatSpeed   = _cfg.combatSpeed   end
    if _cfg.fovRadius     then end  -- not needed here, used in Perception

    FlightController.resetManeuver()
end
print(body.BodyGyro.ClassName)
print(body.BodyVelocity.ClassName)
return FlightController
