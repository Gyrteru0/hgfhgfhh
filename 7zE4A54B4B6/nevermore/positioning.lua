local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local P = {}

function P.GetFountain(bot)
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function P.GetT1Tower(bot)
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local tower = GetTower(bot:GetTeam(), TOWER_MID_1)
        if tower and tower:IsAlive() and (not tower.CanBeSeen or tower:CanBeSeen()) then
            return tower:GetLocation()
        end
    end
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
end

function P.GetT1Close(bot, distance)
    local tower = P.GetT1Tower(bot)
    local enemyTeam = bot:GetTeam() == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
    local enemyLoc = bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local enemyTower = GetTower(enemyTeam, TOWER_MID_1)
        if enemyTower and enemyTower:IsAlive() and (not enemyTower.CanBeSeen or enemyTower:CanBeSeen()) then
            enemyLoc = enemyTower:GetLocation() or enemyLoc
        end
    end
    local home = (enemyLoc - tower):Normalized()
    return tower + home * (distance or 180)
end

-- True defensive point BEHIND allied T1 toward Fountain (never forward into river — fixes `R2_2044` `04:16..04:26`
-- `(1653, 1533) <-> (1450, 1334)` Salve oscillation where `GetT1Close(bot, 420)` pointed SW toward enemy!).
function P.GetBehindT1(bot, distance, fallbackDist)
    local dist = (type(distance) == "number" and distance)
        or (type(fallbackDist) == "number" and fallbackDist)
        or 400
    local tower = P.GetT1Tower(bot)
    local fnt = P.GetFountain(bot)
    local back = (fnt - tower):Normalized()
    return tower + back * dist
end

