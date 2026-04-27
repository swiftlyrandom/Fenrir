-- BotState.lua
-- Returns a fresh state table for one bot instance.
-- MainBrain calls this once on startup.

local BotState = {}

function BotState.new()
    return {

        -- ------------------------------------------------
        -- IDENTITY
        -- ------------------------------------------------
        botPlayer       = nil,   -- LocalPlayer reference
        vehicle         = nil,   -- vehicle Model
        mainBody        = nil,   -- BasePart with BodyGyro + BodyVelocity
        engineRunning   = false,
        targetEnemy     = nil,   -- current primary target (Player or nil)

        -- ------------------------------------------------
        -- DIFFICULTY  (set by DifficultyController)
        -- ------------------------------------------------
        difficulty = {
            level             = "Hard",  -- "Easy"|"Medium"|"Hard"|"Elite"
            reactionDelay     = 0.15,    -- seconds before acting on new info
            aimConfidence     = 0.65,    -- minimum hit probability to fire
            aggressionBias    = 0.5,     -- 0=passive, 1=hyper-aggressive
            defenseThreshold  = 0.45,    -- threat score that triggers defense
            learningRate      = 0.08,    -- how fast OpponentModel updates
            loopInterval      = 0.15,    -- decision loop seconds
        },

        -- ------------------------------------------------
        -- PERCEPTION  (written by PerceptionSystem each tick)
        -- ------------------------------------------------
        perception = {
            enemyPosition     = Vector3.zero,
            enemyVelocity     = Vector3.zero,
            enemyAltitude     = 0,
            selfPosition      = Vector3.zero,
            selfVelocity      = Vector3.zero,
            selfAltitude      = 0,
            altitudeDelta     = 0,      -- enemy alt - self alt (+ means enemy higher)
            distance          = 999,
            hasLOS            = false,  -- line-of-sight clear
            relativeAngle     = 0,      -- degrees: 0=head-on, 180=enemy behind
            enemyBearing      = 0,      -- compass degrees to enemy
            incomingThreat    = false,  -- enemy gun/bomb aimed near us
            threatScore       = 0,      -- 0..1 composite danger level
            ammoReady         = true,
            bombReady         = false,
            gunCooldown       = 0,
            mapDangerZone     = false,  -- are we inside a flagged danger area
        },

        -- ------------------------------------------------
        -- OPPONENT MODEL  (written by LearningSystem / OpponentModel)
        -- ------------------------------------------------
        opponentProfile = {
            -- raw counters (increment every observed maneuver)
            breakLeftCount    = 0,
            breakRightCount   = 0,
            headOnCount       = 0,
            chaseCount        = 0,
            climbCount        = 0,
            diveCount         = 0,
            panicCount        = 0,
            totalObservations = 0,

            -- derived probabilities (recomputed after each counter update)
            breakLeftChance   = 0.5,
            breakRightChance  = 0.5,
            headOnChance      = 0.3,
            chaseChance       = 0.5,
            climbChance       = 0.5,
            diveChance        = 0.5,
            aggressionLevel   = 0.5,   -- 0=passive, 1=aggressive

            -- last observed position (used to classify maneuvers)
            lastEnemyPos      = Vector3.zero,
            lastEnemyVel      = Vector3.zero,
            lastSampleTime    = 0,
        },

        -- ------------------------------------------------
        -- TACTICAL  (written by TacticalEvaluator)
        -- ------------------------------------------------
        tactical = {
            -- all scored actions this tick
            actionScores = {
                attackPass    = 0,
                disengage     = 0,
                climb         = 0,
                dive          = 0,
                ambush        = 0,
                bombRun       = 0,
                bait          = 0,
                evade         = 0,
                resetDistance = 0,
            },
            chosenAction      = "resetDistance",  -- default safe action
            previousAction    = nil,
            actionHoldTimer   = 0,    -- prevents flip-flopping every tick
            actionHoldMin     = 1.0,  -- minimum seconds to hold an action
        },

        -- ------------------------------------------------
        -- FLIGHT CONTROL  (written by FlightController)
        -- ------------------------------------------------
        flight = {
            targetHeading     = Vector3.zero,   -- world-space aim point
            currentSpeed      = 0,
            desiredSpeed      = 100,
            minSpeed          = 40,             -- stall threshold
            maxSpeed          = 220,
            weaveOffset       = Vector3.zero,   -- sinusoidal evasion displacement
            weavePhase        = 0,              -- radians, incremented each tick
            interceptPoint    = Vector3.zero,   -- predicted intercept pos
        },

        -- ------------------------------------------------
        -- WEAPON  (written by WeaponSystem)
        -- ------------------------------------------------
        weapon = {
            aimPoint          = Vector3.zero,   -- world-space predicted target pos
            hitConfidence     = 0,              -- 0..1
            burstActive       = false,
            burstTimer        = 0,
            burstDuration     = 0.25,           -- seconds per burst
            burstCooldown     = 0.6,
            bombDropQueued    = false,
        },

        -- ------------------------------------------------
        -- DEFENSE  (written by DefenseSystem)
        -- ------------------------------------------------
        defense = {
            active            = false,
            maneuver          = nil,    -- "weave"|"splitS"|"barrelRoll"|"disengage"
            maneuverTimer     = 0,
            maneuverDuration  = 2.0,
            overrideHeading   = nil,    -- if set, FlightController uses this instead
        },

        -- ------------------------------------------------
        -- TIMING  (internal clock for the MainBrain loop)
        -- ------------------------------------------------
        timing = {
            lastLoopTime      = 0,
            lastLearnTime     = 0,
            learnInterval     = 0.5,   -- OpponentModel updated every 0.5s
            deltaTime         = 0,
        },
    }
end

return BotState
