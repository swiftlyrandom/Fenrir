-- ============================================================
--  PerceptionSystem.lua
--  Snapshots the world around the bot every decision tick.
--  Scans all three plane types, filters to enemy team only,
--  within the configured FOV radius.
-- ============================================================

local Players = game:GetService("Players")
local Teams   = game:GetService("Teams")

local PerceptionSystem = {}
local _cfg = {}

-- Stores previous velocity per player for acceleration estimation
-- prevVel[player] = { vel: Vector3, time: number }
local _prevVel = {}

-- ── All recognised plane names ───────────────────────────────
local PLANE_NAMES = {
    ["Bomber"]         = true,
    ["Torpedo Bomber"] = true,
    ["Large Bomber"]   = true,
}

-- ============================================================
--  HELPERS
-- ============================================================

local function clampDot(d)
    return math.max(-1, math.min(1, d))
end

--- Returns the enemy team relative to LocalPlayer.
local function getEnemyTeam(localPlayer)
    if _cfg.teamName then
        for _, team in ipairs(Teams:GetTeams()) do
            if team.Name == _cfg.teamName then return team end
        end
    end
    local myTeam = localPlayer.Team
    for _, team in ipairs(Teams:GetTeams()) do
        if team ~= myTeam then return team end
    end
    return nil
end

--- True if `player` is on the enemy team.
local function isEnemy(player, localPlayer, enemyTeam)
    if player == localPlayer then return false end
    if enemyTeam then
        return player.Team == enemyTeam
    end
    return true  -- no teams = FFA, everyone is enemy
end

--- Find a vehicle in workspace owned by `ownerName`.
--- Checks all three plane types.
local function findVehicle(ownerName)
    for _, obj in ipairs(workspace:GetChildren()) do
        if PLANE_NAMES[obj.Name] then
            local owner = obj:FindFirstChild("Owner")
            if owner and owner.Value == ownerName then
                return obj
            end
        end
    end
    return nil
end

--- Find the main controllable body inside a vehicle.
--- Identified by having both BodyGyro and BodyVelocity.
local function getMainBody(vehicle)
    if not vehicle then return nil end
    for _, part in ipairs(vehicle:GetDescendants()) do
        if part:IsA("BasePart")
            and part:FindFirstChild("BodyGyro")
            and part:FindFirstChild("BodyVelocity") then
            return part
        end
    end
    return nil
end

-- ============================================================
--  SNAPSHOT
-- ============================================================

function PerceptionSystem.snapshot(cfg)
    local localPlayer = Players.LocalPlayer

    local percept = {
        selfBody      = nil,
        selfPos       = Vector3.zero,
        selfVel       = Vector3.zero,
        selfAltitude  = 0,
        targets       = {},
        primaryTarget = nil,
        threats       = {},
        ammoReady     = true,
        bombReady     = true,
    }

    -- Locate bot's own vehicle
    local myVehicle = findVehicle(localPlayer.Name)
    local myBody    = getMainBody(myVehicle)
    if not myBody then return percept end

    percept.selfBody     = myBody
    percept.selfPos      = myBody.Position
    percept.selfVel      = myBody.AssemblyLinearVelocity
    percept.selfAltitude = myBody.Position.Y

    local enemyTeam = getEnemyTeam(localPlayer)
    local fovRadius = (cfg and cfg.fovRadius) or _cfg.fovRadius or 2000
    local closestDist = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isEnemy(player, localPlayer, enemyTeam) then
            local enemyBody = getMainBody(findVehicle(player.Name))

            if enemyBody then
                local ePos = enemyBody.Position
                local dist = (ePos - myBody.Position).Magnitude

                if dist <= fovRadius then
                    local toEnemy  = (ePos - myBody.Position).Unit
                    local dot      = clampDot(myBody.CFrame.LookVector:Dot(toEnemy))
                    local angle    = math.deg(math.acos(dot))
                    local isBehind = dot < -0.2

                    local eVel = enemyBody.AssemblyLinearVelocity
                    local now  = tick()

                    -- Derive acceleration from velocity delta since last snapshot
                    local accel = nil
                    local prev  = _prevVel[player]
                    if prev then
                        local dt = now - prev.time
                        if dt > 0 and dt < 0.5 then  -- ignore stale entries
                            accel = (eVel - prev.vel) / dt
                        end
                    end
                    _prevVel[player] = { vel = eVel, time = now }

                    local targetInfo = {
                        player       = player,
                        position     = ePos,
                        velocity     = eVel,
                        acceleration = accel,   -- Vector3 or nil
                        distance     = dist,
                        altitude     = ePos.Y,
                        altDiff      = ePos.Y - myBody.Position.Y,
                        angle        = angle,
                        isBehind     = isBehind,
                    }

                    table.insert(percept.targets, targetInfo)

                    if dist < closestDist then
                        closestDist           = dist
                        percept.primaryTarget = targetInfo
                    end

                    if isBehind then
                        table.insert(percept.threats, targetInfo)
                    end
                end
            end
        end
    end

    return percept
end

function PerceptionSystem.init(cfg)
    _cfg = cfg or {}
    _prevVel = {}
end

return PerceptionSystem
