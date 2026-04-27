-- ============================================================
--  PerceptionSystem.lua  (STUB — expand in next pass)
--  Snapshots the game world around the bot.
-- ============================================================

local Players  = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local PerceptionSystem = {}
local _cfg = {}

-- ── Team detection ──────────────────────────────────────────
local function getEnemyTeam()
    -- If a specific teamName is configured, use it.
    -- Otherwise return the team the LocalPlayer is NOT on.
    local myTeam = LocalPlayer.Team
    for _, team in ipairs(game:GetService("Teams"):GetTeams()) do
        if team ~= myTeam then return team end
    end
    return nil
end

local function isEnemy(player)
    if player == LocalPlayer then return false end
    local enemyTeam = getEnemyTeam()
    if enemyTeam then
        return player.Team == enemyTeam
    end
    -- Fallback: everyone is an enemy
    return true
end

-- ── Vehicle finders (mirrors your existing helpers) ─────────
local function getVehicle(vehicleName, playerName)
    for _, v in ipairs(workspace:GetChildren()) do
        if v.Name == vehicleName then
            local owner = v:FindFirstChild("Owner")
            if owner and owner.Value == playerName then return v end
        end
    end
end

local function getMainBody(vehicle)
    if not vehicle then return end
    for _, x in ipairs(vehicle:GetDescendants()) do
        if x:IsA("BasePart")
           and x:FindFirstChild("BodyGyro")
           and x:FindFirstChild("BodyVelocity") then
            return x
        end
    end
end

-- ── Main snapshot ───────────────────────────────────────────
function PerceptionSystem.snapshot(cfg)
    local percept = {
        selfBody      = nil,
        selfPos       = Vector3.zero,
        selfVel       = Vector3.zero,
        selfAltitude  = 0,
        targets       = {},
        primaryTarget = nil,
        threats       = {},
        ammoReady     = true,   -- TODO: hook into actual cooldown state
        bombReady     = true,
    }

    -- ── Self ──────────────────────────────────────────────
    local myVehicle = getVehicle(cfg.vehicleName, LocalPlayer.Name)
    local myBody    = getMainBody(myVehicle)
    if not myBody then return percept end

    percept.selfBody     = myBody
    percept.selfPos      = myBody.Position
    percept.selfVel      = myBody.AssemblyLinearVelocity
    percept.selfAltitude = myBody.Position.Y

    -- ── Scan enemies within FOV radius ────────────────────
    local fov = cfg.fovRadius or 2000
    local closestDist = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isEnemy(player) then
            local enemyVehicle = getVehicle(cfg.vehicleName, player.Name)
            -- Also check any vehicle the enemy is in
            local enemyBody = getMainBody(enemyVehicle)

            if enemyBody then
                local dist = (enemyBody.Position - myBody.Position).Magnitude
                if dist <= fov then
                    local relAngle = math.deg(math.acos(
                        clampDot(myBody.CFrame.LookVector:Dot(
                            (enemyBody.Position - myBody.Position).Unit
                        ))
                    ))

                    local targetInfo = {
                        player   = player,
                        position = enemyBody.Position,
                        velocity = enemyBody.AssemblyLinearVelocity,
                        distance = dist,
                        altitude = enemyBody.Position.Y,
                        altDiff  = enemyBody.Position.Y - myBody.Position.Y,
                        angle    = relAngle,   -- degrees off nose
                    }
                    table.insert(percept.targets, targetInfo)

                    if dist < closestDist then
                        closestDist = dist
                        percept.primaryTarget = targetInfo
                    end
                end
            end
        end
    end

    -- ── Threat scan (enemies behind us) ───────────────────
    for _, t in ipairs(percept.targets) do
        local toEnemy = (t.position - myBody.Position).Unit
        local dot = myBody.CFrame.LookVector:Dot(toEnemy)
        if dot < -0.3 then  -- ~100 ° behind us
            table.insert(percept.threats, t)
        end
    end

    return percept
end

function clampDot(d)
    return math.max(-1, math.min(1, d))
end

function PerceptionSystem.init(cfg)
    _cfg = cfg or {}
end

return PerceptionSystem