-- Ensures `candidate` is AT LEAST as deep toward Fountain as `P.GetBehindT1(bot, minBehindT1)`
-- (`9069188041.dem` Death #1 Fix: NEVER pull a deeper anchor outward away from Fountain via inverted `<`!).
function P.ClampDeeperTowardFountain(bot, candidate, minBehindT1)
    local minSpot = P.GetBehindT1(bot, minBehindT1 or 400)
    if not candidate then return minSpot end
    local fnt = P.GetFountain(bot)
    if U.DistanceBetweenLocations(candidate, fnt) > U.DistanceBetweenLocations(minSpot, fnt) then
        return minSpot
    end
    return candidate
end

-- Monotonic Fountain-ward retreat anchor (`9069188041.dem` `03:44.1-03:47.5` Death #2 Fix):
-- When `bot` is ALREADY deeper toward Fountain than `P.GetBehindT1(bot, minBehindT1)` (e.g. `(1304, 1095)` vs
-- `(675, 798)`), NEVER pull `bot` 620u backward SW toward the river/enemy! Either hold current deep position
-- (`stepWhenDeep <= 0`) or continue retreating `stepWhenDeep` units closer to Fountain (`stepWhenDeep > 0`).
function P.GetRetreatAnchor(bot, minBehindT1, stepWhenDeep)
    local base = P.GetBehindT1(bot, minBehindT1 or 260)
    local bLoc = bot:GetLocation()
    local fnt = P.GetFountain(bot)
    local dBotFnt = U.DistanceBetweenLocations(bLoc, fnt)
    local dBaseFnt = U.DistanceBetweenLocations(base, fnt)
    if dBotFnt > dBaseFnt + 35 then
        return base
    end
    local extra = tonumber(stepWhenDeep) or 0
    if extra <= 0 then
        return bLoc
    end
    local step = math.min(extra, math.max(0, dBotFnt - 420))
    if step <= 5 then return bLoc end
    return bLoc + (fnt - bLoc):Normalized() * step
end

-- Upgrade river points (height level 1) up toward allied highground bank when attacking highground creeps,
-- eliminating the 25% Source 2 uphill miss rate completely whenever safe.
function P.AvoidUphillMiss(bot, candidatePos, targetLoc, maxRange)
    if type(GetHeightLevel) ~= "function" or not candidatePos or not targetLoc then
        return candidatePos
    end
    local th = GetHeightLevel(targetLoc)
    local ch = GetHeightLevel(candidatePos)
    if ch >= th then return candidatePos end

    local fountain = P.GetFountain(bot)
    local toFountain = (fountain - candidatePos):Normalized()
    maxRange = maxRange or ((bot:GetAttackRange() or 525) - 25)

    -- Search radially & along allied ramp for closest non-river highground point still inside attack range
    for step = 60, 320, 40 do
        local test = candidatePos + toFountain * step
        local dx, dy = test.x - targetLoc.x, test.y - targetLoc.y
        if math.sqrt(dx * dx + dy * dy) <= maxRange and GetHeightLevel(test) >= th then
            return test
        end
    end
    -- NEVER step forward across the river onto the ENEMY's highground ramp (`auto-20261031-0230` `01:00.3` `d=130u`,
    -- `01:51.7` `d=496u`, `02:01.4` `d=373u` Root-Cause Fix!) when a live/recent enemy hero or live enemy T1 is near!
    local WmodUp = package.loaded["bots/nevermore/world"]
    local wsUp = WmodUp and WmodUp.s
    local enemyDeadUp = wsUp and wsUp.enemyAlive == false
    if not enemyDeadUp then
        local ehLoc = nil
        if wsUp and wsUp.enemy and (not wsUp.enemy.CanBeSeen or wsUp.enemy:CanBeSeen()) and wsUp.enemy:IsAlive() then
            ehLoc = wsUp.enemy:GetLocation()
        elseif wsUp and wsUp.enemyLastLoc and (wsUp.enemyAbsentFor or 99) <= 3.0 then
            ehLoc = wsUp.enemyLastLoc
        end
        local enT1Loc = (wsUp and wsUp.enemyT1Alive ~= false and wsUp.enemyT1Loc) or nil
        local towardTarget = (targetLoc - candidatePos):Normalized()
        for step = 60, 260, 40 do
            local test = candidatePos + towardTarget * step
            local dx, dy = test.x - targetLoc.x, test.y - targetLoc.y
            local safeFromHero = (not ehLoc) or (U.DistanceBetweenLocations(test, ehLoc) >= 920)
            local safeFromT1 = (not enT1Loc) or (U.DistanceBetweenLocations(test, enT1Loc) >= 930)
            if safeFromHero and safeFromT1 and math.sqrt(dx * dx + dy * dy) <= maxRange and GetHeightLevel(test) >= th then
                return test
            end
        end
        return candidatePos
    end
    -- Enemy hero is dead on scoreboard: stepping onto target's highground lip is 100% safe
    local towardTarget = (targetLoc - candidatePos):Normalized()
    for step = 60, 260, 40 do
        local test = candidatePos + towardTarget * step
        local dx, dy = test.x - targetLoc.x, test.y - targetLoc.y
        if math.sqrt(dx * dx + dy * dy) <= maxRange and GetHeightLevel(test) >= th then
            return test
        end
    end
    return candidatePos
end

-- `v7.6.0` Own-T1 Highground Anti-Miss Discipline (`auto-20261101-0031-start-ShaNachnetsya.dem`):
-- When the creep wave clashes near our allied T1 (`ClassifyWaveZone == "OWN_T1"`), hold our own T1 highground
-- (`GetHeightLevel(pos) >= GetHeightLevel(ownT1)`) whenever any wave creep is reachable from our highground lip,
-- eliminating the 25% Source 2 uphill miss penalty on creeps completely!
function P.HoldOwnT1Highground(bot, candidatePos, enemyCreeps, allyCreeps)
    if not bot or not candidatePos then return candidatePos end
    local waveZone = U.ClassifyWaveZone and U.ClassifyWaveZone(bot, allyCreeps, enemyCreeps) or "NONE"
    if waveZone ~= "OWN_T1" then return candidatePos end

    local ownT1 = P.GetT1Tower(bot)
    if not ownT1 then return candidatePos end
    local fnt = P.GetFountain(bot)
    local maxReach = (bot:GetAttackRange() or 525) - 12

    local refCreepLoc, minD = nil, math.huge
    for _, list in ipairs({ enemyCreeps or {}, allyCreeps or {} }) do
        for _, c in pairs(list) do
            if c and c:IsAlive() then
                local cl = c:GetLocation()
                local d = U.DistanceBetweenLocations(ownT1, cl)
                if d < minD then
                    minD, refCreepLoc = d, cl
                end
            end
        end
    end
    if not refCreepLoc then return candidatePos end

    if type(GetHeightLevel) == "function" then
        local ownHg = GetHeightLevel(ownT1)
        if ownHg and (GetHeightLevel(candidatePos) or 0) < ownHg then
            local toT1 = (ownT1 - candidatePos)
            local dirT1 = (toT1:Length2D() > 1) and toT1:Normalized() or (fnt - candidatePos):Normalized()
            local dirFnt = (fnt - candidatePos):Normalized()
            for step = 40, 440, 35 do
                for _, dir in ipairs({ dirT1, dirFnt }) do
                    local test = candidatePos + dir * step
                    if (GetHeightLevel(test) or 0) >= ownHg
                        and U.DistanceBetweenLocations(test, refCreepLoc) <= maxReach then
                        return test
                    end
                end
            end
        end
    end
    return candidatePos
end

function P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, prepareTarget, mode)
    local fountain = P.GetFountain(bot)

    -- Farm cleanly under our T1 WITHOUT letting unshielded enemy melee creeps beat on our hero body
    -- (`9056469656.dem` `01:20` `(90, 981)` 9 free melee creep hits & `02:34` `(293, 374)` stationary tanking!):
    -- When `#allyCreeps == 0` and any live non-killable enemy creep under our T1 is aggroed onto `bot` (`GetAttackTarget() == bot`),
    -- step 435u back past our own T1 toward Fountain so Dire/Radiant T1 tanks & damages the melee creeps for 0 HP cost!
    do
        local t1 = P.GetT1Tower(bot)
        if t1 and enemyCreeps and #enemyCreeps > 0 then
            local lowestCreep, lowestHP = nil, math.huge
            local meleeBeatingBot, beatingCount, minFntDist = nil, 0, math.huge
            local killThresh = (bot:GetAttackDamage() or 55) + 22
            local hpDamaged = (bot:GetHealth() or 999) < (bot:GetMaxHealth() or 999) * 0.72
            local t1LocRef = (t1.GetLocation and t1:GetLocation()) or t1
            local WmodT1Scan = package.loaded["bots/nevermore/world"]
            local wsT1Scan = WmodT1Scan and WmodT1Scan.s
            local siegeOrHeroPressingT1 = false
            if wsT1Scan and wsT1Scan.enemy and U.CanQuery(wsT1Scan.enemy) and wsT1Scan.enemy:IsAlive()
                and U.DistanceBetweenLocations(t1LocRef, wsT1Scan.enemy:GetLocation()) <= 775 then
                siegeOrHeroPressingT1 = true
            end
            for _, c in pairs(enemyCreeps) do
                if c and c:IsAlive() then
                    local d = GetUnitToLocationDistance(c, t1)
                    if d <= 865 then
                        local nmC = (c.GetUnitName and c:GetUnitName()) or ""
                        if nmC:find("siege") or nmC:find("catapult") then
                            siegeOrHeroPressingT1 = true
                        end
                        local hp = c:GetHealth()
                        if hp < lowestHP then
                            lowestHP, lowestCreep = hp, c
                        end
                        if (not allyCreeps or #allyCreeps == 0) and hp > killThresh
                            and c.GetAttackTarget and c:GetAttackTarget() == bot then
                            beatingCount = beatingCount + 1
                            local dFnt = GetUnitToLocationDistance(c, fountain)
                            if dFnt < minFntDist then
                                minFntDist, meleeBeatingBot = dFnt, c
                            end
                        end
                    end
                end
            end
            -- `v7.9.19` (`9074666246.dem` `06:36..06:43` `RAD CREEP id=208` `dT1=697.5u` Aggro-Hijack Fix!):
            -- In Dota 2 C++, an enemy creep inside `700u` attacking our hero has HIGHER tower priority (#1) than an enemy
            -- Siege Catapult (`823u`) or Hero (`687u`) attacking our T1 (#2)! Whenever `siegeOrHeroPressingT1` is true and
            -- ANY enemy creep (`even beatingCount == 1 at 82% HP!`) is hitting `bot` inside `<= 725u` of `t1`, pull `bot`
            -- cleanly to `825u` toward Fountain (`> 730u` creep-to-T1!) so `t1` immediately switches aggro onto the Catapult/Hero!
            local aggroHijackUnderT1 = siegeOrHeroPressingT1 and meleeBeatingBot
                and (U.DistanceBetweenLocations(meleeBeatingBot:GetLocation(), t1LocRef) <= 725)
            if aggroHijackUnderT1 then
                local pullOutDir = (fountain - t1LocRef):Normalized()
                return t1LocRef + pullOutDir * 830
            end
            -- Stop kiting `435u` back as soon as the lowest under-T1 creep is within `1` tower hit (`killThresh + 115`),
            -- so SF steps straight into `175u` phase-locked stance with `0` turn-rate penalty BEFORE the killing window opens!
            if meleeBeatingBot and (hpDamaged or beatingCount >= 2) and lowestCreep and lowestHP > (killThresh + 115) then
                local cLoc = meleeBeatingBot:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                return cLoc + dir * 435
            end
            if lowestCreep then
                local cLoc = lowestCreep:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                local stand = (C.BALLISTIC and C.BALLISTIC.CLOSE_STAND_DIST) or 175
                -- `auto-20261031-0230` `02:08.3` Death #2 Root-Cause Fix:
                -- When a live enemy hero pressures near our T1 while we are wounded (`<= 420 HP` / `< 65%`) or out-leveled,
                -- NEVER pull SF from `(701, 685)` (`d=709u`) SW to `175u` (`(645, 517)`, `d=334u`) into enemy right-clicks!
                local WmodT1 = package.loaded["bots/nevermore/world"]
                local wsT1 = WmodT1 and WmodT1.s
                local ehT1 = (wsT1 and wsT1.enemy and U.CanQuery(wsT1.enemy) and wsT1.enemy:IsAlive() and wsT1.enemy) or nil
                local ehLocT1 = (ehT1 and ehT1:GetLocation())
                    or ((wsT1 and wsT1.enemyAlive ~= false and (wsT1.enemyAbsentFor or 99) <= 3.0) and wsT1.enemyLastLoc or nil)
                if ehLocT1 and U.DistanceBetweenLocations(ehLocT1, cLoc) <= 960 then
                    local myHpT1 = bot:GetHealth() or 999
                    local myMaxT1 = math.max(1, bot:GetMaxHealth() or 600)
                    local outLvlT1 = ehT1 and ((ehT1:GetLevel() or 1) > (bot:GetLevel() or 1)) or false
                    if myHpT1 <= 420 or (myHpT1 / myMaxT1) < 0.65 or outLvlT1 then
                        local safeMaxStand = math.min((bot:GetAttackRange() or 525) - 40, 470)
                        local bLocT1 = bot:GetLocation()
                        if U.DistanceBetweenLocations(bLocT1, cLoc) <= (bot:GetAttackRange() or 525) - 15
                            and U.DistanceBetweenLocations(bLocT1, fountain) < U.DistanceBetweenLocations(cLoc + dir * safeMaxStand, fountain) then
                            return bLocT1
                        end
                        stand = safeMaxStand
                    end
                end
                return P.AvoidUphillMiss(bot, cLoc + dir * stand, cLoc)
            end
        end
    end

    local function safeNoShieldCS(p)
        if not p then return p end
        local Wmod = package.loaded["bots/nevermore/world"]
        local ws = Wmod and Wmod.s
        if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc and #(allyCreeps or {}) == 0 then
            local tLoc = ws.enemyT1Loc
            local safeRad = math.max((C.TOWER and C.TOWER.SAFE_RADIUS) or 890, 925)
            if U.DistanceBetweenLocations(p, tLoc) < safeRad then
                return tLoc + (fountain - tLoc):Normalized() * safeRad
            end
        end
        return p
    end

    if prepareTarget and prepareTarget:IsAlive() then
        local Wmod = package.loaded["bots/nevermore/world"]
        local ws = Wmod and Wmod.s
        local enemyDead = ws and ws.enemyAlive == false
        local dominant = (mode ~= "PASSIVE") and (not enemyDead)
            and U.IsLaneDominant and U.IsLaneDominant(bot, ws, nil) or false
        local ehPrep = (not enemyDead and ws and ws.enemy and U.CanQuery(ws.enemy) and ws.enemy:IsAlive() and ws.enemy) or nil
        local cLoc = prepareTarget:GetLocation()
        local dir = (fountain - cLoc):Normalized()
        local stand
        if enemyDead then
            stand = (C.BALLISTIC and C.BALLISTIC.CLOSE_STAND_DIST) or 175
        elseif mode == "PASSIVE" then
            stand = 455
        elseif dominant then
            -- Commanding `210u` forward CS/Deny stance when dominating (`0.175s` bolt flight vs `0.42s` at `505u`!):
            -- snipes both contested CS and denies 7 ticks faster while holding our body at the wave front!
            stand = 210
        elseif ehPrep and (
            (bot:GetHealth() or 999) <= 360
            or ((ehPrep:GetLevel() or 1) > (bot:GetLevel() or 1))
            or (U.IsOutRazedTier and U.IsOutRazedTier(bot, ehPrep))
            or ((U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0) >= 1
        ) then
            -- `auto-20261031-0230` `00:59.3`, `01:51.1` & `02:00.4` Fix:
            -- Hold crisp max-attack-range spacing (`480u`) when down a level/raze tier, wounded, or carrying a raze stack!
            stand = math.min((bot:GetAttackRange() or 525) - 35, 480)
        else
            stand = (C.BALLISTIC and C.BALLISTIC.CONTESTED_STAND_DIST) or 415
        end
        local anchor = cLoc + dir * stand
        local bootlessVsArmedFaster = ehPrep and ((ehPrep:GetCurrentMovementSpeed() or 305) >= (bot:GetCurrentMovementSpeed() or 305) + 20)
            and (((ehPrep:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehPrep) or 0)) >= 145)
        local lowRealManaDeep = ((bot:GetMana() or 0) < 140)
            and ws and ws.allyT1Loc and (U.DistanceBetweenLocations(cLoc, ws.allyT1Loc) > 1550)
        if dominant and not enemyDead and not bootlessVsArmedFaster and not lowRealManaDeep and allyCreeps and #allyCreeps > 0
            and (prepareTarget:GetHealth() or 0) > ((bot:GetAttackDamage() or 60) * 1.85 + 25) then
            local enemyT1RefD = (ws and ws.enemyT1Loc)
                or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
            local frontAllyD, minT1D = nil, math.huge
            for _, ac in pairs(allyCreeps) do
                if ac and ac:IsAlive() then
                    local dT = GetUnitToLocationDistance(ac, enemyT1RefD)
                    if dT < minT1D then minT1D, frontAllyD = dT, ac end
                end
            end
            if frontAllyD and minT1D > 1060 then
                local faLocD = frontAllyD:GetLocation()
                -- `v7.9.13-pro` (`0210 @ 00:00..06:00` 27x Creep-Reaggro Screen):
                -- Stand `185u` IN FRONT of `frontAllyD` toward `enemyT1` (clamped `>= 920u` outside `enemyT1`) so the
                -- enemy SF CANNOT step within `500u` of `frontAllyD` to pull creep aggro without crossing inside `315..495u`
                -- of our SF and eating immediate right-clicks + centered `Shadowraze2`!
                local bullyStep = (((DotaTime and DotaTime()) or 0) <= 390) and 185 or 145
                local shieldAnchor = faLocD - dir * bullyStep
                local maxReachD = math.max(380, (bot:GetAttackRange() or 525) - 30)
                if U.DistanceBetweenLocations(shieldAnchor, cLoc) <= maxReachD
                    and (not enemyT1RefD or U.DistanceBetweenLocations(shieldAnchor, enemyT1RefD) >= 920) then
                    anchor = shieldAnchor
                end
            end
        end
        -- Never walk ahead of our front allied melee line toward enemy creeps/hero when `cLoc` is already
        -- comfortably reachable from behind our allied creeps (`<= maxReach = atkRange - 35`), EXCEPT when
        -- `dominant == true` where holding the wave front zones the opponent off CS & denies!
        if not enemyDead and not dominant and allyCreeps and #allyCreeps > 0 then
            local enemyT1Ref = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
            local frontAlly, minT1 = nil, math.huge
            for _, ac in pairs(allyCreeps) do
                if ac and ac:IsAlive() then
                    local dT = GetUnitToLocationDistance(ac, enemyT1Ref)
                    if dT < minT1 then minT1, frontAlly = dT, ac end
                end
            end
            if frontAlly then
                local faLoc = frontAlly:GetLocation()
                local behindFront = faLoc + dir * 135
                local maxReach = math.max(380, (bot:GetAttackRange() or 525) - 35)
                local fntToAnchor = U.DistanceBetweenLocations(fountain, anchor)
                local fntToBehind = U.DistanceBetweenLocations(fountain, behindFront)
                if fntToAnchor > fntToBehind and U.DistanceBetweenLocations(behindFront, cLoc) <= maxReach then
                    anchor = behindFront
                end
            end
        end
        -- If `ehPrep` stands near `anchor`, pull `anchor` back toward Fountain up to `maxSafeReach` (`atkRange - 20`)
        -- when even/losing; when `dominant`, only avoid standing point-blank inside an armed enemy's `200u` Q band!
        if ehPrep then
            local eLocP = ehPrep:GetLocation()
            if dominant then
                local enArmed = ((ehPrep:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehPrep) or 0)) >= 75
                -- Strictly avoid `[176, 474]` `Q+W` double-coil overlap! Step out to `495u` (outside `Q = 474u` hull edge!)
                -- or `maxSafeReach` (`atkRange - 18`) instead of `340u`!
                if enArmed and U.DistanceBetweenLocations(anchor, eLocP) < 490 then
                    local r1Safe = eLocP + dir * 495
                    local reachLim = (bot:GetAttackRange() or 525) - 18
                    local farPrep = cLoc + dir * reachLim
                    if U.DistanceBetweenLocations(r1Safe, cLoc) <= reachLim then
                        anchor = r1Safe
                    elseif U.DistanceBetweenLocations(farPrep, eLocP) > U.DistanceBetweenLocations(anchor, eLocP) + 15 then
                        anchor = farPrep
                    end
                end
            else
                local dryNow = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, ehPrep, ws) or false
                local minEnemyDist = dryNow and math.max(745, U.GetDrySafeStandoffDist(bot, ehPrep)) or 715
                local maxSafeReach = math.max(415, (bot:GetAttackRange() or 525) - (dryNow and 15 or 20))
                local farAnchor = cLoc + dir * maxSafeReach
                if U.DistanceBetweenLocations(anchor, eLocP) < minEnemyDist
                    and U.DistanceBetweenLocations(farAnchor, eLocP) > U.DistanceBetweenLocations(anchor, eLocP) + 12 then
                    anchor = farAnchor
                end
            end
        end
        -- Honor `GetDeepEnemyT1ChokeSpot` EVEN when `prepareTarget ~= nil` whenever `cLoc` is reachable from the river-lip choke!
        if (mode ~= "PASSIVE") and (not enemyDead) and U.GetDeepEnemyT1ChokeSpot then
            local prepChoke = U.GetDeepEnemyT1ChokeSpot(bot, ws, nil, allyCreeps, enemyCreeps)
            if prepChoke and U.DistanceBetweenLocations(prepChoke, cLoc) <= (bot:GetAttackRange() or 525) - 20
                and U.DistanceBetweenLocations(fountain, prepChoke) < U.DistanceBetweenLocations(fountain, anchor) - 20 then
                anchor = prepChoke
            end
        end
        if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc then
            local tLoc = ws.enemyT1Loc
            if U.DistanceBetweenLocations(anchor, tLoc) < 915 then
                anchor = tLoc + (fountain - tLoc):Normalized() * 915
            end
        end
        return safeNoShieldCS(P.HoldOwnT1Highground(bot, P.AvoidUphillMiss(bot, anchor, cLoc), enemyCreeps, allyCreeps))
    end

    if not allyCreeps or #allyCreeps == 0 then
        if enemyCreeps and #enemyCreeps > 0 then
            -- Kite/hold safely at max range toward our tower without losing sight or missing dying low-HP enemy creeps
            local bestC, bestHP = nil, math.huge
            for _, c in pairs(enemyCreeps) do
                if c and c:IsAlive() and c:GetHealth() < bestHP then
                    bestHP, bestC = c:GetHealth(), c
                end
            end
            if bestC then
                local cLoc = bestC:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                return safeNoShieldCS(P.AvoidUphillMiss(bot, cLoc + dir * 430, cLoc))
            end
        end
        return P.GetT1Close(bot)
    end

    local enemyT1 = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local frontAlly = allyCreeps[1]
    local minDist = math.huge
    for _, c in pairs(allyCreeps) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, enemyT1)
            if d < minDist then
                minDist = d
                frontAlly = c
            end
        end
    end
    local fLoc = frontAlly:GetLocation()
    local dir = (fountain - fLoc):Normalized()
    local WmodLive = package.loaded["bots/nevermore/world"]
    local wsLive = WmodLive and WmodLive.s
    local enemyDeadIdle = wsLive and wsLive.enemyAlive == false
    local waveZone = U.ClassifyWaveZone and U.ClassifyWaveZone(bot, allyCreeps, enemyCreeps) or "NONE"
    local deepChokeSpot = (mode ~= "PASSIVE") and (not enemyDeadIdle)
        and U.GetDeepEnemyT1ChokeSpot
        and U.GetDeepEnemyT1ChokeSpot(bot, wsLive, nil, allyCreeps, enemyCreeps) or nil
    if deepChokeSpot then
        return deepChokeSpot
    end
    local dominantIdle = (mode ~= "PASSIVE") and (not enemyDeadIdle)
        and U.IsLaneDominant and U.IsLaneDominant(bot, wsLive, nil) or false
    local dist_from_creeps = enemyDeadIdle and 220 or 365
    if mode == "PASSIVE" then
        dist_from_creeps = 465
    elseif dominantIdle then
        -- `v7.9.19` (`9074666246.dem` `05:38` Bootless Overextension & `450u` `W` Bullseye Fix):
        -- Only step `-135u` ahead of `frontAlly` when NOT out-sped (`+20 MS`) by an armed (`>= 145 MP`) enemy SF
        -- and holding `>= 145` real mana; otherwise hold crisp `+165u` behind `frontAlly`!
        local ehDom = wsLive and wsLive.enemy
        local unsafeBullyIdle = (ehDom and U.CanQuery(ehDom) and ehDom:IsAlive()
                and (ehDom:GetCurrentMovementSpeed() or 305) >= (bot:GetCurrentMovementSpeed() or 305) + 20
                and ((ehDom:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehDom) or 0)) >= 145)
            or ((bot:GetMana() or 0) < 145 and wsLive and wsLive.allyT1Loc and U.DistanceBetweenLocations(fLoc, wsLive.allyT1Loc) > 1550)
        dist_from_creeps = (waveZone == "OWN_T1") and 215 or (unsafeBullyIdle and 165 or -135)
    elseif mode == "AGGRESSIVE" then
        dist_from_creeps = enemyDeadIdle and 175 or 305
    end
    if not dominantIdle then
        local WV = package.loaded["bots/nevermore/wave"]
        if WV then dist_from_creeps = WV.WaveDist(bot, dist_from_creeps, mode) end
    end
    local aimRef = fLoc
    if prepareTarget and prepareTarget.GetLocation then
        aimRef = prepareTarget:GetLocation()
    elseif enemyCreeps then
        for _, ec in pairs(enemyCreeps) do
            if ec and ec:IsAlive() then
                local el = ec:GetLocation()
                if type(GetHeightLevel) == "function" and GetHeightLevel(el) > GetHeightLevel(aimRef) then
                    aimRef = el
                    break
                end
            end
        end
    end
    local baseIdle = fLoc + dir * dist_from_creeps
    -- Dry-Mana Idle Coil Guard (`v7.8.0`): never park idle wave stance inside enemy `R1`/`R2` (`745u`) or stacked `R3` (`990u`) when `< 75 MP`!
    if wsLive and wsLive.enemy and U.CanQuery(wsLive.enemy) and wsLive.enemy:IsAlive()
        and U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, wsLive.enemy, wsLive) then
        local dryStand = U.GetDrySafeStandoffDist(bot, wsLive.enemy)
        local eLocIdle = wsLive.enemy:GetLocation()
        if dryStand > 0 and U.DistanceBetweenLocations(baseIdle, eLocIdle) < dryStand then
            baseIdle = eLocIdle + (fountain - eLocIdle):Normalized() * dryStand
        end
    end
    -- Never step into unengaged marching enemy melee creeps before our wave meets them, and keep `>= 920u` off enemy T1!
    if dominantIdle then
        for _, ec in pairs(enemyCreeps or {}) do
            if ec and ec:IsAlive() and ((ec.GetAttackRange and ec:GetAttackRange()) or 100) < 250 then
                local okT, tgt = false, nil
                if ec.GetAttackTarget then okT, tgt = pcall(ec.GetAttackTarget, ec) end
                if not okT or tgt == nil then
                    local ecLoc = ec:GetLocation()
                    if U.DistanceBetweenLocations(baseIdle, ecLoc) < 235 then
                        baseIdle = ecLoc + dir * 235
                    end
                end
            end
        end
        if wsLive and wsLive.enemyT1Alive ~= false and wsLive.enemyT1Loc then
            local tLoc = wsLive.enemyT1Loc
            if U.DistanceBetweenLocations(baseIdle, tLoc) < 920 then
                baseIdle = tLoc + (fountain - tLoc):Normalized() * 920
            end
        end
    end
    -- Hold calm, rock-steady contested stance (`math.sin(GameTime()*2.15)*58` removed -> eliminates 116u artificial pacing reversals!)
    local res = P.AvoidUphillMiss(bot, baseIdle, aimRef)
    -- Forward-Zoning Enemy Guard (`R2_2044` `02:39` `A464(-348,-215)` & `03:53` `A300(-541,-360)` Root Cause!):
    -- Uses Beastmaster-filtered `wsLive.enemy` first, and holds `495u` (strictly outside `[176, 474]` `Q+W` overlap!)
    local eh = (wsLive and wsLive.enemy and U.CanQuery(wsLive.enemy) and wsLive.enemy:IsAlive() and wsLive.enemy) or nil
    if not eh and bot.GetNearbyHeroes then
        local nearEnemies = bot:GetNearbyHeroes(1500, true, BOT_MODE_NONE)
        for _, candH in pairs(nearEnemies or {}) do
            if candH and (not WmodLive or not WmodLive.IsFillerBeastmasterUnit or not WmodLive.IsFillerBeastmasterUnit(candH)) then
                eh = candH
                break
            end
        end
    end
    if eh and (not eh.CanBeSeen or eh:CanBeSeen()) and eh:IsAlive() and (eh:GetHealth() or 999) > 220 then
        local eLoc = eh:GetLocation()
        local dxE, dyE = fountain.x - eLoc.x, fountain.y - eLoc.y
        local dxR, dyR = fountain.x - res.x, fountain.y - res.y
        local eFntDist = math.sqrt(dxE * dxE + dyE * dyE)
        local rFntDist = math.sqrt(dxR * dxR + dyR * dyR)
        if rFntDist > eFntDist - 80 then
            local myHpNow = bot:GetHealth() or 0
            local ehHpNow = eh:GetHealth() or 999
            local ehArmedSF = (eh:GetUnitName() == "npc_dota_hero_nevermore")
                and (((eh:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(eh) or 0)) >= 75)
            local canStandGround = (myHpNow >= 320 and myHpNow >= ehHpNow * 0.78 and mode ~= "PASSIVE")
            -- `v7.9.19` (`DEEP_CENTER_START` Prevention): `570u` is the exact `[450u W .. 700u E]` seam (`120..130u` off BOTH centers ->
            -- `sExit <= 149u`, 100% dodgeable on reaction!), whereas `495..505u` parked `45..55u` from `450u` `W` bullseye!
            local standPad = ehArmedSF and 570 or (canStandGround and 495 or ((mode == "PASSIVE") and 565 or 515))
            local homeDir = (fountain - eLoc):Normalized()
            res = P.AvoidUphillMiss(bot, eLoc + homeDir * standPad, eLoc)
        end
        -- Pre-Windup Sightline Lateral Offset: if `res` sits inside an armed enemy SF's `W(450)` or `E(700)` radius band
        -- right on his facing ray (`lat < 95u`), shift `105u` laterally off his facing vector so any cast starts `>= 115u` off-center!
        if eh:GetUnitName() == "npc_dota_hero_nevermore"
            and (((eh:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(eh) or 0)) >= 75) then
            local dResEh = U.DistanceBetweenLocations(res, eLoc)
            if (dResEh >= 370 and dResEh <= 520) or (dResEh >= 620 and dResEh <= 780) then
                local fRad = math.rad(eh:GetFacing() or 0)
                local fx, fy = math.cos(fRad), math.sin(fRad)
                local rx, ry = res.x - eLoc.x, res.y - eLoc.y
                local fwdProj = rx * fx + ry * fy
                if fwdProj > 180 then
                    local latSigned = rx * (-fy) + ry * fx
                    if math.abs(latSigned) < 95 then
                        local sgnLat = (latSigned >= 0) and 1.0 or -1.0
                        local bNowLat = bot:GetLocation()
                        if bNowLat then
                            local curLat = (bNowLat.x - eLoc.x) * (-fy) + (bNowLat.y - eLoc.y) * fx
                            if math.abs(curLat) >= 20 then sgnLat = (curLat >= 0) and 1.0 or -1.0 end
                        end
                        local candLat = Vector(res.x + (-fy) * sgnLat * (105 - math.abs(latSigned)),
                            res.y + fx * sgnLat * (105 - math.abs(latSigned)), res.z)
                        if U.IsRayPassable and U.IsRayPassable(res, candLat) then
                            res = candLat
                        end
                    end
                end
            end
        end
    end
    -- XP-Range Tether (`<= 1380u` inside Dota 2 `1500u` XP radius when an enemy creep is dying `<= 160 HP` and we are `>= 220 HP`!):
    if (bot:GetHealth() or 0) >= 220 and enemyCreeps and #enemyCreeps > 0 then
        local dyingCreep, minChp = nil, 161
        for _, ec in pairs(enemyCreeps) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local chp = ec:GetHealth() or 999
                if chp < minChp then minChp, dyingCreep = chp, ec end
            end
        end
        if dyingCreep then
            local dcLoc = dyingCreep:GetLocation()
            if U.DistanceBetweenLocations(res, dcLoc) > 1380 then
                local xpSpot = dcLoc + (fountain - dcLoc):Normalized() * 1360
                local safeT1 = not (wsLive and wsLive.enemyT1Alive ~= false and wsLive.enemyT1Loc
                    and U.DistanceBetweenLocations(xpSpot, wsLive.enemyT1Loc) < 900)
                if safeT1 then
                    res = xpSpot
                end
            end
        end
    end
    -- Fog-of-War Enemy T1 No-Shield Guard (`v3.9.0` + `v7.9.0` FoW `ws.enemy == nil` Fix!):
    -- MUST check `ws.enemyAlive ~= false` (NOT `ws.enemy`, which is `nil` when highground T1 drops into Fog of War!)
    local Wmod = package.loaded["bots/nevermore/world"]
    local ws = Wmod and Wmod.s
    if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc and ws.enemyAlive ~= false and #(allyCreeps or {}) == 0 then
        local tLoc = ws.enemyT1Loc
        local dT1 = U.DistanceBetweenLocations(res, tLoc)
        if dT1 < 895 then
            res = tLoc + (fountain - tLoc):Normalized() * 895
        end
    end
    return P.HoldOwnT1Highground(bot, res, enemyCreeps, allyCreeps)
end

return P
