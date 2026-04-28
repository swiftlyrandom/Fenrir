-- ============================================================
--  TacticalEvaluator.lua
--  Scores all possible actions and returns a ranked list.
--  Weights are adjusted by difficulty profile.
-- ============================================================
local TacticalEvaluator = {}
local _cfg = {}

local ACTIONS = {
    "attack", "bomb_run", "climb", "dive",
    "disengage", "reset_distance", "ambush",
    "bait", "evade", "idle",
    "stall_snap", "stall_bait", "stall_brake",
}

-- ============================================================
--  HELPERS
-- ============================================================

--- Threat urgency: 0 = no real threat, 1 = critical.
--- Factors in how many threats, how close, and how directly
--- behind us they are. A single enemy 1800 studs back barely
--- registers; one 100 studs directly behind is critical.
local function threatUrgency(percept)
    if #percept.threats == 0 then return 0 end

    local worst = 0
    for _, threat in ipairs(percept.threats) do
        -- Closer = more urgent (normalised over 800 studs)
        local distFactor = 1 - math.min(threat.distance / 800, 1)
        -- More directly behind = more urgent
        -- threat.angle is degrees off our nose; 180 = dead behind
        local angleFactor = math.max(0, (threat.angle - 90) / 90)  -- 0 at 90°, 1 at 180°
        local urgency = distFactor * 0.6 + angleFactor * 0.4
        if urgency > worst then worst = urgency end
    end
    return worst
end

--- Attack score based on distance. Sweet spot 300-700 studs.
--- Falls off sharply below 150 (too close) and above 1000 (too far).
local function attackScoreForDist(dist)
    if dist < 150 then
        -- Inside minimum — can't aim properly
        return 0.3 + (dist / 150) * 0.3   -- 0.3 -> 0.6
    elseif dist <= 700 then
        -- Ideal engagement range
        return 0.85
    elseif dist <= 1200 then
        -- Acceptable but degrading
        return 0.85 - ((dist - 700) / 500) * 0.4   -- 0.85 -> 0.45
    else
        -- Too far
        return 0.1
    end
end

-- ============================================================
--  EVALUATE
-- ============================================================

--- Returns sorted { {action, score}, ... } highest first.
function TacticalEvaluator.evaluate(percept, diff)
    local scores  = {}
    local t       = percept.primaryTarget
    local urgency = threatUrgency(percept)   -- 0-1, replaces hasThreat bool

    for _, action in ipairs(ACTIONS) do
        local score = 0

        -- ── Idle ─────────────────────────────────────────────
        if action == "idle" then
            score = t and 0.0 or 0.4

        -- ── Attack ───────────────────────────────────────────
        -- Only penalise attack if the threat urgency is HIGH (>0.6).
        -- A mild threat behind us should not stop us from attacking.
        elseif action == "attack" then
            if t then
                score = attackScoreForDist(t.distance)
                -- Penalty scales with urgency, but never drops attack
                -- below 0.5 so it stays competitive with evade
                if urgency > 0.6 then
                    score = score - (urgency - 0.6) * 0.5
                end
                score = math.max(score, 0)
            end

        -- ── Evade ────────────────────────────────────────────
        -- Only dominates when urgency is genuinely high.
        -- Low-urgency threats don't justify full evasion.
        elseif action == "evade" then
            if urgency > 0.3 then
                -- Scale from 0.45 (mild) up to 0.85 (critical)
                score = 0.45 + (urgency - 0.3) / 0.7 * 0.40
            end

        -- ── Disengage ────────────────────────────────────────
        -- Only when critically threatened AND low altitude.
        elseif action == "disengage" then
            local lowAlt = percept.selfAltitude < 150
            if urgency > 0.7 and lowAlt then
                score = 0.80
            elseif urgency > 0.8 then
                score = 0.60
            else
                score = 0.05
            end

        -- ── Reset distance ───────────────────────────────────
        -- Use when enemy is dangerously close OR very far away.
        elseif action == "reset_distance" then
            if t then
                if t.distance < 250 then
                    -- Too close — create separation
                    score = 0.75
                elseif t.distance > 1400 then
                    -- Too far — close in
                    score = 0.50
                else
                    score = 0.05
                end
            end

        -- ── Climb ────────────────────────────────────────────
        elseif action == "climb" then
            if t then
                if t.altDiff > 150 then
                    -- Enemy has significant altitude advantage
                    score = 0.65
                elseif percept.selfAltitude < 150 then
                    -- Too low regardless of enemy
                    score = 0.55
                else
                    score = 0.20
                end
            else
                score = percept.selfAltitude < 200 and 0.45 or 0.10
            end

        -- ── Dive ─────────────────────────────────────────────
        elseif action == "dive" then
            if t and t.altDiff < -150 then
                score = 0.55
            else
                score = 0.10
            end

        -- ── Bomb run ─────────────────────────────────────────
        elseif action == "bomb_run" then
            if t and percept.bombReady and t.altDiff > 150 then
                score = 0.65
            end

        -- ── Ambush ───────────────────────────────────────────
        elseif action == "ambush" then
            if t and t.distance > 1200 then
                score = 0.50
            end

        -- ── Bait ─────────────────────────────────────────────
        elseif action == "bait" then
            -- Only useful when a threat is chasing but we have no
            -- clean attack angle yet
            if urgency > 0.2 and urgency < 0.6 and t then
                score = 0.40
            end

        -- ── Stall snap turn ───────────────────────────────
        -- Best when enemy has just overshot — was behind, now
        -- crossing into front arc at close range.
        elseif action == "stall_snap" then
            if t and urgency > 0.5 and t.distance < 400 then
                local facingBonus = t.angle < 60 and 0.15 or 0
                score = 0.72 + facingBonus
            end

        -- ── Stall bait ────────────────────────────────────
        -- Enemy closing fast from behind at medium range.
        -- Don't use when urgency is critical — too slow to react.
        elseif action == "stall_bait" then
            if t and urgency > 0.25 and urgency < 0.65
               and t.distance < 600 and t.isBehind then
                score = 0.60
            end

        -- ── Emergency brake ───────────────────────────────
        -- Last resort — enemy extremely close directly behind.
        elseif action == "stall_brake" then
            if urgency > 0.75 and t and t.distance < 250 and t.isBehind then
                score = 0.82
            end
        end

        -- ── Difficulty multipliers ────────────────────────────
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
