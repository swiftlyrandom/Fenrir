-- ============================================================
--  BotState.lua
--  Lightweight runtime state snapshot.
--  Urgency drives tick rate — high urgency = faster decisions.
-- ============================================================
local BotState = {}

local _state = {
    lastAction  = "idle",
    urgency     = 0.0,   -- 0 = calm, 1 = critical
    inCombat    = false,
    tickCount   = 0,
}

--- Called after each execute phase.
function BotState.update(action, percept)
    _state.lastAction = action
    _state.tickCount  = _state.tickCount + 1
    _state.inCombat   = percept.primaryTarget ~= nil

    -- Urgency: max out when threats are behind us and we're low
    local threatCount = #(percept.threats or {})
    local lowAlt = (percept.selfAltitude or 999) < 150 and 1 or 0
    _state.urgency = math.min(1, (threatCount * 0.4) + (lowAlt * 0.3)
                                + (action == "evade" and 0.3 or 0))
end

function BotState.getUrgency()
    return _state.urgency
end

function BotState.getLastAction()
    return _state.lastAction
end

function BotState.isInCombat()
    return _state.inCombat
end

function BotState.init()
    _state = {
        lastAction = "idle",
        urgency    = 0.0,
        inCombat   = false,
        tickCount  = 0,
    }
end

return BotState
