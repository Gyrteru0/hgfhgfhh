local L = {}

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

L._prepCreep = nil
L._prepStartLAT = -100
L._prepExpire = 0

local RAZE_SPECS = {
    { slot = "nevermore_shadowraze1", idx = 0, dist = 200, radius = 250 },
    { slot = "nevermore_shadowraze2", idx = 1, dist = 450, radius = 250 },
    { slot = "nevermore_shadowraze3", idx = 2, dist = 700, radius = 250 },
}

local function BuildAllAttackers(bot, enemyCreeps, allyCreeps, enemyTowers, allyTowers, enemyHero)
    local enemySide = {} -- Units attacking OUR creeps (for denies)
    local allySide  = {} -- Units attacking ENEMY creeps (for last hits)
    for _, c in pairs(enemyCreeps or {}) do
        if U.CanQuery(c) then enemySide[#enemySide + 1] = c end
    end
    for _, t in pairs(enemyTowers or {}) do
        if U.CanQuery(t) then enemySide[#enemySide + 1] = t end
    end
    if enemyHero and U.CanQuery(enemyHero) then
        enemySide[#enemySide + 1] = enemyHero
        allySide[#allySide + 1]   = enemyHero -- Rival denies count on contested enemy creeps!
    end
    for _, c in pairs(allyCreeps or {}) do
        if U.CanQuery(c) then allySide[#allySide + 1] = c end
    end
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then allySide[#allySide + 1] = t end
    end
    return allySide, enemySide
end
L.BuildAllAttackers = BuildAllAttackers

-- True when the opposing mid hero has zero coil mana (`< 75`), is not mid-cast, and stands well outside
-- physical right-click reach (`> enAtkRange + 150 = 675u`) while we hold enough HP (`>= max(135, 1.6x auto)`):
-- prevents conceding uncontested CS or under-tower prep when the enemy literally cannot punish us!
function L.EnemyCannotPunishLane(bot, enemyHero, hp)
    if not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false end
    local enPotMana = U.GetPotentialManaForRaze(enemyHero) or 0
    if enPotMana >= 75 then return false end
    if enemyHero.IsUsingAbility and enemyHero:IsUsingAbility() then return false end
    local d = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local enAtkRange = (enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525
    if d <= enAtkRange + 150 then return false end
    local raw = ((enemyHero.GetAttackDamage and enemyHero:GetAttackDamage()) or 55) + 4
    local enOneAuto = bot.GetActualIncomingDamage and bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL) or raw
    return (hp or bot:GetHealth() or 0) >= math.max(135, enOneAuto * 1.6)
end

local function IsPositionLethalFromEnemy(bot, checkLoc, enemyHero, race, isDeny, sharedLr)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    local maxHP = math.max(1, bot:GetMaxHealth())
    local hpPct = hp / maxHP
    local bLoc = bot:GetLocation()
    local eLoc = enemyHero:GetLocation()
    local d = U.DistanceBetweenLocations(checkLoc, eLoc)
    local dNow = U.DistanceBetweenLocations(bLoc, eLoc)
    local enPotMana = U.GetPotentialManaForRaze(enemyHero)
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0

    -- 0. Shadowraze Debuff Stack Discipline (`R1_2039` `01:59.73` + `auto-20261022-2237` Death #1 `05:39.03` Root Cause!):
    --   (a) With >= 2 active stacks (`myRem > 0.35s`) and enemy `enPotMana >= 75` (INCLUDING Mango/Stick!),
    --       a 3rd coil hits for `210..380+` magic damage up to `950u` — NEVER turn around toward a creep inside `965u`!
    --   (b) With 1 active stack (`myRem > 0.20s` — INCLUDING fresh `7.8s` stack right after `Shadowraze3` hit at `05:38.80`!):
    --       NEVER step forward inside enemy's READY remaining bands (`W <= 715u` / `Q <= 475u` when `enPotMana >= 75`)!
    --       Conversely, if enemy just spent `Z` (`700u` on `10s` CD), `[720u..900u]` is 100% safe for ranged CS!
    local lrCheck = sharedLr or U.SolveLethalRace(bot, enemyHero, U._W and U._W.s or nil)
    if lrCheck and lrCheck.winsFirstKill then
        return false
    end

    local K = U._K
    local myPotManaEarly = (K and K.MyManaBudget and K.MyManaBudget(bot, true)) or (bot:GetMana() or 0)
    if myStacks >= 2 and myRem > 0.35 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        if d < 980 then return true end
    end
    if myStacks == 1 and myRem > 0.20 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        local readyReach = (K and K.EnemyMinSafeDistance and K.EnemyMinSafeDistance(enemyHero, 0.8)) or 760
        -- When we are ALSO dry (`myPotManaEarly < 75` = 0 coils to answer!), respect the FULL `readyReach` (`~980u` if R3 ready)
        -- immediately instead of capping at `725u` and eating a free stacked `R3` (`ShaNachnetsya` `02:23–02:40` Fix)!
        local forbidDist = (myPotManaEarly < 75 or myRem <= 2.15) and math.max(760, readyReach) or math.min(735, readyReach)
        if d < forbidDist then return true end
    end

    -- 1. NEVER walk into an actively casting enemy Shadowraze circle when raze puts us in combo range or < 55% HP!
    if enemyHero:IsUsingAbility() then
        local eFace = (enemyHero.GetFacing and enemyHero:GetFacing()) or 0
        local rad = math.rad(eFace)
        for _, rz in ipairs({ 200, 450, 700 }) do
            local spot = Vector(eLoc.x + math.cos(rad) * rz, eLoc.y + math.sin(rad) * rz, eLoc.z or 128)
            if U.DistanceBetweenLocations(checkLoc, spot) <= 255 then
                local oneR = (race and race.valid and race.oneRaze) or 220
                if hp <= oneR * 1.85 or hpPct <= 0.58 or myStacks >= 1 then
                    return true
                end
            end
        end
    end
    -- 2. Exact Reachable Burst Check at `checkLoc` over the CS strike window (`0.85s` — NEVER false-blocking safe CS at `700..850u`!):
    if K and K.EnemyBurstVs and not (race and race.valid and race.canKillNow) then
        local burstAtCheck = K.EnemyBurstVs(bot, enemyHero, d, 0.85, false)
        if burstAtCheck + 35 >= hp then
            return true
        end
    end
    local myPotMana = (K and K.MyManaBudget and K.MyManaBudget(bot, true)) or (bot:GetMana() or 0)
    local enCastable = (K and K.EnemyCastableRazeCount and K.EnemyCastableRazeCount(enemyHero, 2.5)) or 0
    local enOneAuto = (K and K.AttackDamageVs and K.AttackDamageVs(enemyHero, bot)) or 52

    -- 2B. Dry-Mana vs Multi-Raze Execution Guard (`9069188041.dem` `02:01.0`, `9070886384.dem` `03:54.40` & `ShaNachnetsya` `02:22–02:40` Fix!):
    -- When we have `< 75` potential mana (ZERO Razes to trade back!), NEVER walk inside `R1` (`< 500u`) against ANY armed SF,
    -- NEVER walk inside `R2` (`< 705u` for denies or `< 665u` for melee CS) against a `2+`-coil (`>= 150 MP`) SF even at full HP
    -- (`874 -> 159 HP` 4-coil shred at `02:22`!), and keep lethal burst thresholds strict. Ranged/max-range CS at `>= 705u` stays open!
    if U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemyHero, U._W and U._W.s) and not (race and race.valid and race.canKillNow) then
        local nearReady = not (K and K.EnemyRazeReadyIn) or K.EnemyRazeReadyIn("near") <= 1.4
        local midReady  = not (K and K.EnemyRazeReadyIn) or K.EnemyRazeReadyIn("mid") <= 1.4
        if nearReady and d < 500 then
            return true
        end
        if enCastable >= 2 and midReady then
            if isDeny and d < 735 then return true end
            -- `v7.9.20` (`1610.dem` `#37/#38/#40` @ `04:59..05:14` `782..869 HP` Under-Own-T1 Dry-CS Fix!):
            -- When standing under our own live allied T1 (`<= 625u`), carrying `0` Shadowraze stacks, and holding
            -- `>= twoCastR + enOneAuto + 155` HP (e.g. `2x Bracer` `869 HP` vs `409` 2-coil dmg), NEVER concede
            -- `500 <= d < 665` last-hits under our own tower to an enemy posturing on the river lip!
            local wsOwn = U._W and U._W.s
            local twoCastOwn = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5)) or 360
            local protectedUnderOwnT1 = (not isDeny)
                and (myStacks == 0)
                and wsOwn and wsOwn.allyT1Alive ~= false and wsOwn.allyT1Loc
                and (U.DistanceBetweenLocations(checkLoc, wsOwn.allyT1Loc) <= 625)
                and (hp >= twoCastOwn + enOneAuto + 155)
            if not protectedUnderOwnT1 and d < 665 then return true end
        end
    end
    if myPotMana < 75 and enCastable >= 2 and not (race and race.valid and race.canKillNow) then
        local twoCastR = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5)) or 0
        if hp <= twoCastR + enOneAuto + 30 and d < 745 then
            return true
        end
        if enCastable >= 3 then
            local threeCastR = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 3, nil, 2.5)) or 0
            if hp <= threeCastR + enOneAuto + 25 and d < 680 then
                return true
            end
        end
    end

    if race and race.valid and not race.canKillNow and not (race.canKillSoon and (race.edge or 0) >= -25) then
        if race.heCanKillNow then
            if d < math.max(780, (race.minSafeDist or 860) - 55) then return true end
        elseif race.heCanKillSoon and not race.canKillSoon then
            local twoR = race.twoRaze or ((race.oneRaze or 180) * 2.2)
            local outLeveledOrBootless = race.heHasBootsLead or ((enemyHero:GetLevel() or 1) > (bot:GetLevel() or 1))
            if outLeveledOrBootless and hp <= twoR + 95 then
                if d < 715 then return true end
            elseif hp <= twoR + 40 and d < 640 then
                return true
            end
        end
    end

    -- 2C. Level-Spike & Out-Razed Tier Respect (`auto-20261031-0230` `00:59.3` Lvl 1 vs Lvl 2, `01:51.1` & `02:00.4` Lvl 2 vs Lvl 3 Fix!):
    --   * At Lvl 1 vs Lvl 2+, enemy has `Necromastery + Raze` while we have 0 Necromastery (`43` dmg) — NEVER step into `d < 605`
    --     when below `430 HP` or surrounded by enemy creeps!
    --   * When down a Raze tier (`Lvl 2 vs Lvl 3` = `69` vs `124+161 = 285` dmg!), NEVER walk forward into `R2` (`d < 720u`)
    --     to deny an allied creep (`isDeny == true`), nor enter `d < 695u` when enemy holds `>= 2` castable Razes!
    local myLvlNow = (bot.GetLevel and bot:GetLevel()) or 1
    local enLvlNow = (enemyHero.GetLevel and enemyHero:GetLevel()) or 1
    local outLeveledNow = enLvlNow > myLvlNow
    local outRazedNow = (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemyHero)) or (myLvlNow == 1 and enLvlNow >= 2)
    if outLeveledNow and not (race and race.valid and race.canKillNow) then
        local wsCheck = U._W and U._W.s
        local nearEnemyCreeps = 0
        for _, ec in pairs((wsCheck and wsCheck.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(checkLoc, ec:GetLocation()) <= 285 then
                nearEnemyCreeps = nearEnemyCreeps + 1
            end
        end
        if myLvlNow == 1 and (hp <= 430 or nearEnemyCreeps >= 2) and d < 605 then
            return true
        end
        if outRazedNow and enCastable >= 1 then
            local twoCastOut = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5))
                or ((K and K.EnemyRazeDamage and K.EnemyRazeDamage(bot, enemyHero, 2)) or 260)
            if isDeny and d < dNow - 12 and d < 725 and hp <= twoCastOut + enOneAuto * 1.5 + 150 then
                return true
            end
            if enCastable >= 2 and d < 695 and hp <= twoCastOut + enOneAuto + 265 then
                return true
            end
        end
    end

    -- 3. Low-HP lethal burst & close physical execution fallback (`auto-20261031-0230` `02:08.3` `180 HP` vs `68 MP` Lvl-3 SF Fix!):
    --    Even if `enPotMana < 75`, walking inside `<= 665u` at `<= 3.25` right-clicks of HP hands enemy lethal physical autos!
    local enRangeCheck = (enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525
    if hp <= math.max(210, enOneAuto * 3.25) and not (race and race.valid and race.canKillNow) then
        if d < enRangeCheck + 145 then return true end
    end
    if hpPct <= 0.36 and enPotMana >= 150 then
        if d < 595 then return true end
    end
    -- 4. No Walk-Through-Enemy for Out-of-Range Back-Wave Creep (`R1_2039` `02:35` & `R2_2044` `02:31` Fix!):
    -- If reaching `checkLoc` requires WALKING closer to a live non-lethal `enemyHero` (`moveDist > 25` & `d < dNow - 15`),
    -- NEVER walk straight through `enemyHero` (`d < 340`) or into active right-click focus when behind in HP!
    local moveDist = U.DistanceBetweenLocations(bLoc, checkLoc)
    local enHp = enemyHero:GetHealth() or 999
    -- `auto-20261102-0007` `10:07.53` (`325 HP` @ `d=414u`) In-Range Flee Turn-Back Fix:
    -- Even when `moveDist == 0` (creep ALREADY inside `525u` range), stopping `0.55s` + spinning `162 deg` backward
    -- while actively fleeing a healthy pursuing hero (`dNow < 760` & `hp <= 360` & `hp < enHp - 180`) is lethal!
    local stNow = U._State
    local nowG = GameTime()
    local activeCritFlee = stNow and (nowG < (stNow.critDangerHystUntil or 0) or nowG < (stNow.fleeUntil or 0))
    if (activeCritFlee or (hp <= 360 and hp < enHp - 180)) and enHp > 240 and dNow < 760
        and not (race and race.valid and (race.canKillNow or race.canKillSoon)) then
        local beingChasedOrHit = (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8))
            or ((U.EnemyApproachSpeed and U.EnemyApproachSpeed(bot, enemyHero) or 0) > 55)
        if beingChasedOrHit then
            return true
        end
    end
    if moveDist > 25 and d < dNow - 15 and enHp > 205 then
        if d < 340 then return true end
        local beingHit = (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.5))
        -- `v4.2.0` Equal-State Stand-Ground Rule (`Demo 2` 25-concession fix!):
        -- NEVER abandon every creep in `560u` on EVEN or WINNING HP (`hp >= enHp - 95` or `hp > 430`)!
        if beingHit and d < 560 and ((hp < enHp - 95 and hp <= 430) or hp <= 285) then
            return true
        end
    end
    return false
end
L.IsPositionLethalFromEnemy = IsPositionLethalFromEnemy

