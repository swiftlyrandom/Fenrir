-- ============================================================
--  WeaponSystem.lua
--  Predictive aiming, confidence-gated firing, bomb drops.
-- ============================================================
local WeaponSystem = {}

local _fireEvent = nil
local _cfg       = {}

-- ── Cooldown state ───────────────────────────────────────────
local _shooting  = false
local _bombTimer = 0
local BOMB_COOLDOWN = 8  -- seconds between bomb drops

-- ── Confidence thresholds (by difficulty) ───────────────────
local CONF_THRESHOLD = {
    Easy   = 0.85,  -- only fires with very high confidence
    Medium = 0.70,
    Hard   = 0.55,
    Elite  = 0.40,
}

--- Predict where a moving target will be after travel time.
local function predictAimPoint(selfPos, targetPos, targetVel, bulletSpeed)
    bulletSpeed = bulletSpeed or 1800  -- 1800 studs/s (matches your 1800 stud limit)
    local dist  = (targetPos - selfPos).Magnitude
    local t     = dist / bulletSpeed
    return targetPos + targetVel * t
end

--- Angle (degrees) between our look vector and target direction.
local function aimError(body, aimPos)
    local toTarget = (aimPos - body.Position).Unit
    local dot = math.max(-1, math.min(1, body.CFrame.LookVector:Dot(toTarget)))
    return math.deg(math.acos(dot))
end

--- Confidence score: 1.0 = perfectly on target, 0.0 = way off.
local function calcConfidence(error_deg)
    -- Linear falloff: 0° = 1.0, 5° = 0.0
    return math.max(0, 1 - error_deg / 5)
end

--- Attempt to fire guns if confidence is high enough.
function WeaponSystem.tryShoot(percept, diff)
    if not percept.primaryTarget then return end
    if not percept.ammoReady     then return end
    if not _fireEvent             then return end

    local body     = percept.selfBody
    local target   = percept.primaryTarget
    local aimPos   = predictAimPoint(body.Position, target.position, target.velocity)
    local err      = aimError(body, aimPos)
    local conf     = calcConfidence(err)
    local threshold = CONF_THRESHOLD[_cfg.difficulty] or 0.55

    if conf >= threshold then
        if not _shooting then
            _fireEvent("shoot", { true })
            _shooting = true
        end
    else
        if _shooting then
            _fireEvent("shoot", { false })
            _shooting = false
        end
    end
end

--- Stop all firing (call on bot stop or disengage).
function WeaponSystem.stopFiring()
    if _shooting and _fireEvent then
        _fireEvent("shoot", { false })
    end
    _shooting = false
end

--- Attempt a bomb drop if hit window is good.
function WeaponSystem.tryBomb(percept)
    if not percept.bombReady then return end
    if _bombTimer > 0        then return end
    -- TODO: implement actual bomb drop event call when you have the event name
    -- _fireEvent("dropBomb", { ... })
    _bombTimer = BOMB_COOLDOWN
    warn("[WeaponSystem] Bomb drop triggered (add your bomb event here).")
end

--- Decrement bomb cooldown each tick (call from MainBrain or Heartbeat).
function WeaponSystem.tick(dt)
    if _bombTimer > 0 then
        _bombTimer = math.max(0, _bombTimer - dt)
    end
end

function WeaponSystem.init(cfg, fireEvent)
    _cfg       = cfg or {}
    _fireEvent = fireEvent
    _shooting  = false
    _bombTimer = 0
end

return WeaponSystem
