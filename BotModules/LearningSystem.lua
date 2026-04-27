-- ============================================================
--  LearningSystem.lua
--  Records action outcomes to bias future tactical choices.
--  Uses simple hit-rate counters — no ML.
--
--  FUTURE HOOKS:
--    Call LearningSystem.markSuccess(action) from MainBrain
--    when you detect a positive outcome (e.g. enemy health drop,
--    enemy disengaged, bot survived an evade window).
-- ============================================================
local LearningSystem = {}

-- actionStats[action] = { attempts, successes }
local actionStats = {}

--- Called every execute phase with the chosen action.
function LearningSystem.record(action, percept)
    if not actionStats[action] then
        actionStats[action] = { attempts = 0, successes = 0 }
    end
    actionStats[action].attempts = actionStats[action].attempts + 1
end

--- Call this from MainBrain when an action is confirmed successful.
function LearningSystem.markSuccess(action)
    if actionStats[action] then
        actionStats[action].successes = actionStats[action].successes + 1
    end
end

--- Returns success rate for an action (0–1). Default 0.5 (unknown).
function LearningSystem.getSuccessRate(action)
    local s = actionStats[action]
    if not s or s.attempts == 0 then return 0.5 end
    return s.successes / s.attempts
end

--- Debug dump of all action stats.
function LearningSystem.dump()
    for action, s in pairs(actionStats) do
        print(string.format("  %-18s  attempts=%d  successes=%d  rate=%.2f",
            action, s.attempts, s.successes,
            s.attempts > 0 and (s.successes / s.attempts) or 0))
    end
end

function LearningSystem.init()
    actionStats = {}
end

return LearningSystem