-- Evaluate every enemy & ally creep on exact 30 Hz integer trajectory ticks
function L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, enemyHero, race)
    local candidates = {}
    local sharedLr = (enemyHero and U.CanQuery(enemyHero))
        and U.SolveLethalRace(bot, enemyHero, U._W and U._W.s or nil) or nil
    local bLocScan = bot:GetLocation()
    -- Source 2 Hull-to-Hull Creep Attack Reach (`9074178342.dem` `02:13.8..02:14.7` `tk=7080..7128` `R#1537` Fix!):
    -- Hero (`24u` hull) attacking lane creep (`16..24u` hull) launches without walking up to `atkRange + 40u` (`540..565u`
    -- center-to-center; verified at `tk=7116` where SF launched attack on `R#1537` from `d=531.0u` with `atkRange=500`).
    -- Using `+18` falsely projected a `13..35u` forward step (`moveDist > 25`), flickering `lethalRightClick` on the ramp!
    local maxR = (bot:GetAttackRange() or 500) + 40

    local function evalList(list, isDeny, attackers)
        local curTickScan = math.floor(GameTime() * 30.0 + 0.5)
        local ownRec = U._unitTrack[bot]
        local curAtkTarget = (bot.GetAttackTarget and bot:GetAttackTarget()) or nil
        for _, c in pairs(list or {}) do
            if U.CanQuery(c) and c:GetHealth() > 0 then
                local kOpen, kTargetImpact, effClose, gamble, ctx = U.GetExactKillableInfo(bot, c, attackers)
                if kOpen ~= -2 then -- -2 = already fatally struck by our own mid-air projectile!
                    local totalT, launchT, wT, fT, turnT, walkT, cdT = U.GetExactBallisticTicks(bot, c)
                    -- `A01` Mid-Swing Preservation: keep remaining `(launchTick - curTick) + fT` ONLY inside `SelectBestRightClickPlan`
                    -- reachability check (`effT <= effClose + 1`) while `ExecutePhaseLockedCS` uses pristine `totalT`!
                    local activeRemT = nil
                    if ownRec and ownRec.wasAnim and ownRec.launchTick and ownRec.launchTick >= curTickScan and curAtkTarget == c then
                        activeRemT = (ownRec.launchTick - curTickScan) + fT
                    end
                    local cLoc = c:GetLocation()
                    local distNow = U.DistanceBetweenLocations(bLocScan, cLoc)
                    local reqLoc = bLocScan
                    if distNow > maxR then
                        reqLoc = cLoc + (bLocScan - cLoc):Normalized() * (maxR - 12)
                    end
                    local lethalRightClick = IsPositionLethalFromEnemy(bot, reqLoc, enemyHero, race, isDeny, sharedLr)
                    local nm = c:GetUnitName() or ""
                    local isRangedCreep = nm:find("ranged") ~= nil
                    local isSiegeCreep  = nm:find("siege") ~= nil
                    candidates[#candidates + 1] = {
                        creep = c,
                        isDeny = isDeny,
                        isRanged = isRangedCreep,
                        isSiege = isSiegeCreep,
                        kOpen = kOpen,
                        kTargetImpact = kTargetImpact,
                        effClose = effClose,
                        gamble = gamble,
                        ctx = ctx,
                        totalT = totalT,
                        activeRemT = activeRemT,
                        launchT = launchT,
                        wT = wT,
                        fT = fT,
                        turnT = turnT,
                        walkT = walkT,
                        cdT = cdT,
                        distNow = distNow,
                        reqLoc = reqLoc,
                        lethalRightClick = lethalRightClick,
                    }
                end
            end
        end
    end

    evalList(enemyCreeps, false, allySideAttackers)
    evalList(allyCreeps, true, enemySideAttackers)
    return candidates
end

-- Select optimal right-click target with strict Last-Hit > Deny collision arbitration
function L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0)
    -- Earliest enemy last-hit opening & closing ticks so a deny NEVER steals attack cooldown from an imminent last hit!
    local earliestEnemyOpen = 9999
    local earliestEnemyClose = 9999
    local earliestEnemyTotal = 18
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and not cand.lethalRightClick and cand.kOpen >= 0 and cand.kOpen < 900 then
            local effT = cand.activeRemT or cand.totalT
            if effT <= cand.effClose + 1 and cand.kOpen < earliestEnemyOpen then
                earliestEnemyOpen = cand.kOpen
                earliestEnemyClose = cand.effClose
                earliestEnemyTotal = cand.totalT
            end
        end
    end

    local best = nil
    local bestScore = -1e9

    local wsSel = U._W and U._W.s or nil
    local enemyDeadSel = wsSel and wsSel.enemyAlive == false
    local isDominantCS = (not siegingEnemyT1) and U.IsLaneDominant and U.IsLaneDominant(bot, nil, nil) or false
    local denyMaxSlack = siegingEnemyT1 and 3 or (enemyDeadSel and 22 or (isDominantCS and 16 or 10))
    for _, cand in ipairs(candidates) do
        local effT = cand.activeRemT or cand.totalT
        local horizonOk = (not cand.isDeny and cand.kOpen >= 0 and cand.kOpen <= 68)
            or (cand.isDeny and cand.kOpen >= 0 and (cand.kTargetImpact - cand.totalT) <= denyMaxSlack)
        if not cand.lethalRightClick and horizonOk then
            if effT <= cand.effClose + 1 then
                local blocksEnemyLH = false
                if cand.isDeny and earliestEnemyOpen < 900 then
                    local denyLaunch = (cand.activeRemT ~= nil)
                        and math.max(0, cand.activeRemT - cand.fT)
                        or math.max(cand.launchT, cand.kTargetImpact - cand.fT)
                    local nextReadyImpact = denyLaunch + spaTicks + earliestEnemyTotal
                    local latestSafeEnemyImpact = math.max(earliestEnemyOpen + 2, math.min(earliestEnemyOpen + 10, earliestEnemyClose))
                    if nextReadyImpact > latestSafeEnemyImpact then
                        blocksEnemyLH = true
                    end
                end

                if not blocksEnemyLH then
                    -- Exact Urgency Score:
                    -- 1. Enemy Last-Hit strongly beats simultaneous Deny (+400 priority)
                    -- 2. Earlier kTargetImpact comes first so multiple creeps in sequence get 100% chained!
                    -- 3. Ranged / Flagbearer / Siege tie-break bonus + Soul-Economy bonus below Necromastery cap
                    local typePrio = cand.isDeny and 0.0 or 400.0
                    local valueBonus = (cand.isRanged or cand.isSiege) and 22.0 or 0.0
                    local gamblePen = cand.gamble and -6.0 or 0.0
                    local soulBonus = 0.0
                    if not cand.isDeny then
                        local S = U._S
                        if S and S.GetSouls then
                            local mySouls = S.GetSouls(bot) or 0
                            local cap = (S.GetMaxSouls and S.GetMaxSouls(bot)) or ((C.LASTHIT and C.LASTHIT.SOUL_CAP) or 20)
                            if mySouls < cap then
                                soulBonus = ((C.LASTHIT and C.LASTHIT.SOUL_LH_BONUS) or 14.0)
                                    * (1.0 - math.min(1.0, mySouls / math.max(1, cap)) * 0.5)
                            end
                        end
                    end
                    local score = typePrio + valueBonus + gamblePen + soulBonus - (cand.kTargetImpact * 3.0)
                    if score > bestScore then
                        bestScore = score
                        best = cand
                    end
                end
            end
        end
    end

    return best
end

-- Backwards-compatible public helper used by legacy callers in bot_nevermore.lua
function L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    U.BeginPredictionFrame()
    local cands = L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allyAttackers, enemyAttackers, nil, nil)
    local best = L.SelectBestRightClickPlan(bot, cands, true)
    if best then
        return best.creep, best.isDeny, best
    end
    return nil, false, nil
end

