-- ============================================================
--  LearningSystem.lua
--  Records action outcomes to bias future tactical choices.
--  Uses simple hit-rate counters, not ML.
-- ============================================================
local LearningSystem = {}

-- actionStats[action] = { attempts, successes }
local actionStats = {}

function LearningSystem.record(action, percept)
    if not actionStats[action] then
        actionStats[action] = { attempts = 0, successes = 0 }
    end
    actionStats[action].attempts = actionStats[action].attempts + 1
    -- TODO: define "success" per action type (e.g. enemy took damage after attack)
    -- For now, stub returns without scoring success
end

--- Returns success rate for an action (0-1), or 0.5 if no data.
function LearningSystem.getSuccessRate(action)
    local s = actionStats[action]
    if not s or s.attempts == 0 then return 0.5 end
    return s.successes / s.attempts
end

function LearningSystem.init()
    actionStats = {}
end

return LearningSystem


-- ============================================================
--  DifficultyController.lua
--  Returns a profile table for a given difficulty level.
--  All tunable numbers live here — change once, affects all.
-- ============================================================
-- NOTE: This is a second module in the same file for brevity.
-- In your project, split these into separate files.

-- ============================================================
--  BotState.lua
--  Lightweight runtime state: urgency, last action, etc.
-- ============================================================
