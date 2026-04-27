-- ============================================================
--  MainBrain.lua (FIXED)
--  Top-level orchestrator
-- ============================================================

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

------------------------------------------------------------
-- MODULE LOADER
------------------------------------------------------------
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

------------------------------------------------------------
-- REMOTE
------------------------------------------------------------
local Event = ReplicatedStorage:WaitForChild("Event")

local function fireEvent(...)
	Event:FireServer(...)
end

------------------------------------------------------------
-- MODULE
------------------------------------------------------------
local MainBrain = {}

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local _running = false
local _loopConn = nil
local _accumulator = 0
local _engineRunning = false
local _config = {}

------------------------------------------------------------
-- DEFAULTS
------------------------------------------------------------
local DEFAULTS = {
	difficulty = "Hard",
	vehicleName = "Large Bomber",
	teamName = nil,

	fovRadius = 2000,

	tickMin = 0.10,
	tickMax = 0.25,

	engineSpeed = 8652.419607067108,
	engineThrottle = 1.2,
	engineAltitude = 40,

	debugPrint = false,
}

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function log(...)
	if _config.debugPrint then
		print("[MainBrain]", ...)
	end
end

local function getTickInterval(urgency)
	local diff = DifficultyController.get(_config.difficulty)

	local minTick = _config.tickMin * diff.reactionMult
	local maxTick = _config.tickMax * diff.reactionMult

	return minTick + (maxTick - minTick) * (1 - urgency)
end

------------------------------------------------------------
-- ENGINE
------------------------------------------------------------
local function startEngine()
	if _engineRunning then return end

	fireEvent("startEngine", {
		_config.engineSpeed,
		_config.engineThrottle,
		_config.engineAltitude
	})

	_engineRunning = true
	log("Engine started")
end

local function stopEngine()
	if not _engineRunning then return end

	fireEvent("stopEngine")
	_engineRunning = false

	log("Engine stopped")
end

------------------------------------------------------------
-- PHASES
------------------------------------------------------------
local function sense()
	return PerceptionSystem.snapshot({
		vehicleName = _config.vehicleName,
		fovRadius = _config.fovRadius,
		teamName = _config.teamName,
	})
end

local function analyze(percept)
	if percept.primaryTarget then
		OpponentModel.observe(percept.primaryTarget)
		percept.opponentProfile =
			OpponentModel.getProfile(percept.primaryTarget.player)
	end

	return percept
end

local function scoreActions(percept)
	local diff = DifficultyController.get(_config.difficulty)
	return TacticalEvaluator.evaluate(percept, diff)
end

local function chooseAction(ranked)
	local diff = DifficultyController.get(_config.difficulty)
	local noise = diff.choiceNoise

	if #ranked == 0 then
		return "idle"
	end

	if #ranked >= 2 and math.random() < noise then
		return ranked[2].action
	end

	return ranked[1].action
end

local function execute(action, percept)
	local body = percept.selfBody
	if not body then return end

	if action == "attack" then
		FlightController.intercept(body, percept.primaryTarget.position)

	elseif action == "bomb_run" then
		FlightController.approachBomb(body, percept.primaryTarget.position)
		WeaponSystem.tryBomb(percept)

	elseif action == "climb" then
		FlightController.climb(body)

	elseif action == "dive" then
		FlightController.dive(body)

	elseif action == "disengage" then
		FlightController.disengage(body, percept)

	elseif action == "reset_distance" then
		FlightController.resetDistance(
			body,
			percept.primaryTarget and percept.primaryTarget.position
		)

	elseif action == "ambush" then
		FlightController.ambush(body, percept.primaryTarget.position)

	elseif action == "bait" then
		FlightController.bait(body, percept)

	elseif action == "evade" then
		DefenseSystem.evade(body, percept)

	else
		FlightController.cruise(body)
	end

	if percept.primaryTarget and action ~= "evade" and action ~= "disengage" then
		WeaponSystem.tryShoot(
			percept,
			DifficultyController.get(_config.difficulty)
		)
	end

	DefenseSystem.checkPassive(body, percept)
end

local function reevaluate(action, percept)
	LearningSystem.record(action, percept)
	BotState.update(action, percept)
end

------------------------------------------------------------
-- MAIN LOOP (RENAMED FROM tick)
------------------------------------------------------------
local function brainTick(dt)
	if not dt then return end

	local urgency = BotState.getUrgency()
	local interval = getTickInterval(urgency)

	_accumulator += dt

	if _accumulator < interval then
		return
	end

	_accumulator = 0

	local ok, err = pcall(function()
		local percept = sense()

		if not percept or not percept.selfBody then
			return
		end

		percept = analyze(percept)

		local ranked = scoreActions(percept)
		local action = chooseAction(ranked)

		log(
			"Action:",
			action,
			"| Target:",
			percept.primaryTarget
				and percept.primaryTarget.player.Name
				or "none"
		)

		execute(action, percept)
		reevaluate(action, percept)
	end)

	if not ok then
		warn("[MainBrain] Tick Error:", err)
	end
end

------------------------------------------------------------
-- API
------------------------------------------------------------
function MainBrain.init(cfg)
	_config = setmetatable(cfg or {}, {
		__index = DEFAULTS
	})

	-- FIXED RNG SEED
	math.randomseed(os.clock() * 100000)

	DifficultyController.init(_config.difficulty)
	FlightController.init(_config)
	WeaponSystem.init(_config, fireEvent)
	DefenseSystem.init(_config)
	PerceptionSystem.init(_config)
	OpponentModel.init()
	TacticalEvaluator.init(_config)
	LearningSystem.init()
	BotState.init()

	log("Initialized")
end

function MainBrain.start()
	if _running then return end
	_running = true

	startEngine()

	_loopConn = RunService.Heartbeat:Connect(function(dt)
		brainTick(dt)
	end)

	log("Started")
end

function MainBrain.stop()
	if not _running then return end
	_running = false

	if _loopConn then
		_loopConn:Disconnect()
		_loopConn = nil
	end

	stopEngine()
	WeaponSystem.stopFiring()

	log("Stopped")
end

function MainBrain.setDifficulty(level)
	_config.difficulty = level
	DifficultyController.init(level)
end

function MainBrain.getConfig()
	return _config
end

return MainBrain