-- Dual-Value Shadowraze CS (`Enemy Hero + Creep in Same 250u Coil`) + Exact Pre-Impact Alive Check:
-- Verified on live replay `auto-20261021-1713-start-ShaNachnetsya.dem` (`tk=14946 -> 14950 -> 14964`):
--   1. NEVER waste Shadowraze on a solo creep when the enemy hero is NOT inside that same 250u coil!
--   2. ONLY cast Shadowraze for CS when:
--      (A) PRIMARY DUAL-VALUE COIL (`heroInSameCoil == true`): `enemyHero` is alive, visible,
--          AND inside `235u` of `rSpot` BOTH right now AND at impact (`+0.55s`), taking BOTH
--          the +43g creep last-hit AND full Hero Shadowraze nuke + stack in a single 75-mana cast!
--      (B) SIMULTANEOUS MULTI-CREEP RESCUE (`multiKills >= 2` with `mana >= 165`): 2+ enemy creeps
--          dying simultaneously in the same 250u circle that right-click cooldown CANNOT reach both.
--   3. STRICT PRE-IMPACT ALIVE CHECK: `hpAlive > 10` at `(castTotalT - 1)` ticks is MANDATORY
--      (NO `or cand.effClose >= castTotalT` bypass!) so we NEVER start a 0.55s coil on a creep
--      already doomed to an incoming tower/creep projectile (`tk=14950`), AND every cast invokes
--      `startRazeCb(ab, c, rSpot, 250, true)` for 0-tick `Action_ClearActions(true)` S-cancel!
function L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb)
    local mana = bot:GetMana() or 0
    if mana < 75 then return false end
    local razeCastTicks = (C.BALLISTIC and C.BALLISTIC.RAZE_CAST_TICKS) or 17
    local bLoc = bot:GetLocation()
    local curYaw = (bot.GetFacing and bot:GetFacing()) or 0
    local degPerTick = math.deg((C.BALLISTIC and C.BALLISTIC.SF_TURN_RATE) or 0.90)
    local hasHero = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
    -- Stack-Discipline Self-Root Guard (`R1_2039` `01:59.73` Fix!):
    -- NEVER self-root `0.55s` casting a non-hero-kill creep raze when:
    --   (a) we carry `>= 2` enemy raze stacks (`myRem > 0.3s`), OR
    --   (b) our 1st enemy raze stack is `<= 2.20s` from expiring completely while enemy can follow up with `W`/`Q`!
    local enemyStackedForFollowup = false
    local enemyOutwardSpd = 0
    if hasHero then
        local mySt, myRem = U.GetShadowrazeDebuff(bot)
        local enSt, enRem = U.GetShadowrazeDebuff(enemyHero)
        local enPotMana = U.GetPotentialManaForRaze(enemyHero)
        local dHero = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
        if U.EnemyOutwardSpeed then
            enemyOutwardSpd = U.EnemyOutwardSpeed(bot, enemyHero) or 0
        end
        -- `9072025270.dem` `05:48.53` (`#41`) Fix: NEVER burn `Shadowraze1` / `Shadowraze2` on creep-only double-kills
        -- right after landing a stack on `enemyHero` (`enSt >= 1`) or when `enemyHero` is in active kill range!
        if dHero <= 1050 and (((enSt or 0) >= 1 and (enRem or 0) >= 1.40)
            or ((enemyHero:GetHealth() or 9999) <= 470 and dHero <= 940)) then
            enemyStackedForFollowup = true
        end
        if enPotMana >= 75 then
            if (mySt or 0) >= 2 and (myRem or 0) > 0.30 and dHero < 1020 then
                return false
            end
            if (mySt or 0) == 1 and (myRem or 0) > 0.20 and (myRem or 0) <= 2.20 and dHero < 810 then
                return false
            end
        end
    end

    local bestAb, bestCand, bestSpot, bestAng, bestScore = nil, nil, nil, 0, -1
    local bestSpecDist, bestMustHitHero = 450, false
    local outRazed = hasHero and U.IsOutRazedTier and U.IsOutRazedTier(bot, enemyHero) or false
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and cand.creep and U.CanQuery(cand.creep)
            and cand.creep:IsAlive() and cand.creep:GetHealth() > 0 then
            local c = cand.creep
            local cLoc = c:GetLocation()
            local d = U.DistanceBetweenLocations(bLoc, cLoc)

            for _, spec in ipairs(RAZE_SPECS) do
                if math.abs(d - spec.dist) <= (spec.radius - 16) then
                    local ab = U.GetAbility(bot, spec.slot)
                    if ab and ab:IsFullyCastable() then
                        local baseDmg = U.GetRazeDamage(bot, ab)
                        local magicDmg = math.floor(c:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))

                        -- Solve BOTH direct creep yaw AND 2D Dual-Value midpoint yaw (`0.5 * (cLoc + hPred)`)
                        -- so off-axis `Creep + Hero` pairs inside the same 250u Shadowraze circle are NEVER missed!
                        local aimYaws = {}
                        local creepYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
                        if hasHero then
                            local roughPred = U.PredictPosition(enemyHero, razeCastTicks / 30.0)
                            local mx = 0.5 * (cLoc.x + roughPred.x)
                            local my = 0.5 * (cLoc.y + roughPred.y)
                            if math.abs(mx - bLoc.x) > 1 or math.abs(my - bLoc.y) > 1 then
                                aimYaws[#aimYaws + 1] = math.deg(math.atan2(my - bLoc.y, mx - bLoc.x)) % 360
                            end
                        end
                        aimYaws[#aimYaws + 1] = creepYaw

                        for _, wantYaw in ipairs(aimYaws) do
                            local ang = math.abs(((wantYaw - curYaw + 180) % 360) - 180)
                            local turnT = (ang > 11.5) and math.ceil((ang - 11.5) / degPerTick) or 0
                            local castTotalT = turnT + razeCastTicks
                            local tImpact = castTotalT / 30.0
                            local tBefore = math.max(0.033, (castTotalT - 1) / 30.0)
                            local hpAtCast = U.PredictHPWithContext(cand.ctx, c, tImpact, "max")
                            local hpAlive  = U.PredictHPWithContext(cand.ctx, c, tBefore, "min")
                            local rad = math.rad(wantYaw)
                            local rSpot = Vector(bLoc.x + math.cos(rad) * spec.dist, bLoc.y + math.sin(rad) * spec.dist, bLoc.z or 128)

                            local creepHitLim = ((C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266) - 12 -- 254u (12u inside 266u creep hull)
                            local heroHitLim  = ((C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274) - 16  -- 258u (16u inside 274u hero hull)
                            -- `auto-20261102-0159-start-ShaNachnetsya.dem` `11:05.3` Whiff #1 Fix:
                            -- Verify BOTH current `cLoc` AND extrapolated `cPred` (`tImpact = 0.55s+`) lie inside `rSpot`
                            -- so an unengaged creep marching inward toward Enemy T1 NEVER walks out of our coil during cast!
                            local cPred = U.PredictPosition(c, tImpact)
                            if hpAlive > 14 and hpAtCast > 0 and hpAtCast <= magicDmg
                                and U.DistanceBetweenLocations(rSpot, cLoc) <= creepHitLim
                                and U.DistanceBetweenLocations(rSpot, cPred) <= (creepHitLim - 6) then
                                local heroInSameCoil = false
                                if hasHero then
                                    local hNow = enemyHero:GetLocation()
                                    local hPred = U.PredictPosition(enemyHero, tImpact)
                                    local dHeroNow = U.DistanceBetweenLocations(bLoc, hNow)
                                    -- `9072025270.dem` `02:49.73` (`#24` `dStart=912.3u -> dEnd=999.1u`) Fix:
                                    -- When `enemyHero` is actively walking away (`enemyOutwardSpd >= 40`) OR already standing on
                                    -- the outer rim (`dHeroNow >= spec.dist + 185`), require `<= 205u` / `198u` so we NEVER commit
                                    -- a 1-melee-creep dual-value raze onto a hero who walks out in `0.3s`!
                                    local onOuterEscapeRim = (enemyOutwardSpd >= 40) or (dHeroNow >= spec.dist + 185)
                                    local effHeroNowLim  = onOuterEscapeRim and 205 or heroHitLim
                                    local effHeroPredLim = onOuterEscapeRim and 198 or (heroHitLim - 12)
                                    if U.DistanceBetweenLocations(rSpot, hNow) <= effHeroNowLim
                                        and U.DistanceBetweenLocations(rSpot, hPred) <= effHeroPredLim then
                                        heroInSameCoil = true
                                    end
                                end

                                -- AoE Splash Safety + Multi-Creep Kill Count across all enemy creeps (`266u` exact creep hull!)
                                local splashCheckRad = (C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266
                                local ruinsOtherCreep = false
                                local multiKills = 1
                                for _, oc in ipairs(candidates) do
                                    if not oc.isDeny and oc.creep ~= c and U.CanQuery(oc.creep) and oc.creep:IsAlive() then
                                        if U.DistanceBetweenLocations(rSpot, oc.creep:GetLocation()) <= splashCheckRad then
                                            local oDmg = math.floor(oc.creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))
                                            local oRem = oc.creep:GetHealth() - oDmg
                                            local oMin = U.SFDamageRange(bot, oc.creep).min
                                            if oRem <= 0 then
                                                multiKills = multiKills + 1
                                            elseif oRem > 0 and oRem <= oMin + 28 then
                                                ruinsOtherCreep = true
                                                break
                                            end
                                        end
                                    end
                                end

                                local rightClickImpossible = cand.lethalRightClick
                                    or (cand.kOpen == -1 and cand.effClose >= castTotalT)
                                    or (cand.kOpen >= 0 and cand.totalT > cand.effClose + 1)
                                local holdFollowupBand = enemyStackedForFollowup
                                    and (spec.slot == "nevermore_shadowraze1" or spec.slot == "nevermore_shadowraze2")
                                -- `v7.9.13-pro` + `v7.9.16-pro` (`1343 @ 05:32.60` `Q200` CS Self-Root & `183->110 MP` Trap Fix!):
                                -- When a live armed rival SF (`enHp > 350`, `enPotMana >= 140`) is within `1,550u`:
                                --   1. NEVER spend a pure creep-only raze (`not heroInSameCoil`) if `W` or `E` is on cooldown (`> 0.75s`);
                                --   2. At `level >= 3`, require `mana >= 225` (`>= 150 MP` post-cast = 2 combat coils preserved);
                                --   3. Kinematic Self-Root Veto: NEVER self-root `0.55s` for a pure-creep `Q200` (or close `W450`) when the
                                --      armed enemy SF can walk to `<= 545u` (`W450 + Q200` triple-coil trap!) during our `0.58s` root!
                                local armedRivalCloseForReserve = false
                                local otherMidFarAlreadyOnCd = false
                                local selfRootInWalkInZone = false
                                if hasHero and not heroInSameCoil then
                                    local dHeroRes = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
                                    if dHeroRes <= 1550 and (enemyHero:GetHealth() or 0) > 350
                                        and U.GetPotentialManaForRaze(enemyHero) >= 140 then
                                        armedRivalCloseForReserve = true
                                        local wRes = U.GetAbility(bot, "nevermore_shadowraze2")
                                        local eRes = U.GetAbility(bot, "nevermore_shadowraze3")
                                        local wOnCdRes = wRes and wRes:GetLevel() > 0 and (wRes:GetCooldownTimeRemaining() or 0) > 0.75
                                        local eOnCdRes = eRes and eRes:GetLevel() > 0 and (eRes:GetCooldownTimeRemaining() or 0) > 0.75
                                        otherMidFarAlreadyOnCd = (wOnCdRes or eOnCdRes) and true or false
                                        if spec.slot == "nevermore_shadowraze1"
                                            or (spec.slot == "nevermore_shadowraze2" and d < 500) then
                                            local enMsRes = enemyHero:GetCurrentMovementSpeed() or 320
                                            if (dHeroRes - enMsRes * 0.58) <= 545 then
                                                selfRootInWalkInZone = true
                                            end
                                        end
                                    end
                                end
                                local minCreepRazeMana = (armedRivalCloseForReserve and (bot:GetLevel() or 1) >= 3) and 225 or 165
                                local allowDoubleCreepRescue = (not heroInSameCoil)
                                    and (not holdFollowupBand)
                                    and (not otherMidFarAlreadyOnCd)
                                    and (not selfRootInWalkInZone)
                                    and multiKills >= 2
                                    and rightClickImpossible
                                    and mana >= minCreepRazeMana
                                -- Pro Anti-Freeze & Contested-Deny Ranged-Creep Rescue:
                                --   1. When zoned (`d >= 530` or `outRazed`) and right-click cannot reach, rescue with `E` (or `W` at `>= 530u`).
                                --   2. When rival SF stands inside deny reach (`<= 560u` of ranged creep) with a physical damage lead
                                --      (`enDenyAvg >= myMin + 8`) and the ranged creep has ALREADY entered rival SF's legal 1-shot deny zone
                                --      (`myMin + 4 < cHp <= enDenyAvg + 10` & `< 50%` MaxHP), execute it with Raze before rival SF denies +69 XP!
                                local minRangedRazeMana = (armedRivalCloseForReserve and otherMidFarAlreadyOnCd) and 225 or 145
                                local allowZonedRangedRescue = (not heroInSameCoil)
                                    and cand.isRanged
                                    and (spec.slot == "nevermore_shadowraze3" or (spec.slot == "nevermore_shadowraze2" and d >= 530))
                                    and rightClickImpossible
                                    and (outRazed or d >= 530)
                                    and mana >= minRangedRazeMana
                                local allowContestedRangedDenySteal = false
                                if (not heroInSameCoil) and cand.isRanged and hasHero and mana >= 150
                                    and (spec.slot == "nevermore_shadowraze2" or spec.slot == "nevermore_shadowraze3") then
                                    local cHpNow = c:GetHealth() or 999
                                    local cMaxHp = math.max(1, c:GetMaxHealth() or 300)
                                    -- Proactive `17`-tick (`0.55s`) Deny-Steal Forecast: start Raze windup BEFORE/AS the ranged
                                    -- creep enters rival SF's deny threshold (`hpAtCast <= enDenyAvg + 12`), landing on frame 0!
                                    if (cHpNow * 2 < cMaxHp + 35) and U.DistanceBetweenLocations(enemyHero:GetLocation(), cLoc) <= 565 then
                                        local myMinR = U.SFDamageRange(bot, c).min
                                        local enDenyAvg = U.SFDamageRange(enemyHero, c).avg
                                        if enDenyAvg >= myMinR + 8 and hpAtCast > myMinR + 3 and hpAtCast <= enDenyAvg + 12 then
                                            allowContestedRangedDenySteal = true
                                        end
                                    end
                                end

                                -- `v7.9.8-pro` (`1630 @ 02:35.87` `111 MP` & `1638 @ 02:16.00` `92 MP` 1-Coil Mana-Trap Fix!)
                                -- + `v7.9.17-pro` (`1507 @ 07:12.33` Close Dual-Value Self-Root Veto vs Armed/Higher-Tier SF!):
                                -- NEVER self-root `0.55s` on a close `Q(200)` / `W(450)` dual-value CS coil (`spec.dist < 650`) when
                                -- the enemy hero survives the coil AND either:
                                --   (a) we become dry (`mySustainedM < 145`) vs `enPotM >= 150`, OR
                                --   (b) inside `dHeroTrap <= 525u` (`Q+W+AA` walk-in zone!), the enemy holds `2+` coils (`enPotM >= 145`)
                                --       and out-tiers our Raze (`outRazed`, e.g. L7 L4 Raze vs L6 L3 Raze!), we already carry a stack,
                                --       or his `2-raze + 1 AA` counter-burst chunks `>= 66%` of our current HP (`leaving us 1-shot to E700!`).
                                local singleCoilCloseTrap = false
                                if heroInSameCoil and hasHero and spec.dist < 650 then
                                    local mySustainedM = (U._K and U._K.MySustainedManaBudget and U._K.MySustainedManaBudget(bot, 6.5))
                                        or (mana + (U.GetMangoMana and U.GetMangoMana(bot) or 0) + (U.GetStickCharges and U.GetStickCharges(bot) or 0) * 15)
                                    local enPotM = U.GetPotentialManaForRaze(enemyHero) or 0
                                    local dHeroTrap = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
                                    local oneRazeDmg = (U.GetNRazeDamage and U.GetNRazeDamage(bot, enemyHero, 1)) or magicDmg
                                    local enHpTrap = enemyHero:GetHealth() or 9999
                                    if enHpTrap > (oneRazeDmg + 55) then
                                        if mySustainedM < 145 and enPotM >= 150 and dHeroTrap < 660
                                            and enHpTrap > (oneRazeDmg + 95) then
                                            singleCoilCloseTrap = true
                                        elseif dHeroTrap <= 525 and enPotM >= 145 then
                                            local myCurHpTrap = bot:GetHealth() or 600
                                            local myStacksTrap = (U.GetShadowrazeDebuff and select(1, U.GetShadowrazeDebuff(bot))) or 0
                                            local enTwoRaze = (U.GetNRazeDamage and U.GetNRazeDamage(enemyHero, bot, 2)) or 340
                                            local enOneAuto = (U._K and U._K.AttackDamageVs and U._K.AttackDamageVs(enemyHero, bot)) or 68
                                            local enReadyCnt = (U._K and U._K.EnemyReadyRazeCount and U._K.EnemyReadyRazeCount(enemyHero, 0.85, true)) or 2
                                            local closeWalkInDist = (spec.slot == "nevermore_shadowraze1" and 495) or 395
                                            if enReadyCnt >= 2 and dHeroTrap <= closeWalkInDist
                                                and (outRazed
                                                    or (myStacksTrap or 0) >= 1
                                                    or (enTwoRaze + enOneAuto >= myCurHpTrap * 0.66)) then
                                                singleCoilCloseTrap = true
                                            end
                                        end
                                    end
                                end

                                if not ruinsOtherCreep and not singleCoilCloseTrap
                                    and (heroInSameCoil or allowDoubleCreepRescue or allowZonedRangedRescue or allowContestedRangedDenySteal) then
                                    local creepOnlyLegal = allowDoubleCreepRescue or allowZonedRangedRescue or allowContestedRangedDenySteal
                                    local score = (heroInSameCoil and 1000 or (allowDoubleCreepRescue and 240 or 180))
                                        + multiKills * 90
                                        + (cand.isRanged and 55 or 20)
                                        - turnT * 8
                                    if score > bestScore then
                                        bestAb = ab
                                        bestCand = cand
                                        bestSpot = rSpot
                                        bestAng = ang
                                        bestScore = score
                                        bestSpecDist = spec.dist
                                        bestMustHitHero = heroInSameCoil and (not creepOnlyLegal)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if bestAb and bestCand and bestSpot then
        -- Exact Current-Yaw Circle Verification (`v7.9.2`, `TWO_ANALYSES_REVIEW_RU.md` `P0-01` + `9072025270` `#24` Fix!):
        -- NEVER fire `Action_UseAbility` on a blind `t+1` assumption; verify directly on `curYaw` that `curSpot` covers
        -- `bestCand.creep` (and `enemyHero` when `bestMustHitHero == true`, corresponding to exact `cos θ_max = (r^2+d^2-R^2)/(2rd)`)!
        local curRad = math.rad(curYaw)
        local curSpot = Vector(
            bLoc.x + math.cos(curRad) * bestSpecDist,
            bLoc.y + math.sin(curRad) * bestSpecDist,
            bLoc.z or 128
        )
        local creepHitLimNow = ((C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266) - 12
        local heroHitLimNow  = (enemyOutwardSpd >= 45) and 212 or (((C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274) - 22)
        local cPredNow = U.PredictPosition(bestCand.creep, razeCastTicks / 30.0)
        local curCoversCreep = U.DistanceBetweenLocations(curSpot, bestCand.creep:GetLocation()) <= creepHitLimNow
            and U.DistanceBetweenLocations(curSpot, cPredNow) <= (creepHitLimNow - 6)
        local curCoversHero  = true
        if bestMustHitHero and hasHero then
            local hPredNow = U.PredictPosition(enemyHero, razeCastTicks / 30.0)
            curCoversHero = U.DistanceBetweenLocations(curSpot, enemyHero:GetLocation()) <= (heroHitLimNow + 8)
                and U.DistanceBetweenLocations(curSpot, hPredNow) <= heroHitLimNow
        end
        if curCoversCreep and curCoversHero and bestAng <= 24.0 then
            L._razeTurnStampAt = nil
            local valRad = (C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266
            local mustHeroArg = (bestMustHitHero and hasHero) and enemyHero or nil
            if startRazeCb then
                startRazeCb(bestAb, bestCand.creep, curSpot, valRad, true, mustHeroArg)
            else
                bot:Action_UseAbility(bestAb)
            end
        else
            L._razeTurnStampAt = GameTime()
            local turnPt = bLoc + (bestSpot - bLoc):Normalized() * 36
            if bot.Action_MoveDirectly then
                bot:Action_MoveDirectly(turnPt)
            else
                bot:Action_MoveToLocation(turnPt)
            end
        end
        return true
    end
    return false
end

-- Exact Algebraic Under-Tower HP Prep Solver (Zero Over-Attack Guarantee via m_flLastAttackTime lock)
function L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, allyTowers, enemyTowers, candidates, enemyHero, race)
    local curLAT = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
    if L._prepExpire and GameTime() < L._prepExpire - 2.0 then
        L._prepCreep = nil
        L._prepExpire = 0
    end
    -- CRITICAL (`9056469656.dem` `01:20` Root Cause!):
    -- Valve C++ `CDOTA_BaseNPC::StartAttack` stamps `m_flLastAttackTime` on TICK 1 of windup (`0.46s` BEFORE launch!),
    -- so checking `curLAT > L._prepStartLAT` S-cancelled 100% of under-tower prep swings on frame 2 without firing 1 bolt!
    -- Instead, detect actual projectile release directly from `L._prepCreep:GetIncomingTrackingProjectiles()` (`p.caster == bot`)!
    -- `9071946472.dem` `03:41.47–03:43.10` Dry-Mana Retreat Turnback Fix:
    -- NEVER let a non-lethal under-tower prep swing (`143 HP` melee creep) abort an active forced/dry-mana retreat
    -- or drag a `< 75 MP` SF `230u` forward (`782u -> 546u`) back into an armed enemy SF's right-clicks & Shadowrazes!
    local nowPrep = GameTime()
    local retreatLockedPrep = U._State and (nowPrep < (U._State.forcedRetreatUntil or 0)
        or nowPrep < (U._State.dryRetreatHystUntil or 0))
    local dryThreatPrep = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
        and U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemyHero, nil)
        and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 860
    if retreatLockedPrep or dryThreatPrep then
        if L._prepCreep then
            L._prepCreep = nil
            L._prepExpire = 0
        end
        return false
    end

    if L._prepCreep then
        local launched = false
        if U.CanQuery(L._prepCreep) then
            for _, p in pairs(U.SafeGetIncomingProjectiles(L._prepCreep)) do
                if p.is_attack and p.caster == bot then
                    launched = true
                    break
                end
            end
        end
        if not U.CanQuery(L._prepCreep) or GameTime() > L._prepExpire or launched then
            if launched then
                bot:Action_ClearActions(true)
            end
            L._prepCreep = nil
            L._prepExpire = 0
        else
            -- Keep finishing the single locked prep swing unless an urgent CS just opened
            return true
        end
    end

    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0)
    -- Never start a prep hit if ANY creep needs a real last hit / deny within spaTicks + 16 ticks!
    for _, cand in ipairs(candidates) do
        if cand.kOpen >= 0 and cand.kOpen <= spaTicks + 16 and not cand.lethalRightClick then
            return false
        end
    end

    -- Never distract SF from executing a low-HP enemy hero (`<= 350 HP`, e.g. `S29` `02:32.92` `284 HP` ramp brawl!),
    -- nor swing prep hits while low HP & being poked (`2:48` fix!)
    if enemyHero and U.CanQuery(enemyHero) and (enemyHero:GetHealth() or 9999) <= 350
        and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 700 then
        return false
    end
    local beingPokedNow = enemyHero and U.CanQuery(enemyHero)
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    if beingPokedNow and (bot:GetHealth() or 9999) <= 380 then
        return false
    end

    -- Exact 1- & 2-Step Ballistic Modular Under-Tower Prep (`9056469656.dem` `01:20` Lvl 2 `58..64` vs `550 HP` Fix!):
    -- Why `k in {1, 2}` prep steps is mandatory under T1:
    --   - At Lvl 2 (`myMin = 58, myAvg = 61`) vs `550 HP` melee under T1 (`tDmg = 97`):
    --     * `0` preps -> `550 - 5*97 = 65 HP > 58` (T1 steals 3/3 melee creeps at `01:20`!).
    --     * `1` prep  -> `550 - 61 - 4*97 = 101 HP` -> `101 - 97 = 4 HP` (still needs a 2nd prep!).
    --     * `2` preps -> `550 - 2*61 - 4*97 = 40 HP` inside `[5, 56]` -> `100%` clean 1-shot CS!
    --   - Meanwhile, on Ranged creeps (`300 - 2*109 = 82 <= 84` or `300 - 3*97 = 9 <= 58`), `rem0` ALREADY lies in
    --     `[1, myMin]`, so `remNow > myMin` is `false` -> `0` preps fired, NEVER breaking an already clean 1-shot!
    local mySpa = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.25
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then
            local _, _, towerRawAvg = U.SampleRawDamageRange(t)
            local tSpa = (t.GetSecondsPerAttack and t:GetSecondsPerAttack()) or 0.818
            if tSpa <= 0.1 then tSpa = 0.818 end
            local okTT, tCurTarget = false, nil
            if t.GetAttackTarget then okTT, tCurTarget = pcall(t.GetAttackTarget, t) end
            if not okTT then tCurTarget = nil end
            if not tCurTarget then
                local curTickPrep = math.floor(GameTime() * 30.0 + 0.5)
                local tRec = U._unitTrack and U._unitTrack[t]
                if tRec and tRec.inferredTowerTarget and U.CanQuery(tRec.inferredTowerTarget)
                    and tRec.inferredTowerTarget:IsAlive() and curTickPrep <= (tRec.inferredTowerTargetUntil or -1) then
                    tCurTarget = tRec.inferredTowerTarget
                end
            end
            local towerActivelyFiring = (tCurTarget ~= nil)
            if not towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        for _, p in pairs(U.SafeGetIncomingProjectiles(c)) do
                            if p.is_attack and p.caster == t then towerActivelyFiring = true; break end
                        end
                    end
                    if towerActivelyFiring then break end
                end
            end

            -- CRITICAL (`9056469656.dem` `01:20` Fix!): NEVER prep unless `t` is ACTUALLY firing at creeps,
            -- and sort strictly by C++ `CDOTA_BaseNPC_Tower` kill order (`tCurTarget` first, then closest to `t`)!
            local orderedUnderT1 = {}
            if towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        local dT = GetUnitToLocationDistance(t, c:GetLocation())
                        if dT <= 730 then
                            orderedUnderT1[#orderedUnderT1 + 1] = { c = c, d = dT, active = (c == tCurTarget) }
                        end
                    end
                end
            end
            table.sort(orderedUnderT1, function(a, b)
                if a.active ~= b.active then return a.active end
                return a.d < b.d
            end)

            for idx, entry in ipairs(orderedUnderT1) do
                local c = entry.c
                local isImmediateTarget = entry.active or (idx == 1)
                -- `auto-20261023-1329-start-ShaNachnetsya.dem` `tk=6182..6240` Fix:
                -- NEVER ignore an enemy hero right-clicking us inside `<= 640u` while our T1 is busy shooting creeps
                -- (`tCurTarget ~= enemyHero`)! Yield immediately so `HandleAntiFreeHarassRetaliation` punishes him!
                local enemyFreeHittingUs = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
                    and tCurTarget ~= enemyHero
                    and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 640
                    and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
                        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.35)))
                local safePrepPos = L.EnemyCannotPunishLane(bot, enemyHero, bot:GetHealth())
                    or not IsPositionLethalFromEnemy(bot, bot:GetLocation(), enemyHero, race)
                if not enemyFreeHittingUs and safePrepPos then
                    local tDmg = U.CalcExactIntDamage(t, c, towerRawAvg)
                    local sfRange = U.SFDamageRange(bot, c)
                    local myMin, myAvg = sfRange.min, sfRange.avg
                    local cLocPrep = c:GetLocation()
                    local allyHitCount = 0
                    for _, ac in pairs(allyCreeps or {}) do
                        if U.CanQuery(ac) and ac:IsAlive() then
                            if (ac.GetAttackTarget and ac:GetAttackTarget() == c)
                                or (U.DistanceBetweenLocations(ac:GetLocation(), cLocPrep) <= 165) then
                                allyHitCount = allyHitCount + 1
                            end
                        end
                    end
                    -- Account for ALL projectiles ALREADY in flight (`tower` AND `bot` prep bolt!)
                    local hpEff = c:GetHealth()
                    local hasTowerBoltInAir = false
                    for _, p in pairs(U.SafeGetIncomingProjectiles(c)) do
                        if p.is_attack then
                            if p.caster == t then
                                hpEff = hpEff - tDmg
                                hasTowerBoltInAir = true
                            elseif p.caster == bot then
                                hpEff = hpEff - myAvg
                            end
                        end
                    end
                    local skipMultiAllyChip = (allyHitCount >= 2 and hpEff <= 2 * tDmg + 55)
                    if tDmg > 0 and hpEff > myMin + 6 and not skipMultiAllyChip then
                        local kShotsRaw = math.max(1, math.floor(hpEff / tDmg))
                        -- Exact Stochastic Drift + Creep Regen Margin (`+0.5 HP/s` regen + T1 min-roll spread over `kShots`!):
                        -- Without this margin, `550 - 5*96 = 70 <= 71` and `300 - 2*108 = 84 <= 84` looked "safe",
                        -- then `+2 HP` creep regen + T1 low rolls pushed actual post-T1 HP to `74..76` & `87 HP`,
                        -- leaving `1–5 HP` slivers on EVERY creep under T1 (`s30_probe`: `c4: 87 -> 1 HP` at `tk=5768`!)!
                        -- Also guard against the opposite edge (`remNow <= 8`, where a high T1 roll `98` kills `98 -> 0` directly!).
                        local driftMargin = math.min(18, kShotsRaw * 2 + 4)
                        local safeNoPrepCeil = math.max(8, myMin - driftMargin)
                        local remNow = hpEff % tDmg
                        if remNow == 0 then remNow = tDmg end
                        if remNow > safeNoPrepCeil then
                            local totalTicksNow = U.GetExactBallisticTicks(bot, c)
                            local upperClean = math.max(8, myMin - math.min(12, kShotsRaw * 2 + 2))
                            local bestPrep = false
                            for nPreps = 1, 2 do
                                local hpAfterN = hpEff - nPreps * myAvg
                                if hpAfterN >= tDmg + 2 then
                                    local remN = hpAfterN % tDmg
                                    if remN == 0 then remN = tDmg end
                                    local towerShotsToOpen = math.max(1, math.floor((hpAfterN - remN) / tDmg + 0.5))
                                    local minRemFloor = (towerShotsToOpen <= 1)
                                        and ((allyHitCount > 0) and 24 or 10)
                                        or ((allyHitCount > 0) and 14 or 2)
                                    if remN >= minRemFloor and remN <= upperClean then
                                        local timeUntilSteal = isImmediateTarget
                                            and ((towerShotsToOpen + 0.45) * tSpa)
                                            or ((towerShotsToOpen + 1.55) * tSpa)
                                        local reloadNeed = nPreps * mySpa + (totalTicksNow / 30.0) + 0.08
                                        if timeUntilSteal >= reloadNeed then
                                            bestPrep = true
                                            break
                                        end
                                    end
                                end
                            end
                            if bestPrep then
                                L._prepCreep = c
                                L._prepStartLAT = curLAT
                                L._prepExpire = GameTime() + 1.1
                                bot:Action_AttackUnit(c, true)
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Exact 30.000 Hz Zero-Cancel Phase-Locked Ballistic Controller (`0–1` Tick Arrival, `0` Fake Swing Cancels!)
function L.ExecutePhaseLockedCS(bot, plan, s, P)
    local target = plan.creep
    local curTick = math.floor(GameTime() * 30.0 + 0.5)    local rec = U._unitTrack[bot]
    local dmgRange = U.SFDamageRange(bot, target)
    local myMinDmg = dmgRange.min
    local maxHP = math.max(1, target:GetMaxHealth())

    -- 1. If our bot is ALREADY mid-windup on `target`, inspect exact arrival tick of THIS active swing!
    -- CRITICAL SOURCE 2 INTRA-TICK LAW (`9058240714.dem` `2:50`, `2:59` & `val = 1..18 HP` slivers fix!):
    -- `CProjectileManager` delivers SF's bolt AT THE START of tick `predImpact` BEFORE same-tick creep melee hits,
    -- so true HP upon bolt impact is the HP at the end of tick `(predImpact - 1)` (`hpBeforeSameTickHits`)!
    if rec and rec.wasAnim and rec.launchTick and rec.launchTick >= curTick and bot:GetAttackTarget() == target then
        local predImpact = (rec.launchTick - curTick) + plan.fT
        local hpAtPred = (predImpact <= 0)
            and target:GetHealth()
            or U.PredictHPWithContext(plan.ctx, target, (predImpact - 1) / 30.0, "max")
        local hpAtPredMin = U.PredictHPWithContext(plan.ctx, target, predImpact / 30.0, "min")
        local legalDeny = (not plan.isDeny) or (hpAtPred * 2 < maxHP)

        -- If target is ALREADY provably dead BEFORE our projectile arrives (`hpAtPred == 0`), S-cancel on tick 0 (`S11`)!
        if hpAtPred <= 0 and hpAtPredMin <= 0 then
            bot:Action_ClearActions(true)
            return true
        end

        -- THIS SWING IS LOCKED ON TARGET TO HIT IN [0, 1] TICKS OF KILLABLE (`A07`: AND alive before `effClose + 1`) -> DO NOT TOUCH IT!
        -- `auto-20261102-0007` (`2:31.5`, `5:51.7`, `7:00.8` `128->7 HP` Sliver Fix):
        -- On the final tick before projectile launch (`rec.launchTick - curTick <= 1`), any creep/tower swing that could
        -- land before our bolt (`fT = 6..10` ticks < `14`-tick melee windup!) is ALREADY animating (`certain == true`) or in air!
        -- Therefore, if `hpAtPred > myMinDmg` AND `hpAfterRestart > 0` (the creep is guaranteed to survive in `"max"` mode for a
        -- clean restarted swing!), do NOT blindly pass via `predImpact >= plan.kTargetImpact` (`avg` no-slack estimate) —
        -- S-cancel 1 tick before launch and cleanly secure the post-hit killable window with zero 1..7 HP slivers!
        local onFinalLaunchTick = (rec.launchTick - curTick) <= 1
        local hpAfterRestartNow = onFinalLaunchTick
            and U.PredictHPWithContext(plan.ctx, target, ((plan.totalT or 20) + 1) / 30.0, "max")
            or 0
        -- `9074178342.dem` `02:14.4..02:14.8` (`tk=7116, 7128` `R#1537` `62..64 HP` Zero-Attacker S-Cancel Loop Fix!):
        -- `earlySliverGuaranteed` exists ONLY to wait `0.2..0.6s` for an active allied creep/tower hit (`#hits > 0` or
        -- `#projectileHits > 0`) to drop the creep below `myMinDmg`. When ZERO units/projectiles are attacking `target`,
        -- S-cancelling 1 tick before launch NEVER lowers `target`'s HP — it just spins in an infinite `Attack -> S-cancel` loop!
        local hasIncomingDmgSource = plan.ctx
            and ((plan.ctx.hits and #plan.ctx.hits > 0) or (plan.ctx.projectileHits and #plan.ctx.projectileHits > 0))
            or false
        local earlySliverGuaranteed = onFinalLaunchTick
            and (not plan.isDeny)
            and hasIncomingDmgSource
            and (hpAtPred > myMinDmg)
            and (hpAfterRestartNow > 0)
        if ((predImpact >= plan.kTargetImpact and predImpact <= (plan.effClose or 999) + 1) and not earlySliverGuaranteed)
            or (hpAtPred > 0 and hpAtPred <= myMinDmg and legalDeny) then
            return true
        end

        -- ONLY abort an already-started swing if the creep unexpectedly stopped taking damage and our bolt
        -- would genuinely arrive BEFORE killable threshold (`hpAtPred > myMinDmg`)!
        -- `auto-20261101-2135` `1:48.00` (`tk=6258` `R1491` `60 HP` vs `58..64` SF dmg under T1 + 3 melee creeps) Fix:
        -- NEVER S-cancel 1 tick before projectile launch when a fresh restart (`plan.totalT` ticks) will arrive AFTER
        -- the creep is already dead (`hpAfterRestart <= 0`) and `hpAtPred <= dmgRange.max + 1` (real kill roll vs 0% if cancelled)!
        if onFinalLaunchTick then
            local uncontestedFinishRoll = (not plan.isDeny)
                and (not hasIncomingDmgSource)
                and hpAtPred > 0
                and hpAtPred <= ((dmgRange.max or myMinDmg) + 6)
            local doNotAbortLastChance = uncontestedFinishRoll or ((not plan.isDeny)
                and hpAfterRestartNow <= 0
                and hpAtPred > 0
                and hpAtPred <= ((dmgRange.max or myMinDmg) + 1))
            if not doNotAbortLastChance then
                bot:Action_ClearActions(true)
            end
            return true
        end
        return true
    end

    -- 2. Not mid-windup on `target` right now: compute exact integer slack `freshDelta`
    local freshDelta = plan.kTargetImpact - plan.totalT
    local nowG = GameTime()
    local liveEnemy = s and s.enemy
    local hasLiveEnemy = liveEnemy and U.CanQuery(liveEnemy) and liveEnemy:IsAlive()
    local dLiveEnemy = hasLiveEnemy and GetUnitToLocationDistance(bot, liveEnemy:GetLocation()) or 9999

    -- Two-Phase CS Slack Weaving (`v5.0.0` Pro Mid Upgrade — fixes `1000+` right-click deficit & silent `E` coils):
    --   * COMMIT PHASE (`freshDelta <= 18` for enemy CS, `<= 10` for ally deny): 100% sacred phase-lock (`0` missed CS!).
    --   * SLACK PHASE (`freshDelta >= 19` for enemy CS, `>= 11` for ally deny): compute `freeSlackSec = (freshDelta - 4) / 30`
    --     and yield (`return false` with `L._imminentCS == false`) whenever ANY safe combat/punish action fits inside the
    --     slack window BEFORE we must pre-align & start our CS swing!
    local enemyPokingDuringWait = hasLiveEnemy and dLiveEnemy <= 965
        and ((liveEnemy.GetAttackTarget and liveEnemy:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(liveEnemy, 1.45)))
    local alreadySwingingAtHero = hasLiveEnemy and U.IsAttackingAction(bot) and bot:GetAttackTarget() == liveEnemy
    local commitCutoff = plan.isDeny and 10 or 18
    local mySpaNow = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
    if freshDelta > commitCutoff and hasLiveEnemy then
        local freeSlackSec = (freshDelta - 4) / 30.0
        local enemySalving = U.IsEnemyHighValueRegen and U.IsEnemyHighValueRegen(liveEnemy) and dLiveEnemy <= 965
        -- Shadowraze weave does NOT put basic attack on cooldown (`0.55s` cast point), so `freeSlackSec >= 0.72` suffices!
        local enemyRootedCS = U.IsAttackingAction(liveEnemy)
            and (not liveEnemy.GetAttackTarget or liveEnemy:GetAttackTarget() ~= bot)
            and dLiveEnemy <= 740 and freeSlackSec >= 0.72 and (bot:GetMana() or 0) >= 130
        local myAtkReady = (nowG - (bot:GetLastAttackTime() or -100)) >= (mySpaNow * 0.90)
        local aggroCdActive = nowG < (((U._State and U._State.myCreepAggroCdUntil) or 0) - 0.25)
        local nearestEnemyCreepSq = 9999 * 9999
        local enemyCreepsWithin500 = 0
        local bLocSlack = bot:GetLocation()
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if ec then
                local ecLoc = ec:GetLocation()
                local dxC = ecLoc.x - bLocSlack.x
                local dyC = ecLoc.y - bLocSlack.y
                local dSqC = dxC * dxC + dyC * dyC
                if dSqC < nearestEnemyCreepSq then nearestEnemyCreepSq = dSqC end
                if dSqC <= (502 * 502) then enemyCreepsWithin500 = enemyCreepsWithin500 + 1 end
            end
        end
        local nearestEnemyCreepD = (nearestEnemyCreepSq < 9999 * 9999) and math.sqrt(nearestEnemyCreepSq) or 9999
        -- `v7.0.0` + `v7.9.17-pro` (`1507 @ 02:18–03:08 & 04:00–05:00` Exact CS-Slack Attack Physics Fix!):
        -- `freshDelta = kTargetImpact - totalT` ALREADY subtracts `totalT` (`attackPoint + boltFlight ~ 0.67s`), so SF
        -- only needs `mySpaNow` (`+ 0.12s` turn/margin when in range, `+ 0.22s` when stepping) before `freshDelta == 0`!
        -- Also scope uphill creep-pack caution strictly to `enemyCreepsWithin500 >= 3 and not aggroCdActive` vs armed enemies!
        local dryPokeBlock = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, liveEnemy, s) or false
        local enemyMovingAwayPoke = U._K and U._K.IsEnemyMovingAway and U._K.IsEnemyMovingAway(bot, liveEnemy) or false
        local myAtkRangeSlack = (bot:GetAttackRange() or 525)
        local enPotManaSlack = (U.GetPotentialManaForRaze and U.GetPotentialManaForRaze(liveEnemy)) or (liveEnemy:GetMana() or 0)
        local allyWaveCntSlack = #((s and s.allyCreeps) or {})
        local outnumberedByEnemyWave = (enemyCreepsWithin500 >= allyWaveCntSlack + 2)
        local realUphillCreepPack = (((liveEnemy:GetLocation().z or 0) - (bot:GetLocation().z or 0)) >= 85)
            and (not aggroCdActive)
            and (enemyCreepsWithin500 >= 3)
            and (enPotManaSlack >= 75 or outnumberedByEnemyWave or (bot:GetHealth() or 0) < 380)
        local reqPokeSlack = (dLiveEnemy <= myAtkRangeSlack + 25) and (mySpaNow + 0.12) or (mySpaNow + 0.22)
        local zeroAggroPokeReady = (not dryPokeBlock) and myAtkReady and freeSlackSec >= reqPokeSlack
            and dLiveEnemy <= myAtkRangeSlack + (enemyMovingAwayPoke and 35 or 75)
            and (aggroCdActive or nearestEnemyCreepD > 502
                or (enemyCreepsWithin500 <= 2 and (bot:GetHealth() or 0) >= 340)
                or (enPotManaSlack < 75 and not outnumberedByEnemyWave and (bot:GetHealth() or 0) >= math.max(380, (liveEnemy:GetHealth() or 500) + 80)))
            and not realUphillCreepPack
            and not (U.IsOutRazedTier and U.IsOutRazedTier(bot, liveEnemy) and enPotManaSlack >= 75)
            and (bot:GetHealth() or 0) >= 280
        local dominantZonePunish = false
        if not dryPokeBlock and freeSlackSec >= 0.80 and dLiveEnemy <= 835
            and U.IsLaneDominant and U.IsLaneDominant(bot, s, nil) then
            local eLocSlack = liveEnemy:GetLocation()
            local dWaveSlack = 9999
            for _, ac in pairs((s and s.allyCreeps) or {}) do
                if U.CanQuery(ac) and ac:IsAlive() then
                    local dw = U.DistanceBetweenLocations(ac:GetLocation(), eLocSlack)
                    if dw < dWaveSlack then dWaveSlack = dw end
                end
            end
            if dWaveSlack <= 790 then
                local manaSlack = bot:GetMana() or 0
                local razeInBand = false
                if manaSlack >= 135 or (manaSlack >= 75 and (liveEnemy:GetHealth() or 999) <= 360) then
                    for _, spec in ipairs({
                        { "nevermore_shadowraze1", 200 },
                        { "nevermore_shadowraze2", 450 },
                        { "nevermore_shadowraze3", 700 },
                    }) do
                        local abS = U.GetAbility(bot, spec[1])
                        if abS and abS:GetLevel() > 0 and abS:IsCooldownReady() and math.abs(dLiveEnemy - spec[2]) <= 195 then
                            razeInBand = true
                            break
                        end
                    end
                end
                local lightWavePoke = myAtkReady and freeSlackSec >= (mySpaNow + 0.16)
                    and dLiveEnemy <= (bot:GetAttackRange() or 525) + (enemyMovingAwayPoke and 20 or 38)
                    and enemyCreepsWithin500 <= 2
                if razeInBand or lightWavePoke then
                    dominantZonePunish = true
                end
            end
        end
        local hasReadyCenteredPokeRaze = false
        if (not dryPokeBlock) and enemyPokingDuringWait and freeSlackSec >= 0.72 and (bot:GetMana() or 0) >= 150 and dLiveEnemy <= 835 then
            for _, specR in ipairs({
                { "nevermore_shadowraze1", 200 },
                { "nevermore_shadowraze2", 450 },
                { "nevermore_shadowraze3", 700 },
            }) do
                local abR = U.GetAbility(bot, specR[1])
                if abR and abR:GetLevel() > 0 and abR:IsCooldownReady() and math.abs(dLiveEnemy - specR[2]) <= 125 then
                    hasReadyCenteredPokeRaze = true
                    break
                end
            end
        end
        local razePokeAnswer = hasReadyCenteredPokeRaze
            and not realUphillCreepPack
            and not (U.IsOutRazedTier and U.IsOutRazedTier(bot, liveEnemy))
        local safePokeAnswer = (not dryPokeBlock) and enemyPokingDuringWait
            and ((myAtkReady and freeSlackSec >= (mySpaNow + 0.12) and not realUphillCreepPack)
                or razePokeAnswer
                or (bot:GetHealth() or 999) <= 245)
        if safePokeAnswer or enemySalving or enemyRootedCS or zeroAggroPokeReady or dominantZonePunish then
            return false
        end
    end
    local heroSwingCommitted = hasLiveEnemy and U._State
        and nowG < (U._State.heroAttackCommitUntil or 0)
        and U._State.heroAttackTarget == liveEnemy
        and U.IsAttackingAction(bot)
        and dLiveEnemy <= 655
    if (enemyPokingDuringWait and (bot:GetHealth() or 999) <= 245)
        or ((alreadySwingingAtHero or heroSwingCommitted) and freshDelta >= 8) then
        return false
    end

    -- Source 2 Lane Creep Aggro & Ranged-Creep Reset Physics (`v5.0.0`):
    --   1. During the `2.30s` forced protective chase (`nowG < myCreepChaseUntil`), A-clicking an allied creep CANNOT drop
    --      aggro in Source 2 — kite back `435u` instead of wasting a tick attacking our own creep!
    --   2. An enemy ranged creep (`500u` range) NEVER re-evaluates `Condition 1/3` unless forced to move (`dc > 505u`)!
    local creepsAggroOnMeDuringWait = false
    local rangedAggroCreep = nil
    local recentCreepHitWait = (bot.WasRecentlyDamagedByCreep and bot:WasRecentlyDamagedByCreep(0.85)) or false
    if s and s.enemyCreeps then
        for _, ec in pairs(s.enemyCreeps) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (recentCreepHitWait and dc <= 215) then
                    creepsAggroOnMeDuringWait = true
                    local ecRange = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                    if ecRange > 300 and dc <= 505 then
                        rangedAggroCreep = ec
                    end
                end
            end
        end
    end
    local chaseLockedNow = nowG < (((U._State and U._State.myCreepChaseUntil) or 0) - 0.08)
    if creepsAggroOnMeDuringWait and not chaseLockedNow and freshDelta >= 8 and s and s.allyCreeps then
        if rangedAggroCreep and freshDelta >= 18 then
            local rcLoc = rangedAggroCreep:GetLocation()
            local fnt = P.GetFountain(bot)
            local stepOut = rcLoc + (fnt - rcLoc):Normalized() * 520
            if U.DistanceBetweenLocations(stepOut, target:GetLocation()) <= (bot:GetAttackRange() or 525) + 45 then
                bot:Action_MoveToLocation(stepOut)
                return true
            end
        end
        if L._lastDeaggroAt and nowG < L._lastDeaggroAt then
            L._lastDeaggroAt = -100
        end
        if nowG >= (L._lastDeaggroAt or -100) + 1.30 then
            local maxDeaggroReach = (bot:GetAttackRange() or 525) + 35
            local bestAlly, bestAllyDist = nil, math.huge
            local fallbackAlly, fallbackDist = nil, math.huge
            -- Prefer `hp * 2 > maxHp + 20` (`> 50% HP`) allied creeps so `Action_AttackUnit` resets creep aggro
            -- in `0.00s` WITHOUT starting a legal `< 50% HP` deny swing (`1.14s` attack cooldown)!
            for _, ac in pairs(s.allyCreeps) do
                if U.CanQuery(ac) and ac:IsAlive() and ac ~= target then
                    local aHp = ac:GetHealth() or 0
                    local aMax = ac:GetMaxHealth() or 550
                    local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                    if da <= maxDeaggroReach then
                        if aHp * 2 > aMax + 20 and da < bestAllyDist then
                            bestAllyDist, bestAlly = da, ac
                        elseif aHp > 95 and freshDelta >= 22 and da < fallbackDist then
                            fallbackDist, fallbackAlly = da, ac
                        end
                    end
                end
            end
            local chosenAlly = bestAlly or fallbackAlly
            if chosenAlly then
                L._lastDeaggroAt = nowG
                bot:Action_AttackUnit(chosenAlly, true)
                return true
            end
        end
    end

    -- Helper: ensure slack positioning (`optPos`) NEVER pulls SF forward into lethal enemy range or onto enemy ramp
    -- (`auto-20261031-0230` `01:00.3`, `01:51.7`, `02:01.4`, `02:08.3` Root-Cause Fix!)
    local function sanitizeSlackOptPos(optPos)
        if not optPos then return nil end
        local bCur = bot:GetLocation()
        local cCur = target:GetLocation()
        local fnt = P.GetFountain(bot)
        if (enemyPokingDuringWait or creepsAggroOnMeDuringWait) then
            -- `9074178342.dem` `04:20.47..04:25.57` (`tk=10860..11004` `814 -> 519 HP` 5 Free Uphill Hits Fix!):
            -- Previously `math.min(460, atkRange - 40)` froze SF at `460u` from `M#1637` (`555u` from HG enemy) for `3.1s`
            -- (`93` ticks of slack!). Use exact **Ballistic CS-Slack Tether**: stand outside enemy uphill poke reach while
            -- `freshDelta > 11` (`safeTetherR` up to `atkRange + 245u`), and contract smoothly (`0.42 * (freshDelta - 11)`
            -- walk-back budget) to `atkRange + 8u` (`<= 540u` hull-to-hull reach!) as `freshDelta -> 0` (`0` missed CS!).
            local myAtkR = bot:GetAttackRange() or 500
            local myMsT = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 305)
            local extraTether = enemyPokingDuringWait
                and math.min(240, math.max(0, freshDelta - 11) * 0.42 * (myMsT / 30.0))
                or 0
            local baseBackR = enemyPokingDuringWait and (myAtkR + 8 + extraTether) or math.min(475, myAtkR - 25)
            optPos = cCur + (fnt - cCur):Normalized() * baseBackR
        end
        if s and s.enemyT1Alive ~= false and s.enemyT1Loc then
            local shieldCnt = 0
            for _, ac in pairs(s.allyCreeps or {}) do
                if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 135
                    and U.DistanceBetweenLocations(ac:GetLocation(), s.enemyT1Loc) <= 755 then
                    shieldCnt = shieldCnt + 1
                end
            end
            if shieldCnt < 1 and U.DistanceBetweenLocations(optPos, s.enemyT1Loc) < 905 then
                local safeOut = s.enemyT1Loc + (fnt - s.enemyT1Loc):Normalized() * 905
                if U.DistanceBetweenLocations(safeOut, cCur) <= (bot:GetAttackRange() or 525) - 5 then
                    optPos = safeOut
                end
            elseif #(s.enemyCreeps or {}) == 0 and U.DistanceBetweenLocations(optPos, s.enemyT1Loc) < 610 then
                optPos = s.enemyT1Loc + (fnt - s.enemyT1Loc):Normalized() * 610
            end
        end
        if hasLiveEnemy then
            local eCur = liveEnemy:GetLocation()
            local dNowE = U.DistanceBetweenLocations(bCur, eCur)
            local dOptE = U.DistanceBetweenLocations(optPos, eCur)
            local inReachAlready = U.DistanceBetweenLocations(bCur, cCur) <= (bot:GetAttackRange() or 525) - 18
            local enHasCoilMana = ((liveEnemy:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(liveEnemy) or 0)) >= 75
            local dryVsEnemy = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, liveEnemy, s) or false
            local cautiousState = dryVsEnemy
                or ((bot:GetHealth() or 999) <= 390)
                or ((liveEnemy:GetLevel() or 1) > (bot:GetLevel() or 1))
                or (U.IsOutRazedTier and U.IsOutRazedTier(bot, liveEnemy))
                or (((U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0) >= 1)
                or (enHasCoilMana and (bot:GetMana() or 0) < 135)
            if inReachAlready and cautiousState and dOptE < dNowE - 14 then
                return nil
            end
            if dryVsEnemy then
                local dryStand = U.GetDrySafeStandoffDist(bot, liveEnemy)
                if dOptE < dryStand then
                    local maxBackDry = cCur + (fnt - cCur):Normalized() * math.max(430, (bot:GetAttackRange() or 525) - 16)
                    local dBackE = U.DistanceBetweenLocations(maxBackDry, eCur)
                    local curRaceRef = (U._K and (U._K._race or U._K._lastRace)) or nil
                    if dBackE >= math.min(dryStand, 695) and not IsPositionLethalFromEnemy(bot, maxBackDry, liveEnemy, curRaceRef, plan.isDeny) then
                        optPos = maxBackDry
                        dOptE = dBackE
                    else
                        return nil
                    end
                end
            end
            -- `9070869385.dem` `03:13.2–03:14.5` + `9070886384.dem` `03:54.40` (`474u` `R1` hull edge!) Fix:
            -- NEVER let CS slack positioning walk SF inside an enemy SF's `Shadowraze1 (200+250+24 = 474u)` while waiting
            -- for a creep when the enemy has coil mana and `Raze1` off cooldown!
            if enHasCoilMana and dOptE < 495 and dOptE < dNowE - 10
                and not (U._K and U._K.EnemyRazeReadyIn and U._K.EnemyRazeReadyIn("near") > 2.0) then
                return nil
            end
            local raceRef = (U._K and (U._K._race or U._K._lastRace)) or nil
            if IsPositionLethalFromEnemy(bot, optPos, liveEnemy, raceRef, plan.isDeny) then
                local maxBack = cCur + (fnt - cCur):Normalized() * math.max(415, (bot:GetAttackRange() or 525) - 20)
                if not IsPositionLethalFromEnemy(bot, maxBack, liveEnemy, raceRef, plan.isDeny) then
                    optPos = maxBack
                else
                    return nil
                end
            end
        end
        return optPos
    end

    -- Move off river lowground (`25%` uphill miss!) or to contested safe stance (`415–480u` behind allied wave) while we have slack —
    -- UNLESS low-HP (`<= 42%` & `< 410 HP`) vs a spell-ready enemy during early slack (`freshDelta >= 14`), where holding safe spacing avoids edge-dance oscillation!
    local lowHpHoldBack = hasLiveEnemy
        and ((bot:GetHealth() or 999) <= math.min(410, (bot:GetMaxHealth() or 600) * 0.42))
        and ((liveEnemy:GetMana() or 0) >= 75)
        and (freshDelta >= 14)
    -- Only use `"AGGRESSIVE"` forward CS stance (`250u` past wave) when enemy is dry (`< 75 MP`) OR we hold both high HP (`>= 620`) & `2+` coils (`>= 150 MP`)!
    local enPoolForStance = hasLiveEnemy and ((liveEnemy:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(liveEnemy) or 0)) or 0
    local allowAggroSlackStance = (U.IsLaneDominant and U.IsLaneDominant(bot, s, nil))
        and (not hasLiveEnemy or enPoolForStance < 75 or ((bot:GetHealth() or 0) >= 620 and (bot:GetMana() or 0) >= 150))
    local slackPosMode = allowAggroSlackStance and "AGGRESSIVE" or "NEUTRAL"
    -- `9070869385.dem` `03:13.87` + `v7.9.8-pro` (`1630` `2 vs 23` & `1638` `6 vs 13` Right-Clicks + `00:28.6` Mirror `E` Fix!):
    -- Yield CS slack (`return false` so `Stage B0/B` combat, mirror counter-raze, & zero-aggro right-click harass can fire
    -- WITHOUT ever missing the creep!) in three strictly CS-safe windows:
    --   (a) Close-duel or recent enemy raze/hit (`freshDelta >= 19` ticks = `>= 0.63s` > `0.55s` raze cast): allows instant
    --       `E(700)` mirror counter-raze (`00:28.60`) and close `Q`/`W` counter-coils (`d <= 475u`).
    --   (b) Full hero right-click weave (`freshDelta >= spaTicks + 7` & attack off CD & `d <= atkRange + 75`): SF completes a
    --       full hero right-click AND recovers 100% of attack cooldown BEFORE `freshDelta == 0` on the creep!
    --   (c) Waiting on an allied deny (`plan.isDeny` & `freshDelta >= 14`) while enemy swings at a creep or hits us within `565u`.
    if hasLiveEnemy then
        local bLocYield = bot:GetLocation()
        local dLiveE = U.DistanceBetweenLocations(bLocYield, liveEnemy:GetLocation())
        local spaTicksYield = math.ceil((bot:GetSecondsPerAttack() or 1.45) * 30.0)
        local atkReadyYield = ((GameTime() - (bot:GetLastAttackTime() or -100)) >= ((bot:GetSecondsPerAttack() or 1.45) * 0.90))
        local recentHitByEnemy = (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(liveEnemy, 1.35))
            or (((U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0) >= 1)
        local enemySwinging = (U.IsAttackingAction and U.IsAttackingAction(liveEnemy)) or false
        local hasCenteredCounterRaze = false
        if freshDelta >= 19 and dLiveE <= 865 and recentHitByEnemy and (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
            for _, spec in ipairs({
                { "nevermore_shadowraze1", 200 },
                { "nevermore_shadowraze2", 450 },
                { "nevermore_shadowraze3", 700 },
            }) do
                local abC = U.GetAbility(bot, spec[1])
                if abC and abC:GetLevel() > 0 and abC:IsCooldownReady() and math.abs(dLiveE - spec[2]) <= 225 then
                    hasCenteredCounterRaze = true
                    break
                end
            end
        end
        local aggroCdYield = nowG < (((U._State and U._State.myCreepAggroCdUntil) or 0) - 0.25)
        local nearEC500Yield = 0
        if freshDelta >= 14 and not aggroCdYield then
            for _, ecY in pairs((s and s.enemyCreeps) or {}) do
                if ecY then
                    local ecLocY = ecY:GetLocation()
                    local dxY = ecLocY.x - bLocYield.x
                    local dyY = ecLocY.y - bLocYield.y
                    if (dxY * dxY + dyY * dyY) <= (502 * 502) then
                        nearEC500Yield = nearEC500Yield + 1
                    end
                end
            end
        end
        local enPotYield = (U.GetPotentialManaForRaze and U.GetPotentialManaForRaze(liveEnemy)) or (liveEnemy:GetMana() or 0)
        local outnumberedYield = (nearEC500Yield >= #((s and s.allyCreeps) or {}) + 2)
        local uphillCreepTrapNow = (((liveEnemy:GetLocation().z or 0) - (bot:GetLocation().z or 0)) >= 85)
            and (not aggroCdYield)
            and (nearEC500Yield >= 3)
            and (enPotYield >= 75 or outnumberedYield or (bot:GetHealth() or 0) < 380)
        if freshDelta >= 18 and (bot:GetMana() or 0) >= 75
            and (dLiveE <= 475 or (freshDelta >= 19 and dLiveE <= 865 and recentHitByEnemy
                and (hasCenteredCounterRaze or (bot:GetHealth() or 999) <= 340))) then
            return false
        end
        if freshDelta >= (spaTicksYield + 4) and atkReadyYield and dLiveE <= ((bot:GetAttackRange() or 525) + 75)
            and not uphillCreepTrapNow then
            return false
        end
        if plan.isDeny and freshDelta >= 14 and atkReadyYield and dLiveE <= ((bot:GetAttackRange() or 525) + 55)
            and (enemySwinging or recentHitByEnemy) then
            return false
        end
    end
    if freshDelta >= 12 and U._State and U._State.trySafeTreadsCb then
        if U._State.trySafeTreadsCb(bot, "FIGHT") then
            return true
        end
    end
    -- `9071946472.dem` `03:09.33–03:12.43` Post-Kill Slack Whiplash Fix:
    -- When the enemy hero is DEAD (`s.enemyAlive == false`) and SF is already comfortably in attack range (`<= atkRange - 28`)
    -- and safely outside Enemy T1 (`>= 905u`), hold clean firing stance instead of walking `400u` backward & forward on creep deaths!
    local deadEnemyAlreadyInRange = (not hasLiveEnemy) and (s and s.enemyAlive == false)
        and U.DistanceBetweenLocations(bot:GetLocation(), target:GetLocation()) <= ((bot:GetAttackRange() or 525) - 28)
        and not (s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(bot:GetLocation(), s.enemyT1Loc) < 905)
    if freshDelta >= 7 and (enemyPokingDuringWait or not lowHpHoldBack) and not deadEnemyAlreadyInRange and P and P.GetLasthitPosition then
        local optPos = sanitizeSlackOptPos(P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, slackPosMode))
        if optPos and U.DistanceBetweenLocations(bot:GetLocation(), optPos) > 32 then
            bot:Action_MoveToLocation(optPos)
            return true
        end
    end

    -- Exact firing tick (`freshDelta <= 0` AND `A04` `< 50% HP` legal deny check): ONE clean swing -> ZERO self-cancels!
    local denyLegalRightNow = (not plan.isDeny) or ((target:GetHealth() or maxHP) * 2 < maxHP)
    if freshDelta <= 0 and denyLegalRightNow then
        bot:Action_AttackUnit(target, true)
        return true
    end

    -- Pre-align hero yaw to `0.00 deg` toward `target` smoothly WITHOUT fake attack-swing spam (`0` `SCancel`!):
    -- Align strictly at `freshDelta >= 3` down to `<= 2.5 deg` so on ticks `freshDelta == 2, 1, 0` hero stands dead-still at `0.0 deg`!
    local bLoc = bot:GetLocation()
    local cLoc = target:GetLocation()
    local wantYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
    local curYaw = (bot.GetFacing and bot:GetFacing()) or wantYaw
    local angErr = math.abs(((wantYaw - curYaw + 180) % 360) - 180)

    if freshDelta >= 3 and angErr > 5.5 and U.DistanceBetweenLocations(bLoc, cLoc) > 125 then
        bot:Action_MoveToLocation(bLoc + (cLoc - bLoc):Normalized() * 15)
        return true
    end

    if freshDelta >= 4 and not deadEnemyAlreadyInRange and P and P.GetLasthitPosition then
        local stRef = U._State
        local nowSlk = GameTime()
        local retreatLockSlk = stRef and (
            (stRef.forcedRetreatLoc ~= nil and nowSlk < (stRef.forcedRetreatUntil or 0))
            or (nowSlk < (stRef.fleeUntil or 0))
            or (nowSlk < (stRef.critDangerHystUntil or 0))
            or (stRef.survivalLoc ~= nil and nowSlk < (stRef.survivalUntil or 0))
            or (nowSlk < (stRef.noHarassTurnbackUntil or 0))
        )
        if not retreatLockSlk then
            local optPos = sanitizeSlackOptPos(P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, slackPosMode))
            if optPos and U.DistanceBetweenLocations(bLoc, optPos) > 28 then
                if stRef then
                    stRef.lastMoveLoc = optPos
                    stRef.lastMoveTime = nowSlk
                end
                bot:Action_MoveToLocation(optPos)
                return true
            end
        end
    end

    if U.IsAttackingAction(bot) then
        bot:Action_ClearActions(true)
    end
    return true
end

-- Shared Enemy-T1 & Post-Kill Ally-Deny Filter (`v7.9.19`):
--   1. `ShaNachnetsya` `00:45–01:01` Fix: When the enemy hero is DEAD (`s.enemyAlive == false`) and our wave CANNOT
--      crash into Enemy T1 before he respawns (`not U.CanCrashWaveBeforeEnemyReturn`), ALWAYS deny allied `< 50% HP`
--      creeps for Necromastery souls + wave equilibrium so he does NOT TP back to a 6-creep double-wave under his T1!
--   2. `9074666246.dem` Every-Wave Block Fix (`Waves 5,7,8,9,10,11,14,15,19`): When `#enemyCreeps == 0` (wave cleared!)
--      and `<= 2` leftover allied creeps are dying inside `<= 825u` of `enemyT1` (`0` denies achieved across Waves 7/9/10/11
--      due to Enemy T1 `110 dmg` boulder + 25% uphill miss!), ONLY allow an immediate in-range 1-hit guaranteed deny
--      (`hp <= myAvg + 8`); drop higher-HP doomed creeps immediately so SF peels back to body-block the next `:00`/`:30` wave!
local function ResolveDenyListAndSiegeFlag(bot, s, allyCreeps)
    local fastPostKillCrash = (s and s.enemyAlive == false)
        and (U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s)) or false
    local nearEnT1 = (s and s.enemyT1Alive and s.enemyT1Loc
        and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1220) and true or false
    local noLocalEnemyCreeps = (#((s and s.enemyCreeps) or {}) == 0)
    if fastPostKillCrash then
        local dT1 = (s and s.enemyT1Alive and s.enemyT1Loc) and GetUnitToLocationDistance(bot, s.enemyT1Loc) or 9999
        return {}, (dT1 <= 885)
    end
    if not nearEnT1 then
        return allyCreeps or {}, false
    end

    local tLoc = s.enemyT1Loc
    local dBotT1 = GetUnitToLocationDistance(bot, tLoc)
    local shieldCreeps = 0
    for _, ac in pairs(allyCreeps or {}) do
        if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 25
            and GetUnitToLocationDistance(ac, tLoc) <= 755 then
            shieldCreeps = shieldCreeps + 1
        end
    end

    local atkR = math.max(525, bot:GetAttackRange() or 525)
    local function isInstantOneHitSafeDeny(ac)
        if not (U.CanQuery(ac) and ac:IsAlive()) then return false end
        local dAcT1 = GetUnitToLocationDistance(ac, tLoc)
        if dAcT1 + atkR < 895 then return false end
        if noLocalEnemyCreeps and dAcT1 <= 825 and (s and s.enemyAlive ~= false) then
            -- Do NOT linger watching high-HP allied creeps die to Enemy T1 when `0` enemy creeps remain!
            if GetUnitToLocationDistance(bot, ac:GetLocation()) > atkR + 25 then
                return false
            end
            local myAvg = U.SFDamageRange(bot, ac).avg
            return (ac:GetHealth() or 9999) <= (myAvg + 8)
        end
        return true
    end

    local activelySieging = (dBotT1 <= 885) and (shieldCreeps >= 1)
    if activelySieging then
        if shieldCreeps >= 2 and (s.enemyAlive == false or not noLocalEnemyCreeps) then
            return allyCreeps or {}, true
        end
        local safeLast = {}
        for _, ac in pairs(allyCreeps or {}) do
            if isInstantOneHitSafeDeny(ac) and (GetUnitToLocationDistance(ac, tLoc) + atkR >= 900) then
                safeLast[#safeLast + 1] = ac
            end
        end
        return safeLast, true
    end

    -- Bot is OUTSIDE Enemy T1 (`dBotT1 > 885`): allow tower-safe denies, excluding futile high-HP under-T1 creeps when wave is clear!
    local outSafe = {}
    for _, ac in pairs(allyCreeps or {}) do
        if isInstantOneHitSafeDeny(ac) then
            outSafe[#outSafe + 1] = ac
        end
    end
    return outSafe, false
end

-- Per-tick CS trajectory & candidate bundle (`v7.9.15-pro` Lossless 1-Scan-Per-Tick Engine):
-- `PeekBestPlan` is queried 4-5x per tick (`HandleCreepTankDrop`, `war_director`, `HandleHarass`, etc.) BEFORE `RunSacredCS`.
-- Sharing the exact trajectory bundle across the same `Think()` tick (`U._inTickScope`) avoids wiping `U._predCache`
-- and recomputing `GetExactKillableInfo` + `GetExactBallisticTicks` 5-6 times per tick with ZERO behavioral drift!
L._frameBundle = {
    scopeId = -1, epoch = -1, bot = nil, s = nil,
    bx = 0, by = 0, bhp = 0, bmp = 0, nEn = 0, nAl = 0, enemy = nil,
    allySideAtk = nil, enemySideAtk = nil,
    denyList = nil, siegingEnemyT1 = false, candidates = nil,
    peekPlan = nil, peekEta = 999,
}

local function GetOrBuildFrameCSBundle(bot, s)
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    if not U._inTickScope then
        U.BeginPredictionFrame()
        local allySideAtk, enemySideAtk = BuildAllAttackers(
            bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, s.enemy
        )
        local denyList, siegingEnemyT1 = ResolveDenyListAndSiegeFlag(bot, s, allyCreeps)
        local candidates = L.ScanCreepCandidates(
            bot, enemyCreeps, denyList, allySideAtk, enemySideAtk, s.enemy, nil
        )
        local plan = L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
        local eta = plan and (math.max(0, (plan.kTargetImpact or 0) - (plan.totalT or 0)) / 30.0) or 999
        return allySideAtk, enemySideAtk, denyList, siegingEnemyT1, candidates, plan, eta
    end

    local b = L._frameBundle
    local bLoc = bot:GetLocation()
    local bhp = bot:GetHealth() or 0
    local bmp = bot:GetMana() or 0
    local nEn = #enemyCreeps
    local nAl = #allyCreeps
    local enemy = s.enemy
    if b.scopeId == U._scopeId and b.epoch == U._invEpoch and b.bot == bot and b.s == s
        and b.bx == bLoc.x and b.by == bLoc.y and b.bhp == bhp and b.bmp == bmp
        and b.nEn == nEn and b.nAl == nAl and b.enemy == enemy and b.candidates ~= nil then
        return b.allySideAtk, b.enemySideAtk, b.denyList, b.siegingEnemyT1, b.candidates, b.peekPlan, b.peekEta
    end

    U.BeginPredictionFrame()
    local allySideAtk, enemySideAtk = BuildAllAttackers(
        bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, enemy
    )
    local denyList, siegingEnemyT1 = ResolveDenyListAndSiegeFlag(bot, s, allyCreeps)
    local candidates = L.ScanCreepCandidates(
        bot, enemyCreeps, denyList, allySideAtk, enemySideAtk, enemy, nil
    )
    local plan = L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    local eta = plan and (math.max(0, (plan.kTargetImpact or 0) - (plan.totalT or 0)) / 30.0) or 999

    b.scopeId, b.epoch, b.bot, b.s = U._scopeId, U._invEpoch, bot, s
    b.bx, b.by, b.bhp, b.bmp = bLoc.x, bLoc.y, bhp, bmp
    b.nEn, b.nAl, b.enemy = nEn, nAl, enemy
    b.allySideAtk, b.enemySideAtk = allySideAtk, enemySideAtk
    b.denyList, b.siegingEnemyT1, b.candidates = denyList, siegingEnemyT1, candidates
    b.peekPlan, b.peekEta = plan, eta
    return allySideAtk, enemySideAtk, denyList, siegingEnemyT1, candidates, plan, eta
end

-- Non-mutating peek at the highest-priority securable CS plan (`v5.2.0` helper for `HandleCreepTankDrop` & `war_director`):
-- Returns `bestPlan, etaSec` when an enemy CS or ally deny opens within the sacred window.
function L.PeekBestPlan(bot, s)
    if not bot or not s then return nil, 999 end
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    if #enemyCreeps == 0 and #allyCreeps == 0 then return nil, 999 end
    local _, _, _, _, _, plan, eta = GetOrBuildFrameCSBundle(bot, s)
    return plan, eta
end

-- Master Top-Priority 30.000 Hz Sacred CS & Spacing Entry Point
function L.RunSacredCS(bot, s, race, P, startRazeCb)
    L._imminentCS = false
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    local enemyHero   = s.enemy
    if #enemyCreeps == 0 and #allyCreeps == 0 then
        return false, false
    end

    local allySideAtk, enemySideAtk, denyCreepsList, siegingEnemyT1, candidates, cachedPeekPlan
    if U._inTickScope then
        allySideAtk, enemySideAtk, denyCreepsList, siegingEnemyT1, candidates, cachedPeekPlan = GetOrBuildFrameCSBundle(bot, s)
        if race and race.valid and enemyHero and U.CanQuery(enemyHero) then
            local sharedLr = U.SolveLethalRace(bot, enemyHero, U._W and U._W.s or nil)
            for i = 1, #candidates do
                local cand = candidates[i]
                cand.lethalRightClick = IsPositionLethalFromEnemy(bot, cand.reqLoc, enemyHero, race, cand.isDeny, sharedLr)
            end
            cachedPeekPlan = nil
        end
    else
        U.BeginPredictionFrame()
        allySideAtk, enemySideAtk = BuildAllAttackers(
            bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, enemyHero
        )
        denyCreepsList, siegingEnemyT1 = ResolveDenyListAndSiegeFlag(bot, s, allyCreeps)
        candidates = L.ScanCreepCandidates(
            bot, enemyCreeps, denyCreepsList, allySideAtk, enemySideAtk, enemyHero, race
        )
    end
    local allowAllyDenies = #denyCreepsList > 0

    -- 1. First execute Dual-Value Hero+Creep Shadowraze (or 2+ simultaneous creep rescue) with S-cancel hook!
    if L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb) then
        return true, true
    end

    L._imminentCS = false
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and cand.kOpen ~= nil and cand.kOpen >= 0 and (cand.kTargetImpact - cand.totalT) <= 18 then
            L._imminentCS = true
            break
        end
    end

    -- 2. Select highest-priority right-click last-hit / deny within the sacred horizon
    local bestPlan = cachedPeekPlan or L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    if bestPlan then
        local planDelta = bestPlan.kTargetImpact - bestPlan.totalT
        local recNow = U._unitTrack and U._unitTrack[bot]
        local midSwingOnPlan = recNow and recNow.wasAnim and bot:GetAttackTarget() == bestPlan.creep
        local planCommitCutoff = bestPlan.isDeny and 10 or 18
        local actedCS = L.ExecutePhaseLockedCS(bot, bestPlan, s, P)
        L._imminentCS = midSwingOnPlan or (actedCS and planDelta <= planCommitCutoff) or false
        if actedCS then
            return true, true
        end
        return false, true
    end

    -- 3. Low-HP Safe Lane Spacing (Strict One-Sided Minimum-Distance Floor -> ZERO Oscillation!):
    --   * FoW Low-HP / Active-Salve Guard (`v5.2.0`): when wounded (`<= 28% HP`) or actively healing with Salve while
    --     the live enemy SF is unseen in highground FoW, anchor behind `allyT1` instead of walking into river coils!
    --   * One-Sided Floor (`targetGap = 810..860 < war_director.RELEASE_DIST = 950`):
    --     - When `d < targetGap`: step back cleanly toward fixed `P.GetBehindT1` anchor!
    --     - When `d >= targetGap`: NEVER pull inward to `eLoc + dir * 900` (eliminates the `29.5 rev/min` oscillator!).
    local hp = bot:GetHealth()
    local hpPctNow = hp / math.max(1, bot:GetMaxHealth() or 600)
    if (not enemyHero or not U.CanQuery(enemyHero)) and s.enemyAlive ~= false
        and (#enemyCreeps > 0 or #allyCreeps > 0)
        and (bot:HasModifier("modifier_flask_healing") or (hpPctNow <= 0.28 and (s.enemyAbsentFor or 99) <= 8.0)) then
        -- `9069188041.dem` `03:44.1` Death #2 Fix: NEVER walk 620u backward SW toward `GetBehindT1(210)` when already deeper!
        local nearbyFogThreat = s.enemyLastLoc and ((s.enemyAbsentFor or 99) <= 3.5)
            and (U.DistanceBetweenLocations(bot:GetLocation(), s.enemyLastLoc) <= 980)
        local safeT1
        if P and P.GetRetreatAnchor then
            safeT1 = P.GetRetreatAnchor(bot, nearbyFogThreat and 480 or 210, nearbyFogThreat and 280 or 0)
        else
            safeT1 = (P and P.GetBehindT1 and P.GetBehindT1(bot, 210)) or P.GetFountain(bot)
        end
        if safeT1 and U.DistanceBetweenLocations(bot:GetLocation(), safeT1) > 35 then
            bot:Action_MoveToLocation(safeT1)
        elseif U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        return true, false
    end
    local enemyManaAvail = (enemyHero and U.CanQuery(enemyHero))
        and ((enemyHero:GetMana() or 0) + U.GetMangoMana(enemyHero)) or 0
    local canFinishEnemy = enemyHero and U.CanQuery(enemyHero)
        and (U.SolveLethalRace(bot, enemyHero, s).winsFirstKill
            or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            or U.CanOneShotEnemyHero(bot, enemyHero)
            or (enemyHero:GetHealth() <= U.GetNRazeDamage(bot, enemyHero, 1) + 75 and (bot:GetMana() or 0) >= 75)
            or (enemyManaAvail < 75 and (enemyHero:GetHealth() or 999) <= 145 and hp >= 140)
            or (race and race.valid and (race.canKillNow or (race.canKillSoon and not race.heCanKillNow))))
    local enAtkAdv = (enemyHero and U.CanQuery(enemyHero) and U._K and U._K.AttackDamageVs and U._K.AttackDamageVs(enemyHero, bot)) or 54
    local enManaRegenSoon = (enemyHero and U.CanQuery(enemyHero) and enemyHero.GetManaRegen and (enemyHero:GetManaRegen() or 1.0) * 2.5) or 2.5
    local myDomSoulAtk = enemyHero and U.CanQuery(enemyHero) and hp >= math.max(230, enAtkAdv * 4.0) and U._K and U._K.AttackDamageVs
        and U._K.AttackDamageVs(bot, enemyHero) >= U._K.AttackDamageVs(enemyHero, bot) + 10
        and hp >= (enemyHero:GetHealth() or 999) * 0.76
    -- `auto-20261031-0230` `02:08.1` Death #2 Fix + `9074178342.dem` `02:15.6..02:17.2` Dry-Enemy Overextend Into Allied Wave Fix:
    -- NEVER claim `weHoldDryAdvantage` at `180 HP` vs `334 HP / 68 MP` Lvl-3 SF (`3` right-clicks from death, or `2.5s` from `75 MP`!)!
    -- Conversely, when `hp >= max(255, enAtkAdv * 4.2)` AND a dry (`< 75 MP`, 0-coil) enemy walks onto flat/allied ground INTO `3+`
    -- allied creeps with `<= 1` enemy creep nearby (`0` creep aggro on us, `60..80 DPS` allied creeps on him!), stand & punish!
    local dryWaveShieldAdv = false
    if enemyHero and U.CanQuery(enemyHero) and enemyManaAvail < 75
        and not (U._K and U._K.EnemyPhase and U._K.EnemyPhase() ~= nil) then
        local bLocW = bot:GetLocation()
        local eLocW = enemyHero:GetLocation()
        if ((eLocW.z or 0) - (bLocW.z or 0)) < 64 and U.DistanceBetweenLocations(bLocW, eLocW) <= 560 then
            local alNearE, enNearB = 0, 0
            for _, ac in pairs(allyCreeps) do
                if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), eLocW) <= 480 then
                    alNearE = alNearE + 1
                end
            end
            for _, ec in pairs(enemyCreeps) do
                if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(ec:GetLocation(), bLocW) <= 500 then
                    enNearB = enNearB + 1
                end
            end
            if alNearE >= 3 and enNearB <= 1 and hp >= math.max(275, enAtkAdv * 4.5) then
                dryWaveShieldAdv = true
            end
        end
    end
    local weHoldDryAdvantage = ((enemyManaAvail + enManaRegenSoon < 75) or dryWaveShieldAdv)
        and (hp >= math.max(255, enAtkAdv * 4.2))
        and (myDomSoulAtk
            or canFinishEnemy
            or dryWaveShieldAdv
            or (hp >= math.max(260, (enemyHero and U.CanQuery(enemyHero) and enemyHero:GetHealth() or 999) * 0.82)
                and (bot:GetMana() or 0) >= 75))
    local pokedLow = enemyHero and U.CanQuery(enemyHero) and hp >= 155 and hp <= 345
        and not canFinishEnemy and not weHoldDryAdvantage
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    local myStacksNow, myStacksRemNow = U.GetShadowrazeDebuff(bot)
    local twoStackLethalWait = enemyHero and U.CanQuery(enemyHero) and not canFinishEnemy
        and (myStacksNow or 0) >= 2 and (myStacksRemNow or 0) > 0.35 and enemyManaAvail >= 75
        and hp <= ((race and race.valid and race.oneRaze) or 200) + 110
    if enemyHero and U.CanQuery(enemyHero) and not canFinishEnemy and not weHoldDryAdvantage
        and not (not twoStackLethalWait and L.EnemyCannotPunishLane(bot, enemyHero, hp))
        and ((hp >= 165 and hp <= 295) or pokedLow or twoStackLethalWait) and (#enemyCreeps > 0 or #allyCreeps > 0) then
        local lethalRace = race and race.valid and (race.heCanKillSoon or race.losingHard)
        if not lethalRace or pokedLow or twoStackLethalWait then
            local eLoc = enemyHero:GetLocation()
            local bLoc = bot:GetLocation()
            local d = U.DistanceBetweenLocations(bLoc, eLoc)
            local targetGap = twoStackLethalWait and 955 or (pokedLow and 810 or 860)
            if d < targetGap then
                local behindT1 = (P and P.GetRetreatAnchor and P.GetRetreatAnchor(bot, 210, 0))
                    or (P and P.GetBehindT1 and P.GetBehindT1(bot, 210))
                    or P.GetFountain(bot)
                local safeAnchor
                if U.DistanceBetweenLocations(behindT1, eLoc) > d + 40 and U.DistanceBetweenLocations(bLoc, behindT1) > 35 then
                    safeAnchor = behindT1
                else
                    local away = (bLoc - eLoc)
                    if away:Length2D() < 1 then away = (P.GetFountain(bot) - bLoc) end
                    safeAnchor = bLoc + away:Normalized() * (targetGap - d + 85)
                end
                safeAnchor = U.SteerAroundObstacles(bot, safeAnchor, s)
                if U.DistanceBetweenLocations(bLoc, safeAnchor) > 32 then
                    bot:Action_MoveToLocation(safeAnchor)
                elseif U.IsAttackingAction(bot) then
                    bot:Action_ClearActions(true)
                end
                return true, false
            else
                -- `v7.9.12-pro` (`2319 @ 06:29.33..06:33.33` `(645,530) <-> (530,480)` Ping-Pong Fix!):
                -- Strictly ONE-SIDED minimum-distance floor! NEVER pull a low-HP / `2`-stack wounded SF inward to `1,040u`
                -- toward `enemyHero` when `d >= targetGap` (which immediately re-triggers `DisengageFromLethalTrade`!).
                if U.IsAttackingAction(bot) then
                    bot:Action_ClearActions(true)
                end
                return true, false
            end
        end
    end

    -- 4. No CS needed in next ~1.70s and safe from low-HP hero focus: solve exact algebraic Under-Tower HP Prep hits!
    if L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAtk, enemySideAtk, s.allyTowers, s.enemyTowers, candidates, enemyHero, race) then
        return true, false
    end

    -- 4.25. Pro Dual-Value Ranged-Creep Prep (`1` auto -> `Shadowraze` kills ranged creep + hits rival SF!):
    -- When no CS is imminent, we have `>= 90` mana + ready `W`/`E`, and an unattacked enemy ranged creep stands near
    -- `enemyHero` (`<= 360u`) with `razeDmg < hp <= razeDmg + myAvgDmg + 12`, land ONE setup right-click from behind
    -- our wave so the very next tick/second `TryRazeSecureCS` scores a guaranteed +54g/+69XP + Hero Stack Dual Coil!
    if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
        and (bot:GetMana() or 0) >= 90 and (bot:GetHealth() or 0) >= 340 then
        local nowPrep = GameTime()
        local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
        if (nowPrep - (bot:GetLastAttackTime() or -100)) >= mySpa * 0.95 then
            local wAb = U.GetAbility(bot, "nevermore_shadowraze2")
            local eAb = U.GetAbility(bot, "nevermore_shadowraze3")
            local refAb = (wAb and wAb:IsFullyCastable() and wAb) or (eAb and eAb:IsFullyCastable() and eAb) or nil
            if refAb then
                local rRaw = U.GetRazeDamage(bot, refAb, 0)
                local eLoc = enemyHero:GetLocation()
                for _, ec in pairs(enemyCreeps) do
                    if U.CanQuery(ec) and ec:IsAlive() then
                        local nm = ec:GetUnitName() or ""
                        local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                        if string.find(nm, "ranged", 1, true) and dc <= (bot:GetAttackRange() or 525) + 25
                            and U.DistanceBetweenLocations(ec:GetLocation(), eLoc) <= 360 then
                            local rMagic = math.floor(ec:GetActualIncomingDamage(rRaw, DAMAGE_TYPE_MAGICAL))
                            local myAvg = U.SFDamageRange(bot, ec).avg
                            local cHp = ec:GetHealth() or 999
                            if cHp > rMagic + 8 and cHp <= rMagic + myAvg + 10 then
                                bot:Action_AttackUnit(ec, true)
                                return true, true
                            end
                        end
                    end
                end
            end
        end
    end

    -- 4.5. `v5.0.0` Source 2 Creep-Aggro Reset & Kite-Back During Idle Wait (respects `2.3s` chase lock & `515u` ranged reset!):
    do
        local creepsHittingMe, closestAggroCreep, rangedAggroIdle, minAggroDist = 0, nil, nil, math.huge
        local recentCreepHit = (bot.WasRecentlyDamagedByCreep and bot:WasRecentlyDamagedByCreep(0.95)) or false
        for _, ec in pairs(enemyCreeps) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (recentCreepHit and dc <= 215) then
                    creepsHittingMe = creepsHittingMe + 1
                    if dc < minAggroDist then
                        minAggroDist, closestAggroCreep = dc, ec
                    end
                    if ((ec.GetAttackRange and ec:GetAttackRange()) or 100) > 300 and dc <= 505 then
                        rangedAggroIdle = ec
                    end
                end
            end
        end
        local allyShieldNear = 0
        for _, ac in pairs(allyCreeps) do
            if U.CanQuery(ac) and ac:IsAlive() and GetUnitToLocationDistance(bot, ac:GetLocation()) <= 360 then
                allyShieldNear = allyShieldNear + 1
            end
        end
        -- `v7.9.19` (`9074666246.dem` `06:36..06:43` `RAD CREEP id=208` `dT1=697.5u` Aggro-Hijack Pull-Out!):
        -- If our `allyT1` has a Siege Catapult (`<= 865u`) or Enemy Hero (`<= 775u`) hitting it while `closestAggroCreep`
        -- stands inside `<= 725u` of `allyT1` attacking `bot`, pull `closestAggroCreep` to `835u` toward Fountain (`> 730u`
        -- outside `allyT1` `700u` range) so `allyT1` immediately switches Priority #1 aggro onto the Catapult/Hero!
        local aggroHijackingAllyT1 = false
        if closestAggroCreep and allyShieldNear == 0 and s and s.allyT1Alive and s.allyT1Loc
            and U.DistanceBetweenLocations(closestAggroCreep:GetLocation(), s.allyT1Loc) <= 725 then
            if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
                and U.DistanceBetweenLocations(enemyHero:GetLocation(), s.allyT1Loc) <= 775 then
                aggroHijackingAllyT1 = true
            else
                for _, ecS in pairs(enemyCreeps) do
                    if U.CanQuery(ecS) and ecS:IsAlive() then
                        local nmS = (ecS.GetUnitName and ecS:GetUnitName()) or ""
                        if (nmS:find("siege") or nmS:find("catapult"))
                            and U.DistanceBetweenLocations(ecS:GetLocation(), s.allyT1Loc) <= 865 then
                            aggroHijackingAllyT1 = true
                            break
                        end
                    end
                end
            end
        end
        local lowOrMultiTank = aggroHijackingAllyT1
            or (creepsHittingMe >= 2)
            or (creepsHittingMe >= 1 and ((bot:GetHealth() or 999) < (bot:GetMaxHealth() or 999) * 0.85 or allyShieldNear == 0))
        if lowOrMultiTank and closestAggroCreep then
            local nowT = GameTime()
            local chaseLocked = nowT < (((U._State and U._State.myCreepChaseUntil) or 0) - 0.08)
            local maxDeaggroReachIdle = (bot:GetAttackRange() or 525) + 35
            local bestAlly, bestAllyDist = nil, math.huge
            for _, ac in pairs(allyCreeps) do
                if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 55 then
                    local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                    if da <= maxDeaggroReachIdle and da < bestAllyDist then
                        bestAllyDist, bestAlly = da, ac
                    end
                end
            end
            if L._lastDeaggroAt and nowT < L._lastDeaggroAt then
                L._lastDeaggroAt = -100
            end
            if not chaseLocked and not rangedAggroIdle and bestAlly and nowT >= (L._lastDeaggroAt or -100) + 1.35 then
                L._lastDeaggroAt = nowT
                bot:Action_AttackUnit(bestAlly, true)
                return true, true
            end
            local fnt = P.GetFountain(bot)
            local rawKite
            if aggroHijackingAllyT1 and s and s.allyT1Loc then
                rawKite = s.allyT1Loc + (fnt - s.allyT1Loc):Normalized() * 835
            else
                local refLoc = rangedAggroIdle and rangedAggroIdle:GetLocation()
                    or (bestAlly and bestAlly:GetLocation() or closestAggroCreep:GetLocation())
                local padBack = rangedAggroIdle and 525 or (bestAlly and 265 or 355)
                rawKite = refLoc + (fnt - refLoc):Normalized() * padBack
            end
            local kiteAnchor = U.SteerAroundObstacles(bot, rawKite, s)
            if kiteAnchor and U.DistanceBetweenLocations(bot:GetLocation(), kiteAnchor) > 25 then
                if U._State then
                    U._State.lastMoveLoc = kiteAnchor
                    U._State.lastMoveTime = nowT
                end
                bot:Action_MoveToLocation(kiteAnchor)
                return true, true
            end
        end
    end

    -- 4.75. Dominance & Post-Kill Equilibrium Freeze (`v7.5.0` + `v7.8.0` `ShaNachnetsya` `00:45–01:01` Fix):
    -- When dominating the lane (or when the enemy hero is DEAD and we are holding wave equilibrium instead of shoving!)
    -- with no enemy CS opening inside `mySpa + 0.55s`, chip any `< 50% HP` allied creep safely to pull equilibrium & build souls!
    local postKillFreeze = (s and s.enemyAlive == false)
        and not (U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s))
    if allowAllyDenies and not siegingEnemyT1 and (postKillFreeze or (U.IsLaneDominant and U.IsLaneDominant(bot, s, race))) then
        local enemyFarEnough = postKillFreeze or (not enemyHero) or (not U.CanQuery(enemyHero))
            or (GetUnitToLocationDistance(bot, enemyHero:GetLocation()) > 830)
        if enemyFarEnough then
            local nowPD = GameTime()
            local mySpaPD = math.max(0.65, bot:GetSecondsPerAttack() or 1.35)
            local needClearTicks = math.ceil((mySpaPD + 0.55) * 30.0)
            local enemyCSOpeningSoon = false
            for _, cand in ipairs(candidates) do
                if not cand.isDeny and cand.kOpen ~= nil and cand.kOpen >= 0 and cand.kOpen <= needClearTicks then
                    enemyCSOpeningSoon = true
                    break
                end
            end
            if not enemyCSOpeningSoon and (nowPD - (bot:GetLastAttackTime() or -100)) >= mySpaPD * 0.95 then
                local enHeroRawDmg = postKillFreeze and 0
                    or ((enemyHero and U.CanQuery(enemyHero) and enemyHero:GetAttackDamage())
                        or (s and s.enemyLastAttackDmg) or 82)
                for _, ac in pairs(denyCreepsList) do
                    if U.CanQuery(ac) and ac:IsAlive() then
                        local hpA = ac:GetHealth() or 999
                        local maxHpA = math.max(1, ac:GetMaxHealth() or 550)
                        local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                        if (hpA * 2 < maxHpA) and da <= (bot:GetAttackRange() or 525) + 15 then
                            local myDmgRange = U.SFDamageRange(bot, ac)
                            local enHeroDmg = postKillFreeze and 0 or ac:GetActualIncomingDamage(enHeroRawDmg + 6, DAMAGE_TYPE_PHYSICAL)
                            local incomingCreepDps = 0
                            for _, ec in pairs(enemyCreeps) do
                                if U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == ac then
                                    incomingCreepDps = incomingCreepDps + 22
                                end
                            end
                            local hpAfterReload = hpA - myDmgRange.max - incomingCreepDps * (mySpaPD + 0.25)
                            local minSafeFloor = postKillFreeze and math.max(24, myDmgRange.min * 0.55)
                                or math.max(enHeroDmg + 28, myDmgRange.min + 14)
                            if hpA > myDmgRange.min + 6 and hpAfterReload >= minSafeFloor then
                                bot:Action_AttackUnit(ac, true)
                                return true, true
                            end
                        end
                    end
                end
            end
        end
    end

    -- 5. Uncontested Wave Equilibrium Stance Discipline:
    -- When uncontested (enemy absent / dead / TPing), hold crisp 175u highground CS anchor
    -- across the entire wave so walkTicks == 0 and fTicks == 4 on 100% of creeps; when an
    -- enemy hero IS live in lane and no creep opens within 68 ticks, yield to combat/spacing!
    local siegingEnemyT1Now = s.enemyT1Alive and s.enemyT1Loc and #allyCreeps >= 1
        and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1120
    local damagedAllyDenySoon = false
    if allowAllyDenies then
        for _, ac in pairs(denyCreepsList) do
            if U.CanQuery(ac) and (ac:GetHealth() or 0) > 0 and ac:GetHealth() < ac:GetMaxHealth() * 0.58 then
                damagedAllyDenySoon = true
                break
            end
        end
    end
    -- Also step up toward `GetLasthitPosition` when `enemyHero` IS visible if SF was stranded `> 690u` from the active wave clash (`0:48..0:52` fix!),
    -- STRICTLY gated by `not retreatContinuityNow` (`9074666246.dem` `00:39, 02:05, 03:28, 04:05, 10:27` 180-deg Ping-Pong Fix!)
    local stIdle = U._State
    local nowIdle = GameTime()
    local retreatContinuityNow = stIdle and (
        (stIdle.forcedRetreatLoc ~= nil and nowIdle < (stIdle.forcedRetreatUntil or 0))
        or (nowIdle < (stIdle.fleeUntil or 0))
        or (nowIdle < (stIdle.critDangerHystUntil or 0))
        or (stIdle.survivalLoc ~= nil and nowIdle < (stIdle.survivalUntil or 0))
        or (nowIdle < (stIdle.noHarassTurnbackUntil or 0))
        or (stIdle.dodgeLoc ~= nil and nowIdle < (stIdle.dodgeUntil or 0))
    )
    local minWaveCreepDist = 9999
    for _, ec in pairs(enemyCreeps) do
        if U.CanQuery(ec) and ec:IsAlive() then
            local dcw = GetUnitToLocationDistance(bot, ec:GetLocation())
            if dcw < minWaveCreepDist then minWaveCreepDist = dcw end
        end
    end
    local strandedFromClash = (not retreatContinuityNow)
        and (minWaveCreepDist > 745 and minWaveCreepDist <= 1550)
        and not (U.IsDryVsArmedEnemySF and enemyHero and U.CanQuery(enemyHero) and U.IsDryVsArmedEnemySF(bot, enemyHero, s))
    if not siegingEnemyT1Now and not retreatContinuityNow
        and ((not enemyHero or not U.CanQuery(enemyHero)) or strandedFromClash)
        and (#enemyCreeps >= 2 or damagedAllyDenySoon) and P and P.GetLasthitPosition then
        -- `v7.9.12-pro` (`2319` Fix): 4th argument of `P.GetLasthitPosition` is `prepareTarget` (creep), NEVER `enemyHero`!
        local anchor = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, "NEUTRAL")
        if anchor then anchor = U.SteerAroundObstacles(bot, anchor, s) end
        if anchor and U.DistanceBetweenLocations(bot:GetLocation(), anchor) > 32 then
            if stIdle then
                stIdle.lastMoveLoc = anchor
                stIdle.lastMoveTime = nowIdle
            end
            bot:Action_MoveToLocation(anchor)
        elseif U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        return true, true
    end

    -- Check whether any creep is below 72% HP so `HandlePriorityPush` does NOT blind-auto-attack mid-wave!
    local waveHasDamagedCreep = false
    for _, c in pairs(enemyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.72 then
            waveHasDamagedCreep = true
            break
        end
    end
    for _, c in pairs(allyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.65 then
            waveHasDamagedCreep = true
            break
        end
    end
    return false, waveHasDamagedCreep
end

return L
