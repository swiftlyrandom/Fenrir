-- ============================================================
--  TacticalEvaluator.lua
--  Scores all possible actions and returns a ranked list.
--  Weights are adjusted by difficulty profile.
-- ============================================================
local TacticalEvaluator = {}
local _cfg = {}

-- All actions the bot can take
local ACTIONS = {
    "attack", "bomb_run", "climb", "dive",
    "disengage", "reset_distance", "ambush",
    "bait", "evade", "idle"
}

--- Returns sorted { {action, score}, ... } highest first.
function TacticalEvaluator.evaluate(percept, diff)
    local scores = {}
    local t = percept.primaryTarget
    local hasThreat = #percept.threats > 0

    for _, action in ipairs(ACTIONS) do
        local score = 0

        if action == "idle" then
            score = t and 0.0 or 0.5

        elseif action == "attack" then
            if t then
                local dist = t.distance
                -- Sweet spot: 200-800 studs
                score = 0.85 - math.abs(dist - 500) / 1000
                if hasThreat then score = score - 0.3 end
            end

        elseif action == "evade" then
            score = hasThreat and 0.9 or 0.0

        elseif action == "climb" then
            if t then
                -- Worth climbing if enemy is above us
                score = t.altDiff > 100 and 0.6 or 0.3
            else
                score = percept.selfAltitude < 200 and 0.5 or 0.1
            end

        elseif action == "dive" then
            score = (t and t.altDiff < -100) and 0.55 or 0.15

        elseif action == "disengage" then
            -- Disengage when low altitude or heavily threatened
            score = (hasThreat and percept.selfAltitude < 150) and 0.7 or 0.1

        elseif action == "reset_distance" then
            score = (t and t.distance < 150) and 0.75 or 0.1

        elseif action == "bomb_run" then
            -- Only if above enemy and bombs ready
            score = (t and percept.bombReady and t.altDiff > 150) and 0.65 or 0.0

        elseif action == "ambush" then
            score = (t and t.distance > 1200) and 0.5 or 0.0

        elseif action == "bait" then
            score = (hasThreat and not t) and 0.4 or 0.15
        end

        -- Apply difficulty aggression multiplier
        if diff then
            if action == "attack" or action == "bomb_run" then
                score = score * diff.aggressionMult
            end
            if action == "evade" or action == "disengage" then
                score = score * diff.defenseMult
            end
        end

        table.insert(scores, { action = action, score = score })
    end

    table.sort(scores, function(a, b) return a.score > b.score end)
    return scores
end

function TacticalEvaluator.init(cfg)
    _cfg = cfg or {}
end

return TacticalEvaluator
