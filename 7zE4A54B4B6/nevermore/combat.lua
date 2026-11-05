--
-- SF vs SF combat model:
-- * enemy raze tracker (cast phase -> ready time, because GetCooldownTimeRemaining
-- does not work for enemy abilities);
-- * honest raze damage (base + stacks + 2 per soul, the talent via GetSpecialValueInt);
-- * the "race": absolute HP after the exchange, who kills whom, which enemy bands are dangerous;
-- * the chase rule (CanCatch): do not run after an enemy with equal speed.
--
-- Combat estimates use the current visible snapshot and bounded time windows.

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")

local K = {}

K.LABELS = { "near", "mid", "far" }
K.RAZE_NAMES = {
    near = "nevermore_shadowraze1",
    mid  = "nevermore_shadowraze2",
    far  = "nevermore_shadowraze3",
}

local RAZE_CD        = (C.RAZE and C.RAZE.COOLDOWN) or 9.0
local CAST_POINT     = (C.RAZE and C.RAZE.CAST_POINT) or 0.55
local HIT_RADIUS     = (C.RAZE and C.RAZE.HIT_RADIUS) or 250
local RAZE_MANA      = 75
local PER_SOUL_FALLBACK = (C.RAZE and C.RAZE.DAMAGE_PER_SOUL) or 2

local function Center(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid" then return C.RAZE.MID_CENTER end
    return C.RAZE.FAR_CENTER
end
K.Center = Center

-- Raze damage (Patch 7.41f: 85/150/215/280 base, 35/50/65/80 stack bonus, +30 Lvl 10 talent, 6.0s stack duration)

local BASE_RAZE_DMG  = (C.RAZE and C.RAZE.BASE_DAMAGE)  or { 85, 150, 215, 280 }
local STACK_RAZE_DMG = (C.RAZE and C.RAZE.STACK_DAMAGE) or { 35, 50, 65, 80 }
local STACK_DURATION = (C.RAZE and C.RAZE.STACK_DURATION) or 6.0

function K.RazeRawDamage(ability, stacks, souls, caster, lvlFallback)
    local lvl = (ability and ability.GetLevel and ability:GetLevel()) or 0
    if lvl <= 0 then lvl = lvlFallback or 0 end
    if lvl <= 0 then return 0 end
    -- CRITICAL DOTA 2 7.36-7.41f FIX: `nevermore_shadowraze*` uses `AbilityValues` KV in `npc_abilities.txt`,
    -- causing C++ `GetSpecialValueInt("shadowraze_damage")` & `"stack_bonus_damage"` to return `0` on live servers!
    local base = (ability and ability.GetSpecialValueInt and ability:GetSpecialValueInt("shadowraze_damage")) or 0
    if base <= 0 then base = BASE_RAZE_DMG[math.min(4, lvl)] or 85 end
    local stackDmg = (ability and ability.GetSpecialValueInt and ability:GetSpecialValueInt("stack_bonus_damage")) or 0
    if stackDmg <= 0 then
        stackDmg = STACK_RAZE_DMG[math.min(4, lvl)] or 35
        if caster and U.HasRazeStackTalent and U.HasRazeStackTalent(caster) then
            stackDmg = stackDmg + ((C.RAZE and C.RAZE.TALENT_STACK_BONUS) or 30)
        end
    end
    local perSoul = (ability and ability.GetSpecialValueInt and ability:GetSpecialValueInt("damage_per_soul")) or 0
    if not perSoul or perSoul <= 0 then perSoul = PER_SOUL_FALLBACK end
    local raw = base + (stacks or 0) * stackDmg + (souls or 0) * perSoul
    if caster and U.GetSpellAmpMult then
        raw = raw * U.GetSpellAmpMult(caster)
    end
    return raw
end

-- Damage of N of my razes on a target (current stacks on the target, my souls, target's magic resist + Infused Raindrop).
function K.MyRazeDamage(bot, target, n, extraStacks)
    if n <= 0 or not U.CanQuery(target) then return 0 end
    local q = U.GetAbility(bot, "nevermore_shadowraze1")
    local qLvl = (q and q:GetLevel()) or 0
    if qLvl <= 0 then return 0 end
    local souls = S.GetSouls(bot)
    local stacks = (U.GetShadowrazeDebuff(target) or 0) + (extraStacks or 0)
    if stacks < 0 then stacks = 0 end
    local isHeroTgt = target.IsHero and target:IsHero()
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls, bot, qLvl)
        if i == 1 and isHeroTgt and U.GetMagicBlockOnFirstRaze then
            raw = math.max(0, raw - U.GetMagicBlockOnFirstRaze(target, raw))
        end
        total = total + target:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

local ENEMY_RAZE_TICK = { scopeId = -1, epoch = -1, bot = nil, enemy = nil, r1 = nil, r2 = nil, r3 = nil }

-- Damage of N enemy razes on me (handles C++ enemy ability level returning 0 via U.InferRazeLevel).
function K.EnemyRazeDamage(bot, enemy, n, stacksOverride)
    if n <= 0 or not U.CanQuery(enemy) then return 0 end
    if U._inTickScope and stacksOverride == nil and (n == 1 or n == 2 or n == 3) then
        local c = ENEMY_RAZE_TICK
        if c.scopeId ~= U._scopeId or c.epoch ~= U._invEpoch or c.bot ~= bot or c.enemy ~= enemy then
            c.scopeId, c.epoch, c.bot, c.enemy = U._scopeId, U._invEpoch, bot, enemy
            c.r1, c.r2, c.r3 = nil, nil, nil
        end
        if n == 1 and c.r1 ~= nil then return c.r1 end
        if n == 2 and c.r2 ~= nil then return c.r2 end
        if n == 3 and c.r3 ~= nil then return c.r3 end
        local q = U.GetAbility(enemy, "nevermore_shadowraze1")
        local eLvl = U.InferRazeLevel and U.InferRazeLevel(enemy) or (q and q:GetLevel() or 0)
        if eLvl <= 0 then
            c.r1, c.r2, c.r3 = 0, 0, 0
            return 0
        end
        local souls = S.GetSouls(enemy)
        local stacks = U.GetShadowrazeDebuff(bot) or 0
        local total = 0
        for i = 1, n do
            local raw = K.RazeRawDamage(q, stacks + i - 1, souls, enemy, eLvl)
            if i == 1 and U.GetMagicBlockOnFirstRaze then
                raw = math.max(0, raw - U.GetMagicBlockOnFirstRaze(bot, raw))
            end
            total = total + bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
        end
        if n == 1 then c.r1 = total elseif n == 2 then c.r2 = total else c.r3 = total end
        return total
    end
    local q = U.GetAbility(enemy, "nevermore_shadowraze1")
    local eLvl = U.InferRazeLevel and U.InferRazeLevel(enemy) or (q and q:GetLevel() or 0)
    if eLvl <= 0 then return 0 end
    local souls = S.GetSouls(enemy)
    local stacks = stacksOverride or (U.GetShadowrazeDebuff(bot) or 0)
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls, enemy, eLvl)
        if i == 1 and U.GetMagicBlockOnFirstRaze then
            raw = math.max(0, raw - U.GetMagicBlockOnFirstRaze(bot, raw))
        end
        total = total + bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

local ATK_VS_TICK = { scopeId = -1, epoch = -1, a1 = nil, t1 = nil, v1 = 0, a2 = nil, t2 = nil, v2 = 0 }

-- Exact post-armor AND Source 2 Attack-Class (`Piercing` / `Runty` / `Reinforced` / `Hero`) physical damage.
function K.AttackDamageVs(attacker, target)
    if not attacker or not U.CanQuery(target) then return 0 end
    if U._inTickScope and attacker.IsHero and attacker:IsHero() and target.IsHero and target:IsHero() then
        local c = ATK_VS_TICK
        if c.scopeId ~= U._scopeId or c.epoch ~= U._invEpoch then
            c.scopeId, c.epoch = U._scopeId, U._invEpoch
            c.a1, c.t1, c.a2, c.t2 = nil, nil, nil, nil
        elseif c.a1 == attacker and c.t1 == target then
            return c.v1
        elseif c.a2 == attacker and c.t2 == target then
            return c.v2
        end
        local raw = attacker:GetAttackDamage() or 0
        local val = 0
        if raw > 0 then
            val = U.CalcExactIntDamage and U.CalcExactIntDamage(attacker, target, raw)
                or target:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
        end
        if c.a1 == nil then c.a1, c.t1, c.v1 = attacker, target, val
        elseif c.a2 == nil then c.a2, c.t2, c.v2 = attacker, target, val end
        return val
    end
    local raw = attacker:GetAttackDamage() or 0
    if raw <= 0 then return 0 end
    if U.CalcExactIntDamage then
        return U.CalcExactIntDamage(attacker, target, raw)
    end
    return target:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
end

-- My razes: readiness + mana (counting mango/stick when allowConsumables)

function K.MyManaBudget(bot, allowConsumables)
    local mana = bot:GetMana() or 0
    if allowConsumables then
        mana = mana + U.GetMangoMana(bot) -- By charges
        local charges = U.GetStickCharges(bot)
        if charges > 0 then
            local stick = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
            if stick then mana = mana + charges * 15 end
        end
        -- Include courier Mango ONLY when transfer is practically touching (`<= 0.35s`) for instant-cast budget
        if U.GetIncomingCourierMana then
            mana = mana + U.GetIncomingCourierMana(bot, 0.35)
        end
    end
    return mana
end

-- Sustained Combat/Trade Mana Forecast (`v7.9.5`, `auto-20261102-0139` `3:58.80` Courier-ETA Mango Fix!):
-- Combines on-hand `MyManaBudget(bot, true)` WITH incoming courier Mango mana arriving within `horizonSec` (`default 6.5s`),
-- using exact 2-body closing velocity (`courier` + `bot` movement vectors). Prevents false "last-75-MP" trade paralysis
-- when Mangoes on the courier will refill `+100..+300 MP` right after our opening coil!
function K.MySustainedManaBudget(bot, horizonSec)
    local h = horizonSec or 6.5
    local instant = K.MyManaBudget(bot, true)
    if h > 0.35 and U.GetUnlockingMangoMana then
        instant = instant + (U.GetUnlockingMangoMana(bot, h) or 0)
    end
    if h > 0.35 and U.GetIncomingCourierMana then
        local cMana = U.GetIncomingCourierMana(bot, h)
        local nearMana = U.GetIncomingCourierMana(bot, 0.35)
        instant = instant + math.max(0, cMana - nearMana)
    end
    return instant
end

