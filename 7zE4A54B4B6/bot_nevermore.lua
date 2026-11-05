
-- Nevermore Bot v7.9.20-pro — Pro 1v1 Mid Architecture (Live Turn-During-Cast Raze Dodge + Cliff/Creep Ray Guard + Full-Game Monotonic Creep Block + Own-T1 Dry-CS Precision)
local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")
local L = require("bots/nevermore/lasthit")
local P = require("bots/nevermore/positioning")
local K = require("bots/nevermore/combat")
local W = require("bots/nevermore/world")
local LN = require("bots/nevermore/lane")
local I = require("bots/nevermore/intent")
local WV = require("bots/nevermore/wave")
local WAR = require("bots/nevermore/war_core")
local WD  = require("bots/nevermore/war_director")
local ET  = require("bots/nevermore/engine_truth")

-- Simulation-only diagnostics: counts every gate of the free-pressure handlers. Outside the
-- simulator (no BOT_SIM_PROBE global) this compiles to a no-op, so the shipped bot pays nothing.
local function FDBG(k)
    if not _G.BOT_SIM_PROBE then return end
    local d = _G.__freeDbg
    if not d then d = {}; _G.__freeDbg = d end
    d[k] = (d[k] or 0) + 1
end

-- Load marker: if this line is missing from the console the file did not load
-- and the stock Valve bot plays instead (look for [VScript] errors).
print("[SF-BOT] bot_nevermore.lua loaded (v7.9.20-pro: live-turn-cast-dodge + cliff-creep-ray-guard + monotonic-creep-block + own-t1-dry-cs)")

U.DEBUG = false
U._S = S -- Soul-economy hook used by `lasthit.lua` scorer

-- All handlers live in the H table instead of being local functions: works around the
-- Lua 5.1 limit of 60 upvalues per function (otherwise the file does not compile in Dota).
local H = {}

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}


local State = {
    hunting                   = false, -- Hunting (see H.ComputeHunt)
    attackTarget              = nil,
    attackStartTime           = 0,
    deaggroTime               = 0,
    prepTarget                = nil,
    prepTargetTime            = 0,
    lhAttackTarget            = nil,
    defensive                 = false,
    defensiveSince            = 0,
    enemyAggroCount           = 0,
    flyingProjectiles         = {},
    firedThisAttack           = false,
    lastAggroTime             = 0,
    aggroPullTime             = 0,
    myCreepAggroCdUntil       = 0,
    myCreepChaseUntil         = 0,
    lastAggroPrimeAt          = -100,
    lastItemUseTime           = 0,
    lastHarassTime            = 0,
    needsTP                   = false,
    tpOrderTime               = -100,
    -- Commitment to "finish" or "run" (prevents fight<->flee flapping)
    commitKillUntil           = 0,
    fleeUntil                 = 0,
    -- Enemy is teleporting to its T1 (TP channel visible / respawned after death)
    enemyTPIncomingUntil      = 0,
    enemyWasAlive             = true,
    aimingRaze                = nil,
    aimingTarget              = nil,
    aimingLoc                 = nil,
    aimingStartTime           = 0,
    aimingValidationRadius    = nil,
    forcedRetreatLoc          = nil,
    forcedRetreatUntil        = 0,
    -- Commitment to walk out of the enemy T1 (point + deadline)
    towerEscapeLoc            = nil,
    towerEscapeUntil          = 0,
    nearChainUntil            = 0, -- Window for the follow-up raze chain after punishing an enemy that walked up to us
    lastMoveLoc               = nil,
    lastMoveTime              = 0,
    emergencyRetreat          = nil,
    emergencyRetreatStartTime = 0,
    emergencyTPQueued         = false,
    glyphUsedForDive          = false,
    glyphDiveTime             = 0,
    lastForceSalveTime        = 0,
    enemyT1ClosestCreepDist   = nil,
    enemyT1ClosestCreepTime   = 0,
    actionTaken               = false,
    holdPos = false,
    goingToFountain           = false,
    fountainReason            = nil,
    enemyReachedLevel2First   = false,
    heroAttackTarget          = nil,
    heroAttackTime            = 0,
    _lastSalveAutoBuyTime     = 0,
    -- Tango: sticky tree choice (fixes oscillating between trees)
    tangoTree                 = nil,
    tangoCastAt = 0,
    tangoFails = 0,
    tangoTreeLoc              = nil,
    tangoChosenAt             = 0,
    tangoBestDist             = math.huge,
    tangoBadTree              = nil,
    tangoBadTreeTime          = 0,
    -- Dodging the enemy raze
    dodgeLoc                  = nil,
    dodgeUntil                = 0,
    -- Intent and context
    intent                    = "FARM",
    lastIntentPrint           = 0,
    siegeWaitUntil            = 0,
}

-- Context for the intent FSM (reused, no per-tick allocation)
local IntentCtx = {
    enemy = false, race = nil, myHpPct = 1, myRazes = 0, healing = false,
    enemyDist = 99999, enemyDistToWave = 99999, enemyAbsent = false,
    enemyUnderHisTower = false, canCatch = true, underEnemyTower = false,
}

-- Hook for utils (glyph for a dive): "we are really committing" = aiming a raze / hit a hero <= 1 s ago
U._State = State -- Test hook: State access from the tooling
U._engagedCheck = function(bot, enemy)
    if State.aimingRaze then return true end
    if (GameTime() - (State.heroAttackTime or -10)) <= 1.0 then return true end
    return false
end

-- force=true: micro-steps (turning for a raze, dodging) must not be swallowed by deduplication.
function H.SmartMove(bot, loc, threshold, force, stackAbility)
    if not loc then return false end
    if State.actionTaken then return false end
    local botLoc = bot:GetLocation()
    -- Smooth tangential obstacle & tower hull steering on real navigation moves (`> 55u`, never altering micro-turns!)
    if not force then
        loc = U.SteerAroundObstacles(bot, loc, W.s)
    end
    -- `v7.9.10-pro` Universal Cliff-Safe Passability + Live Enemy-Coil No-Entry Law (`2048` `#55` `277u -> 235u` Fix!):
    loc = U.EnsurePassable(bot, loc)
    local enemy = H._enemyHeroNear
    if enemy and U.CanQuery(enemy) and botLoc and not State.dodgeLoc and K.EnemyPhase then
        local phLbl = K.EnemyPhase()
        if phLbl then
            local liveCenter = K.EnemyRazeCenter(enemy, phLbl)
            local rHero = (C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274
            local dBotC = U.DistanceBetweenLocations(botLoc, liveCenter)
            local dLocC = U.DistanceBetweenLocations(loc, liveCenter)
            local enHpMove = enemy:GetHealth() or 9999
            local canFinishMove = (enHpMove <= 175) and ((bot:GetHealth() or 0) > K.EnemyRazeDamage(bot, enemy, 1) + 185)
            if not canFinishMove and dBotC >= rHero - 2 and dLocC < rHero + 24 then
                local radOut = (dBotC > 1) and (botLoc - liveCenter):Normalized() or (P.GetFountain(bot) - liveCenter):Normalized()
                loc = U.EnsurePassable(bot, liveCenter + radOut * (rHero + 42))
            end
        end
    end
    if not force and botLoc and U.DistanceBetweenLocations(botLoc, loc) <= 22 then
        State.actionTaken = true
        return true
    end
    if enemy and not State.forcedRetreatLoc and not State.survivalLoc and not State.towerEscapeLoc
        and not K.StackLeadStepSafe(bot, enemy, loc)
        and not H.StackLeadThirdRazeOK(bot, enemy, stackAbility, loc, W.s) then return false end
    threshold = threshold or 60
    local now = GameTime()
    local last = State.lastMoveLoc
    if force then
        if last and (now - State.lastMoveTime) < 0.1 and U.DistanceBetweenLocations(last, loc) <= 4 then
            State.actionTaken = true
            return true
        end
    elseif last and (now - State.lastMoveTime) < 0.6 then
        if U.DistanceBetweenLocations(last, loc) <= threshold then
            -- A move order to this point was already issued recently: treat it as in progress (actionTaken),
            -- otherwise the next handler overrides it and everything reverses on the next tick.
            State.actionTaken = true
            return true
        end
        -- Anti-Reversal Hysteresis (`9068560663.dem` 40-reversals fix):
        -- Block sharp >= 110-deg ambient move reversals (`dot < -0.35`) within 0.28s when no emergency
        -- dodge/tower/retreat override is active, eliminating bang-bang movement twitching completely!
        local urgentOverride = State.forcedRetreatLoc or State.survivalLoc or State.towerEscapeLoc
            or State.dodgeLoc or State.urgentMoveOverride
        if not urgentOverride and botLoc and (now - State.lastMoveTime) < 0.28 then
            local prevDx, prevDy = last.x - botLoc.x, last.y - botLoc.y
            local newDx, newDy = loc.x - botLoc.x, loc.y - botLoc.y
            local prevL = math.sqrt(prevDx * prevDx + prevDy * prevDy)
            local newL = math.sqrt(newDx * newDx + newDy * newDy)
            if prevL > 40 and newL > 40 then
                local dot = (prevDx * newDx + prevDy * newDy) / (prevL * newL)
                if dot < -0.35 then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end
    State.lastMoveLoc = loc
    State.lastMoveTime = now
    bot:Action_MoveToLocation(loc)
    State.actionTaken = true
    return true
end

function H.ClearMoveCache()
    State.lastMoveLoc = nil
    State.lastMoveTime = 0
end

function H.SmartFace(bot, point, stackAbility)
    if not bot or not point then return false end
    local botLoc = bot:GetLocation()
    if not botLoc then return false end
    if U.FacingCos and U.FacingCos(bot, point) >= 0.994 then
        return true
    end
    local dist = U.DistanceBetweenLocations(botLoc, point)
    local step = (C.RAZE and C.RAZE.TURN_STEP) or 36
    local stepLoc = (dist > step + 10) and (botLoc + (point - botLoc):Normalized() * step) or point
    if not stackAbility and bot.Action_MoveDirectly then
        bot:Action_MoveDirectly(stepLoc)
        State.lastMoveLoc = stepLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return H.SmartMove(bot, stepLoc, 16, true, stackAbility)
end

function H.ClearRazeState()
    State.shortCombatCast = nil
    State.aimingRaze = nil
    State.aimingTarget = nil
    State.aimingLoc = nil
    State.aimingStartTime = 0
    State.aimingValidationRadius = nil
    State.aimingFollowup = nil
    State.aimingMustHitHero = nil
    State.aimingLastEnemyVel = nil
    State.pumpFakeCancelAt = nil
end

function H.StartRazeCast(ability, target, loc, validationRadius, isCS, mustHitHero)
    State.aimingFollowup = nil
    State.aimingMustHitHero = mustHitHero or nil
    State.aimingLastEnemyVel = nil
    if target and U.CanQuery(target) and target.GetVelocity then
        local okV, tv = pcall(target.GetVelocity, target)
        if okV and tv and tv.x then State.aimingLastEnemyVel = tv end
    end
    State.lastRazeOrderTime = GameTime()
    local isHeroTarget = target and target.IsHero and target:IsHero()
    if isHeroTarget and U.CanQuery(target) then
        local age = U.GetRecentEnemyRazeHitAge(target)
        if age <= C.RAZE.MIRROR_INSTANT_SEC then
            State.mirrorAnsweredEnemy = target
            State.mirrorAnsweredHit = GameTime() - age
        end
        local data = U.GetRazeAbilityData(ability)
        local chain = State.razeFollowup
        if chain and chain.enemy == target and GameTime() <= chain.untilTime then
            State.aimingFollowup = chain
            State.razeFollowup = nil -- The second cast consumes, never renews, this plan.
        elseif data and (data.label == "far" or data.label == "mid") then
            State.razeFollowup = {
                enemy = target, label = data.label == "far" and "mid" or "far",
                opened = GameTime(), untilTime = GameTime() + 2.5,
                stacks = U.GetShadowrazeDebuff(target),
            }
        end
    end
    State.aimingRaze = ability
    State.aimingTarget = target
    State.aimingLoc = loc
    State.aimingStartTime = GameTime()
    State.aimingValidationRadius = validationRadius or C.RAZE.HIT_RADIUS
    State.aimingIsCS = (isCS == true) or (target ~= nil and not isHeroTarget)
    State.actionTaken = true
end

function H.HandleActiveRazeValidation(bot)
    if not State.aimingRaze then return false end
    local now = GameTime()
    if bot:IsUsingAbility() or bot:IsChanneling() then
        local elapsed = now - State.aimingStartTime
        -- Do not cancel a completed cast just because the target moves during backswing.
        if elapsed >= C.RAZE.CAST_POINT and not State.aimingRaze:IsInAbilityPhase() then
            H.ClearRazeState()
            return false
        end
        local remaining = math.max(0, C.RAZE.CAST_POINT - elapsed)

        local data = U.GetRazeAbilityData(State.aimingRaze)
        if not data then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        local enemyNow = H._enemyHeroNear

        -- Deliberate `0.28s` Pro Pump-Fake Cancel (`v7.9.8-pro` `1630 @ 04:10.27` `rzD=189u` & `04:37.27` `rzD=116u` Fix!):
        -- Keep the real `E(700)` cast whenever `(bot:GetMana() >= 150)` AND predicted impact is a solid `<= 185u` hit
        -- (not just when `walkedInward`!), so we NEVER self-cancel a guaranteed centered coil!
        if State.pumpFakeCancelAt and elapsed >= (State.pumpFakeCancelAt - State.aimingStartTime) then
            local keepRealHit = false
            if enemyNow and U.CanQuery(enemyNow) and enemyNow:IsAlive() then
                local eImp = U.PredictPosition(enemyNow, remaining)
                local bNowP = bot:GetLocation()
                local impErr = U.GetRazeHitErrorWithCurrentFacing(bot, eImp, data.center)
                local walkedInward = State.aimingLoc
                    and (U.DistanceBetweenLocations(bNowP, enemyNow:GetLocation()) <= U.DistanceBetweenLocations(bNowP, State.aimingLoc) - 20)
                if (walkedInward and impErr <= 115) or ((bot:GetMana() or 0) >= 150 and impErr <= 185) then
                    keepRealHit = true
                end
            end
            State.pumpFakeCancelAt = nil
            if not keepRealHit then
                bot:Action_ClearActions(true)
                H.ClearRazeState()
                H.ClearMoveCache()
                return true
            end
        end

        -- Check whether live enemy hero (visible OR just stepped into river/highground FoW `<= 0.65s` ago while still alive!)
        -- lands inside this exact coil (`<= 262u` inside Source 2 `250 + 24 = 274u` hero hull hit radius!), OR another creep dies!
        local leadHero = math.min(remaining, 0.04)
        local enemyHitByCoil = false
        if enemyNow and U.CanQuery(enemyNow) and enemyNow:IsAlive() and (enemyNow:GetHealth() or 0) > 0 then
            local eNowLoc = enemyNow:GetLocation()
            if enemyNow.GetVelocity then
                local okV, ev = pcall(enemyNow.GetVelocity, enemyNow)
                if okV and ev and ev.x then State.aimingLastEnemyVel = ev end
            end
            local ePred = U.PredictPosition(enemyNow, remaining + leadHero)
            -- `auto-20261102-0159` `11:05.3` Whiff #1 + `9072025270` `02:49.73` Fix:
            -- On CS-centered dual-value coils (`State.aimingIsCS`), tighten hero containment (`254u` predicted & `264u` live)
            -- so an outer-rim hero walking away never keeps a doomed CS coil alive!
            local predLimH = State.aimingIsCS and (C.RAZE.HIT_RADIUS + 4) or (C.RAZE.HIT_RADIUS + 12)
            if (U.GetRazeHitErrorWithCurrentFacing(bot, ePred, data.center) <= predLimH
                    and (not State.aimingIsCS or U.GetRazeHitErrorWithCurrentFacing(bot, eNowLoc, data.center) <= (C.RAZE.HIT_RADIUS + 14)))
                or (remaining <= 0.10 and U.GetRazeHitErrorWithCurrentFacing(bot, eNowLoc, data.center) <= (C.RAZE.HIT_RADIUS + 6)) then
                enemyHitByCoil = true
            end
        elseif W.s and W.s.enemyAlive ~= false and (W.s.enemyAbsentFor or 99) <= 0.65 and W.s.enemyLastLoc then
            -- `auto-20261102-0159` `17:02.4` Whiff #2 Night-FoW Fix:
            -- Extrapolate `enemyLastLoc` along last-known velocity across `(enemyAbsentFor + remaining)` and require BOTH
            -- `enemyLastLoc` AND `fogPred` to sit strictly inside the `250u` coil (`<= 254u`), so an enemy walking past
            -- `800u` night vision (`395u` outside `W(450)`) is cancelled cleanly instead of blindly firing into empty FoW!
            local fogLoc = W.s.enemyLastLoc
            local dtFog = math.min(1.0, (W.s.enemyAbsentFor or 0) + remaining)
            local lv = State.aimingLastEnemyVel
            local fogPred = (lv and lv.x)
                and Vector(fogLoc.x + lv.x * dtFog, fogLoc.y + lv.y * dtFog, fogLoc.z or 128)
                or fogLoc
            if U.GetRazeHitErrorWithCurrentFacing(bot, fogLoc, data.center) <= (C.RAZE.HIT_RADIUS + 4)
                and U.GetRazeHitErrorWithCurrentFacing(bot, fogPred, data.center) <= (C.RAZE.HIT_RADIUS + 2) then
                enemyHitByCoil = true
            end
        end

        local otherKillableCreepInCoil = false
        if State.aimingIsCS and W.s and W.s.enemyCreeps then
            local rawBase = U.GetRazeDamage(bot, State.aimingRaze, 0)
            for _, oc in pairs(W.s.enemyCreeps) do
                if oc ~= State.aimingTarget and U.CanQuery(oc) and oc:IsAlive() and (oc:GetHealth() or 0) > 0 then
                    local magicDmg = math.floor(oc:GetActualIncomingDamage(rawBase, DAMAGE_TYPE_MAGICAL))
                    local ocPred = U.PredictPosition(oc, remaining)
                    if (oc:GetHealth() or 9999) <= magicDmg
                        and U.GetRazeHitErrorWithCurrentFacing(bot, oc:GetLocation(), data.center) <= (C.RAZE.HIT_RADIUS - 8)
                        and U.GetRazeHitErrorWithCurrentFacing(bot, ocPred, data.center) <= (C.RAZE.HIT_RADIUS - 10) then
                        otherKillableCreepInCoil = true
                        break
                    end
                end
            end
        end

        -- `9056774541.dem` `03:07.63` + `auto-20261102-0159.dem` `17:02.4` Whiff #2 Fix:
        --   1. When a river/staircase creep dies mid-cast and the enemy drops into FoW, keep the cast ONLY when
        --      `enemyHitByCoil` (computed above from `W.s.enemyLastLoc` + velocity!) confirms they are actually inside the coil!
        --   2. NEVER S-cancel a Dual-Value CS coil when `enemyHitByCoil` OR `otherKillableCreepInCoil` holds!
        local aimingHeroRef = (State.aimingTarget ~= nil) and (not State.aimingIsCS)
        local tgtAlive = U.CanQuery(State.aimingTarget)
            and State.aimingTarget:IsAlive()
            and (State.aimingTarget:GetHealth() or 0) > 0
        if not tgtAlive then
            if enemyHitByCoil or otherKillableCreepInCoil then
                return true
            end
            State.mirrorAnsweredHit = nil
            State.razeFollowup = State.aimingFollowup
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        -- `auto-20261102-0159.dem` `11:05.3` Whiff #1 Premature Creep-Death Abort:
        -- If `State.aimingTarget` is a CS creep (`e.g. 14 HP under T1`) and incoming allied tower/creep attacks will kill it
        -- BEFORE `remaining` elapses while neither `enemyHitByCoil` nor `otherKillableCreepInCoil` holds, S-cancel now (`0` MP)!
        local prematureCreepDeath = false
        if State.aimingIsCS and remaining >= 0.066 and W.s and U.PredictHP then
            local incomingOnTarget = U.MergeLists(W.s.allyCreeps, W.s.allyTowers)
            local okHp, hpBeforeDet = pcall(U.PredictHP, State.aimingTarget, math.max(0.033, remaining - 0.033), "min", incomingOnTarget)
            if okHp and type(hpBeforeDet) == "number" and hpBeforeDet <= 0 then
                prematureCreepDeath = true
            end
        end

        -- `auto-20261101-0031-start-ShaNachnetsya.dem` `01:32.67` (`tk=6214` `R2` `err=262.5u`) & `01:37.80` (`tk=6368` `R3` `err=263.3u`) Fix:
        -- Source 2 `FindUnitsInRadius(..., 250, ...)` hits heroes out to `250 + 24 = 274.0u` center-to-center (confirmed at `tk=10344`
        -- solo kill at `254.4u`!). Previously `limit = 240u` + unconditional `+0.08s` post-impact lead cancelled guaranteed hull hits
        -- `1` tick (`0.033s`) before impact! Clamp lead to `min(remaining, 0.04)` and validate hero coils against `262u` (`12u` buffer).
        local effLead = aimingHeroRef and math.min(remaining, 0.04) or (C.RAZE.LAND_LEAD or 0.08)
        local predicted = U.PredictPosition(State.aimingTarget, remaining + effLead)
        local error = U.GetRazeHitErrorWithCurrentFacing(bot, predicted, data.center)
        local limit
        if aimingHeroRef then
            -- `auto-20261102-0043` `2:32.97` (`266.7u <= 274.0u` Mid-`W` Abort Fix):
            -- In the final `0.14s` (`<= 4 ticks` before `0.55s` cast finishes), the enemy can barely move `~35u`,
            -- so `268u` (`6u` inside true `274.0u` `250+24` hero hull!) prevents false late-windup cancels without whiffs!
            local heroHullLimit = (remaining <= 0.14) and (C.RAZE.HIT_RADIUS + 18) or (C.RAZE.HIT_RADIUS + 12)
            limit = math.min((State.aimingValidationRadius or C.RAZE.HIT_RADIUS) + ((remaining <= 0.14) and 18 or 12), heroHullLimit)
            if remaining <= 0.14 then
                local exactImp = U.PredictPosition(State.aimingTarget, remaining)
                if U.GetRazeHitErrorWithCurrentFacing(bot, exactImp, data.center) <= (C.RAZE.HIT_RADIUS + 18) then
                    return true
                end
            end
        else
            limit = math.min(State.aimingValidationRadius or C.RAZE.HIT_RADIUS, C.RAZE.HIT_RADIUS) - 10
        end

        -- For Dual-Value CS coils:
        --   1. NEVER abort if enemyHero (or a 2nd killable creep) is still inside the coil!
        --   2. DO abort (`0` mana, `0s` CD!) if `State.aimingMustHitHero` was required to justify a 1-melee-creep raze
        --      and `enemyHero` escaped outside the coil (`9072025270.dem` `02:49.73` `#24` Fix)!
        local lostRequiredHero = State.aimingIsCS
            and (State.aimingMustHitHero ~= nil)
            and (elapsed >= 0.08)
            and (not enemyHitByCoil)
            and (not otherKillableCreepInCoil)
        if ((error > limit or prematureCreepDeath) and not (State.aimingIsCS and (enemyHitByCoil or otherKillableCreepInCoil)))
            or lostRequiredHero then
            if aimingHeroRef or lostRequiredHero then
                U._lastHeroRazeCancel = now
            end
            State.mirrorAnsweredHit = nil -- A cancelled cast has not answered the hit.
            State.razeFollowup = State.aimingFollowup
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
        end
        return true
    end

    if now > State.aimingStartTime + 1.0 then
        H.ClearRazeState()
    end

    return false
end

function H.SafeClearActions(bot)
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    bot:Action_ClearActions(true)
    H.ClearMoveCache()
    return true
end

-- Power Treads (`v7.8.0` Pro Attribute Discipline — `9070886384.dem` `06:53–07:45` Fix):
-- * `SURVIVE` (`STR = 0`) ONLY when genuinely threatened (retreating, `< 38% HP` / `< 340 HP`, or close lethal/2-stack danger).
-- * `CAST` (`INT = 2`) right before casting Shadowraze (unless close-combat `STR` lock already has `>= 85 MP`).
-- * `FIGHT` (`AGI = 1`, `+10 Damage & +10 Attack Speed`) whenever attacking Enemy Hero, Enemy Tower, pushing, or farming safely!
function H.ShouldLockStrengthTreads(bot)
    if GameTime() < (State.castTreadsHoldUntil or -100) then
        return false
    end
    local cfg = C.TREADS or {}
    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = curHp / maxHp
    if State.intent == I.RETREAT or State.emergencyRetreat or State.forcedRetreatLoc ~= nil or State.goingToFountain then
        State.strTreadsLockActive = true
        return true
    end
    if hpPct < math.max(cfg.SURVIVE_HP_PCT or 0.30, 0.38) or curHp < 340 then
        State.strTreadsLockActive = true
        return true
    end
    local enemy = W and W.s and W.s.enemy
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local d = W.s.enemyDist or GetUnitToLocationDistance(bot, enemy:GetLocation())
        -- `v7.9.18-pro` (`9074513540.dem` `10:50.67..10:55.33` `717/1496 (47.9%) <-> 748/1496 (50.0%)` Treads Churn Fix):
        -- Schmitt-trigger hysteresis (`enter <= 1020u / < 48% HP`, `exit > 1160u and >= 56% HP`) prevents `STR -> INT (-220 HP) -> AGI -> STR`
        -- oscillation when hovering near `50% HP` or `~800u` in front of an armed enemy SF!
        local distLim = State.strTreadsLockActive and 1160 or 1020
        local hpLim = State.strTreadsLockActive and 0.56 or 0.48
        if d <= distLim then
            local R = K._race
            local myStacks, myRem = U.GetShadowrazeDebuff(bot)
            local enPot = U.GetPotentialManaForRaze(enemy)
            if (R and R.valid and (R.heCanKillNow or R.heCanKillSoon or curHp <= (R.enBurstSoon or 0) + 150))
                or ((myStacks or 0) >= 2 and (myRem or 0) > 0.45 and enPot >= 75)
                or hpPct < hpLim then
                State.strTreadsLockActive = true
                return true
            end
        end
    end
    State.strTreadsLockActive = false
    return false
end

function H.ManageTreads(bot, mode)
    if not U.HasItem(bot, "item_power_treads") then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.TREADS or {}
    local opts = nil
    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = curHp / maxHp
    local curMana = bot:GetMana() or 0
    local enemyDist = (W and W.s and W.s.enemy and U.CanQuery(W.s.enemy) and W.s.enemy:IsAlive())
        and (W.s.enemyDist or GetUnitToLocationDistance(bot, W.s.enemy:GetLocation()))
        or 9999
    local needStr = H.ShouldLockStrengthTreads(bot)
    if mode == "CAST" then
        -- `v7.9.13-pro` (`0210 @ 11:24.40..11:25.80` 30x `STR<->INT` Infinite Paralysis Loop Fix!):
        -- In dangerous close combat (`enemyDist <= 1080` and `needStr or hpPct < 0.56`):
        --   * If `curMana >= 75`, DO NOT toggle `STR -> INT` (`return false` so `CastOrTurnRaze` fires `Action_UseAbility`
        --     IMMEDIATELY on this tick without stripping `-220 MaxHP` or triggering `SURVIVE` revert next tick!).
        --   * Only toggle `STR -> INT` under `needStr` when `curMana >= 63 and curMana < 75` (so `+120 MaxMP` lifts us across `75 MP`),
        --     and hold `State.castTreadsHoldUntil` for `0.22s` so `ShouldLockStrengthTreads` NEVER reverts `INT -> STR` mid-cast!
        if enemyDist <= 1080 and (needStr or hpPct < 0.56) then
            if curMana >= 75 or curMana < 63 then
                return false
            end
            local switched = U.UpdatePowerTreads(bot, "CAST", { oneUseOnly = false, urgent = true, hold = 0.30 })
            if switched then
                State.castTreadsHoldUntil = GameTime() + 0.22
            end
            return switched
        end
        opts = { oneUseOnly = false, urgent = true, hold = 0.30 }
    elseif mode == "SURVIVE" then
        if GameTime() < (State.castTreadsHoldUntil or -100) then
            return false
        end
        opts = { urgent = true, hold = 1.15 }
    else
        if needStr then
            mode = "SURVIVE"
            opts = { urgent = (hpPct < 0.38 or curHp < 340), hold = 1.10 }
        else
            mode = "FIGHT"
            opts = { hold = math.min(cfg.MODE_HOLD or 0.85, 0.85) }
        end
    end
    return U.UpdatePowerTreads(bot, mode, opts)
end

-- Safe non-cancelling Power Treads toggle helper: NEVER interrupts casts, active attack windups, or imminent CS!
function H.TrySafeTreadsSwitch(bot, mode)
    if State.actionTaken then return false end
    if not U.HasItem(bot, "item_power_treads") then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    local rec = U._unitTrack and U._unitTrack[bot]
    if rec and rec.wasAnim == true and rec.launchTick and rec.launchTick >= curTick then
        return false
    end
    if W and W.s and W.s.enemy and H.IsHeroWindupNow and H.IsHeroWindupNow(bot, W.s.enemy) then
        return false
    end
    if L and L._imminentCS then return false end
    if H.ManageTreads(bot, mode or "FIGHT") then
        State.actionTaken = true
        return true
    end
    return false
end

function H.SteerClearOfAllyT2Hull(bot, targetLoc, enemyLoc)
    if not (bot and targetLoc) then return targetLoc end
    local ws = W and W.s or nil
    local t2L = (ws and ws.allyT2Alive and ws.allyT2Loc) or nil
    if not t2L then return targetLoc end
    local bLoc = bot:GetLocation()
    local seg = targetLoc - bLoc
    local segLen = math.sqrt(seg.x * seg.x + seg.y * seg.y)
    if segLen <= 35 then return targetLoc end
    local sx, sy = seg.x / segLen, seg.y / segLen
    local rx2, ry2 = t2L.x - bLoc.x, t2L.y - bLoc.y
    local dToT2 = math.sqrt(rx2 * rx2 + ry2 * ry2)
    local proj2 = rx2 * sx + ry2 * sy
    if dToT2 <= 25 or proj2 <= -20 or proj2 >= segLen + 60 then return targetLoc end
    local cx2 = bLoc.x + sx * math.max(0, math.min(segLen, proj2))
    local cy2 = bLoc.y + sy * math.max(0, math.min(segLen, proj2))
    local dSegT2 = math.sqrt((t2L.x - cx2) * (t2L.x - cx2) + (t2L.y - cy2) * (t2L.y - cy2))
    if dSegT2 >= 205 then return targetLoc end
    local ux2, uy2 = rx2 / dToT2, ry2 / dToT2
    local pA = Vector(-uy2, ux2, 0)
    local pB = Vector(uy2, -ux2, 0)
    local pullLead = (dToT2 > 235) and -45 or 85
    local cA = Vector(t2L.x + ux2 * pullLead + pA.x * 248, t2L.y + uy2 * pullLead + pA.y * 248, bLoc.z)
    local cB = Vector(t2L.x + ux2 * pullLead + pB.x * 248, t2L.y + uy2 * pullLead + pB.y * 248, bLoc.z)
    local eRef = enemyLoc or (ws and ws.enemy and U.CanQuery(ws.enemy) and ws.enemy:GetLocation()) or nil
    local chosen = (eRef and U.DistanceBetweenLocations(cA, eRef) < U.DistanceBetweenLocations(cB, eRef)) and cB or cA
    return U.EnsurePassable(bot, chosen)
end

function H.BeginForcedRetreat(bot, loc, duration)
    if not loc then return false end
    local now = GameTime()
    local bLoc = bot:GetLocation()
    -- Project short retreat targets cleanly AND steer around T1 tower hulls & creep walls (`v4.2.0` `Demo 1` `2:47` & `4:10` Fix!)
    local stepDist = U.DistanceBetweenLocations(bLoc, loc)
    if stepDist < 220 then
        local fnt = P.GetFountain(bot)
        local dir = (stepDist > 4) and (loc - bLoc):Normalized() or (fnt - bLoc):Normalized()
        loc = bLoc + dir * 240
    end
    local same = State.forcedRetreatLoc ~= nil
        and U.DistanceBetweenLocations(State.forcedRetreatLoc, loc) <= 120
        and now < (State.forcedRetreatUntil or 0)
    State.forcedRetreatLoc = loc
    State.forcedRetreatUntil = math.max(State.forcedRetreatUntil or 0, now + (duration or 0.65))
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 1.2)
    State.actionTaken = true
    if not same then
        -- Switch Power Treads to STR on tick 1 WITHOUT poisoning `State.lastMoveLoc`, rate-limited (`>= 0.50s`)
        -- so `Action_MoveToLocation` is NEVER starved across consecutive frames!
        if (now - (State.lastRetreatTreadsToggleAt or -100)) >= 0.50 and H.ManageTreads(bot, "SURVIVE") then
            State.lastRetreatTreadsToggleAt = now
            State.lastMoveLoc = nil
            State.lastMoveTime = 0
            return true
        end
        if bot:IsUsingAbility() then
            bot:Action_ClearActions(true)
        end
    end
    local movePt = H.SteerClearOfAllyT2Hull(bot, U.EnsurePassable(bot, U.SteerAroundObstacles(bot, loc, W.s)), nil)
    State.forcedRetreatLoc = movePt
    State.lastMoveLoc = movePt
    State.lastMoveTime = now
    bot:Action_MoveToLocation(movePt)
    return true
end

function H.TickForcedRetreat(bot, s)
    if not State.forcedRetreatLoc then return false end
    local now = GameTime()
    if now >= (State.forcedRetreatUntil or 0) then
        H.ClearForcedRetreat()
        return false
    end
    local bLoc = bot:GetLocation()
    local remDist = U.DistanceBetweenLocations(bLoc, State.forcedRetreatLoc)
    -- Zero-Stall Arrival Rule: NEVER stand idle at `forcedRetreatLoc` waiting for timer expiry!
    if remDist <= 65 then
        local enemy = s and s.enemy
        local dryNeedDist = (enemy and U.CanQuery(enemy) and now < (State.dryRetreatHystUntil or 0))
            and (((U.GetDrySafeStandoffDist and U.GetDrySafeStandoffDist(bot, enemy)) or 745) + 95) or 0
        if enemy and U.CanQuery(enemy)
            and ((U.EnemyApproachSpeed(bot, enemy) > 45 and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 860)
                or (dryNeedDist > 0 and GetUnitToLocationDistance(bot, enemy:GetLocation()) < dryNeedDist)) then
            local fnt = P.GetFountain(bot)
            local ext = bLoc + (fnt - bLoc):Normalized() * 280
            local movePt = U.EnsurePassable(bot, U.SteerAroundObstacles(bot, ext, s or W.s))
            State.forcedRetreatLoc = movePt
            State.lastMoveLoc = movePt
            State.lastMoveTime = now
            bot:Action_MoveToLocation(movePt)
            State.actionTaken = true
            return true
        end
        H.ClearForcedRetreat()
        return false
    end
    return H.SmartMove(bot, State.forcedRetreatLoc, 60)
end

-- `v7.9.1` Exact Right-Click Pursuit Kinematics & Unshielded Enemy-T1 Dive Gate (`9071946472.dem` `02:39.2–02:42.9` Fix!):
-- Prevents suicidal zero-catch right-click chases (`305 MS` vs `305 MS` at `d = 720..853u` under Radiant T1 with `38 MP` & `0` creeps!).
function H.CanKinematicallyCatchForAttack(bot, enemy, enemyTowers, allyCreeps, maxCatchSec)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local atkReach = (bot:GetAttackRange() or 500) + 32
    if d <= atkReach then
        return true
    end

    local gap = d - atkReach
    local myMS = math.max(260, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 305)
    local enMS = math.max(260, (enemy.GetCurrentMovementSpeed and enemy:GetCurrentMovementSpeed()) or 305)
    local enHome = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_BASE or C.POSITIONS.RADIANT_BASE

    -- `v7.9.3` (`H01` + `auto-20261101-2135` `2:15..2:59` `26–112 HP` Fix!):
    -- Measure REAL enemy outward velocity from live velocity or frame-to-frame position deltas (`U.EnemyOutwardSpeed`),
    -- NEVER inventing `0.65 * enMS` phantom flee speed just because `eLoc` stands on the enemy half of mid!
    local awaySpeed = 0
    local dirToEn = (eLoc - bLoc):Normalized()
    local ev = (enemy.GetVelocity and enemy:GetVelocity()) or nil
    if ev and (math.abs(ev.x or 0) + math.abs(ev.y or 0)) > 15 then
        awaySpeed = (ev.x * dirToEn.x) + (ev.y * dirToEn.y)
    elseif U.EnemyOutwardSpeed then
        awaySpeed = U.EnemyOutwardSpeed(bot, enemy) or 0
    else
        local movingAwayTracker = K.IsEnemyMovingAway and K.IsEnemyMovingAway(bot, enemy)
        local enemyCloserHome = enHome and (U.DistanceBetweenLocations(eLoc, enHome) < U.DistanceBetweenLocations(bLoc, enHome) - 40)
        if movingAwayTracker and enemyCloserHome then
            awaySpeed = enMS * 0.85
        end
    end

    local closeSpeed = myMS - math.max(0, awaySpeed)
    if closeSpeed <= 14 and gap > 42 then
        return false -- Equal or slower MS while enemy actively sprints away (`305 vs 305 MS`) -> catch time is infinite!
    end
    local tCatch = gap / math.max(15, closeSpeed)
    if tCatch > (maxCatchSec or 1.75) then
        return false
    end

    -- Project where SF will stand when finally reaching `atkReach`
    local catchTravel = math.min(1200, gap + math.max(0, awaySpeed) * tCatch)
    local catchLoc = bLoc + dirToEn * catchTravel
    local towers = enemyTowers or (W and W.s and W.s.enemyTowers) or {}
    local allies = allyCreeps or (W and W.s and W.s.allyCreeps) or {}
    for _, tw in pairs(towers) do
        if tw and U.CanQuery(tw) and tw:IsAlive() then
            local tLoc = tw:GetLocation()
            local shield = LN.TowerShieldCountLoc and LN.TowerShieldCountLoc(tLoc, tw, allies, catchLoc) or 0
            -- Never run `> 40u` unshielded into Enemy T1 aggro (`880u`) chasing a fleeing enemy!
            if shield <= 0 and U.DistanceBetweenLocations(catchLoc, tLoc) < 880 then
                if gap > 40 or H.TowerBurnActive() or (bot:GetHealth() or 0) < 330 then
                    return false
                end
            end
        end
    end
    return true
end

function H.ClearForcedRetreat()
    State.forcedRetreatLoc = nil
    State.forcedRetreatUntil = 0
end

-- `v7.9.8-pro` (`1630 @ 00:32.6..00:36.0` `d=54u` & `03:36.0..03:39.0` `d=59u` Suicide De-Aggro Fix!):
-- Selects an allied lane creep safe for `Action_AttackUnit(ac, true)` aggro reset:
--   1. NEVER pick a split allied creep standing deeper on the enemy side than `enemyHero` (`acDistFnt > enDistFnt + 35`).
--   2. NEVER pick an out-of-attack-range allied creep (`da > maxReach`) unless it lies strictly behind us toward our
--      Fountain (`acDistFnt < botDistFnt - 40`), so `Action_AttackUnit` NEVER walks SF forward into enemy melee range!
function H.FindSafeDeaggroAllyCreep(bot, allyList, enemyHero)
    if not bot or not allyList then return nil, nil end
    local bLoc = bot:GetLocation()
    local fnt = P.GetFountain(bot)
    local botDistFnt = U.DistanceBetweenLocations(bLoc, fnt)
    local maxReach = math.max(500, bot:GetAttackRange() or 500) + 45
    local hasEn = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
    local enDistFnt = hasEn and U.DistanceBetweenLocations(enemyHero:GetLocation(), fnt) or math.huge

    local bestHealthy, bestHealthyDist = nil, math.huge
    local bestAny, bestAnyDist = nil, math.huge
    for _, ac in pairs(allyList) do
        if ac and U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 65 then
            local acLoc = ac:GetLocation()
            local da = GetUnitToLocationDistance(bot, acLoc)
            local acDistFnt = U.DistanceBetweenLocations(acLoc, fnt)
            local safeVsEnemy = (not hasEn) or (acDistFnt <= enDistFnt + 35)
            local noForwardWalk = (da <= maxReach) or (acDistFnt < botDistFnt - 40)
            if safeVsEnemy and noForwardWalk then
                if da < bestAnyDist then
                    bestAnyDist, bestAny = da, ac
                end
                if (ac:GetHealth() or 0) * 2 > (ac:GetMaxHealth() or 550) + 20 and da < bestHealthyDist then
                    bestHealthyDist, bestHealthy = da, ac
                end
            end
        end
    end
    return bestHealthy, bestAny
end

-- Commitment to walk out of the enemy tower (see HandleEnemyTowerSafety)
function H.ClearTowerEscape()
    State.towerEscapeLoc = nil
    State.towerEscapeUntil = 0
end

function H.CastOrTurnRaze(bot, ability, actionType, aimLoc, target)
    if State.combatPolicyActive == true and target and target.IsHero and target:IsHero()
        and not State.heroCombatAllowed then return false end
    if not ability or (target and not U.CanQuery(target)) then return false end
    if target and State.towerChaseBlockedEnemy == target then return false end
    if target and K.HasRazeStackLead(bot, target) then
        local distance = GetUnitToLocationDistance(bot, target:GetLocation())
        if K.EnemyBandsAcross(target, distance, distance, 0.7) > 0
            and not H.StackLeadThirdRazeOK(bot, target, ability, bot:GetLocation(), W.s) then return false end
    end
    if State.actionTaken then return false end
    -- `v7.9.10-pro` (`2048` `#05/#11/#26/#36/#63` `err=934u` 2-Tick Self-Cancel Fix!):
    -- `nevermore_shadowraze1/2/3` are `DOTA_ABILITY_BEHAVIOR_NO_TARGET`, so calling `Action_UseAbility` while `51°` off-axis
    -- cancels the turn order in Source 2 and triggers an instant 2-tick `HandleActiveRazeValidation` self-cancel!
    -- Always require true `H.RazeFacingOK(bot, aimLoc)` + `GetRazeHitErrorWithCurrentFacing <= hitLim` before pressing cast!
    if actionType == "CAST" and aimLoc and not H.RazeFacingOK(bot, aimLoc) then
        actionType = "TURN"
    elseif actionType == "TURN" and aimLoc and H.RazeFacingOK(bot, aimLoc) then
        actionType = "CAST"
    end

    local data = U.GetRazeAbilityData(ability)
    local isUrgentSnapOrKill = false
    if data and target and U.CanQuery(target) then
        local isHeroTarget = target.IsHero and target:IsHero()
        -- `v4.2.0` Strict Raw-Velocity Reach & Anti-Creep-Sliver Gate (`Demo 1` `0:44.47` `d=1050u` & `Demo 2` `0:47.67` `3 HP` Fix!)
        if isHeroTarget then
            if not U.WillRazeStrictlyCoverMovingTarget(bot, ability, target) then
                return false
            end
            local isLethalHeroCoil = (target:GetHealth() or 9999) <= (U.GetNRazeDamage(bot, target, 1) + 15)
            local _, remDebuff = U.GetShadowrazeDebuff(target)
            local enInPhase = K.EnemyPhase() ~= nil
            isUrgentSnapOrKill = isLethalHeroCoil or enInPhase or ((remDebuff or 99) <= 0.78)
            if U.RazeJukeOK and not U.RazeJukeOK(bot, ability, target, isLethalHeroCoil) then
                return false
            end
            if U.HeroRazeRuinsCreepCS(bot, ability, aimLoc, target, W.s) then
                return false
            end
        end
        -- Check the band against both the current and the predicted position (aimLoc): the raze lands
        -- 0.55 s later and an approaching enemy changes band in that time.
        local distNow = GetUnitToLocationDistance(bot, target:GetLocation())
        local errNow = math.abs(distNow - data.center)
        local errPred = errNow
        if aimLoc then
            errPred = math.abs(GetUnitToLocationDistance(bot, aimLoc) - data.center)
        end
        if math.min(errNow, errPred) > C.RAZE.STRICT_RADIUS + 35 then
            return false
        end
    end

    if actionType == "TURN" then
        -- Guard against an endless turn: turning 180 degrees takes ~0.1 s,
        -- so TURNing for over 0.45 s means something does not add up (target on the circle edge etc.);
        -- then TURN razes are blocked for 1 s and control goes back to the rest of the logic.
        local now = GameTime()
        if now < (State.razeTurnBlockUntil or 0) then return false end
        if (now - (State.lastTurnTick or -10)) > 0.25 then State.turnSince = now end
        State.lastTurnTick = now
        if (now - (State.turnSince or now)) > 0.45 then
            State.razeTurnBlockUntil = now + 1.0
            State.turnSince = now
            return false
        end
        local botLoc = bot:GetLocation()
        local turnLoc = aimLoc or (target and target:GetLocation()) or botLoc
        State._razeTurnStampAt = now
        return H.SmartFace(bot, turnLoc)
    elseif actionType == "CAST" then
        State._razeTurnStampAt = nil
        -- Every caller, including mirror/finish shortcuts, must cover the landing point (using desired facing when turn-masked!).
        if data and target and U.CanQuery(target) then
            local isHeroTgt2 = target.IsHero and target:IsHero()
            local effLead = isHeroTgt2 and 0.04 or (C.RAZE.LAND_LEAD or 0.08)
            local landing = U.PredictPosition(target, C.RAZE.CAST_POINT + effLead)
            local hitLim = isHeroTgt2 and (((C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274) - 14) or (C.RAZE.HIT_RADIUS - 10)
            if U.GetRazeHitErrorWithCurrentFacing(bot, landing, data.center) > hitLim then
                return false
            end
        end
        -- Before a non-urgent raze switch Power Treads to INT; SKIP the 1-tick Treads delay on urgent lethal / mirror / expiring-stack
        -- coils OR whenever `ShouldLockStrengthTreads` is active and `(bot:GetMana() or 0) >= 75`!
        if not isUrgentSnapOrKill and H.ManageTreads(bot, "CAST") then
            State.actionTaken = true
            return true
        end
        State.castTreadsHoldUntil = nil
        bot:Action_UseAbility(ability)
        H.StartRazeCast(ability, target, aimLoc, C.RAZE.HIT_RADIUS)
        H.ClearMoveCache()
        return true
    end

    return false
end

function H.GetDynamicRazeConeDeg(bot, aimLoc)
    local baseAng = (C.RAZE and C.RAZE.MAX_ANGLE_TO_CAST) or 6
    if not bot or not aimLoc then return baseAng end
    local bLoc = bot:GetLocation()
    if not bLoc then return baseAng end
    local d = math.max(200.0, U.DistanceBetweenLocations(bLoc, aimLoc))
    local dyn = math.deg(math.asin(math.min(0.38, 66.0 / d)))
    return math.max(baseAng, math.min(14.5, dyn))
end

function H.RazeFacingOK(bot, aimLoc)
    if not aimLoc then return true end
    return U.GetAngleDifference(bot, aimLoc) <= H.GetDynamicRazeConeDeg(bot, aimLoc)
end



function H.GetRazeAbilityByLabel(bot, label)
    if label == "near" then return bot:GetAbilityByName("nevermore_shadowraze1") end
    if label == "mid"  then return bot:GetAbilityByName("nevermore_shadowraze2") end
    if label == "far"  then return bot:GetAbilityByName("nevermore_shadowraze3") end
    return nil
end

-- Sort `{ "near", "mid", "far" }` in ascending order of `|predDist - center|` (`9055695956.dem` `tk=12868` `5:28` fix!):
-- At `dist = 663.9u`, `|663.9 - 700| = 36.1u` (`far` dead-center bullseye!) strictly beats `|663.9 - 450| = 213.9u`
-- (`mid` razor-edge that `S`-cancelled when enemy stepped `30u` back!). Reuses a static 3-slot array (zero GC churn).
local _CENTERED_ORDER = { "near", "mid", "far" }
function H.BestCenteredRazeOrder(bot, target)
    local d = 450
    if bot and target and U.CanQuery(target) then
        local pred = U.PredictPosition(target, C.RAZE.CAST_POINT or 0.55)
        d = GetUnitToLocationDistance(bot, pred or target:GetLocation())
    end
    local eNear = math.abs(d - 200)
    local eMid  = math.abs(d - 450)
    local eFar  = math.abs(d - 700)
    if eNear <= eMid and eNear <= eFar then
        _CENTERED_ORDER[1] = "near"
        if eMid <= eFar then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "mid", "far"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "far", "mid" end
    elseif eMid <= eNear and eMid <= eFar then
        _CENTERED_ORDER[1] = "mid"
        if eNear <= eFar then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "near", "far"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "far", "near" end
    else
        _CENTERED_ORDER[1] = "far"
        if eMid <= eNear then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "mid", "near"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "near", "mid" end
    end
    return _CENTERED_ORDER
end

-- Robust: CAST if at the current facing the circle covers the enemy both now and
-- after the cast time; TURN toward the aim point if it covers after turning; otherwise nil.
function H.GetRazeActionType(bot, ability, target)
    if not ability or not target or not U.CanQuery(target) then return nil, nil end
    local data = U.GetRazeAbilityData(ability)
    if not data then return nil, nil end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30)
    if errFacing <= limit and H.RazeFacingOK(bot, aim) then return "CAST", aim end
    if errAim <= limit then return "TURN", aim end

    -- `v7.6.0` High-Value Hero Impact-Prediction Window (`01:33.67` `R2` & `01:36.7–01:37.6` `R3` Held-Coil Fix!):
    -- Along the radial line from SF, `RobustRazeErrors` capped fleeing `305 u/s` targets at `dNow <= 728u` for `R3`
    -- even though Source 2 hits heroes out to `250 + 24 = 274u` (`d_impact <= 974u`, `dNow <= 806u`) and
    -- `HandleActiveRazeValidation` monitors every `0.033s` tick (S-cancelling for 0 mana / 0 CD if they juke!).
    local isHeroTgt = target.IsHero and target:IsHero()
    if isHeroTgt then
        local enHp = target:GetHealth() or 9999
        local oneDmg = K.MyRazeDamage(bot, target, 1)
        local stacks, rem = U.GetShadowrazeDebuff(target)
        local enPotMana = (target:GetMana() or 0) + U.GetMangoMana(target)
        local highValueWindow = (enHp <= oneDmg + 95)
            or ((stacks or 0) >= 1 and (rem or 0) >= C.RAZE.CAST_POINT + 0.06)
            or (enHp <= 290 and enPotMana < 75 and (bot:GetHealth() or 0) >= 340)
        if highValueWindow then
            local pImp = U.PredictPosition(target, C.RAZE.CAST_POINT) or target:GetLocation()
            local impLimit = C.RAZE.HIT_RADIUS + 6 -- 256u (18u inside true 274.0u hero hull edge)
            local impErrAim = U.GetRazeHitErrorWithDesiredFacing(bot, pImp, data.center)
            local impErrFac = U.GetRazeHitErrorWithCurrentFacing(bot, pImp, data.center)
            if impErrFac <= impLimit and H.RazeFacingOK(bot, pImp) then return "CAST", pImp end
            if impErrAim <= impLimit then return "TURN", pImp end
        end
    end
    return nil, aim
end

function H.GetStickLikeItem(bot)
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and (not wand.GetCurrentCharges or wand:GetCurrentCharges() > 0) then return wand end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and (not stick.GetCurrentCharges or stick:GetCurrentCharges() > 0) then return stick end
    return nil
end

function H.GetPotentialCombatMana(bot)
    local mana = bot:GetMana() or 0
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and wand.GetCurrentCharges then
        mana = mana + (wand:GetCurrentCharges() or 0) * 15
    end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and stick.GetCurrentCharges then
        mana = mana + (stick:GetCurrentCharges() or 0) * 15
    end
    mana = mana + U.GetMangoMana(bot) -- By charges
    return mana
end

function H.TryUseBurstManaItem(bot, allowMango)
    local item = H.GetStickLikeItem(bot)
    if not item and allowMango then
        item = U.GetActiveItemByName(bot, "item_enchanted_mango")
    end
    if not item then return false end
    bot:Action_UseAbility(item)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

function H.IsInHeroAttackAnimation(bot)
    if not State.heroAttackTarget then return false end
    if not State.heroAttackTarget:IsAlive() then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local target = bot:GetAttackTarget()
    if target ~= State.heroAttackTarget then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local elapsed = GameTime() - State.heroAttackTime
    local bat = bot:GetSecondsPerAttack() or 1.7
    if elapsed < bat + 0.1 then
        return true
    end
    State.heroAttackTarget = nil
    State.heroAttackTime = 0
    return false
end

function H.IsSameAttackTarget(bot, target)
    return U.IsAttackingAction(bot) and bot:GetAttackTarget() == target
end

function H.IssueHeroAttack(bot, enemyHero)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.towerChaseBlockedEnemy == enemyHero then return false end
    local distance = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local myRange = (bot.GetAttackRange and bot:GetAttackRange()) or 500
    -- Backswing Uphill Orb-Walk (`0.000s` DPS loss!):
    -- While right-click is cooling down in backswing (`remAtkCD > 0.16`), step uphill onto equal elevation (`z >= enemy`)
    -- inside attack range so subsequent attacks never suffer the `25%` Source 2 river-to-highground miss penalty!
    if type(GetHeightLevel) == "function" then
        local bLocNow, eLocNow = bot:GetLocation(), enemyHero:GetLocation()
        if GetHeightLevel(bLocNow) < GetHeightLevel(eLocNow) then
            local lastAtkT = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
            local spaNow = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.2
            local apNow = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.5
            local sinceAtk = GameTime() - lastAtkT
            local inBackswingWindow = (lastAtkT > 0) and (sinceAtk > 0.04) and ((spaNow - sinceAtk) > (apNow + 0.10))
            if inBackswingWindow then
                local hgOrb = P.AvoidUphillMiss(bot, bLocNow, eLocNow, myRange - 15)
                if hgOrb and GetHeightLevel(hgOrb) >= GetHeightLevel(eLocNow)
                    and U.DistanceBetweenLocations(bLocNow, hgOrb) > 10 then
                    H.SmartMove(bot, hgOrb, 15)
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = GameTime()
                    return true
                end
                -- If own ramp is out of range, orb-walk directly up enemy's highground lip when winning all-in!
                if distance > 180 and ((bot:GetHealth() or 0) >= 120) then
                    H.SmartMove(bot, eLocNow, 25)
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = GameTime()
                    return true
                end
            end
        end
    end
    local hullAtkReach = math.max(525, myRange) + 48
    local domRightClickOk = K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemyHero, W and W.s or nil)
    if K.HasRazeStackLead(bot, enemyHero) and distance > hullAtkReach and not domRightClickOk then
        if K.EnemyBandsAcross(enemyHero, distance, distance, 0.7) > 0 then return false end
        local stop = enemyHero:GetLocation() + (bot:GetLocation()-enemyHero:GetLocation()):Normalized()
            * math.min(distance, hullAtkReach)
        if not K.StackLeadStepSafe(bot, enemyHero, stop) then return false end
    elseif domRightClickOk and distance > hullAtkReach then
        -- Even when right-click dominant, do not walk `< 435u` into ready enemy `R1` just to chase if already out of range
        local stop = enemyHero:GetLocation() + (bot:GetLocation()-enemyHero:GetLocation()):Normalized()
            * math.min(distance, hullAtkReach)
        if U.DistanceBetweenLocations(stop, enemyHero:GetLocation()) < 435
            and K.EnemyManaBudget(enemyHero, true) >= 75
            and K.EnemyRazeReadyIn("near") <= 0.8 then
            return false
        end
    end
    local sameTarget = H.IsSameAttackTarget(bot, enemyHero)
    -- Switch Power Treads to Agility (`FIGHT`: `+10 Damage & +10 AS`) before initiating a non-one-shot hero attack,
    -- OR during the post-launch attack backswing window while attacking `enemyHero` (`9070886384.dem` `06:55` Fix)!
    local enHpForPt = enemyHero:GetHealth() or 9999
    local oneShotSkipPt = enHpForPt <= K.AttackDamageVs(bot, enemyHero) * 1.15
    if not oneShotSkipPt and U.HasItem(bot, "item_power_treads") then
        local lastAtkPt = bot:GetLastAttackTime() or -100
        local spaPt = math.max(0.65, bot:GetSecondsPerAttack() or 1.40)
        local apPt = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        local sincePt = GameTime() - lastAtkPt
        local inSafePtWindow = (not sameTarget) or (lastAtkPt > 0 and sincePt >= 0.05 and (spaPt - sincePt) >= (apPt + 0.12))
        if inSafePtWindow and H.TrySafeTreadsSwitch(bot, "FIGHT") then
            State.heroAttackTarget = enemyHero
            State.heroAttackTime = GameTime()
            return true
        end
    end
    if not sameTarget then
        local nowAtk = GameTime()
        -- Track exact Source 2 Lane Creep Aggro state (`500u` trigger radius, `3.00s` global CD, `2.30s` forced chase):
        if nowAtk >= (State.myCreepAggroCdUntil or 0) then
            local creepsIn500 = false
            local eCreepsNow = (W and W.s and W.s.enemyCreeps) or (bot.GetNearbyLaneCreeps and bot:GetNearbyLaneCreeps(525, true)) or {}
            for _, ec in pairs(eCreepsNow) do
                if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 500 then
                    creepsIn500 = true
                    break
                end
            end
            State.myCreepAggroCdUntil = nowAtk + 3.00
            if creepsIn500 then
                State.myCreepChaseUntil = nowAtk + 2.30
            end
        end
        bot:Action_AttackUnit(enemyHero, true)
        H.ClearMoveCache()
        State.attackTarget = enemyHero
        State.attackStartTime = nowAtk
        State.heroAttackTarget = enemyHero
        State.heroAttackTime = nowAtk
        State.heroAttackStartLAT = bot:GetLastAttackTime() or -100
        if distance <= hullAtkReach + 18 then
            local apCommit = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
            State.heroAttackCommitUntil = nowAtk + math.min(0.74, apCommit + 0.24)
        end
        State.firedThisAttack = false
    elseif State.attackTarget ~= enemyHero then
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    if distance <= hullAtkReach + 12 and (bot:GetLastAttackTime() or -100) <= (State.heroAttackStartLAT or -100) + 0.004 then
        local apHold = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        if GameTime() >= (State.heroAttackCommitUntil or -100) then
            local spaHold = math.max(0.65, bot:GetSecondsPerAttack() or 1.45)
            if (GameTime() - (bot:GetLastAttackTime() or -100)) >= (spaHold * 0.85) then
                State.heroAttackStartLAT = bot:GetLastAttackTime() or -100
                State.heroAttackCommitUntil = GameTime() + math.min(0.74, apHold + 0.24)
            end
        end
    end
    State.heroAttackTarget = enemyHero
    State.heroAttackTime = GameTime()
    return true
end

-- The attack animation detector uses the ANIMATION (GetAnimActivity/GetAnimCycle), not the order time:
-- the attack order is issued 0-1 s before the real swing (the hero is still walking/turning),
-- so an order-time lock expired before the actual swing and the next
-- handler (creep aggro drop, last hit, raze turn, positioning) cancelled the attack a fraction
-- of a second before the attack point. Called every tick before decisions are made.
function H.UpdateAttackActivity(bot)
    local now = GameTime()
    local act, cyc = nil, nil
    if bot.GetAnimActivity then
        local ok, a = pcall(bot.GetAnimActivity, bot)
        if ok and type(a) == "number" then act = a end
    end
    if act == nil then
        State.atkAnimAvailable = false
        State.atkAnimSince = nil
        return
    end
    if bot.GetAnimCycle then
        local ok, c = pcall(bot.GetAnimCycle, bot)
        if ok and type(c) == "number" then cyc = c end
    end
    State.atkAnimAvailable = true
    local A1 = _G.ACTIVITY_ATTACK or 1503
    local A2 = _G.ACTIVITY_ATTACK2 or 1504
    local A3 = _G.ACTIVITY_ATTACK_EVENT or 1505
    local isAtk = (act == A1 or act == A2 or act == A3)
    if isAtk then
        local restarted = cyc and State.atkAnimCycle and (cyc < State.atkAnimCycle - 0.05)
        if not State.atkAnimSince or restarted then State.atkAnimSince = now end
    else
        State.atkAnimSince = nil
    end
    State.atkAnimCycle = cyc
end

-- Is a right-click swing at the enemy hero in progress (attack point not reached yet)?
-- `v7.8.0` (`9070886384.dem` `00:55.80–01:03.27` 8x Edge-Cancel Fix):
-- Holds BOTH during `rec.wasAnim == true` AND during the `2–3` turn-alignment frames of `State.heroAttackCommitUntil`
-- while `d <= 655u` (well inside Source 2's `823u` attack motion buffer!), clearing `0.000s` on `m_flLastAttackTime` launch!
function H.IsHeroWindupNow(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false end
    local latNow = bot:GetLastAttackTime() or -100
    if State.heroAttackStartLAT and latNow > State.heroAttackStartLAT + 0.004 then
        State.heroAttackCommitUntil = 0
    end
    local okT, target = pcall(bot.GetAttackTarget, bot)
    local targetingHero = (okT and target == enemyHero)
        or (State.heroAttackTarget == enemyHero and (GameTime() - (State.heroAttackTime or -100)) <= 0.75)
    if not targetingHero then return false end
    if not U.IsAttackingAction(bot) then return false end
    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    local rec = U._unitTrack and U._unitTrack[bot]
    if rec ~= nil and rec.wasAnim == true and rec.launchTick ~= nil and rec.launchTick >= curTick then
        return true
    end
    if GameTime() < (State.heroAttackCommitUntil or 0)
        and latNow <= (State.heroAttackStartLAT or -100) + 0.004
        and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 655 then
        return true
    end
    return false
end

-- "Let the attack land": while a swing at the hero is in progress, no non-emergency handler issues
-- orders (70-90 damage in 0.3-0.5 s beats all of them). Exceptions: his burst right now
-- is lethal, instant lethal coil is ready, the enemy tower is hitting us, emergency retreat.
function H.ShouldHoldForHeroWindup(bot, s, enemyHero, race)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not H.IsHeroWindupNow(bot, enemyHero) then return false end
    if State.emergencyRetreat then return false end
    if race and race.valid and race.heCanKillNow then return false end
    if U.CanQuickTurnKillWithRaze(bot, enemyHero) then return false end
    local t1 = s and s.enemyT1
    if t1 and U.CanQuery(t1) and t1.GetAttackTarget then
        local okT, tgt = pcall(t1.GetAttackTarget, t1)
        if okT and tgt == bot then return false end
    end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(0.5) then return false end
    return true
end

function H.IsHeroAttackWindupLocked(bot)
    local target = bot:GetAttackTarget()
    if not U.IsAttackingAction(bot) or not target or not target:IsAlive() then
        return false
    end
    if not (target.IsHero and target:IsHero()) then
        return false
    end
    if State.attackTarget ~= target then
        State.attackTarget = target
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    local elapsed = GameTime() - (State.attackStartTime or 0)
    local ap = bot:GetAttackPoint() or 0
    return elapsed < (ap + 0.06)
end

-- "Shield" under the tower: a live (non-siege) allied creep inside the tower radius that is CLOSER to the
-- tower than refLoc (the bot by default), with the tower not currently hitting us. The old check
-- ("any creep within 760 of the tower") missed the case where the creeps walked off after the enemy
-- while the bot stayed the tower's closest target.
function H._hasTankCreepUnderTower(tower, allyCreeps, refLoc)
    if not tower or not tower:IsAlive() then return false end
    local bot = GetBot()
    local tgt = tower.GetAttackTarget and tower:GetAttackTarget()
    if bot and tgt == bot then return false end
    -- "Burn" after leaving the tower: it was hitting US just now - do not trust the shield
    -- (last hits/approaches only from outside its radius until the burn expires)
    if H.TowerBurnActive and H.TowerBurnActive() then return false end
    local ref = refLoc or (bot and bot:GetLocation())
    local count = LN.TowerShieldCount(tower, allyCreeps, ref)
    return count >= 1
end

-- A creep tank under the tower does not justify going in when the enemy hero is nearby and we are weaker
-- (he is at full HP, we are not): in that trade under the tower we simply die while wandering between points.
function H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc)
    if H._hasTankCreepUnderTower(tower, allyCreeps, targetLoc) then
        local eh = H._enemyHeroNear and H._enemyHeroNear
        if eh and U.CanQuery(eh) then
            local d = GetUnitToLocationDistance(eh, targetLoc)
            if d <= 900 then
                local myHp, enHp = bot:GetHealth(), eh:GetHealth()
                if myHp < enHp - 100 or (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.50 then
                    return false
                end
            end
        end
        return true
    end
    return false
end

function H.GetSafeApproach(bot, targetLoc, enemyTowers, allyCreeps)
    if W.s and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc then
        local tLoc = W.s.enemyT1Loc
        local noReenterActive = (GameTime() < (State.noReenterEnemyT1Until or -1000))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.8))
        if noReenterActive and U.DistanceBetweenLocations(targetLoc, tLoc) < 935 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 935
        end
        if U.DistanceBetweenLocations(targetLoc, tLoc) < 890
            and LN.TowerShieldCountLoc(tLoc, W.s.enemyT1, allyCreeps, targetLoc) < 1 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 890
        end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 830 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 885
                end
            end
        end
    end
    return targetLoc
end

function H.GetSafeApproachLoose(bot, targetLoc, enemyTowers, allyCreeps)
    if W.s and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc then
        local tLoc = W.s.enemyT1Loc
        local noReenterActive = (GameTime() < (State.noReenterEnemyT1Until or -1000))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.8))
        if noReenterActive and U.DistanceBetweenLocations(targetLoc, tLoc) < 935 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 935
        end
        if U.DistanceBetweenLocations(targetLoc, tLoc) < 890
            and LN.TowerShieldCountLoc(tLoc, W.s.enemyT1, allyCreeps, targetLoc) < 1 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 890
        end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 740 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 815
                end
            end
        end
    end
    return targetLoc
end

-- Single entry point for ANY approach toward the enemy hero:
-- 1) do not chase a fleeing enemy with equal/greater speed (pointless, we lose creeps);
-- 2) leash at his T1: do not enter the tower radius without a creep shield;
-- 3) the usual point correction relative to the tower.
-- Can we close to distance dAfter without entering our own "band fear" range?
function H.ApproachIntoBandOK(bot, enemyHero, dAfter)
    if State.intent == I.RETREAT then return false end
    local R = K._race
    local killing = (R and R.valid and R.canKillSoon) or State.hunting -- Hunting = finishing
    -- With a fresh stack on us, closing into the near band (< 470 = his right click + near
    -- raze with the stack bonus) is forbidden except to finish; with 2+ stacks we do not close at all.
    -- Previously only "band fear" was checked (it did not trigger without a stack when edge >= 0), so the mirror /
    -- stack finish walked a stacked bot right up to the enemy.
    if not killing then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local nearFear = (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470
            if dAfter < nearFear then return false end
            if st >= 2 then return false end
        end
    end
    -- Single minimum distance (band fear + the "with a stack, stay out of his ready bands" rule)
    local fearMin = U.GetMinDistWithStack(bot, enemyHero)
    if fearMin <= 0 then return true end
    return dAfter >= fearMin - 20
end

function H.ApproachEnemyPoint(bot, enemyHero, loc, threshold, enemyTowers, allyCreeps, allowDive, stackAbility)
    if State.combatPolicyActive == true and enemyHero and not State.heroCombatAllowed then return false end
    if not loc then return false end
    if State.actionTaken then return false end
    if State.towerChaseBlockedEnemy == enemyHero and enemyHero then return false end
    local third = stackAbility and H.StackLeadThirdRazeOK(bot, enemyHero, stackAbility, loc, W.s)
    if enemyHero and not K.StackLeadStepSafe(bot, enemyHero, loc) and not third then return false end
    if allowDive and H.TowerBurnActive() then allowDive = false end -- No dives after leaving the T1
    if enemyHero and U.CanQuery(enemyHero) then
        local botLoc = bot:GetLocation()
        local enLoc = enemyHero:GetLocation()
        local dNow = U.DistanceBetweenLocations(botLoc, enLoc)
        local dAfter = U.DistanceBetweenLocations(loc, enLoc)
        if dAfter < dNow - 60 then
            -- Closing in: does it make sense?
            if not K.CanCatch(bot, enemyHero, dAfter, 2.0) then return false end
            -- Do not enter his READY band if our own fear triggers there too
            -- (ShouldRetreatFromEnemyRazeStack): otherwise we get an "approach - get scared - back off" loop.
            if not allowDive and not third and not H.ApproachIntoBandOK(bot, enemyHero, dAfter) then return false end
        end
        local t1 = W.s.enemyT1
        if t1 and not allowDive then
            local okLoc, tLoc = pcall(t1.GetLocation, t1)
            if okLoc and tLoc then
                local leash = (C.TOWER and C.TOWER.CHASE_LEASH) or 820
                if U.DistanceBetweenLocations(tLoc, loc) < leash and LN.TowerDanger(bot, t1, allyCreeps, loc) >= 2 then
                    return false
                end
                -- Do not chase the enemy BEHIND his T1. The leash above only checked the radius, so
                -- a point on the far side of the tower passed the check - and walking back would mean
                -- crossing its attack radius (hence the freezes under the tower).
                if LN.IsBeyondTower(bot, t1, loc) then return false end
            end
        end
    end
    loc = H.GetSafeApproachLoose(bot, loc, enemyTowers or {}, allyCreeps or {})
    if U.DistanceBetweenLocations(bot:GetLocation(), loc) <= (threshold or 35) then return false end
    return H.SmartMove(bot, loc, threshold or 35, false, stackAbility)
end

function H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    local enemy = H._enemyHeroNear
    if enemy and K.HasRazeStackLead(bot, enemy) then
        local walk = math.max(0, U.DistanceBetweenLocations(botLoc, targetLoc) - bot:GetAttackRange())
        local stop = botLoc + (targetLoc - botLoc):Normalized() * walk
        if not K.StackLeadStepSafe(bot, enemy, stop) then return false end
    end
    local atkR = (bot.GetAttackRange and bot:GetAttackRange()) or 500
    local walkDist = math.max(0, U.DistanceBetweenLocations(botLoc, targetLoc) - math.max(480, atkR - 15))
    local attackStandLoc = (walkDist > 0.5)
        and (botLoc + (targetLoc - botLoc):Normalized() * walkDist)
        or botLoc
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, botLoc) < 860 then return false end
                if GetUnitToLocationDistance(tower, attackStandLoc) < 860 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToHarass(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            -- A right click on a hero inside the tower radius draws the tower onto us REGARDLESS of
            -- creeps (the tower aggros on hero attacks) - so we always stay outside its radius
            -- (+30 for the step toward the target). A creep shield only relaxes the requirement on the target position.
            if GetUnitToLocationDistance(tower, botLoc) < 790 then return false end
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 320 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local towerToEnemy = GetUnitToLocationDistance(tower, enemyHero:GetLocation())
            if towerToEnemy <= 850 then
                if H._hasTankCreepUnderTower(tower, allyCreeps) then
                    return true
                end
                if GetUnitToLocationDistance(bot, tower:GetLocation()) > 810 then
                    return true
                end
                return false
            end
        end
    end
    return true
end

function H.GetEnemyT1Tower(enemyTowers)
    for _, tower in pairs(enemyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                return tower
            end
        end
    end
    return nil
end

-- Bot near its own T1 (within radius of the tower)
function H.IsNearOwnT1(bot, radius)
    local s = W.s
    local t1 = s and s.allyT1
    if not t1 then return false end
    local okL, tl = pcall(t1.GetLocation, t1)
    if not okL or not tl then return false end
    return GetUnitToLocationDistance(bot, tl) <= (radius or 400)
end

function H.IsBotUnderEnemyT1(bot, enemyTowers)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 then return false, nil end
    if GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880 then
        return true, t1
    end
    return false, t1
end

function H.HasRazeResource(bot)
    return H.GetPotentialCombatMana(bot) >= 75
end

function H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.TowerBurnActive() then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if bot:GetLevel() < 5 then return false end
    if not H.HasRazeResource(bot) then return false end
    local enemyCanPunish = U.EnemyCanUseRaze(enemyHero)
    local atkActual = enemyHero:GetActualIncomingDamage(bot:GetAttackDamage() or 0, DAMAGE_TYPE_PHYSICAL)
    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    local enemyVeryLow = enemyHero:GetHealth() <= (oneRaze + atkActual * 2.0) or enemyHero:GetHealth() <= (twoRaze + atkActual)
    if not enemyCanPunish then return true end
    if enemyVeryLow then return true end
    return false
end

function H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if not H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    U.UseGlyph(bot)
    State.actionTaken = true
    return true
end

function H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, mode)
    local safeLoc = P.GetLasthitPosition(bot, enemyCreeps or {}, allyCreeps or {}, nil, mode or "PASSIVE")
    local fountain = P.GetFountain(bot)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    local tLoc = (t1 and t1:IsAlive() and t1:GetLocation()) or (W.s and W.s.enemyT1Alive and W.s.enemyT1Loc) or nil
    if tLoc then
        local dir = (fountain - tLoc):Normalized()
        local extra = 150
        safeLoc = tLoc + dir * (865 + C.T1_SAFETY.RETREAT_BUFFER + extra)
    end
    return safeLoc
end

function H.HandleEnemyTowerSafety(bot, s, enemyHero)
    -- CRITICAL TWO-PART FIX (`9056568054.dem` `tk=14006` `837.5u` stall & `9056774541.dem` `tk=6338` `817.0u` FoW stall):
    --   1. Drive tower evacuation from `s.enemyT1Alive` + `s.enemyT1Loc` EVEN WHEN `s.enemyT1 == nil` in Highground FoW!
    --   2. True Dota 2 C++ T1 reach center-to-center = `700 + 144 + 24 = 868.0u` (NOT `720u`!), with full exit at `965u+`!
    local t1 = s and s.enemyT1 or nil
    if not (s and s.enemyT1Alive) then
        State.t1EnterTime = nil
        H.ClearTowerEscape()
        return false
    end
    local tLoc = (t1 and U.CanQuery(t1) and t1:GetLocation()) or (s and s.enemyT1Loc) or nil
    if not tLoc then return false end
    local cfg = C.TOWER or {}
    local escapeRad = math.max(cfg.ESCAPE_RADIUS or 965, 965)
    local d = GetUnitToLocationDistance(bot, tLoc)
    local now = GameTime()

    -- The tower is nearly down (visible & <= 3 hits) - finish it (breaking the T1 wins the game)
    if t1 and LN.IsTowerFinishable(bot, t1) then
        State.t1EnterTime = nil
        H.ClearTowerEscape()
        return false
    end

    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local towerBoltIncoming = false
    for _, p in pairs((bot.GetIncomingTrackingProjectiles and bot:GetIncomingTrackingProjectiles()) or {}) do
        if p and p.is_attack and p.caster and p.caster.IsTower then
            local okTw, isTw = pcall(p.caster.IsTower, p.caster)
            if okTw and isTw then towerBoltIncoming = true; break end
        end
    end

    -- `9069188041.dem` `01:44.0-01:46.3` T1 Exit Freeze Fix:
    -- Enemy T1 max attack range is `868u` (`700 + 144 + 24`). Once `d > escapeRad` (`>= 980u`), T1 CANNOT fire
    -- any new attack! Previously `towerBoltIncoming` (`0.67s` flight) + `WasRecentlyDamagedByTower(1.25)` kept
    -- `onMeEarly = true` at `d = 1030u`, calling `SmartMove` to `State.towerEscapeLoc` (`dist == 0`, `v == 0`)
    -- and freezing SF motionless for `1.2-1.9s` while the human SF walked up and landed 2 free attacks!
    local onMeEarly = false
    if d <= 905 then
        onMeEarly = towerBoltIncoming
        if not onMeEarly and t1 and U.CanQuery(t1) and t1.GetAttackTarget then
            local okTE, tgtE = pcall(t1.GetAttackTarget, t1)
            if okTE and tgtE == bot then onMeEarly = true end
        end
        if not onMeEarly and bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.25) then
            onMeEarly = true
        end
    elseif t1 and U.CanQuery(t1) and t1.GetAttackTarget then
        local okTE, tgtE = pcall(t1.GetAttackTarget, t1)
        if okTE and tgtE == bot then onMeEarly = true end
    end

    if (State.towerEscapeUntil or 0) > now and State.towerEscapeLoc then
        if d > escapeRad and not onMeEarly then
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.2)
            H.ClearTowerEscape()
        elseif not onMeEarly and H.LaneEnemyAbsent(s) and LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation()) >= 1 then
            H.ClearTowerEscape()
            H.ClearForcedRetreat()
        else
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.2)
            if GetUnitToLocationDistance(bot, State.towerEscapeLoc) <= 75 then
                local fnt = P.GetFountain(bot)
                State.towerEscapeLoc = bot:GetLocation() + (fnt - bot:GetLocation()):Normalized() * 240
            end
            H.SmartMove(bot, State.towerEscapeLoc, 45)
            State.actionTaken = true
            return true
        end
    elseif (State.towerEscapeUntil or 0) > 0 then
        H.ClearTowerEscape()
    end

    -- True C++ T1 reach center-to-center = `868.0u` (`700 + 144 + 24`): `885u` eliminates the entire `[720u..868u]` blind zone!
    -- Pre-horn ward-return guard (`9072220529.dem` `tk=4390..4440` `dRT1=881u` bounce fix): while walking around Enemy T1
    -- before `0:02` with `0` tower aggro (`not onMeEarly`), only trigger emergency pushback inside `785u` (`> 724u` night sight/atk)!
    local dtimeTw = (type(DotaTime) == "function") and DotaTime() or 99
    local preHornSkirt = (dtimeTw < 2.0) and not onMeEarly
    local inRange = d <= (preHornSkirt and 785 or 885)
    if not inRange then State.t1EnterTime = nil end
    if d > escapeRad and not onMeEarly then return false end
    if State.actionTaken then return false end

    local onMe = onMeEarly
    local reason = nil
    if onMe then
        State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.6)
        reason = "tower on me"
    elseif inRange then
        if not State.t1EnterTime then State.t1EnterTime = now end
        local shield = LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation())
        local shieldHpTotal = 0
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), tLoc) <= 780 then
                shieldHpTotal = shieldHpTotal + (ac:GetHealth() or 0)
            end
        end
        if shield == 0 or (shield == 1 and shieldHpTotal <= 185 and not H.LaneEnemyAbsent(s)) then
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.6)
            reason = "no shield"
        else
            local cur = bot:GetAttackTarget()
            local heroEngaged = State.aimingRaze and true or false
            if not heroEngaged and (not t1 or cur ~= t1) and (now - (State.heroAttackTime or -10)) <= 1.5 then heroEngaged = true end
            if not heroEngaged and cur and U.CanQuery(cur) and cur.IsHero and cur:IsHero() then heroEngaged = true end
            if heroEngaged and (now - State.t1EnterTime) > (cfg.DIVE_MAX_TIME or 1.0) then
                reason = "dive budget"
            end
        end
    end

    if not reason and inRange and enemyHero and U.CanQuery(enemyHero) and bot.WasRecentlyDamagedByHero then
        if bot:WasRecentlyDamagedByHero(enemyHero, 1.5) then
            local killing = U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            local committed = GameTime() < (State.commitKillUntil or 0)
            local R = K._race
            local shieldHold = (not onMe) and LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation()) >= 1
                and (bot:GetHealth() or 0) >= 520 and (t1 ~= nil and bot:GetAttackTarget() == t1)
                and not (R and R.valid and R.heCanKillSoon)
            if not killing and not committed and not shieldHold then
                reason = "hero hits me under T1"
            end
        end
    end
    if not reason then return false end

    if reason ~= "no shield" and enemyHero and U.CanQuery(enemyHero) then
        local hp = bot:GetHealth()
        local maxHp = math.max(1, bot:GetMaxHealth())
        local tDmg = 100
        if t1 and U.CanQuery(t1) and t1.GetAttackDamage then
            local okD, v = pcall(t1.GetAttackDamage, t1)
            if okD and type(v) == "number" and v > 0 then tDmg = v end
        end
        local hpOk = hp >= maxHp * 0.40 and hp >= tDmg * 3
        local within = (now - (State.t1EnterTime or now)) <= (cfg.DIVE_MAX_TIME or 1.0)
        if hpOk and within then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if U.CanOneShotEnemyHero(bot, enemyHero) and dist <= bot:GetAttackRange() + 60 then
                return false
            end
            if not onMe and U.CanQuickTurnKillWithRaze(bot, enemyHero) then
                return false
            end
        end
    end
    -- `v7.9.16-pro` (`1343 @ 07:34.47` `979 HP` Bot vs `41 HP` Human at Outer T1 Skirt Fix):
    -- When healthy (`hp >= 550` & `>= 55%` MaxHP), NOT tanking tower aggro (`not onMe`), and standing at the outer
    -- T1 skirt (`d >= 720u`), allow an immediate `0.55s` 1-coil (`CanQuickTurnKillWithRaze`) or already-in-range
    -- 1-shot right-click (`dist <= atkRange + 20`) without chasing unshielded deep under T1 (`2:42` stays 100% blocked!).
    if reason == "no shield" and (not onMe) and d >= 720 and enemyHero and U.CanQuery(enemyHero) then
        local hp = bot:GetHealth() or 0
        local maxHp = math.max(1, bot:GetMaxHealth() or 1)
        local within = (now - (State.t1EnterTime or now)) <= 0.85
        if within and hp >= 550 and hp >= maxHp * 0.55 then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if U.CanQuickTurnKillWithRaze(bot, enemyHero)
                or (U.CanOneShotEnemyHero(bot, enemyHero) and dist <= (bot:GetAttackRange() or 525) + 20) then
                return false
            end
        end
    end

    local burn = cfg.BURN_SEC or 2.5
    if (now - (State.lastTowerEscapeAt or -100)) < (cfg.REPEAT_WINDOW or 10) then burn = cfg.BURN_REPEAT_SEC or 6.0 end
    State.lastTowerEscapeAt = now
    State.towerBurnUntil = now + burn
    State.t1EnterTime = nil
    local escape = LN.TowerEscapePointLoc(bot, tLoc)
    State.towerEscapeLoc = escape
    State.towerEscapeUntil = now + (cfg.ESCAPE_COMMIT_SEC or 3.0)
    H.BeginForcedRetreat(bot, escape, 0.9)
    if U.DEBUG then print(string.format("[SF-BOT] tower escape (%s) d=%.0f", reason, d)) end
    return true
end

-- The tower burn is active (we had to leave the T1 recently)
function H.TowerBurnActive()
    return GameTime() < (State.towerBurnUntil or 0)
end

-- A few of my hits are left on the enemy T1 - hit it no matter what:
-- in 1v1 breaking the T1 is a win. The HP threshold is held by LN.IsTowerFinishable (HP >= the number
-- of hits needed converted into its shots); a lethal hero finish still outranks the tower.
function H.HandleEnemyTowerFinish(bot, s, enemyHero)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local t1 = s.enemyT1
    if not t1 or not LN.IsTowerFinishable(bot, t1) then return false end
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okL or not tLoc then return false end
    if GetUnitToLocationDistance(bot, tLoc) > ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then return false end
    if enemyHero and U.CanQuery(enemyHero) then
        if U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero) then
            return false
        end
    end
    if LN.TowerHitsToKill(bot, t1) > 1 and H.TrySafeTreadsSwitch(bot, "FIGHT") then
        return true
    end
    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= t1 then
        bot:Action_AttackUnit(t1, true)
        H.ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

function H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps)
    if not ability or not enemyHero or not U.CanQuery(enemyHero) then return false end
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 or not t1:IsAlive() then return false end
    if H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local enemyNearTower = GetUnitToLocationDistance(t1, enemyHero:GetLocation()) <= 900
    if not enemyNearTower then return false end
    local botUnderT1 = GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880
    local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, data.center)
    local setupUnderT1 = setupPos and U.DistanceBetweenLocations(setupPos, t1:GetLocation()) < 900
    if botUnderT1 or setupUnderT1 then
        return true
    end
    return false
end

function H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana()<75 or not U.IsRazeAbilityCastable(bot,H.GetRazeAbilityByLabel(bot,"mid")) then return false end
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or hitLabel ~= "mid" then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local minHold = C.RAZE.NEAR_CENTER + 110
    local maxHold = C.RAZE.FAR_CENTER - 110
    local desired = C.RAZE.MID_CENTER
    if dist >= minHold and dist <= maxHold then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    return H.SmartMove(bot, holdLoc, 35)
end

function H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil, nil, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return false, nil, nil, nil end
    local nearRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
    local atkRaw = bot:GetAttackDamage() or 0
    local atkActual = enemyHero:GetActualIncomingDamage(atkRaw, DAMAGE_TYPE_PHYSICAL)
    if atkActual <= 0 then return false, nil, nil, nil end
    local hpAfterRaze = enemyHero:GetHealth() - nearRazeDmg
    if hpAfterRaze <= 0 then return false, nearRazeDmg, atkActual, 0 end
    local attacksNeeded = math.ceil(hpAfterRaze / atkActual)
    if attacksNeeded >= 1 and attacksNeeded <= 2 then
        return true, nearRazeDmg, atkActual, attacksNeeded
    end
    return false, nearRazeDmg, atkActual, attacksNeeded
end

function H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not H.HasRazeResource(bot) then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        return false
    end
    local canFinish, _, _, attacksNeeded = H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not canFinish then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not canOneShot then return false end
    if not H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps) and not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist <= attackRange then
        return H.IssueHeroAttack(bot, enemyHero)
    end
    if dist <= attackRange + 260 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 220)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.GetPotentialCombatMana(bot) < 150 then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    if not q or q:GetLevel() == 0 then return false end

    local stacks = U.GetShadowrazeDebuff(enemyHero)
    if stacks ~= 0 then return false end

    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    if twoRaze < enemyHero:GetHealth() then return false end
    if oneRaze >= enemyHero:GetHealth() then return false end

    local candidates = {
        { label = "mid",  ability = w, center = C.RAZE.MID_CENTER  },
        { label = "far",  ability = e, center = C.RAZE.FAR_CENTER  },
        { label = "near", ability = q, center = C.RAZE.NEAR_CENTER },
    }

    for _, c in ipairs(candidates) do
        if c.ability and U.IsRazeAbilityCastable(bot, c.ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, c.ability, enemyTowers, allyCreeps) then
            local actionType, aimLoc = H.GetRazeActionType(bot, c.ability, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, c.ability, actionType, aimLoc, enemyHero) then
                return true
            end
        end
    end

    local opener = nil
    if w and U.IsRazeAbilityCastable(bot, w) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, w, enemyTowers, allyCreeps) then
        opener = { ability = w, center = C.RAZE.MID_CENTER, label = "mid" }
    elseif e and U.IsRazeAbilityCastable(bot, e) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, e, enemyTowers, allyCreeps) then
        opener = { ability = e, center = C.RAZE.FAR_CENTER, label = "far" }
    elseif q and U.IsRazeAbilityCastable(bot, q) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        opener = { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" }
    end

    if opener then
        local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, opener.center)
        if setupPos then
            local currentDist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if math.abs(currentDist - opener.center) > 90 then
                if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                    return true
                end
            end
        end
    end

    return false
end

function H.TryRazeEnemy(bot, enemyHero, current_mode, enemyTowers, allyCreeps, isLethalChase, forceExtend)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end

    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, current_mode, isLethalChase or false, forceExtend or false)
    if ability then
        local data = U.GetRazeAbilityData(ability)
        local predDist = GetUnitToLocationDistance(bot, aimLoc or enemyHero:GetLocation())
        local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
        if data and data.label == "near" and predDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and data.label == "near" and underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and (data.label == "mid" or data.label == "far") and H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
            ability, actionType, aimLoc = nil, nil, nil
        end
    end

    if H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then return true end

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local followUp = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
    if (forceExtend or (stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6) or isLethalChase or followUp) and bot:GetMana() >= 75 then
        local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
        -- Do not close in for a finishing raze into the NEAR band (200 from him) - that is his
        -- right-click range and his near raze; finish from mid/far or do not finish at all
        if setupPos and followUp and not isLethalChase and not forceExtend then
            local pred = U.PredictPosition(enemyHero, 0.35) or enemyHero:GetLocation()
            if U.DistanceBetweenLocations(setupPos, pred) <= C.RAZE.NEAR_CENTER + 10 then setupPos = nil end
        end
        if setupPos then
            -- Approaching his T1 for a raze is allowed while the tower is busy with a creep (a raze gives no aggro)
            -- and his burst cannot kill us; not below 50% HP.
            local allowDive = isLethalChase
            if not allowDive and (followUp or forceExtend) then
                local R = K._race
                local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
                if hpPct >= 0.5 and not (R and R.valid and R.heCanKillSoon) and H.TowerLockedOnCreep(W.s.enemyT1) then
                    allowDive = true
                end
            end
            -- If the safe boundary (tower) cuts off most of the approach, the raze position is
            -- unreachable: do not stamp at the boundary, give the tick to siege/last hits (not for finishing).
            local reachable = true
            if not isLethalChase then
                local clamped = H.GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
                if clamped and U.DistanceBetweenLocations(clamped, setupPos) > 200 then reachable = false end
            end
            if reachable and H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps, allowDive) then
                return true
            end
        end
    end

    return false
end

function H.StackLeadThirdRazeOK(bot, enemy, ability, point, snapshot)
    if not ability or not K.HasRazeStackLead(bot, enemy) then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then return false end
    local stacks, remain = U.GetShadowrazeDebuff(enemy)
    if stacks ~= 2 or not U.IsRazeAbilityCastable(bot, ability) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data or data.label == "near" then return false end
    local race = K._race
    if not race or not race.valid or race.heCanKillSoon then return false end
    local horizon = U.DistanceBetweenLocations(bot:GetLocation(), point) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > 1.25 or remain <= horizon + 0.1 then return false end
    local predicted = U.PredictPosition(enemy, horizon)
    local d = U.DistanceBetweenLocations(point, enemy:GetLocation())
    local dp = U.DistanceBetweenLocations(point, predicted)
    if math.max(math.abs(d-data.center), math.abs(dp-data.center)) > C.RAZE.HIT_RADIUS - 40 then return false end
    local before = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local beforePred = GetUnitToLocationDistance(bot, predicted)
    local replies = K.EnemyBandsAcross(enemy, math.min(d, dp, before, beforePred), math.max(d, dp, before, beforePred), horizon)
    if replies > 1 then return false end -- Do not turn 2:1 into a possible 3:3.
    local snap = snapshot or {}
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 900
            or U.DistanceBetweenLocations(point, tower:GetLocation()) < 900) then return false end
    end
    local incoming = K.EnemyRazeDamage(bot, enemy, replies)
    if math.min(d, dp) <= enemy:GetAttackRange() + enemy:GetCurrentMovementSpeed() * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot) * math.ceil(horizon / math.max(0.6, enemy:GetSecondsPerAttack()))
    end
    for _, creep in pairs(snap.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:IsAlive() then
            if creep:GetAttackTarget() == bot or U.DistanceBetweenLocations(point, creep:GetLocation()) <= 500 then
                incoming = incoming + K.AttackDamageVs(creep, bot) * math.max(1, math.ceil(horizon / math.max(0.75, creep:GetSecondsPerAttack())))
            end
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then return false end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    -- Account for enemy instant heals + post-cast retreat damage when walking into enemy range:
    -- NEVER step forward at low HP against a healthy higher-stat SF unless the 3rd raze is lethal.
    local enEffHp = (enemy:GetHealth() or 0) + (U.HasItem(enemy, "item_faerie_fire") and 85 or 0) + U.GetStickCharges(enemy) * 15
    local myThirdRaze = K.MyRazeDamage(bot, enemy, 1)
    local lethalFinish = (enEffHp - myThirdRaze) <= K.AttackDamageVs(bot, enemy) * 1.15
    if lethalFinish then
        return bot:GetHealth() - incoming >= math.max(95, K.AttackDamageVs(enemy, bot) * 1.1)
    end
    local retreatGap = math.max(0, (enemy:GetAttackRange() + 90) - d)
    local retreatTime = math.min(2.2, retreatGap / math.max(1, bot:GetCurrentMovementSpeed()))
    local postDisengageIncoming = incoming + K.AttackDamageVs(enemy, bot) * math.ceil(retreatTime / math.max(0.65, enemy:GetSecondsPerAttack()))
    local myAfter = bot:GetHealth() - postDisengageIncoming
    local enAfter = enEffHp - myThirdRaze
    return myAfter >= math.max(210, K.AttackDamageVs(enemy, bot) * 2.8) and myAfter >= (enAfter - 95)
end

function H.HandleStackLead(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not K.HasRazeStackLead(bot, enemy) or State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    for _, label in ipairs({"far", "mid"}) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if H.StackLeadThirdRazeOK(bot, enemy, ab, bot:GetLocation(), snapshot) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
        end
        if ab and U.IsRazeAbilityCastable(bot, ab) and distance > K.Center(label) + 150 then
            local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * (K.Center(label)+150)
            if H.StackLeadThirdRazeOK(bot, enemy, ab, point, snapshot)
                and H.ApproachEnemyPoint(bot, enemy, point, 25, snapshot.enemyTowers, snapshot.allyCreeps, false, ab) then return true end
        end
    end
    -- `9070869385.dem` `03:00.53–03:01.87` Anti-Conveyor `HandleStackLead` Fix:
    -- NEVER walk backward from `d < 585u` (`557u`) through a ready `700u` `Shadowraze3` when `450u` `mid` is already on CD,
    -- and NEVER force a `0.45s` stack-lead retreat when `K.HasDominantRightClickPosture` holds right-click supremacy!
    local walkingOutIntoReadyR3 = (distance < 585)
        and (K.EnemyRazeReadyIn("mid") > 1.8)
        and (K.EnemyRazeReadyIn("far") <= 1.2)
    local domRightClickLead = K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, snapshot)
    if K.EnemyBandsAcross(enemy, distance, distance, 0.7) > 0
        and not walkingOutIntoReadyR3
        and not domRightClickLead then
        local _, outer = K.EnemyBandsAcross(enemy, 0, 2000, 1.0)
        local safe = math.max(distance + 120, outer + 60)
        local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * safe
        point = H.GetSafeApproach(bot, point, snapshot.enemyTowers, snapshot.allyCreeps)
        H.ClearRazeState()
        return H.BeginForcedRetreat(bot, point, 0.45)
    end
    return false
end

-- A confirmed first hit may be followed by ONE other ranged raze, even at
-- equal resources. This is not permission to initiate against an equal opponent.
function H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    local chain = State.razeFollowup
    if not chain or chain.enemy ~= enemy or not U.CanQuery(enemy) then return nil end
    local now = GameTime()
    if now > chain.untilTime or now < chain.opened + C.RAZE.CAST_POINT then return nil end
    if not race or not race.valid or race.heCanKillSoon then return nil end
    local stacks, remaining = U.GetShadowrazeDebuff(enemy)
    if stacks <= chain.stacks then return nil end -- No blind chase after a miss.
    local ab = H.GetRazeAbilityByLabel(bot, chain.label)
    if not U.IsRazeAbilityCastable(bot, ab) then return nil end
    local center = U.GetRazeCenterByLabel(chain.label)
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist < 350 or dist > 1000 then return nil end
    local reach = center + C.RAZE.STRICT_RADIUS - 30
    local horizon = math.max(0, dist - reach) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > chain.untilTime - now or remaining <= horizon + 0.1
        or not K.CanCatch(bot, enemy, reach, horizon) then return nil end
    local snap = snapshot or W.s or {}
    local goal = enemy:GetLocation() + (bot:GetLocation() - enemy:GetLocation()):Normalized() * center
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 800
            or U.DistanceBetweenLocations(goal, tower:GetLocation()) < 800) then return nil end
    end
    local incoming, count = K.EnemyBurstVs(bot, enemy, math.min(dist, center), horizon, false)
    local enemyRange = (enemy:GetAttackRange() or 525) + 80
    if math.min(dist, center) > enemyRange
        and math.min(dist, center) <= enemyRange + enemy:GetCurrentMovementSpeed() * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot)
    end
    local regen = math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0)
    local extra = math.floor((K.EnemyManaBudget(enemy, true) + regen * horizon) / 75)
        - math.floor(K.EnemyManaBudget(enemy, true) / 75)
    if extra > 0 then
        incoming = incoming + K.EnemyRazeDamage(bot, enemy, math.min(3, count + extra))
            - K.EnemyRazeDamage(bot, enemy, count)
    end
    for _, creep in pairs(snap.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot)
                * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack()))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then return nil end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    if bot:GetHealth() - incoming < math.max(110, K.AttackDamageVs(enemy, bot)) then return nil end
    if incoming > K.MyRazeDamage(bot, enemy, 1) + math.max(80, bot:GetHealth() - enemy:GetHealth()) then return nil end
    return ab, center
end

function H.HandlePendingRazeFollowup(bot, enemy, race, snapshot)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local ab, center = H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    if not ab then return false end
    local action, aim = H.GetRazeActionType(bot, ab, enemy)
    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
    local predicted = U.PredictPosition(enemy, 0.3)
    local desired = center == C.RAZE.MID_CENTER and center + 150 or center
    local setup = predicted + (bot:GetLocation() - predicted):Normalized() * desired
    if not setup then return false end
    for _, tower in pairs(snapshot.enemyTowers or {}) do
        if tower and tower:IsAlive() and U.DistanceBetweenLocations(setup, tower:GetLocation()) < 800 then return false end
    end
    return H.ApproachEnemyPoint(bot, enemy, setup, 25, snapshot.enemyTowers or {}, snapshot.allyCreeps or {})
end

function H.EnemyStackNeedsImmediateExtension(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.6 then return false end
    -- Do not run to extend a stack on an enemy we cannot reach before it expires (previously
    -- a pointless jog after an enemy that left): the far raze must be reachable in the remaining stack time.
    if not K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS - 60, math.max(0.3, rem_time - C.RAZE.CAST_POINT)) then
        return false
    end
    -- Mana/defence discipline: extending a stack also costs 75 mana and must NEVER walk a wounded/outstatted hero forward.
    local R = K._race
    if R and R.valid and R.heCanKillSoon and not R.canKillNow then return false end
    if R and R.valid and R.losingHard and not R.canKillSoon then return false end
    local minSafeHp = math.max(220, K.AttackDamageVs(enemyHero, bot) * 3.0)
    local killing = R and R.valid and R.canKillSoon
    if killing then return bot:GetHealth() >= math.max(110, K.AttackDamageVs(enemyHero, bot) * 1.4) end
    if bot:GetHealth() < minSafeHp then return false end
    -- A clear advantage in the trade (edge >= 100, he cannot kill us right away) - extend the stack
    if R and R.valid and R.edge >= 100 and not R.heCanKillNow and (bot:GetMana() - 75) >= 75 then return true end
    if State.defensive and not H.HasTradeSupport(R) then return false end
    if H.HarassManaOK(bot, R) then return true end
    if stacks >= 2 and R and R.valid and R.edge >= 40 and (bot:GetMana() - 75) >= 75 then return true end
    return false
end

function H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not H.EnemyStackNeedsImmediateExtension(bot, enemyHero) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return true end
    if State.actionTaken then return false end

    State.prepTarget = nil
    State.attackTarget = nil
    State.attackStartTime = 0
    State.firedThisAttack = false
    State.aggroPullTime = 0
    State.deaggroTime = 0

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local isLethal = U.GetTwoRazeDamage(bot, enemyHero) >= enemyHero:GetHealth() * 0.90
    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, "AGGRESSIVE", isLethal, true)
    if ability and actionType then
        local data = U.GetRazeAbilityData(ability)
        if data and data.label == "near" and actionType == "TURN" then
            local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                ability = nil
                actionType = nil
            end
        end
        if ability and actionType and H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then
            return true
        end
    end

    local shouldCloseIn, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if shouldCloseIn and closePos then
        if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
            return true
        end
    end

    local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
    if setupPos then
        if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 45, enemyTowers, allyCreeps) then
            return true
        end
    end

    local desiredCenter = C.RAZE.MID_CENTER
    local enemyLoc = enemyHero:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = nil
    if dist > desiredCenter + 60 then
        local dir = (enemyLoc - botLoc):Normalized()
        desired = botLoc + dir * math.min(dist - desiredCenter, 380)
    elseif dist < desiredCenter - 100 then
        local dir = (botLoc - enemyLoc):Normalized()
        desired = enemyLoc + dir * desiredCenter
    else
        return false
    end
    if H.ApproachEnemyPoint(bot, enemyHero, desired, 45, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.LevelUpAbilities(bot)
    local ap = (bot.GetAbilityPoints and bot:GetAbilityPoints()) or 0
    local lvl = math.min(30, (bot.GetLevel and bot:GetLevel()) or 1)
    -- `v7.9.7-pro` Dual-Compatible Patch `7.40+`/`7.41f` Talent Points + Valve C++ `6601` Bot-API Leveler:
    --   1. Empirical `.dem` proof (`auto-20261102-0159-start-ShaNachnetsya.dem` `tk=26736->26738->26740`):
    --      - For humans since Patch `7.40`, Talents use dedicated Talent Points (`0` Skill Point cost -> at L10 you learn
    --        BOTH the L10 Talent AND `+2 All Attributes`!).
    --      - In Valve's legacy C++ `CDOTA_Bot_Script::ActionImmediate_LevelAbility` (`build 6601`), leveling `slot[07]`
    --        (`CDOTA_Ability_Special_Bonus_Base`) STILL decrements `m_iAbilityPoints` (`2 -> 1`, `m_iSpecialAbility: 0 -> 1`).
    --   2. NEVER exit early on `ap <= 0` BEFORE checking `L10/L15/L20/L25` talents (`CanAbilityBeUpgraded()`), AND never
    --      cap `"special_bonus_attributes"` by fixed table-row breaks so:
    --      - If Talent costs `0` AP (`7.40+` free Talent Point): Tick 1 at L10 learns L10 Talent (`AP` stays `1`) and
    --        Tick 2 at L10 immediately learns `"special_bonus_attributes"` Rank 2 (`AP: 1 -> 0`) ON LEVEL 10!
    --      - If Talent deducts `1` AP (`build 6601` Bot C++ API): L9 learns Attrs #1, L10 learns L10 Talent, L11+ maxes Attrs `7/7` (`0` stranded AP!).
    local function TryLearn(name, wantRanks, allowZeroAPTalent)
        if not name then return false end
        if C.SKILL and C.SKILL.ALLOW_FRENZY == false and name == "nevermore_frenzy" then
            return false
        end
        if name == "nevermore_requiem" then
            return false
        end
        local isRealTalent = (string.find(name, "special_bonus", 1, true) ~= nil) and (name ~= "special_bonus_attributes")
        if ap <= 0 and not (allowZeroAPTalent and isRealTalent) then
            return false
        end
        local maxRank = isRealTalent and 1
            or ((name == "special_bonus_attributes") and math.min(7, wantRanks or 7) or math.min(4, wantRanks or 4))
        local okA, ab = pcall(bot.GetAbilityByName, bot, name)
        if okA and ab and ab.GetLevel and (ab:GetLevel() or 0) < maxRank then
            local canUpg = (ab.CanAbilityBeUpgraded == nil) and (ap > 0) or ab:CanAbilityBeUpgraded()
            if canUpg then
                bot:ActionImmediate_LevelAbility(name)
                if U.BumpInventoryEpoch then U.BumpInventoryEpoch() end
                return true
            end
        end
        return false
    end

    -- 1. Core `L1..L8` progression (`Q` at `1,3,5,7` -> `4/4`; `Presence` at `2,4,6,8` -> `4/4`; `0` Requiem, `0` Frenzy):
    if ap > 0 then
        local wantRaze = math.min(4, math.floor((lvl + 1) / 2))
        if wantRaze >= 1 and TryLearn("nevermore_shadowraze1", wantRaze, false) then return end
        local wantPresence = math.min(4, math.floor(lvl / 2))
        if wantPresence >= 1 and TryLearn("nevermore_dark_lord", wantPresence, false) then return end
    end

    -- 2. Milestone Talents (`L10, L15, L20, L25`) — checked EVEN WHEN `ap == 0` so free `7.40+` Talent Points train immediately!
    local talents = (C.SKILL and C.SKILL.TALENTS) or {
        { minLevel = 10, name = "special_bonus_unique_nevermore_7" },
        { minLevel = 15, name = "special_bonus_unique_nevermore_3" },
        { minLevel = 20, name = "special_bonus_unique_nevermore_1" },
        { minLevel = 25, name = "special_bonus_unique_nevermore_raze_procsattacks" },
    }
    for _, t in ipairs(talents) do
        if lvl >= t.minLevel and TryLearn(t.name, 1, true) then
            return
        end
    end

    if ap <= 0 then return end

    -- 3. Every remaining Ability Point (`L9+`, including L10's skill point whenever Talent used a free Talent Point!)
    --    flows straight into `"special_bonus_attributes"` (`m_vecAbilities.0015`, up to `7/7` = `+14` All Stats):
    if TryLearn("special_bonus_attributes", 7, false) then return end

    -- 4. Deterministic safety fallback (`0` Requiem, `0` Frenzy):
    for _, fb in ipairs({
        "nevermore_shadowraze1",
        "nevermore_dark_lord",
        "special_bonus_attributes",
    }) do
        if TryLearn(fb, 7, false) then return end
    end
end

function H.IsInDangerForRegen(bot, heroDist)
    heroDist = math.min(1600, heroDist or 850)
    local heroes = bot:GetNearbyHeroes(heroDist, true, BOT_MODE_NONE)
    if heroes and #heroes > 0 then return true end
    local creeps = bot:GetNearbyLaneCreeps(600, true)
    if creeps and #creeps > 0 then return true end
    local projs = bot:GetIncomingTrackingProjectiles()
    if projs and #projs > 0 then return true end
    return false
end

function H.HasEnemyProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = true
            if caster.GetTeam then
                isEnemy = caster:GetTeam() ~= bot:GetTeam()
            end
            if isEnemy then
                return true, p
            end
        end
    end
    return false, nil
end

-- Only Hero / Tower projectiles can cancel `modifier_flask_healing` in Dota 2 7.00-7.41f!
-- Ranged lane creep projectiles NEVER break Healing Salve — treating ranged creep attacks as
-- Dota 2 7.41f Engine Truth (`auto-20261103-1343` `05:49.33..06:02.33` Verified):
-- Towers (`T1/T2/T3/T4`) and lane creeps NEVER dispel `modifier_flask_healing` or `modifier_clarity_potion`!
-- ONLY enemy Hero / Player-Controlled unit / Roshan hits >= 20 post-reduction damage break Salve/Clarity!
function H.HasSalveBreakingProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster and U.CanQuery(caster) then
            local isEnemy = (not caster.GetTeam) or (caster:GetTeam() ~= bot:GetTeam())
            if isEnemy then
                local okH, isHero = pcall(function() return caster:IsHero() end)
                local okT, isTower = pcall(function() return caster:IsTower() end)
                local okC, isCreep = pcall(function() return caster:IsCreep() end)
                if (not (okT and isTower)) and ((okH and isHero) or not (okC and isCreep)) then
                    return true, p
                end
            end
        end
    end
    return false, nil
end

-- Estimate incoming NON-Salve-breaking physical damage from enemy Towers & Lane Creeps over `windowSec` (`v7.9.16-pro`):
-- Crucial for Post-Kill Tower-Exit Survival (`1343 @ 05:49.33`: `3` Dire T2 hits `116/118/115` + `5` creep hits = `401` dmg,
-- survived ONLY because `modifier_flask_healing` healed `+99 HP` uninterrupted right through T2 fire!).
function H.EstimateIncomingNonHeroDamage(bot, s, windowSec)
    local horizon = windowSec or 2.0
    local total = 0.0
    local myTeam = bot:GetTeam()
    local towerProjCount = 0
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, p in pairs(projs) do
                local c = p and p.caster
                if c and U.CanQuery(c) and ((not c.GetTeam) or c:GetTeam() ~= myTeam) then
                    local okT, isTower = pcall(function() return c:IsTower() end)
                    local okC, isCreep = pcall(function() return c:IsCreep() end)
                    if okT and isTower then
                        total = total + 115.0
                        towerProjCount = towerProjCount + 1
                    elseif okC and isCreep then
                        total = total + 17.0
                    end
                end
            end
        end
    end
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and U.CanQuery(tw) and tw:IsAlive() then
            local dTw = GetUnitToLocationDistance(bot, tw:GetLocation())
            if dTw <= 815 then
                local okA, tgt = pcall(tw.GetAttackTarget, tw)
                if (okA and tgt == bot) or (towerProjCount > 0 and dTw <= 760) then
                    local extraShots = math.max(0, math.floor(horizon / 0.95))
                    total = total + extraShots * 115.0
                elseif dTw <= 705 and #(s and s.allyCreeps or {}) == 0 then
                    total = total + 115.0
                end
            end
        end
    end
    local creepAttackers = 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 560 then
            if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                creepAttackers = creepAttackers + 1
            end
        end
    end
    if creepAttackers > 0 then
        total = total + creepAttackers * 16.0 * math.max(1.0, math.min(horizon, 2.5))
    end
    return total
end

-- `v7.9.18-pro` (`9074513540.dem` `11:08.07..11:09.07` `(1184,1568)->(1495,1665)` Flanking Chord-Cut Fix):
-- When an enemy hero flanks laterally (`cos(bot-enemy, fountain-bot) < 0.76`) while `dNow < desiredDist`, moving directly to
-- `enemyLoc + Normalized(fountain - enemyLoc) * desiredDist` cuts across the chord of the enemy's attack/raze circle (`shrinking d`
-- from `617u -> 558u` into a Salve-breaking right-click!). Instead, flee along a radial-dominant escape vector (`uAway` blended
-- gently toward `uFnt`) so `d(bot, enemy)` strictly opens on every single tick!
function H.GetSafeEscapePointAwayFromEnemy(bot, enemyLoc, desiredDist)
    local fountain = P.GetFountain(bot)
    local botLoc = bot:GetLocation()
    local safeDistance = desiredDist or 1120
    if enemyLoc then
        local vx, vy = botLoc.x - enemyLoc.x, botLoc.y - enemyLoc.y
        local dNow = math.sqrt(vx * vx + vy * vy)
        local fx, fy = fountain.x - botLoc.x, fountain.y - botLoc.y
        local dFnt = math.sqrt(fx * fx + fy * fy)
        local ux, uy
        if dNow > 1.0 then
            ux, uy = vx / dNow, vy / dNow
        elseif dFnt > 1.0 then
            ux, uy = fx / dFnt, fy / dFnt
        else
            ux, uy = 1.0, 0.0
        end
        local fux, fuy = (dFnt > 1.0) and (fx / dFnt) or ux, (dFnt > 1.0) and (fy / dFnt) or uy
        local cosAng = ux * fux + uy * fuy
        if dNow < safeDistance and cosAng < 0.76 then
            local wAway = (dNow < 780) and 0.84 or 0.62
            local wFnt = 1.0 - wAway
            local bx, by = ux * wAway + fux * wFnt, uy * wAway + fuy * wFnt
            local bLen = math.sqrt(bx * bx + by * by)
            local stepDir = (bLen > 1e-4) and Vector(bx / bLen, by / bLen, 0) or Vector(ux, uy, 0)
            local stepLen = math.max(380, math.min(680, safeDistance - dNow + 220))
            local cand = botLoc + stepDir * stepLen
            if U.GetRetreatWaypoint and type(IsLocationPassable) == "function" and not IsLocationPassable(cand) then
                cand = U.GetRetreatWaypoint(bot, stepDir) or cand
            end
            return H.SteerClearOfAllyT2Hull(bot, cand, enemyLoc)
        end
        local dir = fountain - enemyLoc
        if U.DistanceBetweenLocations(fountain, enemyLoc) < 1 then
            dir = fountain - botLoc
        end
        dir = dir:Normalized()
        return H.SteerClearOfAllyT2Hull(bot, enemyLoc + dir * safeDistance, enemyLoc)
    end
    local t1Safe = P.GetT1Close(bot, 420)
    if t1Safe then
        return t1Safe
    end
    local dir = (fountain - botLoc):Normalized()
    return botLoc + dir * 280
end

function H.GetSalveSafeRetreatLocation(bot, enemyHero)
    local enemyLoc = (enemyHero and U.CanQuery(enemyHero)) and enemyHero:GetLocation() or nil
    return H.GetSafeEscapePointAwayFromEnemy(bot, enemyLoc, 1120)
end

function H.HandleActiveSalveSafety(bot, enemyHero)
    if not bot:HasModifier("modifier_flask_healing") then
        return false
    end
    if (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.96 then
        return false
    end
    local safeDistance = 1065
    local incomingProjectile = H.HasSalveBreakingProjectileIncoming(bot)
    local tooCloseToEnemy = false
    if enemyHero and U.CanQuery(enemyHero) then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dist < safeDistance then
            tooCloseToEnemy = true
        end
    end
    if incomingProjectile or tooCloseToEnemy then
        local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
        H.BeginForcedRetreat(bot, safeLoc, 0.65)
        return true
    end
    -- Already outside `1065u` and 0 hero/tower projectiles: DO NOT freeze in place with `actionTaken = true`!
    -- Allow normal lane positioning / CS to operate smoothly inside XP range while Salve finishes ticking!
    return false
end

-- Safety condition: he has no time to turn around, catch up and land a second stack on us.
-- Finishing a creep right after the enemy hero's projectile. His projectile is in flight,
-- and after it lands the creep falls into my finish threshold -> hit now so my attack lands
-- right after his (the window between his hit and the creep dying).
function H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local now = GameTime()
    if now < (State.snipeCooldown or 0) then return false end
    if State.prepTarget then return false end
    local myPoint = bot:GetAttackPoint() or 0.5
    for _, c in pairs(enemyCreeps or {}) do
        if c and U.CanQuery(c) and c:IsAlive() then
            local okP, projs = pcall(function() return c:GetIncomingTrackingProjectiles() end)
            if okP and type(projs) == "table" then
                for _, pr in pairs(projs) do
                    if pr.is_attack and pr.caster == enemyHero then
                        local speed = 1200
                        local okS, sp = pcall(function() return enemyHero:GetAttackProjectileSpeed() end)
                        if okS and type(sp) == "number" and sp > 0 then speed = sp end
                        local eta = 0.3
                        if pr.location then
                            eta = U.DistanceBetweenLocations(pr.location, c:GetLocation()) / speed
                        end
                        if eta <= 0.7 then
                            local myDmg = U.SFDamageRange(bot, c).min
                            local ctx = U.GetTargetPredictionContext(c, { enemyHero })
                            local hpAfter = U.PredictHPWithContext(ctx, c, eta + 0.05, "avg")
                            -- his hit does not kill the creep but makes it mine
                            if hpAfter > 0 and hpAfter <= myDmg * 0.97 then
                                local travel = 0.2
                                local okPS, psp = pcall(function() return bot:GetAttackProjectileSpeed() end)
                                if okPS and type(psp) == "number" and psp > 0 then
                                    travel = U.DistanceBetweenLocations(bot:GetLocation(), c:GetLocation()) / psp
                                end
                                local impact = myPoint + travel + 0.03
                                -- my attack lands AFTER his projectile and inside the window before the creep dies
                                if impact >= eta - 0.06 and impact <= eta + 1.1 then
                                    if H.IsSafeToAttack(bot, c:GetLocation(), enemyTowers, allyCreeps) then
                                        State.prepTarget = c
                                        State.prepTargetTime = now
                                        State.snipeCooldown = now + 0.3
                                        if not U.IsAttackingAction(bot)
                                            or bot:GetAttackTarget() ~= c then
                                            bot:Action_AttackUnit(c, true)
                                            H.ClearMoveCache()
                                        end
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- At the end of an already-started dry duel, take the remaining swings instead of wasting them walking.
function H.HandleDryLastStand(bot,enemy,s)
    if State.actionTaken or bot:GetHealth()>bot:GetMaxHealth()*0.40 or not U.CanQuery(enemy) or enemy:GetAttackTarget()~=bot or bot:IsUsingAbility() or bot:IsChanneling()
        or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) or State.towerEscapeLoc then return false end
    local now=GameTime()
    local involved=bot:GetAttackTarget()==enemy
        or (State.heroAttackTarget==enemy and now-(State.heroAttackTime or -100)<2)
        or (State.heroCombatEnemy==enemy and now<(State.heroCombatUntil or 0))
    if not involved or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if K.MyManaBudget(bot,true)+math.max(0,(bot.GetManaRegen and bot:GetManaRegen()) or 0)*0.8>=75
        or K.EnemyManaBudget(enemy,true)+math.max(0,(enemy.GetManaRegen and enemy:GetManaRegen()) or 0)*0.8>=75 then return false end
    local damage=bot:GetActualIncomingDamage(enemy:GetAttackDamage()+math.max(3,(enemy.GetBaseDamageVariance and enemy:GetBaseDamageVariance()) or 0),DAMAGE_TYPE_PHYSICAL)
    local committed=State.lastStandEnemy==enemy and now<(State.lastStandUntil or 0)
    if damage<=0 or (not committed and (bot:GetHealth()>damage*2
        or enemy:GetHealth()>math.max(enemy:GetMaxHealth()*0.40,K.AttackDamageVs(bot,enemy)*3))) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    -- Explicit last-stand exception: only this dry, in-range case may cancel a prior hero retreat.
    H.ClearForcedRetreat();State.survivalLoc=nil;State.survivalUntil=0;State.fleeUntil=0
    State.dodgeLoc=nil;State.dodgeUntil=0;State.goingToFountain=false;State.fountainReason=nil
    State.towerChaseBlockedEnemy=nil;State.heroCombatAllowed=true
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastStandEnemy=enemy;State.lastStandUntil=now+1.0
    State.actionTaken=true;State.lastCombatStage="dry-last-stand"
    return true
end

-- After an exchange, a hero already in attack range gets an actionable answer, not a spacing tour.
function H.HandleContactTrade(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or enemy:GetAttackTarget()~=bot then return false end
    local ours,ourTime=U.GetShadowrazeDebuff(bot)
    local theirs,theirTime=U.GetShadowrazeDebuff(enemy)
    if ours<2 or theirs<2 or ourTime<=0.2 or theirTime<=0.2 then return false end
    local distance=GetUnitToLocationDistance(bot,enemy:GetLocation())
    if distance>bot:GetAttackRange() then return false end
    if H.HandleGuaranteedRazeKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {})
        or H.HandleGuaranteedAttackKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {}) then
        State.actionTaken=true;State.lastCombatStage="contact-trade-finish"
        return true
    end
    local horizon=(bot:GetAttackPoint() or 0.5)+distance/math.max(1,bot:GetAttackProjectileSpeed())+0.15
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    local R = K._race
    local losingContact = (bot:GetHealth()-incoming<math.max(120,K.AttackDamageVs(enemy,bot)*1.6))
        or (R and R.valid and R.losingHard and not R.canKillNow)
    if losingContact then
        local point=U.GetSafeDistancePosition(bot,enemy)
            or U.GetRetreatWaypoint(bot,(bot:GetLocation()-enemy:GetLocation()):Normalized())
        State.lastCombatStage="contact-trade-retreat"
        return H.BeginForcedRetreat(bot,point,2.0)
    end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast=State.aimingRaze==ab
                State.actionTaken=true;State.lastCombatStage="contact-trade-raze"
                return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.heroCombatEnemy=enemy;State.heroCombatUntil=GameTime()+1.25
    State.actionTaken=true;State.lastCombatStage="contact-trade-attack"
    return true
end

-- ---------------------------------------------------------------------------------------------
-- FREE PRESSURE (2026-10-20, replay-driven)
-- In the 20.10 demo against a human SF the bot threw 2 hero right-clicks in 9 minutes (the human
-- threw 29) and went 130 seconds without a single raze while being right-clicked. Both handlers
-- below add exactly one action in windows where the bot previously did nothing, and every gate is
-- a veto: they can only fire when walking is NOT required (the target is already in range), the
-- expected incoming burst cannot kill us, no enemy tower is near, and no last hit is being stolen.
-- ---------------------------------------------------------------------------------------------

-- A last hit we would lose by swinging at the hero instead (same rule for razes: a 0.55 s cast).
local function FreePressureStealsLastHit(bot, s, pad)
    for _, creep in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:IsAlive() then
            local d = GetUnitToLocationDistance(bot, creep:GetLocation())
            if d <= bot:GetAttackRange() + (pad or 0)
                and creep:GetHealth() <= K.AttackDamageVs(bot, creep) + 20 then
                return true
            end
        end
    end
    return false
end

local function FreePressureTowerClear(bot, s, radius)
    for _, tower in pairs((s and s.enemyTowers) or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < radius then
            return false
        end
    end
    return true
end

-- One raze when he is on top of us, when he just cast (hit or miss - both are answers),
-- and a bounded proactive raze in a window where nothing threatens us at all.
function H.FreePressureColdWindow(bot, enemy, cold)
    local pressured = H.IsEnemyPressuring(bot, enemy)
    local inWindow = State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)
    if cold == false then return pressured or inWindow end
    return (not pressured) and (not inWindow)
end

function H.HandleFreeRazeAnswer(bot, s, race, cold)
    FDBG("raze_calls")
    if not C.FREE_RAZE or not C.FREE_RAZE.ENABLED then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then FDBG("raze_busy") return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then FDBG("raze_busycast") return false end
    if State.aimingRaze then FDBG("raze_aiming") return false end
    if race and race.heCanKillSoon then FDBG("raze_race") return false end
    if not FreePressureTowerClear(bot, s, C.FREE_RAZE.TOWER_CLEAR) then FDBG("raze_tower") return false end

    local pressured = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot) or false
    local castAge = GameTime() - ((K._enemy and K._enemy.lastAnyCastAt) or -100)
    -- Answer = he is right-clicking us, or he just cast anything (a hit OR a miss: a miss is exactly
    -- the situation the demo showed the bot ignoring for 130 seconds).
    local answering = pressured or castAge <= C.FREE_RAZE.REPLY_WINDOW
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())

    if answering then
        if cold then
            -- The cold pipeline runs before any combat stage: leave answers to the combat
            -- pipeline, which has already judged the trade. Only the proactive branch is ours.
            FDBG("raze_cold_answering") return false
        end
        FDBG("raze_answering")
        if bot:GetMana() < 75 or hpPct < C.FREE_RAZE.MIN_HP_PCT_ANSWER then FDBG("raze_mana_hp") return false end
    else
        FDBG("raze_proactive")
        local enemyCanAnswer = K.EnemyManaBudget(enemy, true)
            + math.max(0, (enemy.GetManaRegen and enemy:GetManaRegen() or 0)) * 1.2 >= 75
        -- Nobody is threatening us: allow proactive centered coil on surplus mana, `>= 115 MP` with Mango/Stick reserve,
        -- OR `>= 75 MP` (`MIN_HP_PCT_VS_DRY`) when the enemy SF is dry (`< 75` potential mana) and cannot raze back!
        local reqMana = enemyCanAnswer and C.FREE_RAZE.SURPLUS_MANA or (C.FREE_RAZE.SURPLUS_MANA_VS_DRY or 75)
        local minHpPct = enemyCanAnswer and C.FREE_RAZE.MIN_HP_PCT or (C.FREE_RAZE.MIN_HP_PCT_VS_DRY or 0.32)
        local pokeManaOK = (bot:GetMana() >= reqMana)
            or (bot:GetMana() >= 115 and (K.MyManaBudget(bot, true) >= 150 or not enemyCanAnswer))
        if not pokeManaOK or hpPct < minHpPct then FDBG("raze_reserve") return false end
        if K.ShortReplyIncoming(bot, enemy, 1.2, s) > bot:GetHealth() * 0.25 then FDBG("raze_incoming") return false end
        if enemyCanAnswer and hpPct < C.FREE_RAZE.SAFE_VS_ANSWER_PCT then FDBG("raze_cananswer") return false end
    end

    -- He must already be inside one of our three bands: no walking, no setup position.
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local centers = { far = C.RAZE.FAR_CENTER, mid = C.RAZE.MID_CENTER, near = C.RAZE.NEAR_CENTER }
    local inBand = false
    for _, label in ipairs({ "far", "mid", "near" }) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab)
            and math.abs(distance - centers[label]) <= C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30) then
            inBand = true
            break
        end
    end
    if not inBand then FDBG("raze_band") return false end

    local horizon = C.RAZE.CAST_POINT + 0.35
    local incoming = K.ShortReplyIncoming(bot, enemy, horizon, s)
    if bot:GetHealth() - incoming < math.max(C.FREE_RAZE.MIN_HP_AFTER, K.AttackDamageVs(enemy, bot) * 1.25) then
        FDBG("raze_incoming2") return false
    end
    if FreePressureStealsLastHit(bot, s, C.FREE_HIT.LASTHIT_PAD) then FDBG("raze_lasthit") return false end

    for _, label in ipairs({ "far", "mid", "near" }) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                State.shortCombatCast = State.aimingRaze == ab
                State.dodgeLoc = nil
                State.dodgeUntil = 0
                State.actionTaken = true
                State.lastCombatStage = answering and "free-raze-answer" or "free-raze-window"
                _G.__lastCombatStage = State.lastCombatStage
                FDBG(answering and "raze_fired_answer" or "raze_fired_window")
                return true
            end
        end
    end
    FDBG("raze_noaction")
    return false
end

-- A right-click that costs nothing: the target is ALREADY inside our attack range (no chase, no
-- wave break), the swing cannot get us killed, and it does not steal a last hit. The order is
-- re-issued every tick while the situation holds, so the hero keeps swinging.
function H.HandleFreeRightClick(bot, s, race)
    FDBG("hit_calls")
    if not C.FREE_HIT or not C.FREE_HIT.ENABLED then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then FDBG("hit_noenemy") return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then FDBG("hit_busy") return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then FDBG("hit_busycast") return false end
    if State.aimingRaze then FDBG("hit_aiming") return false end
    if race and race.heCanKillSoon then FDBG("hit_race") return false end
    local dEnemyNow = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local effAtkRange = math.max(525, bot:GetAttackRange() or 525)
    local maxPokeDist = effAtkRange + 48
    if dEnemyNow > maxPokeDist then FDBG("hit_range") return false end
    if not FreePressureTowerClear(bot, s, C.FREE_HIT.TOWER_CLEAR) then FDBG("hit_tower") return false end
    if not H.IsSafeToHarass(bot, enemy:GetLocation(), s.enemyTowers or {}, s.allyCreeps or {}) then FDBG("hit_harass") return false end

    -- Immortal Right-Click Reciprocation & Walk-Up Harass (`v3.9.0` + `v7.7.0` `9070869385.dem` `03:00–03:08` Fix):
    -- Valve C++ `enemy:GetAttackTarget()` resets to `nil` immediately after orb-walk projectile launch (`ShaNachnetsya`
    -- orb-walked 25/25 right-clicks while `ehpPct > 0.35`, blocking `HandleFreeRightClick` on 100% of ticks after `02:30`!).
    -- Strike whenever: (a) he is hitting/recently hit us (`1.85s` orb-walk window), (b) he is inside our `573u` hull-to-hull
    -- attack reach while we hold `HasDominantRightClickPosture`, OR (c) clean walk-up poke with `<= 1` aggro creep!
    local losingDryDuel = (K.EnemyManaBudget(enemy, true) < 75)
        and (bot:GetHealth() < enemy:GetHealth() - 25)
        and (K.AttackDamageVs(bot, enemy) < K.AttackDamageVs(enemy, bot) + 4)
    local pressured = (not losingDryDuel) and (((enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.85))) or false)
    local ehpPct = enemy:GetHealth() / math.max(1, enemy:GetMaxHealth())
    local aggroOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then aggroOnMe = aggroOnMe + 1 end
    end
    local dryNowFree = H.IsDryVsEnemyRaze(bot, enemy)
    local domRightClickPoke = (not dryNowFree)
        and (K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, s))
        and aggroOnMe <= 2
        and dEnemyNow <= effAtkRange + 42
    local cleanWalkupPoke = domRightClickPoke or ((not dryNowFree)
        and dEnemyNow <= effAtkRange + 15
        and aggroOnMe <= 1
        and ((U.GetShadowrazeDebuff(bot) or 0) <= (U.GetShadowrazeDebuff(enemy) or 0))
        and (bot:GetHealth() >= bot:GetMaxHealth() * 0.58 or K.EnemyManaBudget(enemy, true) < 75))
    if not pressured and not cleanWalkupPoke and ehpPct > C.FREE_HIT.FINISH_HP_PCT then FDBG("hit_reason") return false end
    FDBG(pressured and "hit_pressured" or "hit_lowfoe")

    if FreePressureStealsLastHit(bot, s, C.FREE_HIT.LASTHIT_PAD) then FDBG("hit_lasthit") return false end

    local horizon = (bot:GetAttackPoint() or 0.5) + C.FREE_HIT.SETTLE_TIME
    local incoming = K.ShortReplyIncoming(bot, enemy, horizon, s)
    if bot:GetHealth() - incoming < math.max(C.FREE_HIT.SAFE_HP_ABS,
        K.AttackDamageVs(enemy, bot) * C.FREE_HIT.SAFE_HP_FACTOR) then
        FDBG("hit_incoming") return false
    end

    if not H.IssueHeroAttack(bot, enemy) then FDBG("hit_issuefail") return false end
    FDBG("hit_issued")
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    State.actionTaken = true
    State.lastCombatStage = "free-right-click"
    _G.__lastCombatStage = State.lastCombatStage
    return true
end

-- A survival retreat is separate from tactical spacing. No turn, mirror or chase
-- may steal its order, even when an enemy raze happens to be on cooldown.
-- Low HP alone must not cancel a winning, already-started dry right-click duel.
-- This is not permission to turn back during a retreat or to chase a fleeing hero.
function H.HandleWinningDryDuel(bot, enemy, snapshot)
    local now = GameTime()
    if not enemy or not U.CanQuery(enemy) then return false end
    if State.forcedRetreatLoc or State.survivalLoc
        or now < (State.fleeUntil or 0) or State.goingToFountain then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) then return false end
    if bot:GetHealth() / math.max(1, bot:GetMaxHealth()) > 0.45 then return false end
    local continuing = bot:GetAttackTarget() == enemy
        or (State.heroAttackTarget == enemy and now - (State.heroAttackTime or -100) < 0.35)
    if not continuing or enemy:GetAttackTarget() ~= bot then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist > bot:GetAttackRange() or U.GetAngleDifference(bot, enemy:GetLocation()) > 25 then return false end
    -- Avoid projecting a clean duel while tower/creep damage is also incoming.
    for _, tower in pairs((snapshot and snapshot.enemyTowers) or {}) do
        if tower and tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < 900 then return false end
    end
    for _, creep in pairs((snapshot and snapshot.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    local hp = bot:GetHealth()
    local enDamage = bot:GetActualIncomingDamage((enemy:GetAttackDamage() or 0)
        + math.max(3, (enemy.GetBaseDamageVariance and enemy:GetBaseDamageVariance()) or 0), DAMAGE_TYPE_PHYSICAL)
    local myDamage = U.SFDamageRange(bot, enemy).min
    if myDamage <= 0 or enDamage <= 0 then return false end
    -- Compare impact events, not "enemy hits NOW" versus our entire fresh windup.
    local function impacts(attacker, target, damage, own)
        local events = {}
        local period = math.max(0.1, attacker:GetSecondsPerAttack() or 1.7)
        local speed = math.max(1,attacker:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED)
        for _, projectile in pairs(U.SafeGetIncomingProjectiles(target)) do
            if not projectile.is_attack or projectile.caster ~= attacker then return nil end
            if projectile.location then
                events[#events+1] = {time=U.DistanceBetweenLocations(projectile.location,target:GetLocation())/speed, damage=damage}
            elseif not own then
                events[#events+1] = {time=0,damage=damage}
            end
        end
        local last = attacker:GetLastAttackTime() or -100
        local travel = dist/speed
        local first
        if last > 0 and now-last <= period+0.1 then
            first = math.max(0,last+period-now) + travel
        else
            first = own and ((attacker:GetAttackPoint() or 0.5)+travel) or 0
        end
        first = math.max(0,first+(own and 0.04 or -0.08))
        for i=0,5 do events[#events+1]={time=first+i*period,damage=damage} end
        table.sort(events,function(x,y) return x.time<y.time end)
        return events
    end
    local outgoing = impacts(bot,enemy,myDamage,true)
    local incoming = impacts(enemy,bot,enDamage,false)
    if not outgoing or not incoming then return false end
    local function lethalAt(events,health)
        for _,e in ipairs(events) do
            health=health-e.damage
            if health<=0 then return e.time end
        end
        return math.huge
    end
    local enemyHp = enemy:GetHealth()+U.GetStickCharges(enemy)*15
        + math.max(0,enemy:GetHealthRegen() or 0)*4
    if U.HasItem(enemy,"item_faerie_fire") then enemyHp=enemyHp+85 end
    local killAt = lethalAt(outgoing,enemyHp)
    local dieAt = lethalAt(incoming,hp)
    if killAt>4 or killAt+0.06>=dieAt then return false end
    -- Include mango/wand charges and mana regenerated before our killing hit.
    if K.MyManaBudget(bot, true) + math.max(0, bot:GetManaRegen() or 0) * killAt >= 75
        or K.EnemyManaBudget(enemy, true) + math.max(0, enemy:GetManaRegen() or 0) * killAt >= 75 then return false end
    if not H.IssueHeroAttack(bot, enemy) then return false end
    State.lastCombatStage = "timed-dry-finish"
    State.actionTaken = true
    return true
end

function H.CanTakeShortCombatAction(bot,enemy,s)
    if not U.CanQuery(enemy) or State.actionTaken or State.goingToFountain
        or State.forcedRetreatLoc or State.survivalLoc or GameTime()<(State.fleeUntil or 0)
        or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    if State.towerChaseBlockedEnemy==enemy then
        if H.TowerChaseBlocked(bot,s) then return false end
        State.towerChaseBlockedEnemy=nil
    end
    return true
end

-- Keep a safe answer through its cast point, while still validating aim and new threats.
function H.HandleShortCombatCast(bot,enemy,s)
    if not State.shortCombatCast or not State.aimingRaze or State.aimingTarget~=enemy
        or not U.CanQuery(enemy) or not bot:IsUsingAbility() or State.forcedRetreatLoc
        or State.survivalLoc or State.goingToFountain or GameTime()<(State.fleeUntil or 0) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    local remaining=math.max(0,C.RAZE.CAST_POINT-(GameTime()-State.aimingStartTime))
    if bot:GetHealth()-K.ShortReplyIncoming(bot,enemy,remaining+0.15,s)<math.max(60,K.AttackDamageVs(enemy,bot)) then return false end
    if H.HandleActiveRazeValidation(bot) then
        State.lastCombatStage="short-cast-validation"
        State.actionTaken=true
        return true
    end
    return false
end

-- A short stationary answer is not the same decision as tanking a 2.5-second combo.
function H.HandleSafeRazeReply(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local age=U.GetRecentEnemyRazeHitAge(enemy)
    local castAge=GameTime()-((K._enemy and K._enemy.lastAnyCastAt) or -100)
    local phase=K.EnemyPhase()
    local phaseThreat=phase and GetUnitToLocationDistance(bot,K.EnemyRazeCenter(enemy,phase))<=C.RAZE.HIT_RADIUS+20
    -- Right-click pressure is a reason to answer even when no raze landed on us and he has not
    -- cast for a while: an SF standing in our face taking free swings must not be free.
    local pressuredNow=(enemy.GetAttackTarget and enemy:GetAttackTarget()==bot) or false
    if not phaseThreat and age>0.8 and not pressuredNow and (castAge>1.0 or not H.IsEnemyPressuring(bot,enemy)) then return false end
    if K.HasRazeStackLead(bot,enemy) then return false end -- The bounded third-spell rule owns this case.
    local hitTime=GameTime()-age
    if not phaseThreat and age<=0.8 and State.mirrorAnsweredEnemy==enemy and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit-hitTime)<0.001 then return false end
    if GetUnitToLocationDistance(bot,enemy:GetLocation())<=bot:GetAttackRange()
        and U.SFDamageRange(bot,enemy).min>=enemy:GetHealth() then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,C.RAZE.CAST_POINT+0.3,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    -- `9056774541.dem` `02:00.87` (`tk=9258`, `230 HP` vs `736 HP / 265 MP` respawned enemy):
    -- NEVER freeze `0.55s` to fire a single non-lethal reply coil at `< 285 HP` into a healthy full-mana SF!
    if (bot:GetHealth() or 0) < 285 and (enemy:GetHealth() or 9999) > 420
        and ((enemy:GetMana() or 0) + U.GetMangoMana(enemy)) >= 150 then
        return false
    end
    for _,label in ipairs({(phaseThreat and phase) or U.GetRecentEnemyRazeHitLabel(enemy) or "far","far","mid","near"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.dodgeLoc=nil; State.dodgeUntil=0
                if State.shortCombatCast and label=="mid" and State.razeFollowup then State.razeFollowup.reply=true end
                State.lastCombatStage="safe-short-reply"
                State.actionTaken=true
                return true
            end
        end
    end
    return false
end

-- A confirmed middle reply owns one short far follow-up before generic stack spacing.
function H.HandleReplyFarFollowup(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local chain=State.razeFollowup
    if not chain or not chain.reply or chain.enemy~=enemy or chain.label~="far"
        or GameTime()>chain.untilTime or GameTime()<chain.opened+C.RAZE.CAST_POINT then return false end
    local stacks,remaining=U.GetShadowrazeDebuff(enemy)
    if stacks<=chain.stacks or K.HasRazeStackLead(bot,enemy) then return false end
    local ab=H.GetRazeAbilityByLabel(bot,"far")
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemy)
    local point=bot:GetLocation()
    local dist=GetUnitToLocationDistance(bot,enemy:GetLocation())
    local move=0
    if not action then
        local desired=C.RAZE.FAR_CENTER-150
        if dist>=desired or desired-dist>160 then return false end
        move=desired-dist
        point=enemy:GetLocation()+(bot:GetLocation()-enemy:GetLocation()):Normalized()*desired
    end
    local horizon=C.RAZE.CAST_POINT+0.3+move/math.max(1,bot:GetCurrentMovementSpeed())
    if remaining<horizon+0.1 or GameTime()+horizon>chain.untilTime then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    if action then
        if not H.CastOrTurnRaze(bot,ab,action,aim,enemy) then return false end
        State.shortCombatCast=State.aimingRaze==ab
    else
        if not H.ApproachEnemyPoint(bot,enemy,point,25,s.enemyTowers or {},s.allyCreeps or {}) then return false end
    end
    State.dodgeLoc=nil;State.dodgeUntil=0
    State.lastCombatStage="reply-far-followup";State.actionTaken=true
    return true
end

-- Continue an existing close fight through one funded cooldown cycle; never initiate at parity.
function H.HandleManaCycleContinuation(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) then return false end
    if enemy:GetAttackTarget()~=bot or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if not H.IsRazeFollowUp(bot,enemy) and not (State.heroCombatEnemy==enemy and GameTime()<State.heroCombatUntil) then return false end
    if not K.ManaCycleWindow(bot,enemy,s) then return false end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.lastCombatStage="mana-cycle-raze";State.actionTaken=true;return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastCombatStage="mana-cycle-attack"
    State.actionTaken=true
    return true
end

function H.ComputeCutOffSafeRetreatTarget(bot, enemy, desiredPoint, minSpacing)
    local bLoc = bot:GetLocation()
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        return desiredPoint
    end
    local eLoc = enemy:GetLocation()
    local curDist = U.DistanceBetweenLocations(bLoc, eLoc)
    if curDist > 980 or curDist < 1 then
        return desiredPoint
    end
    local toGoal = desiredPoint - bLoc
    if toGoal:Length2D() < 10 then
        return desiredPoint
    end
    local goalDir = toGoal:Normalized()
    local toEnemy = (eLoc - bLoc):Normalized()
    local cutOffCos = goalDir.x * toEnemy.x + goalDir.y * toEnemy.y
    -- `auto-20261023-0050` `07:14.23` Cut-Off Fix:
    -- When the enemy stands BETWEEN us and Fountain (`cutOffCos > 0.40`), walking straight toward `desiredPoint`
    -- runs right into `Q`/`W` range! Arc `78 deg` around him away from his position while monotonically widening gap!
    if cutOffCos <= 0.40 then
        return desiredPoint
    end
    local away = (bLoc - eLoc):Normalized()
    local perpA = Vector(-away.y, away.x, 0)
    local perpB = Vector(away.y, -away.x, 0)
    local fnt = P.GetFountain(bot)
    local fntDir = (fnt - bLoc):Normalized()
    local candA = (away * 0.62 + perpA * 0.78):Normalized()
    local candB = (away * 0.62 + perpB * 0.78):Normalized()
    local scoreA = candA.x * fntDir.x + candA.y * fntDir.y
    local scoreB = candB.x * fntDir.x + candB.y * fntDir.y
    local ptA = bLoc + candA * (minSpacing or 420)
    local ptB = bLoc + candB * (minSpacing or 420)
    local passA = (type(IsLocationPassable) ~= "function") or IsLocationPassable(ptA)
    local passB = (type(IsLocationPassable) ~= "function") or IsLocationPassable(ptB)
    if passA and (not passB or scoreA >= scoreB) then return ptA end
    if passB then return ptB end
    return bLoc + away * (minSpacing or 420)
end

function H.HandleSurvivalRetreat(bot, enemy, race)
    local now = GameTime()
    local visible = enemy and U.CanQuery(enemy)
    local myHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = myHp / maxHp
    if visible and enemy:IsAlive() then
        local lr = U.SolveLethalRace(bot, enemy, W and W.s or nil)
        if lr and lr.winsFirstKill and lr.tKillHim <= 2.25 then
            State.survivalLoc = nil
            State.survivalUntil = 0
            return false
        end
    end
    local enAtk = visible and K.AttackDamageVs(enemy, bot) or 55
    local enBurstAvail = visible and K.EnemyBurstVs(bot, enemy, GetUnitToLocationDistance(bot, enemy:GetLocation()), 2.2, false) or 0
    local actualLethalRisk = (myHp <= 215)
        or (race and race.valid and (race.heCanKillNow or race.heCanKillSoon))
        or ((myHp - enBurstAvail) <= math.max(155, enAtk * 2.1))
    local crushingRightClick = visible
        and ((enemy:GetMana() or 0) + U.GetMangoMana(enemy) < 150)
        and myHp >= 310
        and K.AttackDamageVs(bot, enemy) >= enAtk + 9

    local danger = visible and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 1200
        and hpPct <= 0.45
        and actualLethalRisk
        and not crushingRightClick
        and enemy:GetHealth() / math.max(1, enemy:GetMaxHealth()) > hpPct + 0.12
    local active = State.survivalLoc ~= nil and now < (State.survivalUntil or 0)
    if active and visible and hpPct < 0.50 and actualLethalRisk and not crushingRightClick
        and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 990 then
        danger = true
    end
    local favourable = visible and race and race.valid and not race.heCanKillSoon
        and (race.spellWindow or H.GetPendingRazeFollowup(bot, enemy, race)
            or (race.edge >= 0 and myHp >= enemy:GetHealth()))
    if favourable or crushingRightClick then danger = false end
    if danger then State.survivalUntil = now + 1.6 end
    if now >= (State.survivalUntil or 0) or not danger then
        State.survivalLoc = nil
        State.survivalUntil = 0
        return false
    end
    -- Fixed-anchor safe lane retreat (`bot_unbeatable` zero-jitter synthesis: anchor to `behindT1` world coordinate
    -- instead of moving `enemy:GetLocation() + homeDir * 1035` every tick, wrapped in `ComputeCutOffSafeRetreatTarget`!):
    local fountain = P.GetFountain(bot)
    local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 280)) or nil
    local rawTarget
    if behindT1 and visible and U.DistanceBetweenLocations(behindT1, enemy:GetLocation()) >= 940 then
        rawTarget = behindT1
    else
        local bLocS = bot:GetLocation()
        local toFntS = (fountain - bLocS):Normalized()
        if visible then
            local eLocS = enemy:GetLocation()
            local relES = eLocS - bLocS
            local latES = math.abs(relES.x * (-toFntS.y) + relES.y * toFntS.x)
            if latES >= 250 then
                local awayS = (U.DistanceBetweenLocations(bLocS, eLocS) > 5) and (bLocS - eLocS):Normalized() or toFntS
                rawTarget = bLocS + (toFntS * 0.74 + awayS * 0.26):Normalized() * 580
            else
                local homeDir = (fountain - eLocS):Normalized()
                rawTarget = eLocS + homeDir * 1015
            end
        else
            rawTarget = bLocS + toFntS * 1015
        end
    end
    local cutSafe = visible and H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawTarget, 440) or rawTarget
    State.survivalLoc = H.SteerClearOfAllyT2Hull(bot, cutSafe, visible and enemy:GetLocation() or nil)
    -- Hold calm safe anchor upon arrival (`< 85u`) while `danger` remains true — NEVER clear `survivalLoc` and return `false`
    -- to let lower wave-seek handlers walk right back into danger (`30Hz` 85u arrival ping-pong fix!)!
    if GetUnitToLocationDistance(bot, State.survivalLoc) < 85 then
        if U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        State.actionTaken = true
        return true
    end
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 0.9)
    local moving = bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO
    if moving and State.survivalOrderLoc == State.survivalLoc
        and now - (State.survivalOrderTime or -100) < 1.2 then
        State.actionTaken = true
        return true
    end
    State.survivalOrderLoc = State.survivalLoc
    State.survivalOrderTime = now
    return H.SmartMove(bot, State.survivalLoc, 60)
end


function H.HandleEnemyNearRazeCounter(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- Clean flee - no turning toward the enemy
    if GameTime() < (State.fleeUntil or 0) and GameTime() >= (State.commitKillUntil or 0) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q_enemy = enemyHero:GetAbilityByName("nevermore_shadowraze1")
    if not q_enemy or not q_enemy:IsInAbilityPhase() then return false end

    local enemyLoc = enemyHero:GetLocation()
    local enemyFacing = enemyHero:GetFacing()
    local rad = math.rad(enemyFacing)
    local forward = Vector(math.cos(rad), math.sin(rad), 0)
    local center = enemyLoc + forward * C.RAZE.NEAR_CENTER
    if U.DistanceBetweenLocations(center, bot:GetLocation()) > C.RAZE.HIT_RADIUS then
        return false
    end

    local q_bot = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q_bot or not U.IsRazeAbilityCastable(bot, q_bot) then return false end

    local botPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local myError = U.GetRazeHitErrorWithDesiredFacing(bot, botPred, C.RAZE.NEAR_CENTER)
    if myError <= C.RAZE.HIT_RADIUS + 30 then
        local actionType = "TURN"
        if U.GetAngleDifference(bot, botPred) <= C.RAZE.MAX_ANGLE_TO_CAST then
            actionType = "CAST"
        end
        if H.CastOrTurnRaze(bot, q_bot, actionType, botPred, enemyHero) then
            return true
        end
    end

    return false
end

function H.GetPotentialRecallHpPct(bot)
    local hp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local bonus = 0
    if bot:HasModifier("modifier_flask_healing") then
        bonus = bonus + 390
    elseif U.HasItem(bot, "item_flask") then
        bonus = bonus + 390
    end
    return math.min(maxHp, hp + bonus) / maxHp
end


-- Pro 1v1 Post-Kill Economy & Lane Reset (`tk=11000` live fix):
-- When we solo-kill the enemy SF, NEVER abandon an uncontested mid wave on a 7,000u walk to Fountain
-- if we have `>= 100g` (First Blood / kill bounty buys instant `item_flask` via courier!) OR already
-- own a Salve/Tango! Stay in lane, farm 100% of the uncontested wave (+4-8 CS & solo XP), and pop the
-- courier-delivered Salve right before enemy TP lands. Only walk to Fountain when `< 35% HP` WITH `< 100g`
-- AND zero healing items — and once walking to Fountain, NEVER abort halfway before 95% HP / 88% MP!
function H.HandlePostKillReset(bot, snapshot)
    local kills = snapshot and snapshot.myKills
    if type(kills) == "number" then
        local previous = State.postKillCount
        State.postKillCount = kills
        if previous ~= nil and kills > previous then
            H.ClearForcedRetreat()
            H.ClearTowerEscape()
            State.survivalLoc = nil
            State.survivalUntil = 0
            State.emergencyRetreat = nil
            State.commitKillUntil = 0
            State.nearChainUntil = 0
            State.dodgeLoc = nil
            local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
            -- Immediately start unlocking Backpack `item_flask` on the exact kill tick so its `6.0s` Backpack CD
            -- finishes LONG before the dead enemy hero respawns (`15–22s`) and channels TP (`+3.0s`)!
            if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
                H.EnsureConsumableReady(bot, "item_flask")
            end
            State.lastEnemyKillAt = GameTime()
            State.lastEnemyKillRespawnAt = GameTime() + math.max(12.0, math.min(28.0, 9.0 + ((snapshot and snapshot.enemyLastLevel) or 3) * 3.2))
            local hasRegenOrGold = ((bot:GetGold() or 0) >= 100)
                or U.HasItem(bot, "item_flask")
                or U.HasItem(bot, "item_tango")
                or bot:HasModifier("modifier_flask_healing")
                or bot:HasModifier("modifier_tango_heal")
            if hpPct <= 0.35 and not hasRegenOrGold then
                bot:Action_ClearActions(true)
                H.ClearRazeState()
                H.ClearMoveCache()
                State.prepTarget = nil
                State.needsTP = false -- Request TP immediately upon full Fountain restore.
                State.goingToFountain = true
                State.fountainReason = "POST_KILL"
            end
        end
    end
    -- Proactive Post-Kill Overstay Guard (`9056469656.dem` `03:07–03:12` Death #1 prevention):
    -- After shoving the wave post-kill, DO NOT sit `< 75% HP` or `< 150 MP` right next to enemy T1 (`<= 850u`)
    -- inside the `2.5s` window right as the full-HP/full-MP enemy hero is respawning! Step back to river (`>= 980u`
    -- from enemy T1) BEFORE they even finish channeling TP!
    if snapshot and snapshot.enemyAlive == false and State.lastEnemyKillRespawnAt
        and GameTime() >= State.lastEnemyKillRespawnAt - 2.5 then
        local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        local myReadyRazes = K.MyReadyRazeCount(bot, true)
        local tLoc = snapshot.enemyT1Alive and snapshot.enemyT1Loc or nil
        if (hpPctNow < 0.78 or myReadyRazes < 2) and tLoc then
            if GetUnitToLocationDistance(bot, tLoc) < 980 then
                local fnt = P.GetFountain(bot)
                local safeRiver = tLoc + (fnt - tLoc):Normalized() * 1120
                H.SmartMove(bot, safeRiver, 45)
                State.actionTaken = true
                return true
            end
        end
    end
    if State.goingToFountain and State.fountainReason == "POST_KILL" then
        if H.HandleFountainRecall(bot) then return true end
        if State.needsTP then return H.HandleReturnTP(bot) end
    end
    return false
end

function H.ShouldCommitDeepFountainWalk(bot, s)
    if not bot or not bot:IsAlive() or H.IsAtFountain(bot) then return false end
    local snap = s or (W and W.s)
    if snap and snap.enemyAlive == false then return false end
    if U.HasAnyHealing(bot) then return false end
    local courierHasSalve, courierLoc = U.IsCourierBringSalve(bot)
    if courierHasSalve and courierLoc and GetUnitToLocationDistance(bot, courierLoc) <= 1300 then
        return false
    end
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = (bot:GetHealth() or 0) / maxHp
    if hpPct > 0.36 then return false end
    local fountain = P.GetFountain(bot)
    local t1 = P.GetT1Close(bot, 0)
    if not fountain or not t1 then return false end
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local distToT1 = GetUnitToLocationDistance(bot, t1)
    local t1ToFountain = U.DistanceBetweenLocations(t1, fountain)
    -- Already `>= 1500u` behind Mid T1 at `<= 36% HP` (`auto-20261031-1939` `07:13`), OR `>= 900u` behind Mid T1 at
    -- critical `<= 22% HP` (`0210 @ 10:40` `182/1408 HP = 12.9% HP` at `(1016, 1484)` with 0 Salve/Tango!):
    -- finishing the walk to Fountain gives a FREE 100% HP/MP heal instead of turning 180 deg back to river at 182 HP!
    if (distToT1 >= 1500 and distToFountain <= (t1ToFountain - 1350))
        or (distToT1 >= 900 and hpPct <= 0.22 and distToFountain <= (t1ToFountain - 750)) then
        local enemyHero = snap and snap.enemy
        if enemyHero and U.CanQuery(enemyHero) and U.EnemyResourcesAsWeak(bot, enemyHero, hpPct) then
            return false
        end
        State.goingToFountain = true
        State.fountainReason = "DEEP_LOW_HP"
        return true
    end
    return false
end

function H.ShouldGoToFountain(bot)
    if H.ShouldCommitDeepFountainWalk(bot, W and W.s) then
        return true, "DEEP_LOW_HP"
    end
    local enemyHero = W and W.s and W.s.enemy or nil
    if U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero) then
        return false, nil
    end
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    if potentialHpPct < hpCritical then
        -- The enemy has exactly as few resources as we do - walking to the fountain simply hands
        -- him the lane and the wave. Keep the distance and regen.
        if U.EnemyResourcesAsWeak(bot, enemyHero, nil) then return false, nil end
        return true, "HP"
    end
    return false, nil
end

function H.ShouldAbortFountainRecall(bot)
    -- Hysteresis (`auto-20261031-1939` Death #2 Fix!): NEVER abort an active Fountain walk the instant
    -- passive HP regen ticks from `14.9%` to `15.0%` (`165 HP`) with zero Salve/Tango!
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct >= 0.48 then
        return true
    end
    if U.HasAnyHealing(bot) or (U.HasSalveInPipeline and U.HasSalveInPipeline(bot)) then
        local ownT1 = P.GetT1Tower(bot)
        if not ownT1 or GetUnitToLocationDistance(bot, ownT1) < 1450 then
            return true
        end
        local potentialHpPct = H.GetPotentialRecallHpPct(bot)
        if potentialHpPct >= 0.50 then
            return true
        end
    end
    return false
end

function H.IsAtFountain(bot)
    if bot.HasModifier and bot:HasModifier("modifier_fountain_aura_buff") then
        return true
    end
    local fountain = P.GetFountain(bot)
    -- CRITICAL FIX (`v7.9.0`): Previously `math.max(1500, ...)` returned `true` at `1490u` near T3/Barracks WITHOUT
    -- `modifier_fountain_aura_buff`, making `HandleFountainRecall` stop walking (`0` regen AFK stall!).
    local radius = math.min(540, (C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 520)
    return GetUnitToLocationDistance(bot, fountain) <= radius
end

function H.IsFountainFullyRestored(bot)
    local hp = bot:GetHealth()
    local maxHp = math.max(1, bot:GetMaxHealth())
    local mana = bot:GetMana()
    local maxMana = bot:GetMaxMana()
    local hpPct = hp / maxHp
    local manaPct = (maxMana > 0) and (mana / maxMana) or 1.0
    local waitHpPct = 0.95
    local waitManaPct = 0.88
    return hpPct >= waitHpPct and manaPct >= waitManaPct
end

function H.HandleFountainRecall(bot)
    if State.goingToFountain then
        if not bot:IsAlive() then
            State.goingToFountain = false
            State.fountainReason = nil
            return false
        end
        -- `v5.2.0` Dead-Enemy Recall Abort: if the opposing hero just died while we are still in lane (`>= 140 HP`),
        -- NEVER walk 7,000u back to Fountain — stay in lane, farm the uncontested wave, and Salve!
        if not H.IsAtFountain(bot) and State.fountainReason ~= "POST_KILL"
            and W.s and W.s.enemyAlive == false and (bot:GetHealth() or 0) >= 140 then
            State.goingToFountain = false
            State.fountainReason = nil
            H.ClearMoveCache()
            return false
        end
        if not H.IsAtFountain(bot) and State.fountainReason ~= "EMERGENCY" and State.fountainReason ~= "POST_KILL" and H.ShouldAbortFountainRecall(bot) then
            State.goingToFountain = false
            State.fountainReason = nil
            H.ClearMoveCache()
            return false
        end
        if H.IsAtFountain(bot) then
            if H.IsFountainFullyRestored(bot) then
                State.goingToFountain = false
                State.fountainReason = nil
                State.needsTP = true
                return false
            else
                State.actionTaken = true
                return true
            end
        else
            local fountain = P.GetFountain(bot)
            local recallDest = fountain
            local sRec = W.s
            local allyT1Loc = (sRec and sRec.allyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
            if allyT1Loc and sRec and #(sRec.allyCreeps or {}) == 0 then
                local dMeFnt = GetUnitToLocationDistance(bot, fountain)
                local dT1Fnt = U.DistanceBetweenLocations(allyT1Loc, fountain)
                if dMeFnt > dT1Fnt - 90 then
                    for _, ec in pairs(sRec.enemyCreeps or {}) do
                        if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 520 then
                            recallDest = allyT1Loc + (fountain - allyT1Loc):Normalized() * 240
                            break
                        end
                    end
                end
            end
            H.SmartMove(bot, recallDest, 80)
            State.actionTaken = true
            return true
        end
    end

    if State.emergencyRetreat then return false end
    if bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal") then return false end
    if H.IsInDangerForRegen(bot, 900) then return false end
    local should, reason = H.ShouldGoToFountain(bot)
    if should then
        State.goingToFountain = true
        State.fountainReason = reason
        H.ClearForcedRetreat()
        local fountain = P.GetFountain(bot)
        local recallDest = fountain
        local sRec = W.s
        local allyT1Loc = (sRec and sRec.allyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
        if allyT1Loc and sRec and #(sRec.allyCreeps or {}) == 0 then
            local dMeFnt = GetUnitToLocationDistance(bot, fountain)
            local dT1Fnt = U.DistanceBetweenLocations(allyT1Loc, fountain)
            if dMeFnt > dT1Fnt - 90 then
                for _, ec in pairs(sRec.enemyCreeps or {}) do
                    if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 520 then
                        recallDest = allyT1Loc + (fountain - allyT1Loc):Normalized() * 240
                        break
                    end
                end
            end
        end
        H.SmartMove(bot, recallDest, 80)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleReturnTP(bot)
    local t1 = P.GetT1Close(bot)
    local fountain = P.GetFountain(bot)
    local distToT1 = GetUnitToLocationDistance(bot, t1)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local minTpDist = math.max(2600, (C.TP and C.TP.RETURN_DISTANCE_FROM_T1) or 3000)
    local farFromT1 = distToT1 >= minTpDist
    local nearFount = H.IsAtFountain(bot)
    -- `v7.9.8-pro` (`1638 @ 00:11.13` Wasted Opening TP to T1 Fix!):
    --   1. Fix Lua boolean `and/or` short-circuit (`DotaTime() > 15` was `false` at `11.13s`, falling through to `GameTime() > 20` -> `true`!).
    --   2. NEVER burn an `80s` CD / `100g` TP Scroll before `DotaTime() > 45s` (walking with Wave 1 from T3/T2 is always strictly optimal!).
    --   3. Only set `healedDeepBehindLane` when SF actually retreated deep toward Fountain (`distToFountain <= 2200` or active fountain trip),
    --      NEVER during an opening/post-block walk near T2/T3!
    local gameStarted = false
    if type(DotaTime) == "function" then
        gameStarted = (DotaTime() > 45.0)
    else
        gameStarted = (GameTime() > 125.0)
    end

    -- Never waste an 80s TP cooldown on a short walk when already near T1 (< 2600u)!
    if not farFromT1 then
        State.needsTP = false
        State.tpSwapStep = 0
        return false
    end

    -- Whenever inside the Fountain after `0:45` (e.g. respawn or manual/emergency recall), OR deep near Fountain (`<= 2200u`)
    -- and healed up (`>= 78% HP`) after finishing a retreat Salve, mark TP return!
    local healedDeepBehindLane = farFromT1 and not nearFount
        and (distToFountain <= 2200 or State.fountainReason ~= nil)
        and not State.goingToFountain
        and not (bot.HasModifier and bot:HasModifier("modifier_flask_healing"))
        and ((bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 1)) >= 0.78
    if (nearFount or healedDeepBehindLane) and gameStarted then
        State.needsTP = true
    end

    if not State.needsTP then return false end
    if not gameStarted then return false end

    -- If inside or right next to Fountain, ensure full heal in Fountain aura BEFORE teleporting —
    -- UNLESS an enemy creep wave is already crashing into our Mid T1 (`v5.2.0` TP-arrival CS budget: save 6-8 under-tower CS at >= 82% HP & >= 165 MP!).
    -- `v7.9.0` 3.0s-Ahead TP Channel Time-Budget:
    -- TP Scroll channels for `3.0s` (`325 u/s * 3.0s = 975u` creep march!). Forecast unshielded enemy waves within
    -- `1720u` of our Mid T1 so we start channeling BEFORE the wave crashes under tower, saving 100% of Wave CS!
    local urgentWaveUnderOwnT1 = false
    if W.s and W.s.allyT1 and U.CanQuery(W.s.allyT1) then
        local ownT1Loc = W.s.allyT1:GetLocation()
        local underCount, approachingCount = 0, 0
        for _, ec in pairs(W.s.enemyCreeps or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = U.DistanceBetweenLocations(ec:GetLocation(), ownT1Loc)
                if dc <= 780 then underCount = underCount + 1 end
                if dc <= 1720 then approachingCount = approachingCount + 1 end
            end
        end
        if underCount >= 2 or (approachingCount >= 2 and #(W.s.allyCreeps or {}) == 0) then
            urgentWaveUnderOwnT1 = true
        end
    end
    local readyForUrgentWaveTP = urgentWaveUnderOwnT1
        and ((bot:GetHealth() / math.max(1, bot:GetMaxHealth())) >= 0.78)
        and ((bot:GetMana() or 0) >= 150)
    if nearFount and not H.IsFountainFullyRestored(bot) and not readyForUrgentWaveTP then
        if not (bot.HasModifier and bot:HasModifier("modifier_fountain_aura_buff")) then
            H.SmartMove(bot, fountain, 40)
        else
            bot:Action_ClearActions(false)
        end
        State.actionTaken = true
        return true
    end

    -- A TP order was just issued: hold still briefly so channel starts cleanly without canceling it
    if GameTime() - (State.tpOrderTime or -100) < 0.6 then
        State.actionTaken = true
        return true
    end

    local tp = U.GetTPScroll(bot)
    if not tp then
        -- ONLY buy a TP scroll if the hero AND personal courier genuinely own ZERO TP scrolls anywhere!
        if not U.HasAnyTPScroll(bot) and nearFount and bot:GetGold() >= 100
            and GameTime() - (State.tpBuyTime or -100) > 15.0 then
            bot:ActionImmediate_PurchaseItem("item_tpscroll")
            if U.BumpInventoryEpoch then U.BumpInventoryEpoch() end
            State.tpBuyTime = GameTime()
            State.actionTaken = true
            return true
        end
        State.needsTP = false
        return false
    end

    State.tpSwapStep = 0
    local castOk, castable = pcall(function() return tp:IsFullyCastable() end)
    if castOk and castable and bot:GetMana() >= 75 then
        bot:Action_UseAbilityOnLocation(tp, t1)
        State.tpOrderTime = GameTime()
        State.goingToFountain = false
        State.needsTP = false
        State.actionTaken = true
        return true
    end

    -- Scroll on short cooldown (<= 6s) while standing in Fountain: wait in Fountain, then teleport!
    local cdOk, cd = pcall(tp.GetCooldownTimeRemaining, tp)
    if nearFount and cdOk and type(cd) == "number" and cd > 0 and cd <= 6.0 then
        State.actionTaken = true
        return true
    end

    -- Scroll on long cooldown (e.g. > 6s): clear needsTP so we NEVER waste TP near T1 25s later!
    State.needsTP = false
    return false
end

-- v6.4/v6.6 TP Home Instead of Walking Home:
-- When committed to an emergency fountain reset (`State.emergencyRetreat == "FOUNTAIN"`), far from fountain
-- (`>= 2600u`), out of enemy cancel/projectile reach, and NOT holding an usable Healing Salve, channel TP home!
function H.TryTPHome(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local dFount = GetUnitToLocationDistance(bot, fountain)
    if dFount < 2600 then return false end
    local flaskSlotTp = bot:FindItemSlot("item_flask")
    local fasterEnemyBypass = false
    if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() and (bot:GetHealth() or 999) <= 325 then
        local enMsTp = enemyHero:GetCurrentMovementSpeed() or 310
        local myMsTp = bot:GetCurrentMovementSpeed() or 305
        local dEnTp = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if enMsTp >= myMsTp + 20 and dEnTp <= 1450 then
            fasterEnemyBypass = true
        end
    end
    -- Allow emergency TP-Home under a faster-MS enemy bypass dive (`1343 @ 05:39..05:45`: `350 MS vs 305 MS`)
    -- when `flask` is still locked in Backpack (`slot >= 6`) or in transit (since walking at `-45 MS` cannot outrun him!).
    if flaskSlotTp >= 0 and flaskSlotTp <= 5 then return false end
    if flaskSlotTp >= 6 and flaskSlotTp <= 8 and not fasterEnemyBypass then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    -- `02:12.7` (`tk=7414`) Fix: NEVER burn `75 MP` + `100g` TP Home when a Salve is in stash/courier OR `>= 72g`
    -- behind own T1 (`< 1450u`) OR the enemy is equally crippled on resources!
    if not fasterEnemyBypass and U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero) then return false end
    if U.EnemyResourcesAsWeak and U.EnemyResourcesAsWeak(bot, enemyHero, nil) then return false end
    local tp = U.GetTPScroll(bot)
    if not tp then return false end
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    if enemyHero and U.CanQuery(enemyHero) then
        local d = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local ms = bot:GetCurrentMovementSpeed() or 305
        if H.HasEnemyProjectileIncoming(bot) then
            return false
        end
        -- `v7.9.17-pro` (`1507 @ 05:41–05:51` Non-Stunning SF 3.0s TP-Out Physics):
        -- Against an enemy SF without Requiem (`no TP-interrupt!`), TP Scroll (`3.0s`) succeeds whenever SF survives
        -- the exact damage the chaser can walk into and land within `3.05s` (`d >= 935u` instead of rigid `1,346u`!).
        local isNonStunningSF = (enemyHero.GetUnitName and enemyHero:GetUnitName() == "npc_dota_hero_nevermore")
            and (((enemyHero.GetLevel and enemyHero:GetLevel()) or 1) < 6
                or not (enemyHero.GetAbilityByName and enemyHero:GetAbilityByName("nevermore_requiem")
                    and (enemyHero:GetAbilityByName("nevermore_requiem"):GetLevel() or 0) > 0))
        if fasterEnemyBypass and isNonStunningSF and d >= 935 then
            local enMs = math.max(305, enemyHero:GetCurrentMovementSpeed() or 350)
            local myHpTp = (bot:GetHealth() or 0) + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(bot)) or 0)
            local oneR = K.EnemyRazeDamage(bot, enemyHero, 1)
            local twoR = K.EnemyRazeDamage(bot, enemyHero, 2)
            local enAA = K.AttackDamageVs(enemyHero, bot)
            local estDmg3s = 0
            local tToFar = math.max(0, (d - 880) / enMs) + 0.55
            local tToMid = math.max(0, (d - 640) / enMs) + 0.55
            local tToAA  = math.max(0, (d - ((enemyHero:GetAttackRange() or 525) + 25)) / enMs) + 0.52
            if tToMid <= 3.05 and K.EnemyManaBudget(enemyHero, true) >= 150 then
                estDmg3s = estDmg3s + twoR
            elseif tToFar <= 3.05 and K.EnemyManaBudget(enemyHero, true) >= 75 then
                estDmg3s = estDmg3s + oneR
            end
            if tToAA <= 3.05 then
                estDmg3s = estDmg3s + enAA * (1 + math.floor(math.max(0, 3.05 - tToAA) / 1.15))
            end
            if myHpTp < estDmg3s + 55 then
                return false
            end
        elseif d < 980 + ms * 1.2 then
            return false
        end
    end
    local ok, castable = pcall(function() return tp:IsFullyCastable() end)
    if not (ok and castable) then return false end
    bot:Action_UseAbilityOnLocation(tp, fountain)
    State.tpHomeTime = GameTime()
    State.goingToFountain = false
    State.actionTaken = true
    return true
end

-- Defensive stance "I am weaker" (with hysteresis). The criterion is K.Race: a 6 s trade projection
-- (burst + right clicks + HP pool + towers), not just razes. While defending: do not answer his
-- right clicks without creep/tower support, do not harass, do not contest last hits,
-- stand behind our creeps (PASSIVE position), heal earlier.
function H.UpdateDefensive(bot, s, race)
    local now = s.now or GameTime()
    local cfg = C.DEFENSE or {}
    if not race or not race.valid then
        if not s.enemyAlive then State.defensive = false end
        return State.defensive
    end
    if race.spellWindow and not race.heCanKillSoon then
        State.defensive = false
        return false
    end
    if not State.defensive then
        if race.weaker then
            State.defensive = true
            State.defensiveSince = now
        end
    else
        local held = now - (State.defensiveSince or 0)
        if not race.weaker and race.edgeLong > -(cfg.EXIT_EDGE or 40) and held >= (cfg.MIN_HOLD_SEC or 2.0) then
            State.defensive = false
        end
    end
    return State.defensive
end

-- Support in the fight: my creeps are hitting him / he is under my tower.
function H.HasTradeSupport(race)
    local cfg = C.DEFENSE or {}
    if (State.enemyAggroCount or 0) >= (cfg.SUPPORT_CREEPS or 2) then return true end
    if race and race.valid and (race.myTowerOnHim or 0) > 0 then return true end
    return false
end

-- Can we spend 75 mana on a harass raze (not CS, not a finish): the reserve depends on the level.
-- followUp = the enemy has a fresh stack and is still in reach: the second/third raze finishes the stack
-- (+35/50/65/80 bonus per stack, he cannot answer) - the mana reserve does not apply.
function H.HarassManaOK(bot, race, followUp)
    local mana = H.GetPotentialCombatMana(bot)
    if mana < 75 then return false end
    if race and race.valid and (race.canKillSoon or race.spellWindow) then return true end
    if State.hunting then return true end -- Hunting: mana for 1 raze (+mango) is enough
    local enemy = (race and race.enemy) or H._enemyHeroNear
    if enemy and K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, W.s) then
        return true
    end
    local cfg = C.MANA or {}
    local lvl = bot:GetLevel() or 1
    if followUp then
        -- Finishing an active Shadowraze stack (`+35/50/65/80` bonus): keep only minimal reserve (`50` at L1-L2, `35` at L3+)
        if GameTime() < (State.nearChainUntil or 0) then return true end
        local keep = (lvl <= (cfg.EARLY_LEVEL_L2 or 2)) and 50 or 35
        return (mana - 75) >= keep
    end
    local reserve = cfg.RESERVE_FOR_PRESSURE or 75
    if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then
        reserve = 115
    elseif lvl <= (cfg.EARLY_LEVEL_L4 or 4) then
        reserve = 65
    end
    return (mana - 75) >= reserve
end

-- "Stack finish": the enemy has a fresh raze stack (remaining >= FOLLOWUP_MIN_REMAIN) and is within
-- band reach (accounting for his movement during the cast).
function H.IsRazeFollowUp(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    local stacks, rem = U.GetShadowrazeDebuff(enemyHero)
    if (stacks or 0) <= 0 then return false end
    if (rem or 0) < (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then return false end
    local pred = U.PredictPosition(enemyHero, C.RAZE.PREDICT_DELAY)
    local d = GetUnitToLocationDistance(bot, pred or enemyHero:GetLocation())
    return d <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 60
end

-- The enemy T1 is "busy" with a creep: its current target is not a hero, is alive, with HP for >= 2 shots.
-- The tower does not switch to a hero while the target is alive and nobody right-clicks the hero (a raze gives no aggro).
function H.TowerLockedOnCreep(t1)
    if not t1 then return false end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false end
    if t1.CanBeSeen and not t1:CanBeSeen() then return false end
    local okT, tgt = pcall(t1.GetAttackTarget, t1)
    if not okT or not tgt or not U.CanQuery(tgt) then return false end
    if tgt.IsHero and tgt:IsHero() then return false end
    local okD, dmg = pcall(t1.GetAttackDamage, t1)
    if not okD or type(dmg) ~= "number" or dmg <= 0 then dmg = 100 end
    return (tgt:GetHealth() or 0) >= dmg * 2
end


-- Convert a clear lane lead into ranged pressure, without requiring a prior
-- enemy miss or an already-open raze stack. Never bypass retreat or tower safety.
function H.HasLanePressureAdvantage(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid then return false end
    if race.heCanKillSoon then return false end
    if race.spellWindow then return true end
    if race.edge < 0 then return false end
    local hp, enemyHp = bot:GetHealth(), enemy:GetHealth()
    local myHit, enemyHit = K.AttackDamageVs(bot, enemy), K.AttackDamageVs(enemy, bot)
    local levelLead = bot:GetLevel() > enemy:GetLevel()
    local soulLead = S.GetSouls(bot) - S.GetSouls(enemy)
    -- Absolute resources and the projected trade, never a percentage of our own pool.
    local healthLead = hp - enemyHp >= math.max(100, enemyHit * 1.5)
    local laneLead = levelLead and soulLead >= 4 and hp >= enemyHp
    local attackLead = myHit >= enemyHit * 1.20 and hp >= enemyHp and myHit > 0
    return healthLead or laneLead or attackLead

end

-- Observe incoming pressure independently of farm targets and attack intent.
function H.IsEnemyPressuring(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy:GetAttackTarget() == bot then return true end
    local label = K.EnemyPhase()
    if label then
        local center = K.EnemyRazeCenter(enemy, label)
        if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then return true end
    end
    if bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 2.0) then return true end
    if bot.WasRecentlyDamagedByPlayer and enemy.GetPlayerID then
        local id = enemy:GetPlayerID()
        if id and id >= 0 and bot:WasRecentlyDamagedByPlayer(id, 2.0) then return true end
    end
    if U.GetRecentEnemyRazeHitAge(enemy) <= 2.0 then return true end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if projectile.caster == enemy then return true end
        end
    end
    return false
end

function H.TowerChaseBlocked(bot, snapshot)
    local enemy, tower = snapshot.enemy, snapshot.enemyT1
    if not U.CanQuery(enemy) or not tower or not tower:IsAlive() then return false end
    if GetUnitToLocationDistance(enemy, tower:GetLocation()) > 820 then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), snapshot.enemyTowers, snapshot.allyCreeps) then return false end
    if GetUnitToLocationDistance(bot, tower:GetLocation()) >= 900 then
        if State.aimingTarget == enemy and State.aimingRaze and bot:IsUsingAbility() then return false end
        for _, label in ipairs(K.LABELS) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if U.IsRazeAbilityCastable(bot, ab) and not H.IsTowerDiveRazeUnsafe(bot, enemy, ab, snapshot.enemyTowers, snapshot.allyCreeps) then
                local action = H.GetRazeActionType(bot, ab, enemy)
                if action then return false end
            end
        end
    end
    return true
end

function H.UpdateTowerChase(bot, snapshot)
    local enemy = snapshot.enemy
    if not H.TowerChaseBlocked(bot, snapshot) then
        State.towerChaseBlockedEnemy = nil
        return false
    end
    local wasChasing = bot:GetAttackTarget() == enemy
        or (State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)
            and bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO)
    State.towerChaseBlockedEnemy = enemy
    State.heroCombatAllowed = false
    State.heroCombatEnemy = nil
    State.heroCombatUntil = 0
    State.commitKillUntil = 0
    State.razeFollowup = nil
    if GetUnitToLocationDistance(bot, snapshot.enemyT1:GetLocation()) < 900
        or H.IsEnemyPressuring(bot, enemy) then
        local escPt = LN.TowerEscapePoint(bot, snapshot.enemyT1)
        -- `v7.9.9-pro` (`1814 @ 08:42.40..08:45.07` `571u` Tower-Clamp Free-Hit Deadlock Fix):
        -- When `IsEnemyPressuring` fires while `enemy` stands under his T1 (`403u` from T1, `571u <= 573u` attack reach!)
        -- and `towerChaseBlockedEnemy` blocks us from hitting back, ensure `escPt` steps AT LEAST `660u` outside `enemy`
        -- (`strictly beyond 573u hull-to-hull right-click reach!`) AND `>= 980u` outside `enemyT1`!
        if enemy and U.CanQuery(enemy) and H.IsEnemyPressuring(bot, enemy) then
            local eLocEsc = enemy:GetLocation()
            local tLocEsc = snapshot.enemyT1:GetLocation()
            if U.DistanceBetweenLocations(escPt, eLocEsc) < 660 then
                local fntEsc = P.GetFountain(bot)
                local awayEn = (fntEsc - eLocEsc):Normalized()
                escPt = eLocEsc + awayEn * 675
                if U.DistanceBetweenLocations(escPt, tLocEsc) < 980 then
                    escPt = tLocEsc + (fntEsc - tLocEsc):Normalized() * 995
                end
            end
        end
        return H.BeginForcedRetreat(bot, escPt, 0.6)
    end
    if wasChasing then H.SafeClearActions(bot) end
    return false -- Outside danger: release the tick to lane work, not another chase.
end

-- One combat pipeline for both initiation and retaliation. Its caller owns the
-- tick: farm/prehit state is never consulted and cannot suppress a combat stage.
function H.RunCombatPriority(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not enemy or not U.CanQuery(enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    local towers, allies = snapshot.enemyTowers or {}, snapshot.allyCreeps or {}
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.aggroPullTime = 0
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local function stage(name, ...)
        if H[name](...) then
            State.lastCombatStage = name
            State.actionTaken = true
            return true
        end
        return false
    end
    if stage("HandleEnemyTowerSafety", bot, snapshot, enemy) then return true end
    if stage("HandleEmergencyConsumables", bot, race) then return true end
    if stage("HandleGuaranteedRazeKill", bot, enemy, towers, allies) then return true end
    if stage("HandleGuaranteedAttackKill", bot, enemy, towers, allies) then return true end
    if stage("HandleEnemyRazeDodge", bot, enemy) then return true end
    -- Answer him: a cast he just threw (hit or miss) and any right-click pressure deserve one
    -- raze back while nothing threatens us. Runs before the combo ladder so it is not starved.
    if stage("HandleFreeRazeAnswer", bot, W.s, race, false) then return true end
    if race and race.valid and race.heCanKillSoon and not race.canKillNow then
        local point = U.GetSafeDistancePosition(bot, enemy)
            or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
        State.lastCombatStage = "lethal-threat-retreat"
        State.commitKillUntil = 0
        return H.BeginForcedRetreat(bot, point, 1.0)
    end
    if State.aimingRaze and stage("HandleActiveRazeValidation", bot) then return true end
    if bot:IsUsingAbility() or bot:IsChanneling() then
        State.lastCombatStage = "finish-current-cast"
        State.actionTaken = true
        return true
    end
    if stage("HandleStackLead", bot, snapshot, race) then return true end
    -- Preserve a HERO swing, never a creep swing. Safety and lethal finishes above
    -- may interrupt it; ordinary movement/pressure below may not.
    if stage("ShouldHoldForHeroWindup", bot, snapshot, enemy, race) then return true end
    if stage("HandleInstantMirrorRaze", bot, enemy, race, snapshot) then return true end
    if stage("HandlePendingRazeFollowup", bot, enemy, race, snapshot) then return true end
    if race and race.spellWindow then
        if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    end
    if H.CanContinueDryRazeChain(bot, enemy, race) then
        if H.TryRazeEnemy(bot, enemy, "AGGRESSIVE", towers, allies, false, false) then return true end
    end
    if stage("HandleEnemyNearRazeCounter", bot, enemy) then return true end
    if stage("ForceExtendEnemyStack", bot, enemy, towers, allies) then return true end
    if stage("HandleNearRazeReplyPressure", bot, enemy, towers, allies) then return true end
    if race and race.valid and race.canKillSoon then
        if stage("HandleLethalTwoRazeSequence", bot, enemy, towers, allies) then return true end
        if stage("HandleNearRazeFinish", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleImmediateNearRazePunish", bot, enemy, "AGGRESSIVE", towers, allies) then return true end
    if stage("HandleCloseEnemyPunish", bot, enemy, towers, allies) then return true end
    if stage("HandleMirrorRazeTrade", bot, enemy, towers, allies, allies, snapshot.enemyCreeps or {}) then return true end
    if stage("HandleCloseAttackFinish", bot, enemy, towers, allies) then return true end
    local stacked, band = U.IsSecondStackDangerActive(bot, enemy)
    if stacked and band == "mid" and not (race and race.spellWindow) then
        if stage("HandleMidStackSpacing", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleRetaliationAttack", bot, enemy, towers, allies) then return true end
    -- Generic attacks/approach are deliberately LAST, not an early return that
    -- makes every specialised combo handler unreachable.
    if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    -- Last non-destructive option before conceding the tick: a free swing at what is already
    -- inside our attack range (the answer raze had its turn right after the dodge stage).
    if stage("HandleFreeRightClick", bot, W.s, race) then return true end
    -- CRITICAL (`v3.6.0` Anti-Winning-Retreat Fix):
    -- `RunCombatPriority` is entered when we are NOT losing the trade (`edge >= 0` / dominant HP / kill chase).
    -- If the enemy ran past `1150u` or both sides' spells are on short CD, NEVER trigger `BeginForcedRetreat`
    -- (`800ms` backward flee!) unless we are genuinely at risk right now — yield cleanly so CS / T1 siege / forward lane hold run!
    local dangerNow = (not race or not race.valid)
        or race.heCanKillSoon
        or race.losingHard
        or (((bot:GetHealth() or 0) - (race.enBurstSoon or 0)) < 170 and (race.edge or 0) < 40)
    if not dangerNow then
        return false
    end
    local point = U.GetSafeDistancePosition(bot, enemy)
        or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
    State.lastCombatStage = "no-safe-action-retreat"
    return H.BeginForcedRetreat(bot, point, 0.8)
end

function H.HandleIncomingHeroPressure(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local valid = race and race.valid
    if valid and race.canKillNow then
        if H.HandleGuaranteedRazeKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
        if H.HandleGuaranteedAttackKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
    end
    local losing = not valid or (race.heCanKillSoon and not race.canKillNow)
        or (valid and race.losingHard and not race.spellWindow
            and not race.canKillSoon and not H.GetPendingRazeFollowup(bot, enemy, race, snapshot))
        or (valid and race.weakerSustained and not race.spellWindow
            and not race.canKillSoon and not H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
            and (bot:GetHealth() + 120 < (race.enEffHpNow or enemy:GetHealth()) or race.ttkMe < race.ttkHim * 0.62))
    if losing then
        State.commitKillUntil = 0
        H.ClearRazeState()
        local loc = U.GetSafeDistancePosition(bot, enemy)
        if not loc then
            local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
            loc = U.GetRetreatWaypoint(bot, away)
        end
        H.BeginForcedRetreat(bot, loc, 1.0)
        return true
    end
    -- Both response and initiative use the same specialist-first pipeline.
    local previous = State.intent
    State.intent = I.TRADE
    local acted = H.RunCombatPriority(bot, snapshot, race)
    State.intent = previous
    return acted

end

-- Combat owns the tick once selected. Creeps are not a reason to ignore an
-- attacker, but retreat, lethal damage and tower safety still take precedence.
function H.CanContinueDryRazeChain(bot, enemy, race)
    if not race or not race.valid or race.heCanKillSoon or not U.CanQuery(enemy) then return false end
    if K.EnemyManaBudget(enemy, true) + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * 0.7 >= 75 then return false end
    if not H.IsRazeFollowUp(bot, enemy) then return false end
    for _, label in ipairs(K.LABELS) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if U.IsRazeAbilityCastable(bot, ab) and H.GetRazeActionType(bot, ab, enemy) then return true end
    end
    return false
end

function H.ShouldEngageHero(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid or race.heCanKillSoon then return false end
    if State.towerChaseBlockedEnemy == enemy or H.TowerChaseBlocked(bot, W.s) then return false end
    if GetUnitToLocationDistance(bot, enemy:GetLocation()) > 1150 then return false end
    if H.CanContinueDryRazeChain(bot, enemy, race) then return true end
    if K.HasRazeStackLead(bot, enemy) and not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.GetPendingRazeFollowup(bot, enemy, race) then return true end
    if H.HasLanePressureAdvantage(bot, enemy, race) then return true end
    if H.IsEnemyPressuring(bot, enemy) then return true end
    return State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)

end

-- Once our last-hit swing has started, a rival projectile is NOT grounds to
-- surrender it. Timing uncertainty can reverse arrival order at short distances.
function H.ShouldCancelCommittedLastHit(predictedHP, threshold, buffer, remaining, window)
    return predictedHP > threshold + buffer and remaining > 0.01 and remaining <= window
end

function H.HandleAdvantageRazePressure(bot, enemy, race, towers, allies, nextLastHit)
    if not H.ShouldEngageHero(bot, enemy, race) then return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc then return false end
    if State.intent == I.RETREAT or GameTime() < (State.fleeUntil or 0) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    -- A chosen hero fight may interrupt even a creep last-hit windup.
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance > 1150 then return false end
    local setupAbility, setupCenter
    local followUp = H.IsRazeFollowUp(bot, enemy)
    local spellBudget = bot:GetMana() >= 150 or (bot:GetMana() >= 75
        and ((race.enRazesSoon or 0) == 0 or followUp or race.canKillSoon
            or H.IsEnemyPressuring(bot, enemy)))
    for _, label in ipairs({"far", "mid", "near"}) do
        local ability = H.GetRazeAbilityByLabel(bot, label)
        if spellBudget and ability and U.IsRazeAbilityCastable(bot, ability) then
            local center = label == "far" and C.RAZE.FAR_CENTER or (label == "mid" and C.RAZE.MID_CENTER or C.RAZE.NEAR_CENTER)
            if not setupAbility and label ~= "near" then setupAbility, setupCenter = ability, center end
            if not H.IsTowerDiveRazeUnsafe(bot, enemy, ability, towers, allies) then
                local action, aim = H.GetRazeActionType(bot, ability, enemy)
                if action and H.CastOrTurnRaze(bot, ability, action, aim, enemy) then return true end
            end
        end
    end
    -- A lead also means right-click pressure, not waiting for spell mana/cooldowns.
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), towers, allies) then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    end
    if not setupAbility then setupCenter = bot:GetAttackRange() - 30 end
    -- Walk only a short step toward a ready mid/far band, never into near-raze range.
    if setupCenter and distance > setupCenter + 10 then
        local here = bot:GetLocation()
        local step = math.min(220, distance - setupCenter)
        local point = here + (enemy:GetLocation() - here):Normalized() * step
        return H.ApproachEnemyPoint(bot, enemy, point, 35, towers, allies, false)
    end
    return false
end

function H.EarlyRazePolicyBlocks(bot, enemyHero)
    local cfg = C.RAZE or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local razeLvl = (q and q:GetLevel()) or 0
    if razeLvl >= (cfg.AGGRO_MIN_RAZE_LEVEL or 2) then return false end
    if not U.CanQuery(enemyHero) then return true end
    -- Mirror / answer: he cast a raze (hit or missed) in the last MIRROR_WINDOW s
    local E = K._enemy
    if E and E.lastAnyCastAt and (GameTime() - E.lastAnyCastAt) <= (cfg.MIRROR_WINDOW or 2.5) then return false end
    if U.HasEnemyMissedRazeRecently() then return false end
    -- He walked up close: the near band starts a chain of up to 3 razes
    local pred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT) or enemyHero:GetLocation()
    local d = GetUnitToLocationDistance(bot, pred)
    local dNow = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if math.min(d, dNow) <= (cfg.EARLY_CHAIN_DIST or 360) then return false end
    -- An open chain window (he already took a near raze and is leaving)
    if GameTime() < (State.nearChainUntil or 0) then return false end
    return true
end

function H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false, current_mode end
    if not U.CanQuery(enemyHero) then return false, current_mode end
    local intent = State.intent
    if intent == I.RETREAT then return false, current_mode end
    -- Mana reserve: pressure with razes only if mana for one more remains after the cast
    -- (except when the enemy cannot answer or we kill him).
    local R = K._race
    local killing = R and R.valid and (R.canKillSoon or State.hunting) -- Hunting = finishing
    local followUp = H.IsRazeFollowUp(bot, enemyHero)
    -- "Free pressure": the enemy has NO raze available (cooldown or mana) and we are
    -- ahead in the trade - raze without a mana reserve. The old reserve (112-150) kept the bot
    -- on right clicks only even though the enemy could not answer with a raze ("I have 1 coil, he has 0 - hit!").
    local dPress = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local enemyBandOnCdHere = not K.EnemyReadyBandAt(enemyHero, dPress, 1.2)
    local freePressure = R and R.valid and R.edge >= 0 and bot:GetMana() >= 75
        and ((R.enRazesSoon or 0) == 0 or enemyBandOnCdHere)
    -- Mana: reserve by level (at level 1-2 a "harmless" enemy is no reason to go to zero: mana is needed
    -- for last hits and the answer, and he will just regen the 64 damage). Finishing a stack - no reserve.
    if not killing and not freePressure and not H.HarassManaOK(bot, R, followUp) then
        return false, current_mode
    end
    -- Raze policy with 1 point (hero L1-L2): do NOT start a trade from range - he regens/eats a mango
    -- for the 85 damage while 75 mana (a quarter of the pool) is lost. Raze only: (a) as a mirror/answer
    -- to his cast, (b) when he walked up close himself (near->mid->far chain),
    -- (c) finishing a stack / killing. From 2 raze points (usually L3) aggression is as before.
    if not killing and not followUp and H.EarlyRazePolicyBlocks(bot, enemyHero) then
        return false, current_mode
    end
    -- Defence: raze him only with support (creeps/tower hitting him), to finish, or
    -- finishing a stack on a LEAVING enemy (he cannot answer, the stack is free)
    if State.defensive and not killing and not H.HasTradeSupport(R) then
        if not (followUp and K.IsEnemyMovingAway(bot, enemyHero)) then
            return false, current_mode
        end
    end
    if followUp then return true, "AGGRESSIVE" end
    if intent == I.ALLIN or intent == I.TRADE or intent == I.ZONE then return true, "AGGRESSIVE" end
    if intent == I.PUSH and R and R.valid and R.edge >= 0 then return true, "AGGRESSIVE" end
    if current_mode == "NEUTRAL" or current_mode == "AGGRESSIVE" then return true, current_mode end
    if bot:GetLevel() > 1 and U.HasEnemyMissedRazeRecently() and H.GetPotentialCombatMana(bot) >= 75 then
        return true, "AGGRESSIVE"
    end
    if aggroCount > 1 or H.GetPotentialCombatMana(bot) < 75 then return false, current_mode end
    local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
    local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
    local bracerDiff = U.GetItemCount(bot, "item_bracer") - U.GetItemCount(enemyHero, "item_bracer")
    if levelDiff > 0 or soulDiff >= 6 or bracerDiff > 0 then return true, "NEUTRAL" end
    return false, current_mode
end

function H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if State.defensive and not H.HasTradeSupport(K._race) then return false end
    local interruptRegen = U.IsEnemyHighValueRegen(enemyHero)
    local enemyMissed = U.HasEnemyMissedRazeRecently() and bot:GetLevel() > 1
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local attackRange = bot:GetAttackRange() + 60
    if dist > attackRange then return false end
    local minDistStack = U.GetMinDistWithStack(bot, enemyHero)
    if minDistStack > 0 and dist < minDistStack then return false end
    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
        if interruptRegen then
            for _, tower in pairs(enemyTowers or {}) do
                if tower:IsAlive() and GetUnitToLocationDistance(tower, bot:GetLocation()) < 720 then
                    return false
                end
            end
        else
            return false
        end
    end
    if interruptRegen then
        return (bot:GetHealth() / bot:GetMaxHealth()) >= 0.30
    end
    local maxAggro = enemyMissed and 2 or 1
    if aggroCount > maxAggro then return false end
    if (bot:GetHealth() / bot:GetMaxHealth()) < C.HARASS.MIN_HP_PCT then return false end
    if current_mode == "PASSIVE" and not enemyMissed then
        local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
        local eHpPct = enemyHero:GetHealth() / enemyHero:GetMaxHealth()
        if (myHpPct - eHpPct) < -0.15 then
            local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
            local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
            if levelDiff <= 0 and soulDiff < 6 then return false end
        end
    end
    return true
end

function H.GetEnemyApproachDistance(enemyMissed)
    return enemyMissed and C.HARASS.APPROACH_DISTANCE_MISS or C.HARASS.APPROACH_DISTANCE
end

function H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.8 then return false end
    return true
end

function H.IsDryVsEnemyRaze(bot, enemyHero)
    if U.IsDryVsArmedEnemySF then
        return U.IsDryVsArmedEnemySF(bot, enemyHero, W and W.s or nil)
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    return H.GetPotentialCombatMana(bot) < 75 and U.GetPotentialManaForRaze(enemyHero) >= 75
end

-- "Raze parity". The trade is roughly even (level, items) but he has mana for two
-- razes and we have one. Until we save as much, do not close into mid-band distance:
-- otherwise he catches us with the second raze and we have nothing to mirror with.
function H.IsManaBudgetDisadvantage(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local cfg = C.MANA or {}
    if cfg.PARITY_ENABLE == false then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local enBudget = K.EnemyRazeBudget(enemyHero, true)
    if enBudget < (cfg.PARITY_MIN_ENEMY or 2) then return false end
    local myBudget = K.MyRazeBudget(bot, true)
    if enBudget - myBudget < (cfg.PARITY_GAP or 1) then return false end
    -- A clear advantage in the trade - no fear: our edge has to be converted
    local R = K._race
    if R and R.valid and (R.edge >= 100 or R.canKillSoon) then return false end
    -- "Roughly equal": level and items
    if math.abs((bot:GetLevel() or 1) - (enemyHero:GetLevel() or 1)) > (cfg.PARITY_LEVEL_DIFF or 1) then
        return false
    end
    if math.abs(U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemyHero)) > (cfg.PARITY_ITEM_DIFF or 0.35) then
        return false
    end
    return true
end

function H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    -- Harass raze - with the level-based mana reserve (like any pressure)
    if not H.HarassManaOK(bot, K._race) then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local heroPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
    }

    for _, creep in pairs(enemyCreeps or {}) do
        if creep and creep:IsAlive() then
            local name = creep:GetUnitName() or ""
            if name:find("ranged") then
                local creepPred = U.PredictPosition(creep, C.RAZE.CAST_POINT)
                if U.DistanceBetweenLocations(creepPred, heroPred) <= 180 then
                    local ctx = U.GetTargetPredictionContext(creep, allyAttackers)
                    local predHp = U.PredictHPWithContext(ctx, creep, C.RAZE.CAST_POINT + 0.07)
                    for _, ability in ipairs(abilities) do
                        if ability and U.IsRazeAbilityCastable(bot, ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
                            local data = U.GetRazeAbilityData(ability)
                            local baseDmg = U.GetRazeDamage(bot, ability, 0)
                            local actualCreepDmg = creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL)
                            local midPoint = Vector(
                                (creepPred.x + heroPred.x) * 0.5,
                                (creepPred.y + heroPred.y) * 0.5,
                                (creepPred.z + heroPred.z) * 0.5
                            )
                            local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, midPoint, data.center)
                            -- This is a "2 in 1" raze (creep + hero): the hero must be covered robustly
                            -- (now and after the cast), otherwise it is just 75 mana for one creep while the band
                            -- goes on cooldown right as he arrives
                            local heroErrAim = U.RobustRazeErrors(bot, enemyHero, data.center, C.RAZE.CAST_POINT)
                            local heroCovered = heroErrAim <= (C.RAZE.HIT_RADIUS - 60)
                            if predHp > 0 and predHp <= actualCreepDmg + 12 and plannedError <= C.RAZE.HIT_RADIUS and heroCovered then
                                local actionType = "TURN"
                                if U.GetAngleDifference(bot, midPoint) <= C.RAZE.MAX_ANGLE_TO_CAST then
                                    actionType = "CAST"
                                end
                                if H.CastOrTurnRaze(bot, ability, actionType, midPoint, enemyHero) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Emergency consumables BEFORE retreats/salves: wand/faerie when nearly dead,
-- mango for a finish (the raze decides the fight). They used to be in HandleItemsAndConsumables
-- at the end of the tick - while retreating the tick ended earlier and the faerie "was not pressed before death".
function H.HandleEmergencyConsumables(bot, race, snapshot)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GameTime() < (State.lastItemUseTime or 0) + 0.3 then return false end
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local curHp = bot:GetHealth() or 0
    local commitKill = GameTime() < (State.commitKillUntil or 0)
    local enemy = snapshot and snapshot.enemy or (W.s and W.s.enemy)
    local enemyLive = U.CanQuery(enemy)
    local distance = enemyLive and GetUnitToLocationDistance(bot, enemy:GetLocation()) or 99999

    -- Compute TRUE imminent impact damage (`imminentImpact`): ONLY real in-flight attack projectiles on `bot`,
    -- active enemy Shadowraze cast phase whose AOE covers `bot`, or melee/tower attack actively swinging at `bot`!
    -- NEVER waste `item_faerie_fire` (`-2` permanent attack damage!) at `18%–40%` HP with `0` projectiles in flight
    -- (`9056469656.dem` `02:02.72` `tk=6648`: `149/824 = 18.1% HP`, `Sha` at `873u` running away, `Flask` popped `0.66s` later!).
    local imminentImpact = 0
    if enemyLive then
        local label = K.EnemyPhase()
        if label then
            local center = K.EnemyRazeCenter(enemy, label)
            if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then
                imminentImpact = imminentImpact + K.EnemyRazeDamage(bot, enemy, 1)
            end
        end
        if distance <= 215 and enemy.GetAttackTarget and enemy:GetAttackTarget() == bot then
            imminentImpact = imminentImpact + K.AttackDamageVs(enemy, bot)
        end
    end
    if snapshot then
        for _, c in pairs(snapshot.enemyCreeps or {}) do
            if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot and GetUnitToLocationDistance(bot, c:GetLocation()) <= 190 then
                imminentImpact = imminentImpact + K.AttackDamageVs(c, bot)
            end
        end
        for _, tw in pairs(snapshot.enemyTowers or {}) do
            if U.CanQuery(tw) and tw:IsAlive() and tw.GetAttackTarget and tw:GetAttackTarget() == bot
                and GetUnitToLocationDistance(bot, tw:GetLocation()) <= 780 then
                imminentImpact = imminentImpact + bot:GetActualIncomingDamage(tw:GetAttackDamage() or 90, DAMAGE_TYPE_PHYSICAL)
            end
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if projectile.is_attack and U.CanQuery(projectile.caster) then
                imminentImpact = imminentImpact + K.AttackDamageVs(projectile.caster, bot)
            end
        end
    end
    if hpPct < (C.ITEMS.STICK_USE_PCT or 0.10) then
        local stickItem = H.GetStickLikeItem(bot)
        if stickItem then
            bot:Action_UseAbility(stickItem)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    local imminentLethal = imminentImpact > 0 and curHp <= imminentImpact + 18
    local criticalLowFloor = hpPct <= 0.125
        and (imminentImpact > 0 or (enemyLive and distance <= 680) or not U.HasItem(bot, "item_flask"))
    if imminentLethal or criticalLowFloor then
        local faerie = U.GetActiveItemByName(bot, "item_faerie_fire")
        if faerie then
            bot:Action_UseAbility(faerie)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    -- Mango for the finish: let the raze decide the fight right now
    if commitKill and bot:GetMana() < 75 and (bot:GetMana() + U.GetMangoMana(bot)) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    return false
end

-- Plant only when healing is needed; identify the new tree by POSITION, never by handle.
-- (21.10 correction of the 20.10 finding) The bot does plant a branch - and then could not find
-- its own tree: `plan.before[tree]` is keyed by the tree userdata returned by GetNearbyTrees, and in
-- the real client two calls do not return the same userdata for the same tree.  So "not before[tree]"
-- was true for every tree and the bot ate whatever OLD tree happened to lie within 80 of the plant
-- point; the branch stayed on the map as a tree and the tango charge was spent on a stranger.
-- Now the "already there" set is stored as POSITIONS (matched within 12 units) and the plant point is
-- chosen so that no tree stands within 90 units of it - then the only tree that can be within 60 of
-- the point a second later is the one we planted.
-- =================================================================================================
-- SOURCE 2 `CDOTA_TempTree` (`BinaryObjectID = N_static + k`) IRON BRANCH + TANGO CONTROLLER
-- Valve's C++ `bot:GetNearbyTrees(r)` scans only the static spatial grid (`0 .. N_static - 1`,
-- `N_static = max(GetAllTrees()) + 1 = 3282` on `dota`) and never returns dynamic `CDOTA_TempTree`
-- entities planted by `item_branches` (ValveSoftware/Dota2-Gameplay#23152). Every `CDOTA_TempTree`
-- created during a match receives sequential `BinaryObjectID = N_static + k` (`3282, 3283, ...`),
-- which `bot:Action_UseAbilityOnTree(tango, treeId)` targets directly (`DOTA_UNIT_ORDER_CAST_TARGET_TREE`).
-- =================================================================================================
local BRANCH_CLEAR_RADIUS = 90
local BRANCH_FIND_RADIUS  = 65
local TEMPTREE_PROBE_OFFSETS = { 0, 1, 2, -1, 3, 4, -2, 5 }

local function CountUnitBranches(unit, maxSlot)
    if not unit or not U.CanQuery(unit) then return nil end
    local n = 0
    for i = 0, (maxSlot or 8) do
        local ok, it = pcall(function() return unit:GetItemInSlot(i) end)
        if ok and it and it:GetName() == "item_branches" then
            n = n + 1
        end
    end
    return n
end

function H.EnsureTreeRegistry()
    if State.staticTreeBaseId ~= nil then return State.staticTreeBaseId end
    local maxId = -1
    if type(GetAllTrees) == "function" then
        local ok, all = pcall(GetAllTrees)
        if ok and type(all) == "table" then
            for _, tid in pairs(all) do
                if type(tid) == "number" and tid > maxId then
                    maxId = tid
                end
            end
        end
    end
    State.staticTreeBaseId = (maxId >= 0) and (maxId + 1) or 3282
    State.tempTreeCount = State.tempTreeCount or 0
    return State.staticTreeBaseId
end

function H.UpdateTempTreeTracker(bot, enemy)
    H.EnsureTreeRegistry()
    local myB = CountUnitBranches(bot, 14)
    if myB ~= nil then
        if State.prevBotBranches ~= nil and myB < State.prevBotBranches and not State.branchTango then
            State.tempTreeCount = (State.tempTreeCount or 0) + (State.prevBotBranches - myB)
        end
        State.prevBotBranches = myB
    end
    if enemy and U.CanQuery(enemy) then
        local enB = CountUnitBranches(enemy, 8)
        if enB ~= nil then
            if State.prevEnemyBranches ~= nil and enB < State.prevEnemyBranches then
                State.tempTreeCount = (State.tempTreeCount or 0) + (State.prevEnemyBranches - enB)
            end
            State.prevEnemyBranches = enB
        end
    end
end

local function BranchPointClear(bot, point)
    for _, tree in pairs(bot:GetNearbyTrees(400) or {}) do
        if U.DistanceBetweenLocations(GetTreeLocation(tree), point) < BRANCH_CLEAR_RADIUS then return false end
    end
    return true
end

local function BranchIsOldTree(plan, loc)
    for _, old in pairs(plan.beforeLocs or {}) do
        if U.DistanceBetweenLocations(old, loc) < 12 then return true end
    end
    return false
end

function H.FindPlantedTreeViaAPI(bot, plan)
    for _, tree in pairs(bot:GetNearbyTrees(350) or {}) do
        if not plan.beforeSet[tree] then
            local loc = GetTreeLocation(tree)
            if loc and U.DistanceBetweenLocations(loc, plan.location) < BRANCH_FIND_RADIUS
                and not BranchIsOldTree(plan, loc) then
                return tree
            end
        end
    end
    if not plan.checkedAllTrees and type(GetAllTrees) == "function" then
        plan.checkedAllTrees = true
        local ok, all = pcall(GetAllTrees)
        if ok and type(all) == "table" then
            for _, tree in pairs(all) do
                if not plan.beforeSet[tree] then
                    local okL, loc = pcall(GetTreeLocation, tree)
                    if okL and loc and U.DistanceBetweenLocations(loc, plan.location) < BRANCH_FIND_RADIUS then
                        return tree
                    end
                end
            end
        end
    end
    return nil
end

-- PROVEN SOURCE 2 ENGINE INVARIANT (`libserver.so` + live `.dem` ticks `3990..4146` & `7704..7708`):
-- Human `DOTA_UNIT_ORDER_CAST_TARGET_TREE` accepts dynamic `CDOTA_TempTree` (`id >= N_static`, e.g. `3238+`),
-- whereas Valve's C++ `CDOTA_Bot::Action_UseAbilityOnTree(pAbility, iTree)` validates `0 <= iTree < N_static`
-- against the static map tree array (`ValveSoftware/Dota2-Gameplay#23152`, `#34354`) and silently drops ALL
-- `CDOTA_TempTree` targets! Planting `item_branches` from a Lua Bot therefore destroys `50g` + `-1 STR/AGI/INT`
-- permanently for ZERO healing. Keeping `item_branches` in slots `0..5` gives permanent `+1 all stats` (`+22 HP`,
-- `+12 MP`, `+1 DMG`), while `H.TryWaveSafeStaticTango` eats static trees cleanly with zero missed CS!
function H.HandleActiveBranchTango(_bot)
    State.branchTango = nil
    State.branchTangoSwapUntil = nil
    return false
end

function H.HandleBranchTango(_bot, _tango)
    State.branchTango = nil
    State.branchTangoSwapUntil = nil
    return false
end

function H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero)
    if GameTime()>=(State.branchTangoSwapUntil or -math.huge) then U.ManageInventorySlots(bot) end
    -- An eat-tree order was issued: hold position until modifier_tango_heal appears (up to 1 s)
    if State.tangoCastAt > 0 and (GameTime() - State.tangoCastAt) < 1.0 then
        if bot:HasModifier("modifier_tango_heal") then
            H.ClearTangoState()
            State.tangoFails = 0
        else
            State.actionTaken = true
            return true
        end
    end
    if GameTime() < State.lastItemUseTime + 0.3 then return false end
    if H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then return false end

    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    -- (Wand/faerie moved to HandleEmergencyConsumables - the start of the tick)
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local isHighValueBeingAttacked = false
    for _, c in pairs(enemyCreeps or {}) do
        if c:IsAlive() then
            local name = c:GetUnitName() or ""
            if name:find("ranged") or name:find("flagbearer") or name:find("siege") then
                if (c:GetHealth() / c:GetMaxHealth()) < 0.50 then
                    isHighValueBeingAttacked = true
                    break
                end
                for _, atk in pairs(allyAttackers or {}) do
                    if atk:IsAlive() and atk:GetAttackTarget() == c then
                        isHighValueBeingAttacked = true
                        break
                    end
                end
                if isHighValueBeingAttacked then break end
            end
        end
    end

    local tcfg = C.TANGO or {}
    local missingHp = bot:GetMaxHealth() - bot:GetHealth()
    local wantTango = hpPct < (tcfg.USE_HP_PCT or 0.80) and missingHp >= (tcfg.MIN_MISSING_HP or 100)
    -- In an active fight (TRADE/ALLIN) do not walk to trees while HP is above 60%; in ZONE eat below 60%
    local intent = State.intent
    if (intent == "TRADE" or intent == "ALLIN") and hpPct >= 0.60 then wantTango = false end
    if intent == "ZONE" and hpPct >= 0.60 then wantTango = false end
    if intent == "RETREAT" then wantTango = false end
    -- A "valuable creep under attack" delays the tango only at HP >= 50%
    if hpPct < 0.50 then isHighValueBeingAttacked = false end
    if bot:HasModifier("modifier_tango_heal") then
        H.ClearTangoState()
        wantTango = false
    end

    if wantTango and not isHighValueBeingAttacked then
        local tango = U.GetActiveItemByName(bot, "item_tango")
        if tango then
            local now = GameTime()
            -- An eat-tree order was already issued: wait for modifier_tango_heal without leaving the tree.
            -- Otherwise the next handler walks the bot away and the eat order is cancelled (loop).
            if State.tangoCastAt > 0 and (now - State.tangoCastAt) < 1.0 then
                State.actionTaken = true
                return true
            end
            if State.tangoCastAt > 0 then
                -- The order did not work within 1 s: try again, after two failures use another tree
                State.tangoFails = (State.tangoFails or 0) + 1
                State.tangoCastAt = 0
                if State.tangoFails >= 2 then
                    State.tangoBadTree = State.tangoTree
                    State.tangoBadTreeTime = now
                    State.tangoFails = 0
                    H.ClearTangoState()
                end
            end
            local branchAction,waitingForBranch=H.HandleBranchTango(bot,tango)
            if branchAction then return true end
            if waitingForBranch then return false end
            local tree, treeLoc = H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
            if tree and treeLoc then
                local distToTree = U.DistanceBetweenLocations(bot:GetLocation(), treeLoc)
                if distToTree > 165 then
                    H.SmartMove(bot, treeLoc, 40)
                    return true
                end
                bot:Action_UseAbilityOnTree(tango, tree)
                State.branchTangoDone=true
                State.lastItemUseTime = now
                State.tangoCastAt = now
                State.actionTaken = true
                return true
            end
        end
    elseif not wantTango then
        H.ClearTangoState()
    end

    return false
end

function H.ProcessTelemetry(bot)
    local now = GameTime()
    for i = #State.flyingProjectiles, 1, -1 do
        local proj = State.flyingProjectiles[i]
        if now > proj.impactTime + 0.15 then
            table.remove(State.flyingProjectiles, i)
        end
    end
end

function H.HandleEmergencyRetreat(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()

    if enemyHero and U.CanQuery(enemyHero) then
        local canOneShot, oneShotMethod = U.CanOneShotEnemyHero(bot, enemyHero)
        local canRazeKill, razeLabel = U.CanKillEnemyWithOneRaze(bot, enemyHero)
        if canOneShot then
            return false
        end
        if canRazeKill then
            return false
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct >= returnHpPct then
        if H.IsAtFountain(bot) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            State.goingToFountain = true
            State.fountainReason = "HP"
        else
            -- HP recovered on the way (regen/tango/salve): the emergency retreat is over. Otherwise
            -- "FOUNTAIN" would stay in State and on the next HP dip below 50% would force
            -- a fountain run (committedFountain) for no real reason.
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            H.ClearForcedRetreat()
        end
        return false
    end

    local ownT1Pos = P.GetT1Close(bot, 0)
    local deepPastOwnT1 = ownT1Pos and (GetUnitToLocationDistance(bot, ownT1Pos) >= 1450)
        and (distToFountain < U.DistanceBetweenLocations(ownT1Pos, fountain) - 900)
    -- `02:11.7–02:12.7` (`tk=7384..7414`) Fix: clear latched `State.emergencyRetreat == "FOUNTAIN"` BEFORE `TryTPHome`
    -- whenever we are NOT yet deep past own T1 (`not deepPastOwnT1`) and either a Salve is in pipeline/nearly affordable
    -- (`>= 72g`) OR the enemy also backed off crippled (`EnemyResourcesAsWeak`, including FoW)!
    if State.emergencyRetreat == "FOUNTAIN" and not deepPastOwnT1 then
        if (U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero))
            or (U.EnemyResourcesAsWeak and U.EnemyResourcesAsWeak(bot, enemyHero, hpPct)) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            H.ClearForcedRetreat()
            -- Fall through on this same tick so `GetEmergencyRetreatReason` can immediately transition to `"COURIER"`
            -- when critically low (`<= 280 HP` / `<= 24% HP`) with a Salve courier flying toward us (`9074513540.dem` `11:03.40` Fix)!
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct < returnHpPct then
        if H.TryTPHome(bot, enemyHero) then return true end
    end

    local committedFountain = State.emergencyRetreat == "FOUNTAIN"
        and State.emergencyRetreatStartTime > 0
        and ((GameTime() - State.emergencyRetreatStartTime) >= 2.5 or deepPastOwnT1)
        and (W.s == nil or W.s.enemyAlive ~= false)
        and not U.HasAnyHealing(bot)
        and not (not deepPastOwnT1 and U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero))
        and distToFountain > ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500)

    if committedFountain then
        H.BeginForcedRetreat(bot, fountain, 1.0)
        return true
    end

    local reason, extraLoc = U.GetEmergencyRetreatReason(bot, enemyHero)
    if not reason then
        if State.emergencyRetreat then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
        end
        return false
    end

    if reason == "COURIER" and extraLoc then
        State.emergencyRetreat = "COURIER"
        State.emergencyRetreatStartTime = 0
        local botLoc = bot:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, extraLoc)
        if dist > 150 then
            local toFountain = (fountain - botLoc):Normalized()
            local toCourier = (extraLoc - botLoc):Normalized()
            local blended = (toCourier * 0.8 + toFountain * 0.2):Normalized()
            H.SmartMove(bot, botLoc + blended * math.min(dist, 400), 60)
        end
        State.actionTaken = true
        return true
    end

    if State.emergencyRetreat ~= "FOUNTAIN" then
        State.emergencyRetreatStartTime = GameTime()
    end
    State.emergencyRetreat = "FOUNTAIN"

    if distToFountain < ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500) then
        State.emergencyRetreat = nil
        State.goingToFountain = true
        State.fountainReason = "EMERGENCY"
        State.actionTaken = true
        return true
    end

    H.BeginForcedRetreat(bot, fountain, 1.0)
    return true
end

function H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if U.ShouldUseGlyphDefensive(bot, allyTowers) then
        U.UseGlyph(bot)
        State.actionTaken = true
        return true
    end
    if U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then
        U.UseGlyph(bot)
        State.glyphUsedForDive = true
        State.glyphDiveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleForcedSalve(bot)
    if not U.ShouldForceSalve(bot) then return false end
    if GameTime() < State.lastForceSalveTime + 1.0 then return false end
    local nearbyEnemyHeroes = bot:GetNearbyHeroes(700, true, BOT_MODE_NONE)
    if nearbyEnemyHeroes and #nearbyEnemyHeroes > 0 then
        local fountain = P.GetFountain(bot)
        local botLoc = bot:GetLocation()
        H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 400, 60)
        State.actionTaken = true
        return true
    end
    local nearbyEnemyCreeps = bot:GetNearbyLaneCreeps(500, true) or {}
    for _, c in pairs(nearbyEnemyCreeps) do
        if U.CanQuery(c) and c:GetAttackTarget() == bot then -- Creep in fog -> do not query
            local fountain = P.GetFountain(bot)
            local botLoc = bot:GetLocation()
            H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 350, 60)
            State.actionTaken = true
            return true
        end
    end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if flask then
        if H.HasEnemyProjectileIncoming(bot) then
            local safeLoc = H.GetSalveSafeRetreatLocation(bot, nil)
            H.BeginForcedRetreat(bot, safeLoc, 0.65)
            return true
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastForceSalveTime = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

-- Purchases have one owner: item_purchase_nevermore.lua.

function H.HandleSafeDistanceFromEnemy(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if canOneShot then
        if H.IssueHeroAttack(bot, enemyHero) then
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end
    local canQuickRazeKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
        local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
        if ability then
            local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
            local angleDiff = U.GetAngleDifference(bot, predLoc)
            local actionType = angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, ability, actionType, predLoc, enemyHero) then
                return true
            end
        end
    end
    if not U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = isCritical and (SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950) or SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if dist < minDist then
        local duration = isCritical and 1.20 or 0.80
        H.BeginForcedRetreat(bot, safeLoc, duration)
        return true
    end
    return false
end

function H.HandleDryManaMidRazeAvoidance(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if K.EnemyCastableRazeCount(enemyHero, 1.4) <= 0 then
        State.dryRetreatHystUntil = 0
        return false
    end
    if not H.IsDryVsEnemyRaze(bot, enemyHero) then
        State.dryRetreatHystUntil = 0
        return false
    end
    if K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemyHero, W.s) then
        State.dryRetreatHystUntil = 0
        return false
    end
    -- `v7.9.7-pro` (`0255 @ 08:36.6` `5 HP`, `0307 @ 08:52.4` `17 HP` Escape, `0307 @ 10:12.8` `10 HP` Turnback Fix!):
    -- NEVER run away from a `1–2` right-click lethal enemy (`<= 1.85x` attack damage) when our HP comfortably tanks
    -- his desperation burst (`+145 HP` cushion) and we can kinematically catch him outside unshielded Enemy T1!
    do
        local dCheckOne = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local myHpOne = bot:GetHealth() or 0
        local myAtkOne = K.AttackDamageVs(bot, enemyHero)
        local enEffHpOne = (enemyHero:GetHealth() or 9999) + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemyHero)) or 0)
        local isTrueOneShot = U.CanOneShotEnemyHero(bot, enemyHero)
        local burstHere = K.EnemyBurstVs(bot, enemyHero, math.min(dCheckOne, 500), 1.15, false)
        if ((isTrueOneShot and myHpOne >= burstHere + 8)
                or (enEffHpOne <= myAtkOne * 1.85 and myHpOne >= 340 and myHpOne >= burstHere + 145))
            and H.CanKinematicallyCatchForAttack(bot, enemyHero, W.s and W.s.enemyTowers, W.s and W.s.allyCreeps, 1.65) then
            State.dryRetreatHystUntil = 0
            return false
        end
    end
    if State.actionTaken then return false end
    local now = GameTime()
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local safeDryDist = (U.GetDrySafeStandoffDist and U.GetDrySafeStandoffDist(bot, enemyHero)) or 745
    if safeDryDist <= 0 then return false end
    -- `v7.9.1` Dry-Mana Retreat Distance + Time Hysteresis (`9071946472.dem` `03:39.0–03:45.1` Oscillation Fix!):
    -- Enter retreat when `dist < safeDryDist - 12` (`~733u`), and KEEP retreating until `dist >= safeDryDist + 105` (`~850u`)
    -- while `now < State.dryRetreatHystUntil` so SF never releases retreat at `782u` and turns back into enemy coils/autos!
    local inHyst = now < (State.dryRetreatHystUntil or 0)
    local triggerDist = inHyst and (safeDryDist + 55) or (safeDryDist - 12)
    if dist >= triggerDist then return false end
    local fnt = P.GetFountain(bot)
    local deepT1 = P.GetBehindT1(bot, 320)
    if dist >= safeDryDist and U.DistanceBetweenLocations(bot:GetLocation(), fnt) <= U.DistanceBetweenLocations(deepT1, fnt) then
        return false
    end
    -- `auto-20261102-0007` (`7:58..8:06` `1002 HP` @ `dEC=1554u` & `8:56..9:03` `925 HP` @ `dEC=1626u`) 1,340u XP-Radius Tether:
    -- When healthy (`>= 580 HP` & above 2-raze + buffer) with `0` raze stacks, NEVER let forward enemy posturing push SF
    -- beyond `1,340u` from active lane `enemyCreeps` (strictly inside Dota 2's `1,500u` XP radius!).
    -- `v7.9.20` (`1610.dem` `#37/#38/#40` @ `04:59..05:14` `782..869 HP` Under-Own-T1 Dry-CS Exemption!):
    -- When standing under our own live allied T1 (`<= 610u`), unstacked (`myStDry == 0`), holding `>= 2-raze + auto + 165` HP,
    -- outside `Q` (`dist >= 510u`), and an enemy creep is dying (`<= 210 HP`) near our T1, DO NOT lock `0.90s` forced retreat
    -- and forfeit uncontested last-hits under our own tower!
    local myHpDry = bot:GetHealth() or 0
    local myStDry = U.GetShadowrazeDebuff(bot) or 0
    local twoRazeDry = K.EnemyRazeDamage(bot, enemyHero, 2)
    if myStDry == 0 and dist >= 510 and myHpDry >= (twoRazeDry + K.AttackDamageVs(enemyHero, bot) + 165)
        and W and W.s and W.s.allyT1Alive ~= false and W.s.allyT1Loc
        and U.DistanceBetweenLocations(bot:GetLocation(), W.s.allyT1Loc) <= 610 then
        for _, ecOwn in pairs(W.s.enemyCreeps or {}) do
            if ecOwn and U.CanQuery(ecOwn) and ecOwn:IsAlive() and (ecOwn:GetHealth() or 999) <= 210
                and U.DistanceBetweenLocations(ecOwn:GetLocation(), W.s.allyT1Loc) <= 840 then
                return false
            end
        end
    end
    local healthyForXpTether = (myStDry == 0)
        and (myHpDry >= math.max(580, twoRazeDry + 95))
    local nearestCreepLoc = nil
    local minCreepDist = 9999
    if healthyForXpTether and W and W.s and W.s.enemyCreeps then
        for _, ec in pairs(W.s.enemyCreeps) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc < minCreepDist and dc <= 2200 then
                    minCreepDist = dc
                    nearestCreepLoc = ec:GetLocation()
                end
            end
        end
    end
    if nearestCreepLoc and minCreepDist >= 1310 and dist >= 545 then
        return false
    end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero)
    if nearestCreepLoc and U.DistanceBetweenLocations(retreatLoc, nearestCreepLoc) > 1340 then
        local clampedXpLoc = nearestCreepLoc + (fnt - nearestCreepLoc):Normalized() * 1340
        if U.DistanceBetweenLocations(clampedXpLoc, enemyHero:GetLocation()) >= 545 then
            retreatLoc = clampedXpLoc
        end
    end
    State.dryRetreatHystUntil = now + 1.45
    H.BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

function H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_DISTANCE) or 215
    local minDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MIN_DISTANCE) or 150
    local maxDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MAX_DISTANCE) or 250
    local tol = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_TOLERANCE) or 25
    if dist >= minDist and dist <= maxDist then
        H.SafeClearActions(bot)
        bot:Action_MoveToLocation(botLoc)
        State.lastMoveLoc = botLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    -- With a stack on us do NOT close on the enemy (near band = his right click + near raze
    -- with the bonus); "keep the answer distance" only if already adjacent (back off to 215)
    if dist > maxDist then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    H.SmartMove(bot, holdLoc, tol)
    State.actionTaken = true
    return true
end

function H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not secondStackActive or hitLabel ~= "near" then return false end
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if myStacks ~= 1 or myRemain <= C.RAZE.RETREAT_MIN_REMAIN then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            local actionType = U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.0)
    end

    if enemyIsHittingUs then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local attackRange = bot:GetAttackRange() + 60
        if dist <= attackRange then
            if H.IssueHeroAttack(bot, enemyHero) then
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return true
            end
        end
    end

    return H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
end

function H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreepsData, enemyCreepsData)
    if not U.CanQuery(enemyHero) or State.towerChaseBlockedEnemy==enemyHero or State.actionTaken then return false end
    local active,label=U.IsSecondStackDangerActive(bot,enemyHero)
    if not active or not label then return false end
    local ab=H.GetRazeAbilityByLabel(bot,label)
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemyHero)
    if action then return H.CastOrTurnRaze(bot,ab,action,aim,enemyHero) end
    -- A real in-range attacker must not get free hits while we reposition for a different band.
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local setup=U.GetRazeSetupPositionForAbility(bot,enemyHero,U.GetRazeCenterByLabel(label))
    return setup and H.ApproachEnemyPoint(bot,enemyHero,setup,35,enemyTowers,allyCreeps) or false
end

-- Instant mirror. His raze just landed on us (<= MIRROR_INSTANT_SEC): he stands
-- in the same band on our side (symmetry) - answer immediately with the same band (his copy is on a 9 s cd)
-- or with any band that covers robustly. Previously the answer came after the stack-exit rule and the
-- finish block, i.e. 0.5-1 s later when the enemy had already moved ("mirrors slowly").
-- Without closing: cast/turn in place only. No mirror if: his burst is lethal now; less than
-- MIRROR_MIN_HP_LEFT would remain after his next raze; we are under his T1 without a creep shield.
H._mirrorOrder = { nil, nil, nil }
function H.HandleInstantMirrorRaze(bot, enemyHero, race, s)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- While fleeing we MAY answer (an instant reply to his raze that hit us) -
    -- this is a deliberate "turn, cast, run again", not twitching (as it was before v2.6)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local age = U.GetRecentEnemyRazeHitAge(enemyHero)
    if age > ((C.RAZE and C.RAZE.MIRROR_INSTANT_SEC) or 0.7) then return false end
    -- Deduplicate the enemy HIT, not all our casts for 1.2 seconds.
    local hitTime = GameTime() - age
    if State.mirrorAnsweredEnemy == enemyHero and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit - hitTime) < 0.001 then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    local canKillNow = race and race.valid and race.canKillNow
    if race and race.valid and race.heCanKillNow and not canKillNow then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemyHero, 1)
    if not canKillNow and (bot:GetHealth() - oneRaze) < ((C.RAZE and C.RAZE.MIRROR_MIN_HP_LEFT) or 110) then
        return false
    end
    local underT1 = H.IsBotUnderEnemyT1(bot, s and s.enemyTowers or {})
    if underT1 and not H.TowerLockedOnCreep(s and s.enemyT1) then return false end
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
        return false
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemyHero)
    local order = H._mirrorOrder
    local n = 0
    if hitLabel then n = n + 1; order[n] = hitLabel end
    for i = 1, 3 do
        if K.LABELS[i] ~= hitLabel then n = n + 1; order[n] = K.LABELS[i] end
    end
    for i = 1, n do
        local ab = H.GetRazeAbilityByLabel(bot, order[i])
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                if U.DEBUG then print(string.format("[SF-BOT] instant mirror %s (%s) age=%.2f", order[i], actionType, age)) end
                return true
            end
        end
    end
    return false
end

function H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false end
    local shouldClose, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not shouldClose or not closePos then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local canQuickRazeKill, _ = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
    elseif U.IsInEnemyRazeKillThreat(bot, enemyHero) then
        return false
    end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            -- Via the shared CastOrTurnRaze (facing check + turn step, not walking to the enemy)
            local actionType = H.RazeFacingOK(bot, predicted) and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false end
    -- The mana reserve for the near punish was removed (v2.3 gated it with a 130 reserve: at 141 mana the bot
    -- silently stood in the near band and took stacks). The enemy walked up close - that is the best moment
    -- for a trade: a near raze now, mid/far at the runner. Only 75 mana is needed.
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and safeReplyLabel ~= "near" then return false end
    -- Robust - the near circle must cover the enemy both now and after the cast time
    -- (an enemy leaving the near band is not "punished" with a raze into thin air)
    -- A margin of >= 100 u from the near circle edge: an enemy standing at the edge (380-450) gets out of
    -- the circle during the cast as soon as he starts moving; such a target is hit by the mid raze (via GetBestRaze).
    if K.IsEnemyMovingAway(bot, enemyHero) then return false end
    local errAim, errFacing, predicted = U.RobustRazeErrors(bot, enemyHero, C.RAZE.NEAR_CENTER, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - 100
    if errAim > limit then return false end
    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then return false end
    if H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
        if oneRaze < enemyHero:GetHealth() then return false end
    end
    local actionType = "TURN"
    if errFacing <= limit then -- Same threshold as the candidate (no TURN dead zone)
        actionType = "CAST"
    end
    if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
        if actionType == "CAST" then
            -- Chain window: for the next ~5 s the stack-finishing razes go without a mana reserve
            State.nearChainUntil = GameTime() + ((C.RAZE and C.RAZE.NEAR_CHAIN_WINDOW) or 5.0)
        end
        return true
    end
    return false
end

-- The enemy walked up close - punishing him beats waiting for the last hit. Previously at this moment
-- the last-hit block ran (is_free_to_prehit = false) and the bot silently stood by the creep while being hit.
-- Try the near raze first; if it does not cover, finish for sure with mid/far
-- and extend the stack (he is already in reach, too late for him to leave).
function H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.RAZE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist > (cfg.PUNISH_CLOSE_RANGE or 520) then return false end
    if H.GetPotentialCombatMana(bot) < (cfg.PUNISH_MIN_POT_MANA or 150) then return false end
    local R = K._race
    local weWin = R and R.valid and (R.canKillSoon or R.edge > 0)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not weWin and not U.CanOneShotEnemyHero(bot, enemyHero) then
        return false
    end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then return false end

    if H.HandleImmediateNearRazePunish(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps) then
        return true
    end

    -- Near does not cover - hit with mid/far and extend the stack
    State.nearChainUntil = math.max(State.nearChainUntil or 0, GameTime() + (cfg.NEAR_CHAIN_WINDOW or 5.0))
    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, true) then
        return true
    end
    return false
end

function H.HandleBootDisadvantageMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if not U.ShouldFearBootsMidRaze(bot, enemyHero) then return false end
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = (C.BOOT_FEAR and C.BOOT_FEAR.MID_RAZE_RADIUS) or 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, (C.BOOT_FEAR and C.BOOT_FEAR.RETREAT_DURATION) or 0.95)
    return true
end

-- Is any "mid band fear" active (same conditions as the three handlers below,
-- without the distance check). The U._midFear flag makes the minimum enemy distance proactive.
function H.MidRazeFearActive(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) or not U.EnemyHasRaze(enemyHero) then return false end
    -- Do not back off past our own T1: the tower will punish him and retreating behind it loses the lane
    if H.IsNearOwnT1(bot, 400) then return false end
    if State.enemyReachedLevel2First and bot:GetLevel() < 2 then return true end
    if H.IsDryVsEnemyRaze(bot, enemyHero) then return true end
    if H.IsManaBudgetDisadvantage(bot, enemyHero) then return true end
    if U.ShouldFearBootsMidRaze(bot, enemyHero) and not U.IsInEnemyRazeKillThreat(bot, enemyHero)
        and not U.CanKillEnemyWithTwoRazes(bot, enemyHero) then
        return true
    end
    return false
end

function H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not State.enemyReachedLevel2First then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
        return false
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

function H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps)
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    -- The tower is nearly down - stay under it and finish it
    if LN.IsTowerFinishable(bot, t1) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    local closestDist = math.huge
    local closestCreep = nil
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                local d = GetUnitToLocationDistance(t1, c:GetLocation())
                if d < closestDist then
                    closestDist = d
                    closestCreep = c
                end
            end
        end
    end
    local prevDist = State.enemyT1ClosestCreepDist
    State.enemyT1ClosestCreepDist = (closestCreep and closestDist) or nil
    State.enemyT1ClosestCreepTime = GameTime()
    local driftStart = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_START) or 620
    local driftHard = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_HARD) or 700
    local driftDelta = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_DELTA) or 22
    local shouldRetreat = false
    if not closestCreep then
        shouldRetreat = true
    elseif closestDist >= driftHard then
        shouldRetreat = true
    elseif prevDist and closestDist >= driftStart and closestDist > (prevDist + driftDelta) then
        shouldRetreat = true
    end
    if not shouldRetreat then return false end
    -- NEVER burn our 300s team Glyph just to step out of enemy T1 range (`9070559899.dem` `08:07.4` `tk=17580` Fix:
    -- `creep 2239` crossed `706.8u >= 700u` while SF stood at `833.9u` = `34u` inside `868u` outer edge and wasted Glyph!).
    local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
    H.BeginForcedRetreat(bot, safeLoc, 0.90)
    return true
end

-- True when a single right-click from `bot` kills `enemyHero` right now WITHOUT walking (`<= atkRange + 25`)
-- while respecting enemy T1 dive safety (`9070149539.dem` `05:05` `tk=12312` & `tk=12340` 1-Hit Execution Fix!).
function H.CanSafeInRangeOneShot(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false, 9999 end
    if not U.CanOneShotEnemyHero(bot, enemyHero) then return false, 9999 end
    local eLoc = enemyHero:GetLocation()
    local dist = GetUnitToLocationDistance(bot, eLoc)
    local atkRange = (bot:GetAttackRange() or 525) + 25
    if dist > atkRange then return false, dist end
    local myHp = bot:GetHealth() or 0
    local aggroRad = (C.TOWER and C.TOWER.AGGRO_RADIUS) or 868
    for _, tw in pairs(enemyTowers or {}) do
        if tw and tw:IsAlive() then
            if LN.IsBeyondTower(bot, tw, eLoc) then
                return false, dist
            end
            if GetUnitToLocationDistance(tw, eLoc) < (aggroRad - 525)
                and not H._hasTankCreepUnderTower(tw, allyCreeps) and myHp < 280 then
                return false, dist
            end
        end
    end
    if H.IsBotUnderEnemyT1(bot, enemyTowers) then
        if H.TowerBurnActive() or myHp < (bot:GetMaxHealth() or 600) * 0.40 or myHp < 300 then
            return false, dist
        end
    end
    return true, dist
end

-- Detects whether stepping from `botLoc` to `stepLoc` runs into unpassable terrain or a tree trunk (`<= 58u`),
-- which caused Source 2 C++ navmesh in `9070149539.dem` (`tk=12322..12348`) to detour SF `110 deg` SW around
-- the Dire T1 tree grove (`yaw=242..247 deg`), stalling `angleDiff` at `18..22 deg` and never firing `Raze3`!
function H.IsStepBlockedByTerrainOrTrees(bot, botLoc, stepLoc)
    if type(IsLocationPassable) == "function" then
        local okP, pass = pcall(IsLocationPassable, stepLoc)
        if okP and pass == false then return true end
    end
    if bot and bot.GetNearbyTrees and type(GetTreeLocation) == "function" then
        local okT, trees = pcall(bot.GetNearbyTrees, bot, 130)
        if okT and type(trees) == "table" then
            local seg = stepLoc - botLoc
            local segLen = seg:Length2D()
            local segDir = (segLen > 0.001) and (seg * (1.0 / segLen)) or Vector(1, 0, 0)
            local minProj = math.min(14, segLen)
            for _, tr in ipairs(trees) do
                local okL, tLoc = pcall(GetTreeLocation, tr)
                if okL and tLoc then
                    local rel = tLoc - botLoc
                    local dStart = rel:Length2D()
                    local proj = math.max(minProj, math.min(segLen, rel.x * segDir.x + rel.y * segDir.y))
                    local closest = botLoc + segDir * proj
                    local dSeg = U.DistanceBetweenLocations(tLoc, closest)
                    local dEnd = U.DistanceBetweenLocations(tLoc, stepLoc)
                    if (dEnd <= 58 and dEnd < dStart + 4) or (dSeg <= 56 and dEnd < dStart - 4) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Finds a passable, tree-free micro-step to turn SF toward `dir` without C++ navmesh tree-avoidance detours.
function H.ComputeTreeSafeTurnStep(bot, botLoc, dir, maxDist)
    local cap = math.max(18, maxDist or 999)
    for _, stepDist in ipairs({ 48, 28, 72, 18 }) do
        if stepDist <= cap + 1 then
            local cand = botLoc + dir * stepDist
            if not H.IsStepBlockedByTerrainOrTrees(bot, botLoc, cand) then
                return cand, false
            end
        end
    end
    for _, degOff in ipairs({ -8, 8, -16, 16, -28, 28, -42, 42 }) do
        local rad = math.rad(degOff)
        local c, sn = math.cos(rad), math.sin(rad)
        local rDir = Vector(dir.x * c - dir.y * sn, dir.x * sn + dir.y * c, 0)
        for _, stepDist in ipairs({ 48, 32 }) do
            local cand = botLoc + rDir * stepDist
            if not H.IsStepBlockedByTerrainOrTrees(bot, botLoc, cand) then
                return cand, true
            end
        end
    end
    return botLoc + dir * 20, true
end

-- Home-biased & obstacle-steered step-out target for `reverseFarUntil` (`9070149539.dem` Death #1 `tk=9622..9742` Fix:
-- blends radial `away` with `toHome` toward own Mid T1 so SF retreats up the wide mid ramp toward T1 protection
-- instead of backing NW into the top-river dead-end cliff `(-192.6, 706.9)`!).
function H.ComputeSafeFarRazeStepBack(bot, enemyHero, targetDist)
    local bLoc = bot:GetLocation()
    local eLoc = enemyHero:GetLocation()
    local away = (bLoc - eLoc)
    if away:Length2D() < 1 then
        away = (P.GetFountain(bot) - bLoc)
    end
    away = away:Normalized()
    local homeAnchor = (P and P.GetT1Close and P.GetT1Close(bot)) or P.GetFountain(bot)
    local toHomeVec = homeAnchor - bLoc
    local stepDir = away
    if toHomeVec:Length2D() > 35 then
        local toHome = toHomeVec:Normalized()
        local dotHome = away.x * toHome.x + away.y * toHome.y
        if dotHome > -0.20 then
            local blended = away * 0.62 + toHome * 0.38
            if blended:Length2D() > 0.01 then
                stepDir = blended:Normalized()
            end
        end
    end
    local wantDist = targetDist or 555
    local rawTarget = eLoc + stepDir * wantDist
    if U.DistanceBetweenLocations(rawTarget, eLoc) < 520 then
        rawTarget = eLoc + away * wantDist
    end
    return U.SteerAroundObstacles(bot, rawTarget, W and W.s or nil)
end

function H.HandleGuaranteedAttackKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if not canOneShot then return false end
    local eLoc = enemyHero:GetLocation()
    local dist = GetUnitToLocationDistance(bot, eLoc)
    local enDry = (U.GetPotentialManaForRaze(enemyHero) or 0) < 75
    local myHp = bot:GetHealth() or 0
    -- `v7.9.7-pro` + `v7.9.8-pro` (`1630 @ 01:32.6..01:36.2` `3–28 HP` Escape at `156 HP` vs Unused Mango Fix!):
    -- Remove arbitrary `myHp >= 320` gate: at L1–L2 (`156 HP` vs `65` single-raze burst), surviving `burst + 65 HP`
    -- while 1 right-click kills `enemyHero` (`3–28 HP`) is 100% lethal-safe! Extend direct `Action_AttackUnit` reach to
    -- `+250u` (`~775u`) AND keep pressuring in the open river (`>= 1,060u` outside Enemy T1) even at `305 vs 305 MS`
    -- so the instant the crippled enemy stops/turns (`01:34.80`), SF executes immediately instead of orbiting at `700u`!
    local tankSafeOneShot = (myHp >= K.EnemyBurstVs(bot, enemyHero, math.min(dist, 500), 1.15, false) + 8)
    local extraOneShotReach = (enDry and myHp >= 85) and 435 or (tankSafeOneShot and 250 or 80)
    local attackRange = bot:GetAttackRange() + extraOneShotReach
    -- Hitting a hero inside his T1 radius draws the tower onto us: only with an HP margin
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    local enemyDeepUnderHisT1 = false
    local minEnemyToHisTower = 9999
    local aggroRad = (C.TOWER and C.TOWER.AGGRO_RADIUS) or 868
    for _, tw in pairs(enemyTowers or {}) do
        if tw and tw:IsAlive() then
            local dEnTw = GetUnitToLocationDistance(tw, eLoc)
            if dEnTw < minEnemyToHisTower then minEnemyToHisTower = dEnTw end
            if LN.IsBeyondTower(bot, tw, eLoc) then
                enemyDeepUnderHisT1 = true
                break
            end
            if dEnTw < (aggroRad - 525) and not H._hasTankCreepUnderTower(tw, allyCreeps) and myHp < 280 then
                enemyDeepUnderHisT1 = true
                break
            end
        end
    end
    if enemyDeepUnderHisT1 then return false end
    if underT1 then
        if H.TowerBurnActive() or myHp < bot:GetMaxHealth() * 0.40 or myHp < 300 then return false end
    end
    -- `v7.9.1` Kinematic Pursuit & Unshielded Enemy-T1 Dive Gate (`9071946472.dem` `02:39.2–02:42.9` Fix!)
    -- + `v7.9.8-pro` Open-River 1-Shot Shadow-Press (`1630 @ 01:32.8–01:35.2` `3–28 HP` in river `>= 1,060u` from Enemy T1):
    local openRiverOneShotPress = (enDry or tankSafeOneShot)
        and dist <= ((bot:GetAttackRange() or 500) + 250)
        and minEnemyToHisTower >= 1060
        and not underT1
    if not openRiverOneShotPress
        and not H.CanKinematicallyCatchForAttack(bot, enemyHero, enemyTowers, allyCreeps, 1.65) then
        return false
    end
    if dist <= attackRange then
        -- `W3a 04:00.7` (71 HP / 21 MP) & `W4 06:25.5` (15 HP / 63 MP) Fix:
        -- Issue direct `Action_AttackUnit` out to `960u` against a 1-hit OOM enemy WITHOUT routing through
        -- `ApproachEnemyPoint` -> `StackLeadStepSafe` / `ClampMinDistFromEnemy`, which aborted guaranteed kills!
        State.reverseFarUntil = 0
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        State.survivalUntil = 0
        State.survivalLoc = nil
        State.commitKillUntil = GameTime() + 2.5
        if not (U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemyHero) then
            bot:Action_AttackUnit(enemyHero, true)
            H.ClearMoveCache()
        end
        State.heroAttackTarget = enemyHero
        State.heroAttackTime = GameTime()
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        State.actionTaken = true
        return true
    end
    if dist <= attackRange + 240 then
        local botLoc = bot:GetLocation()
        local dir = (eLoc - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 25, 250)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleGuaranteedRazeKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local dNowRazeKill = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local inRangeOneShot = H.CanSafeInRangeOneShot(bot, enemyHero, enemyTowers, allyCreeps)
    local canKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)

    -- CRITICAL (`9070149539.dem` Death #1 `tk=9652..9700` & Death #2 `tk=12312` Fix!):
    -- Immediately release `reverseFarUntil` the instant `inRangeOneShot` is true (never run away from a 1-hit kill!)
    -- OR `canKill` (`CanQuickTurnKillWithRaze`) is ALREADY true at `d >= 490u` (never keep sprinting to `565-575u`
    -- while already inside lethal `Shadowraze3` at `497..559u`!).
    if inRangeOneShot or canKill or dNowRazeKill >= 535 then
        State.reverseFarUntil = 0
    end

    -- In-Range 1-Hit Right-Click Precedence (`9070149539.dem` Death #2 `tk=12312` `26 HP` @ `507.5u` & `tk=12340` `31 HP` @ `515u`):
    -- When 1 auto-attack kills `enemyHero` right now (`d <= 550u`):
    --   * If `not canKill`, yield immediately to `HandleGuaranteedAttackKill` (`0` step-back!).
    --   * If we are already winding up our lethal right-click, OR our attack CD is ready (`<= 0.12s`) while low HP/mana
    --     (`hp <= 140` or `mana < 135`), yield to `HandleGuaranteedAttackKill` (`0` mana cost, `0` tree navmesh detour!).
    if inRangeOneShot then
        if not canKill then
            return false
        end
        if U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemyHero then
            return false
        end
        local remAtkCd = math.max(0, ((bot:GetSecondsPerAttack() or 1.35) * 0.92) - (GameTime() - (bot:GetLastAttackTime() or -100)))
        if remAtkCd <= 0.12 and ((bot:GetHealth() or 0) <= 140 or (bot:GetMana() or 0) < 135) then
            return false
        end
    end

    if GameTime() < (State.reverseFarUntil or -1000) and dNowRazeKill < 535 then
        local stepBackLoc = H.ComputeSafeFarRazeStepBack(bot, enemyHero, 555)
        bot:Action_MoveToLocation(stepBackLoc)
        H.ClearMoveCache()
        State.actionTaken = true
        State.commitKillUntil = GameTime() + 2.0
        return true
    end

    if not canKill then
        -- Immortal Reverse Step-Back Far-Coil Finish (`Q -> W -> step-back E` at `200..495u`, PLUS `W6 07:59.0` 2-stack
        -- close Treads-disadvantage kite where `E` deals >= 62% of remaining enemy HP while `Q`/`W` are on CD!):
        local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
        local qAb = bot:GetAbilityByName("nevermore_shadowraze1")
        local wAb = bot:GetAbilityByName("nevermore_shadowraze2")
        local qwOnCd = (not qAb or not qAb:IsCooldownReady()) and (not wAb or not wAb:IsCooldownReady())
        local enSt, enRem = U.GetShadowrazeDebuff(enemyHero)
        local nextRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
        local enHpNow = enemyHero:GetHealth() or 9999
        local stackedStepBack = qwOnCd and (enSt or 0) >= 2 and (enRem or 0) >= 1.85
            and nextRazeDmg >= enHpNow * 0.62
            and K.AttackDamageVs(enemyHero, bot) >= K.AttackDamageVs(bot, enemyHero) - 4
        if eAb and eAb:GetLevel() > 0 and eAb:IsCooldownReady()
            and (bot:GetMana() + U.GetMangoMana(bot) + U.GetStickCharges(bot) * 15) >= 75
            and not bot:IsSilenced() and dNowRazeKill >= 200 and dNowRazeKill < 495
            and (nextRazeDmg >= enHpNow or stackedStepBack) then
            State.reverseFarUntil = GameTime() + 1.05
            local stepBackLoc = H.ComputeSafeFarRazeStepBack(bot, enemyHero, 555)
            bot:Action_MoveToLocation(stepBackLoc)
            H.ClearMoveCache()
            State.actionTaken = true
            State.commitKillUntil = GameTime() + 2.0
            return true
        end
        return false
    end
    -- Do not cancel the swing of an attack that kills him anyway
    if H.IsHeroAttackWindupLocked(bot) then
        local oneShot = U.CanOneShotEnemyHero(bot, enemyHero)
        if oneShot then return false end
    end
    -- Pop Mango / Magic Stick immediately when lethal raze needs instant burst mana (`BAR 5:09` 27 MP + Mango vs 108 HP!)
    if (bot:GetMana() or 0) < 75 then
        if H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
        return false
    end
    local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
    if ability then
        local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
        local angleDiff = U.GetAngleDifference(bot, predLoc)
        if angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST then
            bot:Action_UseAbility(ability)
            H.StartRazeCast(ability, enemyHero, predLoc, C.RAZE.HIT_RADIUS)
            H.ClearMoveCache()
            -- "Finish" commitment: for the next seconds we do not run or twitch
            State.commitKillUntil = GameTime() + 2.5
            return true
        else
            local botLoc = bot:GetLocation()
            local dir = (predLoc - botLoc):Normalized()
            local stepLoc, blockedAhead = H.ComputeTreeSafeTurnStep(bot, botLoc, dir, U.DistanceBetweenLocations(botLoc, predLoc))
            -- Engine-Exact In-Place Turn (`9070149539.dem` `tk=12322..12348` Tree-Grove & `<515u` Inner-Edge Fix!):
            -- Inside `GetAttackRange()` (`<= 525u`), `Action_AttackUnit(enemyHero, true)` rotates SF at full `0.9` turn rate
            -- (`51.6 deg/tick`, `180 deg` in `3` ticks) with ZERO `(x, y)` displacement — so SF NEVER walks into adjacent
            -- trees (no C++ navmesh `110 deg` SW detour!) and NEVER steps `< 495u` inside `Shadowraze3`'s inner deadzone!
            if dNowRazeKill <= (bot:GetAttackRange() or 525)
                and (razeLabel == "far" or blockedAhead)
                and not H.IsBotUnderEnemyT1(bot, enemyTowers) then
                bot:Action_AttackUnit(enemyHero, true)
                H.ClearMoveCache()
                State.actionTaken = true
                State.commitKillUntil = GameTime() + 2.5
                return true
            end
            if inRangeOneShot and blockedAhead then
                return false
            end
            bot:Action_MoveToLocation(stepLoc)
            H.ClearMoveCache()
            State.actionTaken = true
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    return false
end

function H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.5)
    end

    if not enemyIsHittingUs then return false end

    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local R = K._race

    -- I am weaker (level/souls/items/HP): the right-click trade is lost beforehand. Do not answer
    -- without support (my creeps/tower hitting him) - leave his attack radius toward our own
    -- creeps/tower. Chasing us while attacking, he loses distance (each attack = 0.5 s standing still)
    -- and his attack on a hero draws aggro from my creeps.
    if State.defensive and not H.HasTradeSupport(R) and not (R and R.valid and R.canKillSoon) then
        local enRange = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.KITE_PAD) or 140)
        if dist <= enRange then
            local botLoc = bot:GetLocation()
            local eLoc = enemyHero:GetLocation()
            local away = botLoc - eLoc
            if dist < 1 then away = P.GetT1Close(bot) - botLoc end
            away = away:Normalized()
            local toHome = (P.GetT1Close(bot) - botLoc):Normalized()
            local need = (enRange - dist) + 80
            local target = botLoc + (away * 0.6 + toHome * 0.4):Normalized() * need
            target = H.GetSafeApproach(bot, target, enemyTowers, allyCreeps)
            H.SmartMove(bot, target, 60)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist > bot:GetAttackRange() + 50 then return false end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < 0.25 then return false end

    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then return false end

    if not H.IssueHeroAttack(bot, enemyHero) then return false end
    State.lastHarassTime = GameTime()
    State.lastAggroTime = GameTime()
    State.aggroPullTime = GameTime() + 0.25
    return true
end


-- Raze dodging (any band), sticky tango, zoning, pushing, intents

-- Dodge: the enemy is in a raze cast phase and we are inside his circle -> leave the circle directly
-- (pathfinding movement) if we make it in time; otherwise counter-raze (trade) if his raze is not lethal.
-- `v7.9.19` (`9074666246.dem` `11/21 = 52.4%` `SELF_RAZE_CAST_LOCK` Elimination!):
-- Evaluates whether `bot` is currently locked in its own `0.55s` Shadowraze cast point while an enemy Shadowraze
-- is actively winding up ON TOP of `bot` (`dFromCenter <= R_hero + 10`), and canceling our own cast (`0` MP, `0.0s` CD!)
-- either saves us from eating the enemy coil OR avoids a losing/creep-only self-root trade.
function H.ShouldAbortOwnCastToDodgeRaze(bot, enemyHero)
    if not (bot and enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()) then return false end
    if not (K.EnemyPhase and K.EnemyRazeCenter) then return false end
    local label, _, remaining = K.EnemyPhase()
    if not label or (remaining or 0) <= 0.04 then return false end

    local R_hero = (C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274
    local center = K.EnemyRazeCenter(enemyHero, label)
    local bLoc = bot:GetLocation()
    local dFromCenter = U.DistanceBetweenLocations(bLoc, center)
    if dFromCenter > R_hero + 10 then return false end

    local myHp = bot:GetHealth() or 999
    local enHp = enemyHero:GetHealth() or 9999
    local enDmg = K.EnemyRazeDamage(bot, enemyHero, 1)
    local myStacks = (U.GetShadowrazeDebuff and select(1, U.GetShadowrazeDebuff(bot))) or 0
    local myRazeKillsHim = false
    local myRazeHitsHero = false
    if State.aimingRaze then
        local myData = U.GetRazeAbilityData(State.aimingRaze)
        local myRem = math.max(0, C.RAZE.CAST_POINT - (GameTime() - (State.aimingStartTime or GameTime())))
        if myData then
            local ePred = U.PredictPosition(enemyHero, myRem)
            if U.GetRazeHitErrorWithCurrentFacing(bot, ePred, myData.center) <= (C.RAZE.HIT_RADIUS + 12) then
                myRazeHitsHero = true
                local myOneDmg = K.MyRazeDamage(bot, enemyHero, 1)
                if myOneDmg >= enHp and (myRem <= remaining + 0.04 or myHp > enDmg + 35) then
                    myRazeKillsHim = true
                end
            end
        end
    end
    -- Never abort a guaranteed lethal finishing raze that kills the enemy before/surviving his coil!
    if myRazeKillsHim then return false end

    -- Check if physical escape is still kinematically reachable if we S-cancel right now (`sExit <= (rem - turn) * ms + 16`)
    local ms = bot:GetCurrentMovementSpeed() or 305
    local minExitNeeded = math.max(0, (R_hero + 3) - dFromCenter)
    local canStillDodge = (remaining * ms >= minExitNeeded - 14)

    -- Always S-cancel pump-fakes, pure creep-CS razes (`not myRazeHitsHero`), whiffing razes, lethal/stack-danger coils,
    -- or low-mana (`< 150 MP`) self-roots whenever we can dodge (or when lethal requires immediate movement)!
    local isPumpFake = (State.pumpFakeCancelAt ~= nil)
    local isCreepOnlyOrMiss = (State.aimingIsCS and not myRazeHitsHero) or (not myRazeHitsHero)
    local dangerousHit = (myHp <= enDmg + 225)
        or ((myStacks or 0) >= 1 and myHp <= enDmg * 2.1 + 160)
        or ((bot:GetMana() or 0) < 140 and myHp < enHp)
    if isPumpFake or isCreepOnlyOrMiss then
        return canStillDodge or (myHp <= enDmg + 180)
    end
    if dangerousHit and (canStillDodge or myHp <= enDmg + 65) then
        return true
    end
    return false
end

function H.HandleEnemyRazeDodge(bot, enemyHero)
    local now = GameTime()
    local R_hero = (C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274
    -- Enemy `nevermore_requiem` `1.67s` self-root cast reaction (`v7.9.7-pro`: `0307 @ 10:03.5` `act=1515` Fix!):
    --   A) If a ready Shadowraze (`mana >= 75`) 1-shot KILLS the rooted enemy BEFORE `reqRem` finishes (`cancelling Requiem
    --      with 0 damage & 0 Fear!`), either fire immediately in place OR step straight into safe band range (`615u` for `W`)!
    --   B) Else if `reqRem >= 0.70s` and `dReq >= 680u`, fire any centered long-range `E`/`W` coil that hits right now!
    --   C) Otherwise (`non-lethal Requiem`), sprint outward to `965u` (`NOT 585u`, where `700u` lines still hit & Fear into free `E`!)!
    if enemyHero and U.CanQuery(enemyHero) and K.EnemyRequiemPhase then
        local reqInPhase, _, reqRem = K.EnemyRequiemPhase()
        if reqInPhase and reqRem > 0.12 then
            local bLocReq = bot:GetLocation()
            local eLocReq = enemyHero:GetLocation()
            local dReq = U.DistanceBetweenLocations(bLocReq, eLocReq)
            local fntReq = P.GetFountain(bot)
            local outDir = (dReq > 5) and (bLocReq - eLocReq):Normalized() or (fntReq - eLocReq):Normalized()
            local enHpReq = enemyHero:GetHealth() or 9999
            local oneRazeReq = K.MyRazeDamage(bot, enemyHero, 1)
            local canOneRazeKillReq = ((bot:GetMana() or 0) >= 75) and (not bot:IsSilenced()) and (enHpReq <= oneRazeReq)

            -- Keep an already-valid in-flight lethal raze finishing before Requiem lands!
            if bot:IsUsingAbility() and State.aimingRaze and canOneRazeKillReq and reqRem >= 0.18 then
                return false
            end

            if (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() and not bot:IsUsingAbility() then
                -- A1 / B: Fire immediately if a ready raze hits the rooted enemy right now and finishes before Requiem!
                if (canOneRazeKillReq and reqRem >= C.RAZE.CAST_POINT + 0.04)
                    or (dReq >= 680 and reqRem >= C.RAZE.CAST_POINT + 0.14) then
                    for _, rLabel in ipairs(H.BestCenteredRazeOrder(bot, enemyHero)) do
                        local rAb = H.GetRazeAbilityByLabel(bot, rLabel)
                        if rAb and U.IsRazeAbilityCastable(bot, rAb) then
                            local actT, aimL = H.GetRazeActionType(bot, rAb, enemyHero)
                            if actT and H.CastOrTurnRaze(bot, rAb, actT, aimL, enemyHero) then
                                return true
                            end
                        end
                    end
                end
                -- A2: Step inward to execute `210 HP` frozen Requiem caster (`0307 @ 10:03.6`: `dReq=764u -> 615u` for `W`!)
                if canOneRazeKillReq then
                    local myMSReq = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 305)
                    local bandTargets = {
                        { label = "far",  holdDist = 855, maxHitDist = 900 },
                        { label = "mid",  holdDist = 610, maxHitDist = 660 },
                        { label = "near", holdDist = 345, maxHitDist = 400 },
                    }
                    for _, bt in ipairs(bandTargets) do
                        local rAb = H.GetRazeAbilityByLabel(bot, bt.label)
                        if rAb and U.IsRazeAbilityCastable(bot, rAb) and dReq > bt.maxHitDist then
                            local tWalk = (dReq - bt.maxHitDist + 25) / myMSReq
                            if tWalk + C.RAZE.CAST_POINT + 0.10 <= reqRem then
                                local stepIn = eLocReq + outDir * bt.holdDist
                                local safeTower = true
                                local enT1Req = W and W.s and W.s.enemyT1
                                if enT1Req and U.CanQuery(enT1Req) and enT1Req:IsAlive()
                                    and U.DistanceBetweenLocations(stepIn, enT1Req:GetLocation()) < 880
                                    and (bot:GetHealth() or 0) < 380 then
                                    safeTower = false
                                end
                                if safeTower then
                                    if bot.Action_MoveDirectly then bot:Action_MoveDirectly(stepIn) else bot:Action_MoveToLocation(stepIn) end
                                    State.lastMoveLoc = stepIn
                                    State.lastMoveTime = now
                                    State.actionTaken = true
                                    return true
                                end
                            end
                        end
                    end
                end
            end

            -- C: Non-lethal Requiem -> escape outward to `965u` (`strictly outside dangerous multi-line + Fear zone!`)
            if dReq < 925 then
                if bot:IsUsingAbility() and (dReq <= 760 or reqRem <= 0.62) then
                    bot:Action_ClearActions(true)
                    H.ClearRazeState()
                end
                local toFntDir = (fntReq - eLocReq):Normalized()
                local safeOutDir = (outDir + toFntDir * 0.35):Normalized()
                local escReq = eLocReq + safeOutDir * 965
                if bot.Action_MoveDirectly then bot:Action_MoveDirectly(escReq) else bot:Action_MoveToLocation(escReq) end
                State.lastMoveLoc = escReq
                State.lastMoveTime = now
                State.actionTaken = true
                return true
            end
        end
    end

    local label, elapsed, remaining = K.EnemyPhase()
    if State.dodgeLoc and now < State.dodgeUntil then
        -- While dodging we keep watching his cast: he may CANCEL the raze
        -- (we left the circle) and immediately cast another band - previously we blindly ran for 0.6 s toward
        -- the old point and took a new raze at point blank ("dodges slowly").
        local E = K._enemy
        local newCast = label and (label ~= State.dodgeLabel
            or math.abs((E.phaseStart or -1) - (State.dodgePhaseStart or -2)) > 0.01)
        local cancelled = (not label) and (now - (State.dodgePhaseStart or -10)) < (C.RAZE.CAST_POINT - 0.05)
        if newCast then
            State.dodgeLoc = nil -- Re-evaluated below
        elseif cancelled then
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        elseif label and enemyHero and U.CanQuery(enemyHero) then
            local liveCenter = K.EnemyRazeCenter(enemyHero, label)
            local bLocNow = bot:GetLocation()
            local dNowLive = U.DistanceBetweenLocations(bLocNow, liveCenter)
            local centerDrifted = State.dodgeCenterAtLock
                and (U.DistanceBetweenLocations(liveCenter, State.dodgeCenterAtLock) >= 24)
            local dodgeLocUnsafe = U.DistanceBetweenLocations(State.dodgeLoc, liveCenter) < (R_hero + 10)
            local stalledOnRay = false
            if State.dodgeStallAt and State.dodgeStallLoc and (now - State.dodgeStallAt) >= 0.095 then
                if U.DistanceBetweenLocations(bLocNow, State.dodgeStallLoc) < 13.0 and dNowLive <= R_hero + 8 then
                    stalledOnRay = true
                    State.dodgeBlockedAng = math.atan2(State.dodgeLoc.y - bLocNow.y, State.dodgeLoc.x - bLocNow.x)
                    State.dodgeBlockedPhase = E.phaseStart
                end
                State.dodgeStallAt = now
                State.dodgeStallLoc = bLocNow
            elseif not State.dodgeStallAt then
                State.dodgeStallAt = now
                State.dodgeStallLoc = bLocNow
            end
            if dNowLive > R_hero + 68 then
                State.dodgeLoc = nil
                State.dodgeUntil = 0
                return false
            elseif centerDrifted or dodgeLocUnsafe or stalledOnRay then
                -- `v7.9.20` (`1610.dem` `#07/#11` Critical Fix): NEVER `return false` when `dodgeLoc` falls inside `liveCenter`
                -- or stalls against river cliff/creeps — clear `State.dodgeLoc` and FALL THROUGH in the SAME tick to re-solve!
                State.dodgeLoc = nil
            else
                local safeSticky = U.EnsurePassable(bot, State.dodgeLoc)
                local useNavMesh = (State.dodgeBlockedPhase ~= nil and math.abs((E.phaseStart or -1) - State.dodgeBlockedPhase) < 0.02)
                if bot.Action_MoveDirectly and not useNavMesh then
                    bot:Action_MoveDirectly(safeSticky)
                else
                    bot:Action_MoveToLocation(safeSticky)
                end
                State.lastMoveLoc = safeSticky
                State.lastMoveTime = now
                State.actionTaken = true
                return true
            end
        else
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        end
    end
    State.dodgeLoc = nil
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not label then return false end
    local center = K.EnemyRazeCenter(enemyHero, label)
    local botLoc = bot:GetLocation()
    local dFromCenter = U.DistanceBetweenLocations(botLoc, center)
    local R = R_hero -- CRITICAL P0 FIX: `274u` (`250 + 24` hero hull), NEVER `250u` (`rSafe = 256 < 274` was inside hit circle!)
    if dFromCenter > R + 75 then return false end

    local dmg = K.EnemyRazeDamage(bot, enemyHero, 1)
    local myHp = bot:GetHealth()
    local lethal = (dmg >= myHp - 25) or (myHp <= 260)
    local ms = bot:GetCurrentMovementSpeed() or 305
    local selfCasting = bot:IsUsingAbility() or bot:IsChanneling() or (State.aimingRaze ~= nil)

    -- `03:00.47` (`tk=8848` `8 HP` Enemy Escape) + `v7.9.20` (`1610.dem` `#14` `05:27.47` `231 dmg` 0-Raze Stacked Tank Fix):
    local eLoc = enemyHero:GetLocation()
    local curEnemyDist = U.DistanceBetweenLocations(botLoc, eLoc)
    local enHpNow = enemyHero:GetHealth() or 9999
    local R_race0 = K._race
    local myReadyRazeDmg = (K.MyReadyRazeCount(bot, false) > 0) and K.MyRazeDamage(bot, enemyHero, 1) or 0
    local myAtkVsEn = K.AttackDamageVs(bot, enemyHero)
    local stackedZeroRazeDanger = (myReadyRazeDmg == 0)
        and (enHpNow > myAtkVsEn * 1.90)
        and (((U.GetShadowrazeDebuff(bot) or 0) >= 1) or dmg >= 170)
    local closingForKill = (not lethal)
        and (not stackedZeroRazeDanger)
        and (myHp > dmg + 185)
        and not (R_race0 and R_race0.valid and (R_race0.heCanKillNow or R_race0.heCanKillSoon))
        and ((enHpNow <= 185 and (myReadyRazeDmg > 0 or enHpNow <= myAtkVsEn * 1.90))
            or enHpNow <= myAtkVsEn * 2.2 + myReadyRazeDmg)
    if closingForKill and label == "near" then
        return false
    end

    local fnt = P.GetFountain(bot)
    local homeDir = (fnt - botLoc):Normalized()
    local px, py = botLoc.x - center.x, botLoc.y - center.y
    local p2 = px * px + py * py
    local pNorm = math.sqrt(math.max(1e-6, p2))
    local radOutFromCenter = (dFromCenter > 1.0) and Vector(px / pNorm, py / pNorm, 0) or homeDir

    -- `v7.9.11-pro` (`2213 @ 06:44..06:52` Anti-Inward-Lasso & Anti-`Q(200)` Dodge Law!):
    -- On the inner hemisphere (`curEnemyDist < nominalCenterDist`), `radOutFromCenter` points STRAIGHT TOWARD `eLoc`!
    -- Human SFs exploit this by casting/pump-faking `E(700)` -> `S` -> `W(450)` -> `S` to lasso the bot inward into `Q(200)`
    -- (`719 -> 594 -> 387 -> 248 -> 186u`) or reverse an active retreat (`353 -> 297u`, `533 -> 461u`).
    -- Hard geometric law: when `not closingForKill` and `label ~= "near"`, NEVER dodge inward into armed `Q(200)` (`< 485u`)
    -- and NEVER step closer to `eLoc` (`postEnemyDist < curEnemyDist - 15`) while retreating or disadvantaged!
    local enPotMp = K.EnemyManaBudget(enemyHero, true)
    local myPotMp = K.MyManaBudget(bot, true)
    local enQReady = (label ~= "near") and K.EnemyRazeReady("near", 1.65) and (enPotMp >= 75)
    local enWReady = (label == "far") and K.EnemyRazeReady("mid", 1.65) and (enPotMp >= 75)
    local activelyRetreating = (State.forcedRetreatLoc ~= nil)
        or (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0))
        or (now < (State.critDangerHystUntil or 0))
        or (State.goingToFountain == true)
    local disadvantagedNow = activelyRetreating
        or lethal
        or ((myHp / math.max(1, bot:GetMaxHealth() or 1)) < 0.55)
        or H.IsDryVsEnemyRaze(bot, enemyHero)
        or (myPotMp < 75 and enPotMp >= 75)
        or ((myPotMp + 75 <= enPotMp) and myHp <= enHpNow + 90)
        or (#(W.s and W.s.enemyCreeps or {}) >= #(W.s and W.s.allyCreeps or {}) + 2 and myHp < enHpNow + 140)
    local forbidInwardStep = (not closingForKill) and (label ~= "near") and (disadvantagedNow or enQReady or enWReady)
    local sightLen0 = math.max(1.0, U.DistanceBetweenLocations(eLoc, center))
    local sdx0, sdy0 = (center.x - eLoc.x) / sightLen0, (center.y - eLoc.y) / sightLen0

    -- `v7.9.10-pro` (`2048` `#55 @ 07:19.00` `dFromCenter = 277u -> 235u` Walk-Into-Live-Coil Fix!)
    -- + `v7.9.11` Inner-Rim Anti-Lasso Guard:
    -- When ALREADY outside `R - 1` (`273..349u`) and not `closingForKill`, NEVER reject on `turnTime` or let lower
    -- CS/lane handlers walk INWARD into the detonating circle! Step radially away from `center` to `>= R + 46` (`320u`),
    -- EXCEPT on the inner rim where stepping along `radOutFromCenter` would walk straight into `eLoc` / `Q(200)`!
    if dFromCenter >= R - 1 then
        if closingForKill then return false end
        if selfCasting and not lethal then return false end
        local rawRimPt = center + radOutFromCenter * math.max(dFromCenter + 45, R + 46)
        if forbidInwardStep and U.DistanceBetweenLocations(rawRimPt, eLoc) < math.min(curEnemyDist - 10, 490) then
            local perpA = Vector(-sdy0, sdx0, 0)
            local perpB = Vector(sdy0, -sdx0, 0)
            local bestRim, bestRimSc = nil, -1e9
            for _, pDir in ipairs({ perpA, perpB }) do
                local candRim = botLoc + pDir * 205 + Vector(sdx0, sdy0, 0) * 50
                if U.IsRayPassable(botLoc, candRim)
                    and not (W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(candRim, W.s.enemyT1Loc) < 880) then
                    local scRim = U.DistanceBetweenLocations(candRim, center) * 1.35
                        + (pDir.x * homeDir.x + pDir.y * homeDir.y) * 55.0
                    if scRim > bestRimSc then
                        bestRimSc, bestRim = scRim, candRim
                    end
                end
            end
            if bestRim then rawRimPt = bestRim end
        end
        local holdSafePt = U.EnsurePassable(bot, rawRimPt)
        State.dodgeLoc = holdSafePt
        State.dodgeUntil = now + math.max(0.08, math.min(0.32, (remaining or 0.18) + 0.05))
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        State.dodgeCenterAtLock = center
        if bot.Action_MoveDirectly then
            bot:Action_MoveDirectly(holdSafePt)
        else
            bot:Action_MoveToLocation(holdSafePt)
        end
        State.lastMoveLoc = holdSafePt
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end

    -- `v7.9.19` Two-Tier 32-Ray + Sightline-Perpendicular + Radial Analytic Exit Solver
    -- (`9074666246.dem` vs `v7.9.4` Forensic Synthesis — Fixes `#05, #11, #17, #19, #24, #36`!):
    --   * Pass 1 (`strictInward = true`): searches `32` rays (`11.25 deg` resolution) + exact radial normal (`k = -1`)
    --     + exact `±90 deg` sightline perpendiculars (`k = -2, -3`) for a guaranteed exit that ALSO preserves anti-`Q(200)` spacing.
    --   * Pass 2 (`strictInward = false` — Guaranteed-Dodge Rescue, restoring `v7.9.4`'s inner-hemisphere dodge!):
    --     If Pass 1 found NO exit ray (`bestEscapeLoc == nil`), NEVER eat a 100%-dodgeable `184..278 dmg` Shadowraze
    --     (`like #17 @ 05:43.20 dc=124.5u mv=162.6u` or `#05 @ 00:36.13 dc=166.4u mv=131.9u`) just to avoid stepping inward!
    --     Re-evaluates inner/diagonal-inner exit rays (blocking only unshielded Enemy T1 `< 865u` and scoring `>= 480u` chords higher).
    local bestEscapeLoc, bestScore = nil, -1e9

    local function FindAnalyticCircleExit(strictInward)
        local foundLoc, foundScore = nil, -1e9
        for _, pad in ipairs(lethal and { 18, 6, 2 } or { 20, 8, 2 }) do
            local rSafe = R + pad
            local r2Diff = rSafe * rSafe - p2
            for k = -3, 31 do
                local ux, uy
                if k == -1 then
                    ux, uy = px / pNorm, py / pNorm
                elseif k == -2 then
                    ux, uy = -sdy0, sdx0
                elseif k == -3 then
                    ux, uy = sdy0, -sdx0
                else
                    local ang = k * (2 * math.pi / 32)
                    ux, uy = math.cos(ang), math.sin(ang)
                end
                local pDotU = px * ux + py * uy
                local sExit = -pDotU + math.sqrt(math.max(0, pDotU * pDotU + r2Diff))
                local cand = Vector(botLoc.x + ux * (sExit + 22), botLoc.y + uy * (sExit + 22), botLoc.z)
                local t1SafetyR = strictInward and 760 or ((myHp < 360) and 735 or 620)
                local safeEnT1 = not (W.s and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc
                    and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < t1SafetyR
                    and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < U.DistanceBetweenLocations(botLoc, W.s.enemyT1Loc) - 10)
                if safeEnT1 and U.IsRayPassable(botLoc, cand) then
                    local turnAng = U.GetAngleDifference(bot, cand)
                    -- Source 2 heroes begin forward translation once within ~70 deg of target facing:
                    local turnTime = 0.03 * math.max(0, math.rad(turnAng - 70.0)) / 0.9
                    if (remaining - turnTime - 0.010) * ms >= sExit then
                        local postEnemyDist = U.DistanceBetweenLocations(cand, eLoc)
                        local violatesInwardLaw = false
                        if strictInward and not closingForKill and label ~= "near" then
                            if enQReady and curEnemyDist >= 430 and postEnemyDist < math.min(curEnemyDist - 12, 485) then
                                violatesInwardLaw = true
                            elseif disadvantagedNow and postEnemyDist < curEnemyDist - 15 then
                                violatesInwardLaw = true
                            elseif enWReady and curEnemyDist >= 640 and disadvantagedNow and postEnemyDist < 515 then
                                violatesInwardLaw = true
                            end
                        end
                        if (not violatesInwardLaw) and (not closingForKill or postEnemyDist < curEnemyDist - 35) then
                            local homeAlign = ux * homeDir.x + uy * homeDir.y
                            local nextBandAdj = 0
                            if not closingForKill then
                                if label ~= "near" and K.EnemyRazeReady("near", 0.9) and postEnemyDist < 478 then
                                    nextBandAdj = nextBandAdj - (strictInward and 380 or 260)
                                end
                                if label ~= "far" and K.EnemyRazeReady("far", 1.1) and math.abs(postEnemyDist - 700) <= 125 then
                                    nextBandAdj = nextBandAdj - 135
                                end
                                if curEnemyDist > 20 then
                                    local latFromRay = math.abs((cand.x - eLoc.x) * (-sdy0) + (cand.y - eLoc.y) * sdx0)
                                    nextBandAdj = nextBandAdj + math.min(195, latFromRay * 0.75)
                                end
                            end
                            -- `v7.9.20` (`1610.dem` `#11` @ `04:19.67` River-Cliff / Creep-Hull Pin Fix):
                            -- Penalize rays blocked within `155u` by live creep hulls (`24 + 16 = 40u`) or matching a stalled sector!
                            local obsPen = 0
                            if State.dodgeBlockedPhase ~= nil and math.abs((K._enemy.phaseStart or -1) - State.dodgeBlockedPhase) < 0.02
                                and State.dodgeBlockedAng ~= nil then
                                local dAng = math.abs(((math.atan2(uy, ux) - State.dodgeBlockedAng + math.pi * 3) % (math.pi * 2)) - math.pi)
                                if dAng < 0.78 then obsPen = obsPen + 420 end
                            end
                            if W.s then
                                local segMax = math.min(155.0, sExit + 15.0)
                                for _, clist in ipairs({ W.s.enemyCreeps or {}, W.s.allyCreeps or {} }) do
                                    for _, cr in pairs(clist) do
                                        if cr and U.CanQuery(cr) and cr:IsAlive() then
                                            local cl = cr:GetLocation()
                                            local rcx, rcy = cl.x - botLoc.x, cl.y - botLoc.y
                                            local projC = rcx * ux + rcy * uy
                                            if projC > 12.0 and projC < segMax then
                                                local perpC = math.abs(rcx * (-uy) + rcy * ux)
                                                if perpC < 43.0 then
                                                    obsPen = obsPen + (43.0 - perpC) * 4.5
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            local score = closingForKill
                                and (-postEnemyDist - sExit * 0.35 - obsPen)
                                or (postEnemyDist * (strictInward and 1.0 or 0.65) + homeAlign * 135 - sExit * 0.45 + nextBandAdj - obsPen)
                            if score > foundScore then
                                foundScore = score
                                foundLoc = cand
                            end
                        end
                    end
                end
            end
            if foundLoc then break end
        end
        return foundLoc, foundScore
    end

    bestEscapeLoc, bestScore = FindAnalyticCircleExit(true)
    if not bestEscapeLoc and not closingForKill then
        bestEscapeLoc, bestScore = FindAnalyticCircleExit(false)
    end

    if closingForKill and not bestEscapeLoc then
        return false
    end

    -- `v7.9.12-pro` + `v7.9.19` Near-Threshold Radial/Perpendicular Sprint Fallback (`dFromCenter >= 55u`, within `<= 44u` of exit):
    if (not bestEscapeLoc) and (not closingForKill)
        and dFromCenter >= 55 and (R - dFromCenter) <= ((remaining or 0.35) * ms + 44) then
        local bestRadDir, bestRadDist = nil, -1e9
        local stepSpan = math.max(195, (remaining or 0.35) * ms + 60)
        for k = -3, 31 do
            local ux, uy
            if k == -1 then
                ux, uy = radOutFromCenter.x, radOutFromCenter.y
            elseif k == -2 then
                ux, uy = -sdy0, sdx0
            elseif k == -3 then
                ux, uy = sdy0, -sdx0
            else
                local ang = k * (2 * math.pi / 32)
                ux, uy = math.cos(ang), math.sin(ang)
            end
            local cand = Vector(botLoc.x + ux * stepSpan, botLoc.y + uy * stepSpan, botLoc.z)
            local safeEnT1 = not (W.s and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc
                and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < 745
                and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < U.DistanceBetweenLocations(botLoc, W.s.enemyT1Loc) - 10)
            if safeEnT1 and U.IsRayPassable(botLoc, cand) then
                local turnAng = U.GetAngleDifference(bot, cand)
                local turnPenalty = math.max(0, turnAng - 70.0) * 0.55
                local latGain = math.abs((cand.x - eLoc.x) * (-sdy0) + (cand.y - eLoc.y) * sdx0)
                local dOut = U.DistanceBetweenLocations(cand, center)
                    + math.min(90, latGain * 0.25)
                    + (ux * homeDir.x + uy * homeDir.y) * 22
                    - turnPenalty
                if dOut > bestRadDist then
                    bestRadDist, bestRadDir = dOut, cand
                end
            end
        end
        bestEscapeLoc = bestRadDir
    end

    if bestEscapeLoc and (not selfCasting or lethal or H.ShouldAbortOwnCastToDodgeRaze(bot, enemyHero)) then
        if selfCasting then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
        end
        bestEscapeLoc = U.EnsurePassable(bot, bestEscapeLoc)
        State.dodgeLoc = bestEscapeLoc
        State.dodgeUntil = now + remaining + 0.06
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        State.dodgeCenterAtLock = center
        State.dodgeStallAt = now
        State.dodgeStallLoc = botLoc
        local useNavStall = (State.dodgeBlockedPhase ~= nil and math.abs((K._enemy.phaseStart or -1) - State.dodgeBlockedPhase) < 0.02)
        if bot.Action_MoveDirectly and not useNavStall then
            bot:Action_MoveDirectly(bestEscapeLoc)
        else
            bot:Action_MoveToLocation(bestEscapeLoc)
        end
        State.lastMoveLoc = bestEscapeLoc
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end

    -- `v4.0.0` + `v7.9.19` Anti-Edge-Poke Synchronous Mirror Coil (`#01` & `#13` `@ 81 MP` Self-Root Trap Fix!):
    -- ONLY stand and trade a mirror coil when mathematically un-dodgeable AND we hold `>= 150` real mana (`>= 2` coils so we
    -- NEVER end at `6 MP` with a stack on us!) AND `curMyStacks == 0`!
    local R_race = K._race
    local dHeroCast = U.DistanceBetweenLocations(botLoc, eLoc)
    local curMyStacks = U.GetShadowrazeDebuff(bot) or 0
    local outMatchedChase = ((enemyHero:GetLevel() or 1) > (bot:GetLevel() or 1))
        or (R_race and R_race.valid and (R_race.heCanKillSoon or R_race.heHasBootsLead))
    local safeFarMirror = (label == "far" and dHeroCast >= 660 and curMyStacks == 0
        and (bot:GetMana() or 0) >= 150 and not outMatchedChase and myHp > dmg + 165)
    local unsafeCloseTrade = ((myHp / math.max(1, bot:GetMaxHealth() or 1)) < 0.62)
        or (curMyStacks >= 1)
        or ((bot:GetMana() or 0) < 150)
        or outMatchedChase
        or disadvantagedNow
        or (R_race and R_race.valid and R_race.losingHard)
    local unsafeToStandAndTrade = (State.forcedRetreatLoc ~= nil)
        or (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0))
        or (not safeFarMirror and unsafeCloseTrade)
        or (R_race and R_race.valid and R_race.heCanKillNow)
    if not selfCasting and not lethal and not unsafeToStandAndTrade and (bot:GetMana() or 0) >= 150 then
        for _, lbl in ipairs(H.BestCenteredRazeOrder(bot, enemyHero)) do
            local ab = H.GetRazeAbilityByLabel(bot, lbl)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
                if actionType == "CAST" and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                    return true
                end
            end
        end
    end

    -- `v7.9.19` Sightline-Perpendicular Bullseye Break (`#19 @ 05:48.53` `dc=25.4u` Straight-East Run Fix!):
    -- When caught deep inside the bullseye (`dc0 < 95u`) where `0.55s` cannot clear `274u`, NEVER run straight along
    -- `(sdx0, sdy0)` down the enemy SF's triple-raze line! Sprint ~75-90 deg PERPENDICULAR to `(sdx0, sdy0)` (blended
    -- slightly toward `homeDir`) so the next coil (`W`/`E`/`Q`) is immediately off-axis by `180+u`!
    if not selfCasting then
        local function PickBullseyeEscapeRay(minOutGain, allowSlightInward)
            local bPt, bSc = nil, -1e9
            for i = 0, 31 do
                local a = i * (2.0 * math.pi / 32.0)
                local dir = Vector(math.cos(a), math.sin(a), 0)
                local cand = botLoc + dir * 305
                local safeFromEnT1 = not (W.s and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc
                    and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < 745
                    and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < U.DistanceBetweenLocations(botLoc, W.s.enemyT1Loc) - 10)
                local outGain = U.DistanceBetweenLocations(cand, center) - dFromCenter
                local postEnDist = U.DistanceBetweenLocations(cand, eLoc)
                local inwardBlocked = false
                if not allowSlightInward and not closingForKill and label ~= "near" then
                    if enQReady and curEnemyDist >= 420 and postEnDist < math.min(curEnemyDist - 10, 480) then
                        inwardBlocked = true
                    elseif disadvantagedNow and postEnDist < curEnemyDist - 25 then
                        inwardBlocked = true
                    end
                end
                if outGain >= minOutGain and not inwardBlocked and safeFromEnT1 and U.IsRayPassable(botLoc, cand) then
                    local latFromSight = math.abs((cand.x - eLoc.x) * (-sdy0) + (cand.y - eLoc.y) * sdx0)
                    local homeGain = dir.x * homeDir.x + dir.y * homeDir.y
                    local enDistGain = postEnDist - curEnemyDist
                    local turnAngB = U.GetAngleDifference(bot, cand)
                    local sc = outGain * 1.25 + math.min(250.0, latFromSight) * 1.65 + homeGain * 55.0
                        + enDistGain * 0.30 - math.max(0, turnAngB - 70.0) * 0.45
                    if sc > bSc then
                        bSc = sc
                        bPt = cand
                    end
                end
            end
            return bPt
        end
        local bestBullPt = PickBullseyeEscapeRay(135.0, false)
            or PickBullseyeEscapeRay(85.0, false)
            or PickBullseyeEscapeRay(95.0, true)
            or PickBullseyeEscapeRay(35.0, true)
        local fallbackOut = botLoc + radOutFromCenter * 305
        if forbidInwardStep and U.DistanceBetweenLocations(fallbackOut, eLoc) < curEnemyDist - 15 then
            local perp1 = Vector(-sdy0, sdx0, 0)
            local perp2 = Vector(sdy0, -sdx0, 0)
            local bestPerp = ((perp1.x * homeDir.x + perp1.y * homeDir.y) >= (perp2.x * homeDir.x + perp2.y * homeDir.y)) and perp1 or perp2
            fallbackOut = botLoc + (bestPerp * 0.88 + homeDir * 0.35):Normalized() * 305
        end
        local stepOut = U.EnsurePassable(bot, bestBullPt or fallbackOut)
        State.dodgeLoc = stepOut
        State.dodgeUntil = now + math.min(0.28, (remaining or 0.25) + 0.04)
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        State.dodgeCenterAtLock = center
        State.dodgeStallAt = now
        State.dodgeStallLoc = botLoc
        local useNavBull = (State.dodgeBlockedPhase ~= nil and math.abs((K._enemy.phaseStart or -1) - State.dodgeBlockedPhase) < 0.02)
        if bot.Action_MoveDirectly and not useNavBull then
            bot:Action_MoveDirectly(stepOut)
        else
            bot:Action_MoveToLocation(stepOut)
        end
        State.lastMoveLoc = stepOut
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end
    return false
end

-- Sticky tango tree: pick once and keep it (COMMIT_TIME) until eaten / it became
-- dangerous / we got stuck. Filters: far from the enemy tower, not closer to the enemy, same height level.
function H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
    -- Defensive C++ `HSCRIPT` userdata guard: NEVER allow `pairs(userdata)` if arguments were reversed!
    if type(enemyHero) == "table" and type(enemyHero.GetLocation) ~= "function" then
        enemyHero, enemyTowers = enemyTowers, enemyHero
    end
    local safeTowerList = (type(enemyTowers) == "table") and enemyTowers or {}
    local now = GameTime()
    local cfg = C.TANGO or {}
    local botLoc = bot:GetLocation()
    local enemyLoc = (enemyHero and U.CanQuery(enemyHero)) and enemyHero:GetLocation() or nil

    if State.tangoTree and State.tangoTreeLoc then
        local age = now - State.tangoChosenAt
        local d = U.DistanceBetweenLocations(botLoc, State.tangoTreeLoc)
        if d < State.tangoBestDist - 15 then
            State.tangoBestDist = d
            State.tangoProgressAt = now
        end
        local stuck = d > 165 and (now - (State.tangoProgressAt or State.tangoChosenAt)) > (cfg.STUCK_TIME or 4.0)
        local unsafe = enemyLoc and U.DistanceBetweenLocations(State.tangoTreeLoc, enemyLoc) < ((cfg.ENEMY_MIN_DIST or 650) - 150)
        if age <= (cfg.COMMIT_TIME or 8.0) and not stuck and not unsafe then
            return State.tangoTree, State.tangoTreeLoc
        end
        if stuck then
            State.tangoBadTree = State.tangoTree
            State.tangoBadTreeTime = now
        end
        State.tangoTree = nil
        State.tangoTreeLoc = nil
    end

    local trees = bot:GetNearbyTrees(math.max(cfg.SEARCH_RADIUS or 1400, 1600))
    if not trees or #trees == 0 then return nil, nil end
    local myH = nil
    if type(GetHeightLevel) == "function" then myH = GetHeightLevel(botLoc) end
    local fountain = P.GetFountain(bot)
    local allyT1Loc = (W.s and W.s.allyT1Loc) or P.GetT1Close(bot)
    local t1FntDist = allyT1Loc and U.DistanceBetweenLocations(allyT1Loc, fountain) or 6800

    local best, bestLoc, bestScore = nil, nil, math.huge
    for pass = 1, 2 do
        for _, tree in ipairs(trees) do
            local bad = (State.tangoBadTree == tree) and (now - State.tangoBadTreeTime) < 20
            if not bad then
                local loc = GetTreeLocation(tree)
                local ok = true
                -- Strict Own-Side Tango Invariant (`v3.9.0` + `v7.9.1` `9071946472.dem` Early Tango Fix):
                -- NEVER choose a tree across the river or in enemy territory, while allowing all safe trees behind/around `allyT1`!
                local locFntDist = U.DistanceBetweenLocations(loc, fountain)
                local distAllyT1 = allyT1Loc and U.DistanceBetweenLocations(loc, allyT1Loc) or 0
                if locFntDist > t1FntDist + 560 then ok = false end
                if ok and allyT1Loc and distAllyT1 > 1250 then ok = false end
                if ok then
                    for _, tower in pairs(safeTowerList) do
                        if tower:IsAlive() and GetUnitToLocationDistance(tower, loc) < (cfg.TOWER_MIN_DIST or 1125) then
                            ok = false
                            break
                        end
                    end
                end
                local minEnTreeDist = (allyT1Loc and distAllyT1 <= 720 and locFntDist <= t1FntDist + 160)
                    and 520 or (cfg.ENEMY_MIN_DIST or 650)
                if ok and enemyLoc and U.DistanceBetweenLocations(loc, enemyLoc) < minEnTreeDist then ok = false end
                if ok and pass == 1 and myH and GetHeightLevel(loc) ~= myH then ok = false end
                if ok then
                    local score = U.DistanceBetweenLocations(botLoc, loc)
                    score = score + locFntDist * 0.14
                    if score < bestScore then
                        bestScore, best, bestLoc = score, tree, loc
                    end
                end
            end
        end
        if best then break end
    end
    if best then
        State.tangoTree = best
        State.tangoTreeLoc = bestLoc
        State.tangoChosenAt = now
        State.tangoBestDist = math.huge
        State.tangoProgressAt = now
    end
    return best, bestLoc
end

function H.ClearTangoState()
    State.tangoTree = nil
    State.tangoTreeLoc = nil
    State.tangoBadTree = nil
    State.tangoBadTreeTime = 0
    State.stickyTangoTree = nil
    State.lastTriedTreeId = nil
    State.lastTriedTreeAt = nil
    State.tangoCastAt = 0
end

-- Context + the intent FSM. Returns the intent.
-- "Hunt" (complaint: +400 HP against a low-HP enemy and the bot farms). Go for the kill when:
-- raze >= 2 points, absolute HP edge >= HUNT_HP_EDGE, my HP >= HUNT_MIN_HP_PCT, he is not under
-- his T1, his burst on me from mid range is not dangerous (HUNT_SAFETY_HP margin), my burst over
-- HUNT_HORIZON with an approach into the mid band (razes that come off cooldown; mana WITH mango;
-- 1-2 right clicks) covers his HP, and he is catchable. Hysteresis: while hunting the thresholds are softer.
function H.ComputeHunt(bot, s, race, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not race or not race.valid then return false end
    -- He is TPing back to his T1 (fresh, full) - do not fly in
    if (State.enemyTPIncomingUntil or 0) > s.now then return false end
    local cfg = C.INTENT or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local razeLvl = (q and q:GetLevel()) or 0
    local earlyLowFinish = (razeLvl >= 1) and (race.enHp <= 310) and (K.EnemyManaBudget(enemyHero, true) < 150)
    if razeLvl < 2 and not earlyLowFinish then return false end
    local was = State.hunting and true or false
    local dmg, n = K.MyHuntBurst(bot, enemyHero, cfg.HUNT_HORIZON or 4.0)
    if dmg < race.enHp + (was and -20 or 10) then return false end
    local hisReady = K.EnemyReadyRazeCount(enemyHero, 1.5, true)
    local hisN = math.min(math.max(n, 1), hisReady)
    local enBurst = K.EnemyRazeDamage(bot, enemyHero, hisN)
    local myHp = race.myHp
    local cleanOverkill = (dmg >= race.enHp + 30) and ((myHp - enBurst) >= 150)
    local edgeNeed = cleanOverkill
        and (90 - (was and 45 or 0))
        or ((cfg.HUNT_HP_EDGE or 250) - (was and 60 or 0))
    if race.hpDiff < edgeNeed then return false end
    local minHpPct = (cfg.HUNT_MIN_HP_PCT or 0.40) - (was and 0.05 or 0)
    -- Bracer-invariant absolute HP allowance (`myHp >= 310` with `myHp - enBurst >= 150`) so `2x Bracer` MaxHP never blocks Hunt!
    if (myHp / math.max(1, bot:GetMaxHealth())) < minHpPct and not (cleanOverkill and myHp >= 310) then return false end
    if race.dist > ((cfg.HUNT_MAX_DIST or 1100) + (was and 150 or 0)) then return false end
    if race.heCanKillSoon then return false end
    local t1 = s and s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 760 then
            return false
        end
    end
    if enBurst >= myHp - (cfg.HUNT_SAFETY_HP or 80) then return false end
    if not K.CanCatch(bot, enemyHero, C.RAZE.MID_CENTER + 200, 2.5) then return false end
    return true
end

function H.UpdateIntent(bot, s, race)
    local ctx = IntentCtx
    local enemyHero = s.enemy
    ctx.enemy = enemyHero ~= nil
    ctx.race = race
    ctx.myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    ctx.myRazes = K.MyReadyRazeCount(bot, true)
    ctx.healing = U.IsActivelyHealing(bot)
    ctx.enemyDist = s.enemyDist
    ctx.enemyAbsentFor = (s and s.enemyAbsentFor) or 0
    ctx.enemyRespawningSoon = (s and s.enemyRespawnRemaining ~= nil and s.enemyRespawnRemaining <= 4.5)
        or (GameTime() < (State.freshEnemyTPArrivalUntil or -1000))
    ctx.enemyAbsent = W.EnemyAbsent((C.INTENT and C.INTENT.ENEMY_ABSENT_SEC) or 5.0)
    -- A live enemy disappeared near the lane (highground/trees/fog) - most likely he is
    -- lurking, not gone. Do not count him as "absent" before 12 s.
    if ctx.enemyAbsent and s.enemyAlive and s.enemyLastLoc and s.enemyAbsentFor < 12.0 then
        if U.DistanceBetweenLocations(s.enemyLastLoc, bot:GetLocation()) < 1400 then
            ctx.enemyAbsent = false
        end
    end
    if enemyHero then
        ctx.enemyDistToWave = LN.EnemyDistToAllyWave(enemyHero, s.allyCreeps)
    elseif s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 6.0 then
        local dBestFoW = 99999
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() then
                local dw = U.DistanceBetweenLocations(ac:GetLocation(), s.enemyLastLoc)
                if dw < dBestFoW then dBestFoW = dw end
            end
        end
        ctx.enemyDistToWave = dBestFoW
    else
        ctx.enemyDistToWave = 99999
    end
    ctx.enemyUnderHisTower = false
    ctx.underEnemyTower = false
    local t1 = s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc then
            if enemyHero then
                ctx.enemyUnderHisTower = U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 720
            end
            ctx.underEnemyTower = LN.TowerDanger(bot, t1, s.allyCreeps, nil) >= 2
        end
    end
    ctx.canCatch = enemyHero and K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER, 2.0) or false
    ctx.defensive = State.defensive and not H.HasTradeSupport(race)
    ctx.waveAtMyTower = WV.AtMyTower(bot)
    ctx.waveNoPush = WV.BlockPush(bot, s)
    -- He is TPing to his T1 (channel visible / respawned after death)
    ctx.enemyTPIncoming = (State.enemyTPIncomingUntil or 0) > s.now
    ctx.enemyT1Dist = 99999
    if t1 then
        local okT1, t1Loc = pcall(t1.GetLocation, t1)
        if okT1 and t1Loc then
            ctx.enemyT1Dist = U.DistanceBetweenLocations(bot:GetLocation(), t1Loc)
        end
    end
    ctx.towerChaseBlocked = enemyHero ~= nil and State.towerChaseBlockedEnemy == enemyHero
    ctx.hunt = not ctx.towerChaseBlocked and H.ComputeHunt(bot, s, race, enemyHero)
    ctx.dominant = U.IsLaneDominant and U.IsLaneDominant(bot, s, race) or false
    ctx.deepChoke = ctx.dominant and (U.GetDeepEnemyT1ChokeSpot
        and U.GetDeepEnemyT1ChokeSpot(bot, s, race, s.allyCreeps, s.enemyCreeps) ~= nil) or false
    State.hunting = ctx.hunt
    local intent = I.Update(ctx, s.now)
    State.intent = intent
    if U.DEBUG and (s.now - State.lastIntentPrint) > 2.0 then
        State.lastIntentPrint = s.now
        print(string.format("[SF-BOT] intent=%s (%s) edge=%.0f myB=%.0f enB=%.0f dist=%.0f",
            intent, I.reason, race.valid and race.edge or 0, race.valid and race.myBurstSoon or 0,
            race.valid and race.enBurstSoon or 0, s.enemyDist))
    end
    return intent
end

-- Retreat under the RETREAT intent: get outside the enemy's ready bands toward our own T1.
-- If we are already far enough, do nothing (farming under the tower takes over).
function H.ExecuteRetreat(bot, enemyHero, race)
    -- We took the finish commitment - do not run
    if GameTime() < (State.commitKillUntil or 0) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local hp = bot:GetHealth()
    local critical = race.valid and race.enBurstNow >= hp
    H.BeginForcedRetreat(bot, safeLoc, critical and 1.0 or 0.6)
    return true
end

-- Zoning: stand between the enemy and our wave at HOLD_DIST (outside his near band), right-click him
-- when he is in attack range; do not leave the wave; do not stand in his READY bands.
function H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local deepChokeSpot = U.GetDeepEnemyT1ChokeSpot
        and U.GetDeepEnemyT1ChokeSpot(bot, W and W.s, race, allyCreeps, W and W.s and W.s.enemyCreeps) or nil
    if not enemyHero or not U.CanQuery(enemyHero) then
        if deepChokeSpot then
            local safePos = H.GetSafeApproachLoose(bot, deepChokeSpot, enemyTowers or {}, allyCreeps or {})
            if GetUnitToLocationDistance(bot, safePos) > 55 then
                return H.SmartMove(bot, safePos, 40)
            end
            State.holdPos = true
        end
        return false
    end
    local cfg = C.ZONE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- 0) if he is in a band I can cast and mana allows - the raze (pressure) outranks positioning
    local canPressure = H.ShouldTryRazePressure(bot, enemyHero, "AGGRESSIVE", 0)
    if canPressure and dist <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 20 then
        if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return true end
    end
    local isDominantZ = U.IsLaneDominant and U.IsLaneDominant(bot, nil, race) or false
    local hold = cfg.HOLD_DIST or 495
    -- Do not stand in his ready band when even; when `isDominantZ == true`, hold `495u` against an armed enemy SF
    -- (`> 474u` outside his `Shadowraze1` hull edge, yet inside our `573u` right-click & `450u` `R2`!).
    local minSafe = race.valid and race.minSafeDist or 0
    if isDominantZ then
        minSafe = (((enemyHero:GetMana() or 0) + U.GetMangoMana(enemyHero)) >= 75) and 495 or 280
    elseif H.IsDryVsEnemyRaze(bot, enemyHero) then
        minSafe = math.max(minSafe, (U.GetDrySafeStandoffDist and U.GetDrySafeStandoffDist(bot, enemyHero)) or 745)
    end
    if minSafe > hold then hold = minSafe end
    -- A right click if he is in hull-to-hull range (`525 + 45 = 570u <= 573u`) and it does not walk us into his ready band
    local attackRange = math.max(525, bot:GetAttackRange() or 525) + 45
    if not H.IsDryVsEnemyRaze(bot, enemyHero) and dist <= attackRange and dist >= minSafe - 20 then
        if H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) and not H.IsHeroAttackWindupLocked(bot) then
            if H.IssueHeroAttack(bot, enemyHero) then
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return true
            end
        end
    end
    local maxWaveOff = deepChokeSpot and 780 or (cfg.MAX_FROM_WAVE or 220)
    local pos = deepChokeSpot or LN.ZonePosition(bot, enemyHero, allyCreeps, hold, maxWaveOff)
    if not pos then return false end
    -- Stepping UP to our own wave's zoning line (or River-Wave Enemy-T1 Choke `deepChokeSpot`) is lane dominance!
    local waveCenterZ = LN.AllyWaveCenter(allyCreeps)
    local nearOurWave = (deepChokeSpot ~= nil)
        or (waveCenterZ and (U.DistanceBetweenLocations(pos, waveCenterZ) <= maxWaveOff + 45)) or false
    local dAfter = U.DistanceBetweenLocations(pos, enemyHero:GetLocation())
    if not nearOurWave and dAfter < dist - 60 and not K.CanCatch(bot, enemyHero, dAfter, 1.5) then
        return false
    end
    pos = H.GetSafeApproachLoose(bot, pos, enemyTowers or {}, allyCreeps or {})
    if GetUnitToLocationDistance(bot, pos) > 70 then
        return H.SmartMove(bot, pos, 45)
    end
    -- In place: hold the position (final positioning must not pull the bot away) but
    -- hand control over further on - items/regens must still run.
    State.holdPos = true
    return false
end

function H.HandleIncomingTeleport(bot, s)
    if bot:IsChanneling() then return false end
    local teleports = s and s.incomingEnemyTPs or {}
    if #teleports == 0 then return false end

    -- `v7.9.10-pro` (`2048 @ 04:24.93..04:27.93` `1006 HP / 204 MP` Unreacted Enemy TP -> `Q+W+E` Triple-Coil Fix!):
    -- An enemy hero channeling TP from Fountain lands with **100% HP, 100% Mana (`Q + W + E` ready = `500–850+` burst),
    -- Fountain regen buff, AND point-blank surprise at `300u`**! NEVER ignore an incoming enemy TP at `d = 301u` just because
    -- our own HP is `>= 80%` and mana is `>= 150`! Only skip evacuation if we are literally finishing off a `< 120 HP` Enemy T1
    -- (`<= 2` right-clicks) BEFORE `tp.time_remaining` completes!
    local curHp = bot:GetHealth() or 0
    local enemyT1Loc = (s and s.enemyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
    local dEnemyT1 = enemyT1Loc and GetUnitToLocationDistance(bot, enemyT1Loc) or 9999
    local canFinishT1BeforeTP = false
    if s and s.enemyT1 and U.CanQuery(s.enemyT1) and s.enemyT1:IsAlive() and dEnemyT1 <= (bot:GetAttackRange() or 500) + 120 then
        local t1Hp = s.enemyT1:GetHealth() or 9999
        local botDmgToTower = math.max(25, (bot:GetAttackDamage() or 60) * 0.55)
        local firstTp = teleports[1]
        local remTp = (firstTp and firstTp.time_remaining) or 2.5
        if t1Hp <= botDmgToTower * 2.0 and remTp >= 1.4 and curHp >= 450 then
            canFinishT1BeforeTP = true
        end
    end

    -- Safe standoff outside ALL 3 Shadowrazes (`700 + 250 = 950u`) + walk-up buffer (`1,180u`)!
    local safeRadius = C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 230 -- 1,180u
    for _, tp in pairs(teleports) do
        State.freshEnemyTPArrivalUntil = math.max(State.freshEnemyTPArrivalUntil or 0, GameTime() + (tp.time_remaining or 3.0) + 5.5)
        local distance = GetUnitToLocationDistance(bot, tp.location)
        local nearEnemyT1 = (dEnemyT1 < 1260 and distance < 1480)
            or (s.enemyT1 and s.enemyT1:IsAlive() and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) < 1180)
        if not canFinishT1BeforeTP and (distance < safeRadius or nearEnemyT1) then
            -- Start unlocking any Backpack `item_flask` immediately while running away during the 3.0s TP channel!
            if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
                H.EnsureConsumableReady(bot, "item_flask")
            end
            local fountain = P.GetFountain(bot)
            local toFountain = (fountain - tp.location):Normalized()
            local point = tp.location + toFountain * (safeRadius + 140)
            point = H.GetSafeApproach(bot, point, s.enemyTowers, s.allyCreeps)
            if U.DistanceBetweenLocations(point, tp.location) < safeRadius then
                local away = bot:GetLocation() - tp.location
                if distance < 1 then away = toFountain end
                local dir = away:Normalized()
                for _, candDir in ipairs({ toFountain, dir, Vector(-dir.y, dir.x, 0), Vector(dir.y, -dir.x, 0) }) do
                    local candidate = H.GetSafeApproach(bot, tp.location + candDir * (safeRadius + 160), s.enemyTowers, s.allyCreeps)
                    if U.DistanceBetweenLocations(candidate, tp.location) >= safeRadius then
                        point = candidate
                        break
                    end
                end
            end
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, GameTime() + (tp.time_remaining or 2.8) + 3.2)
            State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, GameTime() + (tp.time_remaining or 2.8) + 2.5)
            State.prepTarget = nil
            State.lhAttackTarget = nil
            H.ClearRazeState()
            State.commitKillUntil = 0
            State.actionTaken = true
            return H.BeginForcedRetreat(bot, point, math.max(1.45, math.min(4.2, (tp.time_remaining or 2.5) + 1.25)))
        end
    end
    return false
end

-- Post-TP Arrival Full-Combo Standoff (`R2_2044` `03:45.33..03:56.57` + `2048` `04:24` Blind Walk-to-Base TP Fix!):
-- 1) Pre-respawn (`enemyAlive == false`, `rem <= 4.0s`): pull back from `dEnemyT1 <= 1420u` unless healthy with creep vision shield.
-- 2) Long walk-to-base absence (`enemyAlive ~= false`, `enemyAbsentFor >= 22.0s`) with NO vision of `enemyT1` highground
--    (`s.enemyT1 == nil` & `shield == 0`): pull back from blind `dEnemyT1 <= 1280u` so a blind FoW TP onto T1 cannot land at `300u`!
function H.HandlePreRespawnOverextensionPullback(bot, s)
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    if not s then return false end
    local enemyT1Loc = s.enemyT1Loc or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
    if not enemyT1Loc then return false end
    local dEnemyT1 = GetUnitToLocationDistance(bot, enemyT1Loc)

    local isPreRespawn = (s.enemyAlive == false) and s.enemyRespawnRemaining and s.enemyRespawnRemaining <= 4.0
    local shield = LN.TowerShieldCountLoc(enemyT1Loc, s.enemyT1, s.allyCreeps, bot:GetLocation())
    local hasT1Vision = (s.enemyT1 ~= nil and U.CanQuery(s.enemyT1)) or shield >= 1
    local isBlindLongAbsence = (s.enemyAlive ~= false) and ((s.enemyAbsentFor or 0) >= 22.0) and not hasT1Vision

    if not isPreRespawn and not isBlindLongAbsence then return false end
    local maxDangerDist = isPreRespawn and 1420 or 1280
    if dEnemyT1 > maxDangerDist then return false end

    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = curHp / maxHp
    local healthyForSiege = (curHp >= 460 and hpPct >= 0.55)
        and not U.IsActivelyHealing(bot)
        and not U.HasItem(bot, "item_flask")
    if isPreRespawn and shield >= 1 and healthyForSiege then
        return false
    end

    local holdPad = isPreRespawn and ((s.enemyRespawnRemaining or 2.0) + 2.8) or 1.5
    State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, GameTime() + holdPad)
    local fnt = P.GetFountain(bot)
    local pullback = enemyT1Loc + (fnt - enemyT1Loc):Normalized() * (isPreRespawn and 1560 or 1360)
    State.prepTarget = nil
    State.lhAttackTarget = nil
    H.SmartMove(bot, pullback, 50)
    State.actionTaken = true
    return true
end

function H.HandleFreshEnemyTPArrival(bot, s, earlyRace)
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    local now = GameTime()
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        if s and (s.enemyAlive == false or (s.enemyAbsentFor or 0) >= 18.0) then
            State.enemyWasDeadRecentlyUntil = now + 22.0
        end
        return false
    end
    -- Also detect hidden-trees post-respawn arrival (`90%+ HP` & `225+ MP` right after respawn) even if TP landed in deep FoW!
    if now < (State.enemyWasDeadRecentlyUntil or -1000) then
        State.enemyWasDeadRecentlyUntil = -1000
        if (enemy:GetHealth() / math.max(1, enemy:GetMaxHealth())) >= 0.88 and U.GetPotentialManaForRaze(enemy) >= 225 then
            State.freshEnemyTPArrivalUntil = math.max(State.freshEnemyTPArrivalUntil or 0, now + 5.0)
        end
    end
    if now >= (State.freshEnemyTPArrivalUntil or -1000) then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) or (earlyRace and earlyRace.valid and earlyRace.canKillNow) then
        return false
    end
    local enHpPct = (enemy:GetHealth() or 0) / math.max(1, enemy:GetMaxHealth() or 1)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    if enHpPct < 0.72 or enPotMana < 150 then return false end

    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = curHp / maxHp
    local myPotMana = U.GetPotentialManaForRaze(bot)
    local myReady = K.MyReadyRazeCount(bot, true)
    local myLvl = bot:GetLevel() or 1
    local enLvl = enemy:GetLevel() or 1
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local enemyT1Loc = (s and s.enemyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
    -- `9070869385.dem` `02:48.87–02:57.53` Post-Kill Anti-Cowardice Fix:
    -- `1620u` from Radiant T1 `(-1544,-1408)` covered the ENTIRE neutral river (`(-398,-262)`), forcing a `L4 17S 2xBracer`
    -- Bot on its own side of the river to flee `1,065u` from a `L3 6S` enemy for `8.5s`! Only treat `<= 1240u` (actual enemy
    -- highground ramp) as `overextendedEnemySide`, and stand ground whenever we hold a safe HP/level/soul combat advantage!
    local overextendedEnemySide = enemyT1Loc and GetUnitToLocationDistance(bot, enemyT1Loc) <= 1240
    local outscaledByFreshFoe = (enLvl > myLvl) or (enMS >= myMS + 25)
        or (earlyRace and earlyRace.valid and (earlyRace.losingHard or earlyRace.heCanKillSoon))
    local twoEnRaze = K.EnemyRazeDamage(bot, enemy, 2)
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local survivesFreshEngage = (curHp >= twoEnRaze + enAtk * 2.0 + 95) and (hpPct >= 0.62 or curHp >= 650)
    local readyEqualFight = (myReady >= 2 and myPotMana >= 150 and (hpPct >= 0.72 or curHp >= 690))
    local holdingStatLead = ((myLvl > enLvl) or (myAtk >= enAtk + 12)) and myPotMana >= 75 and myReady >= 1
    if not overextendedEnemySide and not outscaledByFreshFoe and not U.IsActivelyHealing(bot)
        and survivesFreshEngage and (readyEqualFight or holdingStatLead) then
        return false
    end

    if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
        H.EnsureConsumableReady(bot, "item_flask")
    end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local standDist = 990 -- outside `Shadowraze3` (`700 + 250 = 950u`) + step margin
    if d < standDist then
        local fnt = P.GetFountain(bot)
        local anchor = enemy:GetLocation() + (fnt - enemy:GetLocation()):Normalized() * (standDist + 75)
        State.prepTarget = nil
        State.lhAttackTarget = nil
        H.SmartMove(bot, anchor, 45)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleSeekAlliedWave(bot, s, race)
    State.waveScoutPoint = nil
    if #(s.allyCreeps or {}) > 0 then State.lastAlliedWaveSeen = GameTime(); return false end
    if GameTime() - (State.lastAlliedWaveSeen or -100) < 1.0 then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) or bot:IsUsingAbility() or bot:IsChanneling()
        or U.IsActivelyHealing(bot) or bot:GetHealth() < bot:GetMaxHealth()*0.55 then return false end
    if (State.branchTango and GameTime()-State.branchTango.time<1.5)
        or State.needsTP or (GameTime()>20 and H.IsAtFountain(bot))
        or U.GetActiveItemByName(bot,"item_ward_observer")
        or (State.tangoTree and U.GetActiveItemByName(bot,"item_tango")) then return false end
    local scout = P.GetT1Close(bot, 500)
    for _, tp in pairs(s.incomingEnemyTPs or {}) do
        if GetUnitToLocationDistance(bot, tp.location) < 1300 or U.DistanceBetweenLocations(scout, tp.location) < 1300 then return false end
    end
    if s.enemyT1 and s.enemyT1:IsAlive() and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) < 900 then return false end
    local point = scout
    if U.CanQuery(s.enemy) then
        if GetUnitToLocationDistance(s.enemy, point) < 1100 or GetUnitToLocationDistance(bot, s.enemy:GetLocation()) < 1100
            or (race and race.valid and race.heCanKillSoon) then return false end
    elseif s.enemyAlive and s.enemyLastLoc and (s.enemyAbsentFor or 0) < 5
        and U.DistanceBetweenLocations(point, s.enemyLastLoc) < 1200 then return false end
    if bot.GetIncomingTrackingProjectiles and #(bot:GetIncomingTrackingProjectiles() or {}) > 0 then return false end
    for _, creep in pairs(s.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    for _, tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(tower, point) < 900 then return false end
    end
    State.waveScoutPoint = point
    if GetUnitToLocationDistance(bot, point) > 45 then return H.SmartMove(bot, point, 30) end
    State.holdPos = true
    return false
end

function H.LaneEnemyAbsent(s)
    if s.enemyAlive == false then return true end
    if U.CanQuery(s.enemy) then return (s.enemyDist or 0) > 1800 and LN.EnemyDistToAllyWave(s.enemy, s.allyCreeps) > 1600 end
    local unseen = s.enemyAbsentFor or 0
    if unseen < 5 then return false end
    if unseen < 12 and s.enemyLastLoc and s.bot
        and U.DistanceBetweenLocations(s.enemyLastLoc, s.bot:GetLocation()) < 1400 then return false end
    return true
end

function H.PriorityPushAllowed(bot, s, race)
    if State.branchTango and GameTime()-State.branchTango.time<1.5 then return false end
    if State.needsTP or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc or GameTime() < (State.fleeUntil or 0) then
        return false
    end
    -- Post-kill (`s.enemyAlive == false`, `HUD 09:01`!): lane creeps NEVER cancel Salve or Tango in Dota 2 7.41f,
    -- so shove the wave immediately while healing!
    if s.enemyAlive ~= false and (bot:GetHealth() < bot:GetMaxHealth()*0.5 or U.IsActivelyHealing(bot)) then
        return false
    end
    local teleports = s.incomingEnemyTPs or {}
    if #teleports == 0 and GameTime() < (State.enemyTPIncomingUntil or 0) then return false end
    for _, tp in pairs(teleports) do
        if GetUnitToLocationDistance(bot, tp.location) < 1800
            or (s.enemyT1 and GetUnitToLocationDistance(s.enemyT1, tp.location) < 1200) then return false end
    end
    if U.CanQuery(s.enemy) then
        local distance = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
        if H.IsEnemyPressuring(bot, s.enemy) and distance < 1400 then return false end
        if K.HasRazeStackLead(bot,s.enemy) and K.EnemyBandsAcross(s.enemy,distance,distance,0.7)>0 then return false end
    end
    if (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.28
        and #(s.allyCreeps or {}) <= 1
        and ((s.enemyT1 and U.CanQuery(s.enemyT1) and s.enemyT1:GetHealth()) or 9999) > 450 then
        return false
    end
    if H.LaneEnemyAbsent(s) then return true end
    return race and race.valid and not race.heCanKillSoon and race.edge >= (C.INTENT.PUSH_EDGE or 260)
        and s.enemyT1 ~= nil and GetUnitToLocationDistance(bot,s.enemyT1:GetLocation()) <= 1180
end

function H.HandleSiegeGlyph(bot, s, race)
    if not U.IsGlyphAvailable(bot) then return false end
    if U.ShouldUseGlyphDefensive(bot, s.allyTowers) then return U.UseGlyph(bot) end
    -- Wave-Freeze Defensive Glyph (`v7.9.0`): in 1v1 Sudden-Death T1 rules, if a heavy enemy double/catapult wave
    -- (`>= 5` creeps or `Siege + >= 3` creeps) is actively hitting our unshielded Mid T1 (`<= 1150 HP`), pop Glyph!
    local ownMidT1 = GetTower(bot:GetTeam(), TOWER_MID_1)
    if ownMidT1 and U.CanQuery(ownMidT1) and ownMidT1:IsAlive()
        and not ownMidT1:HasModifier("modifier_fountain_glyph")
        and (ownMidT1:GetHealth() or 1800) <= 1150
        and #(s and s.allyCreeps or {}) == 0 then
        local ownT1Loc = ownMidT1:GetLocation()
        local enUnderT1, hasSiegeUnderT1 = 0, false
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(ec:GetLocation(), ownT1Loc) <= 760 then
                enUnderT1 = enUnderT1 + 1
                if LN.IsSiege and LN.IsSiege(ec) then hasSiegeUnderT1 = true end
            end
        end
        if enUnderT1 >= 5 or (hasSiegeUnderT1 and enUnderT1 >= 3) then
            return U.UseGlyph(bot)
        end
    end
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph")
        or (not H.LaneEnemyAbsent(s) and not H.PriorityPushAllowed(bot, s, race))
        or GetUnitToLocationDistance(bot, tower:GetLocation()) > 1450 then return false end
    local tank = tower:GetAttackTarget()
    if not U.CanQuery(tank) or tank == bot or (tank.IsHero and tank:IsHero())
        or tank:HasModifier("modifier_fountain_glyph") then return false end
    local allied = false
    for _, c in pairs(s.allyCreeps or {}) do if c == tank then allied = true; break end end
    if not allied or GetUnitToLocationDistance(tank, tower:GetLocation()) > 900 then return false end
    local allyT1Hp = (ownMidT1 and U.CanQuery(ownMidT1) and ownMidT1:GetHealth()) or 1800
    if allyT1Hp < 850 then return false end
    local isSiegeTank = LN.IsSiege and LN.IsSiege(tank)
    local enemyTowerHp = tower:GetHealth() or 9999
    local towerLow = enemyTowerHp <= (isSiegeTank and 520 or 320)
    if not towerLow then return false end
    local hit = tank:GetActualIncomingDamage(tower:GetAttackDamage(), DAMAGE_TYPE_PHYSICAL)
    local threshold = isSiegeTank and (hit * 2.55) or (hit * 1.35)
    local imminent = tank:GetHealth() <= threshold
    for _, projectile in pairs(U.SafeGetIncomingProjectiles(tank)) do
        if projectile.caster == tower and projectile.is_attack and tank:GetHealth() <= threshold + hit * 0.65 then imminent = true end
    end
    if not imminent then return false end
    return U.UseGlyph(bot)
end

-- True geometric test whether `enemy` is behind `towerLoc` (toward Enemy T2 / Fountain) or too far to contest max-range chip.
-- `auto-20261102-0159-start-ShaNachnetsya.dem` Fix #7:
-- Previously `dist(enemy, tLoc) < dist(bot, tLoc) + 80` INVERTED whenever a low-HP enemy retreated `850..1,400u` behind
-- their own T1 toward T2 (`950 < 720 == false`!), causing SF to stop hitting an completely undefended Enemy T1!
function H.IsEnemyBehindOwnTower(bot, enemy, towerLoc)
    if not (enemy and U.CanQuery(enemy) and enemy:IsAlive() and towerLoc) then
        return true
    end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local dBotEnemy = U.DistanceBetweenLocations(bLoc, eLoc)
    if dBotEnemy >= 920 then
        return true
    end
    local pushVec = towerLoc - bLoc
    local pushLen = pushVec:Length2D()
    if pushLen < 25 then
        return dBotEnemy >= 760
    end
    local px, py = pushVec.x / pushLen, pushVec.y / pushLen
    local projBehind = (eLoc.x - towerLoc.x) * px + (eLoc.y - towerLoc.y) * py
    return projBehind >= -95 and dBotEnemy >= 680
end

function H.HandleSiegeTower(bot, race, s)
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph") then return false end
    local tLoc = tower:GetLocation()
    local distance = GetUnitToLocationDistance(bot, tLoc)
    local atkRange = math.max(500, (bot.GetAttackRange and bot:GetAttackRange()) or 500)
    -- Must strictly exceed `LN.TowerEscapePoint` (`1035u`, where `9055695956.dem` deadlocked forever at `dRT1 = 912u > 900u`!)
    if distance > math.max(1180, atkRange + 540) then return false end
    local nowSiege = GameTime()
    local finish = LN.IsTowerFinishable(bot, tower)
    local minCreepDistToT1 = math.huge
    local shieldCreeps, shieldHpTotal = 0, 0
    for _, ac in pairs(s.allyCreeps or {}) do
        if U.CanQuery(ac) and ac:IsAlive() then
            local dcT = U.DistanceBetweenLocations(ac:GetLocation(), tLoc)
            if dcT <= 780 then
                shieldCreeps = shieldCreeps + 1
                shieldHpTotal = shieldHpTotal + (ac:GetHealth() or 0)
                if dcT < minCreepDistToT1 then minCreepDistToT1 = dcT end
            end
        end
    end
    -- Dynamic siege standoff scaling with `atkRange` (`645u` at `500–525u` base range; `775u` with Dragon Lance `650u`,
    -- where center-to-center tower reach is `650 + 144 + 24 = 818u` — safely outside T1 `700u` range & enemy razes!).
    local baseSiegeStand = math.min(780, math.max(645, atkRange + 125))
    local desiredSiegeStand = baseSiegeStand
    if minCreepDistToT1 < 900 then
        desiredSiegeStand = math.min(math.max(670, baseSiegeStand + 10), math.max(baseSiegeStand - 5, minCreepDistToT1 + 45))
    end
    if not finish then
        -- `auto-20261031-0230` `01:43.4-01:44.4` (`tk=7230..7250`) 2nd-Tower-Shot Re-Entry Fix:
        -- NEVER let `HandleSiegeTower` reverse SF back into enemy T1 right after `HandleEnemyTowerSafety` evacuated us!
        if nowSiege < (State.noReenterEnemyT1Until or 0) then return false end
        if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.0) then return false end
        local enemyBehindOwnT1 = H.IsEnemyBehindOwnTower(bot, s.enemy, tLoc)
        local enemyFarUncontested = (not U.CanQuery(s.enemy))
            or (GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= 960 and enemyBehindOwnT1)
        local enemyAbsent = H.LaneEnemyAbsent(s) or enemyFarUncontested
        local burnBlocks = H.TowerBurnActive() and not enemyAbsent
        local minSiegeHp = enemyAbsent and 240 or math.min(430, bot:GetMaxHealth() * 0.43)
        if bot:GetHealth() < minSiegeHp or burnBlocks or tower:GetAttackTarget() == bot then return false end
        -- Never siege on a single fragile creep (`<= 310 HP`, e.g. 1 lone `300 HP` ranged creep at `tk=7180`!) when enemy hero contests close
        if not enemyAbsent and shieldCreeps <= 1 and shieldHpTotal <= 310 then return false end
        local point = tLoc + (bot:GetLocation() - tLoc):Normalized() * desiredSiegeStand
        if U.CanQuery(s.enemy) and not enemyFarUncontested and not K.StackLeadStepSafe(bot, s.enemy, point) then return false end
        local activeTank = tower:GetAttackTarget()
        local hasLiveCreepTank = U.CanQuery(activeTank) and activeTank ~= bot and not (activeTank.IsHero and activeTank:IsHero())
        if not LN.CanHitTower(bot, tower, s.allyCreeps, 1)
            or (not hasLiveCreepTank and LN.TowerShieldCount(tower, s.allyCreeps, point) < 1) then return false end
        local enemyDryPassive = U.CanQuery(s.enemy)
            and ((s.enemy:GetMana() or 0) + U.GetMangoMana(s.enemy) < 75)
            and not H.IsEnemyPressuring(bot, s.enemy)
        local dominantHpLead = U.CanQuery(s.enemy)
            and (bot:GetHealth() or 0) >= math.max(650, (s.enemy:GetHealth() or 9999) + 320)
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= 620
        if U.CanQuery(s.enemy) and not enemyFarUncontested and (not race.valid or race.heCanKillSoon or H.IsEnemyPressuring(bot, s.enemy)
            or (not enemyDryPassive and not enemyBehindOwnT1 and not dominantHpLead
                and race.edge < (C.INTENT.PUSH_EDGE or 260) and not LN.EnemyBusyWithWave(bot, s.enemy)
                and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) <= 950)) then return false end
    end
    State.prepTarget = nil; State.lhAttackTarget = nil
    local lastAtkAge = nowSiege - (bot:GetLastAttackTime() or -100)
    if not finish and distance < desiredSiegeStand - 12 and (lastAtkAge < 0.75 or (minCreepDistToT1 < 900 and distance <= minCreepDistToT1 + 22)) then
        local standEdge = tLoc + (P.GetFountain(bot) - tLoc):Normalized() * desiredSiegeStand
        H.SmartMove(bot, standEdge, 22)
        State.actionTaken = true
        return true
    end
    -- Switch Power Treads to Agility (`FIGHT`: `+10 Damage & +10 AS`) before or between Enemy T1 right-clicks (`07:20–07:45` Fix)!
    if LN.TowerHitsToKill(bot, tower) > 1 and U.HasItem(bot, "item_power_treads") then
        local spaTw = math.max(0.65, bot:GetSecondsPerAttack() or 1.35)
        local apTw = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        local notAttackingTowerYet = (bot:GetAttackTarget() ~= tower) or not U.IsAttackingAction(bot)
        local inTowerBackswing = (lastAtkAge >= 0.05) and ((spaTw - lastAtkAge) >= (apTw + 0.12))
        if (notAttackingTowerYet or inTowerBackswing) and H.TrySafeTreadsSwitch(bot, "FIGHT") then
            return true
        end
    end
    if bot:GetAttackTarget() ~= tower or not U.IsAttackingAction(bot) then
        bot:Action_AttackUnit(tower, false)
        H.ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

-- ---------------------------------------------------------------------------
-- (towerLH) Under MY tower the tower is the last-hitter, and the bot never contests it: measured
-- 17.8 enemy-creep deaths per game go to our own tower, 11.8 of them within 700 of the bot and
-- 78 % of those WITHOUT the bot ever having hit the creep in the previous 2 s.  A human takes
-- those creeps by pre-swinging so that the hit lands right after the tower shot.  This runs at the
-- LOWEST priority (after every ordinary last hit/deny/punish), so it only uses otherwise idle
-- attack cycles, and asks for at most 2 tower shots of head-room.
function H.HandleTowerStealLastHit(bot, enemyCreeps, allyTowers, enemyTowers, allyCreeps)
    if C.LASTHIT.TOWER_STEAL_LH == false then return false end
    if State.actionTaken or not enemyCreeps then return false end
    local act = bot:GetCurrentActionType()
    if (act == BOT_ACTION_TYPE_ATTACK or (BOT_ACTION_TYPE_ATTACKUNIT ~= nil and act == BOT_ACTION_TYPE_ATTACKUNIT)) then return false end   -- already swinging at something
    local best, bestScore = nil, math.huge
    for _, c in ipairs(enemyCreeps) do
        if U.CanQuery(c) then
            local onTower = false
            for _, t in ipairs(allyTowers or {}) do
                if t and t:IsAlive() and t:GetAttackTarget() == c then onTower = true; break end
            end
            if onTower then
                local loc = c:GetLocation()
                local dist = GetUnitToLocationDistance(bot, loc)
                if dist <= (bot:GetAttackRange() or 525) + (C.LASTHIT.TOWER_STEAL_RANGE_PAD or 35) then
                    local hp = c:GetHealth()
                    -- one tower shot, as it will actually land on a creep
                    local shot = 90
                    for _, t in ipairs(allyTowers or {}) do
                        if t and t:IsAlive() and t:GetAttackTarget() == c and t.GetAttackDamage then
                            local ok, v = pcall(t.GetAttackDamage, t)
                            if ok and type(v) == "number" and v > 0 then shot = v end
                            break
                        end
                    end
                    local realShot = shot
                    if c.GetActualIncomingDamage then
                        local ok, v = pcall(c.GetActualIncomingDamage, c, shot, DAMAGE_TYPE_PHYSICAL)
                        if ok and type(v) == "number" and v > 0 then realShot = v end
                    end
                    local dr = U.SFDamageRange(bot, c)
                    local remNow = hp % math.max(1, realShot)
                    local alreadyCleanlyPrepped = (remNow >= 8 and remNow <= dr.min)
                    local remAfterOneHit = math.max(0, hp - dr.avg) % math.max(1, realShot)
                    -- Only pre-hit when the creep is NOT already cleanly landing in `[8 .. dr.min]` after tower shots,
                    -- AND one setup hit puts its post-tower remainder cleanly into `[8 .. dr.min + 6]`!
                    if not alreadyCleanlyPrepped
                        and hp <= realShot * (C.LASTHIT.TOWER_STEAL_SHOTS or 2.2) + 2.2 * dr.avg
                        and hp > realShot + 8
                        and remAfterOneHit >= 8 and remAfterOneHit <= (dr.min + 6) then
                        if H.IsSafeToAttack(bot, loc, enemyTowers, allyCreeps) then
                            local score = hp - realShot
                            if score < bestScore then bestScore, best = score, c end
                        end
                    end
                end
            end
        end
    end
    if best then
        bot:Action_AttackUnit(best, true)
        State.lhAttackTarget = best
        State.attackTarget = best
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandlePriorityPush(bot, s, race)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or not H.PriorityPushAllowed(bot,s,race) then return false end
    if H.HandleSiegeGlyph(bot,s,race) then State.actionTaken=true;return true end
    if H.HandleEnemyTowerSafety(bot,s,s.enemy) then return true end
    if H.HandleSiegeTower(bot,race,s) then return true end
    if not H.LaneEnemyAbsent(s) then return false end
    -- `ShaNachnetsya` `00:45–01:01` Post-Kill CS+Deny Equilibrium Fix:
    -- When the enemy hero is DEAD, do NOT auto-shove creeps unless `U.CanCrashWaveBeforeEnemyReturn(bot, s)` proves
    -- our wave will genuinely reach Enemy T1 before he respawns & TPs!
    if s.enemyAlive == false and U.CanCrashWaveBeforeEnemyReturn and not U.CanCrashWaveBeforeEnemyReturn(bot, s) then
        return false
    end
    -- Never displace any securable enemy CS or allied deny inside 1.85s (`L.PeekBestPlan` exact 30Hz check!)
    local bestPlanPush, bestEtaPush = L.PeekBestPlan(bot, s)
    if bestPlanPush and bestEtaPush <= 1.85 then return false end
    local enemyAttackers = U.MergeLists(s.enemyCreeps,s.enemyTowers)
    local allyAttackers = U.MergeLists(s.allyCreeps,s.allyTowers)
    local crashDenies = (s.enemyAlive == false and U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s))
        and {} or s.allyCreeps
    local target, deny = L.GetBestTarget(bot,s.enemyCreeps,crashDenies,enemyAttackers,allyAttackers,false)
    if target and U.GetTimeToKillable(bot,target,deny and enemyAttackers or allyAttackers) <= 1.85 then return false end
    if not LN.BestPushCreep(bot,s.enemyCreeps,(C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700,s.allyCreeps) then return false end
    State.prepTarget=nil;State.lhAttackTarget=nil
    return H.ExecutePush(bot,s.enemy,race,s,true)
end

function H.ExecutePush(bot, enemyHero, race, s, priority)
    if State.actionTaken then return false end
    if not WV.AllowPush(bot, s) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemyCreeps, allyCreeps, enemyTowers = s.enemyCreeps, s.allyCreeps, s.enemyTowers
    local t1 = s.enemyT1
    local myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local now = GameTime()

    if priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 0) Post-Kill Wave-Shove Shadowraze (`s.enemyAlive == false` ONLY when `WV.ShoveAllowed` / `CanCrashWaveBeforeEnemyReturn` is true!)
    -- `auto-20261102-0139` `9:26.40` (`164 -> 90 MP` Close-`Q` on 2 Creeps While Enemy Dead) Fix:
    -- Require `>= 255 MP` (`>= 195 MP` with incoming courier Mango) AND (`hits >= 3` OR `kills >= 2`) so SF NEVER burns
    -- `75 MP` chipping 2 uncontested creeps and greets the respawned + TPing enemy dry!
    if WV.ShoveAllowed(bot, s) and #(enemyCreeps or {}) >= 2 then
        for _, label in ipairs({ "mid", "near", "far" }) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local rawDmg = U.GetRazeDamage(bot, ab, 0)
                local bCenter = (label == "near" and C.RAZE.NEAR_CENTER)
                    or (label == "mid" and C.RAZE.MID_CENTER)
                    or C.RAZE.FAR_CENTER
                for _, c in pairs(enemyCreeps) do
                    if U.CanQuery(c) and c:IsAlive() then
                        local cLoc = c:GetLocation()
                        local coilCtr = U.PointAlongLine(bot:GetLocation(), cLoc, bCenter)
                        local hits, kills = 0, 0
                        for _, c2 in pairs(enemyCreeps) do
                            if U.CanQuery(c2) and c2:IsAlive()
                                and U.DistanceBetweenLocations(coilCtr, c2:GetLocation()) <= C.RAZE.CREEP_EFF_RADIUS then
                                hits = hits + 1
                                local mDmg = c2.GetActualIncomingDamage
                                    and math.floor(c2:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL))
                                    or math.floor(rawDmg * 0.75)
                                if (c2:GetHealth() or 999) <= mDmg then
                                    kills = kills + 1
                                end
                            end
                        end
                        if hits >= 3 or kills >= 2 then
                            local action, aim = H.GetRazeActionType(bot, ab, c)
                            if action and H.CastOrTurnRaze(bot, ab, action, aim, c) then
                                WV.NoteShove(now)
                                return true
                            end
                        end
                    end
                end
            end
        end
        -- Strictly use `LN.BestPushCreep` (respecting `LN.PushHpFloor`!) so we NEVER whack a `79 HP` creep down to `19 HP`
        -- for allied melee creeps to steal (`ShaNachnetsya` `00:56.00` `#1126` Fix)!
        local safeShoveCreep = LN.BestPushCreep(bot, enemyCreeps, (C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700, allyCreeps)
        if safeShoveCreep and H.IsSafeToAttack(bot, safeShoveCreep:GetLocation(), enemyTowers, allyCreeps) then
            if H.TrySafeTreadsSwitch(bot, "FIGHT") then return true end
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= safeShoveCreep then
                bot:Action_AttackUnit(safeShoveCreep, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    -- 1) enemy creeps nearby -> hit the "fat" ones (low HP is the last-hit zone, do not push-hit there)
    local pushCreep = LN.BestPushCreep(bot, enemyCreeps, (C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700, allyCreeps)
    -- The current push target dropped into the last-hit zone: stop attacking it continuously
    if not priority and U.IsAttackingAction(bot) then
        local cur = bot:GetAttackTarget()
        if cur and U.CanQuery(cur) and not (cur.IsHero and cur:IsHero()) and not (cur.IsTower and cur:IsTower())
            and State.lhAttackTarget ~= cur and (cur:GetHealth() or 0) <= LN.PushHpFloor(bot, cur, allyCreeps) then
            if pushCreep == cur then pushCreep = nil end
            if not pushCreep then
                bot:Action_ClearActions(false)
                H.ClearMoveCache()
                State.actionTaken = true
                return true
            end
        end
    end
    if pushCreep then
        if H.IsSafeToAttack(bot, pushCreep:GetLocation(), enemyTowers, allyCreeps) then
            if H.TrySafeTreadsSwitch(bot, "FIGHT") then return true end
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= pushCreep then
                bot:Action_AttackUnit(pushCreep, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    if not priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 4) move forward with the wave (behind the front creep) if there are creeps
    local front = LN.FrontAllyCreep(bot, allyCreeps)
    if front then
        local fountain = P.GetFountain(bot)
        local dir = (fountain - front:GetLocation()):Normalized()
        local pos = front:GetLocation() + dir * 300
        pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
        -- "Moving with the wave" never walks under the T1: without a tower hit (item 2) there is nothing
        -- to do inside its radius (the creeps die - the tower switches to us). Stay >= 800.
        if t1 and t1:IsAlive() then
            local okTL, tl = pcall(t1.GetLocation, t1)
            if okTL and tl then
                local keep = ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) + 20
                if U.DistanceBetweenLocations(pos, tl) < keep then
                    pos = tl + (pos - tl):Normalized() * keep
                end
            end
        end
        if GetUnitToLocationDistance(bot, pos) > 120 then
            return H.SmartMove(bot, pos, 60)
        end
        State.holdPos = true -- In place behind the wave: do not let the final positioning pull us back
        return false
    end
    return false
end

-- Simulation-only probe (never used by the real client): the harness reads the last stage name
-- from the global namespace to attribute free-pressure orders. Zero cost outside the sim.

-- Helper: is friendly Mid T1 (`s.allyT1`) in critical 1v1 Sudden-Death danger (`HP <= 420` with enemy hero/wave nearby)?
-- In `DOTA_GAMEMODE_1V1MID`, friendly Mid T1 dying instantly destroys our Ancient (`tk=21442` BAR 9:10 & `9074666246` `10:39`!).
function H.IsAllyT1InSuddenDeathDanger(bot, s)
    local t1 = s and s.allyT1
    if not t1 then return false, nil end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false, nil end
    local okH, tHp = pcall(t1.GetHealth, t1)
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okH or not tHp or tHp > 920 or not okL or not tLoc then return false, nil end

    local hasSiegeNear = false
    for _, list in ipairs({ (s and s.enemyCreepsNearAllyT1) or {}, (s and s.enemyCreeps) or {} }) do
        for _, c in pairs(list) do
            if U.CanQuery(c) and c:IsAlive() and U.DistanceBetweenLocations(tLoc, c:GetLocation()) <= 880 then
                local nm = (c.GetUnitName and c:GetUnitName()) or ""
                if nm:find("siege") or nm:find("catapult") then
                    hasSiegeNear = true
                    break
                end
            end
        end
        if hasSiegeNear then break end
    end
    local enemy = s and s.enemy
    local heroInSiegeRange = (enemy and U.CanQuery(enemy) and enemy:IsAlive()
        and U.DistanceBetweenLocations(tLoc, enemy:GetLocation()) <= 820) or false
    -- `v7.9.19` (`9074666246.dem` `10:38.87..10:49.00` `520 -> 0 HP` Catapult + Hero T1 Loss Fix!):
    -- Raise emergency threshold from `420` to `720 HP` (`or 920 HP` when Siege Catapult + Enemy Hero hit T1 together)!
    local dangerHpCap = (hasSiegeNear and heroInSiegeRange) and 920 or (hasSiegeNear and 780 or 720)
    if tHp > dangerHpCap then return false, nil end

    local t1RecentlyHit = (t1.WasRecentlyDamagedByAnyHero and t1:WasRecentlyDamagedByAnyHero(2.6))
        or (t1.WasRecentlyDamagedByCreep and t1:WasRecentlyDamagedByCreep(2.6))
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local dEnT1 = U.DistanceBetweenLocations(tLoc, enemy:GetLocation())
        local enTargetingT1 = (enemy.GetAttackTarget and enemy:GetAttackTarget() == t1)
        if enTargetingT1 or dEnT1 <= 760 or (t1RecentlyHit and dEnT1 <= 1120) then
            return true, t1, tLoc
        end
    end
    local allyShieldNearT1 = 0
    for _, ac in pairs((s and s.allyCreeps) or {}) do
        if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(tLoc, ac:GetLocation()) <= 620 then
            allyShieldNearT1 = allyShieldNearT1 + 1
        end
    end
    local creepRadius = (t1RecentlyHit or allyShieldNearT1 == 0) and 920 or 740
    local creepPool = (s and s.enemyCreepsNearAllyT1 and #s.enemyCreepsNearAllyT1 > 0)
        and s.enemyCreepsNearAllyT1
        or ((s and s.enemyCreeps) or {})
    for _, c in pairs(creepPool) do
        if U.CanQuery(c) and c:IsAlive() and U.DistanceBetweenLocations(tLoc, c:GetLocation()) <= creepRadius then
            return true, t1, tLoc
        end
    end
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and U.DistanceBetweenLocations(tLoc, c:GetLocation()) <= creepRadius then
            return true, t1, tLoc
        end
    end
    return false, nil, nil
end

-- `v7.9.11-pro` (`2213 @ 10:54..12:59` Anti-Creep-Cut & Global `allyT1` Siege Awareness):
-- Detects:
--   1. `t1UnderCreepSiege`: Enemy lane creeps attacking or entering `allyT1` (`<= 1,180u`) with NO allied creeps in front
--      of `allyT1` tanking them (even when `bot` is `> 1,600u` away in river or jungle!).
--   2. `enemyCuttingBehindT1`: Enemy hero intercepting/proxy-farming our allied wave behind `allyT1` (between `allyT1` & `allyT2`),
--      plus `enemyFledDeepJungle` (`> 1,020u` lateral off the `allyT1 <-> fountain` spine with `0` allied creeps near them,
--      such as `(3094, 82)` at `11:36..11:48`!).
function H.GetEnemyCreepCutAndT1SiegeState(bot, s)
    local tLoc = (s and s.allyT1Loc)
        or (s and s.allyT1 and U.CanQuery(s.allyT1) and s.allyT1:GetLocation())
        or nil
    if not tLoc or (s and s.allyT1Alive == false) then
        return { valid = false }
    end
    local tHp = (s and s.allyT1Hp)
        or (s and s.allyT1 and U.CanQuery(s.allyT1) and s.allyT1:GetHealth())
        or 1800
    local fnt = P.GetFountain(bot)
    local dT1Fnt = U.DistanceBetweenLocations(tLoc, fnt)
    local spineVec = fnt - tLoc
    local spineLen = math.max(1.0, U.DistanceBetweenLocations(tLoc, fnt))
    local spx, spy = spineVec.x / spineLen, spineVec.y / spineLen

    local siegeCount = 0
    local minDistT1 = math.huge
    local nearestCreep = nil
    local siegeCatapult = nil
    local aggroHijackCreep = nil
    local seenCreep = {}
    local function ScanEnemyCreepList(list)
        for _, ec in pairs(list or {}) do
            if ec and not seenCreep[ec] and U.CanQuery(ec) and ec:IsAlive() then
                seenCreep[ec] = true
                local dc = U.DistanceBetweenLocations(ec:GetLocation(), tLoc)
                if dc <= 1180 then
                    siegeCount = siegeCount + 1
                    local nmEc = (ec.GetUnitName and ec:GetUnitName()) or ""
                    if (nmEc:find("siege") or nmEc:find("catapult")) and dc <= 900 then
                        siegeCatapult = ec
                    end
                    if dc <= 725 and ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                        aggroHijackCreep = ec
                    end
                    if dc < minDistT1 then
                        minDistT1 = dc
                        nearestCreep = ec
                    end
                end
            end
        end
    end
    ScanEnemyCreepList(s and s.enemyCreepsNearAllyT1)
    ScanEnemyCreepList(s and s.enemyCreeps)

    local allyFrontCount = 0
    for _, ac in pairs((s and s.allyCreeps) or {}) do
        if U.CanQuery(ac) and ac:IsAlive() then
            local acLoc = ac:GetLocation()
            if U.DistanceBetweenLocations(acLoc, tLoc) <= 820
                and U.DistanceBetweenLocations(acLoc, fnt) >= dT1Fnt - 220 then
                allyFrontCount = allyFrontCount + 1
            end
        end
    end
    -- Also check if global behind-T1 creeps are still far behind T1 (`allyFrontCount` stays 0 when wave was cut!)
    local t1UnderCreepSiege = (allyFrontCount == 0)
        and (siegeCount >= 1)
        and (minDistT1 <= 920 or (siegeCount >= 2 and minDistT1 <= 1180))

    local enemy = s and s.enemy
    local enemyVisible = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local enemyCuttingBehindT1 = false
    local enemyFledDeepJungle = false
    local cutTargetLoc = nil

    if enemyVisible then
        local eLoc = enemy:GetLocation()
        local dEnFnt = U.DistanceBetweenLocations(eLoc, fnt)
        local dEnT1 = U.DistanceBetweenLocations(eLoc, tLoc)
        if dEnFnt <= dT1Fnt - 120 and dEnT1 <= 2750 then
            local relX, relY = eLoc.x - tLoc.x, eLoc.y - tLoc.y
            local latFromSpine = math.abs(relX * (-spy) + relY * spx)
            local allyNearEnemy = 0
            for _, ac in pairs((s and s.allyCreepsBehindT1) or {}) do
                if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), eLoc) <= 680 then
                    allyNearEnemy = allyNearEnemy + 1
                end
            end
            for _, ac in pairs((s and s.allyCreeps) or {}) do
                if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), eLoc) <= 680 then
                    allyNearEnemy = allyNearEnemy + 1
                end
            end
            enemyCuttingBehindT1 = true
            cutTargetLoc = eLoc
            if latFromSpine > 1020 and allyNearEnemy == 0 and (enemy:GetHealth() or 9999) > 285 then
                enemyFledDeepJungle = true
            end
        end
    end

    if not enemyCuttingBehindT1 and siegeCount == 0 then
        local behindList = (s and s.allyCreepsBehindT1) or {}
        if #behindList >= 2 then
            for _, ac in pairs(behindList) do
                if U.CanQuery(ac) and ac:IsAlive() then
                    local cHp = ac:GetHealth() or 0
                    local cMax = math.max(1, ac:GetMaxHealth() or 1)
                    if cHp < cMax - 18 then
                        enemyCuttingBehindT1 = true
                        cutTargetLoc = ac:GetLocation()
                        break
                    end
                end
            end
        end
    end

    local heroSiegingT1 = enemyVisible
        and (U.DistanceBetweenLocations(enemy:GetLocation(), tLoc) <= 785
            or (s and s.allyT1 and enemy.GetAttackTarget and enemy:GetAttackTarget() == s.allyT1))
        or false

    return {
        valid = true,
        allyT1Loc = tLoc,
        allyT1Hp = tHp,
        t1UnderCreepSiege = t1UnderCreepSiege,
        siegeCount = siegeCount,
        minDistT1 = minDistT1,
        nearestCreep = nearestCreep,
        siegeCatapult = siegeCatapult,
        aggroHijackCreep = aggroHijackCreep,
        heroSiegingT1 = heroSiegingT1,
        enemyCuttingBehindT1 = enemyCuttingBehindT1,
        enemyFledDeepJungle = enemyFledDeepJungle,
        cutTargetLoc = cutTargetLoc,
    }
end

-- `v7.9.11-pro` Anti-Creep-Cut & Undefended `allyT1` Creep-Siege Defender (`2213 @ 10:54..12:59` Complete Fix):
--   Rule 1: Whenever enemy lane creeps are hitting or entering an undefended `allyT1` (`t1UnderCreepSiege`), NEVER push
--           empty river AND NEVER chase a proxy-cutter into deep jungle (`(3094, 82)`): snap back to `allyT1` and clear
--           the enemy creeps off `allyT1` (`0` uncontested tower chip!). Even during `modifier_flask_healing`, lane creeps
--           do NOT break Salve — walk back to `allyT1` if the enemy hero is safely away (`>= 1,180u`)!
--   Rule 2: When the enemy hero is cutting our wave behind `allyT1` (`enemyCuttingBehindT1`) while `allyT1` is clear of
--           enemy creeps, abort empty river push and collapse onto the cutter along the T1-T2 mid corridor (refusing
--           deep side-jungle baits `> 1,020u` off-spine)!
function H.HandleAntiCreepCutAndT1Defense(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if State.goingToFountain then return false end
    local info = H.GetEnemyCreepCutAndT1SiegeState(bot, s)
    if not info or not info.valid then return false end

    local nowCut = GameTime()
    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local enemy = s and s.enemy
    local enemyVisible = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local dBotT1 = GetUnitToLocationDistance(bot, info.allyT1Loc)
    local hasSalve = bot:HasModifier("modifier_flask_healing")

    -- Never turn a fleeing/critically-endangered SF back into a pursuing stronger enemy hero (`10:07.53` Regression Guard!):
    -- Sudden-death `< 420 HP` throne defense is ALREADY handled above by `HandleCriticalAllyT1AndDivePunish`!
    local activeRetreatNow = (State.forcedRetreatLoc ~= nil and nowCut < (State.forcedRetreatUntil or 0))
        or (nowCut < (State.fleeUntil or 0))
        or (nowCut < (State.critDangerHystUntil or 0))
    if activeRetreatNow or H.InCriticalLethalDanger(bot, s, earlyRace)
        or (earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon)) then
        return false
    end
    if enemyVisible and GetUnitToLocationDistance(bot, enemy:GetLocation()) <= 980
        and ((myHp / myMaxHp) <= 0.48 or H.InLosingHeroTrade(bot, s, earlyRace)) then
        return false
    end

    -- [RULE 1] UNDEFENDED `allyT1` CREEP-SIEGE PROTECTION
    if info.t1UnderCreepSiege and info.nearestCreep and myHp >= 260 then
        -- Proactive Glyph before `allyT1` drops into sudden-death range!
        if info.allyT1Hp <= 650 and info.minDistT1 <= 420 and info.siegeCount >= 2 then
            if U.ShouldUseGlyphDefensive(bot, s.allyTowers) or (type(GetGlyphCooldown) == "function" and GetGlyphCooldown() == 0) then
                U.UseGlyph(bot)
            end
        end
        -- Only ignore T1 creep defense if we are literally mid-execution on a `< 260 HP` enemy within `<= 760u`!
        local finishingAdjacentKill = enemyVisible
            and (enemy:GetHealth() or 9999) <= 260
            and GetUnitToLocationDistance(bot, enemy:GetLocation()) <= 760
        if not finishingAdjacentKill then
            local fnt = P.GetFountain(bot)
            local defendSpot = info.allyT1Loc + (fnt - info.allyT1Loc):Normalized() * 185
            if hasSalve then
                local effEnLoc = enemyVisible and enemy:GetLocation()
                    or (((s.enemyAbsentFor or 99) < 4.5) and s.enemyLastLoc or nil)
                local dSpotToEn = effEnLoc and U.DistanceBetweenLocations(defendSpot, effEnLoc) or 9999
                if dSpotToEn >= 1180 and dBotT1 > 420 then
                    H.SmartMove(bot, defendSpot, 45, true)
                    return true
                end
                return false
            end

            -- `v7.9.19` (`9074666246.dem` `06:31.80..06:43.13` `61`-Flip `dT1 = 788.8 <-> 812.1` Oscillation &
            -- `RAD CREEP id=208` `dT1 = 697.5u` Aggro-Hijack + Catapult Counter-Push Fix!):
            --   1. Previously `if dBotT1 > 780 then H.SmartMove(bot, defendSpot, 50, true)` snapped SW at `812u` while
            --      `lasthit.lua` kited NE at `788u` (`61` consecutive `180 deg` reversals!). Now uses Schmitt-trigger
            --      hysteresis (`enter > 960u`, `release <= 680u`) AND NEVER pulls SW when `bot` is ALREADY on the
            --      Fountain side behind `allyT1` (`dBotFnt < dT1Fnt - 80`) kiting an aggroed creep out of `700u` T1 range!
            --   2. When a Siege Catapult (`info.siegeCatapult`) or Enemy Hero (`info.heroSiegingT1`) is hitting `allyT1`
            --      while `info.aggroHijackCreep` attacks `bot` inside `<= 725u` of `allyT1` (stealing Dota 2 Tower Priority #1!),
            --      either nuke `aggroHijackCreep` immediately OR step cleanly to `835u` toward Fountain (`> 730u` creep-to-T1)
            --      so `allyT1` immediately switches aggro onto the Catapult / Enemy Hero!
            --   3. Counter-push Siege Catapults & multi-creep sieges (`info.siegeCatapult ~= nil` or `allyT1Hp <= 1050`)
            --      instead of letting catapults deal `607` free tower damage while waiting for `allyT1Hp <= 650`!
            local bLocDef = bot:GetLocation()
            local dBotFntDef = U.DistanceBetweenLocations(bLocDef, fnt)
            local dT1FntDef = U.DistanceBetweenLocations(info.allyT1Loc, fnt)
            local botBehindOwnT1 = (dBotFntDef < dT1FntDef - 80) and (dBotT1 <= 980)
            if not botBehindOwnT1 then
                if dBotT1 > 960 then
                    State.t1SnapBackActive = true
                elseif dBotT1 <= 680 then
                    State.t1SnapBackActive = false
                end
                if State.t1SnapBackActive and dBotT1 > 680 then
                    H.SmartMove(bot, defendSpot, 50)
                    return true
                end
            else
                State.t1SnapBackActive = false
            end

            -- Priority A: Break Tower Priority #1 Aggro-Hijack (`id=208` at `697.5u` protecting Catapult + `346 HP` Enemy Hero!)
            if (info.siegeCatapult or info.heroSiegingT1) and info.aggroHijackCreep
                and U.CanQuery(info.aggroHijackCreep) and info.aggroHijackCreep:IsAlive() then
                local hijack = info.aggroHijackCreep
                if (bot:GetMana() or 0) >= 150 then
                    for _, lbl in ipairs({ "near", "mid", "far" }) do
                        local ab = H.GetRazeAbilityByLabel(bot, lbl)
                        if ab and U.IsRazeAbilityCastable(bot, ab) then
                            local act, aim = H.GetRazeActionType(bot, ab, hijack)
                            if act and H.CastOrTurnRaze(bot, ab, act, aim, hijack) then
                                return true
                            end
                        end
                    end
                end
                local pullOutSpot = info.allyT1Loc + (fnt - info.allyT1Loc):Normalized() * 835
                if U.DistanceBetweenLocations(hijack:GetLocation(), info.allyT1Loc) <= 725 then
                    H.SmartMove(bot, pullOutSpot, 35)
                    return true
                end
            end

            -- Priority B: Active Counter-Push on Siege Catapults & Tower-Threatening Waves (`0` missed CS on 1-hit creeps!)
            local csPlanT1, csEtaT1 = nil, 99
            if L.PeekBestPlan then
                csPlanT1, csEtaT1 = L.PeekBestPlan(bot, s)
            end
            local imminentLastHit = (csPlanT1 ~= nil) and (not csPlanT1.isDeny) and (csEtaT1 <= 0.65)
            local targetSiegeCreep = (info.siegeCatapult and U.CanQuery(info.siegeCatapult) and info.siegeCatapult:IsAlive())
                and info.siegeCatapult or info.nearestCreep
            local urgentClear = (not imminentLastHit) and (
                (info.allyT1Hp <= 950)
                or (info.siegeCatapult ~= nil)
                or (info.siegeCount >= 3 and info.allyT1Hp <= 1350)
                or (info.enemyCuttingBehindT1 and info.allyT1Hp <= 1350)
            )
            if urgentClear and targetSiegeCreep and U.CanQuery(targetSiegeCreep) and targetSiegeCreep:IsAlive() then
                local allowRazeClear = ((bot:GetMana() or 0) >= 160 and (info.siegeCount >= 2 or info.siegeCatapult ~= nil))
                    or (info.allyT1Hp <= 950 and (bot:GetMana() or 0) >= 75)
                if allowRazeClear then
                    local rTarget = info.nearestCreep or targetSiegeCreep
                    for _, lbl in ipairs({ "far", "mid", "near" }) do
                        local ab = H.GetRazeAbilityByLabel(bot, lbl)
                        if ab and U.IsRazeAbilityCastable(bot, ab) then
                            local act, aim = H.GetRazeActionType(bot, ab, rTarget)
                            if act and H.CastOrTurnRaze(bot, ab, act, aim, rTarget) then
                                return true
                            end
                        end
                    end
                end
                if GetUnitToLocationDistance(bot, targetSiegeCreep:GetLocation()) <= (bot:GetAttackRange() or 525) + 120 then
                    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= targetSiegeCreep then
                        bot:Action_AttackUnit(targetSiegeCreep, true)
                        H.ClearMoveCache()
                    end
                    State.actionTaken = true
                    return true
                end
                H.SmartMove(bot, targetSiegeCreep:GetLocation(), 55)
                return true
            end
        end
    end

    -- [RULE 2] ANTI-CREEP-CUT COLLAPSE & JUNGLE-BAIT LEASH (When `allyT1` Has No Enemy Creeps Hitting It)
    if info.enemyCuttingBehindT1 and info.cutTargetLoc and not hasSalve then
        -- If the cutter fled deep off-spine into side-jungle (`> 1,020u` lateral with `0` allied creeps), DO NOT chase!
        -- Return to `allyT1` so we catch 100% of the next wave and protect our tower.
        if info.enemyFledDeepJungle then
            if dBotT1 > 520 then
                H.SmartMove(bot, info.allyT1Loc, 55, true)
                return true
            end
            return false
        end

        if myHp >= 370 and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow) then
            if enemyVisible then
                if (bot:GetMana() or 0) >= 75 then
                    for _, lbl in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                        local ab = H.GetRazeAbilityByLabel(bot, lbl)
                        if ab and U.IsRazeAbilityCastable(bot, ab) then
                            local act, aim = H.GetRazeActionType(bot, ab, enemy)
                            if act and H.CastOrTurnRaze(bot, ab, act, aim, enemy) then
                                return true
                            end
                        end
                    end
                end
                local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
                local enHasQ = K.EnemyRazeReady("near", 1.2) and (K.EnemyManaBudget(enemy, true) >= 75)
                if enHasQ and dHero < 485 and (enemy:GetHealth() or 9999) > 290 and myHp < (enemy:GetHealth() or 9999) + 120 then
                    local awayDir = (bot:GetLocation() - enemy:GetLocation()):Normalized()
                    H.SmartMove(bot, enemy:GetLocation() + awayDir * 510, 30, true)
                    return true
                end
                if dHero <= (bot:GetAttackRange() or 525) + 65 then
                    if H.IssueHeroAttack(bot, enemy) then
                        State.actionTaken = true
                        return true
                    end
                end
                local approachDir = (info.allyT1Loc - enemy:GetLocation()):Normalized()
                local standoff = enHasQ and 495 or 430
                H.SmartMove(bot, enemy:GetLocation() + approachDir * standoff, 45, true)
                return true
            else
                if GetUnitToLocationDistance(bot, info.cutTargetLoc) > 360 then
                    H.SmartMove(bot, info.cutTargetLoc, 50, true)
                    return true
                end
            end
        end
    end

    return false
end

-- Unified Top-Priority Executioner & Throne-Grade Mid T1 Defender (`BAR 4:10` + `BAR 5:09` + `BAR 6:12` + `BAR 9:10`):
--   1. `BAR 9:10` (`allyT1 <= 420 HP` Sudden-Death Defense): Glyph immediately, override Salve/Fountain flight,
--      pop Mango/Stick, nuke/kill any hero hitting our low-HP T1 (`552 HP` ShaNachnetsya @ `tk=21334`), and clear siege/creeps!
--   2. `BAR 4:10` (`ShaNachnetsya` `186 HP` Dire T1 Dive): Never run away while friendly T1 is shooting a tower diver —
--      pop Mango/Stick if needed, land covering Shadowraze + right-click under friendly T1 aura to execute 100% of divers!
--   3. `BAR 5:09` (`108 -> 212 HP`) & `BAR 6:12` (`283 HP` at `340u`): Immediately pop Mango/Stick and finish low-HP enemy SF!
function H.HandleCriticalAllyT1AndDivePunish(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local myHp = bot:GetHealth() or 0
    local enemy = s and s.enemy
    local t1Danger, allyT1, allyT1Loc = H.IsAllyT1InSuddenDeathDanger(bot, s)

    -- [1] THRONE-GRADE FRIENDLY MID T1 DEFENSE (`BAR 9:10`, `allyT1 HP <= 420`)
    if t1Danger and allyT1 and allyT1Loc and myHp > 110 then
        State.goingToFountain = false
        State.fountainReason = nil
        State.emergencyRetreat = nil
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if U.ShouldUseGlyphDefensive(bot, s.allyTowers) then
            U.UseGlyph(bot)
        end
        if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
            return true
        end
        -- Priority 1A: Enemy hero approaching/attacking our `< 420 HP` Mid T1 -> defend cleanly (from safe `E700` spacing when losing!)
        if enemy and U.CanQuery(enemy) and U.DistanceBetweenLocations(allyT1Loc, enemy:GetLocation()) <= 1120 then
            local lethalWalkInDanger = (myHp <= 290 and K.EnemyManaBudget(enemy, true) >= 75)
                or (earlyRace and earlyRace.valid and earlyRace.heCanKillNow and not earlyRace.canKillNow)
            for _, label in ipairs({ "far", "mid", "near" }) do
                if not (lethalWalkInDanger and label == "near") then
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.commitKillUntil = GameTime() + 2.5
                            return true
                        end
                    end
                end
            end
            local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
            if not lethalWalkInDanger and dHero <= (bot:GetAttackRange() or 525) + 55 then
                if H.IssueHeroAttack(bot, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
            local fntDef = P.GetFountain(bot)
            local stepTarget = lethalWalkInDanger
                and (allyT1Loc + (fntDef - allyT1Loc):Normalized() * 340)
                or (enemy:GetLocation() + (allyT1Loc - enemy:GetLocation()):Normalized() * 440)
            H.SmartMove(bot, stepTarget, 35, true)
            return true
        end
        -- Priority 1B: Enemy creeps threatening `< 420 HP` Mid T1 -> blast cluster with Raze & right-click!
        local urgentCreep, urgentDist = nil, math.huge
        local t1CreepPool = (s and s.enemyCreepsNearAllyT1 and #s.enemyCreepsNearAllyT1 > 0)
            and s.enemyCreepsNearAllyT1
            or ((s and s.enemyCreeps) or {})
        for _, c in pairs(t1CreepPool) do
            if U.CanQuery(c) and c:IsAlive() then
                local dc = U.DistanceBetweenLocations(allyT1Loc, c:GetLocation())
                if dc < urgentDist then
                    urgentDist, urgentCreep = dc, c
                end
            end
        end
        for _, c in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(c) and c:IsAlive() then
                local dc = U.DistanceBetweenLocations(allyT1Loc, c:GetLocation())
                if dc < urgentDist then
                    urgentDist, urgentCreep = dc, c
                end
            end
        end
        if urgentCreep then
            if (bot:GetMana() or 0) >= 75 then
                for _, label in ipairs({ "far", "mid", "near" }) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, urgentCreep)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, urgentCreep) then
                            return true
                        end
                    end
                end
            end
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= urgentCreep then
                bot:Action_AttackUnit(urgentCreep, true)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end

    -- [2] ENEMY TOWER-DIVER EXECUTIONER (`BAR 4:10` + `04:38` & `1343 @ 05:37..05:47` Allied `T1` + `T2` + Offensive Glyph Fix!)
    local myT1 = s and s.allyT1
    local myT2 = (type(GetTower) == "function" and TOWER_MID_2) and GetTower(bot:GetTeam(), TOWER_MID_2) or nil
    local diveTower = myT1
    if myT2 and U.CanQuery(myT2) and myT2:IsAlive() then
        local okL2, t2Loc = pcall(myT2.GetLocation, myT2)
        if okL2 and t2Loc then
            local dEnT2 = U.DistanceBetweenLocations(t2Loc, enemy:GetLocation())
            local dEnT1Chk = (myT1 and U.CanQuery(myT1) and myT1:IsAlive())
                and U.DistanceBetweenLocations(myT1:GetLocation(), enemy:GetLocation()) or 9999
            if dEnT2 <= 920 or dEnT2 < dEnT1Chk then
                diveTower = myT2
            end
        end
    end
    local enManaDive = K.EnemyManaBudget(enemy, true)
    local enemyZeroCoilDive = (enManaDive < 75) or (K.EnemyReadyRazeCount(enemy, 0.7, true) == 0)
    local minDivePunishHp = enemyZeroCoilDive and 105 or 195
    local myDryInTwoRazeLethal = (not enemyZeroCoilDive)
        and (K.MyManaBudget(bot, true) < 75)
        and ((enemy:GetHealth() or 9999) > 260)
        and (myHp <= K.EnemyCastableRazeDamage(bot, enemy, 2, nil, 2.2) + K.AttackDamageVs(enemy, bot) + 45)
    if diveTower and myHp >= minDivePunishHp and not myDryInTwoRazeLethal
        and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow and not enemyZeroCoilDive) then
        local okA, tAlive = pcall(diveTower.IsAlive, diveTower)
        local okL, tLoc = pcall(diveTower.GetLocation, diveTower)
        if okA and tAlive and okL and tLoc then
            local fnt = P.GetFountain(bot)
            local dEnT1 = U.DistanceBetweenLocations(tLoc, enemy:GetLocation())
            local pastOurT1 = U.DistanceBetweenLocations(enemy:GetLocation(), fnt) <= U.DistanceBetweenLocations(tLoc, fnt) + 95
                and dEnT1 <= 1650
            if dEnT1 <= 830 or pastOurT1 then
                local okT, tTgt = pcall(diveTower.GetAttackTarget, diveTower)
                -- `1343 @ 05:37.80` Enemy Offensive Glyph T1 Aggro-Lock Check:
                -- When enemy creeps under our tower carry `modifier_fountain_glyph` (`7.0s` invulnerability),
                -- our tower is locked onto immortal creeps and deals `0` DPS to `enemy` unless `tTgt == enemy`!
                local glyphedCreepLock = false
                if not (okT and tTgt == enemy) then
                    for _, ecG in pairs((s and s.enemyCreeps) or {}) do
                        if ecG and U.CanQuery(ecG) and ecG:IsAlive()
                            and U.DistanceBetweenLocations(tLoc, ecG:GetLocation()) <= 780
                            and ecG.HasModifier and ecG:HasModifier("modifier_fountain_glyph") then
                            glyphedCreepLock = true
                            break
                        end
                    end
                end
                local lrDive = U.SolveLethalRace(bot, enemy, s)
                -- `auto-20261023-0119` Death #1 (`04:24.97` `384 HP` vs `978 HP` + 7 creeps past Radiant T1) Fix:
                -- NEVER blindly stand and fight a near-full-HP enemy + full wave behind our T1 unless our T1 is ACTUALLY
                -- shooting him (`tTgt == enemy` with survival margin), OR `SolveLethalRace` wins, OR we match his HP!
                local safePastT1 = pastOurT1 and (not glyphedCreepLock) and (
                    (okT and tTgt == enemy and myHp >= K.EnemyBurstVs(bot, enemy, dEnT1, 1.0, false) + 75)
                    or (lrDive and lrDive.winsFirstKill and lrDive.tKillHim <= 2.5)
                    or ((enemy:GetHealth() or 9999) <= 465 and myHp >= 250)
                    or (myHp >= 360 and myHp >= (enemy:GetHealth() or 9999) * 0.58)
                )
                -- `9069188041.dem` `02:11.8` + `auto-20261031-0230` `02:09.1` (`tk=8002`) Root-Cause Fix:
                --   1. When enemy creeps tank our T1 (`tTgt ~= enemy`), our T1 deals ZERO DPS to `enemy` — NEVER treat an
                --      enemy standing behind his creeps at `393u` as a "tower diver" when we are low HP (`< 260 HP`)!
                --   2. At low HP (`< 235 HP`), NEVER clear `ForcedRetreat` or self-root `0.55s` inside enemy attack range
                --      unless `SolveLethalRace` (`lrDive.winsFirstKill`) proves we kill him BEFORE his autos kill us!
                local winsDiveRace = (lrDive and lrDive.winsFirstKill and lrDive.tKillHim <= 2.5) or false
                local towerActuallyOnEnemy = (okT and tTgt == enemy)
                    or ((not glyphedCreepLock) and #(s.enemyCreeps or {}) == 0 and dEnT1 <= 695)
                local towerShootingHim = (towerActuallyOnEnemy and (myHp >= 235 or winsDiveRace))
                    or safePastT1
                local lowEnemyUnderT1 = towerActuallyOnEnemy
                    and (myHp >= 255 or winsDiveRace)
                    and ((dEnT1 <= 755 and (enemy:GetHealth() or 9999) <= 465)
                        or (dEnT1 <= 830 and (((bot:GetMana() or 0) >= 75 and (enemy:GetHealth() or 9999) <= 420) or (enemy:GetHealth() or 9999) <= 260)))
                local farSafeDiveCoil = (myHp >= 115)
                    and (GetUnitToLocationDistance(bot, enemy:GetLocation()) >= (enemy:GetAttackRange() or 525) + 85)
                    and (winsDiveRace or (towerActuallyOnEnemy and myHp >= 185))
                if towerShootingHim or lowEnemyUnderT1 or farSafeDiveCoil then
                    H.ClearForcedRetreat()
                    State.fleeUntil = 0
                    if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
                        State.commitKillUntil = GameTime() + 2.0
                        return true
                    end
                    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
                    local oneRazeDmg = K.MyRazeDamage(bot, enemy, 1)
                    local lastAtkDt = GameTime() - (bot:GetLastAttackTime() or -100)
                    local spa = bot:GetSecondsPerAttack() or 1.2
                    local alreadySwingingHero = (U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemy)
                    -- `W5 07:07.5` (`265 HP / 67 MP` stepped to `304u` inside Lvl 4 `Q = 450u` under Dire T1!) Fix:
                    -- When enemy SF has `Q` (`near`, `0..450u`) available and `myHp` is in `Q + Auto` danger,
                    -- NEVER stand inside `< 495u` — kite to `515u` max attack range toward `fnt` while our T1 shoots him!
                    local enNearThreat = (not enemyZeroCoilDive)
                        and (K.EnemyRazeReadyIn("near") <= 1.2)
                        and (myHp <= K.EnemyRazeDamage(bot, enemy, 1) + K.AttackDamageVs(enemy, bot) + 65)
                    if enNearThreat and dHero < 495 and oneRazeDmg < (enemy:GetHealth() or 9999) then
                        local kiteDir = (fnt - enemy:GetLocation()):Normalized()
                        local kiteSpot = enemy:GetLocation() + kiteDir * 520
                        H.SmartMove(bot, kiteSpot, 25, true)
                        State.commitKillUntil = GameTime() + 1.5
                        return true
                    end
                    local swingRange = alreadySwingingHero
                        and ((bot:GetAttackRange() or 525) + 215)
                        or ((bot:GetAttackRange() or 525) + 35)
                    if myHp >= 235 and oneRazeDmg < (enemy:GetHealth() or 9999)
                        and dHero <= swingRange
                        and lastAtkDt >= spa * 0.80 then
                        if not alreadySwingingHero then
                            bot:Action_AttackUnit(enemy, true)
                            H.ClearMoveCache()
                        end
                        State.commitKillUntil = GameTime() + 2.0
                        State.actionTaken = true
                        return true
                    end
                    local canSafelyCastDiveRaze = winsDiveRace
                        or (oneRazeDmg + K.AttackDamageVs(bot, enemy) >= (enemy:GetHealth() or 9999))
                        or (dHero >= (enemy:GetAttackRange() or 525) + 65 and myHp >= 185)
                        or (myHp >= 245)
                    if canSafelyCastDiveRaze then
                        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                            local ab = H.GetRazeAbilityByLabel(bot, label)
                            if ab and U.IsRazeAbilityCastable(bot, ab) then
                                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                                    State.commitKillUntil = GameTime() + 2.0
                                    return true
                                end
                            end
                        end
                    end
                    if myHp >= 210 and dHero <= (bot:GetAttackRange() or 525) + 60 then
                        if H.IssueHeroAttack(bot, enemy) then
                            State.commitKillUntil = GameTime() + 2.0
                            State.actionTaken = true
                            return true
                        end
                    elseif myHp >= 260 and dHero <= 950 then
                        local safeHoldDist = (enNearThreat or (bot:GetMana() or 0) < 75 or myHp < 430) and 515 or 445
                        local refDir = (enNearThreat or safeHoldDist >= 500)
                            and (fnt - enemy:GetLocation()):Normalized()
                            or (tLoc - enemy:GetLocation()):Normalized()
                        local setup = enemy:GetLocation() + refDir * safeHoldDist
                        H.SmartMove(bot, setup, 35, true)
                        return true
                    end
                end
            end
        end
    end

    -- [3] CRITICAL LOW-HP ENEMY FINISH (`BAR 5:09`, `BAR 6:12`, `3:58` 2-Hit Zero-Mana Right-Click Kill, & `5:28` Centered `E`!)
    local enHp = enemy:GetHealth() or 9999
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local underUnsafeEnemyT1 = false
    local botInsideUnsafeEnemyT1 = false
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and not H._hasTankCreepUnderTower(tw, s.allyCreeps) then
            if GetUnitToLocationDistance(tw, enemy:GetLocation()) < 740 then
                underUnsafeEnemyT1 = true
            end
            if GetUnitToLocationDistance(tw, bot:GetLocation()) <= 885 then
                botInsideUnsafeEnemyT1 = true
            end
        end
    end

    -- Pure TTK Race Lethal Override (`0119` `00:24.83` @ `42 HP` & `05:25.43` @ `90 HP` + `9055695956.dem` `3:58` @ `91 HP`):
    -- Uses exact `U.SolveLethalRace` `[0, tKillHim + 0.15s]` first-kill physics so SF NEVER aborts a winning kill at `< 195 HP`!
    local lrCrit = U.SolveLethalRace(bot, enemy, s)
    local myPhysHit = math.max(38, K.AttackDamageVs(bot, enemy))
    if not underUnsafeEnemyT1
        and ((lrCrit and lrCrit.winsFirstKill and lrCrit.tKillHim <= 2.35 and dHero <= math.max((bot:GetAttackRange() or 525) + 155, 880))
            or (enHp <= myPhysHit * 2.25
                and dHero <= (bot:GetAttackRange() or 525) + 135
                and myHp >= math.max(195, K.EnemyBurstVs(bot, enemy, dHero, 1.5, false) + 55))) then
        if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then
            return true
        end
    end

    local myPotMana = H.GetPotentialCombatMana(bot)
    local oneMyRaze = K.MyRazeDamage(bot, enemy, 1)
    local canFinishLow = (enHp <= math.max(275, oneMyRaze * 1.58) and myHp >= 290 and myPotMana >= 75)
        or (enHp <= 335 and myHp >= 420 and myPotMana >= 75 and dHero <= 680)
    -- Casting Shadowraze from outside tower range (`not botInsideUnsafeEnemyT1`) triggers ZERO tower aggro in Dota 2!
    if canFinishLow and dHero <= 965 and not botInsideUnsafeEnemyT1
        and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow) then
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.0
            return true
        end
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.commitKillUntil = GameTime() + 2.0
                    return true
                end
            end
        end
        if not underUnsafeEnemyT1 and dHero <= (bot:GetAttackRange() or 525) + 55 then
            if H.IssueHeroAttack(bot, enemy) then
                State.commitKillUntil = GameTime() + 2.0
                State.actionTaken = true
                return true
            end
        elseif not underUnsafeEnemyT1 and K.CanCatch(bot, enemy, 660, 2.0) then
            local setup = U.GetRazeSetupPosition(bot, enemy)
            if setup and H.ApproachEnemyPoint(bot, enemy, setup, 35, s.enemyTowers, s.allyCreeps) then
                return true
            end
        end
    end

    return false
end

function H.CanTwoHitRightClickKill(bot, enemy, s)
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(tw, enemy:GetLocation()) < 740
            and not H._hasTankCreepUnderTower(tw, s.allyCreeps) then
            return false
        end
    end
    local lr = U.SolveLethalRace(bot, enemy, s)
    if lr and lr.winsFirstKill and lr.tKillHim <= 2.35 and dHero <= math.max((bot:GetAttackRange() or 525) + 155, 880) then
        return true
    end
    -- `v7.9.8-pro` (`1630 @ 01:32.6..01:36.2` `3–28 HP` 1-Shot vs `156 HP` Bot Fix!):
    -- Never let `InCriticalLethalDanger` force-retreat away from a literal 1-shot enemy within `<= 775u` when we tank his burst!
    if U.CanOneShotEnemyHero(bot, enemy)
        and dHero <= (bot:GetAttackRange() or 525) + 250
        and (bot:GetHealth() or 0) >= K.EnemyBurstVs(bot, enemy, math.min(dHero, 500), 1.15, false) + 8 then
        return true
    end
    if dHero > (bot:GetAttackRange() or 525) + 135 then return false end
    local myPhysHit = math.max(38, K.AttackDamageVs(bot, enemy))
    local bLocTwo = bot:GetLocation()
    local eLocTwo = enemy:GetLocation()
    -- `9074178342.dem` `04:20.47..04:25.27` (`tk=10860..11004` `140..168 HP` + `Faerie Fire` + `z_diff=+123u` + `5` Creeps Fix!):
    -- Account for enemy instant burst heal (`Faerie Fire +85` + `Magic Stick/Wand` charges), `25%` Source 2 uphill miss penalty
    -- (`z_diff >= 85u`), and `500u` enemy creep-pack aggro when shooting uphill from river lowground!
    local uphillTwo = ((eLocTwo.z or 0) - (bLocTwo.z or 0)) >= 85
    local effPhysHit = uphillTwo and (myPhysHit * 0.75) or myPhysHit
    local enRawHp = enemy:GetHealth() or 9999
    local enEffHp = enRawHp
        + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy)) or 0)
        + ((U.GetStickCharges and U.GetStickCharges(enemy, false) or 0) * 15)
    if enEffHp > effPhysHit * 2.25 then return false end
    local uphillCreepTax = 0
    if uphillTwo and s and s.enemyCreeps then
        local nearEC = 0
        for _, ec in pairs(s.enemyCreeps) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(bLocTwo, ec:GetLocation()) <= 500 then
                nearEC = nearEC + 1
            end
        end
        if nearEC >= 3 then uphillCreepTax = nearEC * 24 end
    end
    local enNoRaze = K.EnemyCastableRazeCount(enemy, 1.5) == 0
    local minSafeFloor = (enNoRaze and 130 or 195) + uphillCreepTax
    return (bot:GetHealth() or 0) >= math.max(minSafeFloor, K.EnemyBurstVs(bot, enemy, dHero, 1.5, false) + 50 + uphillCreepTax)
end

-- Stage A (ABOVE RunSacredCS): Strictly prevents stopping/turning back for a creep last-hit when 1-2 hits
-- or an immediate enemy cast away from death while NEVER interrupting normal 0.000s-0.033s CS!
-- Uses Schmitt-trigger hysteresis (`+85u` exit margin) so we NEVER bang-bang stall at the boundary!
function H.InCriticalLethalDanger(bot, s, race)
    local myHp = bot:GetHealth() or 0
    local enemy = s and s.enemy
    local now = GameTime()

    -- Critical low-HP protection vs ACTUALLY AGGROED lane creeps (`R2_2044` `03:25..03:31.33` `@420u` Freeze Fix!):
    -- When `s.enemyAlive == false` (`ShaNachnetsya` just died at `03:20`!), unaggroed enemy creeps fighting our own wave
    -- at `417u` (`c:GetAttackTarget() ~= bot`) MUST NEVER paralyze SF at `@420u` until passive regen ticks `155 -> 156 HP`!
    if myHp <= 155 then
        local nearAggroCreeps = 0
        local noAllyShield = #(s and s.allyCreeps or {}) == 0
        for _, c in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(c) and c:IsAlive() then
                if c:GetAttackTarget() == bot or (noAllyShield and GetUnitToLocationDistance(bot, c:GetLocation()) <= 230) then
                    nearAggroCreeps = nearAggroCreeps + 1
                end
            end
        end
        if nearAggroCreeps >= 1 then
            State.critDangerHystUntil = now + 0.75
            return true
        end
    end

    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        -- `9069188041.dem` `03:44.1` FoW Tree-Juke Persistence Fix:
        -- When a live enemy hero ducks behind SE trees within `<= 960u` for `<= 3.0s` while we are at `<= 215 HP`,
        -- DO NOT drop critical danger and walk back into the river/trees!
        if s and s.enemyAlive ~= false and (s.enemyAbsentFor or 99) <= 3.0 and s.enemyLastLoc
            and myHp <= 215 and GetUnitToLocationDistance(bot, s.enemyLastLoc) <= 960 then
            State.critDangerHystUntil = now + 0.55
            return true
        end
        return false
    end
    if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local enRange = (enemy:GetAttackRange() or 525)
    local valid = race and race.valid
    local enCastable = K.EnemyCastableRazeCount(enemy, 2.2)
    if valid and (race.canKillNow
        or (race.canKillSoon and enCastable == 0 and dist > enRange + 30)
        or (race.canKillSoon and not race.heCanKillNow and myHp > K.EnemyBurstVs(bot, enemy, dist, 0.65, false) + 45)) then
        return false
    end
    local hystPad = (now < (State.critDangerHystUntil or -100)) and 85 or 0
    local oneRaze = K.EnemyCastableRazeDamage(bot, enemy, 1, nil, 2.2)
    local oneRazeSoon = K.EnemyCastableRazeDamage(bot, enemy, 1, nil, 3.8)
    local twoRaze = K.EnemyCastableRazeDamage(bot, enemy, 2, nil, 2.2)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local outMatched = valid and (race.heHasBootsLead or ((enemy:GetLevel() or 1) > (bot:GetLevel() or 1)))
    -- `9070869385.dem` `05:06.2–05:09.8` `685u` Bullseye Trap Fix + `auto-20261102-0007` `10:12.07` (`163 HP` @ `d=905u`,
    -- `raze3` CD `2.3s` -> `898u` Death) Fix:
    -- When literally ONE `Shadowraze3` (`950u` reach) kills us within `3.8s` (`oneRazeLethalSoon`), NEVER drop
    -- `safeRadiusForHp` below `1,065u` just because `far` still has `1.6..3.8s` left on cooldown!
    local farOnCdCrit = K.EnemyRazeReadyIn("far") > 1.5
    local farReadySoonLethal = (K.EnemyRazeReadyIn("far") <= 3.8)
        and (K.EnemyManaBudget(enemy, true) >= 75)
        and (myHp <= oneRazeSoon + 55)
    local safeRadiusForHp
    if enCastable == 0 and not farReadySoonLethal then
        -- Manaless/0-coil enemy (`10-18 MP` in `9069188041.dem` `03:39-03:49`): threat reach is ONLY his right-click!
        safeRadiusForHp = enRange + ((myHp <= 165) and 175 or 135) + hystPad
    elseif myHp <= oneRaze + 45 or myHp <= 155 or farReadySoonLethal then
        safeRadiusForHp = math.max(1065, enRange + 420, (race and race.minSafeDist or 960) + 60) + hystPad
    elseif outMatched and myHp <= twoRaze + enAtk * 1.15 then
        safeRadiusForHp = (farOnCdCrit and math.min(735, math.max(620, K.EnemyMinSafeDistance(enemy, 0.8))) or 965) + hystPad
    elseif myHp <= twoRaze + 35 then
        safeRadiusForHp = (farOnCdCrit and math.min(725, math.max(590, K.EnemyMinSafeDistance(enemy, 0.8))) or 955) + hystPad
    else
        safeRadiusForHp = enRange + 145 + hystPad
    end

    -- Stage A runs BEFORE `RunSacredCS`: trigger ONLY on genuine short-horizon (`<= 1.25s`) lethal threat!
    -- Include ACTUAL aggroed enemy lane creep DPS (`auto-20261031-0230` `00:59.3-01:02.1` Fix: `3` Radiant creeps = `45 DPS`,
    -- and `177 HP > 175 HP` let Lvl-1 Bot re-enter `d=87u` vs Lvl-2 Human + 3 melee creeps!).
    local aggroCreepDps = 0
    local noAllyShieldCrit = #(s and s.allyCreeps or {}) == 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() then
            local dcCrit = GetUnitToLocationDistance(bot, ec:GetLocation())
            if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (noAllyShieldCrit and dcCrit <= 225) then
                local ecRange = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                aggroCreepDps = aggroCreepDps + ((ecRange > 300) and 14 or 15)
            end
        end
    end
    local myStNow, myRemNow = U.GetShadowrazeDebuff(bot)
    local enAppNow = U.EnemyApproachSpeed(bot, enemy)
    local burstHorizon = (dist >= 645 and enAppNow < 65 and (myStNow or 0) <= 1 and myHp >= 390 and K.EnemyRazeReadyIn("far") > 4.0) and 0.65 or 1.25
    local burst125 = K.EnemyBurstVs(bot, enemy, dist, burstHorizon, false) + aggroCreepDps * burstHorizon
    local burstSafetyMargin = enAtk * 0.90
    local enManaPoolCrit = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local domPostureCrit = K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, s)
    if (myStNow or 0) >= 1 and (myRemNow or 0) > 0.10 and (myRemNow or 0) <= 2.15
        and enManaPoolCrit >= 75 and not domPostureCrit
        and ((myStNow or 0) >= 2 or myHp <= twoRaze + 145)
        and not (valid and (race.canKillNow or race.canKillSoon)) and dist < 955 then
        State.critDangerHystUntil = now + 0.45
        return true
    end
    local myPotManaCrit = (bot:GetMana() or 0) + U.GetMangoMana(bot)
    -- `v7.9.10-pro` (`2048 @ 04:41..04:56` `335 -> 179 HP` Dry-Mana `< 75 MP` Outer-`E` Standoff Fix!):
    -- 1. NEVER treat `dominatingOneCoilTrade` as true when we have `< 75 MP` (`0` coils) outside right-click range (`dist > enRange + 55`),
    --    where enemy SF gets a 100% free `700u` `Shadowraze3` without taking a single right-click back!
    -- 2. When we have `0` coils (`myPotManaCrit < 75`), enemy SF has `>= 75 MP` + `far` ready (`<= 1.5s`), and 1 coil + follow-up
    --    auto puts us into lethal (`myHp <= oneRaze + enAtk * 2.2 + 80`), maintain strict `>= 985u` outer-`E` standoff!
    if myPotManaCrit < 75 and enManaPoolCrit >= 75 and not farOnCdCrit
        and myHp <= (oneRaze + enAtk * 2.2 + 80)
        and not (valid and race.canKillNow)
        and dist < 985 then
        State.critDangerHystUntil = now + 0.55
        return true
    end
    local dominatingOneCoilTrade = (enManaPoolCrit < 150)
        and myHp >= 380
        and (myPotManaCrit >= 75 or dist <= enRange + 55)
        and aggroCreepDps <= 15
        and not outMatched
        and not (valid and race.heCanKillNow)
        and K.AttackDamageVs(bot, enemy) >= enAtk + 12
    if valid and not race.canKillSoon and not dominatingOneCoilTrade
        and (race.heCanKillNow or ((myHp - burst125) <= burstSafetyMargin))
        and dist < safeRadiusForHp then
        State.critDangerHystUntil = now + 0.55
        return true
    end
    local closeHpFloor = math.max(195, enAtk * (outMatched and 2.85 or 2.45) + aggroCreepDps * 1.65)
    if dist < safeRadiusForHp and (myHp <= closeHpFloor or farReadySoonLethal) then
        State.critDangerHystUntil = now + 0.65
        return true
    end
    -- `v7.9.12-pro` (`2319 @ 06:34.67..06:36.00` `345/1050 HP` Behind-`allyT1` Flank Cut-Off Protection!):
    -- When a healthier, armed enemy SF (`enManaPoolCrit + 8 >= 140` or `enCastable >= 1`) flanks around/past our `allyT1`
    -- (`d(eLoc, fnt) <= d(allyT1, fnt) + 450` and skirting outside `allyT1`'s `700u` range `d(eLoc, allyT1) > 685`) while we
    -- are wounded (`myHp <= 420` or `hpPct <= 0.40`), NEVER let `RunSacredCS` pull us SW into the flanker (`dist < 1,030u`)!
    if s and s.allyT1Alive and s.allyT1Loc and not (valid and (race.canKillNow or race.canKillSoon)) then
        local fntFlank = P.GetFountain(bot)
        local eLocFlank = enemy:GetLocation()
        local myMaxFlank = math.max(1, bot:GetMaxHealth() or 700)
        local dEnT1Flank = U.DistanceBetweenLocations(eLocFlank, s.allyT1Loc)
        local dEnFntFlank = U.DistanceBetweenLocations(eLocFlank, fntFlank)
        local dT1FntFlank = U.DistanceBetweenLocations(s.allyT1Loc, fntFlank)
        if (myHp <= 420 or (myHp / myMaxFlank) <= 0.40)
            and ((enemy:GetHealth() or 999) > myHp + 200)
            and (enManaPoolCrit + 8 >= 140 or enCastable >= 1)
            and dEnT1Flank > 685 and dEnT1Flank <= 1450
            and dEnFntFlank <= (dT1FntFlank + 780)
            and dist < 1030 then
            State.critDangerHystUntil = now + 0.65
            return true
        end
    end
    return false
end

-- Stage B (IMMEDIATELY BELOW RunSacredCS, ABOVE ALL OFFENSIVE COMBAT HANDLERS):
-- Also immediately kites back out of river lowground (`uphillPenalty`) / multi-creep aggro when enemy SF
-- auto-attacks us at early levels (`0:00` opening `HUD 01:01-01:08` 6-unanswered-autos fix)!
-- Stage B0 (`9055695956.dem` `0:00` `tk=4064` Even-Footing Anti-Conveyor Counter-Raze & `1:52` `tk=6360` Dry-Enemy Punish):
--   1. When enemy SF lands an opening coil/close trade (`myStacks >= 1` or close hero hit) while we are healthy on mana & HP
--      and behind on stacks (`enStacks < max(1, myStacks)`), NEVER run backward down his `200->450->700u` triple-raze ray
--      unanswered — immediately fire our best-centered counter-Shadowraze (`Q`/`W`/`E`) FIRST to equalize stacks!
--   2. When enemy hero is completely DRY on mana (`enemy:GetMana() < 75` => `0` counter-razes possible, `1:52` `SHA MP=20`)
--      and we hold `>= 135 MP` with no imminent creep CS, punish his walk-up immediately with our dead-center coil!
function H.HandleMirrorRazeCounterAndDryPunish(bot, s, earlyRace, csWaveBusy)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    -- Note: allow `< 75 MP` entry at top of `HandleMirrorRazeCounterAndDryPunish` so proactive `Mango`/`Wand` top-up & Salve break run!
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 then return false end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local twoEnRaze = K.EnemyRazeDamage(bot, enemy, 2)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local unsafeSoon = earlyRace and earlyRace.valid and earlyRace.heCanKillSoon
    if earlyRace and earlyRace.valid and earlyRace.heCanKillNow then return false end

    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0
    local enStacks = U.GetShadowrazeDebuff(enemy) or 0
    local recentlyHit = (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.35)) or false

    local myMana = bot:GetMana() or 0

    -- Immediate Enemy `modifier_flask_healing` Cancel (`0050` `01:44.5`: enemy healed `395 HP` right in front of us at `796u`!):
    if enemy:HasModifier("modifier_flask_healing") and danger == 0
        and myHp > K.EnemyBurstVs(bot, enemy, dHero, 0.9, false) + 85 then
        if dHero <= (bot:GetAttackRange() or 500) + 175 then
            if H.IssueHeroAttack(bot, enemy) then
                State.actionTaken = true
                return true
            end
        elseif dHero <= 935 then
            if myMana < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            return true
                        end
                    end
                end
            end
        end
    end

    if myMana < 75 and K.MyReadyRazeCount(bot, true) < 1 then return false end

    local outRazedTier = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local nearSpike = (earlyRace and earlyRace.valid and earlyRace.nearLevelSpike)
        or (U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy)) or false

    -- Even-footing mirror answer ONLY on a FRESH opening hit (`myRem > 2.2` for 6.0s 7.41f debuff, NEVER when out-razed in tier!)
    -- Bracer-invariant HP check (`0.44 * maxHp` instead of `0.66 * maxHp`, which demanded `697 HP` with `2x Bracer` at `03:14`!)
    local mirrorCounter = (not unsafeSoon)
        and (not outRazedTier)
        and (not nearSpike)
        and (myHp >= twoEnRaze + enAtk * 1.65 + 55)
        and (myHp >= myMaxHp * 0.44)
        and ((myStacks >= 1 and myRem > 2.2) or (recentlyHit and dHero <= 440))
        and (enStacks < math.max(1, myStacks))
        and myHp >= (enemy:GetHealth() or 9999) * 0.58
        and dHero <= 915

    local approachSpd = U.EnemyApproachSpeed(bot, enemy)
    local outMatchedRunDown = (((enemy:GetLevel() or 1) > (bot:GetLevel() or 1))
        or (earlyRace and earlyRace.valid and earlyRace.heHasBootsLead))
        and approachSpd >= 95
        and myHp < (twoEnRaze + enAtk * 1.6 + 65)

    local enImmediateBurst = K.EnemyBurstVs(bot, enemy, dHero, 0.80, false)
    -- Patch 7.41f: `modifier_nevermore_shadowraze_debuff` starts at `6.000s` (`myRem > 4.35` = hit within last `1.65s`!)
    local farRazeReciprocity = (dHero >= 645 and dHero <= 925)
        and danger == 0
        and not outMatchedRunDown
        and (not outRazedTier or myHp >= twoEnRaze + 140)
        and myHp > enImmediateBurst + 95
        and ((K.EnemyRazeReadyIn("far") > 4.5 and (not csWaveBusy or (myStacks >= 1 and myRem > 4.35)))
            or (myStacks >= 1 and myRem > 4.35 and enStacks < myStacks))

    -- Case B (`Proactive Step-In Edge Intercept`): `U.FacingCos` now implemented in `utils.lua`!
    local enFacingMe = (U.FacingCos and U.FacingCos(enemy, bot:GetLocation()) or 0) >= 0.78
    local proactiveEdgeIntercept = (not csWaveBusy)
        and (not unsafeSoon)
        and (not outRazedTier)
        and (not nearSpike)
        and danger == 0
        and not outMatchedRunDown
        and myStacks == 0
        and dHero >= 695 and dHero <= 905
        and approachSpd > 50
        and enFacingMe
        and myHp > K.EnemyRazeDamage(bot, enemy, 1) + 155
        and enStacks >= myStacks

    -- `< 75 MP` enemy SF has ZERO coils available in reply (`9056469656.dem` `01:42–02:02` `SHA MP = 12..44`, `Bot MP = 97..131`!):
    -- punish any walk-up immediately with our dead-center coil whenever we hold `>= 75 MP` and survive physical reply!
    local enTotalMana = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local dryEnemyPunish = (not csWaveBusy)
        and (not unsafeSoon)
        and danger == 0
        and (enTotalMana < 75)
        and myMana >= 75
        and myHp >= math.max(215, enAtk * 2.7 + 45)
        and dHero <= 915

    -- Zero-turn facing-verified defensive stack equalizer (refines `hgfhgh` `HandleStackedDefensiveRaze` WITHOUT
    -- its blind backward-cast bug): when we ALREADY face `enemy` (`angleDiff <= MAX_ANGLE_TO_CAST`, `0` turn ticks!)
    -- with `>= 1` enemy stack (`myRem > 2.2s`) and `enStacks == 0`, answer immediately if safe from burst!
    local myAngleNow = U.GetAngleDifference(bot, U.PredictPosition(enemy, C.RAZE.CAST_POINT))
    local instantFacingStackReply = (not csWaveBusy)
        and (not unsafeSoon)
        and danger == 0
        and not outMatchedRunDown
        and myStacks >= 1 and myRem > 2.2
        and enStacks == 0
        and myAngleNow <= C.RAZE.MAX_ANGLE_TO_CAST
        and myHp > enImmediateBurst + 105
        and dHero <= 900

    if not mirrorCounter and not farRazeReciprocity and not proactiveEdgeIntercept
        and not dryEnemyPunish and not instantFacingStackReply then
        return false
    end

    if myMana < 75 then
        if not bot:HasModifier("modifier_flask_healing") and H.TryUseBurstManaItem(bot, true) then
            return true
        end
        return false
    end

    -- `auto-20261102-0007` (`4:37`, `8:22`, `10:02.7`) + `9074666246.dem` (`05:44.87` Courier-Mango Single-Coil Trap Fix!):
    -- NEVER count a courier Mango `6.5s` away (`MySustainedManaBudget(6.5)`) when deciding whether spending our last `75 MP`
    -- inside `780u` of an armed (`>= 150 MP`) or faster enemy SF traps us at `0..12 MP`! Require immediate (`<= 1.1s`) mana!
    local myImmediateMana = (K.MySustainedManaBudget and K.MySustainedManaBudget(bot, 1.1)) or K.MyManaBudget(bot, true)
    local mySustainedMana = (K.MySustainedManaBudget and K.MySustainedManaBudget(bot, 4.5)) or K.MyManaBudget(bot, true)
    local closeFasterOrArmed = (dHero <= 780) and (
        ((enemy:GetCurrentMovementSpeed() or 305) >= (bot:GetCurrentMovementSpeed() or 305) + 12)
        or (enTotalMana >= 150 and myHp < (enemy:GetHealth() or 999) + 140)
    )
    local effTrapMana = closeFasterOrArmed and myImmediateMana or mySustainedMana
    local singleCoilTrapRisk = (effTrapMana < 145)
        and (enTotalMana >= 150)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)
    local lastManaBehindRisk = (effTrapMana < 145)
        and (enTotalMana >= 75)
        and ((enemy:GetHealth() or 9999) > (bot:GetHealth() or 0) + 110)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)

    for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
        if (not singleCoilTrapRisk or (label == "far" and dHero >= 660))
            and (not lastManaBehindRisk or (label == "far" and dHero >= 775)) then
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    return true
                end
            end
        end
    end
    return false
end

-- Stage B0.5 (`9056469656.dem` `01:36–02:02` Soul-Lead Passivity & `02:29–02:35` `284 HP / 15 MP` Dry-Enemy Free-Kill Fix):
-- Runs right AFTER `RunSacredCS` (never drops a 0.000s lane CS!) and BEFORE `InLosingHeroTrade` / `TryWaveSafeStaticTango`:
--   1. When enemy has `< 75 MP` (`0` Shadowrazes possible!) and we hold equal/superior damage or HP lead (`01:42–02:02`
--      `Bot 8–10 souls, Lvl 3` vs `Sha 4–5 souls, Lvl 2, 12–44 MP`; `02:32.92` `Bot 514 HP, 13S` vs `Sha 284 HP, 15 MP`),
--      NEVER let them right-click us for free (`0 vs 10` autos!) or walk away on `284 HP` — trade right-clicks decisively!
--   2. Also right BEFORE `RunSacredCS`, `H.HandleActiveLethalDuelFinish` prevents `RunSacredCS` from stealing our fatal
--      swing onto a lane creep (`04:07.32` `U315` creep hit when `Sha = 178 HP` at `d = 171.9u`!).
function H.HandleActiveLethalDuelFinish(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local enHp = enemy:GetHealth() or 9999
    local myHp = bot:GetHealth() or 0
    local myAtk = math.max(1, K.AttackDamageVs(bot, enemy))
    local enAtk = math.max(1, K.AttackDamageVs(enemy, bot))
    local enPotMana = U.GetPotentialManaForRaze(enemy)

    -- Exact First-Kill Time-To-Kill (`TTK_bot < TTK_enemy`) Solver (`auto-20261023-0119` `00:24.83` @ `42 HP` & `05:25.43` @ `90 HP`!):
    -- Runs BEFORE `InCriticalLethalDanger` so SF NEVER turns its back on a guaranteed kill when `tKillHim` resolves BEFORE enemy lethal!
    local lr = U.SolveLethalRace(bot, enemy, s)
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 and myHp < 340 and not (lr and lr.winsFirstKill and lr.tKillHim <= 1.25 and myHp >= 145) then
        return false
    end

    local creepsOnMeNow = 0
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == bot
            and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 260 then
            creepsOnMeNow = creepsOnMeNow + 1
        end
    end
    local oneShotDryKill = (enPotMana < 75)
        and (enHp <= myAtk * 1.08)
        and (myHp > enAtk + creepsOnMeNow * 12 + 12 or GameTime() < (State.oneShotFinishUntil or 0))
    -- `v7.9.7-pro` + `v7.9.8-pro` (`1630 @ 01:32.6..01:36.2` `3–28 HP` Escape at `156 HP` vs Unused Mango Fix!):
    local oneShotTankKill = U.CanOneShotEnemyHero(bot, enemy)
        and (myHp >= K.EnemyBurstVs(bot, enemy, math.min(d, 500), 1.15, false) + 8)
    local anyOneShotKill = oneShotDryKill or oneShotTankKill
    local extendedDryKillReach = anyOneShotKill and 250
        or ((enPotMana < 75 and enHp <= myAtk * 2.6 and myHp >= 185) and 175
            or ((lr and lr.winsFirstKill and lr.tKillHim <= 2.35) and 380 or 85))
    if d > (bot:GetAttackRange() or 500) + extendedDryKillReach then return false end

    local myOneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local hasReadyRaze = K.MyReadyRazeCount(bot, true) >= 1
    local myShots = math.ceil(enHp / myAtk)
    local enShots = math.ceil(myHp / enAtk)
    local dryWinningFinish = myShots <= 4
        and (enPotMana < 75 or not (earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon)))
        and (myShots + 1 <= enShots)
        and myHp >= 185
    local ttkFirstKillWin = (lr and lr.winsFirstKill and lr.tKillHim <= 2.35)
    local duelLethalNow = anyOneShotKill
        or ttkFirstKillWin
        or (enHp <= myAtk * 3.1 and myHp >= math.max(165, K.EnemyBurstVs(bot, enemy, d, 1.15, false) + 25))
        or (hasReadyRaze and enHp <= myOneRaze + myAtk * 1.65 and myHp >= math.max(165, K.EnemyBurstVs(bot, enemy, d, 0.95, false) + 20))
        or dryWinningFinish
    if not duelLethalNow then return false end
    if anyOneShotKill then
        State.oneShotFinishUntil = GameTime() + 1.15
    end

    -- Lock in kill commitment & clear ALL retreat/flee states immediately!
    H.ClearForcedRetreat()
    State.fleeUntil = 0
    State.critDangerHystUntil = 0
    State.survivalUntil = 0
    State.survivalLoc = nil

    -- Instant `0.00s` Emergency Burst EHP (`9058240714.dem` `1:54.03` Fix!):
    --   * `Magic Stick / Wand` (`0` attack damage loss!) fires at `lr.needStickHeal` or `<= 35% HP`.
    --   * `Faerie Fire` (`-2` permanent attack damage!) fires STRICTLY ONLY at `lr.needFaerieHeal` (`<= 0.85s` lethal) or `<= 15% HP`!
    local maxHpNow = math.max(1, bot:GetMaxHealth() or 1)
    if lr and (lr.needStickHeal or lr.needFaerieHeal or (myHp <= (lr.enDmgBeforeDeath or 0) + 75 and myHp <= maxHpNow * 0.35)) then
        local wand = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
        if wand and wand:IsFullyCastable() and U.GetStickCharges(bot) > 0 then
            bot:Action_UseAbility(wand)
            State.commitKillUntil = GameTime() + 2.5
            State.actionTaken = true
            return true
        end
        if lr.needFaerieHeal or myHp <= maxHpNow * 0.15 then
            local ff = U.GetActiveItemByName(bot, "item_faerie_fire")
            if ff and ff:IsFullyCastable() then
                bot:Action_UseAbility(ff)
                State.commitKillUntil = GameTime() + 2.5
                State.actionTaken = true
                return true
            end
        end
    end

    -- If a single right-click ALREADY kills the enemy (`enHp <= myAtk * 1.08`) inside reach, swing/step IMMEDIATELY (`~0.35s`)
    -- instead of spending `0.55s` + `75 MP` on a raze windup or flip-flopping at `d = 600u` (`9058240714.dem` `2:04.6` `50 HP` fix!):
    local minEnTwD = 9999
    for _, tw in pairs(s.enemyTowers or {}) do
        if tw and tw:IsAlive() then
            local dtTw = GetUnitToLocationDistance(tw, enemy:GetLocation())
            if dtTw < minEnTwD then minEnTwD = dtTw end
        end
    end
    local openRiver1Shot = anyOneShotKill and minEnTwD >= 1060 and danger < 2
    if enHp <= myAtk * 1.08 and d <= (bot:GetAttackRange() or 500) + (anyOneShotKill and 250 or 95)
        and (openRiver1Shot or H.CanKinematicallyCatchForAttack(bot, enemy, s.enemyTowers, s.allyCreeps, 1.55)) then
        if H.IssueHeroAttack(bot, enemy) then
            State.prepTarget = nil
            State.lhAttackTarget = nil
            State.commitKillUntil = GameTime() + 2.4
            State.actionTaken = true
            return true
        end
    end

    -- Fire lethal/near-lethal centered raze if ready, otherwise lock right-click directly onto enemy hero!
    if (bot:GetMana() or 0) < 75 and K.MyManaBudget(bot, true) >= 75 and hasReadyRaze then
        if H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    if (bot:GetMana() or 0) >= 75 then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.commitKillUntil = GameTime() + 2.5
                    return true
                end
            end
        end
        -- `Demo 2` `7:41` + `v7.9.8-pro` (`1630 @ 01:28.5..01:32.0` `155 HP` Auto-Weave Before `R3` Fix!):
        -- When `E(700)` ALONE does NOT kill `enemy` (`enHp > myOneRaze`, e.g. `155 > 116`) while `1 auto + E(700)` IS lethal
        -- (or enemy is OOM `< 75 MP`) AND our right-click is ALREADY off cooldown inside reach (`d <= atkRange + 35`),
        -- weave the `0.38s` auto-attack FIRST, then step back into `E(700)` during attack backswing/cooldown!
        local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
        local _, enRemNow = U.GetShadowrazeDebuff(enemy)
        local mySpaWeave = math.max(0.65, bot:GetSecondsPerAttack() or 1.45)
        local atkReadyForWeave = (GameTime() - (bot:GetLastAttackTime() or -100)) >= (mySpaWeave * 0.85)
        local needAutoBeforeR3 = atkReadyForWeave
            and (enHp > myOneRaze)
            and (enHp <= myOneRaze + myAtk * 1.35 or (enemy:GetMana() or 0) < 75)
            and d <= ((bot:GetAttackRange() or 500) + 35)
            and ((enRemNow or 0) == 0 or (enRemNow or 0) >= 2.25)
        local appClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
        local myMsClose = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 310)
        local needDist = math.min(680, math.max(545, 505 + appClose * 0.62))
        local tWalkOut = math.max(0, needDist - d) / math.max(30, myMsClose - appClose)
        if eAb and U.IsRazeAbilityCastable(bot, eAb) and not needAutoBeforeR3 and d >= 200 and d < 620
            and myShots >= 3
            and tWalkOut <= 0.85
            and ((enRemNow or 0) == 0 or (enRemNow or 0) >= 0.85) then
            local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
            bot:Action_MoveToLocation(enemy:GetLocation() + away * (needDist + 65))
            H.ClearMoveCache()
            State.prepTarget = nil
            State.lhAttackTarget = nil
            State.commitKillUntil = GameTime() + 2.2
            State.actionTaken = true
            return true
        end
    end
    -- `v7.9.1` (`9071946472.dem` `02:46.93–02:50.20` 3.27s Stationary Freeze Fix!):
    -- NEVER set `State.actionTaken = true` or return `true` unless `CanKinematicallyCatchForAttack` AND `IssueHeroAttack`
    -- genuinely issued a live C++ attack order! (Previously `towerChaseBlockedEnemy` made `IssueHeroAttack` return `false`
    -- while `HandleActiveLethalDuelFinish` still set `actionTaken = true`, freezing SF for 95 ticks!)
    if not H.CanKinematicallyCatchForAttack(bot, enemy, s.enemyTowers, s.allyCreeps, 1.65) then
        return false
    end
    if H.IssueHeroAttack(bot, enemy) then
        State.prepTarget = nil
        State.lhAttackTarget = nil
        State.commitKillUntil = GameTime() + 2.2
        State.actionTaken = true
        return true
    end
    return false
end

-- `v4.2.0` Multi-Stack Combo Finisher & Anti-`Raze3`-Bait Counter-Geometry
-- Eliminates ALL FOUR replay outplays simultaneously:
--   * Mode A (`Demo 2` `7:41`): 2-stack/3-stack lethal execution INCLUDING `0.15s` step-back `[250..470u] -> 510u` for 3rd-stack `Raze3 (310 dmg)`!
--   * Mode B (`Demo 1` `1:20` & `Demo 2` `7:13.3`): Immediate 2nd/3rd-stack overlap chain (`E -> W` at `[455..670u]`, `Q -> W` at `[210..435u]`)
--     whenever enemy already carries our stack (`enStacks >= 1`) and we survive `0.72s` — NEVER aborting ready `W` to flee!
--   * Mode C (`Demo 2` `7:07` & `Demo 1` `1:40`): Anti-`Raze3`-Bait Outer Kite Punish! When enemy spends long `E (700u)` and runs forward
--     to land `2`-stack `W (450u)`, fire our `E` IN PLACE from `[725..895u]` (NEVER walking into `< 715u`!) and hold `[775..835u]` outside `W`!
function H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, lethalOrChainOnly)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsSilenced() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myMana = bot:GetMana() or 0
    local potMana = K.MyManaBudget(bot, true)
    local enHp = enemy:GetHealth() or 9999
    local enEffHp = enHp + (U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy) or 0) + (U.GetStickCharges(enemy, false) * 15)
    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    enStacks, enRem = enStacks or 0, enRem or 0
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks, myRem = myStacks or 0, myRem or 0
    local myAtk = K.AttackDamageVs(bot, enemy)
    local myNextRaze = U.GetNRazeDamage(bot, enemy, 1)

    -- MODE A: Lethal Next-Stack Execution (including `[240..475u] -> 510u` step-back for 3rd-stack `Raze3`,
    -- PLUS `auto-20261102-0139` `3:58.80` Raw-HP Lethal / Faerie-Force Far `E` at `d >= 615u` vs `< 75 MP` enemy!)
    local enPotManaM = U.GetPotentialManaForRaze(enemy)
    local safeRawKillOrFaeriePop = (enHp <= myNextRaze + 10)
        and ((d >= 615 and enPotManaM < 75) or (myHp > K.EnemyBurstVs(bot, enemy, d, 0.70, false) + 45))
    if potMana >= 75 and myNextRaze > 0 and (enEffHp <= (myNextRaze + (d <= 540 and myAtk * 0.95 or 0)) or safeRawKillOrFaeriePop) then
        local inc065 = K.EnemyBurstVs(bot, enemy, d, 0.65, false)
        if myHp > inc065 + 25 or myNextRaze >= enEffHp or safeRawKillOrFaeriePop then
            H.ClearForcedRetreat()
            State.fleeUntil = 0
            State.critDangerHystUntil = 0
            State.survivalUntil = 0
            State.survivalLoc = nil
            if myMana < 75 and H.TryUseBurstManaItem(bot, true) then
                State.commitKillUntil = GameTime() + 2.5
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.commitKillUntil = GameTime() + 2.5
                            return true
                        end
                    end
                end
                local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
                local appClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
                local myMsClose = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 310)
                local needDist = math.min(680, math.max(545, 505 + appClose * 0.62))
                local tWalkOut = math.max(0, needDist - d) / math.max(30, myMsClose - appClose)
                if eAb and U.IsRazeAbilityCastable(bot, eAb) and d >= 200 and d < 620
                    and math.ceil(enHp / math.max(1, myAtk)) >= 3
                    and tWalkOut <= 0.85 and (enRem == 0 or enRem >= 0.85) then
                    local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
                    local stepBackPt = enemy:GetLocation() + away * (needDist + 65)
                    bot:Action_MoveToLocation(stepBackPt)
                    H.ClearMoveCache()
                    State.commitKillUntil = GameTime() + 2.2
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    -- MODE B: Immediate Overlap 2nd/3rd-Stack Chain (`Demo 1` `1:20` & `Demo 2` `7:13.3`!)
    -- Strictly requires either:
    --   * enemy ALREADY spent both `far` & `mid` razes (`Demo 1` `1:20` at `d >= 460u` -> `0` counter-razes possible!), OR
    --   * we survive the full `2.2s` combo (`not heCanKillSoon`, `not uphillPenalty`, `myHp > burst22 + 95`), so we NEVER
    --     self-root `0.55s` in river lowground into a lethal L4 triple-raze (`S8` safety preserved 100%!).
    if enStacks >= 1 and enRem >= 0.85 and potMana >= 75 and d <= 905 then
        local nowChain = GameTime()
        local burst22 = K.EnemyBurstVs(bot, enemy, d, 2.2, false)
        local oneHitPhys = bot:GetActualIncomingDamage(enemy:GetAttackDamage() or 55, DAMAGE_TYPE_PHYSICAL)
        local aggroCreeps = 0
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == bot
                and GetUnitToLocationDistance(bot, ec:GetLocation()) < 340 then
                aggroCreeps = aggroCreeps + 1
            end
        end
        local enAppChain = U.EnemyApproachSpeed(bot, enemy)
        local spinCastDanger = oneHitPhys * ((d <= 720 or enAppChain > 120) and 2.1 or 1.2)
            + aggroCreeps * 26
        local safeSpinHp = (myHp > math.max(225, spinCastDanger + 75))
            and (((enemy:GetLevel() or 1) <= (bot:GetLevel() or 1)) or myHp >= 340)
        local enemySpentMidAndFar = (K.EnemyRazeReadyIn("far") > 2.0 and K.EnemyRazeReadyIn("mid") > 2.0 and d >= 460)
        -- `auto-20261102-0007` `10:06.20` (`tk=51488`, `74.8->75.8 MP`, `610 HP` vs `995 HP` Pursuer `162 deg` Turn-Back Fix!):
        -- NEVER abort an active retreat or spin `> 65 deg` backward into a pursuing higher-HP SF for a non-lethal 2nd stack,
        -- and NEVER spend our last `75 MP` (`potMana < 145`) inside `< 665u` vs a `>= 150 MP` enemy!
        local activelyRetreatingNow = (State.forcedRetreatLoc ~= nil and nowChain < (State.forcedRetreatUntil or 0))
            or (nowChain < (State.fleeUntil or 0))
            or (nowChain < (State.critDangerHystUntil or 0))
            or H.InLosingHeroTrade(bot, s, earlyRace)
        local angToEnChain = U.GetAngleDifference(bot, enemy:GetLocation())
        local unsafeBackwardSpin = (angToEnChain > 65 and enAppChain > 65 and myHp < enHp - 120)
        local singleCoilChainTrap = (enStacks == 1 and potMana < 145 and K.EnemyManaBudget(enemy, true) >= 150 and d < 665)
        local safeToChainHere = safeSpinHp
            and not unsafeBackwardSpin
            and not singleCoilChainTrap
            and (enemySpentMidAndFar
                or (not activelyRetreatingNow
                    and myHp > burst22 + 95
                    and myHp >= 260
                    and not (earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.uphillPenalty))))
        if safeToChainHere then
            if myMana < 75 and not bot:HasModifier("modifier_flask_healing") and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            H.ClearForcedRetreat()
                            State.fleeUntil = 0
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    -- `v7.9.9-pro` (`1814 @ 07:52.80..07:54.17` Post-2-Coil Disengage & `07:01.13..07:05.20` 1-Stack Survival Law):
    -- Runs BEFORE `if lethalOrChainOnly then return false end` (so `RunSacredCS` & harass handlers NEVER walk a stacked SF
    -- back inside `724u` `Shadowraze2` reach after our `W`+`E` combo is spent or when enemy's stacked coil + auto is lethal!):
    --   * Subcase C0a (`Post-Combo Cooldown Disengage`, `1814 @ 07:53`): We carry `myStacks >= 1` (`myRem > 1.25`), BOTH our
    --     `W(450)` and `E(700)` are on cooldown (`> 1.15s`), enemy has `W(450)` ready (`<= 1.25s`, `mana >= 75`), and `enemy`
    --     cannot be finished in `<= 2` right-clicks (`enHp > myAtk * 2.05`). Hold `>= 815u` across ALL `d` (`355..805u`, or
    --     `0..805u` when `Q` is also on CD), never dropping protection at `d < 690u` or via stale `earlyRace.canKillSoon`!
    --   * Subcase C0b (`Lethal Stack-Burst Survival`, `1814 @ 07:03`): We carry `myStacks >= 1` (`myRem > 1.20`) and enemy's
    --     next stacked coil + `1.15` autos >= `myHp` while enemy `W` (`d <= 795u`) or `Q` (`d <= 510u`) is ready!
    if myStacks >= 1 and myRem > 1.20 and enPotManaM >= 75 then
        local enAtkS = K.AttackDamageVs(enemy, bot)
        local lrStack = U.SolveLethalRace(bot, enemy, s)
        local fastKillOverride = (lrStack and lrStack.winsFirstKill and lrStack.tKillHim <= 1.30)
            or (enHp <= myAtk * 2.05 and d <= (bot:GetAttackRange() or 525) + 45)
        if not fastKillOverride then
            local qAbS = H.GetRazeAbilityByLabel(bot, "near")
            local wAbS = H.GetRazeAbilityByLabel(bot, "mid")
            local eAbS = H.GetRazeAbilityByLabel(bot, "far")
            local qReadyS = qAbS and qAbS:GetLevel() > 0 and (qAbS:GetCooldownTimeRemaining() or 0) <= 0.35 and (bot:GetMana() or 0) >= 75
            local wOnCdS = (not wAbS) or wAbS:GetLevel() == 0 or (wAbS:GetCooldownTimeRemaining() or 0) > 1.15 or (bot:GetMana() or 0) < 75
            local eOnCdS = (not eAbS) or eAbS:GetLevel() == 0 or (eAbS:GetCooldownTimeRemaining() or 0) > 1.15 or (bot:GetMana() or 0) < 75
            local enMidReadyS = K.EnemyRazeReadyIn("mid") <= 1.25
            local enNearReadyS = K.EnemyRazeReadyIn("near") <= 1.05
            local nextStackCoilDmg = K.EnemyRazeDamage(bot, enemy, 1)
            local stackBurstLethal = (nextStackCoilDmg + enAtkS * 1.15 >= myHp)
                and ((enMidReadyS and d <= 805) or (enNearReadyS and d <= 515))
            local postComboSpentKite = wOnCdS and eOnCdS and enMidReadyS
                and d <= 795 and (d >= 355 or not qReadyS)
            if stackBurstLethal or postComboSpentKite then
                if U.IsAttackingAction(bot) and d <= 735 then
                    bot:Action_ClearActions(false)
                end
                local fntS = P.GetFountain(bot)
                local eLocS = enemy:GetLocation()
                local homeDirS = (fntS - eLocS):Normalized()
                local kiteDistS = stackBurstLethal and 845 or 815
                local kiteSpotS = eLocS + homeDirS * kiteDistS
                State.urgentMoveOverride = true
                H.SmartMove(bot, kiteSpotS, 30, true)
                State.urgentMoveOverride = false
                State.actionTaken = true
                return true
            end
        end
    end

    if lethalOrChainOnly then return false end

    -- MODE C: Anti-`Raze3`-Bait Outer Kite Punish (`Demo 2` `7:07`, `Demo 1` `1:40`, `1814 @ 07:53`, & `0210 @ 00:25..05:25` Fix!)
    -- Enemy just spent long `Shadowraze3` (`EnemyRazeReadyIn("far") > 4.0`) and still holds `Shadowraze2` (`<= 724u` hull edge) + mana:
    --   1. If in `[690..905u]` and our `far` raze is ready: fire `Shadowraze3` IN PLACE immediately!
    --   2. `v7.9.13-pro` Stand-Ground Parity Gate (`0210 @ 00:25, 00:53, 01:44, 02:53, 03:25, 03:55, 04:16, 05:23` Fix!):
    --      Previously, `MODE C` unconditionally ran backward to `815..900u` after EVERY `E(700)` trade whenever `myStacks >= 1`!
    --      When BOTH heroes traded `E` (`enStacks >= myStacks`, our `W(450)` is ready with `>= 75 MP`, not out-leveled on raze tier,
    --      and `myHp >= enHp * 0.85` & `myHp >= 400`), OR when we hold a decisive HP cushion (`myHp >= enHp + 150` & `myHp >= nextStackDmg + 210`),
    --      DO NOT retreat `815..900u` and surrender the wave — hold lane dominance and match his `W(450)` with our `W(450)` + right-clicks!
    local enFarSpent = K.EnemyRazeReadyIn("far") > 4.0
    local enMidThreat = K.EnemyRazeReadyIn("mid") <= 1.5 and K.EnemyManaBudget(enemy, true) >= 75
    if enFarSpent and d >= 355 and d <= 940 then
        local farAb = H.GetRazeAbilityByLabel(bot, "far")
        local midAbC = H.GetRazeAbilityByLabel(bot, "mid")
        local myMidReadyC = midAbC and U.IsRazeAbilityCastable(bot, midAbC)
        local myBothMidFarOnCd = (not (farAb and U.IsRazeAbilityCastable(bot, farAb)))
            and (not myMidReadyC)
        local realFastKill = (earlyRace and earlyRace.valid and earlyRace.canKillNow)
            or (not myBothMidFarOnCd and earlyRace and earlyRace.valid and earlyRace.canKillSoon)
            or (enHp <= myAtk * 2.05)
        local outRazedC = U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy) or false
        local nextStackDmgC = K.EnemyRazeDamage(bot, enemy, 1)
        local enAtkC = K.AttackDamageVs(enemy, bot)
        local canMatchWTrade = myMidReadyC and (not outRazedC)
            and (myHp > nextStackDmgC + enAtkC * 1.45 + 95)
            and (((enStacks or 0) >= myStacks and (enRem or 0) > 0.85 and myHp >= enHp * 0.85 and myHp >= 400)
                or (myHp >= enHp + 150 and myHp >= 440))
        local appNow = math.max(0, U.EnemyApproachSpeed(bot, enemy))
        local enInCastNow = K.EnemyPhase() ~= nil
        local mustKiteWFirst = (myStacks >= 1 and myRem > 0.65 and enMidThreat)
            and (not realFastKill)
            and (not canMatchWTrade)
            and not (enInCastNow and d > 728)
            and ((d - appNow * 0.62) < 728)
        if mustKiteWFirst then
            local fnt = P.GetFountain(bot)
            local homeDir = (fnt - enemy:GetLocation()):Normalized()
            local kiteRing = enemy:GetLocation() + homeDir * 900
            H.SmartMove(bot, kiteRing, 35)
            State.actionTaken = true
            return true
        end
        if d >= 690 and farAb and U.IsRazeAbilityCastable(bot, farAb) and myHp > 195 then
            local action, aim = H.GetRazeActionType(bot, farAb, enemy)
            if action and H.CastOrTurnRaze(bot, farAb, action, aim, enemy) then
                State.actionTaken = true
                return true
            end
        elseif myStacks >= 1 and myRem > 0.65 and enMidThreat and (not realFastKill) and (not canMatchWTrade) then
            if d < 795 then
                local fnt = P.GetFountain(bot)
                local homeDir = (fnt - enemy:GetLocation()):Normalized()
                local kiteRing = enemy:GetLocation() + homeDir * 815
                H.SmartMove(bot, kiteRing, 35)
                State.actionTaken = true
                return true
            end
        end
    end

    return false
end

-- `v4.2.0` Close Duel Hero-Attack Lock (`Demo 2` `7:40.87` & `Demo 1` `3:55`) + Equal-State Stand-Ground Anti-Zoning (`Demo 2` 25x)
function H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, preSacredCS, imminentCreepCS)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local enHp = enemy:GetHealth() or 9999
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    local fightingNow = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.8))

    if preSacredCS then
        -- STRICT Close-Duel Lock: fires ONLY inside active all-in hero duels (`d <= 555u`) so normal lane CS is NEVER touched!
        -- `9058240714.dem` `1:53.50..2:06.30` Root-Cause Fix (`-391 HP` tanking 4 enemy lane creeps + 25% uphill miss!):
        --   * Account explicitly for BOTH `uphillHitFactor` (`0.75` from river `z=0` into HG `z=128`) AND all live enemy creeps
        --     inside Source 2 `460u` aggro radius (`enemyCreepsInAggro * 13.0` DPS) + creeps already hitting `bot` (`creepsHittingBot`)!
        --   * When `creepsHittingBot >= 2` while enemy still needs `> 2` right-clicks (`enHp > myAtk * 2.15`), NEVER spam
        --     `IssueHeroAttack` in a 4-creep ring — immediately fire a 1-tick Source 2 Creep De-Aggro onto an allied creep
        --     and step back behind our allied wave!
        local bLocDuel = bot:GetLocation()
        local eLocDuel = enemy:GetLocation()
        local uphillHitFactor = ((eLocDuel.z or 0) - (bLocDuel.z or 0) >= 90) and 0.75 or 1.0
        local effMyAtk = math.max(1, myAtk * uphillHitFactor)
        local enemyCreepsInAggro, creepsHittingBot, bestDeaggAlly, bestDeaggDist = 0, 0, nil, math.huge
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc <= 505 or U.DistanceBetweenLocations(eLocDuel, ec:GetLocation()) <= 460 then
                    enemyCreepsInAggro = enemyCreepsInAggro + 1
                end
                local cRng = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                if dc <= math.max(260, cRng + 55) and ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                    creepsHittingBot = creepsHittingBot + 1
                end
            end
        end
        bestDeaggAlly = H.FindSafeDeaggroAllyCreep(bot, s.allyCreeps, enemy)

        -- `v7.9.7-pro` (`0307 @ 00:53..01:01` `-170 HP` from `4` Radiant melee creeps at `d=303..445u` Fix!):
        -- Check whether a ready raze ACTUALLY covers `d` right now (having `E(700)` ready while standing at `313u` inside
        -- `4` melee creeps does NOT justify eating `52 DPS` of creep hits!), AND at `L1..L4` always de-aggro `3+` melee creeps!
        local hasInBandReadyRaze = false
        if (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
            for _, bSpec in ipairs({
                { label = "near", c = 200 },
                { label = "mid",  c = 450 },
                { label = "far",  c = 700 },
            }) do
                local rAb = H.GetRazeAbilityByLabel(bot, bSpec.label)
                if rAb and U.IsRazeAbilityCastable(bot, rAb) and math.abs(d - bSpec.c) <= 258 then
                    hasInBandReadyRaze = true
                    break
                end
            end
        end
        local earlySwarmOverload = (creepsHittingBot >= 3)
            and ((bot:GetLevel() or 1) <= 4)
            and (enHp > myAtk * 2.15 + U.GetNRazeDamage(bot, enemy, 1))
        if creepsHittingBot >= 2 and enHp > myAtk * 2.15 and ((not hasInBandReadyRaze) or earlySwarmOverload) then
            local nowD = GameTime()
            local chaseLockedNow = nowD < ((State.myCreepChaseUntil or 0) - 0.08)
            if State.lastBrawlDeaggroAt and nowD < State.lastBrawlDeaggroAt then
                State.lastBrawlDeaggroAt = -100
            end
            if not chaseLockedNow and bestDeaggAlly and nowD >= (State.lastBrawlDeaggroAt or -100) + 1.35 then
                State.lastBrawlDeaggroAt = nowD
                bot:Action_AttackUnit(bestDeaggAlly, true)
                State.actionTaken = true
                return true
            end
            -- `v7.9.8-pro` (`1630 @ 00:33` & `03:37` Forward Melee Walk Fix!):
            -- Step strictly backward from `bLocDuel` toward our own Fountain (NEVER toward a forward split creep)!
            local fnt = P.GetFountain(bot)
            local refBack = bLocDuel
            if bestDeaggAlly and U.DistanceBetweenLocations(bestDeaggAlly:GetLocation(), fnt) < U.DistanceBetweenLocations(bLocDuel, fnt) - 25 then
                refBack = bestDeaggAlly:GetLocation()
            end
            local safeStep = U.SteerAroundObstacles(bot, refBack + (fnt - refBack):Normalized() * 265, s)
            H.SmartMove(bot, safeStep, 25)
            State.actionTaken = true
            return true
        end

        local mySpaD = math.max(0.55, bot:GetSecondsPerAttack() or 1.25)
        local enSpaD = math.max(0.55, enemy:GetSecondsPerAttack() or 1.25)
        local incomingDpsWithCreeps = (enAtk / enSpaD) + enemyCreepsInAggro * 12.5
        local outgoingDpsTrue = effMyAtk / mySpaD
        local blockedByCreepPack = (enemyCreepsInAggro >= 3 or (enemyCreepsInAggro >= 2 and uphillHitFactor < 1.0))
            and enHp > myAtk * 2.15
        local winningDrySoulDuel = (enPotMana < 75)
            and not blockedByCreepPack
            and d <= (bot:GetAttackRange() or 500) + 120
            and (myHp >= 150 or enHp <= myAtk * 1.15)
            and myHp >= enHp * 0.76
            and (effMyAtk >= enAtk + 8 or (fightingNow and enHp <= effMyAtk * 3.1))
            and (enHp / math.max(1, outgoingDpsTrue)) + 0.15 <= (myHp / math.max(1, incomingDpsWithCreeps))
        -- `W6 07:58` Fix: NEVER brawl at point-blank right-click disadvantage (`72` vs `99` Treads autos!) with `Q`/`W` on CD!
        local closeCoilReadyHere = false
        if (bot:GetMana() or 0) >= 75 then
            for _, spec in ipairs({ { "nevermore_shadowraze1", 200 }, { "nevermore_shadowraze2", 450 } }) do
                local abC = bot:GetAbilityByName(spec[1])
                if abC and abC:GetLevel() > 0 and abC:IsCooldownReady() and math.abs(d - spec[2]) <= 220 then
                    closeCoilReadyHere = true
                    break
                end
            end
        end
        local myDryVsEnemyRaze = (K.MyManaBudget(bot, true) < 75) and (K.EnemyCastableRazeCount(enemy, 2.2) >= 1)
        -- `auto-20261102-0159-start-ShaNachnetsya.dem` `15:04.8..15:07.9` Point-Blank Melee Freeze Fix (#6):
        -- Previously `myHp <= myMaxHp * 0.86 or enHp <= 560` + `enStacks >= 1` FORBADE a `98.1% HP` (`1662/1694`) SF from
        -- punishing a `771 HP` rival who walked to `213.1u` (`dead-center inside Q(200)`) while `RunSacredCS` waited `2.13s`
        -- to deny a `123 HP` allied melee creep! Protect ONLY imminent `< 0.55s` ENEMY last-hits (`not bestPlan.isDeny`),
        -- never sacrifice a free point-blank `Q(200)` / self-rooted counter-coil for a slow allied creep deny!
        local bestPlanPre, bestEtaPre = L.PeekBestPlan(bot, s)
        local urgentEnemyCSNow = bestPlanPre and (not bestPlanPre.isDeny) and (bestEtaPre or 99) <= 0.55
        local enemySelfRootedClose = (d <= 535) and (K.EnemyPhase() ~= nil) and closeCoilReadyHere
        local pointBlankIntrusionPunish = (not urgentEnemyCSNow)
            and not myDryVsEnemyRaze
            and creepsHittingBot <= 1
            and not blockedByCreepPack
            and not H.InCriticalLethalDanger(bot, s, earlyRace)
            and (not earlyRace or not earlyRace.valid or (((earlyRace.edge or 0) >= -45 or myHp >= enHp * 1.20) and not earlyRace.heCanKillSoon))
            and (enemySelfRootedClose
                or (d <= 335 and (closeCoilReadyHere or (myHp >= enHp * 1.15 and effMyAtk >= enAtk - 6))))
        local activeStackedCloseDuel = d <= 545
            and not urgentEnemyCSNow
            and not myDryVsEnemyRaze
            and creepsHittingBot <= 1
            and not blockedByCreepPack
            and (closeCoilReadyHere or effMyAtk >= enAtk - 8 or enHp <= effMyAtk * 2.8)
            and (((enStacks or 0) >= 1 and (enRem or 0) > 1.5) or ((myStacks or 0) >= 1 and (myRem or 0) > 1.8 and fightingNow))
            and not (enHp >= myHp + 185 and (K.EnemyCastableRazeCount(enemy, 1.4) >= math.max(2, K.MyReadyRazeCount(bot, true))))
            and not H.InCriticalLethalDanger(bot, s, earlyRace)
            and (earlyRace and earlyRace.valid and ((earlyRace.edge or 0) >= -55 or earlyRace.canKillSoon))

        if not winningDrySoulDuel and not activeStackedCloseDuel and not pointBlankIntrusionPunish then
            return false
        end

        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if not bot:IsSilenced() then
            if (bot:GetMana() or 0) < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if (bot:GetMana() or 0) >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
        return false
    end

    -- Post-CS Equal-State Stand-Ground Anti-Zoning & `v7.5.0` Dominant Wave-Contest Punish:
    -- 1) Equal state: when rival steps forward (`d <= 685u`, `approach > 32` or past wave), stand ground & trade back.
    -- 2) Dominant state (`U.IsLaneDominant`): when we are winning the lane (`9070559899.dem` fix!) and the rival dares
    --    walk within `<= 790u` of our creep wave (`d <= 835u`) even WITHOUT running at us (`approach <= 32`), blast him
    --    with a centered `Shadowraze` / clean right-click so he CANNOT walk up and farm creeps for free!
    if imminentCreepCS then return false end
    local isDominantPunish = U.IsLaneDominant and U.IsLaneDominant(bot, s, earlyRace) or false
    local maxPunishDist = isDominantPunish and 835 or 685
    if d > maxPunishDist or myHp < 310 or (not isDominantPunish and myHp < enHp * 0.72) then return false end
    if U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy) then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or (earlyRace.edge or 0) < -65 or (not isDominantPunish and earlyRace.uphillPenalty)) then
        return false
    end

    local approach = U.EnemyApproachSpeed(bot, enemy)
    local fnt = P.GetFountain(bot)
    local waveCenter = LN.AllyWaveCenter(s.allyCreeps)
    local steppedPastWave = waveCenter ~= nil
        and U.DistanceBetweenLocations(enemy:GetLocation(), fnt) <= U.DistanceBetweenLocations(waveCenter, fnt) + 125
    local contestingOurWave = isDominantPunish and (LN.EnemyDistToAllyWave(enemy, s.allyCreeps) <= 790)
    if approach <= 32 and not steppedPastWave and not fightingNow and not contestingOurWave then
        return false
    end

    local nearSpikeNow = U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy) or false
    local manaNow = bot:GetMana() or 0
    if isDominantPunish and manaNow < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
        State.actionTaken = true
        return true
    end
    local enStacksNow = (U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(enemy)) or 0
    local razeManaGate = (not contestingOurWave or enHp <= 360 or enStacksNow >= 1) and 75 or 135
    if not nearSpikeNow and not bot:IsSilenced() and manaNow >= razeManaGate then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end
    local allowAutoPunish = (not H.IsDryVsEnemyRaze(bot, enemy))
        and ((not contestingOurWave) or (approach > 32) or steppedPastWave or fightingNow
            or (#(s.enemyCreeps or {}) <= 2) or (d > 515))
    local movingAwayAuto = K.IsEnemyMovingAway(bot, enemy)
    local autoPunishReach = math.max(525, bot:GetAttackRange() or 525) + (movingAwayAuto and 22 or 45)
    if allowAutoPunish and d <= autoPunishReach then
        local prevPolicy, prevAllow = State.combatPolicyActive, State.heroCombatAllowed
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local okAtk = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive, State.heroCombatAllowed = prevPolicy, prevAllow
        if okAtk then
            State.actionTaken = true
            return true
        end
    end
    return false
end

function H.HandleDryEnemyAndSoulLeadHarass(bot, s, earlyRace, csWaveBusy)
    if State.actionTaken or csWaveBusy or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local atkRange = bot:GetAttackRange() or 500
    local enHp = enemy:GetHealth() or 9999
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local rawMyHp = bot:GetHealth() or 0
    local inFlightOnMe = 0
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, pr in pairs(projs) do
                if pr then
                    local caster = pr.caster
                    if caster and caster.IsHero and caster:IsHero() then
                        inFlightOnMe = inFlightOnMe + enAtk
                    else
                        inFlightOnMe = inFlightOnMe + 18
                    end
                end
            end
        end
    end
    local myHp = math.max(1, rawMyHp - inFlightOnMe)
    local enTotalMana = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local enemyDry = (enTotalMana < 75) and (K.EnemyPhase() == nil)
    local uphill = earlyRace and earlyRace.valid and earlyRace.uphillPenalty

    local creepsOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then
            creepsOnMe = creepsOnMe + 1
        end
    end

    -- Case 1: Enemy has ZERO spell threat (`< 75 MP`) — right-click punish on our soul/HP advantage!
    local crushingSoulLead = (enTotalMana < 150 and myAtk >= enAtk + 12 and (myHp - K.EnemyRazeDamage(bot, enemy, 1)) >= 255)
        or (enTotalMana < 225 and myAtk >= enAtk + 18 and (myHp - K.EnemyRazeDamage(bot, enemy, 2)) >= 75)
    local winningHitTrade = (math.ceil(enHp / math.max(1, myAtk)) <= math.ceil(myHp / math.max(1, enAtk)))
        or (myHp >= enHp * 0.88)
        or ((bot:GetMana() or 0) >= 75 and myHp >= enHp * 0.60)
    local pressDryKill = enemyDry and myHp >= 225 and not uphill
        and ((myAtk >= enAtk - 2 and creepsOnMe <= 1 and winningHitTrade)
            or (myHp >= enHp + 110 and enHp <= 400 and creepsOnMe <= 2))
    -- Case 2: Clear Soul/Attack-Damage Dominance (`>= +7` hero hit damage) with safe spell parity OR
    -- crushing `16 vs 7` soul + `2x Bracer` right-click dominance vs a `1`-coil (`< 150 MP`) enemy (`9056774541.dem` `02:35`!)
    -- NEVER walk dry (`< 75 MP`) into a `2+`-coil (`>= 150 MP`) enemy SF (`ShaNachnetsya` `02:22–02:40` `874 -> 159 HP` Fix),
    -- AND NEVER step in with `1+` raze stack while our `W`+`E` are spent (`1814 @ 07:58` Post-Combo Stack Safety)!
    local myStLead, myRemLead = U.GetShadowrazeDebuff(bot)
    local r2Lead = bot:GetAbilityByName("nevermore_shadowraze2")
    local r3Lead = bot:GetAbilityByName("nevermore_shadowraze3")
    local myWESpentLead = (not (r2Lead and U.IsRazeAbilityCastable(bot, r2Lead)))
        and (not (r3Lead and U.IsRazeAbilityCastable(bot, r3Lead)))
    local stackedSpentVsCoil = ((myStLead or 0) >= 1 and (myRemLead or 0) >= 0.8 and enTotalMana >= 75 and myWESpentLead)
    local dryVsMultiCoil = H.IsDryVsEnemyRaze(bot, enemy)
    local pressSoulLead = (not dryVsMultiCoil) and (not stackedSpentVsCoil) and myHp >= 300 and creepsOnMe <= 1
        and earlyRace and earlyRace.valid and not earlyRace.heCanKillSoon
        and ((myAtk >= enAtk + 7 and not uphill and (earlyRace.edge or 0) >= 45)
            or crushingSoulLead)

    local movingAwayLead = K.IsEnemyMovingAway(bot, enemy)
    local baseAtkR = math.max(525, atkRange)
    local maxReach = ((enemyDry and myHp >= enHp + 110 and enHp <= 400)
        or (enemyDry and myAtk >= enAtk + 12 and myHp >= 265)
        or (not dryVsMultiCoil and crushingSoulLead and enTotalMana < 150))
        and (baseAtkR + 225) or (baseAtkR + (movingAwayLead and 22 or 45))
    if (pressDryKill or pressSoulLead) and d <= maxReach then
        if H.IssueHeroAttack(bot, enemy) then
            State.lastHarassTime = GameTime()
            return true
        end
    end
    return false
end

function H.InLosingHeroTrade(bot, s, race)
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local rawEnHp = enemy:GetHealth() or 9999
    local enHp = (U.GetEnemyEffectiveCombatHp and math.max(rawEnHp, U.GetEnemyEffectiveCombatHp(enemy, 2.5))) or rawEnHp
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = myHp / myMaxHp
    local enRange = (enemy:GetAttackRange() or 500)
    local valid = race and race.valid
    local outMatched = valid and (race.heHasBootsLead or ((enemy:GetLevel() or 1) > (bot:GetLevel() or 1)))
    if valid and (race.canKillNow
        or (not outMatched and race.canKillSoon and (race.edge or 0) >= -30)
        or (race.canKillSoon and not race.heCanKillSoon and (race.edge or 0) >= 60)) then
        return false
    end

    -- `9056469656.dem` `02:29–02:35` & `01:42–02:02` Fix + `v7.9.14` Courier-ETA & Asymmetric-Wave Guard:
    -- NEVER treat a pure dry-mana right-click trade on flat/allied ground as "losing" when the enemy has `< 75 MP`
    -- (`0` Shadowrazes AND no courier/backpack Mango arriving inside `1.85s`!) and we beat them in HP / TTK without
    -- tanking a massive one-sided enemy creep wave (`netCreepDisadv < 95`)!
    local enSoonManaExtra = 0
    if U.GetEnemyIncomingCourierMana then
        enSoonManaExtra = enSoonManaExtra + (U.GetEnemyIncomingCourierMana(bot, enemy, 1.85) or 0)
    end
    if U.GetUnlockingMangoMana then
        enSoonManaExtra = enSoonManaExtra + (U.GetUnlockingMangoMana(enemy, 2.2) or 0)
    end
    local enTotalPool = (enemy:GetMana() or 0) + U.GetMangoMana(enemy) + enSoonManaExtra
    local enemyDry = (enTotalPool < 75) and (K.EnemyPhase() == nil)
    local myAtkNow = K.AttackDamageVs(bot, enemy)
    local enAtkNow = K.AttackDamageVs(enemy, bot)
    local netCreep = (valid and math.max(0, race.netCreepDisadv or 0)) or 0
    local creepSafeForDryBrawl = (not valid)
        or ((myHp - (race.brawlCreepDmgMe or 0) - enAtkNow * 2.0) >= 75)
    local winningDryBrawl = valid and not race.uphillPenalty and creepSafeForDryBrawl
        and ((enemyDry and (myHp - netCreep) >= enHp + 95 and (race.ttkHim or 999) < (race.ttkMe or 999) * 0.82)
            or (enemyDry and myHp >= 300 and (myHp - netCreep) >= enHp - 35 and myAtkNow >= enAtkNow + 6)
            or (enTotalPool < 150 and not race.heCanKillSoon and (myHp - netCreep - K.EnemyRazeDamage(bot, enemy, 1)) >= 245
                and myAtkNow >= enAtkNow + 12))
    if winningDryBrawl then return false end

    -- `v7.9.13-pro` + `v7.9.14-pro` (`0210 @ 11:22..11:27.20` Death #1 + `16:13..16:19` + `10:02` Coil/HP-Deficit Bailout):
    local _, myReadyRaw = K.MyReadyRazeCount(bot, true)
    local myCastN = math.min(myReadyRaw or 0, (K.MyEffectiveRazeBudgetAt and K.MyEffectiveRazeBudgetAt(bot, true, 1.45)) or 0)
    local enCastN = K.EnemyCastableRazeCount and K.EnemyCastableRazeCount(enemy, 1.6) or 0
    local myStTr, myRemTr = U.GetShadowrazeDebuff(bot)
    local closeBrawlLim = math.max(595, enRange + 90)
    if enHp > myAtkNow * 2.15 then
        if myCastN == 0 and ((dist <= closeBrawlLim and enCastN >= 2 and (hpPct <= 0.72 or (myHp - K.EnemyRazeDamage(bot, enemy, 2)) < 380))
            or (dist <= 755 and enCastN >= 1 and (myStTr or 0) >= 1 and (myRemTr or 0) > 0.6 and myHp < 840)) then
            return true
        end
        if dist <= closeBrawlLim + 45 and enHp >= myHp + 215 and enCastN >= math.max(2, myCastN)
            and (myHp - K.EnemyRazeDamage(bot, enemy, math.min(2, enCastN))) < 340 then
            return true
        end
    end

    local lethalGuardDist = outMatched
        and math.max(845, enRange + 300, (race.minSafeDist or 0) + 90)
        or math.max(enRange + 280, (race.minSafeDist or 0) + 90)
    if valid and race.heCanKillSoon and dist <= lethalGuardDist then
        return true
    end

    local beingAttacked = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.1))
        or false
    -- Never stand on river lowground (`uphillPenalty`) or tanking >= 2 creeps eating enemy right-clicks!
    local creepAggroOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then
            creepAggroOnMe = creepAggroOnMe + 1
        end
    end
    if beingAttacked and dist <= enRange + 110 and valid and not race.spellWindow then
        if race.uphillPenalty or creepAggroOnMe >= 2
            or ((race.netCreepDisadv or 0) >= 65 and (race.edgeLong or 0) < -55 and not race.canKillSoon)
            or ((bot:GetLevel() or 1) <= 3 and (race.edgeLong or 0) < -65) then
            return true
        end
    end
    if valid and race.losingHard and not race.spellWindow
        and (beingAttacked or (hpPct <= 0.55 and dist <= enRange + 240))
        and dist <= enRange + 295 then
        return true
    end

    return false
end

function H.DisengageFromLethalTrade(bot, s, race)
    local enemy = s and s.enemy
    State.commitKillUntil = 0
    State.prepTarget = nil
    State.lhAttackTarget = nil
    H.ManageTreads(bot, "SURVIVE")
    local fountain = P.GetFountain(bot)
    local bLoc = bot:GetLocation()

    -- `9069188041.dem` `03:38.8-03:49.5` Death #2 Counter-Raze & Dry-Enemy Finish Fix:
    -- Previously `if myHp <= 165` returned BEFORE checking ANY counter-Raze, causing `121 HP / 220 MP` Bot with
    -- `3/3` ready Razes to run away and die casting `0` Razes against a `10-18 MP` (`0`-Raze!) Human!
    if enemy and U.CanQuery(enemy) and enemy:IsAlive()
        and (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
        local eLocNow = enemy:GetLocation()
        local curDist = U.DistanceBetweenLocations(bLoc, eLocNow)
        if curDist <= 915 then
            local myHpNow = bot:GetHealth() or 0
            local enAtkRange = (enemy:GetAttackRange() or 525)
            local enAtkNow = K.AttackDamageVs(enemy, bot)
            local enNoCoils = (K.EnemyCastableRazeCount(enemy, 0.8) == 0)
            local enSurvHp = (enemy:GetHealth() or 9999)
                + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy)) or 0)
                + (U.GetStickCharges(enemy) or 0) * 15
            local oneMyRaze = U.GetNRazeDamage(bot, enemy, 1)
            local twoMyRaze = U.GetNRazeDamage(bot, enemy, 2)
            local myReadyN = K.MyReadyRazeCount(bot, true)
            local canOneRazeKill = (oneMyRaze >= enSurvHp)
            local canDryTwoRazeKill = enNoCoils and (myReadyN >= 2) and (twoMyRaze >= enSurvHp)
                and (curDist > enAtkRange + 30 or myHpNow > enAtkNow + 15)
            local enAppClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
            local angToEnemyNow = U.GetAngleDifference(bot, eLocNow)
            -- When critically low (`<= 225 HP`) and NOT lethal (`not canDryTwoRazeKill`), NEVER turn `180 deg` while
            -- fleeing (`0.20s` turn + `0.55s` cast = `~230u` gap lost -> enemy walks inside `525u` right-click range!):
            -- only fire a non-lethal `freeDryFarRaze` when ALREADY facing the enemy (`<= 35 deg`) at `>= 680u` (`+155u`)!
            local safeNonLethalFar = (myHpNow > 225)
                or (angToEnemyNow <= 35 and curDist >= enAtkRange + 155)
            local freeDryFarRaze = enNoCoils
                and (curDist >= enAtkRange + 65)
                and (curDist - enAppClose * 0.60 >= enAtkRange + 10)
                and (myHpNow > 105)
                and safeNonLethalFar
                and not H.HasEnemyProjectileIncoming(bot)
            -- `auto-20261031-0230` `02:09.1` Self-Root Death #2 Fix:
            -- NEVER turn `180 deg` + self-root `0.55s` (`~230u` gap lost!) at `(645, 517)` (`d=334u`) for a non-lethal
            -- `69`-damage coil when `myMS >= enMS` and running straight past our T1/wave saves our life!
            -- Fire a close last-stand coil ONLY when `raze + 1 hit` threatens lethal OR a faster Boots enemy
            -- (`enMS >= myMS + 25`) is already on top of us (`<= 420u`) with near-zero turn delay!
            local myMSClose = bot:GetCurrentMovementSpeed() or 305
            local enMSClose = enemy:GetCurrentMovementSpeed() or 305
            local razePlusHitKills = (oneMyRaze + K.AttackDamageVs(bot, enemy) >= enSurvHp)
                and (myHpNow > enAtkNow + 20)
            local inescapableClose = (enMSClose >= myMSClose + 25)
                and (curDist <= 420)
                and (myHpNow <= enAtkNow * 1.45)
                and (U.GetAngleDifference(bot, eLocNow) <= 30)
            -- `v7.9.17-pro` (`1507 @ 05:41–05:49` `305 MS vs 350 MS` Inescapable Boots-Chase Deterrence & Salve-Break!):
            -- When a `+20..45 MS` faster enemy is actively running us down (`pure running cannot escape!`) and either
            -- drinks `modifier_flask_healing` mid-chase (`05:48.40`!) or walks into our centered `W450`/`E700` while we
            -- hold `2+` ready coils (`>= 150 MP`) and `0` stacks on us (`myHpNow >= 195`), fire our deterrence/Salve-break coil!
            local myStacksFlee = (U.GetShadowrazeDebuff and select(1, U.GetShadowrazeDebuff(bot))) or 0
            local minHpForChaseSalveBreak = (curDist >= enAtkRange + 85)
                and math.max(145, enAtkNow * 1.15)
                or math.max(175, enAtkNow * 1.65)
            local fasterChaserSalveBreak = (enMSClose >= myMSClose + 18)
                and enemy:HasModifier("modifier_flask_healing")
                and (curDist <= 820)
                and (myHpNow >= minHpForChaseSalveBreak)
            local fasterChaserCenteredCoil = (enMSClose >= myMSClose + 22)
                and (myReadyN >= 2) and ((bot:GetMana() or 0) >= 150)
                and ((myStacksFlee or 0) == 0)
                and (myHpNow >= math.max(210, K.EnemyRazeDamage(bot, enemy, 1) + 45))
                and (math.abs(curDist - 450) <= 135 or math.abs(curDist - 700) <= 135)
                and ((enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
                    or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 3.0)))
            local lastStandCloseRaze = ((curDist <= enAtkRange + 25) and (razePlusHitKills or inescapableClose)
                    and (not H.HasEnemyProjectileIncoming(bot) or myHpNow > enAtkNow + 12))
                or fasterChaserSalveBreak
                or fasterChaserCenteredCoil
            if canOneRazeKill or canDryTwoRazeKill or freeDryFarRaze or lastStandCloseRaze then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    H.ClearRazeState()
    if not (enemy and U.CanQuery(enemy)) then
        local wp = (P.GetRetreatAnchor and P.GetRetreatAnchor(bot, 480, 340))
            or (bLoc + (fountain - bLoc):Normalized() * math.min(520, U.DistanceBetweenLocations(bLoc, fountain)))
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, wp, 0.65)
    end
    -- Stamp anti-oscillation turnback hysteresis (`auto-20261102-0043` `2:33..2:36` `340 <-> 44 deg` spin fix!)
    State.noHarassTurnbackUntil = math.max(State.noHarassTurnbackUntil or 0, GameTime() + 0.85)

    -- CRITICAL `v7.9.5` ORDERING FIX (`auto-20261102-0139` `7:44.83..7:45.40` `220 HP` Straight-Line `Shadowraze3` Death!):
    -- `Immortal Coil-Ray Break` MUST execute ABOVE `myHp <= 165` AND ABOVE `HandleSurvivalRetreat` (`which previously
    -- intercepted `myHp <= oneRaze + 45` 30 lines higher and ran radially down `ShaNachnetsya`'s `700u` `E` sightline!)!
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local eLocCast = enemy:GetLocation()
        local curDistCast = U.DistanceBetweenLocations(bLoc, eLocCast)
        local isEnemySFCast = (enemy:GetUnitName() == "npc_dota_hero_nevermore")
        local enNoCoilsCast = K.EnemyManaBudget(enemy, true) < 75 or K.EnemyReadyRazeCount(enemy, 0.7, true) == 0
        local inCastPhase = K.EnemyPhase()
        if isEnemySFCast and not enNoCoilsCast and inCastPhase ~= nil and curDistCast >= 180 and curDistCast <= 920 then
            if H.HandleEnemyRazeDodge and H.HandleEnemyRazeDodge(bot, enemy) then
                return true
            end
            local liveC = K.EnemyRazeCenter(enemy, inCastPhase)
            local dLiveC = U.DistanceBetweenLocations(bLoc, liveC)
            local radOutC = (dLiveC > 1.0) and (bLoc - liveC):Normalized() or (fountain - liveC):Normalized()
            -- `v7.9.17-pro` (`1507 @ 05:51.0` `d=616u` `E700` Inner-Hemisphere Turnback Suicide Fix!):
            -- When `bLoc` is on the INNER side of `liveC` (`curDistCast < 700u` for `far` or `< 450u` for `mid`),
            -- `radOutC = (bLoc - liveC):Normalized()` points `180°` BACKWARD straight into `enemy` (`stalling turn + closing gap`)!
            -- Step along the passable perpendicular + homeward escape chord instead so SF keeps 100% forward speed!
            local stepCand = bLoc + radOutC * 320
            if inCastPhase ~= "near" and U.DistanceBetweenLocations(stepCand, eLocCast) < curDistCast - 12 then
                local homeD = (fountain - bLoc):Normalized()
                local aimAxis = (liveC - eLocCast):Normalized()
                local pA = Vector(-aimAxis.y, aimAxis.x, 0)
                local pB = Vector(aimAxis.y, -aimAxis.x, 0)
                local bestPerp = ((pA.x * homeD.x + pA.y * homeD.y) >= (pB.x * homeD.x + pB.y * homeD.y)) and pA or pB
                local altPerp = (bestPerp == pA) and pB or pA
                local try1 = bLoc + (bestPerp * 0.78 + homeD * 0.62):Normalized() * 320
                local try2 = bLoc + (altPerp * 0.78 + homeD * 0.62):Normalized() * 320
                stepCand = U.IsRayPassable(bLoc, try1) and try1 or (U.IsRayPassable(bLoc, try2) and try2 or (bLoc + homeD * 320))
            end
            local lateralPoint = U.EnsurePassable(bot, stepCand)
            State.actionTaken = true
            return H.BeginForcedRetreat(bot, lateralPoint, 0.45)
        end
    end

    local allyT1Ramp = (s and s.allyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
    local function pickPassableSerpentineDir(baseDir, weightBase, weightPerp, probeLen)
        local perpV = Vector(-baseDir.y, baseDir.x, 0)
        local nowSerp = GameTime()
        local sgn = State.retreatSerpSign
        if not sgn or nowSerp >= (State.retreatSerpUntil or 0) then
            -- `v7.9.19` (`9074666246.dem` `#19, #26, #39, #40` Sticky Anti-Sightline Retreat Law):
            -- Lock the lateral side moving AWAY from `enemy:GetFacing()` for `1.50s` instead of flipping every `0.65s` across `0 deg`!
            if enemy and U.CanQuery(enemy) then
                local eL = enemy:GetLocation()
                local fRad = math.rad(enemy:GetFacing() or 0)
                local fx, fy = math.cos(fRad), math.sin(fRad)
                local rx, ry = bLoc.x - eL.x, bLoc.y - eL.y
                local p1Off = math.abs((rx + perpV.x * 130) * (-fy) + (ry + perpV.y * 130) * fx)
                local p2Off = math.abs((rx - perpV.x * 130) * (-fy) + (ry - perpV.y * 130) * fx)
                sgn = (p1Off >= p2Off) and 1.0 or -1.0
            else
                sgn = 1.0
            end
            State.retreatSerpSign = sgn
            State.retreatSerpUntil = nowSerp + 1.50
        end
        for _, trySgn in ipairs({ sgn, -sgn }) do
            local candD = (baseDir * weightBase + perpV * (trySgn * weightPerp)):Normalized()
            local probe = bLoc + candD * probeLen
            local safeFromEnT1 = not (W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(probe, W.s.enemyT1Loc) < 880)
            if safeFromEnT1 and U.IsRayPassable(bLoc, probe) then
                if trySgn ~= sgn then
                    State.retreatSerpSign = trySgn
                    State.retreatSerpUntil = nowSerp + 1.50
                end
                return candD
            end
        end
        -- Narrow river staircase (`e.g. (-449, -449)` in `2048 @ 07:47.60`): both `±34°` hit cliffs — sprint straight up `allyT1` ramp!
        if allyT1Ramp and U.DistanceBetweenLocations(bLoc, allyT1Ramp) > 90 then
            local rampDir = (allyT1Ramp - bLoc):Normalized()
            if U.IsRayPassable(bLoc, bLoc + rampDir * math.min(probeLen, 280)) then
                return rampDir
            end
        end
        return baseDir
    end

    if (bot:GetHealth() or 0) <= 165 then
        -- Route past our allied T1 (`<= 430u` protective aggro radius when T1 is between us and Fountain) & obstacles!
        local eLocCrit = enemy:GetLocation()
        local dirFnt = (fountain - bLoc):Normalized()
        local dCrit = U.DistanceBetweenLocations(bLoc, eLocCrit)
        if enemy:GetUnitName() == "npc_dota_hero_nevermore"
            and dCrit >= 450 and dCrit <= 905
            and (enemy:GetMana() or 0) >= 75
            and K.EnemyRazeReady("far", 1.2) then
            dirFnt = pickPassableSerpentineDir(dirFnt, 0.82, 0.57, 420)
        end
        local rawWp = bLoc + dirFnt * math.min(620, U.DistanceBetweenLocations(bLoc, fountain))
        local wp = H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawWp, 480)
        if s and s.allyT1Alive and s.allyT1Loc then
            local dMeT1 = U.DistanceBetweenLocations(bLoc, s.allyT1Loc)
            local dT1Fnt = U.DistanceBetweenLocations(s.allyT1Loc, fountain)
            local dMeFnt = U.DistanceBetweenLocations(bLoc, fountain)
            if dMeT1 <= 520 and dMeFnt >= dT1Fnt - 120 then
                local hugT1 = s.allyT1Loc + (fountain - s.allyT1Loc):Normalized() * 360
                if U.DistanceBetweenLocations(hugT1, eLocCrit) > U.DistanceBetweenLocations(bLoc, eLocCrit) + 45 then
                    wp = hugT1
                end
            end
        end
        wp = U.EnsurePassable(bot, U.SteerAroundObstacles(bot, wp, s))
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, wp, 0.75)
    end
    if enemy and U.CanQuery(enemy) then
        local eLoc = enemy:GetLocation()
        local myHp = bot:GetHealth() or 0
        local oneRaze = K.EnemyCastableRazeDamage(bot, enemy, 1, nil, 2.2)
        local twoRaze = K.EnemyCastableRazeDamage(bot, enemy, 2, nil, 2.2)
        local enAtk = K.AttackDamageVs(enemy, bot)
        local curDist = U.DistanceBetweenLocations(bLoc, eLoc)
        local isEnemySF = (enemy:GetUnitName() == "npc_dota_hero_nevermore")
        -- `v7.9.19`: Do NOT let `HandleSurvivalRetreat` or collinear `eLoc + homeDir * targetDist` run straight radially
        -- down an armed SF's `W(450)` or `E(700)` facing ray anywhere in `[320..925u]` (`fixes #19, #26, #39, #40`)!
        local razeLineThreatActive = isEnemySF
            and (K.EnemyManaBudget(enemy, true) >= 75)
            and (K.EnemyRazeReady("mid", 1.4) or K.EnemyRazeReady("far", 1.4))
            and curDist >= 320 and curDist <= 925
        if not razeLineThreatActive and myHp <= math.max(175, oneRaze + 45) and H.HandleSurvivalRetreat(bot, enemy, race) then
            State.actionTaken = true
            return true
        end
        local homeDir = (fountain - eLoc):Normalized()
        local approach = U.EnemyApproachSpeed(bot, enemy)
        local baseDist = (myHp <= twoRaze + enAtk * 2.1 + 40) and 940 or 780
        local targetDist = math.min(1180, baseDist + math.min(220, approach * 0.8))
        -- 1. Defensive Snap-Coil Counter when being run down by a faster dry/0-coil enemy (`Death #1` `05:42..05:48` fix!):
        local myMS = bot:GetCurrentMovementSpeed() or 305
        local enMS = enemy:GetCurrentMovementSpeed() or 305
        local enNoCoils = K.EnemyManaBudget(enemy, true) < 75 or K.EnemyReadyRazeCount(enemy, 0.7, true) == 0
        if enNoCoils and enMS > myMS + 10 and curDist <= 520 and (bot:GetMana() or 0) >= 75
            and myHp >= enAtk + 45 and not H.HasEnemyProjectileIncoming(bot) then
            for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local action, aim = H.GetRazeActionType(bot, ab, enemy)
                    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        State.actionTaken = true
                        return true
                    end
                end
            end
        end
        -- 2. Cliff-Safe Anti-`Shadowraze3` Serpentine + Tower-Umbrella Flank Retreat (`v7.9.12-pro` `2319 @ 06:33..06:43` Fix!):
        --   (a) When near/behind `allyT1` and `enemy` flanks laterally around `allyT1` (`latT1 >= 230u`), NEVER compute
        --       `eLoc + (fountain - eLoc):Normalized() * targetDist` (which walked `336 HP` SF `450u` SE from `(711,601)` to
        --       `(1080,438)` right out from behind Dire T1 into `ShaNachnetsya`'s southern flank!). Instead anchor through
        --       `allyT1`'s opposite shadow toward Fountain so `allyT1`'s `700u` attack circle blocks the flanker!
        --   (b) Even away from `allyT1`, when `eLoc` is laterally offset `>= 250u` from `bLoc -> fountain`, retreat along
        --       `bLoc -> fountain` blended with `(bLoc - eLoc)` instead of drifting sideways onto `eLoc -> fountain`!
        local toFntFromMe = (fountain - bLoc):Normalized()
        local awayFromEnemy = (curDist > 5) and (bLoc - eLoc):Normalized() or toFntFromMe
        local rawPoint = nil
        if s and s.allyT1Alive and s.allyT1Loc then
            local t1L = s.allyT1Loc
            local dMeT1 = U.DistanceBetweenLocations(bLoc, t1L)
            local dEnT1 = U.DistanceBetweenLocations(eLoc, t1L)
            local dMeFnt = U.DistanceBetweenLocations(bLoc, fountain)
            local dT1Fnt = U.DistanceBetweenLocations(t1L, fountain)
            local spineT1 = (fountain - t1L):Normalized()
            local relEnT1 = eLoc - t1L
            local latT1 = math.abs(relEnT1.x * (-spineT1.y) + relEnT1.y * spineT1.x)
            if dMeT1 <= 1100 and dMeFnt <= (dT1Fnt + 380) and dEnT1 <= 1380 and latT1 >= 230 then
                local oppT1Dir = (dEnT1 > 5) and (t1L - eLoc):Normalized() or spineT1
                local shadowDir = (oppT1Dir * 0.50 + spineT1 * 0.70):Normalized()
                local shadowDist = math.max(390, targetDist - dEnT1 + 125)
                local shadowPt = t1L + shadowDir * shadowDist
                local fntStepPt = bLoc + toFntFromMe * 320
                if U.DistanceBetweenLocations(shadowPt, fountain) > U.DistanceBetweenLocations(fntStepPt, fountain) then
                    shadowPt = (shadowPt * 0.45 + fntStepPt * 0.55)
                end
                if U.DistanceBetweenLocations(shadowPt, eLoc) > curDist + 35 then
                    rawPoint = shadowPt
                end
            end
        end
        if not rawPoint then
            local relEnMe = eLoc - bLoc
            local latMe = math.abs(relEnMe.x * (-toFntFromMe.y) + relEnMe.y * toFntFromMe.x)
            local retreatDir = homeDir
            if razeLineThreatActive then
                -- Always retreat at a sticky `~26 deg` off-sightline angle across `[320..925u]` vs an armed SF (`cos 26 = 0.90`
                -- radial escape speed + `sin 26 = 0.44` lateral drift = `+185u` off-center, NEVER running down `0 deg` bullseye!)
                local baseD = (latMe >= 250) and (toFntFromMe * 0.74 + awayFromEnemy * 0.26):Normalized() or homeDir
                retreatDir = pickPassableSerpentineDir(baseD, 0.89, 0.45, 380)
                rawPoint = bLoc + retreatDir * 430
            elseif latMe >= 250 then
                local spineBlend = (toFntFromMe * 0.74 + awayFromEnemy * 0.26):Normalized()
                rawPoint = bLoc + spineBlend * math.max(420, targetDist - curDist + 260)
            else
                rawPoint = eLoc + homeDir * targetDist
            end
        end
        local point = H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawPoint, 440)
        -- `auto-20261102-0007` `10:10.37` (`(2044, 1502)` `dAC=40u` `0.40s` Self-Creep Body-Block Fix!):
        -- When fleeing NE/SW straight into an oncoming allied creep wave (`>= 1` allied creep within `210u` in a `38 deg`
        -- forward cone), offset `165u` laterally around the wave so SF never stalls `0.4s` on its own melee creeps!
        if s and s.allyCreeps and #(s.allyCreeps) > 0 then
            local moveVec = point - bLoc
            local moveLen = math.sqrt(moveVec.x * moveVec.x + moveVec.y * moveVec.y)
            if moveLen > 45 then
                local fwd = moveVec:Normalized()
                local perpC = Vector(-fwd.y, fwd.x, 0)
                local blockCount, avgSide = 0, 0
                for _, ac in pairs(s.allyCreeps) do
                    if ac and U.CanQuery(ac) and ac:IsAlive() then
                        local relC = ac:GetLocation() - bLoc
                        local dc = math.sqrt(relC.x * relC.x + relC.y * relC.y)
                        if dc >= 18 and dc <= 215 then
                            local dotF = (relC.x * fwd.x + relC.y * fwd.y) / dc
                            if dotF >= 0.78 then
                                blockCount = blockCount + 1
                                avgSide = avgSide + (relC.x * perpC.x + relC.y * perpC.y)
                            end
                        end
                    end
                end
                if blockCount >= 1 then
                    local dodgeSign = (avgSide >= 0) and -1.0 or 1.0
                    point = bLoc + (fwd * 310) + (perpC * (dodgeSign * 165))
                end
            end
        end
        -- `v7.9.12-pro` (`2319 @ 06:42.33..06:43.00` Dire T2 `(2496, 2112)` `168u` Hull-Bonk Detour Fix!):
        -- Placed AFTER allied-creep lateral dodge so neither `rawPoint` nor `perpC * 165` ever routes the retreat segment
        -- across `allyT2`'s `168u` collision hull (`144u` tower + `24u` hero)! Tangent waypoint sits slightly in front/abreast
        -- of `t2L` (`-uToT2 * 45 + perpT2 * 245`) so the chord clears `t2L` by `>= 195u` cleanly!
        if s and s.allyT2Alive and s.allyT2Loc then
            local t2L = s.allyT2Loc
            local seg = point - bLoc
            local segLen = math.sqrt(seg.x * seg.x + seg.y * seg.y)
            if segLen > 35 then
                local sx, sy = seg.x / segLen, seg.y / segLen
                local rx2, ry2 = t2L.x - bLoc.x, t2L.y - bLoc.y
                local dToT2 = math.sqrt(rx2 * rx2 + ry2 * ry2)
                local proj2 = rx2 * sx + ry2 * sy
                if dToT2 > 25 and proj2 > -20 and proj2 < segLen + 60 then
                    local cx2 = bLoc.x + sx * math.max(0, math.min(segLen, proj2))
                    local cy2 = bLoc.y + sy * math.max(0, math.min(segLen, proj2))
                    local dSegT2 = math.sqrt((t2L.x - cx2) * (t2L.x - cx2) + (t2L.y - cy2) * (t2L.y - cy2))
                    if dSegT2 < 205 then
                        local ux2, uy2 = rx2 / dToT2, ry2 / dToT2
                        local pA = Vector(-uy2, ux2, 0)
                        local pB = Vector(uy2, -ux2, 0)
                        local pullLead = (dToT2 > 235) and -45 or 85
                        local cA = Vector(t2L.x + ux2 * pullLead + pA.x * 248, t2L.y + uy2 * pullLead + pA.y * 248, bLoc.z)
                        local cB = Vector(t2L.x + ux2 * pullLead + pB.x * 248, t2L.y + uy2 * pullLead + pB.y * 248, bLoc.z)
                        point = (U.DistanceBetweenLocations(cA, eLoc) >= U.DistanceBetweenLocations(cB, eLoc)) and cA or cB
                    end
                end
            end
        end
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, point, 0.65)
    end
    return false
end

-- Find an item in slots `0..8`; if in Backpack `6..8`, swap it into the lowest-priority active slot `0..5`
-- cleanly (`branchTangoSwapUntil` holds `ManageInventorySlots` back until the 6.0s Backpack CD unlocks & casts!).
-- Multiple Backpack consumables (e.g. `item_flask` + `item_ward_observer`) swap into DISTINCT active slots on the same tick!
function H.EnsureConsumableReady(bot, itemName)
    local slot = bot:FindItemSlot(itemName)
    if slot < 0 or slot > 8 then return nil, false end
    if slot <= 5 then
        local it = bot:GetItemInSlot(slot)
        -- Hold `branchTangoSwapUntil` BOTH during the 6.0s Backpack CD AND during the short walk/turn to use it!
        State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or -1000, GameTime() + 2.5)
        return it, (it ~= nil and it:IsFullyCastable())
    end
    local bestSlot, bestPrio = nil, math.huge
    for i = 0, 5 do
        local it = bot:GetItemInSlot(i)
        if not it then
            bestSlot = i
            break
        end
        local nm = it:GetName()
        -- Strictly respect unified `U.GetEffectiveItemPriority` AND NEVER displace another active consumable
        -- (`item_tango` / `item_enchanted_mango` / `item_flask` / `item_ward_observer`) — breaks 100% of swap loops!
        if nm ~= "item_boots" and nm ~= "item_power_treads"
            and nm ~= "item_flask" and nm ~= "item_ward_observer"
            and nm ~= "item_tango" and nm ~= "item_enchanted_mango" then
            local pr = U.GetEffectiveItemPriority(bot, nm)
            if pr < bestPrio then
                bestPrio = pr
                bestSlot = i
            end
        end
    end
    if bestSlot ~= nil then
        bot:ActionImmediate_SwapItems(slot, bestSlot)
        if U.BumpInventoryEpoch then U.BumpInventoryEpoch() end
        State.branchTangoSwapUntil = GameTime() + 8.5
        local moved = bot:GetItemInSlot(bestSlot)
        return moved, (moved ~= nil and moved:IsFullyCastable())
    end
    return nil, false
end

-- Immediate Anti-Free-Harass Retaliation (`auto-20261023-1329-start-ShaNachnetsya.dem` `tk=6142..6326` & `tk=10644..10874` Fix!):
-- Whenever the live rival hero right-clicks us within `720u` outside an active final CS windup, NEVER stand idle or
-- auto-attack full-HP creeps while taking unanswered right-clicks! Immediately punish with a centered `Shadowraze` +
-- right-click (when healthy/even), OR step crisply outside his attack range (when low/outmatched)!
function H.HandleAntiFreeHarassRetaliation(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if d > 730 then return false end

    local activelyHittingMe = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.35))
    if not activelyHittingMe then return false end

    -- Never brawl inside enemy T1 attack range!
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) <= 760 then
            return H.DisengageFromLethalTrade(bot, s, earlyRace)
        end
    end

    local enAtk = K.AttackDamageVs(enemy, bot)
    local myAtk = K.AttackDamageVs(bot, enemy)
    local inFlightOnMe = 0
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, pr in pairs(projs) do
                if pr then
                    local caster = pr.caster
                    inFlightOnMe = inFlightOnMe + ((caster and caster.IsHero and caster:IsHero()) and enAtk or 18)
                end
            end
        end
    end
    local myEffHp = math.max(1, (bot:GetHealth() or 0) - inFlightOnMe)
    local enHp = enemy:GetHealth() or 9999
    local lr = U.SolveLethalRace(bot, enemy, s)
    local mySt, myRem = U.GetShadowrazeDebuff(bot)
    local r2Ret = bot:GetAbilityByName("nevermore_shadowraze2")
    local r3Ret = bot:GetAbilityByName("nevermore_shadowraze3")
    local myWESpentRet = (not (r2Ret and U.IsRazeAbilityCastable(bot, r2Ret)))
        and (not (r3Ret and U.IsRazeAbilityCastable(bot, r3Ret)))
    local enMpRet = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local stackedSpentRetal = ((mySt or 0) >= 1 and (myRem or 0) >= 0.8 and enMpRet >= 75 and myWESpentRet and (K.EnemyRazeReadyIn("mid") or 99) <= 1.2)

    -- If low HP or carrying dangerous fresh stacks without first-kill advantage, step clean outside his attack range!
    if not (lr and lr.winsFirstKill) then
        if myEffHp < 235 or stackedSpentRetal or ((mySt or 0) >= 2 and (myRem or 0) > 0.4) or H.InLosingHeroTrade(bot, s, earlyRace) then
            return H.DisengageFromLethalTrade(bot, s, earlyRace)
        end
    end

    -- 1. Punish brazen close/mid/far right-click harass immediately with a dead-center `Shadowraze` —
    --    STRICTLY gated by Raze-Tier / Level-Spike discipline so we NEVER self-root `0.55s` casting an `85`-dmg Raze
    --    into a Level 3/5/7 enemy SF's higher-tier double Raze when they merely tapped us with 1 right-click!
    local outRazedRet = (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local nearSpikeRet = (U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy)) or false
    local allowRazeRetaliate = (lr and lr.winsFirstKill) or (not outRazedRet and not nearSpikeRet)
    local canPopMango = allowRazeRetaliate and (bot:GetMana() or 0) < 75 and myEffHp >= 260 and d <= 650
    if canPopMango and H.TryUseBurstManaItem(bot, true) then
        return true
    end
    if allowRazeRetaliate and not bot:IsSilenced() and (bot:GetMana() or 0) >= 75
        and not ((mySt or 0) == 1 and (myRem or 0) <= 2.0 and (myRem or 0) > 0.2) then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    -- 2. Return crisp right-click when trade is even/favorable (`myEffHp >= enHp * 0.62` or winning hit count), else kite back!
    -- `9074178342.dem` `04:20..04:26` Uphill + Creep-Pack Guard: NEVER click uphill (`25%` miss) into `3+` enemy creeps (`<= 500u`)
    -- unless `SolveLethalRace` proves we win first-kill!
    local bLocRet = bot:GetLocation()
    local eLocRet = enemy:GetLocation()
    local uphillRet = ((eLocRet.z or 0) - (bLocRet.z or 0)) >= 85
    local nearEnCreepsRet = 0
    if uphillRet and s and s.enemyCreeps then
        for _, ec in pairs(s.enemyCreeps) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(bLocRet, ec:GetLocation()) <= 500 then
                nearEnCreepsRet = nearEnCreepsRet + 1
            end
        end
    end
    local aggroCdActiveRet = GameTime() < ((State.myCreepAggroCdUntil or 0) - 0.25)
    local uphillCreepPackTrap = uphillRet and (not aggroCdActiveRet) and (nearEnCreepsRet >= 3)
        and (enMpRet >= 75 or myEffHp < 380) and not (lr and lr.winsFirstKill)
    local effMyAtkRet = uphillRet and math.max(1, myAtk * 0.75) or math.max(1, myAtk)
    local winningOrEvenClick = not uphillCreepPackTrap and ((lr and lr.winsFirstKill)
        or (math.ceil(enHp / effMyAtkRet) <= math.ceil(myEffHp / math.max(1, enAtk)) + 1 and myEffHp >= 270)
        or (myEffHp >= enHp * 0.68 and myEffHp >= 260 and not uphillRet))
    if winningOrEvenClick and d <= (bot:GetAttackRange() or 500) + 95 then
        local prevPolicy = State.combatPolicyActive
        local prevAllow = State.heroCombatAllowed
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local okAtk = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive = prevPolicy
        State.heroCombatAllowed = prevAllow
        if okAtk then
            State.actionTaken = true
            return true
        end
    end

    return H.DisengageFromLethalTrade(bot, s, earlyRace)
end

-- Safe Enemy Observer/Sentry Deward (`A16` Team-Guarded Ward Check + Free Highground Vision Denial!):
-- Strictly requires `w:GetTeam() ~= bot:GetTeam()` so own/allied Observer Wards are NEVER attacked!
function H.HandleFreeEnemyWardDeward(bot, s)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if L._imminentCS then return false end
    if type(GetUnitList) ~= "function" or not UNIT_LIST_ENEMY_WARDS then return false end
    local enemy = s and s.enemy
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() and (s.enemyDist or 9999) <= 760 then
        return false
    end
    local danger = LN.TowerDanger(bot, s and s.enemyT1 or nil, s and s.allyCreeps or nil, nil)
    if danger >= 1 then return false end
    local ok, wards = pcall(GetUnitList, UNIT_LIST_ENEMY_WARDS)
    if not ok or type(wards) ~= "table" then return false end
    local myTeam = bot:GetTeam()
    local maxReach = (bot:GetAttackRange() or 500) + 95
    for _, w in pairs(wards) do
        local wName = (w and w.GetUnitName and w:GetUnitName()) or ""
        if wName:find("ward") and U.CanQuery(w) and w:IsAlive() and w.GetTeam and w:GetTeam() ~= myTeam then
            if GetUnitToLocationDistance(bot, w:GetLocation()) <= maxReach then
                if not (U.IsAttackingAction(bot) and bot:GetAttackTarget() == w) then
                    bot:Action_AttackUnit(w, true)
                    H.ClearMoveCache()
                end
                State.actionTaken = true
                return true
            end
        end
    end
    return false
end

-- Dedicated Top-Priority Enemy Salve Breaker (`W5 07:01.7` Fix + `v7.9.10-pro` `2048 @ 07:46.00` `276 HP` Suicide Turnback Fix!)
function H.HandleBreakEnemySalve(bot, s, _earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if not enemy:HasModifier("modifier_flask_healing") then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dHero > 960 then return false end
    local now = GameTime()
    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = myHp / myMaxHp
    local enHp = enemy:GetHealth() or 9999
    local myAtkReach = (bot:GetAttackRange() or 525) + 115
    local oneMyCoilKills = (enHp <= K.MyRazeDamage(bot, enemy, 1) - 10) and ((bot:GetMana() or 0) + U.GetMangoMana(bot) >= 75)
    local oneMyAutoKills = (enHp <= K.AttackDamageVs(bot, enemy) + 4) and (dHero <= myAtkReach)
    local safeAutoVsCooldownEnemy = (dHero <= (bot:GetAttackRange() or 525) + 75)
        and (K.EnemyRazeReadyIn("near") >= 1.25 and K.EnemyRazeReadyIn("mid") >= 1.25 and K.EnemyRazeReadyIn("far") >= 1.25)
        and (myHp > K.AttackDamageVs(enemy, bot) + 65)
    -- `2048 @ 07:46.00` (`276/1232 HP = 22.4%`) + `v7.9.16-pro` (`1343 @ 10:34.40` `72 HP` Cooldown-Safe Finish Override!):
    -- NEVER spin `180°` and self-root `0.55s` to break Salve when fleeing / in critical danger UNLESS:
    --   (a) 1 coil kills (`oneMyCoilKills`), OR
    --   (b) 1 right-click kills (`oneMyAutoKills`, e.g. `72 HP` enemy vs `108` physical AA!), OR
    --   (c) all 3 enemy coils are on CD (`>= 1.25s`) and a safe right-click cancels his `+390 HP` Salve (`safeAutoVsCooldownEnemy`)!
    if not (oneMyCoilKills or oneMyAutoKills or safeAutoVsCooldownEnemy) then
        if State.forcedRetreatLoc or (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0)) then
            return false
        end
        if H.InCriticalLethalDanger and H.InCriticalLethalDanger(bot, s, _earlyRace) then
            return false
        end
        if hpPct < 0.34 or (_earlyRace and _earlyRace.valid and (_earlyRace.heCanKillNow or _earlyRace.heCanKillSoon or _earlyRace.losingHard)) then
            return false
        end
        -- Also evaluate burst at the distance the enemy can close to during our `0.15s turn + 0.55s cast = 0.70s` self-root!
        local postCastDist = math.max(200, dHero - (enemy:GetCurrentMovementSpeed() or 310) * 0.70)
        if myHp <= K.EnemyBurstVs(bot, enemy, postCastDist, 1.35, false) + 115 then
            return false
        end
    elseif oneMyAutoKills or safeAutoVsCooldownEnemy then
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if not (U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemy) then
            bot:Action_AttackUnit(enemy, true)
            H.ClearMoveCache()
        end
        State.commitKillUntil = now + 1.5
        State.actionTaken = true
        return true
    end
    if myHp <= K.EnemyBurstVs(bot, enemy, dHero, 0.85, false) + 75 then return false end
    if dHero <= (bot:GetAttackRange() or 525) + 175 then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    elseif dHero <= 935 then
        local myMana = bot:GetMana() or 0
        if myMana < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
            return true
        end
        if myMana >= 75 and not bot:IsSilenced() then
            for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local action, aim = H.GetRazeActionType(bot, ab, enemy)
                    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Uncontested Wave Creep-Tank Drop (`v5.2.0` `creep_tank` synthesis, strictly gated by `L.PeekBestPlan` so 0 CS are lost!):
-- When enemy lane creeps are hitting SF (`GetAttackTarget() == bot` or unshielded proximity) and no CS opens within `1.25s`,
-- drop aggro onto our allied wave or kite smoothly toward `behindT1` instead of tanking 300+ free creep damage!
function H.HandleCreepTankDrop(bot, s)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if L._imminentCS then return false end
    if L.PeekBestPlan then
        local _, etaSec = L.PeekBestPlan(bot, s)
        if etaSec <= 1.25 then return false end
    end
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() and (ec:GetHealth() or 999) <= (U.SFDamageRange(bot, ec).min + 12) then
            return false
        end
    end
    local bLoc = bot:GetLocation()
    local hittingCount, closestEnemyCreep, closestDist = 0, nil, math.huge
    local rangedHitting = nil
    local hasAllyShield = #(s and s.allyCreeps or {}) > 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() then
            local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
            local cRng = (ec.GetAttackRange and ec:GetAttackRange()) or 100
            local lockedOnMe = (ec.GetAttackTarget and ec:GetAttackTarget() == bot)
                or (not hasAllyShield and dc <= math.max(195, cRng + 35))
            if lockedOnMe then
                hittingCount = hittingCount + 1
                if cRng > 300 and dc <= 525 then rangedHitting = ec end
                if dc < closestDist then closestDist, closestEnemyCreep = dc, ec end
            end
        end
    end
    if hittingCount == 0 then return false end
    if hittingCount == 1 and hasAllyShield and (bot:GetHealth() or 0) > (bot:GetMaxHealth() or 600) * 0.65 then
        return false
    end
    local now = GameTime()
    local chaseLocked = now < ((State.myCreepChaseUntil or 0) - 0.08)
    local bestAlly, anyLiveAlly = H.FindSafeDeaggroAllyCreep(bot, s and s.allyCreeps, s and s.enemy)
    if not chaseLocked and not rangedHitting and bestAlly and now >= (State.lastTankDeaggroAt or -100) + 1.35 then
        State.lastTankDeaggroAt = now
        bot:Action_AttackUnit(bestAlly, true)
        State.actionTaken = true
        return true
    end
    bestAlly = bestAlly or anyLiveAlly
    local fnt = P.GetFountain(bot)
    local anchor
    if bestAlly and U.DistanceBetweenLocations(bestAlly:GetLocation(), fnt) <= U.DistanceBetweenLocations(bLoc, fnt) + 45 then
        anchor = bestAlly:GetLocation() + (fnt - bestAlly:GetLocation()):Normalized() * (rangedHitting and 340 or 230)
    else
        anchor = (P.GetBehindT1 and P.GetBehindT1(bot, 195)) or (bLoc + (fnt - bLoc):Normalized() * 340)
    end
    if H.SmartMove(bot, anchor, 35) then
        return true
    end
    return false
end

-- Resolve live + fallback Patch 7.41f Mid Tower coordinates (`T1, T2, T3`) for both teams.
function H.GetMidTowerGeometry(bot)
    local isRad = (bot:GetTeam() == TEAM_RADIANT)
    local myTeam = bot:GetTeam()
    local enTeam = (type(GetOpposingTeam) == "function" and GetOpposingTeam()) or (isRad and TEAM_DIRE or TEAM_RADIANT)
    local myT1 = isRad and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
    local myT2 = isRad and C.POSITIONS.RADIANT_T2 or C.POSITIONS.DIRE_T2
    local myT3 = isRad and C.POSITIONS.RADIANT_T3 or C.POSITIONS.DIRE_T3
    local enT1 = isRad and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local enT2 = isRad and C.POSITIONS.DIRE_T2 or C.POSITIONS.RADIANT_T2
    if type(GetTower) == "function" then
        local function qTw(tm, slot, fb)
            if slot == nil then return fb end
            local ok, tw = pcall(GetTower, tm, slot)
            if ok and tw and U.CanQuery(tw) and tw:IsAlive() then
                return tw:GetLocation() or fb
            end
            return fb
        end
        myT1 = qTw(myTeam, TOWER_MID_1, myT1)
        myT2 = qTw(myTeam, TOWER_MID_2, myT2)
        myT3 = qTw(myTeam, TOWER_MID_3, myT3)
        enT1 = qTw(enTeam, TOWER_MID_1, enT1)
        enT2 = qTw(enTeam, TOWER_MID_2, enT2)
    end
    return isRad, myT1, myT2, myT3, enT1, enT2
end

function H.EnsurePassableOutsideTowers(pt, twA, twB, minTowerDist)
    if not pt then return nil end
    local minD = minTowerDist or 960
    local function okPt(cand)
        if twA and U.DistanceBetweenLocations(cand, twA) < minD then return false end
        if twB and U.DistanceBetweenLocations(cand, twB) < minD then return false end
        if type(IsLocationPassable) == "function" and not IsLocationPassable(cand) then return false end
        return true
    end
    if okPt(pt) then return pt end
    for r = 70, 350, 70 do
        for k = 0, 11 do
            local a = (k * math.pi) / 6.0
            local cand = Vector(pt.x + math.cos(a) * r, pt.y + math.sin(a) * r, pt.z or 128)
            if okPt(cand) then return cand end
        end
    end
    return pt
end

-- `auto-20261102-0159-start-ShaNachnetsya.dem` Fix #2:
-- Guarantee `standPt` stays strictly within `<= maxWardDist` (`435u < 475u` cast gate) of `wardTarget` AFTER passability
-- nudging! Previously `EnsurePassableOutsideTowers` nudged `(1210, 1675)` to `(1120, 1760)` (`543.1u > 475u`), causing SF
-- to arrive at `standPt` in `ACT_DOTA_IDLE` while forever waiting for `dToWard2 <= 475`!
function H.EnsureWardStandPoint(prefPt, wardTarget, twA, twB, minTowerDist, maxWardDist)
    if not wardTarget then return prefPt end
    local minTw = minTowerDist or 955
    local maxWd = maxWardDist or 435
    local function okStand(cand)
        if not cand then return false end
        if U.DistanceBetweenLocations(cand, wardTarget) > maxWd then return false end
        if twA and U.DistanceBetweenLocations(cand, twA) < minTw then return false end
        if twB and U.DistanceBetweenLocations(cand, twB) < minTw then return false end
        if type(IsLocationPassable) == "function" and not IsLocationPassable(cand) then return false end
        return true
    end
    if prefPt and okStand(prefPt) then return prefPt end
    if prefPt then
        for r = 64, 420, 64 do
            for k = 0, 15 do
                local a = (k * math.pi) / 8.0
                local cand = Vector(prefPt.x + math.cos(a) * r, prefPt.y + math.sin(a) * r, prefPt.z or 128)
                if okStand(cand) then return cand end
            end
        end
    end
    if okStand(wardTarget) then return wardTarget end
    for r = 80, 400, 80 do
        for k = 0, 15 do
            local a = (k * math.pi) / 8.0
            local cand = Vector(wardTarget.x + math.cos(a) * r, wardTarget.y + math.sin(a) * r, wardTarget.z or 128)
            if okStand(cand) then return cand end
        end
    end
    return wardTarget
end

-- Check whether an alive allied Observer Ward already sits within `minDist` of `spot` (prevents double-warding!).
function H.HasAlliedObserverNear(spot, minDist)
    if not spot then return false end
    local rad = minDist or 880
    local now = GameTime()
    if State.lastPlacedWardLoc and State.lastPlacedWardAt and (now - State.lastPlacedWardAt) <= 340.0 then
        if U.DistanceBetweenLocations(State.lastPlacedWardLoc, spot) <= rad then
            -- Verify via `UNIT_LIST_ALLIED_WARDS` when available; if API unavailable, respect recent cache for 75s
            if type(GetUnitList) ~= "function" or not UNIT_LIST_ALLIED_WARDS then
                if (now - State.lastPlacedWardAt) <= 75.0 then return true end
            end
        end
    end
    if type(GetUnitList) == "function" and UNIT_LIST_ALLIED_WARDS then
        local okW, aWards = pcall(GetUnitList, UNIT_LIST_ALLIED_WARDS)
        if okW and aWards then
            for _, aw in pairs(aWards) do
                if aw and U.CanQuery(aw) and aw:IsAlive() then
                    local wn = (aw.GetUnitName and aw:GetUnitName()) or ""
                    if wn == "" or string.find(wn, "observer", 1, true) then
                        if U.DistanceBetweenLocations(aw:GetLocation(), spot) <= rad then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Open-Ground Multi-Waypoint Corridor + Self-Recorded NavMesh Breadcrumb Reversal (`v7.9.3`,
-- fixes BOTH `auto-20261101-2135.dem` & `9072220529.dem` `(-2209,-663)` / `(-2143,-625)` / `(-1318,-452)` stalls!):
--   1. Outbound to Ward #2 walks the explicit open-ground northern/NW corridor (`WARD2_CORRIDOR_FOR_DIRE/RADIANT`,
--      `1,021u..1,480u` outside Enemy T1 with `0` radial `tangCand` walls!) AND records live navmesh breadcrumbs
--      `State.ward2Breadcrumbs` every `220u` along the actual path SF physically walked at `305 MS`.
--   2. Inbound from Ward #2 pops `State.ward2Breadcrumbs` strictly in reverse (`#list -> 1`), retracing the exact
--      100%-passable outbound footsteps back to `WARD_1` on the river, guarded by a `0.45s` real-velocity watchdog
--      that skips any dynamically body-blocked waypoint so SF can NEVER walk in place!
function H.RecordWard2Breadcrumb(bot)
    local bLoc = bot:GetLocation()
    if not bLoc then return end
    State.ward2Breadcrumbs = State.ward2Breadcrumbs or {}
    local crumbs = State.ward2Breadcrumbs
    if #crumbs == 0 then
        local isRad = (bot:GetTeam() == TEAM_RADIANT)
        local riverAnchor = isRad and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
        if riverAnchor then
            crumbs[#crumbs + 1] = Vector(riverAnchor.x, riverAnchor.y, riverAnchor.z or 128)
        end
    end
    local last = crumbs[#crumbs]
    if not last or U.DistanceBetweenLocations(bLoc, last) >= 220 then
        crumbs[#crumbs + 1] = Vector(bLoc.x, bLoc.y, bLoc.z or 128)
    end
end

function H.FollowWard2ReturnBreadcrumbs(bot)
    local crumbs = State.ward2Breadcrumbs
    if not crumbs or #crumbs == 0 then return false end
    local bLoc = bot:GetLocation()
    local now = GameTime()

    -- Pop all breadcrumbs already reached (`<= 155u`) OR already behind us toward Enemy T2
    while #crumbs > 0 and U.DistanceBetweenLocations(bLoc, crumbs[#crumbs]) <= 155 do
        table.remove(crumbs, #crumbs)
        State.crumbStuckCheckAt = nil
        State.crumbStuckRefLoc = nil
    end
    if #crumbs == 0 then return false end

    -- Real-velocity `0.45s` anti-stuck watchdog: if blocked by hero/trees (`moved < 24u` in `0.45s`), skip current crumb!
    if not State.crumbStuckCheckAt or not State.crumbStuckRefLoc then
        State.crumbStuckCheckAt = now
        State.crumbStuckRefLoc = bLoc
    elseif (now - State.crumbStuckCheckAt) >= 0.45 then
        if U.DistanceBetweenLocations(bLoc, State.crumbStuckRefLoc) < 24 then
            table.remove(crumbs, #crumbs)
        end
        State.crumbStuckCheckAt = now
        State.crumbStuckRefLoc = bLoc
    end
    if #crumbs == 0 then return false end

    local targetWp = crumbs[#crumbs]
    bot:Action_MoveToLocation(targetWp)
    State.lastMoveLoc = targetWp
    State.lastMoveTime = now
    State.actionTaken = true
    return true
end

function H.SafeArcMoveAroundEnemyTowers(bot, goalLoc)
    local isRad, _, _, _, enT1, enT2 = H.GetMidTowerGeometry(bot)
    local bLoc = bot:GetLocation()
    local now = GameTime()
    local corridor = isRad and C.POSITIONS.WARD2_CORRIDOR_FOR_RADIANT or C.POSITIONS.WARD2_CORRIDOR_FOR_DIRE

    local vx, vy = goalLoc.x - bLoc.x, goalLoc.y - bLoc.y
    local segLen2 = vx * vx + vy * vy
    local segMinDistEnT1 = U.DistanceBetweenLocations(bLoc, enT1)
    if segLen2 > 25 then
        local tSeg = math.max(0.0, math.min(1.0, ((enT1.x - bLoc.x) * vx + (enT1.y - bLoc.y) * vy) / segLen2))
        local cx, cy = bLoc.x + vx * tSeg, bLoc.y + vy * tSeg
        segMinDistEnT1 = math.sqrt((enT1.x - cx) * (enT1.x - cx) + (enT1.y - cy) * (enT1.y - cy))
    end

    -- `930u` clears both `700u` tower attack and `900u` True Sight while allowing the natural `951u` Dire river corridor!
    local nextWp = goalLoc
    local goalKey = math.floor(goalLoc.x * 0.1) .. "_" .. math.floor(goalLoc.y * 0.1)
    if segMinDistEnT1 < 930 and corridor and #corridor >= 2 then
        local bestGoalIdx, bestGoalD = #corridor, math.huge
        for i, wp in ipairs(corridor) do
            local dG = U.DistanceBetweenLocations(goalLoc, wp)
            if dG < bestGoalD then bestGoalD, bestGoalIdx = dG, i end
        end
        if State.arcGoalKey ~= goalKey or not State.arcWpIdx then
            local startIdx, bestCurD = 1, math.huge
            for i, wp in ipairs(corridor) do
                local dB = U.DistanceBetweenLocations(bLoc, wp)
                if dB < bestCurD then bestCurD, startIdx = dB, i end
            end
            State.arcGoalKey = goalKey
            State.arcWpIdx = startIdx
            State.arcCheckAt = now
            State.arcRefLoc = bLoc
        end
        local stepDir = (bestGoalIdx >= State.arcWpIdx) and 1 or -1
        while State.arcWpIdx ~= bestGoalIdx and U.DistanceBetweenLocations(bLoc, corridor[State.arcWpIdx]) <= 165 do
            State.arcWpIdx = math.max(1, math.min(#corridor, State.arcWpIdx + stepDir))
            State.arcCheckAt = now
            State.arcRefLoc = bLoc
        end
        if State.arcCheckAt and State.arcRefLoc and (now - State.arcCheckAt) >= 0.45 then
            if U.DistanceBetweenLocations(bLoc, State.arcRefLoc) < 24 and State.arcWpIdx ~= bestGoalIdx then
                State.arcWpIdx = math.max(1, math.min(#corridor, State.arcWpIdx + stepDir))
            end
            State.arcCheckAt = now
            State.arcRefLoc = bLoc
        end
        local candWp = (State.arcWpIdx == bestGoalIdx and U.DistanceBetweenLocations(bLoc, corridor[bestGoalIdx]) <= 165)
            and goalLoc
            or corridor[State.arcWpIdx]
        nextWp = H.EnsurePassableOutsideTowers(candWp, enT1, enT2, 925) or candWp
    else
        State.arcGoalKey = nil
        State.arcWpIdx = nil
    end
    bot:Action_MoveToLocation(nextWp)
    State.lastMoveLoc = nextWp
    State.lastMoveTime = now
    State.actionTaken = true
end

-- Count total `item_ward_observer` charges in active + backpack slots (`0..8`).
function H.CountInventoryObserverWardCharges(bot)
    local total = 0
    for sl = 0, 8 do
        local it = bot:GetItemInSlot(sl)
        if it and it:GetName() == "item_ward_observer" then
            total = total + math.max(1, (it.GetCurrentCharges and it:GetCurrentCharges()) or 1)
        end
    end
    return total
end

-- Top-Level 2-Ward Pre-Horn Choreographer + Post-Horn 3-Spot Anti-Deward Night Ward Planter (`v7.9.3`):
--   * Pre-Horn Ward #1 (`dtime < 0`): plants on the EXACT standard river highground spot (`WARD_RADIANT` / `WARD_DIRE`).
--   * Pre-Horn Ward #2 (`dtime < -31.0`): detours safely (`R >= 1,020u` outside Enemy T1) along the open corridor while
--     recording `State.ward2Breadcrumbs`, plants between Enemy Mid T1 and T2, and then retraces its exact breadcrumbs back!
function H.HandlePriorityWardPlant(bot, s)
    local now = GameTime()
    if now < (State.lastWardCheckAt or -100) then return false end
    local dtime = DotaTime()
    local totalWardCharges = H.CountInventoryObserverWardCharges(bot)
    if dtime < -84 and totalWardCharges >= 2 then
        State.preHornRiverWardDone = false
        State.preHornEnemyLaneWardDone = false
        State.preHornWard2Aborted = false
        State.riverWardStartCharges = nil
        State.enemyWardStartCharges = nil
        State.ward2Breadcrumbs = nil
    end
    if totalWardCharges <= 0 then
        return false
    end

    local isRad, _, _, _, enT1, enT2 = H.GetMidTowerGeometry(bot)

    -- ========================================================================
    -- PRE-HORN (`dtime < 0`): Ward #1 (own HG) -> Ward #2 (between Enemy T1 & T2)
    -- ========================================================================
    if dtime < 0 then
        -- Confirm Ward #1 completion via actual charge consumption (`2 -> 1` or `1 -> 0`)
        if not State.preHornRiverWardDone then
            if State.riverWardStartCharges and totalWardCharges < State.riverWardStartCharges then
                State.preHornRiverWardDone = true
                State.lastPlacedWardLoc = isRad and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
                State.lastPlacedWardAt = now
                State.wardPlantCount = math.max(1, State.wardPlantCount or 0)
            end
        end
        if State.preHornRiverWardDone and not State.preHornEnemyLaneWardDone then
            if State.enemyWardStartCharges and totalWardCharges < State.enemyWardStartCharges then
                State.preHornEnemyLaneWardDone = true
                State.ward2StallCheckAt = nil
                State.ward2StallCount = 0
                State.wardPlantCount = (State.wardPlantCount or 1) + 1
                return false
            end
        end

        -- PHASE 1: Plant Ward #1 on our `.dem`-verified `z=128` highground spot
        if not State.preHornRiverWardDone then
            if dtime >= -16.0 then
                -- Too close to creep spawn — never miss the T3 opening block!
                State.preHornRiverWardDone = true
                State.preHornWard2Aborted = true
                return false
            end
            local ward1, castable1 = H.EnsureConsumableReady(bot, "item_ward_observer")
            local ward1Loc = isRad and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
            if not ward1Loc then return false end
            State.riverWardStartCharges = State.riverWardStartCharges or totalWardCharges
            local d1 = GetUnitToLocationDistance(bot, ward1Loc)
            if castable1 and ward1 and d1 <= 475 then
                if now >= (State.lastWardCastCmdAt or -100) + 0.25 then
                    bot:Action_UseAbilityOnLocation(ward1, ward1Loc)
                    State.lastPlacedWardLoc = ward1Loc
                    State.lastPlacedWardAt = now
                    State.lastWardCastCmdAt = now
                end
                State.actionTaken = true
                return true
            end
            H.SmartMove(bot, ward1Loc, 42, true)
            State.actionTaken = true
            return true
        end

        -- PHASE 2: Plant Ward #2 between Enemy Mid T1 and Enemy Mid T2 (`R >= 1,020u` outside Enemy T1 & T2!)
        if not State.preHornEnemyLaneWardDone and not State.preHornWard2Aborted then
            local lowHpAbort = (bot:GetHealth() or 600) < (bot:GetMaxHealth() or 600) * 0.80
            local towerHitAbort = bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.0)
            local heroBrawlAbort = s and s.enemy and U.CanQuery(s.enemy) and (s.enemyDist or 9999) <= 560
                and bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.8)
            -- Strict `-31.0s` cutoff guarantees `>= 27.7s` return walk back to Own Mid T3 before `-3.3s` wave march!
            if dtime >= -31.0 or lowHpAbort or towerHitAbort or heroBrawlAbort then
                State.preHornWard2Aborted = true
                State.ward2StallCheckAt = nil
                return false
            end

            H.RecordWard2Breadcrumb(bot)
            local ward2, castable2 = H.EnsureConsumableReady(bot, "item_ward_observer")
            local prefWard2 = isRad and C.POSITIONS.ENEMY_T1T2_WARD_FOR_RADIANT or C.POSITIONS.ENEMY_T1T2_WARD_FOR_DIRE
            local rawMidT1T2 = prefWard2 or Vector(0.5 * (enT1.x + enT2.x), 0.5 * (enT1.y + enT2.y), 128)
            local ward2Target = H.EnsurePassableOutsideTowers(rawMidT1T2, enT1, enT2, 980)
            local arcPool = isRad and C.POSITIONS.ENEMY_T1T2_ARC_FOR_RADIANT or C.POSITIONS.ENEMY_T1T2_ARC_FOR_DIRE
            local standPt = H.EnsureWardStandPoint(arcPool and arcPool[2], ward2Target, enT1, enT2, 955, 435)
            State.enemyWardStartCharges = State.enemyWardStartCharges or totalWardCharges

            -- Real-velocity `1.35s` stall watchdog (`auto-20261102-0159` `-00:49.2..-00:31.0` `18s` Idle Fix!):
            --   * 1st stall (`1.35s` with `< 24u` displacement): bypass `standPt` and path straight to `ward2Target`!
            --   * 2nd stall (`2.70s` total): abort Ward #2 cleanly so SF returns to `T3_BLOCK` with `40s+` margin!
            local bLocW2 = bot:GetLocation()
            if not State.ward2StallCheckAt or not State.ward2StallRefLoc then
                State.ward2StallCheckAt = now
                State.ward2StallRefLoc = bLocW2
                State.ward2StallCount = 0
            elseif (now - State.ward2StallCheckAt) >= 1.35 then
                if U.DistanceBetweenLocations(bLocW2, State.ward2StallRefLoc) < 24 then
                    State.ward2StallCount = (State.ward2StallCount or 0) + 1
                    if State.ward2StallCount >= 2 then
                        State.preHornWard2Aborted = true
                        State.ward2StallCheckAt = nil
                        return false
                    end
                else
                    State.ward2StallCount = 0
                end
                State.ward2StallCheckAt = now
                State.ward2StallRefLoc = bLocW2
            end
            if (State.ward2StallCount or 0) >= 1 or GetUnitToLocationDistance(bot, standPt) <= 95 then
                standPt = ward2Target
            end

            local dToWard2 = GetUnitToLocationDistance(bot, ward2Target)
            local dToEnT1 = GetUnitToLocationDistance(bot, enT1)
            if castable2 and ward2 and dToWard2 <= 475 and dToEnT1 >= 905 then
                if now >= (State.lastWardCastCmdAt or -100) + 0.25 then
                    bot:Action_UseAbilityOnLocation(ward2, ward2Target)
                    State.lastWardCastCmdAt = now
                end
                State.actionTaken = true
                return true
            end
            H.SafeArcMoveAroundEnemyTowers(bot, standPt)
            State.actionTaken = true
            return true
        end

        return false
    end

    -- ========================================================================
    -- POST-HORN (`dtime >= 0`): Highground Anti-Deward Night Ward Planter
    -- ========================================================================
    -- NEVER interrupt Wave #1 opening creep block or initial wave clash (`dtime < 28.0s`)!
    if dtime < 28.0 then return false end
    local enemyNear = s and s.enemy and U.CanQuery(s.enemy) and s.enemyDist <= 880
    local creepsBusy = s and (#(s.enemyCreeps or {}) > 0)
    if enemyNear or creepsBusy then return false end
    -- `v7.9.20` (`1610.dem` `W10` @ `05:14.27` `(-92, 613)` Ward-Hijack vs Creep-Block Priority Fix!):
    -- When `#enemyCreeps == 0` and an allied wave (`>= 2` creeps) is actively marching through our T2->Staircase block zone
    -- (`<= 2,250u` behind `myT1` down to `myStaircase`), defer night-ward planting for `~2.5s` so `HandleMidGameIdleCreepBlock`
    -- blocks the wave onto our staircase FIRST, and then plants the ward right from the river lip with zero missed block!
    do
        local isRadW, myT1W, _, _, enT1W, _ = H.GetMidTowerGeometry(bot)
        local myStairW = isRadW and C.POSITIONS.RADIANT_STAIRCASE or C.POSITIONS.DIRE_STAIRCASE
        local t1ToEnW = U.DistanceBetweenLocations(myT1W, enT1W)
        local stairToEnW = U.DistanceBetweenLocations(myStairW, enT1W)
        local fntW = P.GetFountain(bot)
        local bLocW = bot:GetLocation()
        local midAlliesW = H.CollectMidCorridorCreeps(fntW, enT1W, UNIT_LIST_ALLIED_CREEPS, s and s.allyCreeps)
        local blockableNowW = 0
        for _, acW in ipairs(midAlliesW) do
            local dEnW = U.DistanceBetweenLocations(acW:GetLocation(), enT1W)
            local dBotW = U.DistanceBetweenLocations(acW:GetLocation(), bLocW)
            if dBotW <= 1850 and dEnW >= (stairToEnW + 40) and dEnW <= (t1ToEnW + 2250) then
                blockableNowW = blockableNowW + 1
            end
        end
        if blockableNowW >= 2 and GameTime() >= (State.abortedWaveBlockUntil or 0) then
            return false
        end
    end

    local ward, castable = H.EnsureConsumableReady(bot, "item_ward_observer")
    local spotPool = isRad and C.POSITIONS.WARD_SPOTS_RADIANT or C.POSITIONS.WARD_SPOTS_DIRE
    local wardLoc = isRad and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
    if spotPool and #spotPool > 0 then
        local baseIdx = ((State.wardPlantCount or 0) % #spotPool) + 1
        local unwardedSpot = nil
        for offset = 0, #spotPool - 1 do
            local cand = spotPool[((baseIdx - 1 + offset) % #spotPool) + 1]
            if not H.HasAlliedObserverNear(cand, 900) then
                unwardedSpot = cand
                break
            end
        end
        -- If ALL highground spots already have live allied Observer coverage (`e.g. Ward #1 is still alive!`),
        -- hold the spare Observer Ward in backpack until vision expires or gets dewarded — NEVER stack 2 wards!
        if not unwardedSpot then
            return false
        end
        wardLoc = unwardedSpot
        if type(GetUnitList) == "function" and UNIT_LIST_ENEMY_WARDS then
            local okW, eWards = pcall(GetUnitList, UNIT_LIST_ENEMY_WARDS)
            if okW and eWards and #eWards > 0 then
                local bestSpot, bestMinSentryD = nil, -1
                for offset = 0, #spotPool - 1 do
                    local candSpot = spotPool[((baseIdx - 1 + offset) % #spotPool) + 1]
                    if not H.HasAlliedObserverNear(candSpot, 900) then
                        local minSD = math.huge
                        for _, ew in pairs(eWards) do
                            if ew and U.CanQuery(ew) and ew:IsAlive() then
                                local sd = U.DistanceBetweenLocations(ew:GetLocation(), candSpot)
                                if sd < minSD then minSD = sd end
                            end
                        end
                        if minSD > 1010 then
                            bestSpot, bestMinSentryD = candSpot, minSD
                            break
                        elseif minSD > bestMinSentryD then
                            bestSpot, bestMinSentryD = candSpot, minSD
                        end
                    end
                end
                if bestSpot then
                    wardLoc = bestSpot
                end
                if bestMinSentryD >= 0 and bestMinSentryD <= 1010 then
                    local centerAnchor = spotPool[1]
                    local ridgeDir = (wardLoc - centerAnchor)
                    if ridgeDir:Length2D() < 10 then
                        ridgeDir = Vector(-0.7071, 0.7071, 0)
                    else
                        ridgeDir = ridgeDir:Normalized()
                    end
                    local safeOut = centerAnchor + ridgeDir * 1045
                    if not H.HasAlliedObserverNear(safeOut, 900)
                        and (type(IsLocationPassable) ~= "function" or IsLocationPassable(safeOut)) then
                        wardLoc = safeOut
                    end
                end
            end
        end
    end
    if not wardLoc or H.HasAlliedObserverNear(wardLoc, 900) then return false end
    local d = GetUnitToLocationDistance(bot, wardLoc)
    if castable and ward then
        if d <= 475 then
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            State.lastPlacedWardLoc = wardLoc
            State.lastPlacedWardAt = now
            State.wardPlantCount = (State.wardPlantCount or 0) + 1
            State.lastWardCheckAt = now + 1.0
            State.actionTaken = true
            return true
        else
            H.SmartMove(bot, wardLoc, 45)
            State.actionTaken = true
            return true
        end
    end
    return false
end

-- `v7.9.11-pro` Priority-Sorted Backpack Stat-Swapping Tables:
--   * `SALVE_AMP_STAT_RANK` (`+STR` / `+MaxHP` descending): `Ogre Axe / Dragon Lance / Ultimate Orb (10)` >
--     `Belt of Strength (6)` > `Bracer (5)` > `Crown (4)` > `Gauntlets / Wand (3)` > `Wraith / Null / Circlet / Diadem (2)` >
--     `Iron Branch (1)`.
--   * `MANGO_AMP_STAT_ITEMS` / `CLARITY_AMP_STAT_RANK` (`+INT` / `+MaxMP` descending): `Kaya (16)` >
--     `Staff of Wizardry / Ultimate Orb (10)` > `Robe of the Magi (6)` > `Null Talisman (5)` > `Crown (4)` >
--     `Mantle / Wand (3)` > `Bracer / Wraith / Circlet / Diadem (2)` > `Iron Branch (1)`.
local SALVE_AMP_STAT_RANK = {
    ["item_hurricane_pike"]    = 15,
    ["item_sange"]             = 16,
    ["item_sange_and_yasha"]   = 16,
    ["item_vitality_booster"]  = 12,
    ["item_point_booster"]     = 11,
    ["item_ogre_axe"]          = 10,
    ["item_dragon_lance"]      = 10,
    ["item_manta"]             = 10,
    ["item_black_king_bar"]    = 10,
    ["item_ultimate_orb"]      = 10,
    ["item_belt_of_strength"]  = 6,
    ["item_diadem"]            = 6,
    ["item_bracer"]            = 5,
    ["item_crown"]             = 4,
    ["item_gauntlets"]         = 3,
    ["item_magic_wand"]        = 3,
    ["item_wraith_band"]       = 2,
    ["item_null_talisman"]     = 2,
    ["item_circlet"]           = 2,
    ["item_branches"]          = 1,
}

local CLARITY_AMP_STAT_RANK = {
    ["item_mystic_staff"]      = 25,
    ["item_yasha_and_kaya"]    = 16,
    ["item_kaya"]              = 16,
    ["item_hurricane_pike"]    = 15,
    ["item_energy_booster"]    = 12,
    ["item_point_booster"]     = 11,
    ["item_staff_of_wizardry"] = 10,
    ["item_manta"]             = 10,
    ["item_ultimate_orb"]      = 10,
    ["item_robe"]              = 6,
    ["item_diadem"]            = 6,
    ["item_null_talisman"]     = 5,
    ["item_crown"]             = 4,
    ["item_mantle"]            = 3,
    ["item_magic_wand"]        = 3,
    ["item_bracer"]            = 2,
    ["item_wraith_band"]       = 2,
    ["item_circlet"]           = 2,
    ["item_branches"]          = 1,
}

local MANGO_AMP_STAT_ITEMS = CLARITY_AMP_STAT_RANK

-- `v7.9.13-pro`: Includes `item_circlet (+2 all stats)`, `item_magic_wand (+3)`, `item_crown (+4)`, `item_diadem (+6)`,
-- `item_wraith_band (+2)`, and `item_yasha_and_kaya (+16)` so safe in-lane `"INT_ONLY"` Mango pops NEVER skip `item_circlet`!
local MANGO_LOW_RISK_INT_ITEMS = {
    ["item_mystic_staff"]      = 25,
    ["item_yasha_and_kaya"]    = 16,
    ["item_kaya"]              = 16,
    ["item_energy_booster"]    = 12,
    ["item_point_booster"]     = 11,
    ["item_staff_of_wizardry"] = 10,
    ["item_robe"]              = 6,
    ["item_diadem"]            = 6,
    ["item_null_talisman"]     = 5,
    ["item_crown"]             = 4,
    ["item_mantle"]            = 3,
    ["item_magic_wand"]        = 3,
    ["item_wraith_band"]       = 2,
    ["item_circlet"]           = 2,
    ["item_branches"]          = 1,
}

-- Swap up to 3 highest-ranked stat items from active inventory (`0..5`) into free/dormant Backpack slots (`6..8`),
-- never displacing `protectedItemName` (e.g. `"item_flask"`, `"item_clarity"`, `"item_enchanted_mango"`).
-- Returns `(swapsTable, didAnySwap)` where `swapsTable = { { sSlot, bpSlot }, ... }`.
function H.SwapStatItemsToBackpack(bot, rankMap, protectedItemName, protectedHandle)
    local candidates = {}
    for sSlot = 0, 5 do
        local it = bot:GetItemInSlot(sSlot)
        if it and it ~= protectedHandle then
            local nm = it:GetName()
            local r = nm and rankMap[nm]
            if r and nm ~= protectedItemName then
                candidates[#candidates + 1] = { slot = sSlot, rank = r }
            end
        end
    end
    if #candidates == 0 then
        return {}, false
    end
    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.slot < b.slot
    end)
    local swaps = {}
    local usedBp = {}
    for _, cand in ipairs(candidates) do
        local chosenBp = nil
        for bp = 6, 8 do
            if not usedBp[bp] and not bot:GetItemInSlot(bp) then
                chosenBp = bp
                break
            end
        end
        if not chosenBp then
            for bp = 6, 8 do
                local bpIt = bot:GetItemInSlot(bp)
                local bpNm = bpIt and bpIt:GetName() or ""
                if not usedBp[bp] and bpIt and bpNm ~= protectedItemName and not rankMap[bpNm] then
                    chosenBp = bp
                    break
                end
            end
        end
        -- `v7.9.16-pro` (`1343 @ 09:14` `item_branches` vs `item_bracer` Backpack Displacement Fix):
        -- When all 3 Backpack slots already hold ranked stat items (e.g. `6=item_branches` `rank=1`, `7=belt` `rank=6`,
        -- `8=bracer` `rank=5`), displace the lowest-ranked Backpack stat item whenever `cand.rank > bpRank` (`5 > 1` ->
        -- swaps active `Bracer (+5 STR)` into Backpack and `Branch (+1 STR)` into Active, gaining `+88 MaxHP` Salve amp!).
        if not chosenBp then
            local lowestBp, lowestRank = nil, cand.rank
            for bp = 6, 8 do
                local bpIt = bot:GetItemInSlot(bp)
                local bpNm = bpIt and bpIt:GetName() or ""
                local bpRank = rankMap[bpNm] or 999
                if not usedBp[bp] and bpIt and bpNm ~= protectedItemName and bpRank < lowestRank then
                    lowestBp, lowestRank = bp, bpRank
                end
            end
            chosenBp = lowestBp
        end
        if chosenBp then
            usedBp[chosenBp] = true
            bot:ActionImmediate_SwapItems(cand.slot, chosenBp)
            if U.BumpInventoryEpoch then U.BumpInventoryEpoch() end
            swaps[#swaps + 1] = { cand.slot, chosenBp }
        end
    end
    return swaps, (#swaps > 0)
end

-- ============================================================================
-- `v7.9.16-pro` POST-KILL TOWER SURVIVAL & SUPER-EMERGENCY MICRO-SALVE ENGINE
-- (`auto-20261103-1343` `05:49.33` T2 Survival + `05:39.47` Dive Gap + `10:41.13` `179 HP` Rescue + First-Kill `TTK` Flip!)
-- ============================================================================
-- Runs ABOVE `HandleEnemyTowerSafety` (`:12603`) so tower-escape early-return NEVER blocks post-kill Salve!
-- Three exact triggers (`0.00s` instant cast point on `item_flask`):
--   (M1) POST-KILL / ENEMY-DEAD TOWER & CREEP SURVIVAL:
--        Enemy hero is dead (`s.enemyAlive == false`) and SF is under enemy Tower/Creep fire (`nonBreakDmg >= 40`)
--        or low HP (`curHp <= 385` & `missingHp >= 210`). Dota 2 towers/creeps NEVER dispel `modifier_flask_healing`,
--        so popping `item_flask` immediately heals `+30..+36 HP/s` right through T1/T2 tower bolts (`05:49.33`: `341 HP`
--        survived `401` T2+creep dmg at `53 HP` and healed full `13.0s`!).
--   (M2) SUPER-EMERGENCY BETWEEN-BLOWS / COOLDOWN-GAP SURVIVAL RESCUE:
--        Enemy hero is alive, `dtBreak >= 0.34s` (`microHeal >= 10 HP` guaranteed before next hero hit/coil impacts):
--          - (M2a) Next-blow lethal threshold flip: `curHp <= imminentDmg + 24` AND `curHp + microHeal > imminentDmg - 8`
--                  (healing `10..60 HP` between right-clicks/coils or while a projectile flies saves SF's life!);
--          - (M2b) Critical low-HP cooldown/pursuit window: `curHp <= 360`, `missingHp >= 300`, `dtBreak >= 1.30s`
--                  (`05:39.47` `6.8s` CD gap & `10:41.13` `1.72s` walk-in gap -> `+45..+180 HP` healed on the move!).
--   (M3) SUPER-EMERGENCY FIRST-KILL `TTK` FLIP ("иначе не убьёшь врага первым"):
--        In a close duel (`dHero <= 880u`, `tKillHim <= 3.4s`), WITHOUT `microHeal` SF dies before/as he kills the enemy,
--        and WITH `curHp + microHeal` (`>= 10 HP` between hits/coils) SF survives enemy burst long enough to kill him FIRST!
--        Sets `State.microSalveDuelUntil` so `HandleProactiveAndActiveSalve` NEVER forces SF to run away on the next tick!
function H.TryEmergencySurvivalAndMicroSalve(bot, s, _earlyRace)
    if State.actionTaken or bot:IsChanneling() then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    if H.IsAtFountain(bot) then return false end
    local now = GameTime()
    if now <= (State.lastSalveCastAt or -1000) + 0.25 then return false end

    local flaskSlot = bot:FindItemSlot("item_flask")
    if flaskSlot < 0 or flaskSlot > 8 then return false end

    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local missingHp = maxHp - curHp
    if missingHp < 95 then return false end

    local enemy = s and s.enemy
    local enemyDead = (s and s.enemyAlive == false) or false
    -- Start `6.0s` Backpack-to-Active unlock immediately whenever low HP or post-kill, without blocking orders!
    if flaskSlot >= 6 and (curHp <= 440 or (enemyDead and missingHp >= 210)) then
        H.EnsureConsumableReady(bot, "item_flask")
        return false
    end

    local flask = bot:GetItemInSlot(flaskSlot)
    if not flask or flaskSlot > 5 or not flask:IsFullyCastable() then
        return false
    end

    local dtBreak, nextHeroBlowDmg, hasHeroProj = K.EnemySalveBreakWindow(bot, enemy)
    local nonBreakDmg = H.EstimateIncomingNonHeroDamage(bot, s, math.min(3.0, math.max(1.2, dtBreak)))

    -- Respect our own active Raze windup / hero attack point UNLESS an in-flight blow + tower/creep damage will kill us
    -- BEFORE our windup finishes (`<= 0.45s`) and Salve ticks keep us alive!
    local inOwnCommit = bot:IsUsingAbility()
        or (enemy and U.CanQuery(enemy) and enemy:IsAlive() and H.ShouldHoldForHeroWindup and H.ShouldHoldForHeroWindup(bot, enemy))
    if inOwnCommit then
        local lethalMidWindup = (dtBreak >= 0.30 and dtBreak <= 0.55)
            and hasHeroProj
            and (curHp <= nextHeroBlowDmg + nonBreakDmg * 0.35 + 10)
            and (curHp + 30.0 * (dtBreak - 0.05) > nextHeroBlowDmg + 2)
        if not lethalMidWindup then
            return false
        end
    end

    -- Mode M1: Post-Kill / Dead-Enemy Immediate Tower & Creep Survival Salve (`05:49.33` Dire T2 Survival!)
    if enemyDead and (not hasHeroProj or dtBreak >= 0.36) then
        local underTowerOrCreepFire = (nonBreakDmg >= 40)
            and (curHp <= nonBreakDmg + 220 or curHp <= 500 or missingHp >= 200)
        local criticalPostKillLowHp = (curHp <= 385 and missingHp >= 210)
        if underTowerOrCreepFire or criticalPostKillLowHp then
            H.ManageTreads(bot, "FIGHT") -- AGI before Salve so switching back to STR multiplies restored HP%!
            if nonBreakDmg < 40 then
                local _, didSw = H.SwapStatItemsToBackpack(bot, SALVE_AMP_STAT_RANK, "item_flask", flask)
                if didSw then State.branchTangoSwapUntil = now + 6.90 end
            end
            State.salveBuffSeenAt = now
            bot:Action_UseAbilityOnEntity(flask, bot)
            State.lastSalveCastAt = now
            State.lastItemUseTime = now
            State.actionTaken = true
            return true
        end
    end

    if dtBreak < 0.34 then return false end
    local usableSec = math.max(0.0, math.min(13.0, dtBreak) - 0.06)
    local microHeal = 30.0 * usableSec
    if microHeal < 10.0 then return false end

    -- Mode M2: Super-Emergency Between-Hits / Cooldown-Gap Survival Rescue (`05:39.47` & `10:41.13`!)
    local imminentDmg = nextHeroBlowDmg + math.min(nonBreakDmg, 185.0)
    local m2ThresholdSave = (imminentDmg >= 35.0)
        and (curHp <= imminentDmg + 24.0)
        and ((curHp + microHeal) > (imminentDmg - 8.0))
    -- `v7.9.18-pro` Differential-Pursuit Salve Law (`1343 @ 10:41.13` `395 vs 355 MS` + `9074513540 @ 11:08.13` `305 vs 305 MS` Unified!):
    --   * If `enMS >= myMS + 12` (`dd/dt < 0`: faster chaser WILL catch us, we can NEVER open `840u`!), pop Micro-Salve NOW
    --     whenever `dtBreak >= 1.28s` so we never die holding an unused Salve (`1343 @ 10:41.13`!).
    --   * If `enMS < myMS + 12` (`dd/dt >= 0`: equal/slower enemy CANNOT gain on radial escape!), NEVER waste a `400 HP` Salve
    --     on a non-lethal gap inside `d < 840u` (`9074513540 @ 11:08.13` `d=580u` -> right-click broke `370 HP` of healing!);
    --     sprint radially outside break range FIRST (`d >= 840u` & `dtBreak >= 2.60s`), unless at last-gasp `curHp <= 130`!
    local liveEnDistM2 = 9999
    local enFasterInescapableM2 = false
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        liveEnDistM2 = GetUnitToLocationDistance(bot, enemy:GetLocation())
        local enMsM2 = enemy:GetCurrentMovementSpeed() or 310
        local myMsM2 = bot:GetCurrentMovementSpeed() or 305
        enFasterInescapableM2 = (enMsM2 >= myMsM2 + 12)
    end
    local m2PursuitGapSave = (curHp <= 360)
        and (missingHp >= 300)
        and ((enFasterInescapableM2 and dtBreak >= 1.28)
            or (liveEnDistM2 >= 840 and dtBreak >= 2.60)
            or (curHp <= 130 and dtBreak >= 1.50))

    -- Mode M3: Super-Emergency First-Kill `TTK` Flip ("иначе не убьёшь врага первым")
    local m3FirstKillFlip = false
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
        if dHero <= 880 then
            local lr = (_earlyRace and _earlyRace.valid and _earlyRace.lr) or U.SolveLethalRace(bot, enemy, s)
            local enHpNow = enemy:GetHealth() or 9999
            local myOneCoil = (K.MyManaBudget(bot, true) >= 75) and K.MyRazeDamage(bot, enemy, 1) or 0
            local myQuickKillPotential = (enHpNow <= myOneCoil + K.AttackDamageVs(bot, enemy) * 2.1)
                or (lr and (lr.tKillHim or 99) <= 3.4)
            if myQuickKillPotential then
                local horizonKill = math.min(2.8, math.max(0.65, (lr and lr.tKillHim) or 1.6))
                local dmgBeforeKill = K.EnemyBurstVs(bot, enemy, dHero, horizonKill, true) + math.min(nonBreakDmg, 130.0)
                local diesOrTiesWithoutSalve = (curHp <= dmgBeforeKill + 22.0)
                    or (lr and (not lr.winsFirstKill) and ((lr.tKillMe or 99) <= (lr.tKillHim or 99) + 0.45))
                local survivesWithMicroSalve = ((curHp + microHeal) > (dmgBeforeKill + 3.0))
                    or (lr and (not lr.winsFirstKill) and ((curHp + microHeal) > curHp + 11.0)
                        and (curHp <= dmgBeforeKill + 35.0) and ((curHp + microHeal) >= dmgBeforeKill - 4.0))
                if diesOrTiesWithoutSalve and survivesWithMicroSalve then
                    m3FirstKillFlip = true
                end
            end
        end
    end

    if m2ThresholdSave or m2PursuitGapSave or m3FirstKillFlip then
        if inOwnCommit then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
        end
        H.ManageTreads(bot, "FIGHT") -- Instant 0-tick PT -> AGI switch (`0` Backpack stat-drop in close combat!)
        State.salveBuffSeenAt = now
        if m3FirstKillFlip or (m2ThresholdSave and enemy and U.CanQuery(enemy) and enemy:IsAlive()
            and (enemy:GetHealth() or 9999) <= (K.MyRazeDamage(bot, enemy, 1) + K.AttackDamageVs(bot, enemy) * 1.5)) then
            State.microSalveDuelUntil = now + math.min(3.0, math.max(1.2, dtBreak + 0.5))
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastSalveCastAt = now
        State.lastItemUseTime = now
        State.actionTaken = true
        return true
    end

    return false
end

-- Top-Level Proactive Salve Trigger & Active `modifier_flask_healing` Guard (ABOVE `RunSacredCS` & `holdSpot`!):
-- Eliminates Death #1 (`690/1034 HP` with unused `[0]Flask(1)`) & Death #2 (`614/1078 HP` idle for `12s` with `[0]Flask(1)`),
-- AND fixes `9056469656.dem` `02:03–02:18` (`tk=6668..7098`): when enemy SF has `< 75 MP` (cannot cast `Shadowraze3` at `950u`!),
-- `safeDist` drops from `1065u` to `enemyAttackRange + 185` (`685u`), letting our SF hold ground under own T1 and farm `4/4` CS!
function H.HandleProactiveAndActiveSalve(bot, s, _earlyRace)
    local enemy = s and s.enemy
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local curHp = bot:GetHealth() or 0
    local missingHp = maxHp - curHp
    local hpPct = curHp / maxHp
    local fountain = P.GetFountain(bot)
    local safeDist = 1120 -- Default clearance vs `Shadowraze3` (`950u`) + walk lead (`Demo 1` `2:47` & `4:10` Fix!)
    local enApproachSpd = 0
    if enemy and U.CanQuery(enemy) then
        enApproachSpd = U.EnemyApproachSpeed(bot, enemy)
        local enAtkR = (enemy.GetAttackRange and enemy:GetAttackRange()) or 500
        if K.EnemyManaBudget(enemy, true) < 75 or not U.EnemyHasRaze(enemy) then
            safeDist = math.max(690, enAtkR + 205 + math.min(180, enApproachSpd * 0.7))
        else
            safeDist = math.min(1290, math.max(1110, enAtkR + 240, K.EnemyMinSafeDistance(enemy, 1.0) + 95 + math.min(200, enApproachSpd * 0.85)))
        end
    end

    -- Also treat an enemy who dipped into river/highground FoW `< 4.5s` ago at `enemyLastLoc` as LIVE threat (`Demo 1` `2:45.4` Fix!)
    local fogEnemyLoc = (not (enemy and U.CanQuery(enemy)))
        and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 4.5
        and s.enemyLastLoc or nil
    local effEnemyLoc = (enemy and U.CanQuery(enemy) and enemy:GetLocation()) or fogEnemyLoc
    local effEnemyDist = effEnemyLoc and GetUnitToLocationDistance(bot, effEnemyLoc) or 9999

    -- 1. Protect active Healing Salve ONLY against real Salve-breaking sources (Dota 2 7.00-7.41f rule:
    -- ONLY Hero / Tower / Player-Controlled / Roshan hits >= 20 dmg cancel `modifier_flask_healing`; lane creeps NEVER break Salve!).
    if bot:HasModifier("modifier_flask_healing") then
        local nowSalve = GameTime()
        if not State.salveBuffSeenAt or (nowSalve - State.salveBuffSeenAt) > 14.0 then
            State.salveBuffSeenAt = nowSalve
        end
        local salveElapsed = nowSalve - State.salveBuffSeenAt
        if hpPct >= 0.96 then
            State.branchTangoSwapUntil = 0
            State.salveBuffSeenAt = nil
            return false
        end
        -- `auto-20261102-0043` `7:11..7:24` + `v7.9.11` (`Belt of Strength` + `Bracer` + `Circlet` + `Iron Branch` Drop):
        -- Hold `AGI` Treads (`ManageTreads("FIGHT")`) across the Salve when safely out of threat (`>= 1220u` or enemy dead!),
        -- and keep highest-STR stat items in Backpack until `salveElapsed >= 6.85s` (`6.0s` Backpack CD unlocks right at `12.85s`!)!
        -- `v7.9.19` (`9074666246.dem` `10:38.87..10:49.00` `520 -> 0 HP` Dire T1 Sudden-Death Loss Fix!):
        -- NEVER swap `Bracer`/`Belt` into `6.0s` Backpack OR step back AFK behind `allyT1` to pamper Salve while our
        -- `allyT1` is in active 1v1 Sudden-Death Danger (`tHp <= 720..920` under Catapult/Hero siege) and `curHp >= 240`!
        -- Losing `allyT1` in 1v1 Mid is an INSTANT GAME OVER (`Ancient` explodes!).
        local t1SuddenDeathNow = H.IsAllyT1InSuddenDeathDanger and H.IsAllyT1InSuddenDeathDanger(bot, s) or false
        if t1SuddenDeathNow and curHp >= 240 then
            State.branchTangoSwapUntil = 0
            H.ManageTreads(bot, "FIGHT")
            return false
        end
        if (s and s.enemyAlive == false or effEnemyDist >= 1220) and not H.HasSalveBreakingProjectileIncoming(bot) then
            H.ManageTreads(bot, "FIGHT")
            local creepsOnBotSalve = 0
            for _, ecS in pairs((s and s.enemyCreeps) or {}) do
                if U.CanQuery(ecS) and ecS:IsAlive() and ecS.GetAttackTarget and ecS:GetAttackTarget() == bot then
                    creepsOnBotSalve = creepsOnBotSalve + 1
                end
            end
            if salveElapsed <= 5.5 and not t1SuddenDeathNow and (s and s.enemyAlive == false or effEnemyDist >= 1250)
                and not (L and L._imminentCS) and creepsOnBotSalve == 0 then
                H.SwapStatItemsToBackpack(bot, SALVE_AMP_STAT_RANK, "item_flask", nil)
            end
            if salveElapsed < 6.85 then
                State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, State.salveBuffSeenAt + 6.90)
            else
                State.branchTangoSwapUntil = 0
            end
        elseif effEnemyDist < 1050 then
            State.branchTangoSwapUntil = 0
        end
        -- If `TryEmergencySurvivalAndMicroSalve` popped `item_flask` specifically to flip a close-range first-kill `TTK`
        -- duel (`State.microSalveDuelUntil`), yield immediately so combat/razes/attacks finish the kill while Salve ticks!
        if nowSalve < (State.microSalveDuelUntil or -1000)
            and enemy and U.CanQuery(enemy) and enemy:IsAlive() then
            return false
        end
        -- Never throw away a free hero kill right in front of us when already above lethal threshold!
        if enemy and U.CanQuery(enemy) and enemy:IsAlive() and curHp >= 180
            and not (_earlyRace and _earlyRace.valid and _earlyRace.heCanKillNow) then
            if U.CanOneShotEnemyHero(bot, enemy) or U.CanQuickTurnKillWithRaze(bot, enemy)
                or (curHp >= 300 and H.CanTwoHitRightClickKill(bot, enemy, s)) then
                return false
            end
        end
        local needStepBack = H.HasSalveBreakingProjectileIncoming(bot)
        -- `auto-20261102-0007` `9:05..9:14` (`815..937 HP` Salving Behind Dire T1 While 2 Uncontested Creeps Died to T1 Fix!):
        -- Lane creeps NEVER break Healing Salve! Once healed to `>= 640 HP` (`>= 56% HP`), if enemy creeps are actively
        -- dying near our own `allyT1` (`<= 820u`), tighten `effSafeDist` to `985u` (`strictly outside 950u Shadowraze3`)
        -- without `+110u` hysteresis overshoot so SF farms under-tower CS safely while Salve finishes!
        local creepsUnderOwnT1 = false
        if curHp >= 640 and hpPct >= 0.56 and s and s.allyT1Alive and s.allyT1Loc then
            for _, ec in pairs(s.enemyCreeps or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive()
                    and U.DistanceBetweenLocations(ec:GetLocation(), s.allyT1Loc) <= 820 then
                    creepsUnderOwnT1 = true
                    break
                end
            end
            if not creepsUnderOwnT1 then
                for _, ec in pairs(s.enemyCreepsNearAllyT1 or {}) do
                    if ec and U.CanQuery(ec) and ec:IsAlive()
                        and U.DistanceBetweenLocations(ec:GetLocation(), s.allyT1Loc) <= 820 then
                        creepsUnderOwnT1 = true
                        break
                    end
                end
            end
        end
        local effSafeDist = creepsUnderOwnT1 and math.min(safeDist, 985) or safeDist
        local hystThreshold = (not creepsUnderOwnT1 and GameTime() < (State.salveStepBackHystUntil or -1000))
            and (effSafeDist + 110) or effSafeDist
        if effEnemyLoc and effEnemyDist < hystThreshold then
            needStepBack = true
        end
        -- Also step out of enemy creep vision (`< 540u`) while enemy mid is unseen in recent FoW (`Demo 1` `2:46.8` Fix!):
        if not (enemy and U.CanQuery(enemy)) and s and s.enemyAlive ~= false and (s.enemyAbsentFor or 0) <= 6.5 then
            for _, ec in pairs(s.enemyCreeps or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) < 540 then
                    needStepBack = true
                    break
                end
            end
        end
        -- NOTE (`v7.9.16-pro` Dota 2 Engine Truth): `enemyTowers < 890` intentionally NOT treated as `needStepBack` here!
        -- Towers NEVER dispel `modifier_flask_healing` (`1343 @ 05:49.33`), and `HandleEnemyTowerSafety` already manages tower aggro!
        if needStepBack then
            State.salveStepBackHystUntil = GameTime() + 1.05
            local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 520)) or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
            local anchor = behindT1
            local bLocNow = bot:GetLocation()
            if effEnemyLoc then
                anchor = H.GetSafeEscapePointAwayFromEnemy(bot, effEnemyLoc, safeDist + 115)
                if U.DistanceBetweenLocations(bLocNow, effEnemyLoc) >= 880 then
                    anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, anchor, 780)) or anchor
                end
                if U.DistanceBetweenLocations(bLocNow, anchor) > 25 then
                    H.SmartMove(bot, anchor, 40)
                end
            else
                local dBotFnt = U.DistanceBetweenLocations(bLocNow, fountain)
                if dBotFnt <= U.DistanceBetweenLocations(anchor, fountain) + 35 and dBotFnt > 450 then
                    anchor = bLocNow + (fountain - bLocNow):Normalized() * math.min(380, dBotFnt - 420)
                end
                if dBotFnt > U.DistanceBetweenLocations(anchor, fountain) + 25 then
                    H.SmartMove(bot, anchor, 40)
                end
            end
            State.actionTaken = true
            return true
        end
        -- `v7.9.11` (`2213 @ 11:48..12:00` Off-Lane Jungle Salve Freeze & `07:40 / 08:38` Salve Creep-Block Fix!):
        --   1. NEVER freeze `2,600u` away in side-jungle (`(3094, 82)`) while `s.enemyCreepsNearAllyT1` are hitting our `allyT1`
        --      and the enemy hero is safely away (`effEnemyDist >= safeDist`)! Lane creeps NEVER break Salve!
        --   2. When safely behind/near own T1 (`s.enemyAlive == false` or `effEnemyDist >= safeDist + 240`), allow
        --      `HandleMidGameIdleCreepBlock` to body-block our outgoing wave (`07:40` & `08:38`) while Salve heals!
        if #(s and s.enemyCreeps or {}) == 0 then
            local siegeInfo = H.GetEnemyCreepCutAndT1SiegeState and H.GetEnemyCreepCutAndT1SiegeState(bot, s) or nil
            if siegeInfo and siegeInfo.valid and siegeInfo.t1UnderCreepSiege and effEnemyDist >= safeDist then
                local fntS = P.GetFountain(bot)
                local safeT1Spot = siegeInfo.allyT1Loc + (fntS - siegeInfo.allyT1Loc):Normalized() * 190
                local dSpotEn = effEnemyLoc and U.DistanceBetweenLocations(safeT1Spot, effEnemyLoc) or 9999
                if dSpotEn >= safeDist and GetUnitToLocationDistance(bot, safeT1Spot) > 360 then
                    H.SmartMove(bot, safeT1Spot, 45, true)
                    return true
                end
            end
            if (s and s.enemyAlive == false) or effEnemyDist >= safeDist + 240 then
                if H.HandleMidGameIdleCreepBlock and H.HandleMidGameIdleCreepBlock(bot, s) then
                    return true
                end
            end
            State.actionTaken = true
            return true
        end
        return false
    end

    -- 2. Trigger owned Healing Salve (`missingHp >= 300` OR `hpPct <= 0.62`, OR `missingHp >= 205` during a completely
    --    safe empty-wave lull when `0` Tangoes remain — fixes `1507 @ 06:38–07:08` unpopped `Flask#3` at `780/1020 HP`!)
    if missingHp < 205 and hpPct > 0.62 then return false end
    -- `v7.9.19` (`9074666246.dem` `10:31..10:49` T1 Loss Fix): NEVER abandon `allyT1` to drink/protect Salve when `allyT1`
    -- is in Sudden-Death Danger (`tHp <= 720..920` under siege) unless we are literally 1 hit from dying (`curHp < 230`)!
    if curHp >= 230 and H.IsAllyT1InSuddenDeathDanger and H.IsAllyT1InSuddenDeathDanger(bot, s) then
        return false
    end
    if not (U.HasItem and U.HasItem(bot, "item_flask", true)) then return false end
    local emptySafeSalveLull = (missingHp < 300 and hpPct > 0.62)
        and (#((s and s.enemyCreeps) or {}) == 0)
        and not bot:HasModifier("modifier_tango_heal")
        and not (U.HasItem and U.HasItem(bot, "item_tango", true))
        and ((s and s.enemyAlive == false) or effEnemyDist >= 1450 or ((s and s.enemyAbsentFor or 0) >= 6.0 and effEnemyDist >= 1250))
    local minMissingForOwnedSalve = emptySafeSalveLull and 205 or 300
    if missingHp < minMissingForOwnedSalve and hpPct > 0.62 then return false end
    if H.IsAtFountain(bot) then return false end
    -- `auto-20261102-0007` `12:09.90` (`555 HP` Bot chasing `108 HP` Human into 1-tick river FoW) Fix:
    -- Never pop Salve & abort a live kill-chase when a critically low (`<= 240 HP`) enemy dipped into FoW `< 2.8s` ago!
    if not (enemy and U.CanQuery(enemy)) and curHp >= 320 and s and s.enemyAlive ~= false
        and (s.enemyAbsentFor or 99) <= 2.8 and (s.enemyLastHp or 9999) <= 240
        and s.enemyLastLoc and GetUnitToLocationDistance(bot, s.enemyLastLoc) <= 1050 then
        return false
    end
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local dEnNow = GetUnitToLocationDistance(bot, enemy:GetLocation())
        -- `W4 06:25.5` Fix: NEVER retreat to drink Salve when a 1-hit / quick-kill enemy stands within `980u`!
        if dEnNow <= 980 and curHp >= 140
            and (U.CanOneShotEnemyHero(bot, enemy) or U.CanQuickTurnKillWithRaze(bot, enemy)) then
            return false
        end
        if dEnNow <= safeDist then
            if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
            local dominatingLevel = ((bot:GetLevel() or 1) > (enemy:GetLevel() or 1))
                and curHp >= 460
                and not (_earlyRace and _earlyRace.valid and _earlyRace.heCanKillSoon)
            local winningCombat = _earlyRace and _earlyRace.valid
                and (_earlyRace.canKillNow or _earlyRace.canKillSoon
                    or (((_earlyRace.edge or 0) > 65) and curHp >= 450 and not _earlyRace.heCanKillSoon))
            if dominatingLevel or winningCombat then
                return false
            end
        end
    end
    local flaskSlot = bot:FindItemSlot("item_flask")
    if flaskSlot < 0 or flaskSlot > 8 then return false end

    local flask, castable = H.EnsureConsumableReady(bot, "item_flask")
    if (bot:GetMana() or 0) < 90 then
        H.EnsureConsumableReady(bot, "item_enchanted_mango")
    end
    -- `9069188041.dem` `02:40.8-02:47.8` Death #1 Backpack-Salve Paralysis Fix:
    -- While `flask` is still on its `6.0s` Backpack swap cooldown (`not castable`) and NO `modifier_flask_healing`
    -- is active yet, if an enemy hero is wrapping/attacking within `<= 820u` (or just damaged us), DO NOT freeze or
    -- block survival/Mango/counter-Razes waiting for an unusable Salve!
    if not castable and enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local dEnThreat = GetUnitToLocationDistance(bot, enemy:GetLocation())
        local recentlyHit = bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.8)
        if dEnThreat <= 820 or recentlyHit then
            return false
        end
    end
    local unsafeHere = H.HasSalveBreakingProjectileIncoming(bot)
    -- `v7.9.11` (`2213 @ 08:31..08:38` Dead-Enemy `2,200u` T2 Walk Fix):
    -- When `s.enemyAlive == false`, ONLY enemy towers or live hero projectiles can break Salve — pop Salve right on the spot!
    if s and s.enemyAlive ~= false then
        if effEnemyLoc and effEnemyDist < (safeDist + 45) then
            unsafeHere = true
        end
        -- NEVER pop `Healing Salve` inside enemy lane creep vision (`< 540u`) while enemy mid is alive in recent FoW (`<= 6.5s`):
        -- enemy creeps grant shared vision directly to the unseen enemy SF right behind the wave (`Demo 1` `2:47` & `4:10` Fix!).
        if not (enemy and U.CanQuery(enemy)) and (s.enemyAbsentFor or 0) <= 6.5 then
            for _, ec in pairs(s.enemyCreeps or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) < 540 then
                    unsafeHere = true
                    break
                end
            end
        end
    end
    -- NOTE (`v7.9.16-pro` Dota 2 Engine Truth): Towers NEVER dispel `modifier_flask_healing`, so `enemyTowers < 890`
    -- NEVER blocks drinking `item_flask` (vital for surviving post-kill T1/T2 exit shots like `1343 @ 05:49.33`!).
    if unsafeHere then
        -- `v7.9.16-pro` (`1343 @ 05:39..05:47` & `10:41..10:43` Anti-Dive-Paralysis Fix!):
        -- When a live enemy hero is ALREADY inside `<= 920u` (or faster by `>= 15 MS` within `<= 1080u`), walking backward
        -- with `State.actionTaken = true` WITHOUT popping Salve can NEVER open `safeDist = 1120u` — it only paralyzes
        -- counter-razes, tower-diver execution, and emergency TP-Home (`causing 0-raze deaths`)!
        if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
            local enMsNow = enemy:GetCurrentMovementSpeed() or 310
            local myMsNow = bot:GetCurrentMovementSpeed() or 305
            if effEnemyDist <= 920 or (enMsNow >= myMsNow + 15 and effEnemyDist <= 1080) then
                -- `v7.9.18-pro` Differential-Pursuit Salve Law (`1343 @ 10:41.13` vs `9074513540 @ 11:08.13`):
                -- Pop mid-pursuit Salve inside `920u` ONLY when enemy is strictly faster (`enMsNow >= myMsNow + 12`, inescapable)
                -- OR once `effEnemyDist >= 840 and dtBrkNow >= 2.60` (or critical `curHp <= 130`)!
                local enFasterInescapable = (enMsNow >= myMsNow + 12)
                if castable and flask and curHp <= 430 and GameTime() > (State.lastSalveCastAt or -1000) + 0.25 then
                    local dtBrkNow = K.EnemySalveBreakWindow(bot, enemy)
                    if (enFasterInescapable and dtBrkNow >= 1.25)
                        or (effEnemyDist >= 840 and dtBrkNow >= 2.60)
                        or (curHp <= 130 and dtBrkNow >= 1.50) then
                        H.ManageTreads(bot, "FIGHT")
                        State.salveBuffSeenAt = GameTime()
                        bot:Action_UseAbilityOnEntity(flask, bot)
                        State.lastSalveCastAt = GameTime()
                        State.lastItemUseTime = GameTime()
                        State.actionTaken = true
                        return true
                    end
                end
                return false
            end
        end
        local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 520)) or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
        local anchor = behindT1
        local bLocNow = bot:GetLocation()
        if effEnemyLoc then
            anchor = H.GetSafeEscapePointAwayFromEnemy(bot, effEnemyLoc, safeDist + 95)
            if U.DistanceBetweenLocations(bLocNow, effEnemyLoc) >= 880 then
                anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, anchor, 780)) or anchor
            end
            if U.DistanceBetweenLocations(bLocNow, anchor) > 25 then
                H.SmartMove(bot, anchor, 40)
            end
        else
            local dBotFnt = U.DistanceBetweenLocations(bLocNow, fountain)
            if dBotFnt <= U.DistanceBetweenLocations(anchor, fountain) + 35 and dBotFnt > 450 then
                anchor = bLocNow + (fountain - bLocNow):Normalized() * math.min(380, dBotFnt - 420)
            end
            if dBotFnt > U.DistanceBetweenLocations(anchor, fountain) + 25 then
                H.SmartMove(bot, anchor, 40)
            end
        end
        State.actionTaken = true
        return true
    end

    -- `ShaNachnetsya` + `v7.9.11` Stat-Drop Salve Amplification (`Belt of Strength`, `Bracer`, `Circlet`, `Iron Branch`, etc.):
    -- Move highest-STR stat items into free/dormant Backpack slots BEFORE `Action_UseAbilityOnEntity(flask, bot)` and hold
    -- `State.branchTangoSwapUntil = GameTime() + 6.90` so `ManageInventorySlots` restores them at `6.90s` (`6.0s` CD finishes at `12.90s`!)
    if castable and flask and GameTime() > (State.lastSalveCastAt or -1000) + 0.25 then
        H.ManageTreads(bot, "FIGHT") -- AGI before healing so switching back to STR multiplies restored HP%
        local didSwap = false
        local safeOutOfCombat = (s and s.enemyAlive == false)
            or not (enemy and U.CanQuery(enemy) and GetUnitToLocationDistance(bot, enemy:GetLocation()) < safeDist)
        if safeOutOfCombat then
            local _, swappedAny = H.SwapStatItemsToBackpack(bot, SALVE_AMP_STAT_RANK, "item_flask", flask)
            didSwap = swappedAny
        end
        if didSwap then
            State.branchTangoSwapUntil = GameTime() + 6.90
        end
        State.salveBuffSeenAt = GameTime()
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastSalveCastAt = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    State.salveBuffSeenAt = nil
    -- `R2_2044` `04:21..04:26` `(1653, 1533) <-> (1450, 1334)` 1.00s Ping-Pong Fix:
    -- While an owned `item_flask` just moved out of Backpack (`flask ~= nil`, `not castable`) and no lane creeps exist,
    -- hold safely behind our T1 for the remaining Backpack unlock seconds so `holdSpot` & `EmergencyRetreat` NEVER fight!
    if flask and not castable and #(s and s.enemyCreeps or {}) == 0 then
        if H.TryInstantAdjacentTango and H.TryInstantAdjacentTango(bot, s) then
            return true
        end
        if (s and s.enemyAlive == false) or effEnemyDist >= safeDist + 240 then
            if H.HandleMidGameIdleCreepBlock and H.HandleMidGameIdleCreepBlock(bot, s) then
                return true
            end
        end
        local waitAnchor = (P.GetBehindT1 and P.GetBehindT1(bot, 420)) or bot:GetLocation()
        if U.DistanceBetweenLocations(bot:GetLocation(), fountain) > U.DistanceBetweenLocations(waitAnchor, fountain) then
            H.SmartMove(bot, waitAnchor, 45)
        end
        State.actionTaken = true
        return true
    end
    return false
end

-- Proactive & Active `modifier_clarity_potion` Outer-Raze Protector + `v7.9.11` Backpack INT Stat-Drop
-- (`Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, `Kaya`, `Null`, `Bracer`, `Circlet`):
--   * Before popping `item_clarity` and during `clarityElapsed < 18.8s` of the `25.0s` Clarity (when safely out of combat
--     and `not L._imminentCS`), swap highest-INT items into Backpack so flat `+6 MP/s` (`+150 MP`) restores a much higher
--     fraction of `MaxMP`, unlocking right at `18.8 + 6.0 = 24.8s`!
function H.HandleProactiveAndActiveClarity(bot, s, _earlyRace)
    if H.IsAtFountain(bot) or bot:IsChanneling() or bot:IsUsingAbility() then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local fountain = P.GetFountain(bot)
    local enemy = s and s.enemy
    local fogEnemyLoc = (not (enemy and U.CanQuery(enemy)))
        and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 4.5
        and s.enemyLastLoc or nil
    local effEnemyLoc = (enemy and U.CanQuery(enemy) and enemy:GetLocation()) or fogEnemyLoc
    local effEnemyDist = effEnemyLoc and GetUnitToLocationDistance(bot, effEnemyLoc) or 9999
    local safeClarityDist = math.max(1055, (C.REGEN and C.REGEN.ENEMY_SAFE_DISTANCE) or 1055)
    local nowClarity = GameTime()

    -- 1. Active `modifier_clarity_potion` protection (`150 MP` over `25s` = `2` full coils!)
    if bot:HasModifier("modifier_clarity_potion") then
        if not State.clarityBuffSeenAt or (nowClarity - State.clarityBuffSeenAt) > 26.5 then
            State.clarityBuffSeenAt = nowClarity
        end
        local clarityElapsed = nowClarity - State.clarityBuffSeenAt
        local maxMp = math.max(1, bot:GetMaxMana() or 1)
        local mpPct = (bot:GetMana() or 0) / maxMp
        if mpPct >= 0.96 then
            if State.clarityHoldingBackpack then
                State.clarityHoldingBackpack = false
                if not State.mangoSeq then State.branchTangoSwapUntil = 0 end
            end
            State.clarityBuffSeenAt = nil
            return false
        end
        -- Never throw away a guaranteed hero kill right in front of us just to save a `50g` Clarity!
        if enemy and U.CanQuery(enemy) and enemy:IsAlive() and (bot:GetHealth() or 0) >= 260 then
            if U.CanOneShotEnemyHero(bot, enemy) or U.CanQuickTurnKillWithRaze(bot, enemy)
                or H.CanTwoHitRightClickKill(bot, enemy, s) then
                if State.clarityHoldingBackpack then
                    State.clarityHoldingBackpack = false
                    if not State.mangoSeq then State.branchTangoSwapUntil = 0 end
                end
                return false
            end
        end
        local needStepBack = H.HasSalveBreakingProjectileIncoming(bot)
        local hystDist = (nowClarity < (State.clarityStepBackHystUntil or -1000)) and (safeClarityDist + 85) or safeClarityDist
        if effEnemyLoc and effEnemyDist < hystDist then
            needStepBack = true
        end

        -- `v7.9.11` Active Clarity Backpack INT Stat-Drop (`Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, etc.):
        -- Keep INT items in Backpack until `18.8s` (`6.0s` Backpack CD unlocks at `24.8s` of `25.0s` Clarity!) as long as
        -- SF is safely out of hero threat (`>= safeClarityDist + 75` or enemy dead) and not needing attack dmg for imminent CS!
        local safeForClarityDrop = (not needStepBack)
            and (not L._imminentCS)
            and ((s and s.enemyAlive == false) or effEnemyDist >= safeClarityDist + 75)
            and ((bot:GetHealth() / math.max(1, bot:GetMaxHealth() or 1)) >= 0.55)
            and (mpPct < 0.93)
            and (clarityElapsed < 18.8)
        if safeForClarityDrop then
            local creepsOnBotClar = 0
            for _, ecC in pairs((s and s.enemyCreeps) or {}) do
                if U.CanQuery(ecC) and ecC:IsAlive() and ecC.GetAttackTarget and ecC:GetAttackTarget() == bot then
                    creepsOnBotClar = creepsOnBotClar + 1
                end
            end
            if clarityElapsed <= 17.0 and creepsOnBotClar == 0 then
                H.SwapStatItemsToBackpack(bot, CLARITY_AMP_STAT_RANK, "item_clarity", nil)
            end
            State.clarityHoldingBackpack = true
            State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, nowClarity + 0.55)
        elseif State.clarityHoldingBackpack then
            State.clarityHoldingBackpack = false
            if not State.mangoSeq then State.branchTangoSwapUntil = 0 end
        end

        if needStepBack then
            State.clarityStepBackHystUntil = nowClarity + 0.95
            local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 460))
                or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
            local anchor = behindT1
            if effEnemyLoc then
                local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeClarityDist + 95)
                anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, rawAnchor, 720)) or rawAnchor
            end
            H.ManageTreads(bot, "FIGHT") -- Hold AGI/STR so flat +6 MP/s restores higher % of maxMana!
            H.SmartMove(bot, anchor, 40)
            State.actionTaken = true
            return true
        end
        -- Safe (`>= 1,055u` from enemy hero): keep PT off INT for maximum % mana gain, and let `RunMainPipeline` farm safe CS!
        H.ManageTreads(bot, "FIGHT")
        return false
    elseif State.clarityHoldingBackpack then
        State.clarityHoldingBackpack = false
        State.clarityBuffSeenAt = nil
        if not State.mangoSeq and not bot:HasModifier("modifier_flask_healing") then
            State.branchTangoSwapUntil = 0
        end
    end

    -- 2. Proactive `item_clarity` activation (`missingMana >= 155`, no Mango on hand, no imminent CS!)
    if L._imminentCS then return false end
    local curMana = bot:GetMana() or 0
    local maxMana = math.max(1, bot:GetMaxMana() or 300)
    if (maxMana - curMana) < 155 or (curMana / maxMana) > 0.52 then return false end
    if U.HasItem(bot, "item_enchanted_mango") then return false end
    local clarSlot = bot:FindItemSlot("item_clarity")
    if clarSlot < 0 or clarSlot > 8 then return false end
    local clarItem, clarReady = H.EnsureConsumableReady(bot, "item_clarity")
    if not clarReady or not clarItem then return false end
    if H.HasSalveBreakingProjectileIncoming(bot) or (effEnemyLoc and effEnemyDist < (safeClarityDist + 55)) then
        if #(s and s.enemyCreeps or {}) == 0 and effEnemyLoc then
            local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeClarityDist + 95)
            local anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, rawAnchor, 720)) or rawAnchor
            H.SmartMove(bot, anchor, 40)
            State.actionTaken = true
            return true
        end
        return false
    end
    H.ManageTreads(bot, "FIGHT")
    local safeClarityOutOfCombat = ((s and s.enemyAlive == false) or effEnemyDist >= safeClarityDist + 75)
        and ((bot:GetHealth() / math.max(1, bot:GetMaxHealth() or 1)) >= 0.55)
    if safeClarityOutOfCombat then
        local _, didClarSwap = H.SwapStatItemsToBackpack(bot, CLARITY_AMP_STAT_RANK, "item_clarity", clarItem)
        if didClarSwap then
            State.clarityHoldingBackpack = true
            State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, nowClarity + 0.65)
        end
    end
    State.clarityBuffSeenAt = nowClarity
    bot:Action_UseAbilityOnEntity(clarItem, bot)
    State.lastItemUseTime = nowClarity
    State.actionTaken = true
    return true
end

-- `v7.9.6` + `v7.9.11` Engine-Exact 3-Phase Multi-Tick Mango + Power Treads + Priority Stat-Item Backpack State Machine
-- (`Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, `Kaya`, `Null`, `Bracer`, `Circlet`, `Wand`, etc. sorted by `+INT`!):
--   Exact 3-Phase Multi-Tick Protocol:
--     * Phase 1 (`Tick T`): Toggle Power Treads off `INT (2) -> AGI (1)` (`1` unit order, NEVER overwritten!) AND
--       `ActionImmediate_SwapItems` highest-INT stat items to Backpack (`Staff (+10) > Robe (+6) > Bracer/Circlet (+2) > Branch (+1)`).
--     * Phase 2 (`Tick T+2`, once `GetMaxMana() < preMaxMana - 1` or `+0.066s`): Fire `Action_UseAbility(mango)` ALONE on
--       reduced `MaxMP`!
--     * Phase 3 (`Tick T+4`, once `charges < preCharges` or `+0.066s`): Swap all Backpack stat items back to exact slots!

function H.CountInventoryItemCharges(bot, itemName)
    local total = 0
    for sl = 0, 8 do
        local it = bot:GetItemInSlot(sl)
        if it and it:GetName() == itemName then
            total = total + math.max(1, (it.GetCurrentCharges and it:GetCurrentCharges()) or 1)
        end
    end
    return total
end

function H.RestoreMangoSwaps(bot, seq)
    if not seq or not seq.swaps then return end
    for i = #seq.swaps, 1, -1 do
        local pair = seq.swaps[i]
        if pair and pair[1] and pair[2] then
            bot:ActionImmediate_SwapItems(pair[1], pair[2])
        end
    end
    if U.BumpInventoryEpoch then U.BumpInventoryEpoch() end
    seq.swaps = nil
end

function H.TickMangoStateMachine(bot, _s)
    local seq = State.mangoSeq
    if not seq then return false end
    local now = GameTime()
    if not bot:IsAlive() or bot:IsChanneling() or (now - (seq.startedAt or now)) > 0.65 then
        H.RestoreMangoSwaps(bot, seq)
        State.mangoSeq = nil
        State.branchTangoSwapUntil = 0
        return false
    end

    State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, now + 0.50)

    if seq.step == "WAIT_STAT_DROP" then
        -- Ensure Power Treads actually stepped off INT (`2`) before popping Mango
        local ptStat = U.GetCurrentPowerTreadsStat and U.GetCurrentPowerTreadsStat(bot) or nil
        if ptStat == ((C.TREADS and C.TREADS.INTELLIGENCE) or 2) and not bot:IsUsingAbility() then
            if U.SwitchTreadsTo(bot, (C.TREADS and C.TREADS.AGILITY) or 1, { urgent = true, hold = 0.85 }) then
                seq.prepAt = now
                State.actionTaken = true
                return true
            end
        end
        local curMaxMp = bot:GetMaxMana() or 0
        if curMaxMp >= (seq.preMaxMana or 0) - 1 and (now - (seq.prepAt or now)) < 0.066 then
            State.actionTaken = true
            return true
        end
        if bot:IsUsingAbility() then
            return false
        end
        local mangoNow = U.GetActiveItemByName(bot, "item_enchanted_mango")
        if not (mangoNow and mangoNow:IsFullyCastable()) then
            H.RestoreMangoSwaps(bot, seq)
            State.mangoSeq = nil
            State.branchTangoSwapUntil = 0
            return false
        end
        bot:Action_UseAbility(mangoNow)
        seq.castAt = now
        seq.step = "WAIT_CONSUME"
        State.lastItemUseTime = now
        State.actionTaken = true
        return true
    elseif seq.step == "WAIT_CONSUME" then
        local curCharges = H.CountInventoryItemCharges(bot, "item_enchanted_mango")
        if curCharges < (seq.preCharges or 0) or (now - (seq.castAt or now)) >= 0.066 then
            H.RestoreMangoSwaps(bot, seq)
            State.mangoSeq = nil
            State.branchTangoSwapUntil = 0
            return false
        end
        State.actionTaken = true
        return true
    end

    H.RestoreMangoSwaps(bot, seq)
    State.mangoSeq = nil
    State.branchTangoSwapUntil = 0
    return false
end

function H.StartMangoPop(bot, allowBackpackDrop, immediateEmergency)
    if State.mangoSeq then
        return H.TickMangoStateMachine(bot, nil)
    end
    local mango, castable = H.EnsureConsumableReady(bot, "item_enchanted_mango")
    if not castable or not mango then return false end
    local now = GameTime()

    -- True `< 0.03s` close-combat emergency (`< 75 MP` right next to rival): fire Mango immediately with ZERO conflicting PT order!
    if immediateEmergency then
        bot:Action_UseAbility(mango)
        State.lastItemUseTime = now
        State.branchTangoSwapUntil = 0
        State.actionTaken = true
        return true
    end

    local preMaxMana = bot:GetMaxMana() or 0
    local preCharges = H.CountInventoryItemCharges(bot, "item_enchanted_mango")
    local ptStat = U.GetCurrentPowerTreadsStat and U.GetCurrentPowerTreadsStat(bot) or nil
    local toggledPT = false
    if ptStat == ((C.TREADS and C.TREADS.INTELLIGENCE) or 2) then
        toggledPT = U.SwitchTreadsTo(bot, (C.TREADS and C.TREADS.AGILITY) or 1, { urgent = true, hold = 0.85 })
    end

    local swaps = {}
    if allowBackpackDrop then
        local rankMap = (allowBackpackDrop == "INT_ONLY") and MANGO_LOW_RISK_INT_ITEMS or MANGO_AMP_STAT_ITEMS
        swaps = H.SwapStatItemsToBackpack(bot, rankMap, "item_enchanted_mango", mango)
    end

    -- If neither PT was on INT nor any stat item swapped to Backpack, `MaxMP` will not change — pop Mango immediately!
    if not toggledPT and #swaps == 0 then
        bot:Action_UseAbility(mango)
        State.lastItemUseTime = now
        State.branchTangoSwapUntil = 0
        State.actionTaken = true
        return true
    end

    State.mangoSeq = {
        step       = "WAIT_STAT_DROP",
        startedAt  = now,
        prepAt     = now,
        preMaxMana = preMaxMana,
        preCharges = preCharges,
        swaps      = swaps,
    }
    State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, now + 0.65)
    State.actionTaken = true
    return true
end

function H.IsSafeForBackpackMangoDrop(bot, s)
    if (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.62 then return false end
    if bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(2.5) then return false end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.5) then return false end
    local enVisible = s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
    local enDist = enVisible and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
    if enVisible and enDist <= 1080 then
        return false
    end
    if s and s.enemyAlive ~= false then
        local myT1Obj = (s and s.allyT1) or (W and W.s and W.s.allyT1)
        local myT1Loc = (s and s.allyT1Loc)
            or (myT1Obj and U.CanQuery(myT1Obj) and myT1Obj:GetLocation())
            or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
        local fnt = P.GetFountain(bot)
        local safeT1Rad = (enVisible and enDist >= 1250) and 980 or 760
        -- `v7.9.11` Fix: Standing BEHIND `myT1Loc` toward `fountain` (`dBotFnt <= dT1Fnt`) is our own base territory
        -- and is ALWAYS safe from forward river exposure! Only reject when stepped `> safeT1Rad` forward past `myT1Loc`!
        if myT1Loc then
            local dBotFnt = U.DistanceBetweenLocations(bot:GetLocation(), fnt)
            local dT1Fnt = U.DistanceBetweenLocations(myT1Loc, fnt)
            if dBotFnt > dT1Fnt and GetUnitToLocationDistance(bot, myT1Loc) > safeT1Rad then
                return false
            end
        end
        if (not enVisible) and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 8.0
            and GetUnitToLocationDistance(bot, s.enemyLastLoc) <= 1320 then
            return false
        end
    end
    return true
end

-- Determine whether Mango can drop ALL stat items (`"FULL"`, including `Bracer`/`Circlet`),
-- pure-INT/minor items (`"INT_ONLY"` = `Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, `Kaya`, `Null`), or `false`.
function H.GetMangoDropMode(bot, s, immediateEmerg)
    if immediateEmerg then return false end
    if H.IsSafeForBackpackMangoDrop(bot, s) and #(s and s.enemyCreeps or {}) == 0 then
        return "FULL"
    end
    if L._imminentCS then return false end
    if (bot:GetHealth() / math.max(1, bot:GetMaxHealth() or 1)) < 0.48 then return false end
    if bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(2.0) then return false end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.0) then return false end
    local enVisible = s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
    local enDist = enVisible and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
    if enVisible and enDist < 960 then return false end
    if (not enVisible) and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 5.5
        and GetUnitToLocationDistance(bot, s.enemyLastLoc) < 1080 then
        return false
    end
    return "INT_ONLY"
end

function H.TryBackpackAmpMango(bot, s)
    if State.mangoSeq then
        return H.TickMangoStateMachine(bot, s)
    end
    local curManaNow = bot:GetMana() or 0
    local missManaNow = (bot:GetMaxMana() or 0) - curManaNow
    local closeEnemyDist = (s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive())
        and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
    local activeDualCoilPop = curManaNow < 145 and missManaNow >= 115
        and ((U.GetItemCount and U.GetItemCount(bot, "item_enchanted_mango") or 0) >= 2 or closeEnemyDist <= 950)
    if curManaNow < 90 or activeDualCoilPop then
        local immediateEmerg = (curManaNow < 75 and closeEnemyDist <= 680)
        local dropMode = H.GetMangoDropMode(bot, s, immediateEmerg)
        if H.StartMangoPop(bot, dropMode, immediateEmerg) then
            return true
        end
        if curManaNow < 90 then return false end
    end

    if missManaNow < 115 then return false end
    local idleDropMode = H.GetMangoDropMode(bot, s, false)
    if not idleDropMode then return false end
    if idleDropMode ~= "FULL" and s and #(s.enemyCreeps or {}) > 0 and missManaNow < 145 then
        return false
    end
    return H.StartMangoPop(bot, idleDropMode, false)
end

-- Opportunistic 0-tick / 1-step Tango Eat (`v7.9.1`, `9071946472.dem` `00:42–01:31` Early Tango Fix!):
-- Whenever SF has `item_tango` ready (`slot 0..5`), no `modifier_tango_heal` active, `missingHp >= 110`,
-- and is ALREADY passing within `<= 235u` of a safe own-side tree (e.g. retreating behind T1 or waiting for Salve),
-- eat that adjacent tree (`0.0s` cast point, `165u` cast range; Tango stacks cleanly with Salve in Dota 2!).
function H.TryInstantAdjacentTango(bot, s)
    if bot:HasModifier("modifier_tango_heal") or H.IsAtFountain(bot) then return false end
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local curHp = bot:GetHealth() or 0
    local missingHp = maxHp - curHp
    local hpPct = curHp / maxHp
    local hpRegen = (bot.GetHealthRegen and bot:GetHealthRegen()) or 3.0
    local minDeficit = math.max(135, 88 + hpRegen * 9.0)
    -- `auto-20261102-0043` `5:10.87` (`1138/1276 = 89.2% HP` Wasted Tango Fix):
    -- Require BOTH `hpPct <= 0.84` AND `missingHp >= minDeficit` so passive HP regen handles minor `110..145 HP` scratches!
    if hpPct > 0.84 or missingHp < minDeficit then return false end
    local tango = U.GetActiveItemByName(bot, "item_tango")
    if not tango or not tango:IsFullyCastable() then return false end
    local now = GameTime()
    if State.tangoCastAt and now < State.tangoCastAt then return false end
    local tree = H.GetStickyTangoTree(bot, s and s.enemy or nil, s and s.enemyTowers or {})
    if not tree then return false end
    local treeLoc = GetTreeLocation(tree)
    if not treeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, treeLoc)
    if dist > 235 then return false end
    if dist <= 165 then
        bot:Action_UseAbilityOnTree(tango, tree)
        State.lastTriedTreeId = tree
        State.lastTriedTreeAt = now
        State.lastItemUseTime = now
        State.tangoCastAt = now + 0.45
        State.branchTangoSwapUntil = 0
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    H.SmartMove(bot, treeLoc, 35)
    State.actionTaken = true
    return true
end

-- Wave-Safe Static-Tree Tango Controller (runs AFTER `RunSacredCS`, BEFORE `holdSpot` — NEVER plants TempTree,
-- NEVER drops a 0.000s lane CS, `userdata`-safe `(bot, enemyHero, enemyTowers)` argument order!).
function H.TryWaveSafeStaticTango(bot, s, csWaveBusy)
    if bot:HasModifier("modifier_tango_heal") or bot:HasModifier("modifier_flask_healing") then
        State.tangoCastAt = 0
        return false
    end
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local curHp = bot:GetHealth() or 0
    local missingHp = maxHp - curHp
    local hpPct = curHp / maxHp
    local hpRegen = (bot.GetHealthRegen and bot:GetHealthRegen()) or 3.0
    local minDeficit = math.max(135, 88 + hpRegen * 9.0)
    if hpPct > 0.84 or missingHp < minDeficit then return false end
    if H.IsAtFountain(bot) then return false end
    local tangoSlot = bot:FindItemSlot("item_tango")
    if tangoSlot < 0 or tangoSlot > 8 then return false end

    local now = GameTime()
    -- `9072220529.dem` `1:47.67` Fix: NEVER abort an active 4-creep body-block sideways into the trees for a non-urgent Tango (`> 52% HP`)!
    if hpPct > 0.52 and (now - (State.activeCreepBlockAt or -10)) <= 0.35 then
        return false
    end
    if State.tangoCastAt and now < State.tangoCastAt then
        State.actionTaken = true
        return true
    end

    -- CRITICAL (`auto-20261023-1329-start-ShaNachnetsya.dem` `tk=9902..11852` Infinite Swap Fix!):
    -- ALWAYS validate `tree` AND `dist <= allowedTreeWalk` BEFORE calling `EnsureConsumableReady("item_tango")`!
    local tree = H.GetStickyTangoTree(bot, s and s.enemy or nil, s and s.enemyTowers or {})
    if not tree then return false end
    local treeLoc = GetTreeLocation(tree)
    if not treeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, treeLoc)
    local waveActive = s and (#(s.enemyCreeps or {}) > 0 or #(s.allyCreeps or {}) > 0)
    local unopposedEnemyWave = s and #(s.enemyCreeps or {}) > 0 and #(s.allyCreeps or {}) == 0
    local enemyLive = s and s.enemy and U.CanQuery(s.enemy)
    -- `v7.9.1` Early Ramp-Tree Walk Fix (`9071946472.dem` `00:42` `475/648 = 73% HP` Fix!):
    -- From the mid river (`(-150,-80)`) to our T1 highground ramp trees is `540..820u`! Previously capping `allowedWalk`
    -- at `240..300u` whenever `hpPct > 0.65` prevented eating ANY Tango until `< 65% HP`! Now allow `820u` whenever
    -- `not csWaveBusy` (no imminent last-hit!) and `missingHp >= 135` (`hpPct <= 0.79`), and `980u` when `hpPct <= 0.65`!
    local maxSafeTreeWalk = unopposedEnemyWave and 210
        or ((not csWaveBusy and (missingHp >= 135 or hpPct <= 0.78)) and 820
            or ((not csWaveBusy and enemyLive and hpPct <= 0.83) and 420 or 260))
    local allowedWalk = (hpPct <= 0.65 and not unopposedEnemyWave) and 980 or maxSafeTreeWalk
    if waveActive and dist > allowedWalk then
        return false
    end
    -- `auto-20261102-0007` `3:57.40` (`(732, 80)` `dEC=1817u > 1500u` XP Radius Loss Fix!):
    -- When non-critical (`hpPct > 0.38`) during an active wave, NEVER walk to a deep jungle tree outside `1,380u`
    -- of the active enemy creep wave (missing `62..90` creep XP)!
    if waveActive and hpPct > 0.38 and s and s.enemyCreeps then
        local minTreeToWave = 9999
        local anyWaveNear = false
        for _, ec in pairs(s.enemyCreeps) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 1650 then
                anyWaveNear = true
                local dTC = U.DistanceBetweenLocations(treeLoc, ec:GetLocation())
                if dTC < minTreeToWave then minTreeToWave = dTC end
            end
        end
        if anyWaveNear and minTreeToWave > 1380 then
            return false
        end
    end

    local tango, castable = H.EnsureConsumableReady(bot, "item_tango")
    if not tango then return false end
    if not castable then
        -- Pre-walk toward the safe ramp tree while Backpack CD counts down when no CS is active (or HP <= 55%)!
        if (not csWaveBusy and (not waveActive or hpPct <= 0.55)) and dist > 155 then
            H.SmartMove(bot, treeLoc, 40)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist <= 165 then
        if State.lastTriedTreeId == tree and State.lastTriedTreeAt and now - State.lastTriedTreeAt > 0.65 and now - State.lastTriedTreeAt < 3.0 then
            State.blacklistedTrees = State.blacklistedTrees or {}
            State.blacklistedTrees[tree] = now + 15.0
            State.tangoBadTree = tree
            State.tangoBadTreeTime = now
            State.stickyTangoTree = nil
            State.lastTriedTreeId = nil
            return false
        end
        bot:Action_UseAbilityOnTree(tango, tree)
        State.lastTriedTreeId = tree
        State.lastTriedTreeAt = now
        State.lastItemUseTime = now
        State.tangoCastAt = now + 0.55
        State.branchTangoSwapUntil = 0
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    H.SmartMove(bot, treeLoc, 40)
    State.actionTaken = true
    return true
end

-- Pro 1v1 Mid Upgrade #1: Enemy CS-Windup Self-Root Punish (`~0.45s` guaranteed hit window!)
-- Whenever the rival SF swings at a lane creep (`GetAttackTarget() ~= bot`), he is locked in his attack windup:
--   * Punish with a safe centered `Shadowraze` when NOT out-razed in tier & NOT on a Raze-spike XP boundary, OR
--   * Fire an uncontested zero-aggro / cooldown-ready right-click while his attack cooldown is spent on the creep!
function H.HandleEnemyCSWindupPunish(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GameTime() < (State.noHarassTurnbackUntil or 0) then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if not U.IsAttackingAction(enemy) then return false end
    local enTgt = enemy.GetAttackTarget and enemy:GetAttackTarget() or nil
    if not enTgt or enTgt == bot then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.losingHard) then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    if myHp < 285 or d > 915 then return false end

    local outRazed = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local nearSpike = (earlyRace and earlyRace.valid and earlyRace.nearLevelSpike)
        or (U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy)) or false
    local enStacks = U.GetShadowrazeDebuff(enemy) or 0
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local enPotMana = U.GetPotentialManaForRaze(enemy)

    -- 1. Safe centered Shadowraze into enemy's self-rooted CS windup (when band reply is safe or we lead stacks / he is dry!)
    local mySustWindup = (K.MySustainedManaBudget and K.MySustainedManaBudget(bot, 6.5)) or K.MyManaBudget(bot, true)
    local singleCoilWindupTrap = (mySustWindup < 145)
        and (enPotMana >= 150)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)
    local lastManaBehindWindup = (mySustWindup < 145)
        and (enPotMana >= 75)
        and ((enemy:GetHealth() or 9999) > myHp + 110)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)
    if not outRazed and not nearSpike and not bot:IsSilenced() and (bot:GetMana() or 0) >= 75 and myStacks == 0 then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            if (not singleCoilWindupTrap or (label == "far" and d >= 660))
                and (not lastManaBehindWindup or (label == "far" and d >= 775)) then
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local bandSafe = K.BandSafeFromEnemy(enemy, label, 0.85) or (enPotMana < 75) or (enStacks >= 1 and myHp >= 380)
                    if bandSafe then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    -- 2. Free right-click into enemy's CS windup when attack is ready and we draw 0/minimal creep aggro!
    local now = GameTime()
    local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
    local atkReady = (now - (bot:GetLastAttackTime() or -100)) >= (mySpa * 0.88)
    local myRange = math.max(525, bot:GetAttackRange() or 525)
    if not H.IsDryVsEnemyRaze(bot, enemy) and atkReady and d <= myRange + 42 and not (earlyRace and earlyRace.valid and earlyRace.uphillPenalty) then
        local minCreepD, creepsHittingMe = 9999, 0
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc < minCreepD then minCreepD = dc end
                if ec.GetAttackTarget and ec:GetAttackTarget() == bot then creepsHittingMe = creepsHittingMe + 1 end
            end
        end
        local zeroAggroWindow = (minCreepD > 502) or (now < (State.myCreepAggroCdUntil or 0) - 0.20 and creepsHittingMe == 0)
        if zeroAggroWindow or (creepsHittingMe == 0 and myHp >= 360 and minCreepD > 310) then
            local prevP, prevA = State.combatPolicyActive, State.heroCombatAllowed
            State.combatPolicyActive, State.heroCombatAllowed = false, true
            local ok = H.IssueHeroAttack(bot, enemy)
            State.combatPolicyActive, State.heroCombatAllowed = prevP, prevA
            if ok then
                State.lastHarassTime = now
                State.actionTaken = true
                return true
            end
        end
    end
    return false
end

-- Exact Patch 7.41f Own-Highground Detector (`z >= 112` on our side of the mid staircase, strictly before the river drop).
function H.IsOnOwnMidHighground(bot, pt)
    if not pt then return false end
    local _, myT1, _, _, enT1, _ = H.GetMidTowerGeometry(bot)
    local dMyT1 = U.DistanceBetweenLocations(pt, myT1)
    local dEnT1 = U.DistanceBetweenLocations(pt, enT1)
    if dMyT1 > 1035 or dMyT1 >= dEnT1 - 120 then
        return false
    end
    if type(GetHeightLevel) == "function" then
        local okP, hPt = pcall(GetHeightLevel, pt)
        local okT, hT1 = pcall(GetHeightLevel, myT1)
        if okP and okT and type(hPt) == "number" and type(hT1) == "number" then
            return hPt >= hT1
        end
    end
    return (pt.z or 128) >= 112
end

-- Pro Highground `25%` Uphill-Miss Harass with Strictly ZERO Enemy Creep Aggro (`v7.9.2`):
--   * Leverages our `z = 128` mid highground (`25%` enemy uphill miss + uphill vision) to right-click Enemy SF
--     WITHOUT ever pulling enemy creeps off the staircase equilibrium!
--   * Three exact engine-safe paths:
--       1. Direct Highground Strike when `minCreepDist >= 508u` OR `aggroCdPrimed` (`>= 0.50s` remaining on `3.00s` global CD).
--       2. Short Highground-Lip Step-Up (`<= 190u`, staying strictly on `IsOnOwnMidHighground(pokePt)` and `>= 505u` outside
--          enemy `Q`/`W`) to a `pokePt` where `minCreepDist(pokePt) >= 512u` OR `aggroCdPrimed`.
--       3. `>= 510u` Highground Aggro-CD Pre-Prime: when standing at `minCreepDist >= 510u` on our HG while `pokePt` is
--          `360..511u` from staircase creeps, tap 1 zero-aggro attack order to start the `3.00s` global aggro cooldown (`0` creeps
--          aggroed!), step in for `1` free uphill shot during `aggroCdPrimed`, and step back before CD expiry!
function H.HandleHighgroundZeroAggroHarass(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.losingHard) then
        return false
    end

    local bLoc = bot:GetLocation()
    if not H.IsOnOwnMidHighground(bot, bLoc) then return false end

    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local myHp = bot:GetHealth() or 0
    local myRange = math.max(500, bot:GetAttackRange() or 500)
    if myHp < 280 or d > myRange + 215 then return false end

    -- Require true uphill elevation advantage (`eLoc` in river/stairs) OR safe lip posture
    local uphillAdvantage = ((bLoc.z or 128) - (eLoc.z or 0)) >= 30
    if type(GetHeightLevel) == "function" then
        local okB, hB = pcall(GetHeightLevel, bLoc)
        local okE, hE = pcall(GetHeightLevel, eLoc)
        if okB and okE and type(hB) == "number" and type(hE) == "number" then
            uphillAdvantage = uphillAdvantage or (hB > hE)
        end
    end
    if not uphillAdvantage and H.IsDryVsEnemyRaze(bot, enemy) then
        return false
    end

    local eCreepList = {}
    local seenEc = {}
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() then
            seenEc[ec] = true
            eCreepList[#eCreepList + 1] = ec
        end
    end
    if bot.GetNearbyLaneCreeps then
        for _, ec in pairs(bot:GetNearbyLaneCreeps(700, true) or {}) do
            if ec and not seenEc[ec] and U.CanQuery(ec) and ec:IsAlive() then
                seenEc[ec] = true
                eCreepList[#eCreepList + 1] = ec
            end
        end
    end

    local creepsHittingMe = 0
    local function minCreepDistAt(pt)
        local md = 9999
        for _, ec in ipairs(eCreepList) do
            local dc = U.DistanceBetweenLocations(pt, ec:GetLocation())
            if dc < md then md = dc end
        end
        return md
    end
    for _, ec in ipairs(eCreepList) do
        if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
            creepsHittingMe = creepsHittingMe + 1
        end
    end
    if creepsHittingMe > 0 then return false end

    local now = GameTime()
    local minCreepNow = minCreepDistAt(bLoc)
    local cdRem = (State.myCreepAggroCdUntil or 0) - now
    local aggroCdPrimed = (cdRem >= 0.52) and (now >= (State.myCreepChaseUntil or 0))

    -- Pre-expiry lane-control guard: if our `3.00s` global aggro CD is about to expire (`< 0.45s`) while we stepped
    -- within `< 508u` of enemy creeps on our HG, step cleanly back to `>= 515u` BEFORE a 2nd auto-attack can pull aggro!
    if cdRem > -0.15 and cdRem < 0.45 and minCreepNow < 508 and State.hgSteppedInForPoke then
        State.hgSteppedInForPoke = false
        local _, myT1 = H.GetMidTowerGeometry(bot)
        local backPt = bLoc + (myT1 - bLoc):Normalized() * math.max(55, 520 - minCreepNow)
        if U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemy then
            bot:Action_ClearActions(true)
        end
        H.SmartMove(bot, backPt, 24, true)
        State.actionTaken = true
        return true
    end

    if L.PeekBestPlan then
        local _, etaCs = L.PeekBestPlan(bot, s)
        if etaCs <= ((d <= myRange + 38) and 0.48 or 0.98) then
            return false
        end
    end

    local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.50)
    local atkReady = (now - (bot:GetLastAttackTime() or -100)) >= (mySpa * 0.88)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    local outRazed = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local myStHG, myRemHG = U.GetShadowrazeDebuff(bot)
    local wAbHG = H.GetRazeAbilityByLabel(bot, "mid")
    local eAbHG = H.GetRazeAbilityByLabel(bot, "far")
    local myMidFarSpentHG = (not (wAbHG and U.IsRazeAbilityCastable(bot, wAbHG)))
        and (not (eAbHG and U.IsRazeAbilityCastable(bot, eAbHG)))
    -- `v7.9.9-pro` (`1814 @ 07:53.13` Fix): `Shadowraze2` reaches `450 + 274 = 724u` (NEVER `505u`, which is inside dead-center `W`!),
    -- and carrying `myStacks >= 1` while our `W`+`E` are spent makes walking `< 735u` for 1 poke auto feed a `287`-dmg 2nd-stack `W`!
    local midBandUnsafe = (enPotMana >= 75) and (K.EnemyRazeReadyIn("mid") <= 1.15)
        and (outRazed or (bot:GetMana() or 0) < 75 or ((myStHG or 0) >= 1 and (myRemHG or 0) > 1.20 and myMidFarSpentHG))
    local movingAway = K.IsEnemyMovingAway(bot, enemy)
    local strikeReach = myRange + (movingAway and 20 or 40)

    -- Path 1: Instant Highground Strike (`0` creep aggro guaranteed by `minCreepNow >= 508` OR `aggroCdPrimed`!)
    if atkReady and d <= strikeReach and (not midBandUnsafe or d >= 735) and (minCreepNow >= 508 or aggroCdPrimed) then
        local prevP, prevA = State.combatPolicyActive, State.heroCombatAllowed
        State.combatPolicyActive, State.heroCombatAllowed = false, true
        local ok = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive, State.heroCombatAllowed = prevP, prevA
        if ok then
            State.hgSteppedInForPoke = (minCreepNow < 508)
            State.lastHarassTime = now
            State.actionTaken = true
            return true
        end
    end

    -- Compute short Highground-Lip `pokePt` (`<= 190u` step that stays strictly on `IsOnOwnMidHighground` and outside unsafe `W`/`Q`)
    if atkReady and not movingAway and d > strikeReach and d <= myRange + 195 then
        local dirToEn = (eLoc - bLoc):Normalized()
        local stepDist = math.max(24, d - (myRange + 14))
        local pokePt = Vector(bLoc.x + dirToEn.x * stepDist, bLoc.y + dirToEn.y * stepDist, bLoc.z or 128)
        local pokeDistEn = U.DistanceBetweenLocations(pokePt, eLoc)
        if H.IsOnOwnMidHighground(bot, pokePt) and (not midBandUnsafe or pokeDistEn >= 735) and (pokeDistEn >= 505 or enPotMana < 75) then
            local minCreepPoke = minCreepDistAt(pokePt)
            -- Path 2: Walk onto our Highground Lip & fire (`minCreepPoke >= 512` OR `aggroCdPrimed` = ZERO aggro!)
            if minCreepPoke >= 512 or (aggroCdPrimed and minCreepPoke >= 355) then
                State.hgSteppedInForPoke = (minCreepPoke < 508)
                H.SmartMove(bot, pokePt, 22, true)
                State.actionTaken = true
                return true
            end
            -- Path 3: Pre-Prime `3.00s` Global Aggro CD from `minCreepNow >= 510u` (`0` creeps in `500u`!), unlocking Path 2 on next tick!
            if not aggroCdPrimed
                and now >= (State.myCreepAggroCdUntil or 0)
                and now >= (State.lastAggroPrimeAt or -100) + 3.40
                and minCreepNow >= 510
                and minCreepPoke >= 355 then
                bot:Action_AttackUnit(enemy, false)
                State.myCreepAggroCdUntil = now + 3.00
                State.myCreepChaseUntil = 0
                State.lastAggroPrimeAt = now
                State.actionTaken = true
                return true
            end
        end
    end

    return false
end

-- Pro 1v1 Mid Upgrade #2: Exact Source 2 `500u` Global Creep-Aggro Cooldown Abuse (`3.0s` zero-aggro harass window!)
--   * Phase 1 (`Prime`): Standing `>= 504u` from ALL enemy lane creeps (`0` creeps in `500u` trigger circle!), tap a 1-tick
--     attack order on `enemy` to start the `3.00s` global player aggro cooldown with ZERO creeps aggroed!
--   * Phase 2 (`Zero-Aggro Strike`): During `[now .. myCreepAggroCdUntil - 0.25]` with `0` creeps chasing us (OR whenever
--     `minCreepDist > 503u`), fire crisp uncontested right-clicks on `enemy` across the wave without drawing 1 creep hit!
-- Pro-Human `500u` Defensive Creep-Aggro Equilibrium Pull (`auto-20261102-0007`: `ShaNachnetsya = 92` pulls vs `Bot = 0`!):
-- When zoned by uphill miss penalty, low-mana disadvantage, or HP deficit while healthy enemy melee creeps (`>= 170 HP`)
-- stand within `220..490u` of us (`Dota 2 500u aggro radius`) and NO CS/deny opens within `<= 1.35s`:
--   * Tick 1: Issue 1-frame `Action_AttackUnit(enemy, true)` from safe standoff (`d >= 545u`), triggering `2.3s` creep leash
--             without walking into enemy `Q`/autos, and stamp `myCreepAggroCdUntil = now + 3.0`.
--   * Next `0.28s`: Step `210u` toward our allied ranged creep / Fountain so enemy melee creeps drag onto our highground!
function H.HandleDefensiveCreepAggroPull(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local now = GameTime()
    -- Complete active `0.28s` post-click leash drag (yielding immediately if `imminentCreepCS` or critical danger fires!)
    if now < (State.defAggroPullDragUntil or 0) and State.defAggroPullAnchor then
        local planNow, etaNow = L.PeekBestPlan(bot, s)
        if planNow and etaNow <= 0.75 then
            State.defAggroPullDragUntil = 0
            return false
        end
        H.SmartMove(bot, State.defAggroPullAnchor, 30)
        State.actionTaken = true
        return true
    end

    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.IsHeroWindupNow(bot, enemy) then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 or H.IsNearOwnT1(bot, 780) then return false end
    if H.InLosingHeroTrade(bot, s, earlyRace) then return false end
    if (State.forcedRetreatLoc ~= nil and now < (State.forcedRetreatUntil or 0))
        or now < (State.fleeUntil or 0) or now < (State.critDangerHystUntil or 0) then
        return false
    end
    if earlyRace and earlyRace.valid and (earlyRace.canKillNow or earlyRace.canKillSoon or earlyRace.heCanKillNow) then
        return false
    end
    if now < (State.myCreepAggroCdUntil or 0) or now < (State.lastDefAggroPullAt or -100) + 5.5 then
        return false
    end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 999
    local minSafePullDist = H.IsDryVsEnemyRaze(bot, enemy) and 755 or 565
    -- Safe standoff `[minSafePullDist..1350u]`: Dota 2 hero-attack order triggers `500u` creep aggro instantly at ANY distance!
    if myHp < 380 or d < minSafePullDist or d > 1350 then return false end

    local wantEquilibriumPull = (earlyRace and earlyRace.valid and earlyRace.uphillPenalty)
        or H.IsDryVsEnemyRaze(bot, enemy)
        or (K.MyManaBudget(bot, true) < 145 and K.EnemyManaBudget(enemy, true) >= 150)
        or (myHp < enHp - 115)
    if not wantEquilibriumPull then return false end

    -- `auto-20261102-0139` `2:37` Aggro-Pull CS Protection:
    -- Never disturb any enemy CS or allied deny opening within `<= 2.35s`, nor when any nearby enemy creep is already
    -- chipped (`hp <= myAtk * 2.6`) or allied ranged creep is denyable soon (`hp <= myAtk * 2.2`)!
    local planSoon, etaSoon = L.PeekBestPlan(bot, s)
    if planSoon and etaSoon <= 2.35 then return false end

    local myAtkPull = math.max(55, bot:GetAttackDamage() or 55)
    local pullableMelee = 0
    local creepsAlreadyOnMe = 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() then
            if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                creepsAlreadyOnMe = creepsAlreadyOnMe + 1
            end
            local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
            if dc <= 720 and (ec:GetHealth() or 999) <= (myAtkPull * 2.6) then
                return false
            end
            local ecRange = (ec.GetAttackRange and ec:GetAttackRange()) or 100
            if ecRange <= 180 and dc >= 205 and dc <= 490 and (ec:GetHealth() or 0) >= 220 then
                pullableMelee = pullableMelee + 1
            end
        end
    end
    for _, ac in pairs((s and s.allyCreeps) or {}) do
        if ac and U.CanQuery(ac) and ac:IsAlive() and GetUnitToLocationDistance(bot, ac:GetLocation()) <= 720 then
            if (ac:GetHealth() or 999) <= (myAtkPull * 2.2) then
                return false
            end
        end
    end
    if creepsAlreadyOnMe > 0 or pullableMelee == 0 then return false end

    -- Short `115u` / `0.16s` micro-drag toward allied ranged creep / Fountain so SF stays right inside CS reach!
    local fnt = P.GetFountain(bot)
    local bLoc = bot:GetLocation()
    local pullTarget = bLoc + (fnt - bLoc):Normalized() * 115
    for _, ac in pairs((s and s.allyCreeps) or {}) do
        if ac and U.CanQuery(ac) and ac:IsAlive() and ((ac:GetAttackRange() or 100) > 300) then
            local acLoc = ac:GetLocation()
            if U.DistanceBetweenLocations(acLoc, fnt) < U.DistanceBetweenLocations(bLoc, fnt) + 60
                and U.DistanceBetweenLocations(bLoc, acLoc) <= 380 then
                pullTarget = acLoc + (fnt - acLoc):Normalized() * 55
                break
            end
        end
    end

    bot:Action_AttackUnit(enemy, true)
    State.myCreepAggroCdUntil = now + 3.00
    State.myCreepChaseUntil = now + 2.30
    State.lastDefAggroPullAt = now
    State.defAggroPullAnchor = pullTarget
    State.defAggroPullDragUntil = now + 0.16
    State.actionTaken = true
    return true
end

function H.HandleProAggroTrickHarass(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.IsDryVsEnemyRaze(bot, enemy) then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.losingHard or earlyRace.uphillPenalty) then
        return false
    end

    local now = GameTime()
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myRange = math.max(525, bot:GetAttackRange() or 525)
    if myHp < 285 or d > 980 then return false end

    local minCreepDist = 9999
    local creepsHittingMe = 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() then
            local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
            if dc < minCreepDist then minCreepDist = dc end
            if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                creepsHittingMe = creepsHittingMe + 1
            end
        end
    end
    if creepsHittingMe > 0 then return false end

    local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
    local atkReady = (now - (bot:GetLastAttackTime() or -100)) >= (mySpa * 0.90)
    local aggroCdPrimed = (now < (State.myCreepAggroCdUntil or 0) - 0.25) and (now >= (State.myCreepChaseUntil or 0))
    local outRazed = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local myStPA, myRemPA = U.GetShadowrazeDebuff(bot)
    local wAbPA = H.GetRazeAbilityByLabel(bot, "mid")
    local eAbPA = H.GetRazeAbilityByLabel(bot, "far")
    local myMidFarSpentPA = (not (wAbPA and U.IsRazeAbilityCastable(bot, wAbPA)))
        and (not (eAbPA and U.IsRazeAbilityCastable(bot, eAbPA)))
    local midBandDangerous = (U.GetPotentialManaForRaze(enemy) >= 75) and (K.EnemyRazeReadyIn("mid") <= 1.15)
        and (outRazed or ((myStPA or 0) >= 1 and (myRemPA or 0) > 1.20 and myMidFarSpentPA))
    local movingAway = K.IsEnemyMovingAway(bot, enemy)
    local strikeReach = myRange + (movingAway and 20 or 42)

    -- Phase 2: Strike cleanly with ZERO creep aggro when in hull-to-hull range (`aggroCdPrimed` OR `minCreepDist >= 504`)!
    if atkReady and d <= strikeReach and not midBandDangerous and (aggroCdPrimed or minCreepDist >= 504) then
        local prevP, prevA = State.combatPolicyActive, State.heroCombatAllowed
        State.combatPolicyActive, State.heroCombatAllowed = false, true
        local ok = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive, State.heroCombatAllowed = prevP, prevA
        if ok then
            State.lastHarassTime = now
            State.actionTaken = true
            return true
        end
    end

    -- Phase 1: ONLY prime the `3.00s` global aggro cooldown when we are ALREADY actively closing into range (`d <= 635`
    -- and enemy is NOT walking away), preventing out-of-range attack-then-cancel stutters (`00:56–01:03` Fix)!
    if not aggroCdPrimed and now >= (State.myCreepAggroCdUntil or 0)
        and now >= (State.lastAggroPrimeAt or -100) + 4.50
        and not movingAway
        and (U.IsLaneDominant and U.IsLaneDominant(bot, s, earlyRace))
        and minCreepDist >= 506 and minCreepDist <= 680
        and d > strikeReach and d <= 625
        and atkReady and not midBandDangerous then
        bot:Action_AttackUnit(enemy, false)
        State.myCreepAggroCdUntil = now + 3.00
        State.myCreepChaseUntil = 0
        State.lastAggroPrimeAt = now
        State.actionTaken = true
        return true
    end
    return false
end

-- ============================================================================
-- UNIFIED WAR DIRECTOR BRIDGE (`v6.6.0`: Single-Authority, Zero-Jitter Scoped)
-- ============================================================================
function H._PrepareWarDirector(bot, s)
    if not WD.CFG.ENABLED then return nil, nil end
    local enemy = s and s.enemy
    local now = GameTime()
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        if WD.State.last then WD.Reset() end
        return nil, nil
    end
    local eDist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if eDist > WD.CFG.MAX_DIST then
        WD.Reset()
        return nil, nil
    end

    if State._warPreparedAt == now and State._warDec and State._warExec then
        return State._warDec, State._warExec
    end

    local myRaze = bot:GetAbilityByName("nevermore_shadowraze1")
    local hisRaze = enemy:GetAbilityByName("nevermore_shadowraze1")
    local myReady = State._warMyReady or {}
    local hisReady = State._warHisReady or {}
    State._warMyReady, State._warHisReady = myReady, hisReady

    local razeNames = { "nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3" }
    for i = 1, 3 do
        local ab = bot:GetAbilityByName(razeNames[i])
        myReady[i] = now + ((ab and ab:GetCooldownTimeRemaining()) or 999)
    end
    local labels = { "near", "mid", "far" }
    for i = 1, 3 do
        local cd = K.EnemyRazeReadyIn(labels[i]) or 0
        hisReady[i] = now + math.max(0, cd)
    end

    local ownT1Handle = (s and s.allyT1) or P.GetT1Tower(bot)
    if ownT1Handle and U.CanQuery(ownT1Handle) then
        State._warOwnT1Loc = ownT1Handle:GetLocation()
    elseif not State._warOwnT1Loc then
        local t = P.GetT1Tower(bot)
        if t then State._warOwnT1Loc = t:GetLocation() end
    end

    local e = State._warEnv or {}
    State._warEnv = e
    e.now = now
    e.myDamageVsHim = K.AttackDamageVs(bot, enemy)
    e.enemyDamageVsMe = K.AttackDamageVs(enemy, bot)
    e.mySouls = S.GetSouls(bot)
    e.hisSouls = S.GetSouls(enemy)
    e.myRazeLevel = (myRaze and myRaze:GetLevel()) or 0
    e.hisRazeLevel = math.max((hisRaze and hisRaze:GetLevel()) or 0, (U.InferRazeLevel and U.InferRazeLevel(enemy)) or 0)
    local myTal10 = bot:GetAbilityByName("special_bonus_unique_nevermore_7")
    local hisTal10 = enemy:GetAbilityByName("special_bonus_unique_nevermore_7")
    e.myStackTalent = (myTal10 and myTal10:GetLevel() > 0) and 30 or 0
    e.hisStackTalent = (hisTal10 and hisTal10:GetLevel() > 0) and 30 or 0
    local myStW, myRemW = 0, 0
    local hisStW, hisRemW = 0, 0
    if U.GetShadowrazeDebuff then
        myStW, myRemW = U.GetShadowrazeDebuff(bot)
        hisStW, hisRemW = U.GetShadowrazeDebuff(enemy)
    end
    e.myRazeStacksOnMe = myStW or 0
    e.myRazeStacksRem = myRemW or 0
    e.hisRazeStacksOnHim = hisStW or 0
    e.hisRazeStacksRem = hisRemW or 0
    e.myRazeReady = myReady
    e.hisRazeReady = hisReady
    e.myRegen = (bot.GetHealthRegen and bot:GetHealthRegen()) or 1.5
    e.myManaRegen = (bot.GetManaRegen and bot:GetManaRegen()) or 1.0
    e.myStickCharges = U.GetStickCharges(bot) or 0
    e.hisStickCharges = U.GetStickCharges(enemy) or 0
    local myMangoes = U.GetMangoCharges(bot) or 0
    local hisMangoes = U.GetMangoCharges(enemy) or 0
    e.myMango = myMangoes > 0
    e.hisMango = hisMangoes > 0
    e.myMangoCharges = myMangoes
    e.hisMangoCharges = hisMangoes
    if U.GetUnlockingMangoMana then
        e.myUnlockingMangoMana, e.myUnlockEta = U.GetUnlockingMangoMana(bot, 3.0)
        e.hisUnlockingMangoMana, e.hisUnlockEta = U.GetUnlockingMangoMana(enemy, 3.0)
    end
    if U.GetIncomingCourierSupply then
        local myCS = U.GetIncomingCourierSupply(bot)
        e.myCourierMangoMana = myCS.mangoMana or 0
        e.myCourierFaerieHeal = myCS.faerieHeal or 0
        e.myCourierEta = myCS.etaSec or 999
    end
    if U.GetEnemyIncomingCourierSupply then
        local hisCS = U.GetEnemyIncomingCourierSupply(bot, enemy)
        e.hisCourierMangoMana = hisCS.mangoMana or 0
        e.hisCourierFaerieHeal = hisCS.faerieHeal or 0
        e.hisCourierEta = hisCS.etaSec or 999
    end
    e.myMagicResist = (U.GetEffectiveMagicResist and U.GetEffectiveMagicResist(bot)) or 0.25
    e.hisMagicResist = (U.GetEffectiveMagicResist and U.GetEffectiveMagicResist(enemy)) or 0.25
    e.mySpellAmp = (U.GetSpellAmpMult and U.GetSpellAmpMult(bot)) or 1.0
    e.hisSpellAmp = (U.GetSpellAmpMult and U.GetSpellAmpMult(enemy)) or 1.0
    e.myMagicBlock = (U.GetMagicBlockOnFirstRaze and U.GetMagicBlockOnFirstRaze(bot, 200)) or 0
    e.hisMagicBlock = (U.GetMagicBlockOnFirstRaze and U.GetMagicBlockOnFirstRaze(enemy, 200)) or 0
    e.myFaerie = U.GetActiveItemByName(bot, "item_faerie_fire") ~= nil
    e.hisFaerie = U.HasItem and U.HasItem(enemy, "item_faerie_fire") or false
    e.enemyT1Loc = (s.enemyT1Alive and s.enemyT1Loc) or nil
    e.enemyT1Alive = s.enemyT1Alive ~= false
    e.ownT1Loc = State._warOwnT1Loc
    e.enemyT1 = (s.enemyT1Alive ~= false and s.enemyT1) or nil
    e.ownT1 = ownT1Handle
    e.myAggroCdUntil = State.myCreepAggroCdUntil or 0
    local enHidden = (U.GetEnemyHiddenMaxHp and U.GetEnemyHiddenMaxHp(enemy)) or 0
    e.hisTrueMaxHp = (enemy:GetMaxHealth() or 1) + enHidden
    e.hisEffectiveCombatHp = (U.GetEnemyEffectiveCombatHp and U.GetEnemyEffectiveCombatHp(enemy, 2.5)) or (enemy:GetHealth() or 1)
    local rawSafeAnchor = (P.GetRetreatAnchor and P.GetRetreatAnchor(bot, 260, 320))
        or (P.GetBehindT1 and P.GetBehindT1(bot, 260))
        or State._warOwnT1Loc
    e.safeAnchorLoc = rawSafeAnchor and H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawSafeAnchor, 440) or nil

    if not State._warCalibrated and e.enemyT1 then
        State._warCalibrated = true
        pcall(ET.CalibrateConstants, C, bot, { e.enemyT1 })
    end

    local towerShot = ET.FALLBACK.TOWER_APPLIED_DMG
    local towerLockedOnMe = false
    if e.enemyT1 then
        towerShot = ET.AppliedTowerDamage(e.enemyT1, bot)
        local tf = ET.TowerFacts(bot, e.enemyT1, 2, 1, C.TOWER and C.TOWER.HERO_AGGRO_RANGE)
        towerLockedOnMe = (tf and tf.targeting_me) or false
    end
    e.projectileDamage = function(p)
        if p and p.caster and p.caster.IsTower then
            local okTw, isTw = pcall(p.caster.IsTower, p.caster)
            if okTw and isTw then return towerShot end
        end
        if towerLockedOnMe then return math.max(towerShot, e.enemyDamageVsMe or 0) end
        return e.enemyDamageVsMe or 0
    end

    local phLabel, _phEl, phRemain = K.EnemyPhase()
    if phLabel then
        e.hisCastLeft = math.max(0, phRemain or 0)
        e.hisCastBand = nil
        for i = 1, 3 do
            if K.LABELS[i] == phLabel then e.hisCastBand = i; break end
        end
        local okC, centre = pcall(K.EnemyRazeCenter, enemy, phLabel)
        e.hisCastCentre = (okC and centre) or nil
    else
        e.hisCastLeft = nil
        e.hisCastBand = nil
        e.hisCastCentre = nil
    end

    local st = WD.BuildState(bot, s, e)
    local dec = WD.Decide(st, now)
    if not dec then return nil, nil end

    local exec = {
        state = st,
        now = now,
        imminentCS = false,
        moveTo = function(loc, urgentDodge)
            if not loc then return false end
            local bz = (bot:GetLocation() and bot:GetLocation().z) or 128
            local safe = H.GetSafeApproach(bot, Vector(loc.x, loc.y, bz), s.enemyTowers, s.allyCreeps)
            return H.SmartMove(bot, safe, urgentDodge and 20 or 60, urgentDodge == true)
        end,
        approach = function(enemyHero)
            local loc = H.GetSafeApproach(bot, enemyHero:GetLocation(), s.enemyTowers, s.allyCreeps)
            return H.ApproachEnemyPoint(bot, enemyHero, loc, 60, s.enemyTowers, s.allyCreeps)
        end,
        attackHero = function()
            return H.IssueHeroAttack(bot, enemy)
        end,
        canSnapRaze = function(_bot, idx, target)
            local nm = razeNames[idx]
            local ab = nm and bot:GetAbilityByName(nm) or nil
            if not ab or ab:GetLevel() <= 0 or not ab:IsCooldownReady() then return false end
            if bot:GetMana() < 75 then return false end
            local actionType = H.GetRazeActionType(bot, ab, target)
            return actionType == "CAST"
        end,
        castRaze = function(_bot, idx, _aimLoc, target)
            local nm = razeNames[idx]
            local ab = nm and bot:GetAbilityByName(nm) or nil
            if not ab or ab:GetLevel() <= 0 or not ab:IsCooldownReady() then return false end
            if bot:GetMana() < 75 then
                if (U.GetMangoCharges(bot) or 0) > 0 then
                    local mg = U.GetActiveItemByName(bot, "item_enchanted_mango")
                    if mg and mg:IsFullyCastable() then
                        bot:Action_UseAbility(mg)
                        State.actionTaken = true
                        return true
                    end
                end
                return false
            end
            local actionType, aim = H.GetRazeActionType(bot, ab, target)
            if not actionType then return false end
            return H.CastOrTurnRaze(bot, ab, actionType, aim, target)
        end,
    }
    State._warPreparedAt = now
    State._warDec = dec
    State._warExec = exec
    return dec, exec
end

function H.WarDirectorPreCS(bot, s)
    local okRun, res = pcall(function()
        local dec, exec = H._PrepareWarDirector(bot, s)
        if not dec or not exec then return false end
        return WD.ExecuteKillOrCastLockOnly(bot, s, dec, exec)
    end)
    return okRun and res == true
end

function H.WarDirectorPostCS(bot, s, imminentCreepCS)
    local okRun, res = pcall(function()
        local dec, exec = H._PrepareWarDirector(bot, s)
        if not dec or not exec then return false end
        exec.imminentCS = imminentCreepCS and true or false
        return WD.ExecuteTactical(bot, s, dec, exec)
    end)
    return okRun and res == true
end

-- `auto-20261031-0230` `01:32.3-01:35.0` (`tk=6900..6980`) `102 HP / 4 MP` Enemy Escape Fix:
-- When the enemy hero is critically low (`<= 160 HP` or `<= 1 Raze + 45`) and retreating past `960u` (`WarDirector` hunt edge)
-- while we are healthy (`>= 380 HP`), `#enemyCreeps <= 1`, and NO CS is imminent, press smoothly up to the safe enemy T1
-- boundary (`>= 915u`, or `>= 660u` if `>= 2` allied creeps actively shield T1) instead of snapping NE back to `(-33,-26)`!
function H.HandlePressCriticallyLowEnemy(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.TowerBurnActive() or (GameTime() < (State.noReenterEnemyT1Until or 0)) then return false end
    local myHp = bot:GetHealth() or 0
    local myEffHp = myHp
        + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(bot)) or 0)
        + ((U.GetStickCharges and U.GetStickCharges(bot)) or 0) * 15
    local enRawHp = enemy:GetHealth() or 9999
    local enHp = enRawHp + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy)) or 0)
    local enPoolNow = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local enDryZeroCoil = enPoolNow < 75
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    -- `9070869385.dem` `01:10.2` (`339 HP + Faerie = 424 EHP` vs `89 HP / 32 MP`), `02:01.4` (`154 HP` vs `82 HP / 61 MP`),
    -- and `04:04.2–04:06.2` (`75 -> 13 HP` execution) Fix:
    -- Never let a rigid `360 HP` floor or a non-1-hit creep block finishing a 1-2 hit / zero-coil enemy!
    local ultraCriticalTarget = (enHp <= math.max(115, myAtk * 1.85))
    if imminentCreepCS and not ultraCriticalTarget then return false end
    local minReqEffHp = (enDryZeroCoil and enHp <= 185) and math.max(145, enAtk * 2.55) or 340
    if enDryZeroCoil and (bot:GetMana() or 0) >= 75 and enRawHp <= 265 then
        minReqEffHp = math.min(minReqEffHp, 260)
    end
    if myEffHp < minReqEffHp then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or (earlyRace.heCanKillSoon and not ultraCriticalTarget)) then return false end
    local oneRazeDmg = U.GetNRazeDamage(bot, enemy, 1)
    local maxPressHp = math.max(160, oneRazeDmg + 45, myAtk * 2.15)
    if enDryZeroCoil and (bot:GetMana() or 0) >= 75 and enRawHp <= 265 then
        maxPressHp = math.max(maxPressHp, oneRazeDmg + myAtk * 2.35 + 65, 360)
    elseif enDryZeroCoil and enHp <= 185 then
        maxPressHp = math.max(maxPressHp, 185)
    end
    if enHp > maxPressHp then return false end

    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local maxChaseDist = (enRawHp <= 95 and myHp >= 450) and 1360 or 1220
    if d > maxChaseDist then return false end

    -- 1. `v7.9.11` (`2204 @ 03:05` Fix): Ready in-band Shadowraze fires BEFORE any `#enemyCreeps` foot-chase gate!
    -- Spells do NOT draw `500u` lane-creep right-click aggro in Dota 2, so `#enemyCreeps == 3` must NEVER block
    -- blasting an OOM/crippled enemy SF (`188..207 HP, 65 MP`) standing inside `W(450)` / `E(700)`!
    if (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    if #(s.enemyCreeps or {}) > (enDryZeroCoil and enHp <= 155 and 3 or 1) then return false end

    -- 2. If in right-click reach and safe from enemy T1, finish with right-click!
    local atkReach = (bot:GetAttackRange() or 525) + 25
    if d <= atkReach and H.IsSafeToAttack(bot, eLoc, s.enemyTowers, s.allyCreeps) then
        bot:Action_AttackUnit(enemy, true)
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end

    -- 3. Smoothly press toward `eLoc` clamped strictly outside enemy T1 (`>= 915u` unshielded, `>= 660u` with `>= 2` shield creeps)
    -- `v7.9.1` + `v7.9.9-pro` (`1814 @ 08:42.40..08:45.07` `2.67s` Tower-Clamp Deadlock Fix!):
    --   * Previously only aborted unreachable T1-clamped targets when `myManaPress < 75`! At `08:44`, Bot had `218 MP`,
    --     `W` (`2.6s` CD) & `E` (`5.8s` CD) on cooldown, and only `Q(200)` ready while Human stood at `403u` from Dire T1
    --     (`d = 571u`), parking SF motionless at `(-123.5, 5.5)` (`915u` clamp) taking 3 free right-clicks (`539 -> 276 HP`)!
    --   * Now verifies whether `pressTarget` can ACTUALLY hit `eLoc` with a safe right-click OR a ready in-band Shadowraze;
    --     if not, steps back outside enemy's `573u` attack reach when pressured, or returns `false` cleanly!
    local myManaPress = bot:GetMana() or 0
    if myManaPress < 75 and not H.CanKinematicallyCatchForAttack(bot, enemy, s.enemyTowers, s.allyCreeps, 1.80) then
        return false
    end
    local pressTarget = eLoc
    if s.enemyT1Alive ~= false and s.enemyT1Loc then
        local tLoc = s.enemyT1Loc
        local shield = (s.enemyT1 and U.CanQuery(s.enemyT1))
            and LN.TowerShieldCountLoc(tLoc, s.enemyT1, s.allyCreeps, pressTarget) or 0
        local minT1Dist = (shield >= 2 and myHp >= 480) and 660 or 915
        if U.DistanceBetweenLocations(pressTarget, tLoc) < minT1Dist then
            local awayT1 = (bLoc - tLoc)
            if awayT1:Length2D() < 1 then awayT1 = (P.GetFountain(bot) - tLoc) end
            pressTarget = tLoc + awayT1:Normalized() * minT1Dist
            if shield < 2 then
                local dPressToEn = U.DistanceBetweenLocations(pressTarget, eLoc)
                local canAutoFromPress = (dPressToEn <= ((bot:GetAttackRange() or 525) + 30))
                    and H.IsSafeToAttack(bot, eLoc, s.enemyTowers, s.allyCreeps)
                local qAbP = H.GetRazeAbilityByLabel(bot, "near")
                local wAbP = H.GetRazeAbilityByLabel(bot, "mid")
                local eAbP = H.GetRazeAbilityByLabel(bot, "far")
                local canRazeFromPress = (myManaPress >= 75) and (not bot:IsSilenced()) and (
                    (eAbP and (eAbP:GetCooldownTimeRemaining() or 99) <= 0.45 and eAbP:GetLevel() > 0 and dPressToEn >= 430 and dPressToEn <= 955)
                    or (wAbP and (wAbP:GetCooldownTimeRemaining() or 99) <= 0.45 and wAbP:GetLevel() > 0 and dPressToEn >= 200 and dPressToEn <= 705)
                    or (qAbP and (qAbP:GetCooldownTimeRemaining() or 99) <= 0.45 and qAbP:GetLevel() > 0 and dPressToEn <= 455)
                )
                if not canAutoFromPress and not canRazeFromPress then
                    if H.IsEnemyPressuring(bot, enemy) or d <= 615 then
                        local fntP = P.GetFountain(bot)
                        local resetPt = eLoc + (fntP - eLoc):Normalized() * 675
                        if U.DistanceBetweenLocations(resetPt, tLoc) < 980 then
                            resetPt = tLoc + (fntP - tLoc):Normalized() * 995
                        end
                        H.SmartMove(bot, resetPt, 30, true)
                        State.actionTaken = true
                        return true
                    end
                    return false
                end
            end
        end
    end
    if U.DistanceBetweenLocations(bLoc, pressTarget) > 38 then
        H.SmartMove(bot, pressTarget, 30)
        State.actionTaken = true
        return true
    end
    return false
end

-- First-Principles 30Hz Closed-Loop PD + Duty-Cycle Braking Creep-Block Engine (`v7.9.9-pro`):
--   1. Exact Hull Kinematics (`R_hero 24u + R_creep 16u = 40.0u` contact): tracks per-creep live velocity (`vFwd, vLat`)
--      across ticks so the instant Source 2 local avoidance nudges a creep sideways (`±120..185 u/s`) around SF's hull,
--      PD lateral lead (`latErr = creepLat + vLat * 0.10`) cuts across the creep's shoulder on the very first frame!
--   2. True S-Stop Braking Duty Cycle (`Action_ClearActions(true)` at `0°` down-lane yaw):
--      In Source 2, moving a destination from `+80u` to `+58u` STILL moves SF at `100%` MS (`305` base / `350` Boots, which
--      outruns `325 MS` creeps completely!). Our 4-regime closed-loop controller holds/brakes when centered at `fwdLead >= 51u`
--      (`0°` turn!), releases with crisp `36..44u` forward-angled steps on `40u` hull contact (`never turning > 60°`!), and
--      regulates effective wave speed to `~165..205 u/s` whether SF has `305 MS` or `350 MS` Power Treads!
--   3. Strict Slipped-Creep Wave Abort Law: if ANY creep in the wave slips past SF (`fwd < -16u`), immediately aborts
--      blocking trailing creeps (`abortedWaveBlockUntil`) so waves are NEVER split!
--   4. True `190u` Tower-Hull Clearance (`> 144u tower + 24u hero = 168u`!): prevents T2/T1 hull snagging (`1814 @ +7.33s`)!
function H.ExecuteDynamicCreepBlockStep(bot, corridorCreeps, myT1, myT2, enT1, desiredWaveSpeed)
    local now = GameTime()
    local bLoc = bot:GetLocation()
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local dtimeBlock = (type(DotaTime) == "function") and DotaTime() or 0
    local isMidGameWave = (dtimeBlock >= 20.0)
    local canOvertakeFromBehind = (myMS >= 338)
    local minCatchableFwd = canOvertakeFromBehind and (isMidGameWave and -135.0 or -110.0) or -18.0

    State.creepBlockTrack = State.creepBlockTrack or {}
    local trackTbl = State.creepBlockTrack

    local candidates = {}
    local minRawDEn = math.huge
    local minFwdAll = math.huge
    local maxFwdAll = -math.huge

    for _, ac in ipairs(corridorCreeps) do
        local cLoc = ac:GetLocation()
        local dEn = U.DistanceBetweenLocations(cLoc, enT1)
        if dEn < minRawDEn then minRawDEn = dEn end
        local mDir = (enT1 - cLoc):Normalized()
        local rx, ry = bLoc.x - cLoc.x, bLoc.y - cLoc.y
        local fwd = rx * mDir.x + ry * mDir.y
        local lx, ly = -mDir.y, mDir.x
        local creepLat = (-rx) * lx + (-ry) * ly

        local vx, vy = 0.0, 0.0
        local cv = (ac.GetVelocity and ac:GetVelocity()) or nil
        if cv and (math.abs(cv.x or 0) + math.abs(cv.y or 0)) > 5.0 then
            vx, vy = cv.x or 0, cv.y or 0
        else
            local tr = trackTbl[ac]
            if tr and (now - tr.t) >= 0.015 and (now - tr.t) <= 0.45 then
                local invDt = 1.0 / (now - tr.t)
                local rawVx, rawVy = (cLoc.x - tr.x) * invDt, (cLoc.y - tr.y) * invDt
                vx = (tr.vx or rawVx) * 0.35 + rawVx * 0.65
                vy = (tr.vy or rawVy) * 0.35 + rawVy * 0.65
            end
        end
        trackTbl[ac] = { x = cLoc.x, y = cLoc.y, t = now, vx = vx, vy = vy }

        local vFwd = vx * mDir.x + vy * mDir.y
        local vLat = vx * lx + vy * ly
        local isRanged = ((ac.GetAttackRange and ac:GetAttackRange()) or 100) > 300

        if fwd < minFwdAll then minFwdAll = fwd end
        if fwd > maxFwdAll then maxFwdAll = fwd end

        candidates[#candidates + 1] = {
            creep = ac, loc = cLoc, dEn = dEn,
            mDir = mDir, fwd = fwd, creepLat = creepLat,
            vFwd = vFwd, vLat = vLat, lx = lx, ly = ly, isRanged = isRanged,
        }
    end
    if #candidates == 0 then
        return false
    end

    local waveWasLatched = (now < (State.creepBlockWaveLatched or 0))
    local abortSlipFloor = isMidGameWave and -32.0 or -16.0
    if minFwdAll < abortSlipFloor then
        local splitPackAbort = (not isMidGameWave or not canOvertakeFromBehind)
            and (maxFwdAll > 28.0 and minFwdAll < -34.0)
        if waveWasLatched or (not canOvertakeFromBehind and minFwdAll < -36.0) or (minFwdAll < minCatchableFwd - 6.0) or splitPackAbort then
            State.abortedWaveBlockUntil = now + (isMidGameWave and 3.0 or 9.5)
            State.creepBlockWaveLatched = 0
            return false
        end
    end
    if minFwdAll >= 16.0 and minFwdAll <= 220.0 then
        State.creepBlockWaveLatched = now + 1.35
    end

    -- Strict Min-Fwd Priority + Ranged-Flank Guard + 7.5u Target Hysteresis (`State.creepBlockLeadEnt`):
    --   1. If the ranged creep surges within `10u` of `minFwdAll` on an open flank (`|creepLat| >= 40u`, `2135 @ 0:12.20`),
    --      seal the ranged creep first so it never walks to the front of the wave and dies first!
    --   2. Otherwise keep `7.5u` target hysteresis to eliminate 30Hz left-right sawtooth jitter!
    for _, e in ipairs(candidates) do
        local rangedFlankUrgency = (e.isRanged and (e.fwd - minFwdAll) <= 10.0 and math.abs(e.creepLat) >= 40.0) and 9.5 or 0.0
        -- `v7.9.20` (`1610.dem` `W7` @ `03:52.27` Tower-Split Wide-Flanker Kinematic Filter):
        -- When `|creepLat| > max(58u, fwd * 0.78 + 26u)`, `305 MS` SF CANNOT cross `creepLat` before `325 MS` creep passes `fwd = 0`!
        -- Deprioritize kinematically uncatchable tower-split flankers so SF stays locked on the main column instead of spinning sideways!
        local uncatchableWidePen = (e.fwd > 0 and math.abs(e.creepLat) > math.max(58.0, e.fwd * 0.78 + 26.0)) and 185.0 or 0.0
        e.rankScore = e.fwd - rangedFlankUrgency + uncatchableWidePen
    end
    table.sort(candidates, function(a, b) return a.rankScore < b.rankScore end)
    local lead = candidates[1]
    if State.creepBlockLeadEnt then
        for _, e in ipairs(candidates) do
            if e.creep == State.creepBlockLeadEnt and (e.rankScore - candidates[1].rankScore) <= 7.5 then
                lead = e
                break
            end
        end
    end
    State.creepBlockLeadEnt = lead.creep

    local cLoc = lead.loc
    local marchDir = lead.mDir
    local fwdLead = lead.fwd
    local latX, latY = lead.lx, lead.ly

    -- Compute front-pack lateral centroid so SF can HERD drifting flankers INWARD (anti-snowplow physics!):
    --   1. Aim `3.5..11u` OUTSIDE `lead` (`same sign as driftFromPack`) when `fwdLead >= 44u` so once reached,
    --      `lead.creepLat` flips sign (`inward of hero`) and every bump herds `lead` BACK toward `packCenterLat`!
    --   2. Inward-Normal S-Stop Law: NEVER S-stop when `lead.creepLat` has the SAME sign as `driftFromPack` (which wedges
    --      `lead` further outward in an infinite escalator!). S-stop ONLY when dead-center (`|lead.creepLat| <= 4.5..5.5u`)
    --      OR already on the OUTSIDE shoulder (`lead.creepLat * driftFromPack < -5.5 and |lead.creepLat| <= 15.0`)!
    local sumLat, cntPack = 0.0, 0
    for _, e in ipairs(candidates) do
        if (e.fwd - minFwdAll) <= 95.0 then
            sumLat = sumLat + e.creepLat
            cntPack = cntPack + 1
        end
    end
    local packCenterLat = (cntPack > 0) and (sumLat / cntPack) or lead.creepLat
    local driftFromPack = lead.creepLat - packCenterLat

    local herdOutside = 0.0
    if fwdLead >= 44.0 and fwdLead <= 76.0 and math.abs(driftFromPack) >= 3.0 then
        herdOutside = (driftFromPack > 0 and 1.0 or -1.0) * math.min(11.0, 3.5 + math.abs(driftFromPack) * 0.42)
    end

    local latLead = math.max(-14.0, math.min(14.0, lead.vLat * 0.06))
    local latErr = lead.creepLat + latLead + herdOutside

    local targetSpd = desiredWaveSpeed or 215.0
    local maxBlock = (targetSpd <= 268.0)
    local deadCenterTol = (myMS >= 332) and 5.5 or 4.5
    local inwardOrDeadCenter = (math.abs(lead.creepLat) <= deadCenterTol)
        or ((lead.creepLat * driftFromPack) < -5.5 and math.abs(lead.creepLat) <= 15.0)
    local consecStops = State.creepBlockConsecStops or 0
    local canPulseStop = inwardOrDeadCenter and (consecStops == 0)
    local brakeFwd = maxBlock and ((myMS >= 332) and 44.0 or 54.0) or ((myMS >= 332) and 54.0 or 64.0)

    local passingTower = false
    for _, twLoc in ipairs({ myT2, myT1 }) do
        if twLoc then
            local dTwBot = U.DistanceBetweenLocations(bLoc, twLoc)
            if dTwBot <= 245.0 then
                passingTower = true
                break
            end
        end
    end

    local blockPt = nil
    local shouldHoldStop = false

    if minFwdAll < 16.0 then
        local sideClear = 0.0
        if fwdLead < 8.0 and math.abs(lead.creepLat) < 34.0 then
            sideClear = (lead.creepLat >= 0) and -42.0 or 42.0
        end
        blockPt = Vector(
            cLoc.x + marchDir.x * 92.0 + latX * sideClear,
            cLoc.y + marchDir.y * 92.0 + latY * sideClear,
            cLoc.z or 128
        )
    elseif fwdLead > 260.0 then
        -- REGIME A (`fwdLead > 260u`): Turn-angle-aware staging (`92u` when already aligned down-lane, scaling up to `225u`
        -- when walking `180°` up-lane to intercept an incoming mid-game wave with `0` turn-slips!).
        local downPtA = Vector(bLoc.x + marchDir.x * 160.0, bLoc.y + marchDir.y * 160.0, bLoc.z or 128)
        local turnAngA = U.GetAngleDifference(bot, downPtA)
        local aheadA = (turnAngA > 45.0) and math.min(225.0, 92.0 + (turnAngA - 45.0) * 1.0) or 92.0
        blockPt = Vector(
            cLoc.x + marchDir.x * aheadA,
            cLoc.y + marchDir.y * aheadA,
            cLoc.z or 128
        )
    elseif fwdLead > 76.0 then
        -- REGIME B (`76u < fwdLead <= 260u`, `v7.9.20` Monotonic Down-Lane Pre-Contact Alignment — `1610.dem` `W7` `yaw=77°` Fix!):
        -- Guarantee `fwdAlign >= max(48u, |latStepB|*1.05)` so pre-contact lateral alignment NEVER points `68..136°` sideways/uphill!
        local latErrB = lead.creepLat + latLead * 0.75
        if math.abs(latErrB) > 7.5 then
            local latStepB = math.max(-38.0, math.min(38.0, latErrB * 0.72))
            local fwdAlign = math.max(48.0, math.abs(latStepB) * 1.05)
            blockPt = Vector(
                bLoc.x + marchDir.x * fwdAlign + latX * latStepB,
                bLoc.y + marchDir.y * fwdAlign + latY * latStepB,
                bLoc.z or 128
            )
        else
            local downPt = Vector(bLoc.x + marchDir.x * 120.0, bLoc.y + marchDir.y * 120.0, bLoc.z or 128)
            if U.GetAngleDifference(bot, downPt) > 15.0 then
                blockPt = Vector(bLoc.x + marchDir.x * 36.0, bLoc.y + marchDir.y * 36.0, bLoc.z or 128)
            else
                shouldHoldStop = true
            end
        end
    elseif passingTower and myMS < 332 then
        local latTower = math.max(-24.0, math.min(24.0, latErr * 0.70))
        blockPt = Vector(
            bLoc.x + marchDir.x * 64.0 + latX * latTower,
            bLoc.y + marchDir.y * 64.0 + latY * latTower,
            bLoc.z or 128
        )
    elseif fwdLead >= 42.0 then
        -- REGIME C (`42u <= fwdLead <= 76u`): Full Outside-Shoulder Contact Herding + Pulsed 1-Tick Inward-Normal S-Stop!
        if fwdLead >= brakeFwd and canPulseStop then
            shouldHoldStop = true
        elseif math.abs(latErr) > 5.0 then
            local maxTan = (myMS >= 332) and 0.92 or ((fwdLead >= 54.0) and 0.68 or 0.50)
            local latStep = math.max(-48.0, math.min(48.0, latErr * 1.20))
            local fwdStep = math.max((myMS >= 332) and 20.0 or 28.0, math.abs(latStep) / maxTan)
            blockPt = Vector(
                bLoc.x + marchDir.x * fwdStep + latX * latStep,
                bLoc.y + marchDir.y * fwdStep + latY * latStep,
                bLoc.z or 128
            )
        else
            local relStep = (myMS >= 332) and 15.0 or 36.0
            blockPt = Vector(
                bLoc.x + marchDir.x * relStep + latX * latErr,
                bLoc.y + marchDir.y * relStep + latY * latErr,
                bLoc.z or 128
            )
        end
    else
        -- REGIME D (`16u <= fwdLead < 42u`): Tight Hull Recovery — pull `fwdLead -> 46..54u`!
        local maxTanTight = (myMS >= 332) and 0.65 or 0.42
        local latStep = math.max(-36.0, math.min(36.0, latErr * 1.10))
        local fwdStep = math.max((myMS >= 332) and 32.0 or 56.0, math.abs(latStep) / maxTanTight)
        blockPt = Vector(
            bLoc.x + marchDir.x * fwdStep + latX * latStep,
            bLoc.y + marchDir.y * fwdStep + latY * latStep,
            bLoc.z or 128
        )
    end

    if fwdLead <= 260.0 then
        State.activeCreepBlockAt = now
    end

    if shouldHoldStop then
        local nearTowerHull = false
        for _, twLoc in ipairs({ myT2, myT1 }) do
            if twLoc and U.DistanceBetweenLocations(bLoc, twLoc) < 188.0 then
                nearTowerHull = true
                blockPt = Vector(bLoc.x + marchDir.x * 42.0, bLoc.y + marchDir.y * 42.0, bLoc.z or 128)
                break
            end
        end
        if not nearTowerHull then
            State.creepBlockConsecStops = consecStops + 1
            if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_NONE then
                bot:Action_ClearActions(true)
            end
            State.actionTaken = true
            return true
        end
    end
    State.creepBlockConsecStops = 0

    for _, twLoc in ipairs({ myT2, myT1 }) do
        if twLoc then
            local dx, dy = blockPt.x - twLoc.x, blockPt.y - twLoc.y
            local dTw = math.sqrt(dx * dx + dy * dy)
            if dTw < 188.0 then
                if fwdLead > 185.0 then
                    local cx, cy = cLoc.x - twLoc.x, cLoc.y - twLoc.y
                    local cLen = math.max(1.0, math.sqrt(cx * cx + cy * cy))
                    local ux, uy = cx / cLen, cy / cLen
                    if dTw > 10.0 and ((dx * ux + dy * uy) > 0) then
                        ux, uy = dx / dTw, dy / dTw
                    end
                    blockPt = Vector(twLoc.x + ux * 190.0, twLoc.y + uy * 190.0, blockPt.z or 128)
                else
                    local tx, ty = -marchDir.y, marchDir.x
                    local cSide = (cLoc.x - twLoc.x) * tx + (cLoc.y - twLoc.y) * ty
                    if math.abs(cSide) < 8.0 then
                        cSide = (bLoc.x - twLoc.x) * tx + (bLoc.y - twLoc.y) * ty
                    end
                    local sideSign = (cSide >= 0) and 1.0 or -1.0
                    local rLen = math.max(1.0, dTw)
                    local rx, ry = dx / rLen, dy / rLen
                    if dTw <= 10.0 then
                        rx, ry = tx * sideSign, ty * sideSign
                    end
                    local gx = rx * 0.55 + (marchDir.x * 0.62 + tx * sideSign * 0.78) * 0.65
                    local gy = ry * 0.55 + (marchDir.y * 0.62 + ty * sideSign * 0.78) * 0.65
                    local gLen = math.max(1e-4, math.sqrt(gx * gx + gy * gy))
                    blockPt = Vector(twLoc.x + (gx / gLen) * 192.0, twLoc.y + (gy / gLen) * 192.0, blockPt.z or 128)
                end
            end
        end
    end

    -- `v7.9.20` Hard Monotonic Down-Lane Heading Invariant (`1610.dem` `W7` `03:52.27` `yaw=77.3°` Tower-Skirt Uphill Spin Fix!):
    -- Once within `fwdLead <= 260u` of our creep pack, `blockPt - bLoc` MUST ALWAYS project `>= max(34u, |projLat| * 0.92)`
    -- down-lane along `marchDir` (`<= 47 deg` off lane axis — ZERO sideways or `180 deg` uphill reversals around towers!).
    if fwdLead <= 260.0 then
        local relBx, relBy = blockPt.x - bLoc.x, blockPt.y - bLoc.y
        local projFwd = relBx * marchDir.x + relBy * marchDir.y
        local projLat = relBx * latX + relBy * latY
        local minFwdMove = math.max(34.0, math.abs(projLat) * 0.92)
        if projFwd < minFwdMove then
            blockPt = Vector(
                bLoc.x + marchDir.x * minFwdMove + latX * projLat,
                bLoc.y + marchDir.y * minFwdMove + latY * projLat,
                blockPt.z or 128
            )
        end
    end

    if bot.Action_MoveDirectly then
        bot:Action_MoveDirectly(blockPt)
    else
        bot:Action_MoveToLocation(blockPt)
    end
    State.lastMoveLoc = blockPt
    State.lastMoveTime = now
    State.actionTaken = true
    return true
end

-- Collect all alive mid-corridor lane creeps for `unitListConst` (`UNIT_LIST_ALLIED_CREEPS` or `UNIT_LIST_ENEMY_CREEPS`).
function H.CollectMidCorridorCreeps(fnt, enT1, unitListConst, fallbackList)
    local out = {}
    local seen = {}
    local laneAxis = (enT1 - fnt):Normalized()
    local function consider(c)
        if not (c and not seen[c] and U.CanQuery(c) and c:IsAlive()) then return end
        seen[c] = true
        local nm = (c.GetUnitName and c:GetUnitName()) or ""
        if nm ~= "" and not (string.find(nm, "creep", 1, true) or string.find(nm, "siege", 1, true)) then return end
        if string.find(nm, "neutral", 1, true) then return end
        local cLoc = c:GetLocation()
        local relF = cLoc - fnt
        local proj = relF.x * laneAxis.x + relF.y * laneAxis.y
        local perpX = relF.x - laneAxis.x * proj
        local perpY = relF.y - laneAxis.y * proj
        if (perpX * perpX + perpY * perpY) > (960 * 960) then return end
        out[#out + 1] = c
    end
    if type(GetUnitList) == "function" and unitListConst then
        local okL, list = pcall(GetUnitList, unitListConst)
        if okL and list then
            for _, c in pairs(list) do consider(c) end
        end
    end
    for _, c in pairs(fallbackList or {}) do
        consider(c)
    end
    return out
end

-- `v7.9.2` Closed-Loop T3-to-Staircase Opening Creep Block (`9072025270.dem` + Ward #2 Telemetry Solver!):
--   1. Immediately after pre-horn wards finish (`dtime >= -52s`), navigates safely around Enemy T1 (`R >= 1,040u`!) straight
--      back to `RADIANT_T3_BLOCK` / `DIRE_T3_BLOCK`, arriving `~14s` early and pre-aligning `0°` toward `myT2 -> myT1`!
--   2. Holds `T3_BLOCK` while Wave #1 sits frozen at spawn (`dtime < -3.35s`), intercepting all 4 creeps right at T3!
--   3. Reads live Enemy Wave #1 progress via Ward #2 (between Enemy T1 & T2) to modulate block speed (`240 .. 325 u/s`)
--      and release at the exact tick that lands the wave clash right on our highground staircase (`STAIRCASE_RADIANT/DIRE`)!
function H.HandleOpeningCreepBlock(bot, s)
    local dtime = (type(DotaTime) == "function") and DotaTime() or 99
    -- `v7.9.20` (`1610.dem` `00:19.53..00:20.00` `holdSpot (915, 653)` Uphill Dead-Zone Fix!):
    -- Extend `HandleOpeningCreepBlock` to `22.5s` so Wave #1 blocks seamlessly onto `myWave1Meet` with ZERO `0.5s` gap!
    if dtime < -52.0 or dtime > 22.5 then return false end
    -- `v7.9.7-pro` (`0307` Fast-Start / Skip-PreGame Fix): if the lobby host skips strategy time (`dtime` jumps straight
    -- to `0:00` while Ward #2 is still unfinished), abort Ward #2 immediately so Wave #1 block takes full priority!
    if dtime >= 0 and not State.preHornEnemyLaneWardDone then
        State.preHornWard2Aborted = true
    end
    -- Yield ONLY while pre-horn ward phases are still active (so an aborted 2nd ward in backpack NEVER skips the T3 block!)
    local wardCharges = H.CountInventoryObserverWardCharges(bot)
    if dtime < 0 and wardCharges > 0 then
        if (not State.preHornRiverWardDone and dtime < -16.0)
            or (State.preHornRiverWardDone and not State.preHornEnemyLaneWardDone and not State.preHornWard2Aborted and dtime < -31.0) then
            return false
        end
    end
    local isRad, myT1, myT2, _, enT1, _ = H.GetMidTowerGeometry(bot)
    local fnt = P.GetFountain(bot)
    local bLoc = bot:GetLocation()
    local myT3Block = isRad and C.POSITIONS.RADIANT_T3_BLOCK or C.POSITIONS.DIRE_T3_BLOCK
    local myStaircase = isRad and C.POSITIONS.RADIANT_STAIRCASE or C.POSITIONS.DIRE_STAIRCASE

    -- 1. ALWAYS finish retracing `State.ward2Breadcrumbs` back to our river anchor FIRST (both `< -3.35s` and if slightly delayed!),
    --    so SF NEVER cuts into Radiant/Dire forest or stops at `0:00.67` near Enemy T1 to swing a pointless attack!
    if State.ward2Breadcrumbs and #State.ward2Breadcrumbs > 0 then
        if H.FollowWard2ReturnBreadcrumbs(bot) then
            return true
        end
    end

    if dtime >= 0 and s and s.enemy and U.CanQuery(s.enemy) and (s.enemyDist or 9999) <= 760
        and U.DistanceBetweenLocations(bLoc, myT1) <= U.DistanceBetweenLocations(bLoc, enT1) then
        return false
    end

    -- Abort immediately if enemy creeps have already crossed onto our staircase/river within `860u` of `bot`
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(bLoc, ec:GetLocation()) <= 860
            and U.DistanceBetweenLocations(bLoc, myT1) <= U.DistanceBetweenLocations(bLoc, enT1) then
            return false
        end
    end

    -- Pre-Wave Staging (`dtime < -3.35s`): return safely around Enemy T1 -> `myT3Block` and pre-rotate `0°` toward `myT2`!
    -- Includes a self-healing prop-stall detector so even if any map prop sits near `myT3Block`, SF NEVER gets stuck facing `225°`!
    local function stageAndFaceDownLane(anchorPt)
        local dStage = U.DistanceBetweenLocations(bLoc, anchorPt)
        local nowStage = GameTime()
        if State.stagePrevLoc and (nowStage - (State.stagePrevAt or 0)) >= 0.35 then
            if U.DistanceBetweenLocations(bLoc, State.stagePrevLoc) < 5.0 and dStage <= 185.0 then
                State.stagePropSettledAt = nowStage + 2.5
            end
            State.stagePrevLoc = bLoc
            State.stagePrevAt = nowStage
        elseif not State.stagePrevLoc then
            State.stagePrevLoc = bLoc
            State.stagePrevAt = nowStage
        end
        if dStage <= 36.0 then
            State.stageArrivedAnchor = true
        elseif dStage > 96.0 then
            State.stageArrivedAnchor = false
        end
        local settledAtAnchor = State.stageArrivedAnchor or (dStage <= 185.0 and nowStage < (State.stagePropSettledAt or 0))
        if not settledAtAnchor then
            if U.DistanceBetweenLocations(bLoc, enT1) < 1550 then
                H.SafeArcMoveAroundEnemyTowers(bot, anchorPt)
            else
                H.SmartMove(bot, anchorPt, 24, true)
            end
        else
            -- `v7.9.19` (`9074666246.dem` `-00:14..-00:03` `40`-Flip T3 Staging Spin Fix!):
            -- Previously `alignPt = bLoc + dir * 16.0` walked SF incrementally past `dStage > 58`, toggling
            -- `stageArrivedAnchor = false -> walk back NE -> stageArrivedAnchor = true -> walk SW` 40 times!
            -- Anchoring `alignPt` to `anchorPt + (enT1 - anchorPt):Normalized() * 20.0` (`dStage <= 20u` ALWAYS!)
            -- + `0.45s` cooldown guarantees a single clean rotation to `0 deg` and calm stationary hold!
            local angDown = U.GetAngleDifference(bot, enT1)
            if angDown > 15.0 and nowStage >= (State.stageLastAlignAt or -100) + 0.45 then
                State.stageLastAlignAt = nowStage
                local alignPt = anchorPt + (enT1 - anchorPt):Normalized() * 20.0
                if bot.Action_MoveDirectly then
                    bot:Action_MoveDirectly(alignPt)
                else
                    bot:Action_MoveToLocation(alignPt)
                end
            elseif angDown <= 15.0 and bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_NONE then
                bot:Action_ClearActions(true)
            end
        end
        State.actionTaken = true
        return true
    end

    if dtime < -3.35 then
        return stageAndFaceDownLane(myT3Block)
    end

    local allyCorridor = H.CollectMidCorridorCreeps(fnt, enT1, UNIT_LIST_ALLIED_CREEPS, s and s.allyCreeps)
    if #allyCorridor == 0 then
        if dtime <= 3.0 then
            return stageAndFaceDownLane(myT3Block)
        end
        return false
    end

    -- Find frontmost allied creep along the mid corridor
    local frontAllied, minAllyDistEn = nil, math.huge
    for _, ac in ipairs(allyCorridor) do
        local dE = U.DistanceBetweenLocations(ac:GetLocation(), enT1)
        if dE < minAllyDistEn then
            minAllyDistEn, frontAllied = dE, ac
        end
    end
    if not frontAllied then return false end

    -- Once ANY Wave-1 creep has slipped uncatchably ahead (`ExecuteDynamicCreepBlockStep` stamped `abortedWaveBlockUntil`),
    -- NEVER keep body-blocking trailing creeps AND NEVER linger behind them near T2/T3 — march straight to `myStaircase`!
    local stairToEnEarly = U.DistanceBetweenLocations(myStaircase, enT1)
    if dtime >= 0.5 and GameTime() < (State.abortedWaveBlockUntil or 0) then
        if U.DistanceBetweenLocations(bLoc, enT1) > stairToEnEarly + 180 then
            H.SmartMove(bot, myStaircase, 36, true)
            State.actionTaken = true
            return true
        end
        return false
    end

    -- `v7.9.9-pro` (`1814 @ 00:00..00:08` `.dem`-Verified Single-File Convergence Hold):
    -- Hold `myT3Block` (`(-3215, -2718)` Radiant / `(2848, 2121)` Dire — `.dem`-verified exact convergence coordinates
    -- where Valve's north/south barracks streams merge to `lat01 <= 7.6u`!) facing `0°` toward `enT1` until Wave #1 closes within `110u`!
    local t3BlockToEn = U.DistanceBetweenLocations(myT3Block, enT1)
    if dtime < 8.6 and U.DistanceBetweenLocations(bLoc, myT3Block) <= 460 and (minAllyDistEn - t3BlockToEn) > 110 then
        return stageAndFaceDownLane(myT3Block)
    end

    -- `v7.9.7-pro` + `v7.9.8-pro` (`0307` Fast-Start Wave-1 Mid-Lane Intercept, Strictly Down-Lane Only!):
    -- ONLY run when pre-game was skipped while SF was stranded down-lane (`> 480u` closer to `enT1` than `myT3Block`, e.g.
    -- near `myT2`/`myT1`), and clamp `meetPt` so it NEVER pulls SF behind `myT3Block` into T3's split flanks!
    local bDistEn = U.DistanceBetweenLocations(bLoc, enT1)
    if dtime >= 0.5 and dtime <= 14.5 and (t3BlockToEn - bDistEn) > 480 and (minAllyDistEn - bDistEn) > 520 then
        local fLoc = frontAllied:GetLocation()
        local meetPt = fLoc + (enT1 - fLoc):Normalized() * 180
        if U.DistanceBetweenLocations(meetPt, enT1) > t3BlockToEn then
            meetPt = myT3Block
        end
        H.SmartMove(bot, meetPt, 32, true)
        State.actionTaken = true
        return true
    end

    -- Release cleanly once our front creep arrives at `myWave1Meet` (`895u` outside `myT1`, `195u` outside 700u tower range!)
    local myWave1Meet = isRad
        and (C.POSITIONS.RADIANT_WAVE1_MEET or C.POSITIONS.RADIANT_STAIRCASE)
        or (C.POSITIONS.DIRE_WAVE1_MEET or C.POSITIONS.DIRE_STAIRCASE)
    local meetToEn = U.DistanceBetweenLocations(myWave1Meet, enT1)
    if minAllyDistEn <= meetToEn + 65 then
        return false
    end

    -- Piecewise lane-arc path helper (`creep -> towerRef -> meetPt`) so corner bends around `enT1`/`myT1` never skew ETA!
    local function laneArcDistToMeet(pt, viaTower)
        local dPtToMeet = U.DistanceBetweenLocations(pt, myWave1Meet)
        local dViaToMeet = U.DistanceBetweenLocations(viaTower, myWave1Meet)
        if dPtToMeet <= dViaToMeet + 40 then
            return dPtToMeet
        end
        return U.DistanceBetweenLocations(pt, viaTower) + dViaToMeet
    end

    -- `v7.9.13-pro` (`0210 @ 00:06.5..00:21.5` Ward #2 Closed-Loop Piecewise-Path + FoW Dead-Reckoning Early Release!):
    -- Fixes all 3 Wave #1 over-blocking root causes:
    --   1. Removes `dMyToStair <= 1750.0` gate (`at t=11.0..14.3s`, Ward #2 ALREADY proved unblocked `RC_front` at `325 u/s`
    --      would beat `DC_front` onto Dire's staircase even if released immediately at `dMy = 2,150..3,100u`!).
    --   2. Persists Ward #2 speed & path distance across the `~350u` `enT1`/river FoW gap (`dt <= 7.5s` dead-reckoning) so
    --      losing sight of `RC_front` at `t=15.8s` NEVER resets `desiredSpeed` back to `240.0` (max block)!
    --   3. The instant `etaMyUnblocked >= etaEnemy - 0.12` (or `desiredSpeed >= 318.0`), stamps `wave1ReleasedEarlyUntil`
    --      and steps SF `115u` laterally off `DC_front`'s march line (`305 MS` hero otherwise physically caps `325 MS` creeps
    --      at `~230 u/s`!) so our wave sprints at full `325 u/s` to meet `RC_front` on `myWave1Meet` (`895u` outside `myT1`)!
    local nowT = GameTime()
    local fAllyLoc = frontAllied:GetLocation()
    local dMyPathToMeet = laneArcDistToMeet(fAllyLoc, myT1)

    if nowT < (State.wave1ReleasedEarlyUntil or -100) then
        if U.DistanceBetweenLocations(bLoc, enT1) <= meetToEn + 160 then
            return false
        end
        local marchAxis = (myWave1Meet - fAllyLoc)
        if marchAxis:Length2D() < 1 then marchAxis = (enT1 - myT1) end
        marchAxis = marchAxis:Normalized()
        local perpSide = Vector(-marchAxis.y, marchAxis.x, 0)
        local relHero = bLoc - fAllyLoc
        local curLat = relHero.x * perpSide.x + relHero.y * perpSide.y
        if curLat < 0 then perpSide = Vector(-perpSide.x, -perpSide.y, 0) end
        local dHeroToCreep = U.DistanceBetweenLocations(bLoc, fAllyLoc)
        local laneSideTarget = (dHeroToCreep < 210)
            and (fAllyLoc + perpSide * 125 + marchAxis * 165)
            or (myWave1Meet + perpSide * 95)
        H.SmartMove(bot, laneSideTarget, 28, true)
        State.actionTaken = true
        return true
    end

    local desiredSpeed = 240.0 -- Default: max block (`~240 u/s`) from T3 until Ward #2 measures enemy wave
    local enemyCorridor = H.CollectMidCorridorCreeps(enT1, myT1, UNIT_LIST_ENEMY_CREEPS, s and s.enemyCreeps)
    local estEnPathDist = nil
    if #enemyCorridor > 0 then
        local frontEnemy, minEnPath = nil, math.huge
        for _, ec in ipairs(enemyCorridor) do
            local dP = laneArcDistToMeet(ec:GetLocation(), enT1)
            if dP < minEnPath then
                minEnPath, frontEnemy = dP, ec
            end
        end
        if frontEnemy then
            local estEnSpd = State.enWaveEstSpeed or 320.0
            if State.enWavePrevDist and State.enWavePrevTime then
                local dtObs = nowT - State.enWavePrevTime
                if dtObs >= 0.18 and dtObs <= 1.60 then
                    local instSpd = (State.enWavePrevDist - minEnPath) / dtObs
                    if instSpd >= 195.0 and instSpd <= 350.0 then
                        estEnSpd = estEnSpd * 0.58 + instSpd * 0.42
                    end
                end
            end
            State.enWaveEstSpeed = math.max(230.0, math.min(325.0, estEnSpd))
            State.enWavePrevDist = minEnPath
            State.enWavePrevTime = nowT
            estEnPathDist = minEnPath
        end
    elseif State.enWavePrevDist and State.enWavePrevTime and (nowT - State.enWavePrevTime) <= 7.5 then
        -- Dead-reckon Enemy Wave #1 across the `~350u` FoW gap between Ward #2's edge and river vision!
        local dtFow = math.max(0.0, nowT - State.enWavePrevTime)
        estEnPathDist = math.max(0.0, State.enWavePrevDist - dtFow * (State.enWaveEstSpeed or 320.0))
    end

    if estEnPathDist ~= nil then
        local effEnSpd = State.enWaveEstSpeed or 320.0
        local etaEnemy = math.max(0.30, estEnPathDist / effEnSpd)
        -- Unblocked allied creep runs at `325 u/s` after `~0.35s` lateral step-clear & corner turn:
        local etaMyUnblocked = (dMyPathToMeet / 323.0) + 0.35
        desiredSpeed = dMyPathToMeet / etaEnemy
        if etaMyUnblocked >= etaEnemy - 0.12 or desiredSpeed >= 318.0 then
            State.wave1ReleasedEarlyUntil = nowT + 12.0
            local marchAxis = (myWave1Meet - fAllyLoc)
            if marchAxis:Length2D() < 1 then marchAxis = (enT1 - myT1) end
            marchAxis = marchAxis:Normalized()
            local perpSide = Vector(-marchAxis.y, marchAxis.x, 0)
            local relHero = bLoc - fAllyLoc
            if (relHero.x * perpSide.x + relHero.y * perpSide.y) < 0 then
                perpSide = Vector(-perpSide.x, -perpSide.y, 0)
            end
            local stepClearPt = fAllyLoc + perpSide * 125 + marchAxis * 150
            H.SmartMove(bot, stepClearPt, 24, true)
            State.actionTaken = true
            return true
        end
    end

    if H.ExecuteDynamicCreepBlockStep(bot, allyCorridor, myT1, myT2, enT1, desiredSpeed) then
        return true
    end
    local stairToEn = U.DistanceBetweenLocations(myStaircase, enT1)
    if GameTime() < (State.abortedWaveBlockUntil or 0) and U.DistanceBetweenLocations(bLoc, enT1) > stairToEn + 180 then
        H.SmartMove(bot, myStaircase, 36, true)
        State.actionTaken = true
        return true
    end
    return false
end

-- Opportunistic Mid-Game Idle Creep Block (`v7.9.2` + `v7.9.11` Dire T2-T1 & Safe-Salve Wave Block Upgrade):
--   1. Allows blocking while `modifier_flask_healing` is active whenever completely safe from Salve-breaking sources
--      (`s.enemyAlive == false` or `effEnemyDist >= 1,380u`, `#enemyCreeps == 0`, no incoming projectiles — fixes
--      `2213 @ 07:40..07:50` & `08:38..08:50` Dire T2-T1 wave misses!).
--   2. Filters `blockGroup` to creeps that are still behind or overtakable by `bot` (`fwd >= -130u` at `>= 338 MS`,
--      `fwd >= 12u` at `< 338 MS`): if `1` front creep walked past SF while SF finished killing the last enemy creep
--      (`2213 @ 01:43, 02:16, 03:45`), SF still blocks the `2..3` remaining creeps (or overtakes all `4` with PT!)
--      cleanly between T2 and T1 and through T1 to the river staircase!
function H.HandleMidGameIdleCreepBlock(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local dtime = (type(DotaTime) == "function") and DotaTime() or 0
    if dtime < 19.5 then return false end
    if GameTime() < (State.abortedWaveBlockUntil or 0) then return false end
    if L._imminentCS then return false end
    if State.goingToFountain or State.emergencyRetreat then return false end
    -- `v7.9.20` (`1610.dem` `MISS #32/#33` Active-CS Guard + `W6 @ 03:17.47` Early-Abort Fix!):
    --   1. If ANY nearby enemy lane creep (`<= 1,550u`) is ALREADY damaged/contested (`hp < maxHp - 12` or `hp <= 260`),
    --      NEVER abandon active river/tower last-hitting (`fixes MISS #32 @ 861u & MISS #33 @ 675u`)!
    --   2. If all visible enemy creeps are full-HP unengaged incoming wave creeps, only abort once an enemy creep comes
    --      within `<= 920u` of `bot` (and below, `<= 900u` of our front allied creep), preventing `4.0s`-early aborts at `1,260u`!
    local localEnemyCreeps = (s and s.enemyCreeps) or {}
    local bLocEarly = bot:GetLocation()
    for _, ec in pairs(localEnemyCreeps) do
        if ec and U.CanQuery(ec) and ec:IsAlive() then
            local ecHp = ec:GetHealth() or 0
            local ecMax = math.max(1, ec:GetMaxHealth() or 550)
            local dEcBot = U.DistanceBetweenLocations(bLocEarly, ec:GetLocation())
            if (ecHp < ecMax - 12) or (ecHp <= 260) or (dEcBot <= 920) then
                return false
            end
        end
    end

    local enemy = s and s.enemy
    local enemyVis = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local fogLoc = (not enemyVis) and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 4.5
        and s.enemyLastLoc or nil
    local effEnLoc = (enemyVis and enemy:GetLocation()) or fogLoc
    local effEnDist = effEnLoc and GetUnitToLocationDistance(bot, effEnLoc) or 9999

    if bot:HasModifier("modifier_flask_healing") then
        if H.HasSalveBreakingProjectileIncoming(bot) then return false end
        if not (s and s.enemyAlive == false) and effEnDist < 1380 then
            return false
        end
    else
        local myHp = bot:GetHealth() or 0
        local myMaxHp = math.max(1, bot:GetMaxHealth() or 600)
        if myHp < math.max(260, myMaxHp * 0.42) then return false end
    end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.canKillNow) then return false end

    local enemyCreepCount = 0
    local noEnemyCreepsNow = true
    local minEnemyBlockDist = 760
    if enemyVis and (s.enemyDist or 9999) <= minEnemyBlockDist then
        return false
    end
    if L.PeekBestPlan then
        local _, etaSec = L.PeekBestPlan(bot, s)
        if etaSec <= 2.6 then return false end
    end

    local isRad, myT1, myT2, _, enT1, _ = H.GetMidTowerGeometry(bot)
    local myStaircase = isRad and C.POSITIONS.RADIANT_STAIRCASE or C.POSITIONS.DIRE_STAIRCASE
    local bLoc = bot:GetLocation()

    -- Ensure no enemy lane creeps are already at our staircase (`< 1,080u` from `myT1` or `< 920u` from `bot`)
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() then
            local ecLoc = ec:GetLocation()
            if U.DistanceBetweenLocations(ecLoc, myT1) < 1080 or U.DistanceBetweenLocations(ecLoc, bLoc) < 920 then
                return false
            end
        end
    end

    local fnt = P.GetFountain(bot)
    local allMidAllies = H.CollectMidCorridorCreeps(fnt, enT1, UNIT_LIST_ALLIED_CREEPS, s and s.allyCreeps)
    local waveModEarly = dtime % 30.0
    if #allMidAllies < 2 and not (waveModEarly >= 24.5 and U.DistanceBetweenLocations(bLoc, myT1) <= 1850) then
        return false
    end

    local t1ToEn = U.DistanceBetweenLocations(myT1, enT1)
    local stairToEn = U.DistanceBetweenLocations(myStaircase, enT1)
    local dBotFnt = U.DistanceBetweenLocations(bLoc, fnt)
    local dMyT1Fnt = U.DistanceBetweenLocations(myT1, fnt)
    local botAlreadyBehindT1 = (dBotFnt < dMyT1Fnt - 160)
    local effectivelyClearLane = noEnemyCreepsNow
    -- Do NOT abandon an active shielded Enemy T1 tower siege (`>= 2` allied creeps within `820u` of live `enemyT1`!)
    if s and U.CanQuery(s.enemyT1) and s.enemyT1:IsAlive() and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) <= 1050 then
        local shieldAtEnT1 = 0
        for _, acS in pairs(s.allyCreeps or {}) do
            if U.CanQuery(acS) and acS:IsAlive() and U.DistanceBetweenLocations(acS:GetLocation(), s.enemyT1:GetLocation()) <= 820 then
                shieldAtEnT1 = shieldAtEnT1 + 1
            end
        end
        if shieldAtEnT1 >= 2 and (s.enemyAlive == false or H.IsEnemyBehindOwnTower(bot, enemy, s.enemyT1:GetLocation())) then
            return false
        end
    end

    -- `v7.9.17-pro` Recurring Every-Wave Staircase Creep-Block & Proactive T2->Staircase Intercept:
    --   1. When `noEnemyCreepsNow` (`0` enemy lane creeps in mid), catch outgoing `:00`/`:30` waves all the way from `myT2`
    --      (`maxBehindT1 = 3150`, `maxBotDist = 3550`), OR if the newly-spawned wave is still marching from `myT3 -> myT2`
    --      (`3150 < behindT1 <= 4850`), proactively pre-stage `880u` behind `myT1` so SF catches 100% of the wave aligned `0°`!
    --   2. Block at full pro stop-cadence (`desiredWaveSpeed = 195.0`) down onto `myStaircase` (`stairToEn - 25`), while releasing
    --      early ONLY if a visible incoming enemy wave approaches within `1,180u` of `myT1` (preventing accidental self-T1 pulls!).
    local maxBotDist = effectivelyClearLane and 3550 or (botAlreadyBehindT1 and 3150 or 1550)
    local maxBehindT1 = effectivelyClearLane and 3150 or (botAlreadyBehindT1 and 2750 or 1250)
    local myMSNow = bot:GetCurrentMovementSpeed() or 305
    local minBlockableFwd = (myMSNow >= 338) and -140.0 or -12.0
    local dBotEnNow = U.DistanceBetweenLocations(bLoc, enT1)

    local blockGroup = {}
    local spawningWaveCount = 0
    local slippedSameWaveCount = 0
    local minSlippedDistStair = math.huge
    local minAllyDistMyT1 = math.huge
    for _, ac in ipairs(allMidAllies) do
        local cHp = ac:GetHealth() or 0
        local cMax = math.max(1, ac:GetMaxHealth() or 550)
        local cLoc = ac:GetLocation()
        local dEn = U.DistanceBetweenLocations(cLoc, enT1)
        local dBot = U.DistanceBetweenLocations(cLoc, bLoc)
        local notFighting = not (ac.GetAttackTarget and ac:GetAttackTarget() ~= nil)
        local mDir = (enT1 - cLoc):Normalized()
        local fwd = (bLoc.x - cLoc.x) * mDir.x + (bLoc.y - cLoc.y) * mDir.y
        local catchableFromRiver = effectivelyClearLane and (dEn > dBotEnNow + 25)
        if cHp >= cMax * 0.75 and notFighting then
            if dBot <= maxBotDist
                and dEn <= (t1ToEn + maxBehindT1)
                and dEn >= (stairToEn - 25)
                and (fwd >= minBlockableFwd or catchableFromRiver) then
                blockGroup[#blockGroup + 1] = ac
                local dMyT1C = U.DistanceBetweenLocations(cLoc, myT1)
                if dMyT1C < minAllyDistMyT1 then minAllyDistMyT1 = dMyT1C end
            elseif fwd < -38.0 and fwd > -620.0 and dEn >= (stairToEn - 80) then
                -- `v7.9.20` (`1610.dem` `W0/W7` Slipped-Creep Wave-Split Guard!):
                -- Track creeps of the SAME wave that already slipped past `bot`: allow `3+`-creep recovery deep behind T1
                -- when at most `1` creep slipped (`>= 560u` before `myStaircase`), but abort immediately if `>= 2` slipped
                -- OR once the slipped creep nears `myStaircase` (`< 560u`) so the wave never splits `700u` at clash!
                slippedSameWaveCount = slippedSameWaveCount + 1
                local dSlipStair = dEn - stairToEn
                if dSlipStair < minSlippedDistStair then minSlippedDistStair = dSlipStair end
            elseif effectivelyClearLane and dEn > (t1ToEn + maxBehindT1) and dEn <= (t1ToEn + 4850) then
                spawningWaveCount = spawningWaveCount + 1
            end
        end
    end

    if slippedSameWaveCount >= 2 or (slippedSameWaveCount >= 1 and (#blockGroup < 3 or minSlippedDistStair < 560)) then
        State.abortedWaveBlockUntil = GameTime() + 2.8
        return false
    end

    if #blockGroup < 2 then
        -- Fresh `:00`/`:30` wave just spawned between `myT3` and `myT2` OR `:24.5..:29.9` / `:54.5..:59.9` spawn clock is
        -- imminent while mid has `0` enemy creeps: proactively pre-stage `840u` behind `myT1` (`aligned 0 deg` down-lane!)
        -- so SF catches 100% of every wave from behind `myT1` -> `myStaircase` instead of lingering empty-handed on river!
        local waveMod30 = dtime % 30.0
        local spawnImminentPreStage = (waveMod30 >= 24.5 or waveMod30 <= 3.5)
            and (U.DistanceBetweenLocations(bLoc, myT1) <= 1850)
        if effectivelyClearLane and (spawningWaveCount >= 2 or spawnImminentPreStage)
            and (not enemyVis or (s.enemyDist or 9999) >= 840) then
            local upLaneDir = (myT2 and U.DistanceBetweenLocations(myT2, myT1) > 100)
                and (myT2 - myT1):Normalized()
                or (fnt - myT1):Normalized()
            local preStageSpot = myT1 + upLaneDir * 840
            if U.DistanceBetweenLocations(bLoc, preStageSpot) > 85 then
                H.SmartMove(bot, preStageSpot, 45)
            else
                -- Already at pre-stage spot: pre-align `0°` down-lane toward `myT1` so first contact has zero turn delay!
                local alignDown = preStageSpot + (myT1 - preStageSpot):Normalized() * 24
                if U.GetAngleDifference(bot, myT1) > 15 and GameTime() >= (State.stageLastAlignAt or -100) + 0.45 then
                    State.stageLastAlignAt = GameTime()
                    bot:Action_MoveToLocation(alignDown)
                end
            end
            State.actionTaken = true
            return true
        end
        return false
    end

    -- Dynamic Staircase-Lip Equilibrium Guard: if an unblocked enemy wave is already approaching our staircase (`<= 1,180u`
    -- from `myT1` and closer than `minAllyDistMyT1 + 210`), release the block so waves clash right on `myStaircase` outside `myT1`!
    local minEnDistMyT1 = math.huge
    for _, list in ipairs({ (s and s.enemyCreeps) or {}, (s and s.midActiveEnemyCreeps) or {} }) do
        for _, ec in pairs(list) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local dET1 = U.DistanceBetweenLocations(ec:GetLocation(), myT1)
                if dET1 < minEnDistMyT1 then minEnDistMyT1 = dET1 end
            end
        end
    end
    if minEnDistMyT1 <= 1180 and minEnDistMyT1 <= (minAllyDistMyT1 + 210) then
        return false
    end

    return H.ExecuteDynamicCreepBlockStep(bot, blockGroup, myT1, myT2, enT1, 195.0)
end

-- `v7.9.0` Night-Vision Asymmetric Sniping (`800u` Night Vision vs our Highground Ward / Creep Vision):
function H.HandleNightVisionAdvantagePoke(bot, s, earlyRace)
    if not (s and s.isNight and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()) then return false end
    if (bot:GetMana() or 0) < 135 or (bot:GetHealth() or 0) < 340 then return false end
    if earlyRace and earlyRace.valid and earlyRace.heCanKillSoon then return false end
    local bLoc = bot:GetLocation()
    local eLoc = s.enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    -- At night (`800u` hero vision), `Shadowraze3` (`700 ± 274 = [426, 974]`) reaches up to `174u` BEYOND enemy night sight!
    if d < 785 or d > 945 then return false end
    local unseenOrUphill = (d >= 805) or (((bLoc.z or 0) - (eLoc.z or 0)) >= 85)
    if not unseenOrUphill then return false end
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(bLoc, ec:GetLocation()) <= 575 then
            return false -- Enemy lane creep grants vision of SF
        end
    end
    local r3 = bot:GetAbilityByName("nevermore_shadowraze3")
    if r3 and U.IsRazeAbilityCastable(bot, r3) then
        local actT, aimL = H.GetRazeActionType(bot, r3, s.enemy)
        if actT and H.CastOrTurnRaze(bot, r3, actT, aimL, s.enemy) then
            return true
        end
    end
    return false
end

-- `v7.9.0` + `v7.9.8-pro` (`1630 @ 04:10.27` & `04:37.27` Bullseye Self-Cancel Fix!):
-- Deliberate `0.28s` Pro `Shadowraze3` Pump-Fake Bait ONLY on the outer bait rim (`d = [855 .. 975u]`), NEVER inside
-- `[700 .. 850u]` where a real `E(700)` is already a high-probability / guaranteed centered hit!
function H.HandlePumpFakeBait(bot, s, earlyRace)
    if not (s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()) then return false end
    local now = GameTime()
    if now < (State.nextPumpFakeAt or 0) then return false end
    if (bot:GetMana() or 0) < 150 or (bot:GetHealth() or 0) < 440 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.canKillNow) then return false end
    local d = U.DistanceBetweenLocations(bot:GetLocation(), s.enemy:GetLocation())
    if d < 855 or d > 975 then return false end
    if K.EnemyPhase and K.EnemyPhase() ~= nil then return false end
    local r3 = bot:GetAbilityByName("nevermore_shadowraze3")
    if not (r3 and r3:GetLevel() >= 2 and r3:IsCooldownReady()) then return false end
    if not H.RazeFacingOK(bot, s.enemy:GetLocation()) then return false end
    State.nextPumpFakeAt = now + 16.5
    State.pumpFakeCancelAt = now + 0.28
    bot:Action_UseAbility(r3)
    H.StartRazeCast(r3, s.enemy, s.enemy:GetLocation(), C.RAZE.HIT_RADIUS, false)
    H.ClearMoveCache()
    return true
end

-- `v7.9.11-pro` (`2204 @ 02:20, 02:53, 03:22, 03:30, 03:49` Dominant Anti-Reaggro Wave-Shield & Punish!):
-- When our SF is significantly stronger than the enemy SF (`U.IsLaneDominant(bot, s, earlyRace) == true`) and no CS/deny
-- requires an immediate swing (`<= 0.55s`), NEVER allow a weaker opponent to walk up within `<= 665u` of our allied creeps
-- to touch the `500u` creep-aggro circle and pull our melee creeps back onto his ranged creep!
--   1. If a ready `W(450)` or `E(700)` coil hits him cleanly right now (`mana >= 75`), blast him immediately!
--   2. Otherwise right-click him immediately (`H.IssueHeroAttack`) OR step onto the forward intercept screen between
--      `frontAlly` and `enemy` (`standoff >= 495u` if enemy has `>= 150 MP` + `Q`, `>= 380u` otherwise, `>= 920u` from `enemyT1`)!
function H.HandleDominantAntiReaggroZone(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or H.TowerBurnActive() then return false end
    if GameTime() < (State.noReenterEnemyT1Until or 0) then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local allyCreeps = s and s.allyCreeps
    if not allyCreeps or #allyCreeps == 0 then return false end
    if not (U.IsLaneDominant and U.IsLaneDominant(bot, s, earlyRace)) then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon) then return false end
    local myHp = bot:GetHealth() or 0
    if myHp < 375 then return false end

    local dEnToAlly, frontAlly = LN.EnemyDistToAllyWave(enemy, allyCreeps)
    if not frontAlly then
        for _, ac in pairs(allyCreeps) do
            if ac and U.CanQuery(ac) and ac:IsAlive() then
                frontAlly = ac
                break
            end
        end
    end
    if dEnToAlly > 785 or not frontAlly or not U.CanQuery(frontAlly) then return false end

    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local dHero = U.DistanceBetweenLocations(bLoc, eLoc)
    if s.enemyT1Alive ~= false and s.enemyT1Loc then
        -- Do not try to zone an enemy already standing deep under his own T1 (`< 720u` from `enemyT1Loc`)!
        if U.DistanceBetweenLocations(eLoc, s.enemyT1Loc) < 720 then
            return false
        end
    end

    local myMana = bot:GetMana() or 0
    local enPotMp = K.EnemyManaBudget(enemy, true)
    local enHp = enemy:GetHealth() or 999
    local allowSingleCoilPunish = (enPotMp < 150) or (enHp <= 460) or (myMana >= 140)
    if myMana >= 75 and allowSingleCoilPunish and not bot:IsSilenced() then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action == "CAST" or (action == "TURN" and dEnToAlly <= 625) then
                    if H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        State.actionTaken = true
                        return true
                    end
                end
            end
        end
    end

    local enQArmed = (enPotMp >= 75) and K.EnemyRazeReady("near", 1.2)
    local minSafeStand = (enQArmed and enPotMp >= 150 and myHp < enHp + 220) and 495 or 385
    local atkR = (bot:GetAttackRange() or 525)
    if dHero <= atkR + 35 and dHero >= minSafeStand - 25
        and H.IsSafeToAttack(bot, bLoc, s.enemyTowers, allyCreeps) then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    elseif dHero <= atkR + 585 and dEnToAlly <= 765 then
        -- `v7.9.13-pro` (`0210 @ 00:00..06:00` Proactive Anti-Reaggro Screen):
        -- Position `195u` IN FRONT of `frontAlly` toward `enemy` (clamped `>= minSafeStand` from `enemy` and `>= 920u`
        -- outside `enemyT1`) BEFORE `enemy` reaches the `500u` creep-aggro circle — even when `eLoc` stands `730..865u`
        -- in front of his own T1 (`screenPt` itself is strictly `>= 920u` outside `enemyT1`, so moving there NEVER aggros T1)!
        local faLoc = frontAlly:GetLocation()
        local toEnemyFromAlly = (eLoc - faLoc)
        if toEnemyFromAlly:Length2D() < 1 then toEnemyFromAlly = (eLoc - bLoc) end
        toEnemyFromAlly = toEnemyFromAlly:Normalized()
        local screenPt = faLoc + toEnemyFromAlly * math.min(205, math.max(95, dEnToAlly - minSafeStand))
        if U.DistanceBetweenLocations(screenPt, eLoc) < minSafeStand then
            local awayFromEn = (faLoc - eLoc)
            if awayFromEn:Length2D() < 1 then awayFromEn = (bLoc - eLoc) end
            screenPt = eLoc + awayFromEn:Normalized() * minSafeStand
        end
        if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(screenPt, s.enemyT1Loc) < 920 then
            local fntRef = P.GetFountain(bot)
            screenPt = s.enemyT1Loc + (fntRef - s.enemyT1Loc):Normalized() * 920
        end
        if U.DistanceBetweenLocations(bLoc, screenPt) > 40
            and U.DistanceBetweenLocations(screenPt, eLoc) >= minSafeStand - 15 then
            H.SmartMove(bot, screenPt, 32, true)
            State.actionTaken = true
            return true
        end
    end
    return false
end

-- `v7.9.12-pro` (`2319 @ 00:54..01:12, 02:20..02:26, 02:55..03:12` Staircase Wave-Freeze Blindness Fix!):
-- When the enemy holds/freezes the wave on his own staircase (`1,601..2,750u` from our T1), C++ `GetNearbyLaneCreeps(1600)`
-- returns `{}` (`#s.enemyCreeps == 0` & `#s.allyCreeps == 0`), which previously trapped `RealThink` inside `holdSpot` at
-- `P.GetT1Close(bot)` (`(632, 518)` — `0` CS, `0` XP!). Using `s.activeMidClashLoc` (`GetUnitList` mid-battle-corridor scan),
-- advance cleanly to safe contested/XP standoff (`~475u`, or `dryStand` when dry) until `<= 1,600u` `RunSacredCS` takes over!
function H.HandleAdvanceToDistantMidWave(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not (s and s.hasDistantMidWaveClash and s.activeMidClashLoc) then return false end
    if State.goingToFountain or State.emergencyRetreat then return false end
    local nowAdv = GameTime()
    if (State.forcedRetreatLoc ~= nil and nowAdv < (State.forcedRetreatUntil or 0))
        or (nowAdv < (State.fleeUntil or 0))
        or (nowAdv < (State.critDangerHystUntil or 0)) then
        return false
    end
    if bot:HasModifier("modifier_flask_healing") or H.TowerBurnActive() then return false end
    if nowAdv < (State.noReenterEnemyT1Until or 0) then return false end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 600)
    if myHp < math.max(245, myMaxHp * 0.36) then return false end
    if H.InCriticalLethalDanger(bot, s, earlyRace)
        or (earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon)) then
        return false
    end

    -- Only needed when local `1,600u` `RunSacredCS` cannot yet reach/see the active wave clash (`#s.enemyCreeps == 0`
    -- or `bot` is still `> 1,280u` from `s.activeMidClashLoc` with `0` local enemy creeps inside `1,280u`)!
    local bLoc = bot:GetLocation()
    local clashLoc = s.activeMidClashLoc
    local dClash = U.DistanceBetweenLocations(bLoc, clashLoc)
    if #(s.enemyCreeps or {}) >= 2 and dClash <= 1150 then
        return false
    end
    if dClash <= 520 or dClash > 2950 then
        return false
    end

    local fnt = P.GetFountain(bot)
    local dirHome = (fnt - clashLoc):Normalized()
    local standDist = 475
    local enemy = s.enemy
    local enemyVis = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    if enemyVis and U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemy, s) then
        standDist = math.max(standDist, U.GetDrySafeStandoffDist(bot, enemy))
    end
    local targetSpot = clashLoc + dirHome * standDist

    if enemyVis then
        local eLoc = enemy:GetLocation()
        local minHeroGap = (U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemy, s))
            and math.max(745, U.GetDrySafeStandoffDist(bot, enemy))
            or 515
        if U.DistanceBetweenLocations(targetSpot, eLoc) < minHeroGap then
            targetSpot = eLoc + (fnt - eLoc):Normalized() * minHeroGap
        end
    end
    if s.enemyT1Alive ~= false and s.enemyT1Loc then
        local shieldUnderEnT1 = 0
        for _, ac in pairs(s.midActiveAllyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 135
                and U.DistanceBetweenLocations(ac:GetLocation(), s.enemyT1Loc) <= 755 then
                shieldUnderEnT1 = shieldUnderEnT1 + 1
            end
        end
        if shieldUnderEnT1 < 1 and U.DistanceBetweenLocations(targetSpot, s.enemyT1Loc) < 930 then
            targetSpot = s.enemyT1Loc + (fnt - s.enemyT1Loc):Normalized() * 930
        end
    end

    if U.DistanceBetweenLocations(bLoc, targetSpot) > 55 then
        H.SmartMove(bot, targetSpot, 45)
        State.actionTaken = true
        return true
    end
    return false
end

function H.RealThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    State.actionTaken = false
    State.combatPolicyActive = false
    State.holdPos = false
    State.trySafeTreadsCb = H.TrySafeTreadsSwitch
    L._imminentCS = false -- Always reset per-tick so early-return frames never leave stale `_imminentCS = true`!
    _G.__lastCombatStage = nil
    FDBG("think")
    U.BeginPredictionFrame()

    -- World snapshot + enemy raze tracker + live attack animation state (must run BEFORE windup holds!)
    local s = W.Update(bot)
    K.UpdateEnemyTracker(bot, s.enemy)
    H.UpdateAttackActivity(bot)
    H._enemyHeroNear = s.enemy -- GetSafeApproach & HandleActiveRazeValidation read live enemy hero
    -- The hit/miss tracker for his razes - before decisions (the instant mirror reads it)
    if s.enemy then U.UpdateEnemyRazeMissTracker(bot, s.enemy) end

    -- A visible channel/respawn gives a conservative arrival warning only when
    -- no actual visible landing point is available. It is not a known destination.
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemy and U.IsEnemyTPChanneling(s.enemy) then
        State.enemyTPIncomingUntil = s.now + 3.0
    end
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemyAlive and State.enemyWasAlive == false then
        State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, s.now + 6.0)
    end
    State.enemyWasAlive = s.enemyAlive

    -- A TP channel is running - no orders (any order cancels the teleport to the T1)
    if bot:IsChanneling() then
        State.actionTaken = true
        return
    end

    H.LevelUpAbilities(bot)
    -- Keep active inventory organized UNLESS a Backpack consumable or 3-phase Mango sequence is active
    if not State.mangoSeq and GameTime() >= (State.branchTangoSwapUntil or -1000) then
        U.ManageInventorySlots(bot)
    end
    local earlyRace = K.Race(bot, s.enemy, false, s)

    -- Emergency survival consumables WITH full earlyRace context (Faerie Fire +85, Stick/Wand, Mango)
    if H.HandleEmergencyConsumables(bot, earlyRace, s) then return end
    -- Advance any active 3-phase Multi-Tick Mango + PT/Backpack state machine BEFORE regular Treads/lane orders!
    if H.TickMangoStateMachine(bot, s) then return end
    -- Instant `+220 HP` Strength Power Treads survival lock BEFORE emergency retreats/disengages!
    if H.ShouldLockStrengthTreads(bot) and H.TrySafeTreadsSwitch(bot, "SURVIVE") then return end
    if H.HandleIncomingTeleport(bot, s) then return end
    if H.HandlePreRespawnOverextensionPullback(bot, s) then return end
    if H.HandleFreshEnemyTPArrival(bot, s, earlyRace) then return end

    -- FOUNTAIN RESPAWN / HEAL + IMMEDIATE TP TO MID T1 (runs BEFORE RunSacredCS and empty-wave holdSpot!)
    if H.HandleReturnTP(bot) then return end

    -- =========================================================================
    -- SACRED 30.000 Hz BALLISTIC CS & IMMORTAL LANE SUSTAIN PRIORITY GATE
    -- =========================================================================
    -- `v7.9.19` (`9074666246.dem` `11/21 = 52.4%` `SELF_RAZE_CAST_LOCK` Fix!):
    -- BEFORE returning inside `HandleActiveRazeValidation` / `inRealCastPhase`, check if an enemy Shadowraze is actively
    -- winding up ON TOP of `bot` while our own cast is a pump-fake, creep-only CS, whiff, or losing non-lethal coil:
    -- S-cancel our `0.55s` cast (`0 MP`, `0.0s CD`!) and execute `HandleEnemyRazeDodge` on the exact same tick!
    if bot:IsUsingAbility() and s.enemy and H.ShouldAbortOwnCastToDodgeRaze(bot, s.enemy) then
        bot:Action_ClearActions(true)
        H.ClearRazeState()
        if H.HandleEnemyRazeDodge(bot, s.enemy) then return end
    end
    if H.HandleActiveRazeValidation(bot) then return end
    if bot:IsUsingAbility() then
        -- `v7.9.0` 0.00s Post-Cast Raze Backswing Cancel:
        -- In Source 2 C++, `bot:IsUsingAbility()` stays `true` during the `0.30–0.45s` cosmetic post-cast backswing AFTER
        -- `IsInAbilityPhase()` becomes `false` and the coil has already detonated (`cd > 8.1s`)! Cancel backswing immediately!
        local inRealCastPhase = false
        for _, rName in ipairs({ "nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3" }) do
            local rAb = bot:GetAbilityByName(rName)
            if rAb and rAb:IsInAbilityPhase() then
                inRealCastPhase = true
                break
            end
        end
        local curActive = bot.GetCurrentActiveAbility and bot:GetCurrentActiveAbility() or nil
        if not inRealCastPhase and curActive and curActive.IsInAbilityPhase and curActive:IsInAbilityPhase() then
            inRealCastPhase = true
        end
        if inRealCastPhase then
            return
        end
        bot:Action_ClearActions(false)
        H.ClearRazeState()
    end
    if s.enemy then
        local lrQuick = U.SolveLethalRace(bot, s.enemy, s)
        if lrQuick and lrQuick.winsFirstKill and lrQuick.needEmergencyHeal then
            local wandQuick = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
            if wandQuick and wandQuick:IsFullyCastable() and U.GetStickCharges(bot) > 0 then
                bot:Action_UseAbility(wandQuick)
                State.actionTaken = true
                return
            end
            local ffQuick = U.GetActiveItemByName(bot, "item_faerie_fire")
            if ffQuick and ffQuick:IsFullyCastable() and (bot:GetHealth() or 999) <= math.max(95, (bot:GetMaxHealth() or 600) * 0.15) then
                bot:Action_UseAbility(ffQuick)
                State.actionTaken = true
                return
            end
        end
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end
    -- `v7.9.16-pro` Post-Kill Tower Survival (`05:49.33`) + Super-Emergency Between-Blows / First-Kill-Flip Micro-Salve!
    -- MUST execute ABOVE `HandleEnemyTowerSafety` so post-kill tower-escape early-return NEVER suppresses Salve activation!
    if H.TryEmergencySurvivalAndMicroSalve(bot, s, earlyRace) then return end
    -- Instant `0`-tick Siege Glyph check runs BEFORE `HandleEnemyTowerSafety` (`9055695956.dem` `tk=14412` fix:
    -- `ActionImmediate_Glyph` does NOT consume our hero's unit order and works even while SF stands back at `912u`!)
    H.HandleSiegeGlyph(bot, s, earlyRace)
    if H.HandleEnemyTowerSafety(bot, s, s.enemy) then return end

    -- Throne-Grade Mid T1 Sudden-Death Defense (`BAR 9:10`), Tower-Diver Execution (`BAR 4:10`), & Low-HP Finish (`BAR 5:09`/`6:12`)
    if H.HandleCriticalAllyT1AndDivePunish(bot, s, earlyRace) then return end

    -- Top-Level Post-Kill Check BEFORE `goingToFountain` clear so an actual low-HP 0-gold reset never aborts halfway!
    if H.HandlePostKillReset(bot, s) then return end

    -- Urgent `< 75 MP` Combat Mango Unlock & `v7.5.0` Active-Lane Dual-Coil (`< 145 MP`) Mango Pop:
    -- `L.RunSacredCS` returns early whenever lane creeps are alive, which previously prevented `TryBackpackAmpMango`
    -- (`:8552`) from ever firing during waves! Pop 1 Mango here whenever `< 75 MP` in combat OR `< 145 MP` (`missing >= 115`)
    -- when no last-hit swing is imminent and either `enemy <= 950u` or we carry `2+` Mangoes!
    do
        local topMana = bot:GetMana() or 0
        local topMissing = (bot:GetMaxMana() or 0) - topMana
        local enDistTop = (s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive())
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
        local urgentCombatPop = topMana < 75
            and (enDistTop <= 1050 or (s.enemyAlive ~= false and (s.enemyAbsentFor or 99) <= 4.0))
        local dualCoilLanePop = (not L._imminentCS) and topMana < 145 and topMissing >= 115
            and ((U.GetItemCount and U.GetItemCount(bot, "item_enchanted_mango") or 0) >= 2
                or enDistTop <= 950)
        if (urgentCombatPop or dualCoilLanePop) and not bot:IsChanneling() and not bot:IsUsingAbility() then
            local immediateEmerg = urgentCombatPop and enDistTop <= 680
            local dropMode = H.GetMangoDropMode and H.GetMangoDropMode(bot, s, immediateEmerg)
                or ((not immediateEmerg) and H.IsSafeForBackpackMangoDrop(bot, s) and #(s.enemyCreeps or {}) == 0)
            if H.StartMangoPop(bot, dropMode, immediateEmerg) then
                return
            end
        end
    end

    -- Top-Level Salve Trigger & Active `modifier_flask_healing` Protection (`missingHp >= 300` -> full 100% HP!)
    if H.HandleProactiveAndActiveSalve(bot, s, earlyRace) then return end
    -- Top-Level Clarity Trigger & Active `modifier_clarity_potion` `1,055u` Outer-Raze Protection (`auto-20261102-0139` `11:46..11:50` Fix!)
    if H.HandleProactiveAndActiveClarity and H.HandleProactiveAndActiveClarity(bot, s, earlyRace) then return end

    -- Immediate Enemy `modifier_flask_healing` Breaker (`W5 07:01.7` + `1343 @ 10:34.40` `72 HP` Lethal Override!)
    local lethalSalveTarget = s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive() and ((s.enemy:GetHealth() or 9999) <= 195)
    if (not L._imminentCS or lethalSalveTarget) and H.HandleBreakEnemySalve(bot, s, earlyRace) then return end

    -- `0:00` Creep Wave Body-Block runs BEFORE `HandlePriorityWardPlant` (`auto-20261102-0159` `00:00..00:18` Fix #2:
    -- `HandleOpeningCreepBlock` already yields to pre-horn Ward #1 / Ward #2 while `dtime < -31.0`, and running it FIRST
    -- guarantees a leftover/aborted 2nd ward NEVER hijacks Wave #1 block at `00:00`!).
    if H.HandleOpeningCreepBlock(bot, s) then return end
    if H.HandlePriorityWardPlant(bot, s) then return end

    -- Unified WarDirector Pre-CS Reflex: ONLY guaranteed `KILL` or 0.55s pinned enemy cast-lock `PUNISH` / `ANSWER`
    -- (NEVER steals Sacred CS or blocks Salve/Retreat!)
    if H.WarDirectorPreCS(bot, s) then return end

    -- CRITICAL `v4.0.0`–`v4.2.0` FIRST-KILL `TTK` & MULTI-STACK COMBO OVERRIDE:
    -- MUST execute ABOVE `InCriticalLethalDanger` so lethal 3rd-stack `Raze3` (`Demo 2` `7:41`), 2nd-stack overlap chains
    -- (`Demo 1` `1:20` & `Demo 2` `7:13.3`), and dominant dry-mana duels (`Demo 1` `3:55`) NEVER abort to flee!
    if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then return end
    if H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, true) then return end

    -- Stage A: Critical life & Outer-Hedge `Shadowraze3` Bait/Dodge Protection
    -- `auto-20261022-2237-start-ShaNachnetsya.dem` `05:42` (`Death #1`) Fix:
    -- If an enemy SF already closed inside point-blank `Shadowraze1` (`115..325u`), our stack timer is fresh (`> 2.5s`,
    -- preserving `S43` last-second expiry sprint!), and enemy carries `0` raze stacks while we have `>= 180 HP` and `Q` ready,
    -- fire ONE instant defensive `Snap-Q` BEFORE disengaging so we never die with `297 MP` unused (`0` inward steps)!
    if H.InCriticalLethalDanger(bot, s, earlyRace) then
        if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive() and not bot:IsSilenced() then
            local dClose = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
            local mySt, myRemT = U.GetShadowrazeDebuff(bot)
            local enSt = U.GetShadowrazeDebuff(s.enemy) or 0
            local qAb = bot:GetAbilityByName("nevermore_shadowraze1")
            local nearCrSnap = 0
            for _, ec in pairs(s.enemyCreeps or {}) do
                if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 235 then
                    nearCrSnap = nearCrSnap + 1
                end
            end
            local outMatchedSnap = ((s.enemy:GetLevel() or 1) > (bot:GetLevel() or 1))
            local minHpSnapQ = (outMatchedSnap or nearCrSnap >= 2) and 295 or 215
            if dClose >= 115 and dClose <= 325
                and (mySt == 0 or (myRemT or 0) > 2.5)
                and enSt == 0
                and (bot:GetHealth() or 0) >= minHpSnapQ
                and (bot:GetMana() or 0) >= 75
                and qAb and qAb:GetLevel() > 0 and qAb:IsCooldownReady() then
                local eLocNow = U.PredictPosition(s.enemy, C.RAZE.CAST_POINT)
                -- `v7.9.19` (`9074666246.dem` `05:44.87` `180 deg` Turn-Cast `Snap-Q` Suicide Fix!):
                -- NEVER turn `> 48 deg` (`0.20s` turn + `0.55s` cast = `0.75s` stationary root!) when fleeing a faster enemy SF!
                -- Previously `elseif angSnap <= 48 or enFasterSnap` forced a `180 deg` spin at `86.8 MP -> 11.8 MP` right into
                -- `ShaNachnetsya`'s point-blank `Shadowraze1 + auto` (`568 -> 283 HP`)! Also require `>= 150 MP` (or lethal `Q`)
                -- when the enemy SF still holds `>= 150 MP` so we NEVER root ourselves spending our last `75 MP`!
                local angSnap = U.GetAngleDifference(bot, eLocNow)
                local enTotalMpSnap = (s.enemy:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(s.enemy) or 0)
                local qKillsNow = (s.enemy:GetHealth() or 9999) <= (K.MyRazeDamage(bot, s.enemy, 1) + 20)
                local safeManaSnap = qKillsNow or ((bot:GetMana() or 0) >= 150) or (enTotalMpSnap < 140)
                if safeManaSnap and angSnap <= C.RAZE.MAX_ANGLE_TO_CAST then
                    -- Do NOT issue `ManageTreads("CAST")` on the same tick before `Action_UseAbility(qAb)`:
                    -- C++ overwrites the unit order slot with `qAb` while desyncing `U._pt.stat`!
                    bot:Action_UseAbility(qAb)
                    H.StartRazeCast(qAb, s.enemy, eLocNow, C.RAZE.HIT_RADIUS, false)
                    H.ClearMoveCache()
                    return
                elseif safeManaSnap and angSnap <= 42 then
                    local bSnap = bot:GetLocation()
                    bot:Action_MoveToLocation(bSnap + (eLocNow - bSnap):Normalized() * 32)
                    State.actionTaken = true
                    return
                end
            end
        end
        if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
    end

    -- `auto-20261102-0007` + `v7.9.19` (`9074666246.dem` `00:39, 02:05, 03:28, 04:05, 07:58, 10:27`) Zero-Turnback Retreat Continuity Gate:
    -- While critical-danger hysteresis (`critDangerHystUntil`) OR any active forced/losing-trade retreat is running
    -- (REGARDLESS of whether `myHp <= 540` — previously `> 540 HP` retreats fell through into `RunSacredCS` and spun `180 deg`!),
    -- NEVER fall through into `RunSacredCS` or Stage `B0` and spin backward toward a pursuing SF!
    do
        local nowRet = GameTime()
        local activeForcedFlee = (State.forcedRetreatLoc ~= nil and nowRet < (State.forcedRetreatUntil or 0))
            or (nowRet < (State.fleeUntil or 0))
            or (State.survivalLoc ~= nil and nowRet < (State.survivalUntil or 0))
        local critHystActive = nowRet < (State.critDangerHystUntil or 0)
        local activeLosingRetreat = activeForcedFlee
            and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
            and (H.InLosingHeroTrade(bot, s, earlyRace) or H.IsDryVsEnemyRaze(bot, s.enemy) or nowRet < (State.noHarassTurnbackUntil or 0))
        if (critHystActive or activeLosingRetreat)
            and not (earlyRace and earlyRace.valid and (earlyRace.canKillNow or earlyRace.canKillSoon)) then
            if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
                and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) <= 1040 then
                if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
            end
            if H.TickForcedRetreat(bot, s) then return end
        end
    end

    -- `v7.9.11` (`2213 @ 10:54..12:59` Global Anti-Creep-Cut & Undefended `allyT1` Creep-Siege Defender!):
    -- Placed right AFTER `InCriticalLethalDanger` + `Zero-Turnback Retreat Continuity Gate` (so wounded retreats NEVER
    -- turn back into a pursuing SF!) and BEFORE `RunSacredCS`, jungle chasing, or empty-river `holdSpot`!
    if H.HandleAntiCreepCutAndT1Defense(bot, s, earlyRace) then return end

    -- Post-Kill Rapid Wave Crash (`HUD 09:01`, `s.enemyAlive == false`) vs Equilibrium CS+Deny (`ShaNachnetsya` `00:45–01:01`):
    -- ONLY shove before `RunSacredCS` when `U.CanCrashWaveBeforeEnemyReturn(bot, s)` proves our wave will genuinely reach
    -- Enemy T1 before he respawns & TPs AND no enemy CS / allied deny opens within `1.85s`!
    local waveUnderOwnT1 = false
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and ec:IsAlive() and H.IsNearOwnT1(ec, 760) then
            waveUnderOwnT1 = true
            break
        end
    end
    local canCrashPostKill = (U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s)) or false
    if s.enemyAlive == false and canCrashPostKill
        and not waveUnderOwnT1 and #(s.enemyCreeps or {}) > 0 then
        local planNowPK, etaNowPK = L.PeekBestPlan(bot, s)
        local eAtk = U.MergeLists(s.enemyCreeps, s.enemyTowers)
        local aAtk = U.MergeLists(s.allyCreeps, s.allyTowers)
        -- `v7.9.1` (`9071946472.dem` `03:08` Desync Fix): When `canCrashPostKill == true`, `ResolveDenyListAndSiegeFlag`
        -- excludes allied denies (`{}`), so pass `{}` here too so an allied deny NEVER blocks shoving enemy creeps!
        local lhNow, isDeny = L.GetBestTarget(bot, s.enemyCreeps, {}, eAtk, aAtk, false)
        local imminentCS = (planNowPK ~= nil and etaNowPK <= 1.85)
            or (lhNow ~= nil and U.GetTimeToKillable(bot, lhNow, isDeny and eAtk or aAtk) <= 1.85)
        if not imminentCS and H.HandlePriorityPush(bot, s, earlyRace) then
            return
        end
    end

    -- Never let `RunSacredCS` steal our fatal swing onto a lane creep mid-duel (`9056469656.dem` `04:07.32` `U315` &
    -- `Demo 2` `7:40.87` `50 HP` melee creep mid-duel at `d = 355u` & `Demo 1` `3:55` `20 vs 11` soul brawl!)
    if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then return end
    if H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, true, false) then return end

    -- `01:35.1–01:36.5` (`tk=6288..6332` `214 HP / 9 MP`) + `2204 @ 03:05` (`188..207 HP / 65 MP` with `ec = 3`)
    -- + `2204 @ 02:20..03:49` Dominant Anti-Reaggro Wave-Shield Fix:
    --   1. Ready in-band Shadowraze on a crippled OOM enemy (`<= 265 HP`, `< 75 MP`) fires BEFORE `RunSacredCS` regardless
    --      of `#enemyCreeps` (spells do NOT pull creep aggro, whereas `RunSacredCS` otherwise kites creeps & returns `true`!).
    --   2. When dominating the lane (`U.IsLaneDominant`) and no CS/deny needs our swing within `<= 0.55s`, immediately
    --      punish & screen any weaker enemy SF stepping within `<= 665u` of our allied wave to pull creep aggro!
    if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive() then
        local myHpPre = bot:GetHealth() or 0
        local myEffPre = myHpPre + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(bot)) or 0)
        local enHpDry = s.enemy:GetHealth() or 9999
        local enMpDry = (s.enemy:GetMana() or 0) + U.GetMangoMana(s.enemy)
        local dDry = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
        local myAtkPre = K.AttackDamageVs(bot, s.enemy)
        local oneHitCreep = false
        for _, ec in pairs(s.enemyCreeps or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and (ec:GetHealth() or 999) <= (U.SFDamageRange(bot, ec).min + 12) then
                oneHitCreep = true
                break
            end
        end
        local dryFinishOk = myEffPre >= 260 and (bot:GetMana() or 0) >= 75
            and enHpDry <= 265 and enMpDry < 75 and dDry <= 965
        local ultraCritFinishOk = (#(s.enemyCreeps or {}) <= 2)
            and (enHpDry <= math.max(115, myAtkPre * 1.85))
            and dDry <= 1180
            and ((enMpDry < 75 and myEffPre >= math.max(150, K.AttackDamageVs(s.enemy, bot) * 2.55))
                or (myHpPre >= K.EnemyBurstVs(bot, s.enemy, dDry, 1.0, false) + 125 and myHpPre >= 360))
        if not oneHitCreep and (dryFinishOk or ultraCritFinishOk) then
            if H.HandlePressCriticallyLowEnemy(bot, s, earlyRace, false) then
                return
            end
        end

        if not oneHitCreep then
            local csPlanDom, csEtaDom = nil, 99
            if L.PeekBestPlan then
                csPlanDom, csEtaDom = L.PeekBestPlan(bot, s)
            end
            local csUrgentDom = (csPlanDom ~= nil) and (csEtaDom <= 0.55)
            if not csUrgentDom and H.HandleDominantAntiReaggroZone(bot, s, earlyRace, false) then
                return
            end
        end
    end

    -- Never cancel an active near-launch hero right-click (`ShouldHoldForHeroWindup`) UNLESS an enemy lane creep CS
    -- genuinely needs firing inside `<= 0.24s` (`L.PeekBestPlan` exact 30Hz check — fixes `00:55.80–01:03.27` 8x cancels)!
    if s.enemy and U.CanQuery(s.enemy) and H.ShouldHoldForHeroWindup(bot, s, s.enemy, earlyRace) then
        local csPlanHold, csEtaHold = L.PeekBestPlan(bot, s)
        local myAtkHold = K.AttackDamageVs(bot, s.enemy)
        local heroNearLethal = (s.enemy:GetHealth() or 9999) <= (myAtkHold * 2.35)
        local criticalCreepNow = (not heroNearLethal)
            and (csPlanHold ~= nil) and (not csPlanHold.isDeny) and (csEtaHold <= 0.24)
        if not criticalCreepNow then
            State.actionTaken = true
            return
        end
    end

    -- `v7.9.19` Pre-CS Empty-Wave Creep-Block Intercept (`9074666246.dem` Waves 2–21 Every-Wave Block Fix!):
    -- When `#(s.enemyCreeps or {}) == 0` (`0` contested enemy creeps!) and no allied deny is killable within `2.4s`,
    -- run `HandleMidGameIdleCreepBlock` BEFORE `RunSacredCS` so leftover allied creeps dying near Enemy T1 NEVER trap SF
    -- on the river missing the `:00`/`:30` wave block!
    if #(s.enemyCreeps or {}) == 0 then
        local planPreBlk, etaPreBlk = nil, 99
        if L.PeekBestPlan then
            planPreBlk, etaPreBlk = L.PeekBestPlan(bot, s)
        end
        if (not planPreBlk or etaPreBlk > 2.4) and H.HandleMidGameIdleCreepBlock(bot, s, earlyRace) then
            return
        end
    end

    local csRazeHook = function(ab, targetCreep, rSpot, radius, isCS, mustHitHero)
        -- Do NOT call `ManageTreads("CAST")` on the same tick right before `Action_UseAbility(ab)` (`9074513540.dem` `10:50.47` Fix):
        -- C++ only keeps one active unit order per tick, so `Action_UseAbility(ab)` overwrites `Action_UseAbility(pt)` and desyncs `U._pt.stat`!
        bot:Action_UseAbility(ab)
        H.StartRazeCast(ab, targetCreep, rSpot, radius or C.RAZE.HIT_RADIUS, isCS ~= false, mustHitHero)
        H.ClearMoveCache()
    end
    local csActed, csWaveBusy = L.RunSacredCS(bot, s, earlyRace, P, csRazeHook)
    if csActed then
        if not H.IsAtFountain(bot) and State.fountainReason ~= "POST_KILL" then
            State.goingToFountain = false
        end
        State.actionTaken = true
        return
    end

    -- Shielded Enemy T1 Siege Priority (`9056774541.dem` `01:45` + `auto-20261102-0159.dem` Fix #7):
    -- Whenever `RunSacredCS` has NO active CS/deny window right now (`not csActed`), hit enemy T1 under creep shield EVEN IF
    -- fresh full-HP enemy creeps just spawned behind T1 (`#enemyCreeps > 0`) OR the enemy hero retreated `850..1,400u` behind T1!
    if U.CanQuery(s.enemyT1) and #(s.allyCreeps or {}) >= 1 then
        local enemyBehindT1 = H.IsEnemyBehindOwnTower(bot, s.enemy, s.enemyT1:GetLocation())
            and (not (s.enemy and U.CanQuery(s.enemy)) or s.enemy:GetHealth() > U.GetNRazeDamage(bot, s.enemy, 1) + 40)
        local dominantChip = s.enemy and U.CanQuery(s.enemy)
            and (bot:GetHealth() or 0) >= math.max(700, (s.enemy:GetHealth() or 9999) + 360)
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= 640
        if (enemyBehindT1 or dominantChip) and H.HandleSiegeTower(bot, earlyRace, s) then
            State.actionTaken = true
            return
        end
    end

    -- Hold active hero windup BEFORE lower combat stages (`9056774541.dem` `03:29–03:33` `tk=13526..13628`):
    if s.enemy and U.CanQuery(s.enemy) and H.ShouldHoldForHeroWindup(bot, s, s.enemy, earlyRace) then
        return
    end

    -- Stage B0 (`v6.6.0`: Multi-Stack Combo, Mirror Counter-Raze, WarDirector Post-CS Tactical, Enemy CS-Windup Punish,
    -- `500u` Zero-Aggro Harass Trick, Stand-Ground Anti-Zoning, Dry-Enemy/Soul-Lead Harass, Retaliation, & Deward):
    local imminentCreepCS = L._imminentCS and true or false
    if H.HandleBreakEnemySalve(bot, s, earlyRace) then return end
    if H.HandleDominantAntiReaggroZone(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, false) then return end
    if H.HandleMirrorRazeCounterAndDryPunish(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleDefensiveCreepAggroPull(bot, s, earlyRace, imminentCreepCS) then return end
    if H.WarDirectorPostCS(bot, s, imminentCreepCS) then return end
    if H.HandlePressCriticallyLowEnemy(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleCreepTankDrop(bot, s) then return end

    -- Stage B: Losing trade / dry-mana / uphill-aggro disengage — MUST gate ALL right-click harass handlers below
    -- (`9069188041.dem` `02:11.8` + `9071946472.dem` `03:39–03:45` Fix: honor active `TickForcedRetreat` BEFORE poke/harass!)
    if not imminentCreepCS and H.TryInstantAdjacentTango(bot, s) then return end
    if H.InLosingHeroTrade(bot, s, earlyRace) then
        if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
    end
    if s.enemy and H.HandleDryManaMidRazeAvoidance(bot, s.enemy) then
        H.TickForcedRetreat(bot, s)
        return
    end
    if H.TickForcedRetreat(bot, s) then return end

    if H.HandleEnemyCSWindupPunish(bot, s, earlyRace, imminentCreepCS) then return end
    if not imminentCreepCS and H.HandleNightVisionAdvantagePoke(bot, s, earlyRace) then return end
    if H.HandleHighgroundZeroAggroHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleProAggroTrickHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, false, imminentCreepCS) then return end
    if H.HandleDryEnemyAndSoulLeadHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleAntiFreeHarassRetaliation(bot, s, earlyRace) then return end
    -- `v7.9.17-pro`: Punish long enemy Fountain-walk (`1507 @ 04:45–05:18` `33s` absent!) by crashing the current wave into
    -- Enemy T1 so T1 deletes our creeps before he walks back, then immediately peel back to body-block our next `:00`/`:30` wave!
    if not imminentCreepCS and DotaTime() >= 180 and s.enemyAlive ~= false
        and (s.enemyAbsentFor or 0) >= 11.5
        and not waveUnderOwnT1
        and #(s.enemyCreeps or {}) >= 1
        and (bot:GetMana() or 0) >= 210
        and (bot:GetHealth() or 0) >= 420 then
        if H.HandlePriorityPush(bot, s, earlyRace) then return end
    end
    -- `v7.9.17-pro` Recurring Every-Wave Staircase Creep-Block Hook (fires even when `1..2` leftover allied creeps from the
    -- cleared wave are still within `1,600u` walking toward Enemy T1, instead of waiting for `#s.allyCreeps == 0`!):
    if not imminentCreepCS
        and #(s.enemyCreeps or {}) == 0
        and H.HandleMidGameIdleCreepBlock(bot, s, earlyRace) then
        return
    end
    if not imminentCreepCS and H.HandlePumpFakeBait(bot, s, earlyRace) then return end
    if H.HandleFreeEnemyWardDeward(bot, s) then return end

    -- Instant `0`-tick Mango pop FIRST, then Wave-safe Static-Tree Tango (run BEFORE empty-wave `holdSpot`!)
    if H.TryBackpackAmpMango(bot, s) then return end
    if H.TryWaveSafeStaticTango(bot, s, csWaveBusy) then return end

    -- Preserve active forced/survival retreat BEFORE empty-wave holdSpot WITH Zero-Stall Arrival check!
    if H.TickForcedRetreat(bot, s) then return end
    if State.survivalLoc and GameTime() < (State.survivalUntil or 0) then
        if U.DistanceBetweenLocations(bot:GetLocation(), State.survivalLoc) <= 65 then
            if U.IsAttackingAction(bot) then
                bot:Action_ClearActions(true)
            end
            State.actionTaken = true
            return
        else
            H.SmartMove(bot, State.survivalLoc, 60)
            return
        end
    end

    -- Deep-Retreat Fountain Commitment (`auto-20261031-1939` `07:13` `(2393, 2251)` behind Dire T2 at `212/1100 HP` Fix!):
    -- When ALREADY `>= 1500u` behind Mid T1 toward Fountain at `<= 36% HP` with 0 Salve/Tango (and live non-crippled enemy),
    -- finish the short ~10s walk into Fountain aura for a FREE 100% HP/MP heal instead of wiping `goingToFountain` at `>= 105 HP`
    -- and letting empty `1600u` creep lists march SF `2,500u` back to mid at `249 HP` to die!
    H.ShouldCommitDeepFountainWalk(bot, s)
    if State.emergencyRetreat == "FOUNTAIN" and H.HandleEmergencyRetreat(bot, s.enemy) then
        return
    end

    -- Outside Fountain: never abandon mid lane on a 7,000-unit walk from the river unless critically `< max(115, 18% MaxHP)`
    -- (`0210 @ 10:40` `182/1408 HP = 12.9% HP` Scaling Fix!), committed `POST_KILL`, `EMERGENCY`, or `DEEP_LOW_HP`!
    local critFlatFloor = math.max(115, (bot:GetMaxHealth() or 600) * 0.18)
    if not H.IsAtFountain(bot) and (bot:GetHealth() or 0) >= critFlatFloor
        and State.fountainReason ~= "POST_KILL"
        and State.fountainReason ~= "DEEP_LOW_HP"
        and State.fountainReason ~= "EMERGENCY" then
        State.goingToFountain = false
    end
    if State.goingToFountain and (State.fountainReason == "DEEP_LOW_HP" or State.fountainReason == "EMERGENCY" or State.fountainReason == "HP") then
        if H.HandleFountainRecall(bot) then return end
    end

    -- Between waves (0 visible lane creeps): hold crisp mid equilibrium / T1 highground instead of walking to base —
    -- UNLESS we are actively dominating / finishing a live enemy hero right in front of us after wave clear
    -- (`9055695956.dem` `7:05` `tk=15836`: waves just died to razes at `519u` while BOT was Level 7 vs Level 5 —
    -- returning early here walked BOT `1,300u` back to `Vector(395, 405)` mid-fight instead of killing `ShaNachnetsya`!)
    -- `9070869385.dem` `04:05.8–04:06.6` (`13 HP` Uphill FoW Ramp Escape) Fix:
    -- When a 1-hit enemy hero (`<= 95 HP`) just stepped onto the enemy river ramp into highground FoW (`s.enemy == nil`,
    -- `enemyAbsentFor <= 2.4s`, `enemyLastLoc` strictly outside Enemy T1 `>= 915u`), step toward `enemyLastLoc` to
    -- regain highground vision and land the fatal attack/raze instead of walking back to `holdSpot`!
    if (not s.enemy or not U.CanQuery(s.enemy))
        and s.enemyAlive ~= false
        and (s.enemyAbsentFor or 99) <= 2.4
        and (s.enemyLastHealth or 9999) <= math.max(95, (bot:GetAttackDamage() or 60) * 1.25)
        and s.enemyLastLoc
        and (bot:GetHealth() or 0) >= 340
        and not H.TowerBurnActive()
        and GameTime() >= (State.noReenterEnemyT1Until or 0) then
        local bNow = bot:GetLocation()
        local dLast = U.DistanceBetweenLocations(bNow, s.enemyLastLoc)
        local maxFowChase = ((bot:GetMana() or 0) >= 75) and 920 or 585
        local safeFromEnT1 = (s.enemyT1Alive == false) or (not s.enemyT1Loc)
            or (U.DistanceBetweenLocations(s.enemyLastLoc, s.enemyT1Loc) >= 620)
        if dLast >= 45 and dLast <= maxFowChase and safeFromEnT1 then
            local stepLoc = s.enemyLastLoc
            if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(stepLoc, s.enemyT1Loc) < 925 then
                stepLoc = s.enemyT1Loc + (bNow - s.enemyT1Loc):Normalized() * 925
            end
            H.SmartMove(bot, stepLoc, 30)
            State.actionTaken = true
            return
        end
    end

    local enemyUnreachableUnderT1 = s.enemy and U.CanQuery(s.enemy)
        and (State.towerChaseBlockedEnemy == s.enemy
            or (s.enemyT1Alive ~= false and s.enemyT1Loc
                and U.DistanceBetweenLocations(s.enemy:GetLocation(), s.enemyT1Loc) < 520
                and #(s.allyCreeps or {}) == 0
                and (s.enemyDist or 9999) > ((bot:GetAttackRange() or 525) + 30)))
    local fightingEnemyInLane = s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
        and (not enemyUnreachableUnderT1)
        and (s.enemyDist or 9999) <= (((s.enemy:GetHealth() or 9999) <= 115 and (bot:GetHealth() or 0) >= 420) and 1320 or 1050)
        and (H.CanTwoHitRightClickKill(bot, s.enemy, s)
            or ((s.enemy:GetHealth() or 9999) <= 115 and (bot:GetHealth() or 0) >= 420)
            or (((bot:GetLevel() or 1) > (s.enemy:GetLevel() or 1)) and (bot:GetHealth() or 0) >= 620
                and not (earlyRace and earlyRace.valid and earlyRace.heCanKillSoon))
            or (earlyRace and earlyRace.valid and (earlyRace.canKillNow
                or (earlyRace.canKillSoon and not earlyRace.heCanKillSoon and (earlyRace.edge or 0) >= 40)
                or ((s.enemyDist or 9999) <= 560 and not earlyRace.heCanKillSoon and (earlyRace.edge or 0) >= 25))))
    if not fightingEnemyInLane and H.HandleMidGameIdleCreepBlock(bot, s, earlyRace) then
        return
    end
    -- `v7.9.12-pro` (`2319` Staircase Wave-Freeze Advance):
    -- MUST run BEFORE the `#s.enemyCreeps == 0 and #s.allyCreeps == 0` (`1,600u` engine cap!) `holdSpot` early return!
    if H.HandleAdvanceToDistantMidWave(bot, s, earlyRace) then
        return
    end
    if not fightingEnemyInLane and not State.emergencyRetreat and not State.goingToFountain
        and #(s.enemyCreeps or {}) == 0 and #(s.allyCreeps or {}) == 0
        and not s.hasDistantMidWaveClash
        and (bot:GetHealth() or 0) >= critFlatFloor then
        if H.TrySafeTreadsSwitch(bot, nil) then return end
        local curHpPctHold = (bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 600)
        local holdSpot
        if s.enemyAlive ~= false and curHpPctHold <= 0.28 and not U.HasAnyHealing(bot) then
            holdSpot = (P.GetBehindT1 and P.GetBehindT1(bot, 380)) or P.GetLasthitPosition(bot, {}, {}, nil, "NEUTRAL")
        else
            holdSpot = P.GetLasthitPosition(bot, {}, {}, nil, "NEUTRAL")
        end
        if holdSpot and U.DistanceBetweenLocations(bot:GetLocation(), holdSpot) > 55 then
            H.SmartMove(bot, holdSpot, 45)
        end
        State.actionTaken = true
        return
    end

    if H.HandleSurvivalRetreat(bot, s.enemy, earlyRace) then return end

    if H.HandleShortCombatCast(bot,s.enemy,s) then return end
    if H.HandleSafeRazeReply(bot,s.enemy,s) then return end
    if H.HandleReplyFarFollowup(bot,s.enemy,s) then return end
    if H.HandleManaCycleContinuation(bot,s.enemy,s) then return end
    if H.HandleContactTrade(bot,s.enemy,s) then return end
    -- Free pressure: both handlers veto themselves in every risky or busy situation
    -- (retreat, fountain, low HP, tower, lethal burst, imminent last hit, aimed raze).
    if H.HandleFreeRazeAnswer(bot,s,earlyRace,true) then return end
    if H.HandleFreeRightClick(bot,s,earlyRace) then return end

    -- A committed retreat owns the tick WITH Zero-Stall Arrival check!
    if H.TickForcedRetreat(bot, s) then return end

    if (bot:GetHealth() or 0) < critFlatFloor and H.HandleSurvivalRetreat(bot, s.enemy, earlyRace) then return end
    if H.HandleSeekAlliedWave(bot, s, earlyRace) then return end
    if (not csWaveBusy or s.enemyAlive == false) and H.HandlePriorityPush(bot, s, earlyRace) then return end
    if H.UpdateTowerChase(bot, s) then return end
    local stackChaseSafe = not (earlyRace and earlyRace.valid
        and (earlyRace.losingHard or earlyRace.heHasBootsLead or ((s.enemy and s.enemy:GetLevel() or 1) > (bot:GetLevel() or 1))))
        and (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.55
    if stackChaseSafe and H.HandleStackLead(bot, s, earlyRace) then return end
    H.UpdateDefensive(bot, s, earlyRace)
    State.enemyAggroCount = 0
    for _, creep in pairs(s.allyCreeps or {}) do
        if s.enemy and U.CanQuery(creep) and creep:GetAttackTarget() == s.enemy then
            State.enemyAggroCount = State.enemyAggroCount + 1
        end
    end
    State.combatPolicyActive = true
    local xchAllowsVoluntaryEngage = GameTime() >= (WD.State.refuseTradeUntil or -100)
    State.heroCombatAllowed = State.towerChaseBlockedEnemy ~= s.enemy
        and ((xchAllowsVoluntaryEngage and H.ShouldEngageHero(bot, s.enemy, earlyRace))
            or H.IsEnemyPressuring(bot, s.enemy)
            or (earlyRace.valid and earlyRace.canKillNow))
    if H.HandleIncomingHeroPressure(bot, s, earlyRace) then return end
    if State.heroCombatAllowed and not State.goingToFountain
        and GameTime() >= (State.fleeUntil or 0) then
        local previous = State.intent
        State.intent = I.TRADE
        local acted = H.RunCombatPriority(bot, s, earlyRace)
        State.intent = previous
        if acted then return end
    end

    if H.HandleActiveRazeValidation(bot) then return end

    -- A guaranteed finish comes before dodging and everything else: if we can kill
    -- him with a raze/click right now - kill immediately, do not postpone it for seconds
    if s.enemy then
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end

    -- Dodging the enemy raze outranks even our own cast (if the raze is lethal)
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end

    if bot:IsUsingAbility() then return end

    H.ProcessTelemetry(bot)

    -- Power Treads are handled by H.ManageTreads - on an idle tick (end of RealThink),
    -- on the first retreat tick (strength) and on the tick before a raze cast (intelligence). The old call
    -- here issued a switch order EVERY tick and overrode the combat orders.

    local enemyHero = s.enemy

    -- The race (absolute HP, razes available to both sides) and the intent for the tick
    local race = earlyRace
    local intent = H.UpdateIntent(bot, s, race)

    -- A swing at the hero is in progress - let it land (see ShouldHoldForHeroWindup)
    H.UpdateAttackActivity(bot)
    if enemyHero and H.ShouldHoldForHeroWindup(bot, s, enemyHero, race) then
        State.actionTaken = true
        return
    end

    -- Emergency consumables (faerie/wand/mango for a finish) - right after the swing,
    -- before salves and retreats
    if H.HandleEmergencyConsumables(bot, race) then return end

    if H.HandleActiveSalveSafety(bot, enemyHero) then return end
    if H.HandleEnemyNearRazeCounter(bot, enemyHero) then return end
    if enemyHero and H.HandleInstantMirrorRaze(bot, enemyHero, race, s) then return end

    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
    end
    if enemyHero and U.CanQuery(enemyHero) and U.EnemyHasRaze(enemyHero) then
        if bot:GetLevel() < 2 and enemyHero:GetLevel() >= 2 then
            State.enemyReachedLevel2First = true
        end
    end

    -- (Guaranteed finishes moved up - before dodging and the swing)
    if H.HandleReturnTP(bot) then return end

    -- Defence against the enemy T1 - before everything else
    if H.HandleEnemyTowerSafety(bot, s, enemyHero) then return end

    -- The enemy T1 is nearly down - finish it before any retreat or last hit
    if H.HandleEnemyTowerFinish(bot, s, enemyHero) then return end

    if H.HandleEmergencyRetreat(bot, enemyHero) then return end

    -- RETREAT intent: get out of the enemy's ready bands (his available burst is lethal)
    if intent == I.RETREAT and enemyHero then
        if H.ExecuteRetreat(bot, enemyHero, race) then return end
    end

    if H.HandleForcedSalve(bot) then return end
    if H.HandleFountainRecall(bot) then return end

    -- The intent is still RETREAT but we are already at a safe distance (ExecuteRetreat
    -- returned false). Previously control fell through to last hits/prehit - those turned
    -- the bot toward the creep pack, the enemy caught up, run again - a crooked zigzag instead of leaving.
    -- Keep a clean step straight away from the enemy while he is near.
    if intent == I.RETREAT and enemyHero and U.CanQuery(enemyHero) and not State.actionTaken then
        local bLoc, eLoc = bot:GetLocation(), enemyHero:GetLocation()
        local d = U.DistanceBetweenLocations(bLoc, eLoc)
        if d < 1100 and d >= 1 then
            H.SmartMove(bot, bLoc + (bLoc - eLoc):Normalized() * 160, 60)
            return
        end
    end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local mpPct = bot:GetMana() / bot:GetMaxMana()
    local flask = U.GetActiveItemByName(bot, "item_flask")
    local clarity = U.GetActiveItemByName(bot, "item_clarity")
    local hasMango = U.HasItem(bot, "item_enchanted_mango")
    local isHealing = bot:HasModifier("modifier_flask_healing")
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50

    if bot:HasModifier("modifier_clarity_potion") and not bot:HasModifier("modifier_flask_healing") and myHpPct >= returnHpPct then
        H.ClearForcedRetreat()
    end

    -- `H.HandleProactiveAndActiveSalve` and `H.HandleProactiveAndActiveClarity` now govern 100% of Salve/Clarity usage & protection!
    local needsFlask = false
    local needsClarity = false

    if isHealing or needsFlask or needsClarity then
        local fountain = P.GetFountain(bot)
        local dangerRange = 850
        if enemyHero and enemyHero:GetUnitName() == "npc_dota_hero_nevermore" then
            if bot:HasModifier("modifier_flask_healing") or needsFlask then
                dangerRange = C.REGEN.FLASK_SAFE_DISTANCE or 1150
            else
                dangerRange = C.REGEN.ENEMY_SAFE_DISTANCE or 1100
            end
        end
        if H.IsInDangerForRegen(bot, dangerRange) then
            local moveLoc = P.GetT1Close(bot)
            if enemyHero then
                local dir = (fountain - enemyHero:GetLocation()):Normalized()
                moveLoc = enemyHero:GetLocation() + dir * dangerRange
            end
            H.BeginForcedRetreat(bot, moveLoc, 0.85)
            return
        end
        if needsFlask and GameTime() > State.lastItemUseTime + 0.3 then
            if H.HasEnemyProjectileIncoming(bot) then
                local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
                H.BeginForcedRetreat(bot, safeLoc, 0.65)
                return
            end
            bot:Action_UseAbilityOnEntity(flask, bot)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return
        elseif needsClarity and GameTime() > State.lastItemUseTime + 0.3 then
            bot:Action_UseAbilityOnEntity(clarity, bot)
            State.lastItemUseTime = GameTime()
            return
        elseif isHealing then
            -- Lists from the world snapshot (filtered through CanQuery - no creeps in fog)
            local enemyCreepsNearby = s.enemyCreeps or {}
            local allyCreepsNearby = s.allyCreeps or {}
            if #allyCreepsNearby == 0 then
                local targetPos = P.GetT1Close(bot)
                if GetUnitToLocationDistance(bot, targetPos) > 45 then
                    H.SmartMove(bot, targetPos, 60)
                end
            elseif bot:HasModifier("modifier_flask_healing") then
                local safeLoc = P.GetLasthitPosition(bot, enemyCreepsNearby, allyCreepsNearby, nil, "PASSIVE")
                if enemyHero and U.CanQuery(enemyHero) then
                    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
                    if distToEnemy < dangerRange then
                        local dir = (fountain - enemyHero:GetLocation()):Normalized()
                        safeLoc = enemyHero:GetLocation() + dir * dangerRange
                    end
                end
                if not H.IsInDangerForRegen(bot, dangerRange) then
                    H.SmartMove(bot, safeLoc, 60)
                end
            end
            if State.actionTaken or #allyCreepsNearby == 0 or bot:HasModifier("modifier_flask_healing") then return end
        end
    end

    local enemyCreeps = s.enemyCreeps
    local allyCreeps = s.allyCreeps
    local enemyTowers = s.enemyTowers
    local allyTowers = s.allyTowers
    local enemyAttackers = U.MergeLists(enemyCreeps, enemyTowers)
    local allyAttackers = U.MergeLists(allyCreeps, allyTowers)
    -- The enemy hero also hits creeps (finishes his own = deny, finishes mine). His attack
    -- is accounted for in the target HP forecast (GetAttackTarget() == target): the "safe" last-hit window
    -- closes with his attack -> hit earlier/immediately instead of waiting for a moment he takes.
    if enemyHero and U.CanQuery(enemyHero) then
        table.insert(enemyAttackers, enemyHero)
        table.insert(allyAttackers, enemyHero)
    end
    local enemyNearWave = enemyHero ~= nil and s.enemyDist <= 1300

    U.UpdateAllyCreepHealthTracking(allyCreeps)


    local current_mode = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    if State.defensive then current_mode = "PASSIVE" end
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local enemyMissedAggro = enemyMissed and bot:GetLevel() > 1
    if bot:GetLevel() <= 1 and enemyMissed and current_mode == "AGGRESSIVE" then
        current_mode = "NEUTRAL"
    end

    if H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then return end
    if H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps) then return end

    local inKillThreat = U.IsInEnemyRazeKillThreat(bot, enemyHero)
    local secondStackActive, secondStackLabel = false, nil
    if enemyHero then
        secondStackActive, secondStackLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    end

    if enemyHero and secondStackActive and secondStackLabel == "near" then
        if H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if inKillThreat then
        if H.HandleSafeDistanceFromEnemy(bot, enemyHero) then return end
    end

    U._midFear = (enemyHero ~= nil) and H.MidRazeFearActive(bot, enemyHero) or false
    if enemyHero and H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero) then return end
    if enemyHero and H.HandleDryManaMidRazeAvoidance(bot, enemyHero) then return end

    -- Stacks on us: the decision is based on the enemy's available burst and absolute HP (not "2 stacks = run").
    -- If his razes are on cooldown / out of mana / the band is out of reach - keep pressing.
    if enemyHero then
        local shouldFear, fearLoc = U.ShouldRetreatFromEnemyRazeStack(bot, enemyHero)
        if shouldFear and fearLoc then
            H.BeginForcedRetreat(bot, fearLoc, 0.80)
            return
        end
    end

    if enemyHero and H.HandleBootDisadvantageMidRazeFear(bot, enemyHero) then return end

    local mustRetreatFromT1Soon = U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not mustRetreatFromT1Soon and s.enemyT1 then
        -- The shield is gone (creeps ran off after the enemy / died) and we are still inside the tower radius
        local okLoc, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, bot:GetLocation()) <= ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) then
            if LN.TowerDanger(bot, s.enemyT1, allyCreeps, nil) >= 2 then
                mustRetreatFromT1Soon = true
            end
        end
    end
    if mustRetreatFromT1Soon and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
        and not (s.enemyT1 and LN.IsTowerFinishable(bot, s.enemyT1)) then
        -- Do NOT spend the glyph just to get out of the tower (an accidental entry into the T1 radius without a finish
        -- burned the glyph for 5 minutes) - just walk out
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    if enemyHero and not inKillThreat then
        if H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and H.GetPotentialCombatMana(bot) >= 150 and not inKillThreat then
        local q = bot:GetAbilityByName("nevermore_shadowraze1")
        if q and q:GetLevel() > 0 then
            local dmg2 = U.GetTwoRazeDamage(bot, enemyHero)
            local lethal = dmg2 >= enemyHero:GetHealth()
            local Rr = K._race
            if Rr and Rr.valid then
                -- Only razes that are REALLY available (cooldowns/mana), not "two razes by formula"
                lethal = Rr.canKillSoon
            end
            if intent == I.RETREAT then lethal = false end
            if lethal then
                local myBoots = U.HasItem(bot, "item_boots") or U.HasItem(bot, "item_power_treads")
                local eBoots = U.HasItem(enemyHero, "item_boots") or U.HasItem(enemyHero, "item_power_treads")
                local canChase = myBoots and not eBoots
                local chaseTargetLoc = enemyHero:GetLocation()
                local isSafeChase = true
                for _, tower in pairs(enemyTowers) do
                    if tower:IsAlive() then
                        local name = tower:GetUnitName() or ""
                        if name:find("tower2") or name:find("tower3") or name:find("tower4") then
                            if GetUnitToLocationDistance(tower, chaseTargetLoc) < 850 then
                                isSafeChase = false
                                break
                            end
                        end
                    end
                end
                local glyphActive = State.glyphUsedForDive and (GameTime() - State.glyphDiveTime) < 5.0
                local normalSafe = (H.GetSafeApproachLoose(bot, chaseTargetLoc, enemyTowers, allyCreeps) == chaseTargetLoc)
                -- His T1 is busy with our creep (>= 2 shots), HP >= 50%, his burst is not lethal:
                -- razes under the tower give no aggro - the finish is allowed
                local towerLockedSafe = isSafeChase and H.TowerLockedOnCreep(s.enemyT1)
                    and myHpPct >= 0.5 and not (Rr and Rr.valid and Rr.heCanKillSoon)
                    and not H.TowerBurnActive()
                if (canChase and isSafeChase) or normalSafe or glyphActive or towerLockedSafe then
                    if H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, true, false) then
                        return
                    end
                end
            end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreeps, enemyCreeps) then return end
    end

    if enemyHero and not inKillThreat and secondStackActive then
        if secondStackLabel == "mid" then
            if H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        elseif secondStackLabel == "near" then
            if H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    local ward = U.GetActiveItemByName(bot, "item_ward_observer")
    if ward and not H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then
        local wardLoc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
        local distToWard = GetUnitToLocationDistance(bot, wardLoc)
        if distToWard > 450 then
            H.SmartMove(bot, wardLoc, 60)
        else
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            H.ClearMoveCache()
        end
        return
    end

    local aggroCount = 0
    local closeCreepsCount = 0
    local hasRangedAggro = false
    local is_taking_damage = bot:WasRecentlyDamagedByCreep(1.5)
    -- How many of MY creeps are hitting the enemy hero (support in the trade)
    local enemyAggroCount = 0
    if enemyHero and U.CanQuery(enemyHero) then
        for _, c in pairs(allyCreeps) do
            if U.CanQuery(c) and c:GetAttackTarget() == enemyHero then enemyAggroCount = enemyAggroCount + 1 end
        end
    end
    State.enemyAggroCount = enemyAggroCount
    for _, c in pairs(enemyCreeps) do
        if c:IsAlive() then
            if U.CanQuery(c) and c:GetAttackTarget() == bot then
                aggroCount = aggroCount + 1
                local name = c:GetUnitName() or ""
                if name:find("ranged") or name:find("siege") then hasRangedAggro = true end
            end
            if GetUnitToLocationDistance(bot, c:GetLocation()) < 350 then
                closeCreepsCount = closeCreepsCount + 1
            end
        end
    end

    if U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero) then
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    local is_under_my_tower = false
    for _, t in pairs(allyTowers) do
        if GetUnitToLocationDistance(bot, t:GetLocation()) < 850 then
            is_under_my_tower = true
            break
        end
    end

    if not csWaveBusy and GameTime() > State.deaggroTime and GameTime() >= (State.myCreepChaseUntil or 0) then
        local should_deaggro = false
        if allyCreeps and #allyCreeps > 0 then
            -- Drop aggro only when the creeps are REALLY hitting us (>= 2 creeps, or 1 + damage, or
            -- a ranged + damage). The old condition "2 enemy creeps closer than 350" triggered on any
            -- last hit near the wave: CLEAR + "attack own creep" + a 400 back-off every 1.2 s ->
            -- lost last hits and twitching toward the tower.
            if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) or (hasRangedAggro and is_taking_damage) then
                should_deaggro = true
            end
        else
            if is_under_my_tower and bot:GetHealth() > 300 then
                if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) then
                    should_deaggro = true
                end
            else
                if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) or hasRangedAggro then
                    should_deaggro = true
                end
            end
        end
        -- Suppress deaggro `400u` backward flee when healthy (`> 320 HP`) and either:
        --   (a) a creep is dying right now (`hp <= 155`), OR
        --   (b) we are executing a winning hero finish (`enHp <= 340` / `canKillSoon`)!
        if should_deaggro and (bot:GetHealth() or 0) > 320 then
            local R = K._race
            if enemyHero and U.CanQuery(enemyHero) and (
                (enemyHero:GetHealth() or 9999) <= 340
                or (R and R.valid and not R.heCanKillSoon and (R.canKillNow or R.canKillSoon or (R.edge or 0) >= 95))
            ) then
                should_deaggro = false
            end
            if should_deaggro then
                for _, c in pairs(enemyCreeps or {}) do
                    if c and c:IsAlive() and c:GetHealth() <= 155 then
                        should_deaggro = false
                        break
                    end
                end
            end
        end
        if should_deaggro then
            bot:Action_ClearActions(false)
            H.ClearMoveCache()
            State.heroAttackTarget = nil
            State.heroAttackTime = 0
            local fountain = P.GetFountain(bot)
            local safeCloseAlly, safeFbAlly = H.FindSafeDeaggroAllyCreep(bot, allyCreeps, enemyHero)
            local chosenSafeAlly = safeCloseAlly or safeFbAlly
            if chosenSafeAlly then
                local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 400
                if bot.ActionQueue_AttackUnit and bot.ActionQueue_MoveToLocation then
                    bot:ActionQueue_AttackUnit(chosenSafeAlly, true)
                    bot:ActionQueue_MoveToLocation(safe_pos)
                else
                    bot:Action_AttackUnit(chosenSafeAlly, true)
                end
                State.deaggroTime = GameTime() + 1.2
            else
                local kite_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 300
                bot:Action_MoveToLocation(kite_pos)
                State.deaggroTime = GameTime() + 0.6
            end
            return
        end
    end

    if GameTime() < State.aggroPullTime then
        if H.IsHeroAttackWindupLocked(bot) then return end
        if H.IsInHeroAttackAnimation(bot) then return end
        H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
        return
    end

    local bestTarget, isDeny = L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    -- Do not take a last hit that requires entering his ready band in a bad trade:
    -- otherwise it is an endless "approach for the creep - get scared - back off", and every approach is his raze on us.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) then
        local fearMin = U.GetFearMinDist(bot, enemyHero)
        if fearMin > 0 then
            local eLoc = enemyHero:GetLocation()
            local cLoc = bestTarget:GetLocation()
            local botD = U.DistanceBetweenLocations(bot:GetLocation(), eLoc)
            local inRangeNow = GetUnitToLocationDistance(bot, cLoc) <= bot:GetAttackRange() + 20
            local creepD = U.DistanceBetweenLocations(cLoc, eLoc)
            if not (inRangeNow and botD >= fearMin - 40) and creepD < fearMin - bot:GetAttackRange() + 40 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Do not walk for a creep into a point where his available burst (ready bands + right clicks)
    -- kills me: otherwise "approached for the creep -> became lethal -> RETREAT for 1 s -> came back"
    -- in a loop every 2-3 s (twitching). Take only what is reachable from a non-lethal distance.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) and race.valid and not race.canKillNow then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        local atkD = U.DistanceBetweenLocations(atkPos, eLoc)
        local curD = U.DistanceBetweenLocations(bLoc, eLoc)
        if atkD < curD - 30 then
            local burst = K.EnemyBurstVs(bot, enemyHero, atkD, 2.5, false)
            if burst >= bot:GetHealth() - 20 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Defence (clearly weaker, no creep/tower support): do not enter his attack
    -- radius for a last hit - every entry is 1-2 of his hits (70+ per hit with 20 souls and bracers), a creep
    -- is not worth that. Take only what is reachable from outside his radius, or while he is busy with the wave.
    local myHpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if bestTarget and enemyHero and State.defensive and race.valid and race.weakerSustained
        and U.CanQuery(enemyHero) and not H.HasTradeSupport(race) then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local hisReach = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.CONTEST_PAD) or 80)
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        -- Skip a creep only if it is really pressuring us (hitting us / hit us in the last
        -- 3 s) or we are low with his raze ready. Merely "standing by the wave" is no reason to give up
        -- all the farm: previously a weaker bot with that rule took not a single creep.
        local pressing = false
        if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then pressing = true end
        if not pressing and bot.WasRecentlyDamagedByHero then
            pressing = bot:WasRecentlyDamagedByHero(enemyHero, 3.0) and true or false
        end
        if not pressing and myHpPctNow <= 0.45 and (race.enRazesSoon or 0) >= 1 then
            pressing = true
        end
        if pressing and U.DistanceBetweenLocations(atkPos, eLoc) <= hisReach and not LN.EnemyBusyWithWave(bot, enemyHero) then
            bestTarget, isDeny = nil, false
        end
    end
    local bestTargetTime = 999
    if bestTarget then
        bestTargetTime = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
    end
    local lasthitImminent = bestTarget ~= nil and bestTargetTime >= 0 and bestTargetTime <= 1.2

    local am_i_tanking_too_much = false
    if not allyCreeps or #allyCreeps == 0 then
        if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) then am_i_tanking_too_much = true end
    else
        if aggroCount >= 3 or (aggroCount >= 2 and bot:GetHealth() < 400) then am_i_tanking_too_much = true end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then
        if aggroCount <= 1 then am_i_tanking_too_much = false end
    end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            local fountain = P.GetFountain(bot)
            local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 250
            H.SmartMove(bot, safe_pos, 60)
            return
        end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then am_i_tanking_too_much = false end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
            return
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        if H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and U.IsEnemyHighValueRegen(enemyHero) then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if bot:GetMana() >= 75 and distToEnemy <= 1100 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
        local attackRange = bot:GetAttackRange() + 60
        if distToEnemy <= attackRange then
            if myHpPct > 0.30 and H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
                if H.IssueHeroAttack(bot, enemyHero) then
                    State.lastHarassTime = GameTime()
                    State.lastAggroTime = GameTime()
                    State.aggroPullTime = GameTime() + 0.25
                    return
                end
            end
        elseif distToEnemy <= C.HARASS.INTERRUPT_APPROACH and myHpPct > 0.40 and H.GetPotentialCombatMana(bot) >= 75 then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local approachLoc = botLoc + dir * math.min(distToEnemy - attackRange + 50, 400)
            approachLoc = U.ClampMinDistFromEnemy(bot, enemyHero, approachLoc)
            if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
        -- Extending 2 stacks is a combo continuation: allowed with a favourable trade or by the mana reserve
        local extendOk = (race.valid and race.edge >= 0 and bot:GetMana() >= 75) or H.HarassManaOK(bot, race)
        if eStacks >= 2 and eRem <= C.RAZE.EXTEND_AT + 0.6 and extendOk and not State.defensive then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and enemyMissedAggro
        and H.HarassManaOK(bot, race) and not State.defensive then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if distToEnemy <= 950 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    -- ZONE: keep the enemy away from our wave (or hold River-Wave Enemy-T1 Choke even when he backs into FoW!)
    if intent == I.ZONE and not lasthitImminent and not am_i_tanking_too_much and not inKillThreat then
        if H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers) then return end
    end

    if H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero) then return end

    -- prepTarget (the creep for a "pre-hit") was NEVER reset (except by ForceExtend):
    -- after the first pre-hit, harass, push and the pre-hit itself were disabled forever while the dead handle
    -- was queried every tick. Reset when: the target is dead/invisible, the hit landed, or > 2.5 s passed.
    if State.prepTarget then
        local pt = State.prepTarget
        local age = GameTime() - (State.prepTargetTime or 0)
        if not U.CanQuery(pt) or age > 2.5
            or (not U.IsAttackingAction(bot) and age > 0.6) then
            State.prepTarget = nil
            State.prepTargetTime = 0
        end
    end

    -- The enemy projectile is already flying at the creep, his hit is not enough to finish it, and after
    -- it lands the creep becomes mine - send our attack RIGHT AFTER his projectile.
    if H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps) then return end

    local is_free_to_prehit = true
    if bestTarget then
        local t_killable = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
        if t_killable < (bot:GetSecondsPerAttack() + 0.3) then is_free_to_prehit = false end
    end

    local prehit_target = nil
    if is_free_to_prehit and not State.prepTarget and not am_i_tanking_too_much then
        local attack_cd = bot:GetSecondsPerAttack()
        for _, c in pairs(enemyCreeps) do
            if U.CanQuery(c) then
                local in_tower_range = false
                for _, t in pairs(allyTowers) do
                    if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                        in_tower_range = true
                        break
                    end
                end
                -- "HP shaping": the pre-hit is allowed outside our own tower too if the enemy cannot
                -- punish it (far from the creep / busy with the wave / no ready razes) and we are not under his T1.
                local prehit_ok = in_tower_range
                if not prehit_ok and (C.LASTHIT.PREHIT_ANYWHERE ~= false) and not inKillThreat and not State.defensive then
                    local eFar = true
                    if enemyHero and U.CanQuery(enemyHero) then
                        local dce = U.DistanceBetweenLocations(c:GetLocation(), enemyHero:GetLocation())
                        local R = K._race
                        eFar = dce > 850 or LN.EnemyBusyWithWave(bot, enemyHero) or (R and R.valid and R.enRazesSoon == 0)
                    end
                    local underEnemyTower = false
                    for _, t in pairs(enemyTowers) do
                        if t:IsAlive() and GetUnitToLocationDistance(t, c:GetLocation()) < 800 then underEnemyTower = true break end
                    end
                    prehit_ok = eFar and not underEnemyTower
                end
                if prehit_ok then
                    local myDmg = U.SFDamageRange(bot, c).min
                    local hp = c:GetHealth()
                    if hp > (myDmg * 1.5) then
                        local ctx_normal = U.GetTargetPredictionContext(c, allyAttackers)
                        if not U.HasLasthitWindow(ctx_normal, c, myDmg, 0) then
                            local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                            if U.HasLasthitWindow(ctx_prehit, c, myDmg, attack_cd) then
                                prehit_target = c
                                break
                            end
                        end
                    end
                end
            end
        end

        if not prehit_target then
            for _, c in pairs(allyCreeps) do
                if c:IsAlive() and (c:GetHealth() / c:GetMaxHealth()) < 0.5 then
                    local in_enemy_tower_range = false
                    for _, t in pairs(enemyTowers) do
                        if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                            in_enemy_tower_range = true
                            break
                        end
                    end
                    if in_enemy_tower_range then
                        local eSF = enemyHero
                        local eDmg = eSF and U.CanQuery(eSF) and eSF:GetAttackDamage() or U.SFDamageRange(bot, c).min
                        local myDmg = U.SFDamageRange(bot, c).min
                        local hp = c:GetHealth()
                        if hp > myDmg then
                            local ctx_normal = U.GetTargetPredictionContext(c, enemyAttackers)
                            if U.HasLasthitWindow(ctx_normal, c, eDmg, 0) then
                                local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                                if not U.HasLasthitWindow(ctx_prehit, c, eDmg, 0) then
                                    prehit_target = c
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if prehit_target then
            local tower_proj_flying = false
            local projs = U.SafeGetIncomingProjectiles(prehit_target)
            if projs then
                for _, p in pairs(projs) do
                    if p.is_attack and p.caster and p.caster:IsTower() then
                        tower_proj_flying = true
                        break
                    end
                end
            end
            if not tower_proj_flying then
                State.prepTarget = prehit_target
                State.prepTargetTime = GameTime()
                if H.IsSafeToAttack(bot, prehit_target:GetLocation(), enemyTowers, allyCreeps) then
                    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= prehit_target then
                        -- ONE attack (previously a continuous attack: the second hit cut the creep into the zone
                        -- where our own creeps finished it)
                        bot:Action_AttackUnit(prehit_target, true)
                        H.ClearMoveCache()
                    end
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, bot:GetLocation(), enemyTowers, allyCreeps), 60)
                end
                return
            end
        end
    end

    -- Finishing a stack on the enemy does not wait for the 1.9 s "free window" before a last hit: the cast is 0.55 s,
    -- we only yield to a last hit that must be taken within the next 0.7 s.
    -- A stack-finishing raze outranks a last hit when the last hit is not "right now" (<= 0.45 s):
    -- a raze on a stacked hero (~120-160 damage + stack extension) is worth more than one creep
    local followUpNow = enemyHero and H.IsRazeFollowUp(bot, enemyHero) and (bestTargetTime < 0 or bestTargetTime > 0.45)
    -- Hunting (State.hunting) outranks the last hit and is not blocked by a stack on us (his burst on us
    -- was already checked in ComputeHunt with the stack taken into account)
    local hunting = (State.hunting and enemyHero ~= nil) or false
    -- The enemy walked up close and we have mana for two razes - the trade beats waiting for the
    -- last hit (previously is_free_to_prehit = false here and the bot silently stood by the creep)
    local punishWindow = enemyHero ~= nil
        and (s.enemyDist <= ((C.RAZE and C.RAZE.PUNISH_CLOSE_RANGE) or 520))
        and H.GetPotentialCombatMana(bot) >= ((C.RAZE and C.RAZE.PUNISH_MIN_POT_MANA) or 150)
    local allowHarass = (is_free_to_prehit or enemyMissedAggro or followUpNow or hunting or punishWindow) and not State.prepTarget and not inKillThreat and (not secondStackActive or hunting or punishWindow)
    -- "Stack finish only" window (a last hit in 0.45-1.9 s): only razes are allowed (0.55 s cast),
    -- while a right click on the hero (0.5 s swing + 1.6 s cooldown) would cost the last hit.
    local razeOnlyWindow = followUpNow and not (is_free_to_prehit or enemyMissedAggro or hunting)
    -- No aggression under RETREAT; under FARM - no closing on the enemy (only if he came to us)
    if intent == I.RETREAT then allowHarass = false end
    local allowApproach = (intent == I.TRADE or intent == I.ALLIN)
    
    if H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps) then return end

    if allowHarass and enemyHero then
        local canRazePressure, razeMode = H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
        if canRazePressure then
            if H.TryRazeEnemy(bot, enemyHero, razeMode, enemyTowers, allyCreeps, false, false) then return end
        end
        if razeOnlyWindow then
            -- The stack finish did not work (no coverage/mana) - go back to the last hit
        elseif H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps) then
            if H.IssueHeroAttack(bot, enemyHero) then
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return
            end
        end

        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local approachThreshold = H.GetEnemyApproachDistance(enemyMissedAggro)
        local minHpPct = enemyMissedAggro and C.HARASS.MIN_HP_PCT_MISS or C.HARASS.MIN_HP_PCT
        local effectiveMode = enemyMissedAggro and "AGGRESSIVE" or current_mode
        if hunting then
            approachThreshold = (C.INTENT and C.INTENT.HUNT_MAX_DIST or 1100) + 150
            minHpPct = (C.INTENT and C.INTENT.HUNT_MIN_HP_PCT) or 0.40
            effectiveMode = "AGGRESSIVE"
        end
        if allowApproach and not razeOnlyWindow
            and (effectiveMode == "AGGRESSIVE" or (effectiveMode == "NEUTRAL" and enemyMissedAggro))
            and aggroCount <= 1
            and myHpPct >= minHpPct
            and dist > bot:GetAttackRange() + 50
            and dist < approachThreshold then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local stepIn = math.min(dist - bot:GetAttackRange() + 30, 350)
            local rawApproach = botLoc + dir * stepIn
            local futureDist = U.DistanceBetweenLocations(rawApproach, enemyHero:GetLocation())
            local fearMidBlock = U.ShouldFearBootsMidRaze(bot, enemyHero) and math.abs(futureDist - C.RAZE.MID_CENTER) <= 220
            if not fearMidBlock then
                local rawApproachClamped = U.ClampMinDistFromEnemy(bot, enemyHero, rawApproach)
                -- `auto-20261102-0139` `0:48..0:52` Fix: when `ClampMinDistFromEnemy` rejects stepping closer to `enemyHero`,
                -- skip `ApproachEnemyPoint` WITHOUT early `return` so `GetLasthitPosition` below still positions SF at the wave!
                if U.DistanceBetweenLocations(rawApproachClamped, enemyHero:GetLocation()) < dist - 20 then
                    if H.ApproachEnemyPoint(bot, enemyHero, rawApproachClamped, 60, enemyTowers, allyCreeps) then
                        return
                    end
                end
            end
        end
    end

    local isAttacking = U.IsAttackingAction(bot)
    local target = bot:GetAttackTarget()
    -- The target went into fog/died: it must not be queried (otherwise "[Developer] ... cannot be seen" every tick)
    if isAttacking and target and not U.CanQuery(target) then
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
        isAttacking = false
        target = nil
    end
    local lhFallThrough = false
    if isAttacking and target and State.lhAttackTarget==target and not (target.IsHero and target:IsHero()) then
        local last=bot:GetLastAttackTime() or -100
        local released=false
        if State.attackTarget==target and State.attackStartTime>0
            and last>State.attackStartTime+0.01 and last<=GameTime() then
            for _,projectile in pairs(U.SafeGetIncomingProjectiles(target)) do
                if projectile.is_attack and projectile.caster==bot then released=true;break end
            end
        end
        local waitingForCooldown=bestTarget and bestTarget~=target and last>0
            and last<State.attackStartTime
            and last+bot:GetSecondsPerAttack()-GameTime()>(bot:GetAttackPoint() or 0.5)+0.08
        if released or waitingForCooldown then
            State.lhAttackTarget=nil;State.prepTarget=nil;State.attackTarget=nil
            State.attackStartTime=0;State.firedThisAttack=false
            lhFallThrough=true
        end
    end
    if isAttacking and target and not lhFallThrough then
        if State.attackTarget ~= target then
            State.attackTarget = target
            State.attackStartTime = GameTime()
            State.firedThisAttack = false
        end
        if State.prepTarget == target then return end
        local targetIsHero = target.IsHero and target:IsHero()
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        if targetIsHero then return end
        -- The attack is not a "last hit" (push/clearing the wave): the cancel logic does not apply to it - previously
        -- it cancelled EVERY such attack 0.08 s before the attack point (the creep was "too alive") and the bot
        -- twitched endlessly without dealing damage. If a real last hit ripens meanwhile - yield to it.
        if State.lhAttackTarget ~= target then
            if target == bestTarget then
                -- A continuous (push) attack on a creep that became a last-hit candidate:
                -- if it is killable right now - let the attack land; otherwise stop attacking,
                -- the last-hit logic below takes over the timing
                if bestTargetTime <= 0.05 then return end
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
                isAttacking = false
                target = nil
                lhFallThrough = true
            elseif bestTarget and bestTargetTime >= 0 and bestTargetTime <= (bot:GetSecondsPerAttack() + 0.4) then
                lhFallThrough = true
            else
                return
            end
        end
    end
    if isAttacking and target and not lhFallThrough then
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        local dist = GetUnitToLocationDistance(bot, target:GetLocation())
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local impact_time = remaining_windup + (dist / projSpeed)
        local isAlly = (target:GetTeam() == bot:GetTeam())
        local attackers = isAlly and enemyAttackers or allyAttackers
        local ctx = U.GetTargetPredictionContext(target, attackers)
        local predHP = U.PredictHPWithContext(ctx, target, impact_time, "avg")
        local atkCount = 0
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then atkCount = atkCount + 1 end
        end
        local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
        local kill_threshold = dmg - safety_margin
        local dmgRange = U.SFDamageRange(bot, target)
        local commit_threshold = math.max(kill_threshold, dmgRange.avg)
        local commit_buffer = C.LASTHIT.COMMIT_HP_BUFFER or 8
        local cancel_window = C.LASTHIT.CANCEL_WINDOW or math.max(0.03, math.min(0.08, ap * 0.20))
        local shouldCancel = H.ShouldCancelCommittedLastHit(predHP, commit_threshold, commit_buffer, remaining_windup, cancel_window)
        if shouldCancel then
            if remaining_windup > 0.01 and remaining_windup <= cancel_window then
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
            end
            return
        else
            if remaining_windup <= 0.05 and not State.firedThisAttack then
                State.firedThisAttack = true
            end
            return
        end
    else
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
    end

    -- The enemy walked up close - punish him without waiting for a last-hit window
    if enemyHero and not am_i_tanking_too_much and not State.prepTarget then
        if H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    -- Never let legacy `DESIRED_ATK_RANGE = 450` CS override `L.RunSacredCS` slack-weaving ticks (`csWaveBusy == true`)!
    if bestTarget and not csWaveBusy then
        local targetLoc = bestTarget:GetLocation()
        local botLoc = bot:GetLocation()
        local dist = GetUnitToLocationDistance(bot, targetLoc)
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local ap = bot:GetAttackPoint()
        local ms = bot:GetCurrentMovementSpeed() or 305
        local earliest_t_attack,current_t_attack=U.GetAttackImpactWindow(bot,bestTarget)
        local DESIRED_ATK_RANGE = 450
        local time_to_walk = math.max(0, dist - DESIRED_ATK_RANGE) / ms
        local ranged_t_attack = ap + (DESIRED_ATK_RANGE / projSpeed) + C.LASTHIT.NET_LATENCY
        local attackers = isDeny and enemyAttackers or allyAttackers
        local t_killable, t_window_end = U.GetTimeToKillable(bot, bestTarget, attackers)
        -- My hit must land AFTER the creep becomes killable (with the IMPACT_LEAD margin
        -- for jitter), and BEFORE our own creeps finish it. Previously a hit was allowed
        -- 0.05 s BEFORE the threshold -> systematic "hit too early, the creep survived".
        if t_killable < 0 then
            -- No window: our own creeps kill it first. If it is nearly killable - hit now (a chance).
            local hpNow = bestTarget:GetHealth()
            local dr = U.SFDamageRange(bot, bestTarget)
            if hpNow <= dr.avg + 4 and not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                    return
                end
            end
            t_killable = 999
        end
        if (time_to_walk + ranged_t_attack + 0.1) < t_killable then
            if dist > DESIRED_ATK_RANGE then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * DESIRED_ATK_RANGE, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            else
                if isAttacking then
                    bot:Action_ClearActions(true)
                    H.ClearMoveCache()
                end
            end
            return
        elseif U.LastHitImpactFits(earliest_t_attack, current_t_attack, t_killable, t_window_end) then
            if not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, botLoc, enemyTowers, allyCreeps), 60)
                end
            end
            return
        else
            if dist > 500 then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * 480, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            end
            return
        end
    end

    -- AGGRO PULL (chapter 18): drag his wave back to my side with an attack order + a step back
    if WV.PULL ~= "off" and not State.actionTaken then
        if WV.PullTick(bot, s, enemyHero, GameTime()) then return end
    end

    -- WAVE SHOVE (chapter 18): raze the creep wave to crash it now - the stock bot never razes
    -- creeps.  Fires after the last-hit block, so a cs is never traded for a shove.
    if WV.SHOVE ~= "off" and not State.actionTaken and WV.ShoveAllowed(bot, s, enemyHero) then
        local tgt, abName = WV.FindShove(bot, s)
        if tgt then
            local ab = bot:GetAbilityByName(abName)
            if ab and ab:GetLevel() > 0 and U.IsRazeAbilityCastable(bot, ab) then
                local actionType, aimLoc = H.GetRazeActionType(bot, ab, tgt)
                if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, tgt) then
                    WV.NoteShove()
                    return
                end
            end
        end
    end

    if H.HandleTowerStealLastHit(bot, enemyCreeps, allyTowers, enemyTowers, allyCreeps) then return end

    -- PUSH: push the wave / hit the T1 under a shield (last hits have higher priority - we get here
    -- only when no last hit is imminent)
    -- Siege as a fallback plan: the intent is aggressive (ALLIN/ZONE/TRADE) but the enemy hides
    -- under his T1 and is unreachable while our edge is large and the wave is at the tower - hit the tower/creeps
    -- under a shield instead of standing around. (ExecutePush checks the shield, HP and enemy threat itself.)
    local siegeFallback = false
    if intent ~= I.PUSH and intent ~= I.RETREAT and intent ~= I.FARM and not State.defensive
        and race.valid and s.enemyT1 and myHpPct >= ((C.INTENT and C.INTENT.PUSH_MIN_HP_PCT) or 0.55)
        and race.edge >= ((C.INTENT and C.INTENT.PUSH_EDGE) or 260) and not race.heCanKillSoon then
        local okTL, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okTL and tLoc and GetUnitToLocationDistance(bot, tLoc) <= ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then
            siegeFallback = true
        end
    end
    if (intent == I.PUSH or siegeFallback) and not State.prepTarget and not am_i_tanking_too_much then
        if H.ExecutePush(bot, enemyHero, race, s) then return end
    end

    -- No creeps: walk to the lane (to the centre if far; otherwise to our own T1)
    local hasCreeps = (#allyCreeps > 0) or (#enemyCreeps > 0)
    -- Time hysteresis - creep lists are taken within 1200 of the bot, and when moving past
    -- that boundary "no creeps -> walk to the T1 (closer to the wave) -> creeps again -> back off"
    -- twitched 20 times a second. "No creeps" = not seen for >= 1.5 s.
    local nowC = GameTime()
    if hasCreeps then State.lastCreepsSeenTime = nowC end
    if not hasCreeps and (nowC - (State.lastCreepsSeenTime or -1e9)) < 1.5 then hasCreeps = true end
    if not hasCreeps and not U.IsActivelyHealing(bot) and not fightingEnemyInLane then
        -- No creeps (early game / the wave died): wait at our own T1 (the T1_CLOSE point).
        -- One target without "centre/T1" thresholds (they twitched at the 1500-from-centre boundary);
        -- the "between the T1 and the centre" point was removed - for Dire it landed in the river.
        local targetPos = State.waveScoutPoint or P.GetT1Close(bot)
        -- Do not route through the enemy T1 radius
        targetPos = H.GetSafeApproach(bot, targetPos, enemyTowers, allyCreeps)
        if GetUnitToLocationDistance(bot, targetPos) > 45 then
            H.SmartMove(bot, targetPos, 80)
        end
        return
    end

    if State.holdPos then return end

    local pos = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode)
    if enemyHero and U.CanQuery(enemyHero) then
        pos = U.ClampMinDistFromEnemy(bot, enemyHero, pos) -- Do not enter his band under "fear"
    end
    pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
    if GetUnitToLocationDistance(bot, pos) > 100 then
        H.SmartMove(bot, pos, 60)
    end

    -- `v7.9.9-pro` (`1814 @ 08:42.40..08:45.07` End-of-Tick Zero-Order Anti-Freeze Guard):
    -- NEVER finish `RealThink` stationary (`not State.actionTaken`) while `enemyHero` is actively right-clicking/pressuring us
    -- within `615u` and `towerChaseBlockedEnemy` prevented retaliation! Step `190u` back outside `573u` attack reach!
    if not State.actionTaken and enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() then
        local dEnd = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dEnd <= 615 and (enemyHero:GetAttackTarget() == bot or H.IsEnemyPressuring(bot, enemyHero)) then
            local fntEnd = P.GetFountain(bot)
            local stepOutEnd = enemyHero:GetLocation() + (fntEnd - enemyHero:GetLocation()):Normalized() * 680
            if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(stepOutEnd, s.enemyT1Loc) < 980 then
                stepOutEnd = s.enemyT1Loc + (fntEnd - s.enemyT1Loc):Normalized() * 995
            end
            H.SmartMove(bot, stepOutEnd, 28, true)
        end
    end

    -- The tick stayed free - switch the Power Treads for the current task
    if not State.actionTaken then
        H.ManageTreads(bot, nil)
    end
end

-- `v7.9.18-pro` (`9074513540.dem` `11:12.00..11:40.07` Dead-Hero Tower Glyph Rescue!):
-- In Dota 2 Bot Scripting, `Think()` executes every tick while dead AND `bot:ActionImmediate_Glyph()` is a team-level
-- immediate order (`DOTA_UNIT_ORDER_GLYPH`) that works while `bot:IsAlive() == false`!
-- Previously `Think()` returned early on `not bot:IsAlive()`, letting Dire Mid T1 die at `11:40.07` (`4.06s` before respawn!)
-- with Dire Glyph 100% unused (`7.0s` invulnerability + 5-target Multishot wipes the creep wave and saves the game!).
function H.HandleDeadHeroTowerGlyph(bot)
    if not bot then return false end
    local now = (type(GameTime) == "function") and GameTime() or 0
    if now - (State.lastDeadGlyphCheckAt or -100) < 0.10 then
        return false
    end
    State.lastDeadGlyphCheckAt = now
    if not U.IsGlyphAvailable(bot) then return false end
    if type(GetTower) ~= "function" or TOWER_MID_1 == nil then return false end
    local ownMidT1 = GetTower(bot:GetTeam(), TOWER_MID_1)
    if not (ownMidT1 and U.CanQuery(ownMidT1) and ownMidT1:IsAlive()) then return false end
    if ownMidT1.HasModifier and ownMidT1:HasModifier("modifier_fountain_glyph") then return false end

    local curHp = ownMidT1:GetHealth() or 1800
    local maxHp = math.max(1, ownMidT1:GetMaxHealth() or 1800)
    local hpPct = curHp / maxHp
    U._allyTowerHpTrack = U._allyTowerHpTrack or {}
    local tr = U._allyTowerHpTrack[ownMidT1]
    if not tr or now < (tr.lastAt or 0) then
        tr = { lastHp = curHp, damagedAt = -100, lastAt = now }
        U._allyTowerHpTrack[ownMidT1] = tr
    else
        if curHp < tr.lastHp then
            tr.damagedAt = now
        end
        tr.lastHp = curHp
        tr.lastAt = now
    end

    local projs = U.SafeGetIncomingProjectiles(ownMidT1)
    local hasProjs = projs and #projs > 0
    local recentlyLostHp = (now - (tr.damagedAt or -100)) <= 1.8
    local recentlyHitHero = ownMidT1.WasRecentlyDamagedByAnyHero and ownMidT1:WasRecentlyDamagedByAnyHero(1.8)
    local recentlyHitCreep = ownMidT1.WasRecentlyDamagedByCreep and ownMidT1:WasRecentlyDamagedByCreep(1.8)
    local underFireNow = hasProjs or recentlyLostHp or recentlyHitHero or recentlyHitCreep
    if not underFireNow then return false end

    local respawnRem = (bot.GetRespawnTime and bot:GetRespawnTime()) or 99
    local defPct = (C.GLYPH and C.GLYPH.T1_HP_PCT_THRESHOLD) or 0.25
    local defAbs = math.max(520, (C.GLYPH and C.GLYPH.T1_HP_ABS_THRESHOLD) or 450)
    -- Trigger Glyph while dead when:
    --   1. Sudden-Death T1 Survival: `curHp <= 520` (or `<= defPct`) under active fire, OR
    --   2. Respawn-Bridge Wave-Wipe (`<= 14.0s` to respawn, `curHp <= 820` under active fire): `7.0s` Glyph invulnerability +
    --      5-target Multishot wipes the enemy wave and bridges the final seconds until respawn + TP!
    if curHp <= defAbs or hpPct <= defPct or (respawnRem > 0 and respawnRem <= 14.0 and curHp <= 820) then
        return U.UseGlyph(bot)
    end
    return false
end

function Think()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then
        if bot then
            pcall(H.HandleDeadHeroTowerGlyph, bot)
        end
        State.heroCombatEnemy = nil
        State.heroCombatUntil = 0
        State.survivalUntil = 0
        State.survivalLoc = nil
        State.needsTP = true
        State.emergencyRetreat = nil
        State.emergencyRetreatStartTime = 0
        State.emergencyTPQueued = false
        State.strTreadsLockActive = false
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        State.goingToFountain = false
        State.fountainReason = nil
        State.enemyReachedLevel2First = false
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        State.heroAttackCommitUntil = 0
        State.heroAttackStartLAT = -100
        H.ClearForcedRetreat()
        H.ClearTowerEscape()
        H.ClearRazeState()
        H.ClearMoveCache()
        H.ClearTangoState()
        State.dodgeLoc = nil
        State.dodgeUntil = 0
        State.intent = "FARM"
        I.Reset()
        return
    end

    local now = GameTime()
    if now - (State.lastThinkTick or -100) < 0.015 then return end
    State.lastThinkTick = now
    if U.BeginTickScope then U.BeginTickScope(now) end
    local success, err = pcall(H.RealThink)
    if U.EndTickScope then U.EndTickScope() end
    if not success then
        _G.__SF_RUNTIME_ERRORS = (_G.__SF_RUNTIME_ERRORS or 0) + 1
        _G.__SF_LAST_RUNTIME_ERROR = tostring(err)
        if _G.__SF_STRICT_ASSERT then
            error("[SF-BOT STRICT ASSERT] " .. tostring(err), 0)
        end
        if now - (State.lastErrorLog or -100) >= 1.0 then
            State.lastErrorLog = now
            print("[SF-BOT CRITICAL ERROR] " .. tostring(err))
        end
        -- Zero-Freeze Fail-Safe Recovery (`auto-20261031-1939` `tk=14068..14298` `(255.0, 384.1)` Fix!):
        -- NEVER walk `380u` IN FRONT of T1 (`P.GetT1Close(bot, 380)`) and freeze within `<= 65u` under enemy attack!
        -- Retreat BEHIND allied Mid T1 (`P.GetBehindT1(bot, 480)`), or all the way to Fountain when wounded / taking hero hits!
        pcall(function()
            local maxHpFs = math.max(1, bot:GetMaxHealth() or 1)
            local hpPctFs = (bot:GetHealth() or 0) / maxHpFs
            local hitByHero = (bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.8)) or false
            local safeAnchor = nil
            if hpPctFs <= 0.35 or hitByHero then
                safeAnchor = P.GetFountain(bot)
            else
                safeAnchor = (P.GetBehindT1 and P.GetBehindT1(bot, 480)) or P.GetFountain(bot)
            end
            if safeAnchor and GetUnitToLocationDistance(bot, safeAnchor) > 55 then
                bot:Action_MoveToLocation(safeAnchor)
            end
        end)
    end
end

if _G.BOT_SIM_PROBE then
    _G.__NEVERMORE_H = H
    _G.__NEVERMORE_STATE = State
end
