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

local Players = game:GetService("Players")

-- ── Confidence thresholds (by difficulty) ───────────────────
local CONF_THRESHOLD = {
    Easy   = 0.70,
    Medium = 0.55,
    Hard   = 0.35,
    Elite  = 0.48,
}

-- ── Aim config ───────────────────────────────────────────────
-- estimatedPingMs: conservative ping estimate for the bot's
-- client. Roblox adds ~half RTT of latency before the server
-- sees the FireServer call and spawns the bullet.
-- Tune this to match your server's typical player ping.
-- 80ms is a reasonable default for a same-region bot account.
local AIM_CONFIG = {
    bulletSpeed     = 600,   -- studs/s — match your game's bullet speed
    estimatedPingMs = 80,     -- ms — bot client -> server round trip estimate
    accelLookAhead  = 0.08,   -- seconds of target acceleration to sample
}

--- Predict where a moving target will be, accounting for:
---   1. Bullet travel time (dist / bulletSpeed)
---   2. Server-side ping delay (bullet spawns after FireServer latency)
---   3. Target acceleration approximation (velocity delta over short window)
local function predictAimPoint(selfPos, targetPos, targetVel, targetAccel)
    local bulletSpeed = AIM_CONFIG.bulletSpeed
    local pingSec     = AIM_CONFIG.estimatedPingMs / 1000

    local dist = (targetPos - selfPos).Magnitude

    -- Time for bullet to travel to where the target currently is
    local travelTime = dist / bulletSpeed

    -- Total lead time = bullet travel + half ping (one-way server latency)
    -- We use half RTT because FireServer takes ~half the round trip
    -- before the server processes the shot.
    local totalLead = travelTime + (pingSec * 0.5)

    -- Apply velocity lead
    local leadPos = targetPos + targetVel * totalLead

    -- Apply acceleration if available (improves aim on turning targets)
    if targetAccel then
        leadPos = leadPos + targetAccel * (totalLead * totalLead * 0.5)
    end

    return leadPos
end

--- Angle (degrees) between our look vector and target direction.
local function aimError(body, aimPos)
    local toTarget = (aimPos - body.Position).Unit
    local dot = math.max(-1, math.min(1, body.CFrame.LookVector:Dot(toTarget)))
    return math.deg(math.acos(dot))
end

--- Confidence score: 1.0 = perfectly on target, 0.0 = way off.
local function calcConfidence(error_deg)
    return math.max(0, 1 - error_deg / 30)
end

--- Attempt to fire guns if confidence is high enough.
function WeaponSystem.tryShoot(percept, diff)
    if not percept.primaryTarget then return end
    if not percept.ammoReady     then return end
    if not _fireEvent             then return end

    local body   = percept.selfBody
    local target = percept.primaryTarget

    -- Pass target acceleration if PerceptionSystem tracked it
    -- (targetAccel will be nil if not yet implemented — that's fine,
    --  predictAimPoint handles nil gracefully)
    local aimPos  = predictAimPoint(
        body.Position,
        target.position,
        target.velocity,
        target.acceleration   -- nil until PerceptionSystem tracks it
    )

    local err     = aimError(body, aimPos)
    local conf    = calcConfidence(err)
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
    -- Allow ping override from BOT_CONFIG
    if _cfg.estimatedPingMs then
        AIM_CONFIG.estimatedPingMs = _cfg.estimatedPingMs
    end
    if _cfg.bulletSpeed then
        AIM_CONFIG.bulletSpeed = _cfg.bulletSpeed
    end
end

return WeaponSystem