-- Time-gated Raze count budget for `bot` over `[0, horizonSec]` (`v7.9.14-pro`):
-- Accounts for instant mana + active unlocked Mangoes + 6s backpack-swap Mangoes unlocking before `horizonSec - 0.45s`
-- + courier Mangoes arriving before `horizonSec - 0.50s` (strictly capped by remaining `0.55s` sequential cast slots
-- AFTER courier arrival so a Mango arriving at `t = 1.7s` inside a `2.5s` window unlocks at most `1` coil, not `3`!).
function K.MyEffectiveRazeBudgetAt(bot, allowConsumables, horizonSec)
    local h = horizonSec or 0.3
    local baseMana = K.MyManaBudget(bot, allowConsumables)
    if h >= 1.2 then
        baseMana = baseMana + math.max(0, (bot.GetManaRegen and bot:GetManaRegen()) or 1.0) * math.min(h, 3.0)
    end
    if allowConsumables and h > 0.45 and U.GetUnlockingMangoMana then
        baseMana = baseMana + (U.GetUnlockingMangoMana(bot, h) or 0)
    end
    local preRazes = math.floor(math.max(0, baseMana) / RAZE_MANA)
    if allowConsumables and h > 0.55 and U.GetIncomingCourierMana then
        local nearMana = U.GetIncomingCourierMana(bot, 0.35)
        local cMana, cEta = U.GetIncomingCourierMana(bot, h - 0.50)
        local extraCourMana = math.max(0, (cMana or 0) - (nearMana or 0))
        if extraCourMana > 0 and (cEta or 999) <= (h - 0.50) then
            local postSlots = math.max(1, math.floor((h - cEta + 0.15) / CAST_POINT))
            local totalRazes = math.floor((baseMana + extraCourMana) / RAZE_MANA)
            return math.min(totalRazes, preRazes + postSlots)
        end
    end
    return preRazes
end

-- How many of my razes are really available (cooldown ready and enough mana).
-- Returns count, readyIgnoringMana.
function K.MyReadyRazeCount(bot, allowConsumables)
    local ready = 0
    for i = 1, 3 do
        local ab = U.GetAbility(bot, K.RAZE_NAMES[K.LABELS[i]])
        if ab and ab:GetLevel() > 0 and ab:IsCooldownReady() then
            ready = ready + 1
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, allowConsumables) / RAZE_MANA)
    if budget < ready then return budget, ready end
    return ready, ready
end

function K.MyRazeReady(bot, label)
    local ab = U.GetAbility(bot, K.RAZE_NAMES[label])
    return ab and ab:GetLevel() > 0 and ab:IsCooldownReady() or false
end

-- Enemy raze tracker

K._enemy = {
    key = nil,
    raze = {
        near = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        mid  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        far  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
    },
    phaseLabel = nil,
    phaseStart = -1,
    requiemInPhase = false,
    requiemPhaseStart = -1,
    lastAnyCastAt = -1,
    prevMyStacks = 0,
    prevMyStacksTime = -1,
    prevYaw = nil,
    prevYawAt = -1,
    yawVelDegPerSec = 0,
}

local function ResetEnemyTracker()
    local E = K._enemy
    for i = 1, 3 do
        local st = E.raze[K.LABELS[i]]
        st.inPhase = false
        st.phaseStart = -1
        st.readyAt = 0
        st.lastCastAt = -1
    end
    E.phaseLabel = nil
    E.phaseStart = -1
    E.requiemInPhase = false
    E.requiemPhaseStart = -1
    E.lastAnyCastAt = -1
    E.prevYaw = nil
    E.prevYawAt = -1
    E.yawVelDegPerSec = 0
end

local function EnemyKey(enemy)
    local pid = enemy.GetPlayerID and enemy:GetPlayerID()
    if pid == nil or pid < 0 then return tostring(enemy) end
    return pid
end

