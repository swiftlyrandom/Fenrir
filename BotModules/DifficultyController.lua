-- ============================================================
--  DifficultyController.lua
--  Single source of truth for all difficulty-scaled values.
--  Changing a number here affects the entire bot.
-- ============================================================
local DifficultyController = {}

local PROFILES = {
    Easy = {
        reactionMult    = 2.0,   -- tick interval multiplier (slower reactions)
        aggressionMult  = 0.6,   -- scales attack action scores down
        defenseMult     = 1.4,   -- scales evade/disengage scores up
        choiceNoise     = 0.40,  -- probability of picking 2nd-best action
        aimSpread       = 4.0,   -- extra degrees of aim error
        description     = "Hesitant, erratic, easily baited.",
    },
    Medium = {
        reactionMult    = 1.4,
        aggressionMult  = 0.8,
        defenseMult     = 1.1,
        choiceNoise     = 0.20,
        aimSpread       = 2.0,
        description     = "Competent but predictable.",
    },
    Hard = {
        reactionMult    = 1.0,
        aggressionMult  = 1.0,
        defenseMult     = 1.0,
        choiceNoise     = 0.10,
        aimSpread       = 1.0,
        description     = "Consistent, uses energy tactics.",
    },
    Elite = {
        reactionMult    = 0.7,   -- reacts faster than hard
        aggressionMult  = 1.2,
        defenseMult     = 1.2,   -- aggressive AND defensive
        choiceNoise     = 0.02,  -- almost always picks best
        aimSpread       = 0.0,
        description     = "Adaptive, reads patterns, punishes mistakes.",
    },
}

local _current = "Hard"

function DifficultyController.init(level)
    _current = level or "Hard"
    assert(PROFILES[_current], "Unknown difficulty: " .. tostring(_current))
end

--- Returns the profile table for a given level (or current if nil).
function DifficultyController.get(level)
    return PROFILES[level or _current] or PROFILES["Hard"]
end

function DifficultyController.getCurrent()
    return _current
end

return DifficultyController
