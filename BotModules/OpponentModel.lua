-- ============================================================
--  OpponentModel.lua
--  Tracks observed enemy behavior patterns using counters.
--  No ML — pure probabilistic counters.
-- ============================================================
local OpponentModel = {}

-- profiles[player] = { leftBreaks, rightBreaks, headOnCount,
--                       aggressionScore, climbCount, diveCount,
--                       panicCount, totalObs }
local profiles = {}

local function getOrCreate(player)
    if not profiles[player] then
        profiles[player] = {
            leftBreaks      = 0,
            rightBreaks     = 0,
            headOnCount     = 0,
            aggressionScore = 0.5,  -- 0=passive, 1=aggressive
            climbCount      = 0,
            diveCount       = 0,
            panicCount      = 0,
            totalObs        = 0,
        }
    end
    return profiles[player]
end

--- Call every perception tick with fresh TargetInfo.
function OpponentModel.observe(targetInfo)
    if not targetInfo or not targetInfo.player then return end
    local p = getOrCreate(targetInfo.player)
    p.totalObs = p.totalObs + 1

    local vel = targetInfo.velocity
    if vel then
        -- Detect climbing/diving
        if vel.Y > 20  then p.climbCount = p.climbCount + 1 end
        if vel.Y < -20 then p.diveCount  = p.diveCount  + 1 end

        -- Detect lateral break direction (relative to our nose)
        -- TODO: needs self-CFrame; plug in percept.selfBody.CFrame here
        -- Placeholder: track raw X velocity sign
        if vel.X > 10  then p.rightBreaks = p.rightBreaks + 1 end
        if vel.X < -10 then p.leftBreaks  = p.leftBreaks  + 1 end
    end
end

--- Returns profile table for use in TacticalEvaluator.
function OpponentModel.getProfile(player)
    return getOrCreate(player)
end

function OpponentModel.init()
    profiles = {}
end

return OpponentModel