-- Call every tick (enemy may be nil / invisible).
function K.UpdateEnemyTracker(bot, enemy)
    local now = GameTime()
    local E = K._enemy

    -- Hull-aware + Cooldown-eliminating FoW Band Deducer (`HERO_EFF_RADIUS = 274u`):
    --   near (`200 ± 274`) = `[0, 474]`, mid (`450 ± 274`) = `[176, 724]`, far (`700 ± 274`) = `[426, 974]`.
    --   Excludes bands already known to be on cooldown (`readyAt > now + 0.35`), resolving `[426, 724]` & `[176, 474]` overlaps!
    local function deduceBandByDist(estDist)
        if not estDist or estDist <= 0 then return nil end
        local nearAvail = (E.raze.near.readyAt or 0) <= now + 0.35 and estDist <= 488
        local midAvail  = (E.raze.mid.readyAt  or 0) <= now + 0.35 and estDist >= 162 and estDist <= 738
        local farAvail  = (E.raze.far.readyAt  or 0) <= now + 0.35 and estDist >= 412 and estDist <= 995
        if estDist > 726 and farAvail then return "far" end
        if estDist < 174 and nearAvail then return "near" end
        local count = (nearAvail and 1 or 0) + (midAvail and 1 or 0) + (farAvail and 1 or 0)
        if count == 1 then
            if farAvail then return "far" end
            if midAvail then return "mid" end
            if nearAvail then return "near" end
        end
        if estDist >= 595 and farAvail and not midAvail then return "far" end
        if estDist <= 315 and nearAvail and not midAvail then return "near" end
        return nil
    end

    if not U.CanQuery(enemy) then
        -- Preserve mid-cast -> Fog-of-War Raze completions (`>= 0.30s` into `0.55s` cast point before losing sight!)
        for i = 1, 3 do
            local st = E.raze[K.LABELS[i]]
            if st.inPhase and st.phaseStart and st.phaseStart > 0 and (now - st.phaseStart) >= 0.30 then
                local releaseAt = st.phaseStart + CAST_POINT
                st.lastCastAt = releaseAt
                st.readyAt = math.max(st.readyAt or 0, releaseAt + RAZE_CD - 0.10)
                E.lastAnyCastAt = releaseAt
            end
            st.inPhase = false
        end
        E.phaseLabel = nil
        E.requiemInPhase = false
        E.prevYaw = nil
        E.yawVelDegPerSec = 0
        if bot then
            local fogStacks, fogRem = U.GetShadowrazeDebuff(bot)
            fogStacks = fogStacks or 0
            fogRem = fogRem or 0
            local freshStackHit = (fogStacks >= 1 and fogRem >= (STACK_DURATION - 0.85))
                and (fogStacks > (E.prevMyStacks or 0) or fogStacks == 1)
            if freshStackHit then
                local hitTime = now - math.max(0.0, STACK_DURATION - fogRem)
                if hitTime > (E.lastAnyCastAt or -100) + 0.45 then
                    local Wref = U._W
                    local lastLoc = Wref and Wref.s and Wref.s.enemyLastLoc
                    local estDist = lastLoc and GetUnitToLocationDistance(bot, lastLoc) or 0
                    local bLabel = deduceBandByDist(estDist)
                    if bLabel then
                        local st = E.raze[bLabel]
                        st.lastCastAt = hitTime
                        st.readyAt = math.max(st.readyAt or 0, hitTime + RAZE_CD - 0.15)
                    end
                    E.lastAnyCastAt = hitTime
                end
            end
            E.prevMyStacks = fogStacks
            E.prevMyStacksTime = now
        end
        return
    end

    local key = EnemyKey(enemy)
    if E.key ~= key or E.selfBot ~= bot then
        ResetEnemyTracker()
        E.key = key
        E.selfBot = bot
        E.prevMyStacksTime = -1
        E.prevEnemyMana = nil
    end

    local actAnim = enemy.GetAnimActivity and enemy:GetAnimActivity() or 0
    local curAb = enemy.GetCurrentActiveAbility and enemy:GetCurrentActiveAbility() or nil

    -- Track enemy angular yaw velocity (`deg/s`) for Dota 2 `NO_TARGET` Turn-During-Cast-Point Raze prediction
    -- (`auto-20261103-1343` `#79` @ `10:30.40`: `140.6 deg -> 38.0 deg` over `0.55s` cast point = `-186 deg/s`!).
    if enemy.GetFacing then
        local curYaw = enemy:GetFacing()
        if type(curYaw) == "number" then
            if E.prevYaw ~= nil and E.prevYawAt and E.prevYawAt > 0 then
                local dtYaw = now - E.prevYawAt
                if dtYaw >= 0.015 and dtYaw <= 0.25 then
                    local dYaw = ((curYaw - E.prevYaw + 540.0) % 360.0) - 180.0
                    if math.abs(dYaw) < 0.08 then
                        E.yawVelDegPerSec = (E.yawVelDegPerSec or 0) * 0.35
                        if math.abs(E.yawVelDegPerSec) < 4.0 then E.yawVelDegPerSec = 0 end
                    else
                        local instVel = math.max(-580.0, math.min(580.0, dYaw / dtYaw))
                        if dtYaw <= 0.12 and E.yawVelDegPerSec and E.yawVelDegPerSec ~= 0
                            and (instVel * E.yawVelDegPerSec) > 0 then
                            E.yawVelDegPerSec = 0.72 * instVel + 0.28 * E.yawVelDegPerSec
                        else
                            E.yawVelDegPerSec = instVel
                        end
                    end
                elseif dtYaw > 0.25 then
                    E.yawVelDegPerSec = 0
                end
            else
                E.yawVelDegPerSec = 0
            end
            if E.prevYawAt ~= now then
                E.prevYaw = curYaw
                E.prevYawAt = now
            end
        end
    end

    E.phaseLabel = nil
    for i = 1, 3 do
        local label = K.LABELS[i]
        local razeName = K.RAZE_NAMES[label]
        local st = E.raze[label]
        local ab = U.GetAbility(enemy, razeName)
        local inPhase = false
        if ab and ab:GetLevel() > 0 and ab:IsInAbilityPhase() then
            inPhase = true
        elseif curAb and curAb.GetName and curAb:GetName() == razeName then
            inPhase = true
        elseif actAnim == (1509 + i) then -- 1510 = Q (near), 1511 = W (mid), 1512 = E (far)
            inPhase = true
        end

        if inPhase and not st.inPhase then
            local preVel = E.yawVelDegPerSec or 0
            st.phaseStart = now
            st.phaseStartYaw = (enemy.GetFacing and enemy:GetFacing()) or 0
            st.preTurnTowardBot = false
            -- `v7.9.20` (`1610.dem` `#01/#05/#06/#08/#10` Active Turn-Into-Cast vs `9074666246` Finished-Turn Fix):
            -- Preserve `preVel` on tick 0 ONLY when `enemy` is actively spinning (`|preVel| >= 85 deg/s`) TOWARD `bot`
            -- (`|deltaToBot| >= 14 deg`) while `bot` stands inside `label`'s radial band (`[cDist - 285, cDist + 285]`);
            -- otherwise zero `yawVelDegPerSec` so an already-finished pre-cast turn never overshoots past `bot`!
            if bot and U.CanQuery(bot) and math.abs(preVel) >= 85.0 then
                local eLoc0 = enemy:GetLocation()
                local bLoc0 = bot:GetLocation()
                local dHero0 = U.DistanceBetweenLocations(eLoc0, bLoc0)
                local cDist0 = Center(label)
                if dHero0 >= math.max(0.0, cDist0 - 285.0) and dHero0 <= (cDist0 + 285.0) then
                    local yawToBot0 = math.deg(math.atan2(bLoc0.y - eLoc0.y, bLoc0.x - eLoc0.x))
                    local delta0 = ((yawToBot0 - st.phaseStartYaw + 540.0) % 360.0) - 180.0
                    if math.abs(delta0) >= 14.0 and math.abs(delta0) <= 168.0 and (delta0 * preVel) > 0 then
                        st.preTurnTowardBot = true
                    end
                end
            end
            if not st.preTurnTowardBot then
                E.yawVelDegPerSec = 0
            end
            st.manaAtStart = (enemy.GetMana and enemy:GetMana()) or nil
            st.mangoManaAtStart = (U.GetMangoMana and U.GetMangoMana(enemy)) or 0
            st.stickAtStart = (U.GetStickCharges and U.GetStickCharges(enemy)) or 0
            local s0, r0 = 0, 0
            if bot and U.GetShadowrazeDebuff then
                s0, r0 = U.GetShadowrazeDebuff(bot)
            end
            st.myStacksAtStart = s0 or 0
            st.myRemAtStart = r0 or 0
        elseif st.inPhase and not inPhase then
            local dur = now - st.phaseStart
            -- `v7.9.17-pro` (`1507 @ 07:11.00–07:12.00` & `DEFEAT_0_2_REVIEW_RU.md` Counterexample #1 Fix!):
            -- Skilled humans (`ShaNachnetsya`) hold Shadowraze pump-fakes for `0.40..0.54s` and cancel with `HOLD_POSITION` (`0 MP` spent!).
            -- NEVER stamp a `9.0s` phantom cooldown unless the spell ACTUALLY detonated (confirmed by native ability CD, `~75 MP` mana drop
            -- accounting for Mango/Stick/regen, or fresh Shadowraze debuff stack/refresh on `bot`)!
            local nativeCd = (ab and ab.GetCooldownTimeRemaining and ab:GetCooldownTimeRemaining()) or 0
            local manaConfirmed = (st.manaAtStart == nil)
            if st.manaAtStart ~= nil and enemy.GetMana then
                local curM = enemy:GetMana() or 0
                local curMangoM = (U.GetMangoMana and U.GetMangoMana(enemy)) or 0
                local curStick = (U.GetStickCharges and U.GetStickCharges(enemy)) or 0
                local gainedItems = math.max(0, (st.mangoManaAtStart or 0) - curMangoM)
                    + math.max(0, ((st.stickAtStart or 0) - curStick) * 15)
                local gainedRegen = math.max(0, dur) * ((enemy.GetManaRegen and enemy:GetManaRegen()) or 1.4)
                local expectedNoCast = st.manaAtStart + gainedItems + gainedRegen
                manaConfirmed = ((expectedNoCast - curM) >= 38.0)
            end
            local stackConfirmed = false
            if bot and U.GetShadowrazeDebuff then
                local sNow, rNow = U.GetShadowrazeDebuff(bot)
                sNow, rNow = sNow or 0, rNow or 0
                stackConfirmed = (sNow > (st.myStacksAtStart or 0))
                    or (sNow >= 1 and rNow >= (STACK_DURATION - 0.25) and (st.myRemAtStart or 0) < (STACK_DURATION - 0.35))
            end
            if nativeCd > 0.5 or (dur >= CAST_POINT - 0.15 and (manaConfirmed or stackConfirmed)) then
                st.lastCastAt = now
                st.readyAt = now + RAZE_CD - 0.05
                E.lastAnyCastAt = now
            else
                E.lastCancelAt = now
                E.lastCancelLabel = label
            end
        end
        st.inPhase = inPhase
        if inPhase then
            E.phaseLabel = label
            E.phaseStart = st.phaseStart
        end
    end

    -- Track enemy `nevermore_requiem` (`1.67s` self-root cast phase if a human opponent levels Requiem!)
    -- Verified on `auto-20261102-0307-start-ShaNachnetsya.dem` `tk=20556..20608`: in Patch 7.41f (`build 6601`),
    -- `nevermore_requiem` sits in `slot 6` (`m_vecAbilities.0005`, after `nevermore_frenzy`) and emits `m_NetworkActivity == 1515`
    -- (`ACT_DOTA_CAST_ABILITY_6`), NOT legacy `1513`!
    local reqAb = U.GetAbility(enemy, "nevermore_requiem")
    local reqPhase = false
    if reqAb and reqAb:GetLevel() > 0 and reqAb:IsInAbilityPhase() then
        reqPhase = true
    elseif curAb and curAb.GetName and curAb:GetName() == "nevermore_requiem" then
        reqPhase = true
    elseif actAnim == 1515 or actAnim == 1513 then
        reqPhase = true
    end
    if reqPhase and not E.requiemInPhase then
        E.requiemPhaseStart = now
    elseif E.requiemInPhase and not reqPhase then
        if (now - (E.requiemPhaseStart or now)) >= 1.45 then
            E.lastRequiemAt = now
        end
    end
    E.requiemInPhase = reqPhase

    -- Continuously observe self & enemy Mango slot transitions (`6.0s` backpack mute) + enemy courier under Ward #2!
    if U.ObserveUnitMangoes then
        if bot then U.ObserveUnitMangoes(bot) end
        U.ObserveUnitMangoes(enemy)
    end
    if U.GetEnemyIncomingCourierSupply then
        U.GetEnemyIncomingCourierSupply(bot, enemy)
    end

    -- Exact Patch 7.41f (`6.000s` `modifier_nevermore_shadowraze_debuff`) FoW / Initial-Sight Cooldown Deducer
    -- + `75 MP` Enemy Mana-Drop Fallback when cast completed inside brief highground Fog-of-War:
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0
    local curEnMana = enemy:GetMana() or 0
    local distNow = GetUnitToLocationDistance(enemy, bot:GetLocation())
    local freshVisibleStack = (myStacks >= 1 and myRem >= (STACK_DURATION - 0.85))
        and (myStacks > (E.prevMyStacks or 0) or myStacks == 1)
    if freshVisibleStack then
        local hitTime = now - math.max(0.0, STACK_DURATION - myRem)
        if hitTime > (E.lastAnyCastAt or -100) + 0.45 then
            local bLabel = deduceBandByDist(distNow)
            if bLabel then
                local st = E.raze[bLabel]
                st.lastCastAt = hitTime
                st.readyAt = math.max(st.readyAt or 0, hitTime + RAZE_CD - 0.15)
            end
            E.lastAnyCastAt = hitTime
        end
    elseif E.prevEnemyMana and (E.prevEnemyMana - curEnMana) >= 65 and (E.prevEnemyMana - curEnMana) <= 88
        and now > (E.lastAnyCastAt or -100) + 0.45 then
        local bLabel = deduceBandByDist(distNow)
        if bLabel then
            local st = E.raze[bLabel]
            st.lastCastAt = now
            st.readyAt = math.max(st.readyAt or 0, now + RAZE_CD - 0.20)
        end
        E.lastAnyCastAt = now
    end
    E.prevEnemyMana = curEnMana
    E.prevMyStacks = myStacks
    E.prevMyStacksTime = now
end

-- How many seconds until the enemy band is ready (0 = ready now / unknown = ready).
function K.EnemyRazeReadyIn(label)
    local st = K._enemy.raze[label]
    if not st then return 0 end
    local dt = st.readyAt - GameTime()
    if dt < 0 then return 0 end
    return dt
end

function K.EnemyRazeReady(label, horizon)
    return K.EnemyRazeReadyIn(label) <= (horizon or 0)
end

-- Is the enemy in a raze cast phase right now? -> label, elapsed, remaining
function K.EnemyPhase()
    local E = K._enemy
    if not E.phaseLabel then return nil, 0, 0 end
    local elapsed = GameTime() - E.phaseStart
    local remaining = CAST_POINT - elapsed
    if remaining < 0 then remaining = 0 end
    return E.phaseLabel, elapsed, remaining
end

-- Is the enemy in a `1.67s` `nevermore_requiem` cast windup right now? -> inPhase, elapsed, remaining
function K.EnemyRequiemPhase()
    local E = K._enemy
    if not E.requiemInPhase then return false, 0, 0 end
    local elapsed = math.max(0, GameTime() - (E.requiemPhaseStart or GameTime()))
    local remaining = math.max(0, 1.67 - elapsed)
    return true, elapsed, remaining
end

-- Raw instantaneous centre of the enemy raze circle (ignoring mid-cast angular velocity).
function K.EnemyRazeRawCenter(enemy, label)
    local loc = enemy:GetLocation()
    local rad = math.rad(enemy:GetFacing() or 0)
    local d = Center(label)
    return Vector(loc.x + math.cos(rad) * d, loc.y + math.sin(rad) * d, loc.z)
end

-- Predicted completion-tick centre of the enemy raze circle (`v7.9.16-pro` Turn-During-Cast-Point Predictor):
-- In Dota 2, Shadowraze is `NO_TARGET`, so a hero rotating while pressing `Q/W/E` continues turning throughout
-- the `0.55s` cast point (`auto-20261103-1343` `#79` @ `10:30.40`: `140.6 deg -> 38.0 deg` = `312u` center shift!).
-- When `enemy` has active angular velocity (`|yawVel| >= 30 deg/s`) during a raze windup, project yaw to completion tick,
-- clamping at `yawToBot` when rotating toward our hero (matching Dota's turn-controller stop angle).
function K.EnemyRazeCenter(enemy, label)
    local loc = enemy:GetLocation()
    local curYaw = enemy:GetFacing() or 0
    local E = K._enemy
    local st = E and E.raze and E.raze[label] or nil
    local yawVel = E and E.yawVelDegPerSec or 0
    if E and E.phaseLabel == label and math.abs(yawVel) >= 35.0 then
        local elapsed = math.max(0.0, GameTime() - (E.phaseStart or GameTime()))
        local rem = math.max(0.0, math.min(CAST_POINT, CAST_POINT - elapsed))
        local sinceStartYaw = (st and st.phaseStartYaw ~= nil)
            and math.abs(((curYaw - st.phaseStartYaw + 540.0) % 360.0) - 180.0)
            or 0.0
        -- `v7.9.20` (`1610.dem` `#01/#05/#06/#08/#10`): Project from tick 0 when `preTurnTowardBot` is active,
        -- or as soon as `>= 3.0 deg` in-phase rotation (`elapsed >= 0.03s`) occurs toward `myBot` (clamped at `yawToBot`).
        local activeTurnGate = (st and st.preTurnTowardBot and rem > 0.02)
            or (elapsed >= 0.030 and rem > 0.02 and sinceStartYaw >= 3.0)
        if activeTurnGate then
            local predTurn = 0.0
            local myBot = E.selfBot
            if myBot and U.CanQuery(myBot) then
                local bLoc = myBot:GetLocation()
                local yawToBot = math.deg(math.atan2(bLoc.y - loc.y, bLoc.x - loc.x))
                local deltaToBot = ((yawToBot - curYaw + 540.0) % 360.0) - 180.0
                if (deltaToBot * yawVel) > 0 then
                    local maxTurn = math.abs(yawVel) * rem * 0.96
                    local mag = math.min(math.abs(deltaToBot), maxTurn)
                    predTurn = (deltaToBot >= 0) and mag or -mag
                end
            end
            curYaw = curYaw + predTurn
        end
    end
    local rad = math.rad(curYaw)
    local d = Center(label)
    return Vector(loc.x + math.cos(rad) * d, loc.y + math.sin(rad) * d, loc.z)
end

-- Exact Dota 2 7.41f Salve-Break Window (`v7.9.16-pro`):
-- Towers and lane creeps NEVER dispel `modifier_flask_healing` or `modifier_clarity_potion`
-- (verified on `auto-20261103-1343` `05:49.33..06:02.33`: `3` Dire T2 hits `116/118/115` + `5` creep hits = `0` dispels!).
-- Returns: `dtBreak` (seconds until earliest hero/player damage >= 20 can impact `bot`), `nextHeroBlowDmg`, `hasHeroProjInFlight`.
function K.EnemySalveBreakWindow(bot, enemy)
    local minDt = 99.0
    local nextDmg = 0.0
    local hasHeroProj = false
    if not bot then return minDt, nextDmg, hasHeroProj end

    local myTeam = bot:GetTeam()
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, p in pairs(projs) do
                if p and p.caster and U.CanQuery(p.caster) then
                    local c = p.caster
                    local sameTeam = c.GetTeam and c:GetTeam() == myTeam
                    local isTower = c.IsTower and c:IsTower()
                    local isCreep = c.IsCreep and c:IsCreep()
                    local isHero = c.IsHero and c:IsHero()
                    if (not sameTeam) and (not isTower) and (isHero or not isCreep) then
                        local dProj = p.location and GetUnitToLocationDistance(bot, p.location) or 260.0
                        local tHit = math.max(0.03, dProj / 1200.0)
                        hasHeroProj = true
                        if tHit < minDt then
                            minDt = tHit
                            nextDmg = (enemy and U.CanQuery(enemy)) and K.AttackDamageVs(enemy, bot) or 95.0
                        end
                    end
                end
            end
        end
    end

    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        return minDt, nextDmg, hasHeroProj
    end

    local enLoc = enemy:GetLocation()
    local dHero = GetUnitToLocationDistance(bot, enLoc)
    -- `v7.9.18-pro` (`9074513540.dem` `11:08.13->11:09.07` `0.94s` Right-Click Salve-Break Fix):
    -- Dota 2 ranged attack acquisition distance center-to-center is `attackRange + hull_attacker(24) + hull_target(24) = 548u`
    -- (previously `+25u` underestimated range by `23u` and overestimated `dtBreak` at `d=580u` as `1.52s` instead of `0.94s`!).
    local enAtkRange = (enemy:GetAttackRange() or 500) + 48.0
    local enMS = math.max(250.0, enemy:GetCurrentMovementSpeed() or 310.0)
    local myMS = math.max(250.0, bot:GetCurrentMovementSpeed() or 305.0)
    local atkDmg = K.AttackDamageVs(enemy, bot)

    -- 1. Next enemy hero auto-attack impact ETA:
    local tFlight = math.max(0.08, math.min(dHero, enAtkRange) / 1200.0)
    local tAuto
    if dHero <= enAtkRange then
        local actAnim = enemy.GetAnimActivity and enemy:GetAnimActivity() or 0
        local tWindup = (actAnim == 1503) and 0.22 or 0.42
        tAuto = tWindup + tFlight
    else
        local closeSpd = math.max(95.0, enMS - myMS * 0.65)
        tAuto = ((dHero - enAtkRange) / closeSpd) + 0.42 + tFlight
    end
    if tAuto < minDt then
        minDt = tAuto
        nextDmg = atkDmg
    end

    -- 2. Active in-phase enemy Shadowraze ETA:
    local pLabel, _, pRem = K.EnemyPhase()
    if pLabel then
        local c = K.EnemyRazeCenter(enemy, pLabel)
        if GetUnitToLocationDistance(bot, c) <= 320.0 then
            local tPhase = math.max(0.03, pRem)
            local rDmg = K.EnemyRazeDamage(bot, enemy, 1)
            if tPhase < minDt then
                minDt = tPhase
                nextDmg = rDmg
            end
        end
    end

    -- 3. Earliest off-CD / coming-off-CD enemy Shadowraze ETA (if enemy has >= 75 mana budget):
    if K.EnemyManaBudget(enemy, true) >= 75 then
        local rDmg = K.EnemyRazeDamage(bot, enemy, 1)
        for i = 1, 3 do
            local lbl = K.LABELS[i]
            if lbl ~= pLabel then
                local cDist = Center(lbl)
                local bMin = math.max(0.0, cDist - 274.0)
                local bMax = cDist + 274.0
                local rIn = K.EnemyRazeReadyIn(lbl)
                local tWalk = 0.0
                if dHero > bMax then
                    tWalk = (dHero - bMax) / math.max(60.0, enMS - myMS * 0.65)
                elseif dHero < bMin then
                    tWalk = (bMin - dHero) / math.max(85.0, enMS)
                end
                local tRazeHit = math.max(rIn, tWalk) + CAST_POINT
                if tRazeHit < minDt then
                    minDt = tRazeHit
                    nextDmg = rDmg
                end
            end
        end
    end

    return minDt, nextDmg, hasHeroProj
end

function K.EnemyManaBudget(enemy, allowConsumables)
    local mana = enemy:GetMana() or 0
    if allowConsumables then
        mana = mana + U.GetMangoMana(enemy) -- Unlocked active charges (`slots 0..5`)
        local charges = U.GetStickCharges(enemy)
        if charges > 0 then mana = mana + charges * 15 end
    end
    return mana
end

-- Time-gated Raze count budget for `enemy` over `[0, horizonSec]` (`v7.9.14-pro`):
-- Mirrors `MyEffectiveRazeBudgetAt`: includes `6.0s` backpack-swap Mangoes unlocking inside `horizonSec` AND
-- spotted/dead-reckoned enemy courier Mangoes arriving at `ecEta <= horizonSec - 0.50` (capped by remaining `0.55s` cast slots!).
function K.EnemyEffectiveRazeBudgetAt(enemy, allowConsumables, horizonSec, bot)
    local h = horizonSec or 0.3
    local baseMana = K.EnemyManaBudget(enemy, allowConsumables)
    if h >= 1.0 then
        local regen = (enemy.GetManaRegen and math.max(0, enemy:GetManaRegen() or 0)) or 1.2
        baseMana = baseMana + regen * math.min(2.8, h)
    end
    if allowConsumables and h > 0.45 and U.GetUnlockingMangoMana then
        baseMana = baseMana + (U.GetUnlockingMangoMana(enemy, h) or 0)
    end
    local preRazes = math.floor(math.max(0, baseMana) / RAZE_MANA)
    if allowConsumables and h > 0.55 and U.GetEnemyIncomingCourierMana then
        local refBot = bot or (K._enemy and K._enemy.selfBot) or nil
        local ecMana, ecEta = U.GetEnemyIncomingCourierMana(refBot, enemy, h - 0.50)
        if (ecMana or 0) > 0 and (ecEta or 999) <= (h - 0.50) then
            local postSlots = math.max(1, math.floor((h - ecEta + 0.15) / CAST_POINT))
            local totalRazes = math.floor((baseMana + ecMana) / RAZE_MANA)
            return math.min(totalRazes, preRazes + postSlots)
        end
    end
    return preRazes
end

-- How many enemy razes become ready within horizon seconds (limited by mana).
-- Returns count, countIgnoringMana.
function K.EnemyReadyRazeCount(enemy, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    if not U.EnemyHasRaze(enemy) then return 0, 0 end
    local n = 0
    for i = 1, 3 do
        if K.EnemyRazeReadyIn(K.LABELS[i]) <= (horizon or 0) then n = n + 1 end
    end
    local budget = K.EnemyEffectiveRazeBudgetAt(enemy, allowConsumables, horizon or 0)
    if budget < n then return budget, n end
    return n, n
end

-- Exact mana-and-cooldown-gated enemy Raze count & damage (`9069188041.dem` `03:38.8-03:49.5` Death #2 Fix):
-- Never attribute phantom Raze burst to a manaless (`< 75 MP`) enemy who owns no Mango/Stick charges!
function K.EnemyCastableRazeCount(enemy, horizon)
    if not U.CanQuery(enemy) then return 0 end
    if not U.EnemyHasRaze(enemy) then return 0 end
    local h = horizon or 2.2
    local ready = 0
    for i = 1, 3 do
        if K.EnemyRazeReadyIn(K.LABELS[i]) <= h then ready = ready + 1 end
    end
    local manaBands = K.EnemyEffectiveRazeBudgetAt(enemy, true, h)
    local ph = K.EnemyPhase()
    if ph and manaBands < 1 then manaBands = 1 end
    if manaBands < ready then return manaBands end
    return ready
end

function K.EnemyCastableRazeDamage(bot, enemy, maxN, stacksOverride, horizon)
    if (maxN or 0) <= 0 or not U.CanQuery(enemy) then return 0 end
    local cap = K.EnemyCastableRazeCount(enemy, horizon)
    local effN = math.min(maxN, cap)
    if effN <= 0 then return 0 end
    return K.EnemyRazeDamage(bot, enemy, effN, stacksOverride)
end

-- Can an enemy band reach me from distance dist within horizon seconds.
-- Two-sided relative kinematics (`v3.9.0` outer + `v5.2.0` inner `minReach` fix):
--   1. Outer bound: unpinned enemy closes at `(enMS - myMS) * horizon`, never full `enMS * horizon`.
--   2. Inner bound: `Raze3 (700u)` has inner edge `450u` (`425u` w/ hull); at `d = 180u` over short horizon,
--      the enemy cannot hit `Raze3` without walking out to `425u` first!
local function BandCanReach(bot, enemy, label, dist, horizon, pinned)
    local c = Center(label)
    local reach = c + HIT_RADIUS + 25
    local minReach = math.max(0, c - HIT_RADIUS - 25)
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    if dist < minReach then
        local stepOutAllow = pinned
            and (enMS * math.min(horizon or 0, 0.75) + 45)
            or (math.max(40, enMS - myMS * 0.45) * math.min(horizon or 0, 1.35) + 55)
        if dist + stepOutAllow < minReach then
            return false
        end
    end
    if dist <= reach then return true end
    local closeAllowance
    if pinned then
        closeAllowance = enMS * math.min(horizon or 0, 0.65) + 60
    else
        closeAllowance = math.max(0, enMS - myMS) * (horizon or 0) + 95
    end
    return dist <= reach + closeAllowance
end

-- The enemy burst on me from distance dist over horizon (accounting for band readiness, mana,
-- band reach and his right-click damage if he is already in attack range).
-- Returns damage, razeCount (enforcing sequential 0.55s CAST_POINT & interwoven auto-attack time budget).
function K.EnemyBurstVs(bot, enemy, dist, horizon, pinned, stacksOverride)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local maxSequential = math.max(1, math.min(3, math.floor((horizon + 0.30) / CAST_POINT)))
    local n = 0
    local nearReached, farReached = false, false
    if U.EnemyHasRaze(enemy) then
        for i = 1, 3 do
            local label = K.LABELS[i]
            if K.EnemyRazeReadyIn(label) <= horizon and BandCanReach(bot, enemy, label, dist, horizon, pinned) then
                n = n + 1
                if label == "near" then nearReached = true end
                if label == "far" then farReached = true end
            end
        end
        -- Un-pinned SF geometry (`700u - 200u = 500u` center separation!): at `dist >= 445u` without an enemy Boots
        -- speed lead or `> 2.8s` horizon, an un-pinned target cannot simultaneously eat BOTH `near (200u)` AND `far (700u)`!
        local myMSNow = bot:GetCurrentMovementSpeed() or 305
        local enMSNow = enemy:GetCurrentMovementSpeed() or 305
        if nearReached and farReached and not pinned and dist >= 445 and enMSNow < myMSNow + 22 and horizon <= 2.8 then
            n = math.max(1, n - 1)
        end
        local budget = K.EnemyEffectiveRazeBudgetAt(enemy, true, horizon, bot)
        if budget < n then n = budget end
        if n > maxSequential then n = maxSequential end
    end
    local dmg = K.EnemyRazeDamage(bot, enemy, n, stacksOverride)
    local freeAutoHorizon = math.max(0.0, horizon - n * 0.45)
    local atkRange = (enemy:GetAttackRange() or 525) + 80
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local msLead = math.max(0, enMS - myMS)
    if dist <= atkRange and (freeAutoHorizon >= 0.22 or n == 0) then
        local atk = K.AttackDamageVs(enemy, bot)
        local spa = enemy:GetSecondsPerAttack() or 1.6
        local effH = (n == 0) and horizon or freeAutoHorizon
        local hits = math.floor(effH / math.max(0.6, spa)) + (msLead >= 25 and 1 or 0)
        if hits < 1 then hits = 1 end
        if hits > 3 then hits = 3 end
        dmg = dmg + atk * hits
    elseif msLead >= 25 and dist <= atkRange + msLead * horizon * 0.90 + 60 and freeAutoHorizon >= 0.35 then
        local atk = K.AttackDamageVs(enemy, bot)
        dmg = dmg + atk * (horizon >= 2.0 and 2 or 1)
    end
    return dmg, n
end

-- My burst on the enemy from distance dist over horizon (enforcing sequential 0.55s CAST_POINT per Raze!).
function K.MyBurstVs(bot, enemy, dist, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local maxSequential = math.max(1, math.min(3, math.floor((horizon + 0.30) / CAST_POINT)))
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local closeAllowance = math.max(0, myMS - enMS) * (horizon or 0) + (horizon <= 0.45 and 25 or 95)
    local n = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.MyRazeReady(bot, label) then
            local c = Center(label)
            local reach = c + HIT_RADIUS + 20
            local rawMin = math.max(0, c - HIT_RADIUS - 20)
            local stepBackAllow = (horizon <= 0.45) and 15 or (myMS * math.min(horizon, 0.80) * 0.45 + 45)
            local minReach = math.max(0, rawMin - stepBackAllow)
            if dist <= reach + closeAllowance and dist >= minReach then
                n = n + 1
            end
        end
    end
    local budget = K.MyEffectiveRazeBudgetAt(bot, allowConsumables, horizon)
    if budget < n then n = budget end
    if n > maxSequential then n = maxSequential end
    local dmg = K.MyRazeDamage(bot, enemy, n)
    local freeAutoHorizon = math.max(0.0, horizon - n * 0.45)
    local atkRange = (bot:GetAttackRange() or 525) + (horizon <= 0.45 and 20 or 80)
    if dist <= atkRange and (freeAutoHorizon >= 0.22 or n == 0) then
        local atk = K.AttackDamageVs(bot, enemy)
        local spa = bot:GetSecondsPerAttack() or 1.6
        local effH = (n == 0) and horizon or freeAutoHorizon
        local hits = math.floor(effH / math.max(0.6, spa))
        if hits < 1 then hits = 1 end
        if hits > 3 then hits = 3 end
        dmg = dmg + atk * hits
    elseif horizon >= 2.0 and n >= 1 and dist <= math.max(525, bot:GetAttackRange() or 525) + 185 and freeAutoHorizon >= 0.45 then
        -- `9070869385.dem` `05:05.4–05:09.8` `R3+step-in+R2+auto` Initiation Fix:
        -- Over a `>= 2.0s` horizon from `<= 710u`, stepping `110u` forward between `R3 (700u)` and `R2 (450u)`
        -- weaves `1` closing right-click (`0.85x` conservative weight) instead of missing `440 HP` lethal by `8 HP`!
        dmg = dmg + K.AttackDamageVs(bot, enemy) * 0.85
    end
    return dmg, n
end

-- "Hunt": my burst on the enemy over horizon seconds assuming I REACH the mid band
-- (all three reach from there): razes that come off cooldown within the horizon (cd <= horizon - 0.6),
-- limited by mana WITH mango; plus 1-2 right clicks. The "go finish him" decision with a large
-- HP edge when the ordinary race (razes from the current distance only) sees no kill.
function K.MyHuntBurst(bot, enemy, horizon)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 4.0
    local n = 0
    for i = 1, 3 do
        local ab = U.GetAbility(bot, K.RAZE_NAMES[K.LABELS[i]])
        if ab and ab:GetLevel() > 0 then
            local cd = 0
            if ab.GetCooldownTimeRemaining then
                local ok, v = pcall(ab.GetCooldownTimeRemaining, ab)
                if ok and type(v) == "number" then cd = v end
            elseif not ab:IsCooldownReady() then
                cd = 999
            end
            if cd <= horizon - 0.6 then n = n + 1 end
        end
    end
    local budget = math.floor(K.MySustainedManaBudget(bot, horizon) / RAZE_MANA)
    if budget < n then n = budget end
    local dmg = K.MyRazeDamage(bot, enemy, n)
    local spa = bot:GetSecondsPerAttack() or 1.6
    if spa <= 0 then spa = 1.6 end
    local hits = math.floor((horizon - 1.5) / math.max(0.6, spa))
    if hits < 1 then hits = 1 end
    if hits > 2 then hits = 2 end
    return dmg + K.AttackDamageVs(bot, enemy) * hits, n
end

-- Minimum safe distance to the enemy: outside all his bands that are ready within horizon.
-- 0 = no band is ready (or no mana) -> we can stand anywhere.
function K.EnemyMinSafeDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + HIT_RADIUS + 45
            if r > best then best = r end
        end
    end
    return best
end

-- "Hedge" distance: stand at the outer edge of his furthest READY band
-- (centre + 200 of the 250 radius): the cast animation (0.55 s) gives us time to leave the circle.
-- This is the compromise for a "zoned" SF: do not give up the whole wave but do not stand in the band centre.
function K.EnemyDodgeableDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + 200
            if r > best then best = r end
        end
    end
    return best
end

-- The enemy band that is ready within horizon and that I am standing in (or nil).
function K.EnemyReadyBandAt(enemy, dist, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return nil end
    if K.EnemyManaBudget(enemy, true) < RAZE_MANA then return nil end
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            if math.abs(dist - Center(label)) <= HIT_RADIUS + 30 then return label end
        end
    end
    return nil
end

-- How many razes a unit can pay for right now (mana + consumables, 75 per raze).
function K.MyRazeBudget(bot, allowConsumables)
    return math.floor((K.MyManaBudget(bot, allowConsumables) or 0) / RAZE_MANA)
end

function K.EnemyRazeBudget(enemy, allowConsumables)
    if not U.CanQuery(enemy) then return 0 end
    return math.floor((K.EnemyManaBudget(enemy, allowConsumables) or 0) / RAZE_MANA)
end

-- Is it safe for me to stand/cast in band label.
function K.BandSafeFromEnemy(enemy, label, marginSec)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return true end
    local eRazeLvl = (U.InferRazeLevel and U.InferRazeLevel(enemy)) or 0
    if eRazeLvl <= 0 then return true end
    if K.EnemyManaBudget(enemy, true) < RAZE_MANA then return true end
    return K.EnemyRazeReadyIn(label) > (marginSec or 0.0)
end

-- Preserve the confirmed 2:1 lead; waive ONLY when SF holds a clean, healthy, flat-ground lethal finish (`myHp >= 520`, `mana >= 75`).
function K.HasRazeStackLead(bot, enemy)
    if not U.CanQuery(enemy) or not (enemy.IsHero and enemy:IsHero()) then return false end
    local mine, myRemain = U.GetShadowrazeDebuff(bot)
    local theirs, theirRemain = U.GetShadowrazeDebuff(enemy)
    if not (mine == 1 and theirs >= 2 and myRemain > 0.35 and theirRemain > 0.35) then
        return false
    end
    local R = K._race
    if R and R.valid and not R.heCanKillSoon and not R.uphillPenalty
        and (bot:GetHealth() or 0) >= 520 and (bot:GetMana() or 0) >= 75 then
        local enEff = R.enEffHpNow or enemy:GetHealth() or 9999
        local razeKill = U.GetNRazeDamage(bot, enemy, 1) + (bot:GetAttackDamage() or 60) * 1.35
        if enEff <= razeKill then
            return false
        end
    end
    return true
end

-- Count every overlapping, learned, ready band, not just the nearest centre.
function K.EnemyBandsAcross(enemy, low, high, horizon)
    if not U.CanQuery(enemy) then return 0 end
    horizon = horizon or 0.7
    local eRazeLvl = (U.InferRazeLevel and U.InferRazeLevel(enemy)) or 0
    if eRazeLvl <= 0 then return 0, 0 end
    local mana = K.EnemyManaBudget(enemy, true)
        + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * horizon
    local n, outer = 0, 0
    for _, label in ipairs(K.LABELS) do
        if K.EnemyRazeReadyIn(label) <= horizon
            and high >= Center(label) - HIT_RADIUS - 30
            and low <= Center(label) + HIT_RADIUS + 30 then
            n = n + 1
            outer = math.max(outer, Center(label) + HIT_RADIUS + 30)
        end
    end
    return math.min(n, math.floor(mana / RAZE_MANA)), mana >= RAZE_MANA and outer or 0
end

function K.StackLeadStepSafe(bot, enemy, point)
    if not K.HasRazeStackLead(bot, enemy) then return true end
    local here, e = bot:GetLocation(), enemy:GetLocation()
    local step = point - here
    local length2 = step.x * step.x + step.y * step.y
    local t = 0
    if length2 > 1 then
        t = math.max(0, math.min(1, ((e.x-here.x)*step.x + (e.y-here.y)*step.y) / length2))
    end
    local nearest = U.DistanceBetweenLocations(here + step * t, e)
    local before, after = U.DistanceBetweenLocations(here, e), U.DistanceBetweenLocations(point, e)
    if after >= before and nearest >= before - 5 then return true end -- Always permit outward escape.
    local horizon = math.min(1.5, math.sqrt(length2) / math.max(1, bot:GetCurrentMovementSpeed()) + 0.7)
    return K.EnemyBandsAcross(enemy, nearest, math.max(before, after), horizon) == 0
end

-- A short mid/far raze exchange is not a sustained right-click duel. Reuse
-- the existing damage and mana model, but bound the exchange by cast/move time.
-- Returns safe opportunity, ready own razes, enemy razes, our damage, incoming.
function K.SpellTradeWindow(bot, enemy, snapshot)
    if not U.CanQuery(enemy) then return false, 0, 0, 0, 0 end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist < 350 or dist > 1050 then return false, 0, 0, 0, 0 end
    local ready, desired = 0, C.RAZE.FAR_CENTER
    for _, label in ipairs({"far", "mid"}) do
        if K.MyRazeReady(bot, label) then
            ready = ready + 1
            desired = math.min(desired, Center(label))
        end
    end
    -- Only mana already usable without spending this tick on an item.
    local count = math.min(ready, math.floor(bot:GetMana() / RAZE_MANA))
    if count < 1 then return false, count, 0, 0, 0 end
    if count == 1 and K.MyRazeReady(bot, "far") then desired = C.RAZE.FAR_CENTER end
    local ms = math.max(1, bot:GetCurrentMovementSpeed() or 305)
    local reach = desired + HIT_RADIUS - 40
    if count >= 2 then desired = C.RAZE.MID_CENTER + 150; reach = desired end
    local approach = math.max(0, dist - reach) / ms
    local horizon = count * CAST_POINT + approach + 0.40
    if horizon > 3.0 or not K.CanCatch(bot, enemy, reach, horizon) then
        return false, count, 0, 0, 0
    end
    local enemyMana = K.EnemyManaBudget(enemy, true)
        + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * horizon
    local enemyReady = 0
    if U.EnemyHasRaze(enemy) and ((U.InferRazeLevel and U.InferRazeLevel(enemy) or 0) > 0) then
        for _, label in ipairs(K.LABELS) do
            if K.EnemyRazeReadyIn(label) <= horizon then enemyReady = enemyReady + 1 end
        end
    end
    local enemyCount = math.min(enemyReady, math.floor(enemyMana / RAZE_MANA))
    local equalCountQualityEdge = (count >= 1) and (count == enemyCount)
    if count < enemyCount or count <= 0 then return false, count, enemyCount, 0, 0 end
    local goal = enemy:GetLocation() + (bot:GetLocation() - enemy:GetLocation()):Normalized() * desired
    for _, tower in pairs((snapshot and snapshot.enemyTowers) or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 800
            or U.DistanceBetweenLocations(goal, tower:GetLocation()) < 800) then
            return false, count, enemyCount, 0, 0
        end
    end
    local incoming = K.EnemyRazeDamage(bot, enemy, enemyCount)
    local enemyRange = enemy:GetAttackRange() or 525
    -- No mana is NOT no danger: include right clicks if he can reach during casts.
    if math.min(dist, desired) <= enemyRange + (enemy:GetCurrentMovementSpeed() or 305) * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot)
            * math.ceil(horizon / math.max(0.6, enemy:GetSecondsPerAttack() or 1.6))
    end
    for _, creep in pairs((snapshot and snapshot.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot)
                * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack() or 1.0))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack then
                return false, count, enemyCount, 0, incoming
            end
            if U.CanQuery(projectile.caster) then
                incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
            else
                incoming = incoming + 65
            end
        end
    end
    local damage = K.MyRazeDamage(bot, enemy, count)
    local reserve = equalCountQualityEdge
        and math.max(195, K.AttackDamageVs(enemy, bot) * 2.2)
        or math.max(60, K.AttackDamageVs(enemy, bot) * 0.75)
    local myStacks = U.GetShadowrazeDebuff(bot)
    local spentRanged = count >= 2 and myStacks == 0
        and K.EnemyRazeReadyIn("mid") > horizon + 0.2 and K.EnemyRazeReadyIn("far") > horizon + 0.2
    local minNetEdge = equalCountQualityEdge
        and math.max(75, incoming * 0.28)
        or (spentRanged and 0 or 35)
    local favourable = bot:GetHealth() - incoming >= reserve
        and damage >= incoming + minNetEdge
    return favourable, count, enemyCount, damage, incoming, favourable and spentRanged
end

-- Unified Physical/Stat Dominance Predicate (`9070869385.dem` `03:00.53–03:08.53` Post-Kill Anti-Fear Fix):
-- Returns `true` when our SF decisively out-stats the enemy hero in physical DPS + HP (`L4 19S 2xBracer 69 dmg`
-- vs `L3 7S 1xBracer 45 dmg`) and cannot be bursted inside `1.4s`, so `< 75 MP` never triggers panic retreats into `R3`!
function K.HasDominantRightClickPosture(bot, enemy, s)
    if not bot or not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemy, s) then return false end
    local myLvl = bot:GetLevel() or 1
    local enLvl = enemy:GetLevel() or 1
    if enLvl > myLvl then return false end
    if U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy) then return false end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    if enMS >= myMS + 25 then return false end
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    if myAtk < enAtk + 12 then return false end
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 9999
    if myHp < math.max(460, enHp * 0.78) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local burst14 = K.EnemyBurstVs(bot, enemy, dist, 1.4, false)
    if myHp <= burst14 + enAtk * 1.5 + 85 then return false end
    local aggroCreeps = 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == bot then
            aggroCreeps = aggroCreeps + 1
        end
    end
    if aggroCreeps >= 2 then return false end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    if bLoc.z and eLoc.z and (eLoc.z - bLoc.z) > 64 then return false end
    return true
end

-- Finite cast schedule for one short reply, including regeneration and already flying attacks.
function K.ShortReplyIncoming(bot,enemy,horizon,s)
    local dist=GetUnitToLocationDistance(bot,enemy:GetLocation())
    local budget=K.EnemyEffectiveRazeBudgetAt(enemy,true,horizon,bot)
    local phase,_,remaining=K.EnemyPhase()
    local times={}
    local eRazeLvl = (U.InferRazeLevel and U.InferRazeLevel(enemy)) or 0
    for _,label in ipairs(K.LABELS) do
        local ab=U.GetAbility(enemy, K.RAZE_NAMES[label])
        if (ab and ab:GetLevel()>0) or eRazeLvl>0 then
            local gap=math.max(0,dist-Center(label)-HIT_RADIUS,Center(label)-HIT_RADIUS-dist)
            local t=math.max(K.EnemyRazeReadyIn(label),gap/math.max(1,enemy:GetCurrentMovementSpeed()))+CAST_POINT
            if phase==label then t=math.max(0,remaining or CAST_POINT);budget=budget+1 end
            times[#times+1]=t
        end
    end
    table.sort(times)
    local n,last=0,-CAST_POINT
    for _,t in ipairs(times) do
        local finish=math.max(t,last+CAST_POINT)
        if finish<=horizon and n<budget then n=n+1;last=finish end
    end
    local damage=K.EnemyRazeDamage(bot,enemy,n)
    -- `v7.9.13-pro` (`0210 @ 16:40..16:48` Requiem Threat Model, C++ Non-Teammate-Safe!):
    -- NEVER call `GetCooldownTimeRemaining()` on a non-teammate ability (`[Developer]` C++ warning); track via `enTrack.lastRequiemAt`!
    local reqAbEn = enemy.GetAbilityByName and U.GetAbility(enemy, "nevermore_requiem") or nil
    local enTrack = K._enemy
    local reqOffCd = not (enTrack and enTrack.lastRequiemAt and (GameTime() - enTrack.lastRequiemAt) < 105)
    local enHasReq = reqOffCd and ((reqAbEn and reqAbEn:GetLevel() > 0)
        or (not reqAbEn and (enemy.GetLevel and enemy:GetLevel() or 1) >= 9))
    local reqInPhase, _, reqRem = false, 0, 0
    if K.EnemyRequiemPhase then
        reqInPhase, _, reqRem = K.EnemyRequiemPhase()
    end
    if (reqInPhase and horizon >= math.max(0.10, reqRem) and dist <= 620)
        or (enHasReq and horizon >= 1.75 and dist <= 435 and (K.EnemyEffectiveRazeBudgetAt(enemy, true, horizon, bot) >= 2)) then
        local closeScale = math.max(0.28, 1.0 - math.max(0, dist - 140) / 520.0)
        local estSouls = math.max(10, U.GetEnemySouls and U.GetEnemySouls(enemy) or 14)
        local reqRaw = math.min(1150, estSouls * 80 * closeScale)
        local reqMagic = bot.GetActualIncomingDamage and bot:GetActualIncomingDamage(reqRaw, DAMAGE_TYPE_MAGICAL) or (reqRaw * 0.75)
        damage = damage + reqMagic
    end
    local bLoc, eLoc = bot:GetLocation(), enemy:GetLocation()
    local enHitFactor = (bLoc and eLoc and (bLoc.z or 0) - (eLoc.z or 0) >= 90) and 0.75 or 1.0
    if dist<=enemy:GetAttackRange()+enemy:GetCurrentMovementSpeed()*horizon then
        damage=damage+K.AttackDamageVs(enemy,bot)*enHitFactor*math.ceil(horizon/math.max(0.6,enemy:GetSecondsPerAttack()))
    end
    for _,creep in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:IsAlive() then
            local cTargeting = (creep:GetAttackTarget()==bot)
            local cNearAggro = (not cTargeting) and (dist<=enemy:GetAttackRange()+120)
                and (GetUnitToLocationDistance(bot, creep:GetLocation()) <= 500)
            if cTargeting then
                damage=damage+K.AttackDamageVs(creep,bot)*math.ceil(horizon/math.max(0.6,creep:GetSecondsPerAttack()))
            elseif cNearAggro then
                damage=damage+K.AttackDamageVs(creep,bot)*math.max(1, math.floor(horizon/math.max(0.75,creep:GetSecondsPerAttack())))
            end
        end
    end
    for _,pr in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
        if not pr.is_attack then return math.huge end
        if U.CanQuery(pr.caster) then
            damage=damage+K.AttackDamageVs(pr.caster,bot)
        else
            damage=damage+65
        end
    end
    return damage
end

function K.ManaCycleWindow(bot,enemy,s)
    if not U.CanQuery(enemy) or bot:GetMana()<150 or bot:IsSilenced() or bot:IsHexed()
        or (bot.IsDisarmed and bot:IsDisarmed()) then return false end
    local times={}
    local distance=GetUnitToLocationDistance(bot,enemy:GetLocation())
    for _,label in ipairs(K.LABELS) do
        local ab=U.GetAbility(bot, K.RAZE_NAMES[label])
        if ab and ab:GetLevel()>0 then
            local cd=ab:GetCooldownTimeRemaining()
            if cd<=9 and math.abs(distance-Center(label))<=HIT_RADIUS-(C.RAZE.ROBUST_MARGIN or 30) then
                times[#times+1]=math.max(0,cd)
            end
        end
    end
    table.sort(times)
    local n=math.min(#times,math.floor(bot:GetMana()/RAZE_MANA))
    if n<2 then return false end
    local horizon=0
    for i=1,n do horizon=math.max(horizon,times[i])+CAST_POINT end
    horizon=horizon+0.35
    if horizon>10.5 or K.EnemyManaBudget(enemy,true)+math.max(0,enemy:GetManaRegen() or 0)*horizon>=75 then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(100,K.AttackDamageVs(enemy,bot)*1.25) then return false end
    local hits=math.max(0,math.floor((horizon-n*CAST_POINT)/math.max(0.6,bot:GetSecondsPerAttack())))
    -- Do not assume old stacks survive until the reloaded spells.
    local damage=n*K.MyRazeDamage(bot,enemy,1,-(U.GetShadowrazeDebuff(enemy) or 0))+K.AttackDamageVs(bot,enemy)*hits
    local enemyHP=enemy:GetHealth()+math.max(0,enemy:GetHealthRegen() or 0)*horizon+U.GetStickCharges(enemy)*15
    if U.HasItem(enemy,"item_faerie_fire") then enemyHP=enemyHP+85 end
    return bot:GetHealth()-incoming-(enemyHP-damage)>=60
end

-- A read-only recovery estimate for the shop. Do not call Race here: the shop
-- must not overwrite the live combat snapshot or reset the enemy cast tracker.
function K.NeedsRecoverySupport(bot, enemy)
    if not U.CanQuery(enemy) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist > 1600 then return false end
    local mine = K.MyBurstVs(bot, enemy, math.min(dist, 600), 2.5, true)
    local theirs = K.EnemyBurstVs(bot, enemy, math.min(dist, 600), 2.5, false)
    local deficit = (enemy:GetHealth() - mine) - (bot:GetHealth() - theirs)
    return deficit >= 220 and (theirs >= mine + 80 or enemy:GetHealth() >= bot:GetHealth() + 250)
end

-- The race: absolute HP, who kills whom.

K._race = {
    valid = false,
    dist = 0,
    myHp = 0, enHp = 0,
    myBurstNow = 0, myBurstSoon = 0, myRazesSoon = 0,
    enBurstNow = 0, enBurstSoon = 0, enRazesSoon = 0,
    canKillNow = false, canKillSoon = false,
    heCanKillNow = false, heCanKillSoon = false,
    edge = 0, -- (my HP after his burst) - (his HP after my burst)
    hpDiff = 0, -- my HP - his HP (absolute)
    minSafeDist = 0, -- the distance beyond which his ready bands cannot reach me
    enemyFaster = false,
    enemyBandHere = nil, -- the enemy's ready band that I am standing in
}

-- Tower damage on a hero over horizon seconds (if the hero is in its radius). T1: ~90 damage, BAT 0.9.
local function TowerDamageOn(tower, hero, horizon)
    if not tower or not U.CanQuery(hero) then return 0 end
    local okAlive, alive = pcall(tower.IsAlive, tower)
    if not okAlive or not alive then return 0 end
    local okLoc, tLoc = pcall(tower.GetLocation, tower)
    if not okLoc or not tLoc then return 0 end
    local aggroRad = (C.TOWER and C.TOWER.AGGRO_RADIUS) or 868
    local lockedOnHero = tower.GetAttackTarget and tower:GetAttackTarget() == hero
    local maxReach = lockedOnHero and (aggroRad + 25) or 755
    if GetUnitToLocationDistance(hero, tLoc) > maxReach then return 0 end
    local raw = 90
    local okD, d = pcall(tower.GetAttackDamage, tower)
    if okD and type(d) == "number" and d > 0 then raw = d end
    local per = (U.CalcExactIntDamage and U.CalcExactIntDamage(tower, hero, raw))
        or ((hero:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL) or 0) * 0.75)
    return per * math.max(lockedOnHero and 1 or 0, math.floor(horizon / 0.9))
end

-- s (optional) = the world snapshot W.s: towers + nearby creeps so creep aggro, symmetric burst heals
-- (Faerie Fire +85, Stick/Wand +15*charges, regen) and Source 2 25% uphill miss factor count in Race.
function K.Race(bot, enemy, pinned, s)
    local R = K._race
    R.valid = false
    R.enemy = nil
    R.snapshot = s
    if not bot or not U.CanQuery(enemy) then return R end
    R.enemy = enemy
    local bLoc, eLoc = bot:GetLocation(), enemy:GetLocation()
    local dist = GetUnitToLocationDistance(bot, eLoc)
    local myHp = bot:GetHealth() or 0
    local myInstantHeal = ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(bot))
        or (U.GetActiveItemByName(bot, "item_faerie_fire") and 85 or 0))
        + (U.GetStickCharges(bot, false) * 15)
    local myCourSup = U.GetIncomingCourierSupply and U.GetIncomingCourierSupply(bot) or nil
    local myCourFaerieSoon = (myCourSup and (myCourSup.faerieHeal or 0) > 0 and (myCourSup.etaSec or 999) <= 1.85)
        and myCourSup.faerieHeal or 0
    local myEffHp = myHp + myInstantHeal
    local myEffHpSoon = myEffHp + myCourFaerieSoon
    local enHp = enemy:GetHealth() or 0
    local enHpNowBase  = (U.GetEnemyEffectiveCombatHp and U.GetEnemyEffectiveCombatHp(enemy, 1.25)) or enHp
    local enHpSoonBase = (U.GetEnemyEffectiveCombatHp and U.GetEnemyEffectiveCombatHp(enemy, 2.85)) or enHp
    local enHpLongBase = (U.GetEnemyEffectiveCombatHp and U.GetEnemyEffectiveCombatHp(enemy, 6.0)) or enHp

    -- Enemy instant burst survival items (active Faerie Fire +85 HP, active Stick/Wand +15 HP per charge) + incoming courier Faerie + regen
    local enInstantHeal = (U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy) or (U.HasItem(enemy, "item_faerie_fire") and 85 or 0))
        + (U.GetStickCharges(enemy, false) * 15)
    local enCourSup = U.GetEnemyIncomingCourierSupply and U.GetEnemyIncomingCourierSupply(bot, enemy) or nil
    local enCourFaerieSoon = (enCourSup and (enCourSup.faerieHeal or 0) > 0 and (enCourSup.etaSec or 999) <= 1.85)
        and enCourSup.faerieHeal or 0
    local enRegen25 = math.max(0, (enemy.GetHealthRegen and enemy:GetHealthRegen() or 0)) * 2.5
    local enEffHpNow = math.max(enHp, enHpNowBase) + enInstantHeal
    local enEffHpSoon = math.max(enHp, enHpSoonBase) + enInstantHeal + enCourFaerieSoon + enRegen25
    local enEffHpLong = math.max(enEffHpSoon, enHpLongBase + enInstantHeal + enCourFaerieSoon + enRegen25)

    -- Source 2 25% uphill miss factor (0.75x projectile hit expectation when attacking >= 90u uphill)
    local myHitFactor = (bLoc and eLoc and (eLoc.z or 0) - (bLoc.z or 0) >= 90) and 0.75 or 1.0
    local enHitFactor = (bLoc and eLoc and (bLoc.z or 0) - (eLoc.z or 0) >= 90) and 0.75 or 1.0

    local myNow = K.MyBurstVs(bot, enemy, dist, 0.3, true)
    local mySoon, myRazesSoon = K.MyBurstVs(bot, enemy, dist, 2.5, true)
    local enNow = K.EnemyBurstVs(bot, enemy, dist, 0.3, pinned)
    local enSoon, enRazesSoon = K.EnemyBurstVs(bot, enemy, dist, 2.5, pinned)

    -- Apply uphill miss expectation to physical attack portion of 2.5s burst
    if myHitFactor < 1.0 then
        local myRazePart = K.MyRazeDamage(bot, enemy, myRazesSoon or 0)
        mySoon = myRazePart + math.max(0, mySoon - myRazePart) * myHitFactor
    end

    -- Prolonged right-click hero-only kinematics (used to cap realistic engagement duration `tBrawl <= 3.4s`):
    local myAtk = K.AttackDamageVs(bot, enemy) * myHitFactor
    local enAtk = K.AttackDamageVs(enemy, bot) * enHitFactor
    local mySpa = bot:GetSecondsPerAttack() or 1.6
    local enSpa = enemy:GetSecondsPerAttack() or 1.6
    if mySpa <= 0 then mySpa = 1.6 end
    if enSpa <= 0 then enSpa = 1.6 end
    local myHeroDps = myAtk / mySpa
    local enHeroDps = enAtk / enSpa
    local heroTtkMe = (enHeroDps > 0) and (myEffHpSoon / enHeroDps) or 999
    local heroTtkHim = (myHeroDps > 0) and (enEffHpSoon / myHeroDps) or 999
    local tBrawl = math.max(1.4, math.min(3.4, heroTtkMe, heroTtkHim))

    -- Towers & Intent-Separated Source 2 Creep Physics (`v7.9.14-pro` Zero-Cowardice Architecture):
    --   * `enSoon` / `heCanKillSoon` (`PASSIVE` / `SPELL_ONLY`): adds ONLY creeps ALREADY targeting `bot` (`0` hypothetical 500u aggro!)
    --     so SF NEVER gets scared away from casting coils, poking, or finishing kills near un-aggroed enemy creeps!
    --   * `brawlCreepDmgMe` / `brawlCreepDmgHim` (`BRAWL`): integrates walk-in lag + 500u aggro + dying tank creep strictly
    --     over actual engagement duration `tBrawl <= 3.4s` (NOT fixed 6.0s!) for voluntary sustained right-click trades!
    local nowT = GameTime()
    local myAggroOffCd = nowT >= (((U._State and U._State.myCreepAggroCdUntil) or 0) - 0.15)
    R.myTowerOnHim = 0
    R.hisTowerOnMe = 0
    local passiveCreepDmgMe = 0
    local passiveCreepDmgHim = 0
    local myBrawlCreepDmg = 0
    local hisBrawlCreepDmg = 0
    if s then
        R.myTowerOnHim = TowerDamageOn(s.allyT1, enemy, 2.5)
        R.hisTowerOnMe = TowerDamageOn(s.enemyT1, bot, 2.5)
        local aggroRad = (C.TOWER and C.TOWER.AGGRO_RADIUS) or 868
        if R.hisTowerOnMe == 0 and s.enemyT1Alive ~= false and s.enemyT1Loc
            and U.DistanceBetweenLocations(bLoc, s.enemyT1Loc) <= aggroRad and #(s.allyCreeps or {}) == 0 then
            R.hisTowerOnMe = bot:GetActualIncomingDamage(90, DAMAGE_TYPE_PHYSICAL) * 2
        end
        mySoon = mySoon + R.myTowerOnHim
        enSoon = enSoon + R.hisTowerOnMe

        passiveCreepDmgMe  = U.ComputeIntentCreepBrawlDamage(bot, enemy, s.enemyCreeps, s.allyCreeps, 1.55, "PASSIVE", false)
        passiveCreepDmgHim = U.ComputeIntentCreepBrawlDamage(enemy, bot, s.allyCreeps, s.enemyCreeps, 1.55, "PASSIVE", false)
        myBrawlCreepDmg    = U.ComputeIntentCreepBrawlDamage(bot, enemy, s.enemyCreeps, s.allyCreeps, tBrawl, "BRAWL", myAggroOffCd)
        hisBrawlCreepDmg   = U.ComputeIntentCreepBrawlDamage(enemy, bot, s.allyCreeps, s.enemyCreeps, tBrawl, "BRAWL", true)

        enSoon = enSoon + passiveCreepDmgMe
        mySoon = mySoon + passiveCreepDmgHim
        enNow = enNow + passiveCreepDmgMe * 0.30
        myNow = myNow + passiveCreepDmgHim * 0.30
    end

    local effCreepDpsMe  = myBrawlCreepDmg / tBrawl
    local effCreepDpsHim = hisBrawlCreepDmg / tBrawl
    R.myDps = myHeroDps + effCreepDpsHim
    R.enHeroDps = enHeroDps
    R.creepDpsOnMe = effCreepDpsMe
    R.brawlCreepDmgMe = myBrawlCreepDmg
    R.brawlCreepDmgHim = hisBrawlCreepDmg
    R.netCreepDisadv = myBrawlCreepDmg - hisBrawlCreepDmg
    R.enDps = R.enHeroDps + effCreepDpsMe
    R.uphillPenalty = (myHitFactor < 1.0)
    R.ttkMe = (R.enDps > 0) and (myEffHpSoon / R.enDps) or 999
    R.ttkHim = (R.myDps > 0) and (enEffHpSoon / R.myDps) or 999

    R.dist = dist
    R.myHp = myHp
    R.myEffHp = myEffHp
    R.enHp = enHp
    R.enEffHpNow = enEffHpNow
    R.enEffHpSoon = enEffHpSoon
    R.myBurstNow = myNow
    R.myBurstSoon = mySoon
    R.myRazesSoon = myRazesSoon
    R.enBurstNow = enNow
    R.enBurstSoon = enSoon
    R.enRazesSoon = enRazesSoon
    R.canKillNow = (myNow > 0) and (myNow >= enEffHpNow)
    local rawCanKillSoon = (mySoon > 0) and (mySoon >= enEffHpSoon)
    R.heCanKillNow = (enNow > 0) and (enNow >= myEffHp)
    R.heCanKillSoon = (enSoon > 0) and (enSoon >= myEffHpSoon)
    -- `v5.2.0` First-To-Kill Disambiguation: if BOTH sides can kill inside 2.5s, only claim `canKillSoon = true`
    -- when `SolveLethalRace` proves we land the killing blow BEFORE the enemy kills us!
    if rawCanKillSoon and R.heCanKillSoon and U.SolveLethalRace then
        local firstRace = U.SolveLethalRace(bot, enemy, s)
        rawCanKillSoon = (firstRace and firstRace.winsFirstKill) == true
    end
    R.canKillSoon = rawCanKillSoon
    R.edge = (myEffHpSoon - enSoon) - (enEffHpSoon - mySoon)
    R.hpDiff = myEffHp - enEffHpNow
    -- Engagement-bounded post-burst trade projection (`tPost <= 2.6s`, creep damage strictly capped at `tBrawl <= 3.4s`):
    local remMyPost  = math.max(80, myEffHpSoon - enSoon)
    local remHimPost = math.max(80, enEffHpLong - mySoon)
    local tPost = math.max(0.8, math.min(2.6, remMyPost / math.max(15, enHeroDps), remHimPost / math.max(15, myHeroDps)))
    local extraBrawlCreepMe  = math.max(0, myBrawlCreepDmg - passiveCreepDmgMe)
    local extraBrawlCreepHim = math.max(0, hisBrawlCreepDmg - passiveCreepDmgHim)
    local myAfter = myEffHpSoon - enSoon - enHeroDps * tPost - extraBrawlCreepMe
    local enAfter = enEffHpLong - mySoon - myHeroDps * tPost - extraBrawlCreepHim
    R.edgeLong = myAfter - enAfter
    local cfgD = C.DEFENSE or {}
    R.weaker = (R.edgeLong < -(cfgD.WEAKER_EDGE or 120))
        or (R.ttkMe < R.ttkHim * 0.65 and R.edge < 0)
    R.weakerSustained = R.ttkMe < R.ttkHim * (cfgD.SUSTAINED_TTK_RATIO or 0.8)
    R.losingHard = R.heCanKillSoon or (R.edgeLong <= -180 and not R.canKillSoon)
        or (R.ttkMe < R.ttkHim * 0.62 and not R.canKillSoon)
    local enCastable = K.EnemyCastableRazeCount(enemy, 2.5)
    R.enemyCastableRazes = enCastable
    R.minSafeDist = (enCastable > 0) and K.EnemyMinSafeDistance(enemy, 2.5) or ((enemy:GetAttackRange() or 525) + 45)
    R.rawOneRaze = K.EnemyRazeDamage(bot, enemy, 1)
    R.oneRaze = K.EnemyCastableRazeDamage(bot, enemy, 1, nil, 2.5)
    R.twoRaze = K.EnemyCastableRazeDamage(bot, enemy, 2, nil, 2.5)
    R.threeRaze = K.EnemyCastableRazeDamage(bot, enemy, 3, nil, 2.5)
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    R.enemyFaster = enMS > myMS + 5
    R.heHasBootsLead = (enMS - myMS) >= 25
    R.myHpPct = myHp / math.max(1, bot:GetMaxHealth() or 1)
    R.outRazedTier = U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy) or false
    R.nearLevelSpike = U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy) or false
    R.enemyBandHere = (enCastable > 0) and K.EnemyReadyBandAt(enemy, dist, 1.0) or nil
    R.spellWindow, R.windowMyRazes, R.windowEnemyRazes, R.windowDamage, R.windowIncoming, R.cooldownWindow = K.SpellTradeWindow(bot, enemy, s)
    R.valid = true
    return R
