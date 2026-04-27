-- MainBrain.lua
-- The only module that owns RunService connections.
-- Orchestrates all other systems in strict order each tick.

local RunService     = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Module imports (adjust paths to match your folder structure)
local BotState           = require(script.Parent.BotState)
local DifficultyController = require(script.Parent.DifficultyController)
local PerceptionSystem   = require(script.Parent.PerceptionSystem)
local LearningSystem     = require(script.Parent.LearningSystem)
local OpponentModel      = require(script.Parent.OpponentModel)
local TacticalEvaluator  = require(script.Parent.TacticalEvaluator)
local FlightController   = require(script.Parent.FlightController)
local WeaponSystem       = require(script.Parent.WeaponSystem)
local DefenseSystem      = require(script.Parent.DefenseSystem)

-- Remote event used by WeaponSystem and engine control
local Event = ReplicatedStorage:WaitForChild("Event")

----------------------------------------------------
-- VEHICLE HELPERS  (identical to your provided code)
----------------------------------------------------
local VEHICLE_NAME = "Large Bomber"
local Players      = game:GetService("Players")
local LocalPlayer  = Players.LocalPlayer

local function getVehicle()
    for _, v in ipairs(workspace:GetChildren()) do
        if v.Name == VEHICLE_NAME then
            local owner = v:FindFirstChild("Owner")
            if owner and owner.Value == LocalPlayer.Name then
                return v
            end
        end
    end
end

local function getMainBody(vehicle)
    if not vehicle then return nil end
    for _, x in ipairs(vehicle:GetDescendants()) do
        if x:IsA("BasePart") then
            if x:FindFirstChild("BodyGyro") and x:FindFirstChild("BodyVelocity") then
                return x
            end
        end
    end
end

----------------------------------------------------
-- ENGINE CONTROL
----------------------------------------------------
local function startEngine(state)
    -- Args match your provided startEngine remote: throttle, pitch, something
    Event:FireServer("startEngine", { 8652.419607067108, 1.2, 40 })
    state.engineRunning = true
end

local function stopEngine(state)
    Event:FireServer("stopEngine")
    state.engineRunning = false
end

----------------------------------------------------
-- MAINBRAIN
----------------------------------------------------
local MainBrain = {}

function MainBrain.start(difficultyLevel)
    local state = BotState.new()

    -- 1. Apply difficulty settings before anything else
    DifficultyController.apply(state, difficultyLevel or "Hard")

    -- 2. Wait for vehicle to appear in workspace
    local waitStart = tick()
    repeat
        state.vehicle   = getVehicle()
        state.mainBody  = getMainBody(state.vehicle)
        task.wait(0.5)
    until (state.mainBody ~= nil) or (tick() - waitStart > 15)

    if not state.mainBody then
        warn("[MainBrain] Could not find vehicle mainBody after 15s. Aborting.")
        return
    end

    -- 3. Start engine
    startEngine(state)
    task.wait(1.0)  -- give engine a moment to spool up

    -- 4. Find initial target (first enemy player with a vehicle)
    state.targetEnemy = MainBrain._findBestTarget(state)

    -- 5. Main decision loop
    RunService.Heartbeat:Connect(function(dt)
        local now = tick()

        -- Throttle to configured loop interval
        if (now - state.timing.lastLoopTime) < state.difficulty.loopInterval then
            return
        end
        state.timing.deltaTime    = now - state.timing.lastLoopTime
        state.timing.lastLoopTime = now

        -- Safety: re-acquire vehicle if lost (respawn case)
        if not state.mainBody or not state.mainBody.Parent then
            state.vehicle  = getVehicle()
            state.mainBody = getMainBody(state.vehicle)
            if not state.mainBody then return end
            startEngine(state)
        end

        -- Refresh target if lost
        if not state.targetEnemy or not state.targetEnemy.Character then
            state.targetEnemy = MainBrain._findBestTarget(state)
        end
        if not state.targetEnemy then return end  -- no valid target, idle

        -- ============================================================
        -- SENSE → ANALYZE → SCORE → CHOOSE → EXECUTE → REEVALUATE
        -- ============================================================

        -- SENSE
        PerceptionSystem.update(state)

        -- ANALYZE (opponent learning, runs on its own slower interval)
        if (now - state.timing.lastLearnTime) >= state.timing.learnInterval then
            LearningSystem.observe(state)
            OpponentModel.recompute(state)
            state.timing.lastLearnTime = now
        end

        -- SCORE + CHOOSE
        TacticalEvaluator.evaluate(state)

        -- EXECUTE
        -- Defense can override flight heading — run it first
        DefenseSystem.update(state)

        -- Flight and weapons run after defense has had its say
        FlightController.update(state)
        WeaponSystem.update(state, Event)

        -- REEVALUATE
        -- Decay actionHoldTimer so TacticalEvaluator can switch actions
        if state.tactical.actionHoldTimer > 0 then
            state.tactical.actionHoldTimer = state.tactical.actionHoldTimer - state.timing.deltaTime
        end
    end)
end

-- Scans all players, returns the one closest to us with a live vehicle
function MainBrain._findBestTarget(state)
    local bestPlayer = nil
    local bestDist   = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        -- Try to find their vehicle mainBody
        for _, v in ipairs(workspace:GetChildren()) do
            if v.Name == VEHICLE_NAME then
                local owner = v:FindFirstChild("Owner")
                if owner and owner.Value == player.Name then
                    local body = getMainBody(v)
                    if body then
                        local dist = (body.Position - state.mainBody.Position).Magnitude
                        if dist < bestDist then
                            bestDist   = dist
                            bestPlayer = player
                        end
                    end
                end
            end
        end
    end

    return bestPlayer
end

-- Clean shutdown (call if bot is destroyed mid-game)
function MainBrain.stop(state)
    stopEngine(state)
end

return MainBrain
