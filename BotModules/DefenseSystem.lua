-- ============================================================
--  DefenseSystem.lua
--  Reactive and passive defensive behaviors.
-- ============================================================
local DefenseSystem  = {}
local FlightController  -- set in init to avoid circular require

local _cfg = {}
local _evadeTimer = 0
local EVADE_DURATION = 3.0  -- seconds to maintain an evasive maneuver

--- Full evasive action — called when action == "evade".
function DefenseSystem.evade(body, percept)
    _evadeTimer = EVADE_DURATION
    -- Choose maneuver based on altitude
    if percept.selfAltitude > 250 then
        FlightController.splitS(body, 0.05)
    elseif #percept.threats > 1 then
        FlightController.barrelOffset(body, math.random(-1, 1) * 2 - 1, 0.05)
    else
        FlightController.weave(body, 0.05)
    end
end

--- Passive check — continue evading if timer still active.
function DefenseSystem.checkPassive(body, percept)
    if _evadeTimer > 0 then
        _evadeTimer = _evadeTimer - 0.15  -- approximate tick
        FlightController.weave(body, 0.05)
    end
end

function DefenseSystem.init(cfg)
    _cfg = cfg or {}
    -- Resolve FlightController via registry (executor) or script.Parent (Studio)
    if _G._Modules and _G._Modules["FlightController"] then
        FlightController = _G._Modules["FlightController"]
    else
        FlightController = require(script.Parent.FlightController)
    end
end

return DefenseSystem