end

-- Chasing

-- Can the distance be closed to neededDist in a reasonable time.
-- An enemy with equal/greater speed running away from us - uncatchable.
function K.CanCatch(bot, enemy, neededDist, maxTime)
    if not U.CanQuery(enemy) then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d <= neededDist + 60 then return true end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local vx, vy = 0, 0
    if enemy.GetVelocity then
        local v = enemy:GetVelocity()
        if v then vx, vy = v.x or 0, v.y or 0 end
    end
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 40 then
        -- Standing still: we catch him if the distance is reasonable
        return (d - neededDist) / myMS <= (maxTime or 2.5)
    end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    local awaySpeed = vx * ax + vy * ay -- >0: running away from us
    if awaySpeed > 0.4 * speed then
        local closing = myMS - awaySpeed
        if closing <= 15 then return false end
        return (d - neededDist) / closing <= (maxTime or 2.5)
    end
    -- Walking toward us / sideways
    return (d - neededDist) / (myMS + math.max(0, -awaySpeed)) <= (maxTime or 2.5)
end

-- Is the enemy moving away from us (fleeing)?
function K.IsEnemyMovingAway(bot, enemy)
    if not U.CanQuery(enemy) or not enemy.GetVelocity then return false end
    local v = enemy:GetVelocity()
    if not v then return false end
    local speed = math.sqrt((v.x or 0) ^ 2 + (v.y or 0) ^ 2)
    if speed < 60 then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d < 1 then return false end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    return (v.x * ax + v.y * ay) > 0.5 * speed
end

-- Hook for utils (utils cannot require combat because of the cycle)
U._K = K

return K
