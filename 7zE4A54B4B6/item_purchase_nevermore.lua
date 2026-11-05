-- scripts/vscripts/bots/item_purchase_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local K = require("bots/nevermore/combat")
local P = require("bots/nevermore/positioning")

local PurchaseTable = {
    "item_ward_observer",
    "item_tango",
    "item_branches",
    "item_circlet",
    "item_circlet",
    "item_enchanted_mango",
    "item_faerie_fire",

    -- Strictly 2x Bracer FIRST (+10 STR = +220 HP, +6 DMG, +2 HP/s + Bracer-backpack regen amp),
    -- THEN Boots of Speed, and STRAIGHT into full Power Treads (`item_magic_stick` strictly forbidden!).
    "item_gauntlets", "item_recipe_bracer",
    "item_gauntlets", "item_recipe_bracer",
    "item_boots",

    -- Straight into Power Treads with Belt of Strength FIRST (+132 HP in lane!) then Gloves of Haste
    "item_belt_of_strength",
    "item_gloves",

    "item_blade_of_alacrity", "item_belt_of_strength", "item_recipe_dragon_lance",

    "item_staff_of_wizardry", "item_robe", "item_recipe_kaya"
}

-- Per-bot purchase state (keyed by player ID)
local BotPurchaseState = {}

local function GetBotState(bot)
    local pid = bot:GetPlayerID()
    if pid == nil or pid < 0 then
        return nil
    end

    if not BotPurchaseState[pid] then
        BotPurchaseState[pid] = {
            currentItemIndex = 1,
            lastSalveBuyTime = -1000,
            lastMangoBuyTime = -1000,
            lastClarityBuyTime = -1000,
            extraMango = 0,
            extraSalve = 0,
            extraClarity = 0,
            recoveryWindowAt = -1000,
            recoverySpent = 0,
            lastRecoveryBuy = -1000,
            lastShopAttempt = -1000,
            boughtSecondStartWard = false,
            bought5MinWard = false,
            lastCourierCallTime = -1000,
            resolvedCourierSlot = nil,
            trySlotOffset = 0,
            lastEnemySeenAt = -1000,
            lastEnemyHp = nil,
            lastEnemyMaxHp = nil,
            lastEnemyLvl = nil,
            enKnownMaxHp = nil,
            lastEnemyHasSalve = false,
            lastEnemyHasTango = false,
            lastEnemyRegen = 2.0,
        }
    end

    return BotPurchaseState[pid]
end

-- Inspect whether a queryable enemy hero owns `item_flask` (active/backpack/stash) or has `modifier_flask_healing`.
local function UnitHasHealingSalve(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy.HasModifier then
        local okM, hasMod = pcall(enemy.HasModifier, enemy, "modifier_flask_healing")
        if okM and hasMod then return true end
    end
    if enemy.GetItemInSlot then
        for s = 0, 14 do
            local okI, it = pcall(enemy.GetItemInSlot, enemy, s)
            if okI and it and it.GetName and it:GetName() == "item_flask" then
                return true
            end
        end
    end
    return false
end

local function UnitHasTangoSustain(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy.HasModifier then
        local okM, hasMod = pcall(enemy.HasModifier, enemy, "modifier_tango_heal")
        if okM and hasMod then return true end
    end
    if enemy.GetItemInSlot then
        for s = 0, 8 do
            local okI, it = pcall(enemy.GetItemInSlot, enemy, s)
            if okI and it and it.GetName and it:GetName() == "item_tango" then
                return true
            end
        end
    end
    return false
end

local function UnitHasBootsMobility(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy.GetItemInSlot then
        for s = 0, 8 do
            local okI, it = pcall(enemy.GetItemInSlot, enemy, s)
            if okI and it and it.GetName then
                local nm = it:GetName()
                if nm == "item_boots" or nm == "item_power_treads" then
                    return true
                end
            end
        end
    end
    return false
end

-- Update cached observation of the opposing mid hero (handles backpacked Bracers via `enKnownMaxHp`).
local function UpdateObservedEnemy(bot, state, now)
    local enemy = nil
    local Wmod = package.loaded["bots/nevermore/world"]
    if Wmod and Wmod.s and Wmod.s.enemy and U.CanQuery(Wmod.s.enemy) then
        enemy = Wmod.s.enemy
    elseif bot.GetNearbyHeroes then
        local near = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
        if near and near[1] and U.CanQuery(near[1]) then
            enemy = near[1]
        end
    end

    if enemy and enemy:IsAlive() then
        if enemy.GetPlayerID then
            local okP, ePid = pcall(enemy.GetPlayerID, enemy)
            if okP and type(ePid) == "number" and ePid >= 0 then
                state.lastEnemyPid = ePid
            end
        end
        local enHp = enemy:GetHealth() or 0
        local enMax = math.max(1, enemy:GetMaxHealth() or 600)
        local enLvl = (enemy.GetLevel and enemy:GetLevel()) or 1
        if state.lastEnemyLvl ~= enLvl then
            state.lastEnemyLvl = enLvl
            state.enKnownMaxHp = enMax
        else
            state.enKnownMaxHp = math.max(state.enKnownMaxHp or enMax, enMax)
        end
        local trueMax = state.enKnownMaxHp or enMax
        local trueHp = enHp
        if trueMax - enMax >= 110 and enMax > 0 then
            trueHp = enHp * (trueMax / enMax)
        end
        state.lastEnemySeenAt = now
        state.lastEnemyHp = trueHp
        state.lastEnemyMaxHp = trueMax
        state.lastEnemyHasSalve = UnitHasHealingSalve(enemy)
        state.lastEnemyHasTango = UnitHasTangoSustain(enemy)
        if UnitHasBootsMobility(enemy) then
            state.lastEnemyHasBoots = true
        end
        local okR, reg = false, nil
        if enemy.GetHealthRegen then okR, reg = pcall(enemy.GetHealthRegen, enemy) end
        state.lastEnemyRegen = (okR and type(reg) == "number" and reg >= 0) and reg or 2.2
    end
end

-- Live enemy-death check (`9069188041.dem` `01:11.6` First Blood Fix):
-- `ItemPurchaseThink()` can run BEFORE `Think()` (`W.Update`) on the exact kill tick, so query `IsHeroAlive`
-- directly in addition to `W.s.enemyAlive == false`!
local function IsEnemyDeadRightNow(bot, state)
    local Wmod = package.loaded["bots/nevermore/world"]
    if Wmod and Wmod.s and Wmod.s.enemyAlive == false then
        return true
    end
    if type(IsHeroAlive) == "function" then
        local enPid = (state and state.lastEnemyPid) or (Wmod and Wmod.s and Wmod.s.enemyPlayerId)
        if type(enPid) == "number" and enPid >= 0 then
            local ok, alive = pcall(IsHeroAlive, enPid)
            if ok and alive == false then return true end
        elseif bot and type(GetTeamPlayers) == "function" then
            local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
            local okT, pids = pcall(GetTeamPlayers, enemyTeam)
            if okT and type(pids) == "table" and #pids == 1 then
                local ok, alive = pcall(IsHeroAlive, pids[1])
                if ok and alive == false then return true end
            end
        end
    end
    return false
end

-- Count total `item_tango` charges owned by `bot` across inventory, backpack, stash, and personal courier.
local function GetBotTangoCharges(bot, state)
    if not bot then return 0 end
    local total = 0
    for i = 0, 20 do
        local ok, it = pcall(bot.GetItemInSlot, bot, i)
        if ok and it and it.GetName and it:GetName() == "item_tango" then
            local ch = (it.GetCurrentCharges and it:GetCurrentCharges()) or 0
            total = total + (ch > 0 and ch or 1)
        end
    end
    local myPid = (bot.GetPlayerID and bot:GetPlayerID()) or -1
    local nCour = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
    for i = 0, nCour - 1 do
        local courier = GetCourier(i)
        if courier and not courier:IsNull() then
            local cPid = courier.GetPlayerID and courier:GetPlayerID() or -1
            local foreignOwner = (cPid >= 0 and cPid ~= myPid)
            local mine = (not foreignOwner) and ((cPid == myPid)
                or (state and state.resolvedCourierSlot ~= nil and i == state.resolvedCourierSlot)
                or (nCour == 1 and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam())))
            if mine then
                for slot = 0, 8 do
                    local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                    if ok and it and it.GetName and it:GetName() == "item_tango" then
                        local ch = (it.GetCurrentCharges and it:GetCurrentCharges()) or 0
                        total = total + (ch > 0 and ch or 1)
                    end
                end
            end
        end
    end
    return total
end

-- `v7.0.0` / `v7.9.1` Salve Purchase Discipline:
-- NEVER buy `item_flask` when the live enemy hero has approximately the same HP (or even less HP) as the bot
-- AND the enemy does NOT have a Healing Salve (`item_flask` or active `modifier_flask_healing`)!
function NevermoreEnemyBlocksSalveBuy(bot, state, now)
    if not bot or not state then return false end
    now = now or GameTime()
    if IsEnemyDeadRightNow(bot, state) then
        return false -- Enemy is dead & respawning full at Fountain -> post-kill reset Salve is allowed
    end
    UpdateObservedEnemy(bot, state, now)
    local dt = now - (state.lastEnemySeenAt or -1000)
    if not state.lastEnemyHp or dt < 0 or dt > 10.0 then
        return false
    end
    if state.lastEnemyHasSalve then
        return false -- Enemy owns or is actively drinking a Salve -> matching sustain is allowed
    end
    local enMax = math.max(1, state.lastEnemyMaxHp or 600)
    local enHp = math.min(enMax, state.lastEnemyHp + dt * (state.lastEnemyRegen or 2.2))
    local enPct = enHp / enMax

    local myHp = bot:GetHealth() or 0
    local myMax = math.max(1, bot:GetMaxHealth() or 600)
    local myPct = myHp / myMax

    -- `v7.6.0` / `v7.9.1` Anti-Fountain Sustain Exception (`tangoCharges < 2` rule):
    -- Preserve Equal-HP No-Salve discipline for normal trades, EXCEPT when:
    --   (1) Bot is in critical Fountain-retreat HP (`myPct <= 0.38` or `<= 255 HP` missing `>= 400 HP` with `< 2` Tangoes), OR
    --   (2) Bot has fewer than 2 Tangoes (`tangoCharges < 2`, i.e. `0` or `1` tango) at `<= 56% HP` (`missing >= 320 HP`)
    --       while the enemy still holds active Tango sustain (`state.lastEnemyHasTango`).
    local tangoCharges = GetBotTangoCharges(bot, state)
    local lowTangoSustain = (tangoCharges < 2)
    if myPct <= 0.38 or (lowTangoSustain and myHp <= 255 and (myMax - myHp) >= 400) then
        return false
    end
    if lowTangoSustain and myPct <= 0.56 and (myMax - myHp) >= 320 and state.lastEnemyHasTango then
        return false
    end
    -- `auto-20261102-0007` (`9:58` `726/1408 HP`, `682` missing HP, `0` Tangoes vs Human `9` Salves) Mid-Game Sustain Parity:
    -- After `3:30` (`DotaTime() >= 210`), starting Tangoes are gone and skilled humans ferry Salves in highground FoW;
    -- NEVER starve SF at `<= 55% HP` (`missing >= 400 HP`) with `0` Tangoes just because `state.lastEnemyHasTango` is false!
    if lowTangoSustain and DotaTime() >= 210 and myPct <= 0.55 and (myMax - myHp) >= 400 then
        return false
    end

    local cfg = C.CONSUMABLE_BUY or {}
    local eqAbs = cfg.EQUAL_HP_ABS or 165
    local eqPct = cfg.EQUAL_HP_PCT or 0.17

    local approxSameHp = (math.abs(myHp - enHp) <= eqAbs) or (math.abs(myPct - enPct) <= eqPct)
    local enemyEvenLower = (enHp < myHp) and (enPct <= myPct)
    return approxSameHp or enemyEvenLower
end

function NevermoreGetPurchaseOrder()
    local copy = {}
    for i = 1, #PurchaseTable do copy[i] = PurchaseTable[i] end
    return copy
end

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local state = GetBotState(bot)
    if not state then return end
    if GameTime() < state.lastShopAttempt then
        state.lastShopAttempt = -1000
        state.lastCourierCallTime = -1000
        state.lastSalveBuyTime = -1000
        state.lastMangoBuyTime = -1000
        state.recoveryWindowAt = GameTime()
        state.resolvedCourierSlot = nil
        state.trySlotOffset = 0
        state.lastEnemySeenAt = -1000
    end
    if GameTime() - state.lastShopAttempt < 0.25 then return end
    state.lastShopAttempt = GameTime()
    local now = GameTime()
    local gold = bot:GetGold()

    UpdateObservedEnemy(bot, state, now)

    -- 0A. SECOND STARTING OBSERVER WARD (pre-horn in Fountain, `0g` cost, stacks to `charges = 2` in slot 0 without shifting `PurchaseTable` indices!)
    if DotaTime() < -55 and not state.boughtSecondStartWard and state.currentItemIndex > 1 then
        local inStockW = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_ward_observer") > 0
        if inStockW then
            local wRes0 = bot:ActionImmediate_PurchaseItem("item_ward_observer")
            if wRes0 == (PURCHASE_ITEM_SUCCESS or 0) then
                state.boughtSecondStartWard = true
                gold = bot:GetGold()
            end
        else
            state.boughtSecondStartWard = true
        end
    end

    -- 0B. WARD AT 4:30 (270 seconds) — never buy a duplicate if starting ward is still in inventory!
    if DotaTime() >= 270 and not state.bought5MinWard then
        local alreadyHasWard = false
        for s = 0, 14 do
            local it = bot:GetItemInSlot(s)
            if it and it:GetName() == "item_ward_observer" then alreadyHasWard = true; break end
        end
        if alreadyHasWard then
            state.bought5MinWard = true
        else
            local wRes = bot:ActionImmediate_PurchaseItem("item_ward_observer")
            if wRes == (PURCHASE_ITEM_SUCCESS or 0) then
                state.bought5MinWard = true
                gold = bot:GetGold()
            end
        end
    end

    -- Inventory + stash + dedicated TP slot + team courier: do not duplicate an item in delivery.
    local function owns(name)
        if name == "item_tpscroll" or name == "item_teleport_scroll" then
            return U.HasAnyTPScroll(bot)
        end
        for i = 0, 20 do
            local ok, it = pcall(bot.GetItemInSlot, bot, i)
            if ok and it and it:GetName() == name then return true end
        end
        local myPid = bot:GetPlayerID()
        local nCour = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        for i = 0, nCour - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() then
                local cPid = courier.GetPlayerID and courier:GetPlayerID() or -1
                local foreignOwner = (cPid >= 0 and cPid ~= myPid)
                local mine = (not foreignOwner) and ((cPid == myPid)
                    or (state.resolvedCourierSlot ~= nil and i == state.resolvedCourierSlot)
                    or (nCour == 1 and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam())))
                if mine then
                    for slot = 0, 8 do
                        local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                        if ok and it and it:GetName() == name then return true end
                    end
                end
            end
        end
        return false
    end

    local function countOwned(name)
        local total = 0
        for i = 0, 20 do
            local ok, it = pcall(bot.GetItemInSlot, bot, i)
            if ok and it and it:GetName() == name then
                local ch = (it.GetCurrentCharges and it:GetCurrentCharges()) or 0
                total = total + (ch > 0 and ch or 1)
            end
        end
        local myPid = bot:GetPlayerID()
        local nCour = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        for i = 0, nCour - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() then
                local cPid = courier.GetPlayerID and courier:GetPlayerID() or -1
                local foreignOwner = (cPid >= 0 and cPid ~= myPid)
                local mine = (not foreignOwner) and ((cPid == myPid)
                    or (state.resolvedCourierSlot ~= nil and i == state.resolvedCourierSlot)
                    or (nCour == 1 and (not courier.GetTeam or courier:GetTeam() == bot:GetTeam())))
                if mine then
                    for slot = 0, 8 do
                        local ok, it = pcall(courier.GetItemInSlot, courier, slot)
                        if ok and it and it:GetName() == name then
                            local ch = (it.GetCurrentCharges and it:GetCurrentCharges()) or 0
                            total = total + (ch > 0 and ch or 1)
                        end
                    end
                end
            end
        end
        return total
    end

    local cfg = C.CONSUMABLE_BUY or {}
    if now - state.recoveryWindowAt >= (cfg.RECOVERY_WINDOW or 150) then
        state.recoveryWindowAt = now
        state.recoverySpent = 0
    end
    local fntLoc = P.GetFountain(bot)
    local ownT1Loc = P.GetT1Tower and P.GetT1Tower(bot) or nil
    local missingHP = bot:GetMaxHealth() - bot:GetHealth()
    local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local distToFountain = fntLoc and GetUnitToLocationDistance(bot, fntLoc) or 99999
    local distToOwnT1 = ownT1Loc and GetUnitToLocationDistance(bot, ownT1Loc) or 0
    local t1ToFountain = (ownT1Loc and fntLoc) and U.DistanceBetweenLocations(ownT1Loc, fntLoc) or 8600
    -- Include deep behind-T2 Fountain walk (`>= 1500u` behind Mid T1 toward Fountain at `<= 36% HP` with 0 active regen,
    -- e.g. `auto-20261031-1939` `(2393, 2251)` = `2460u` behind T1) so SF finishes the free Fountain heal
    -- and saves `100g` toward `500g` `item_boots` instead of stranding a Salve in stash!
    local deepWalkingToFountain = (distToOwnT1 >= 1500)
        and (distToFountain <= t1ToFountain - 1350)
        and (hpPctNow <= 0.36)
        and not bot:HasModifier("modifier_flask_healing")
        and not bot:HasModifier("modifier_tango_heal")
    local nearFountain = bot:HasModifier("modifier_fountain_aura_buff")
        or (distToFountain <= 2000)
        or deepWalkingToFountain

    local recoveryBought = false
    -- Only real death agony blocks stash buys (`9069188041.dem` `01:11.6` First Blood Fix:
    -- when the enemy hero JUST DIED (`enemyDeadNow == true`) and no tower is hitting us, `80 HP` is a WON duel,
    -- NOT incoming death — buy post-kill `Salve` BEFORE Section 2 spends FB gold on components!)
    local agonyHp = cfg.AGONY_HP or 115
    local enemyDeadNow = IsEnemyDeadRightNow(bot, state)
    local incomingLethalOrDying = (bot:GetHealth() <= agonyHp
        and ((not enemyDeadNow and bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.5))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.5))))
    local hasBootsOwned = owns("item_boots") or owns("item_power_treads")
    local dtimeNow = DotaTime()
    local bothBracersDone = (state.currentItemIndex or 1) > 11
    -- `v7.9.17-pro` (`1507 @ 05:44.6` Useless Mid-Chase `Flask#3` + Pre-Boots Consumable Drain Fix!):
    --   1. Strictly cap pre-Boots Salves at `2` (`200g` max before `500g` `item_boots` — a 3rd pre-Boots Salve locks SF at `305 MS`!).
    --   2. NEVER order `item_flask` while actively being chased/hunted inside `1,080u` right after hero damage (`<= 4.5s`)!
    local preBootsSalveCap = (cfg.PRE_BOOTS_SALVES or 2)
    local maxExtraSalves = hasBootsOwned
        and math.min(7, 3 + math.floor(math.max(0, dtimeNow - 240) / 120))
        or preBootsSalveCap
    U._salveCapReached = (state.extraSalve >= maxExtraSalves)
    local WrefShop = package.loaded["bots/nevermore/world"]
    local liveEnShop = WrefShop and WrefShop.s and WrefShop.s.enemy
    local activelyChasedNow = (not enemyDeadNow)
        and liveEnShop and U.CanQuery(liveEnShop) and liveEnShop:IsAlive()
        and GetUnitToLocationDistance(bot, liveEnShop:GetLocation()) <= 1080
        and (bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(4.5))
    -- Stick-free Mango fuel curve (`9070559899.dem` + `v7.9.17-pro` Pre-Boots Economy Discipline):
    -- Cap pre-Boots extra Mangoes at `3` (`195g`) unless `hasBootsOwned`, protecting `item_boots` timing (`~04:15–04:50`)!
    local preBootsMangoCap = math.min((cfg.PRE_BOOTS_MANGOES or 3), 3) + ((bothBracersDone and dtimeNow >= 310) and 1 or 0)
    local maxExtraMangoes = hasBootsOwned
        and math.min(10, 5 + math.floor(math.max(0, dtimeNow - 180) / 70))
        or preBootsMangoCap

    local salveBlockedByEqualEnemy = NevermoreEnemyBlocksSalveBuy(bot, state, now)
    local wantSalveFirstNow = false

    -- 1A. Allowed Healing Salve (strictly blocked when enemy has ~equal/lower HP and no Salve!):
    -- Hold gold when `<= 100g` shy of completing a `2x Bracer` component (`currentItemIndex <= 11`) ONLY while
    -- `hpPctNow > 0.38`; at critical `hpPctNow <= 0.38` (`9070149539.dem` `01:33` `36 HP` Fix!), ALWAYS override
    -- the component hold so SF never walks `50s` back to Fountain instead of ordering a `100g` Salve!
    if dtimeNow > 0 and not nearFountain and not incomingLethalOrDying then
        local salveCD = math.max(cfg.RECOVERY_COOLDOWN or 20, cfg.SALVE_CD or 42)
        local hasTangoBuff = bot:HasModifier("modifier_tango_heal")
        local tangoRemHeal = hasTangoBuff and 95 or 0
        local needsSalveDespiteTango = ((missingHP - tangoRemHeal) >= 340)
            or (hpPctNow <= 0.36)
            or (not hasTangoBuff and hpPctNow <= 0.48)
        local nextCoreItem = (state.currentItemIndex <= 11) and PurchaseTable[state.currentItemIndex] or nil
        local nextCoreCost = nextCoreItem and GetItemCost(nextCoreItem) or 0
        local flaskCost = GetItemCost("item_flask")
        local flaskInStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_flask") > 0
        local tangoChargesNow = countOwned("item_tango")
        local lowTangoNow = (tangoChargesNow < 2)
        local lowTangoWounded = lowTangoNow and (hpPctNow <= 0.56) and (missingHP >= 320)
        local coreHoldBlocksSalve = (nextCoreCost > 0)
            and (hpPctNow > 0.38)
            and (not lowTangoWounded)
            and (not enemyDeadNow)
            and (gold >= nextCoreCost - 100)
            and (gold < nextCoreCost + flaskCost)
        -- `v7.9.1` `< 2` Tangos Salve Rule (`9071946472.dem` `01:00` & `02:14` Fix):
        -- Require `tangoChargesNow < 2` (`0` or `1` tango left) to buy `item_flask` so SF eats its starting Tangos
        -- instead of burning Salve cap with 2-3 Tangos in inventory, while immediately unlocking Salve at `< 2` Tangos!
        local salveBaseEligible = lowTangoNow
            and (not activelyChasedNow)
            and (not salveBlockedByEqualEnemy)
            and state.extraSalve < maxExtraSalves
            and (needsSalveDespiteTango or lowTangoWounded)
            and not bot:HasModifier("modifier_flask_healing")
            and not owns("item_flask")
            and now - state.lastSalveBuyTime >= salveCD
            and flaskInStock
        local bootsSaveBlocksSalve = (not hasBootsOwned)
            and (state.currentItemIndex == 12 or state.lastEnemyHasBoots == true)
            and (hpPctNow > 0.34)
            and (not enemyDeadNow)
            and (gold >= 360) and (gold < 600)
        local salveEligibleNow = salveBaseEligible and (not coreHoldBlocksSalve) and (not bootsSaveBlocksSalve)
        if salveEligibleNow then
            local cost = flaskCost
            if gold >= cost then
                local result = bot:ActionImmediate_PurchaseItem("item_flask")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastSalveBuyTime = now
                    state.extraSalve = state.extraSalve + 1
                    U._salveCapReached = (state.extraSalve >= maxExtraSalves)
                    gold = bot:GetGold()
                else
                    wantSalveFirstNow = true
                end
            else
                -- `v7.6.0` Salve-Before-Mango Priority (`01:51.6` `tk=6782` `88g -> 24g` Mango steal Fix!):
                -- Hold `65..99g` for `item_flask` (`100g`) FIRST instead of draining gold on `65g` Mango and
                -- forcing an unnecessary Fountain trip!
                wantSalveFirstNow = true
            end
        elseif salveBaseEligible then
            -- Never let Mango steal gold while `coreHoldBlocksSalve` is holding for core + Salve!
            wantSalveFirstNow = true
        end

        -- 1B. Priority Coil-Fuel Mango (Stick-free `v7.5.0` upgrade):
        -- Order BEFORE courier takes 14s to fly out: `< 95` budget during 2x Bracer, `< 145` budget (`< 2` coils!)
        -- after 2x Bracer, plus 2nd Mango in the SAME courier batch when deeply dry (`< 65 MP` & `missing >= 220`)!
        local mangoCD = cfg.MANGO_CD or 20
        local curMana = bot:GetMana() or 0
        local maxMana = bot:GetMaxMana() or 300
        local manaBudget = K.MyManaBudget(bot, true)
        local ownedMangoes = countOwned("item_enchanted_mango")
        local wantUrgentMango = bothBracersDone and (manaBudget < 145) or (manaBudget < 95)
        local bootsAlmostReady = (not hasBootsOwned)
            and (state.currentItemIndex == 12 or (state.currentItemIndex >= 10 and (state.lastEnemyHasBoots == true or dtimeNow >= 255)))
            and (gold >= 340) and (gold < 565) and (curMana >= 75)
        local bracerAlmostReady = (not bothBracersDone) and (nextCoreCost > 0)
            and (gold >= nextCoreCost - 55) and (gold < nextCoreCost + 65) and (curMana >= 75)
        if not recoveryBought
            and wantUrgentMango
            and not bootsAlmostReady
            and not bracerAlmostReady
            and state.extraMango < maxExtraMangoes
            and now - state.lastMangoBuyTime >= mangoCD
            and hpPctNow >= 0.28
            and ownedMangoes == 0 then
            local cost = GetItemCost("item_enchanted_mango")
            local minGoldForMango = wantSalveFirstNow and (flaskCost + cost) or cost
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStock and gold >= minGoldForMango then
                local result = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastMangoBuyTime = now
                    state.extraMango = state.extraMango + 1
                    ownedMangoes = ownedMangoes + 1
                    gold = bot:GetGold()
                    -- Double-Mango Courier Batch when deeply dry (`< 65 MP`, `missing >= 220`, post-2xBracer):
                    -- 1 Mango (`+100 MP`) barely leaves 1 coil after 14s flight; stacking 2 Mangoes restores `+200 MP`!
                    local inStock2 = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
                    local wontDelayBoots = hasBootsOwned or (gold < 440) or (gold >= 565)
                    if bothBracersDone and curMana < 65 and (maxMana - curMana) >= 220
                        and state.extraMango < maxExtraMangoes and inStock2 and wontDelayBoots and gold >= cost then
                        local res2 = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                        if res2 == (PURCHASE_ITEM_SUCCESS or 0) then
                            state.recoverySpent = state.recoverySpent + cost
                            state.extraMango = state.extraMango + 1
                            gold = bot:GetGold()
                        end
                    end
                end
            end
        end
    end

    -- 2. STRICT MAIN BUILD PROGRESSION: 2x Bracer FIRST (indices 8..11), THEN Boots (index 12), STRAIGHT into Power Treads!
    -- `v7.9.16-pro` + `v7.9.17-pro` (`1343` & `1507 @ 04:36..05:51` Enemy-Boots & Clock-Gated Mobility Parity!):
    -- Once Bracer #1 is finished (`currentItemIndex >= 10`), if the opposing SF ALREADY has `Boots`/`Power Treads` OR the
    -- game clock passed `04:20` (`DotaTime() >= 260`), prioritize `item_boots` (`500g`) before Bracer #2 so SF NEVER gets
    -- run down at `305 MS vs 350 MS` at `05:00+`!
    local wantBootsParityNow = (state.lastEnemyHasBoots == true or dtimeNow >= 260)
        and (state.currentItemIndex >= 10)
        and (state.currentItemIndex < 12)
        and (not (owns("item_boots") or owns("item_power_treads")))
    if wantBootsParityNow and gold >= GetItemCost("item_boots") then
        local bRes = bot:ActionImmediate_PurchaseItem("item_boots")
        if bRes == (PURCHASE_ITEM_SUCCESS or 0) then
            gold = bot:GetGold()
            wantBootsParityNow = false
        end
    end
    local holdForBootsParity = wantBootsParityNow and (gold >= 340) and (gold < GetItemCost("item_boots"))

    -- Buy ALL affordable sequential build items on the SAME tick (`up to 5`) BEFORE dispatching the courier so
    -- First-Blood gold never dispatches `recipe_bracer` alone while stranding `gauntlets` 0.25s later!
    for _ = 1, 5 do
        local nextItem = PurchaseTable[state.currentItemIndex]
        if not nextItem then break end
        if nextItem == "item_boots" and (owns("item_boots") or owns("item_power_treads")) then
            state.currentItemIndex = state.currentItemIndex + 1
        elseif holdForBootsParity and state.currentItemIndex < 12 then
            break
        elseif gold < GetItemCost(nextItem) then
            break
        else
            local result = bot:ActionImmediate_PurchaseItem(nextItem)
            if result == (PURCHASE_ITEM_SUCCESS or 0) then
                state.currentItemIndex = state.currentItemIndex + 1
                gold = bot:GetGold()
            else
                gold = bot:GetGold()
                break
            end
        end
    end

    -- 2B. Post-Bracer / Spare-Gold Proactive Mango & Fallback Sustain (runs AFTER Section 2 so ready core items buy FIRST!)
    -- `9070869385.dem` `02:30` FB Double-Mango Courier Batch Fix:
    -- When Section 1B bought the 1st Mango (`recoveryBought == true`) right BEFORE Section 2 completed the 2nd Bracer on
    -- the same tick (`bothBracersOrdered` just flipped to `true`!), allow batching the 2nd Mango onto the SAME courier trip
    -- immediately when deeply dry (`< 85 MP`, `missing >= 205`, `ownedMangoes == 1` in stash/courier, `0` on hero)!
    do
        local bothBracersJustDone = (state.currentItemIndex > 11)
        local curManaBatch = bot:GetMana() or 0
        local maxManaBatch = bot:GetMaxMana() or 300
        local heroMangoesNow = 0
        for sIdx = 0, 8 do
            local it = bot:GetItemInSlot(sIdx)
            if it and it:GetName() == "item_enchanted_mango" then
                heroMangoesNow = heroMangoesNow + math.max(1, it:GetCurrentCharges() or 1)
            end
        end
        local totalOwnedNow = countOwned("item_enchanted_mango")
        local bootsHoldBatch = (state.currentItemIndex == 12) and (not (owns("item_boots") or owns("item_power_treads")))
            and (gold >= 340) and (gold < 565)
        if dtimeNow > 0 and not nearFountain and not incomingLethalOrDying
            and bothBracersJustDone and recoveryBought
            and heroMangoesNow == 0 and totalOwnedNow == 1
            and curManaBatch < 85 and (maxManaBatch - curManaBatch) >= 205
            and state.extraMango < maxExtraMangoes
            and not bootsHoldBatch and not wantSalveFirstNow
            and hpPctNow >= 0.28 then
            local costB = GetItemCost("item_enchanted_mango")
            local inStockB = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStockB and gold >= costB then
                local resB = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if resB == (PURCHASE_ITEM_SUCCESS or 0) then
                    state.recoverySpent = state.recoverySpent + costB
                    state.extraMango = state.extraMango + 1
                    gold = bot:GetGold()
                end
            end
        end
    end
    if dtimeNow > 0 and not nearFountain and not incomingLethalOrDying and not recoveryBought then
        local mangoCD = math.min(cfg.MANGO_CD or 20, 18)
        local bothBracersOrdered = state.currentItemIndex > 11
        local nextBuild = PurchaseTable[state.currentItemIndex]
        local reserve = bothBracersOrdered and 0 or (nextBuild and GetItemCost(nextBuild) or 0)
        local curMana2 = bot:GetMana() or 0
        local maxMana2 = bot:GetMaxMana() or 300
        local ownedMangoes2 = countOwned("item_enchanted_mango")
        local bootsCloseHold = (state.currentItemIndex == 12) and (not (owns("item_boots") or owns("item_power_treads")))
            and (gold >= 340)
        local allowSecondProactive = bothBracersOrdered and (ownedMangoes2 == 1) and (curMana2 < 85) and ((maxMana2 - curMana2) >= 210)
        local postBootsManaFloor = (owns("item_boots") or owns("item_power_treads")) and (dtimeNow >= 320) and 160 or 118
        if state.extraMango < maxExtraMangoes
            and not bootsCloseHold
            and now - state.lastMangoBuyTime >= mangoCD
            and (K.MySustainedManaBudget(bot, 12.0) < 165 or curMana2 < postBootsManaFloor)
            and (maxMana2 - curMana2) >= 120
            and hpPctNow >= 0.28
            and (ownedMangoes2 == 0 or allowSecondProactive) then
            local cost = GetItemCost("item_enchanted_mango")
            local salveHold2 = wantSalveFirstNow and GetItemCost("item_flask") or 0
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_enchanted_mango") > 0
            if inStock and gold >= cost + reserve + salveHold2 then
                local result = bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cost
                    state.lastRecoveryBuy = now
                    state.lastMangoBuyTime = now
                    state.extraMango = state.extraMango + 1
                    gold = bot:GetGold()
                end
            end
        end

        -- `v7.9.18-pro` (`9074513540.dem` `06:46.40` Orphaned Sentry Ward Fix):
        -- `item_ward_sentry` is STRICTLY FORBIDDEN: wastes `50g`, hijacks courier during `07:00` catapult night window,
        -- and permanently bricks an active inventory slot (pushing `item_branches` / stat items into Backpack).

        -- 2C. Out-of-Stock Mango -> Clarity Fallback (`auto-20261102-0007` `7:30..10:14` `9/9` Mango Exhaustion Fix!):
        -- Dota 2 gives each team ONLY `4` initial Mangoes + `+1` every `120s` (`9` max by `10:00`). Once Mango stock hits `0`,
        -- order `1x item_clarity` (`50g`, `+150 MP`, separate `4`-stock pool; already auto-drunk/protected in `bot_nevermore.lua`!)
        -- so SF never starves at `< 75 MP` for `160s` waiting on a `120s` Mango restock!
        local mangoStockNow = (type(GetItemStockCount) == "function") and GetItemStockCount("item_enchanted_mango") or 1
        local clarityStockNow = (type(GetItemStockCount) ~= "function") or (GetItemStockCount("item_clarity") > 0)
        if not recoveryBought
            and bothBracersOrdered
            and mangoStockNow <= 0
            and clarityStockNow
            and (state.extraClarity or 0) < 3
            and not bootsCloseHold
            and now - (state.lastClarityBuyTime or -1000) >= 45
            and curMana2 < 145
            and (maxMana2 - curMana2) >= 150
            and hpPctNow >= 0.34
            and ownedMangoes2 == 0
            and not owns("item_clarity")
            and not bot:HasModifier("modifier_clarity_potion") then
            local cCost = GetItemCost("item_clarity")
            local salveHoldC = wantSalveFirstNow and GetItemCost("item_flask") or 0
            if gold >= cCost + reserve + salveHoldC then
                local cRes = bot:ActionImmediate_PurchaseItem("item_clarity")
                if cRes == (PURCHASE_ITEM_SUCCESS or 0) then
                    recoveryBought = true
                    state.recoverySpent = state.recoverySpent + cCost
                    state.lastRecoveryBuy = now
                    state.lastClarityBuyTime = now
                    state.extraClarity = (state.extraClarity or 0) + 1
                    gold = bot:GetGold()
                end
            end
        end

        local interval = bothBracersOrdered and 85 or 115
        if not recoveryBought
            and countOwned("item_tango") < 2
            and not salveBlockedByEqualEnemy
            and now - state.lastSalveBuyTime >= interval
            and hpPctNow < 0.35
            and not bot:HasModifier("modifier_flask_healing")
            and state.extraSalve < maxExtraSalves
            and not owns("item_flask") then
            local cost = GetItemCost("item_flask")
            local salveReserve = math.max(180, nextBuild and GetItemCost(nextBuild) or 0)
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount("item_flask") > 0
            if inStock and gold >= cost + salveReserve then
                local result = bot:ActionImmediate_PurchaseItem("item_flask")
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    state.lastSalveBuyTime = now
                    state.extraSalve = state.extraSalve + 1
                    gold = bot:GetGold()
                end
            end
        end
    end

    -- 3. SMART PERSONAL COURIER (`9069188041.dem` `eid=1462` vs `eid=2094` 5-Courier Fix):
    -- NEVER latch `resolvedCourierSlot` onto a Beastmaster's personal courier delivering `item_ring_of_protection`,
    -- and NEVER rotate `trySlotOffset` onto Beastmasters' personal couriers (which C++ ignores for SF's stash)!
    if GameTime() - state.lastCourierCallTime > 0.35 then
        local pid = bot:GetPlayerID()
        if pid < 0 then return end

        local numCouriers = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
        if numCouriers <= 0 then return end

        local function isBeastmasterCourier(c)
            if not c or c:IsNull() or not c.GetItemInSlot then return false end
            for slot = 0, 8 do
                local okI, it = pcall(c.GetItemInSlot, c, slot)
                if okI and it and it.GetName and it:GetName() == "item_ring_of_protection" then
                    return true
                end
            end
            return false
        end

        local myCourier = nil
        for i = 0, numCouriers - 1 do
            local c = GetCourier(i)
            if c and not c:IsNull() and c.GetPlayerID and c:GetPlayerID() == pid then
                myCourier = c
                state.resolvedCourierSlot = i
                break
            end
        end

        if not myCourier then
            local baseIdx = 0
            if type(GetTeamPlayers) == "function" then
                local okT, teamPlayers = pcall(GetTeamPlayers, bot:GetTeam())
                if okT and type(teamPlayers) == "table" then
                    for index, id in ipairs(teamPlayers) do
                        if id == pid then
                            baseIdx = index - 1
                            break
                        end
                    end
                end
            end
            if baseIdx >= 0 and baseIdx < numCouriers then
                local cBase = GetCourier(baseIdx)
                local cBasePid = (cBase and not cBase:IsNull() and cBase.GetPlayerID) and cBase:GetPlayerID() or -1
                if cBase and not cBase:IsNull() and (cBasePid < 0 or cBasePid == pid)
                    and (not cBase.GetTeam or cBase:GetTeam() == bot:GetTeam())
                    and not isBeastmasterCourier(cBase) then
                    myCourier = cBase
                    state.resolvedCourierSlot = baseIdx
                end
            end
            if not myCourier then
                for i = 0, numCouriers - 1 do
                    local c = GetCourier(i)
                    local cPid = (c and not c:IsNull() and c.GetPlayerID) and c:GetPlayerID() or -1
                    if c and not c:IsNull() and (cPid < 0 or cPid == pid)
                        and (not c.GetTeam or c:GetTeam() == bot:GetTeam())
                        and not isBeastmasterCourier(c) then
                        myCourier = c
                        break
                    end
                end
            end
        end

        if myCourier and not myCourier:IsNull() then
            local state_c = GetCourierState(myCourier)
            local canBurst = COURIER_ACTION_BURST and ((bot.GetLevel and bot:GetLevel()) or 1) >= 10
            local stashItemsCount = 0
            local onlyWardInStash = true
            local urgentCourier = false
            local stashHasFlask = false
            local stashHasMango = false
            local stashHasGauntlets = false
            local courierHasFlask = false
            local courierHasBoots = false
            local courierHasMango = false

            for i = 9, 14 do
                local item = bot:GetItemInSlot(i)
                if item then
                    stashItemsCount = stashItemsCount + 1
                    local nm = item:GetName()
                    if nm ~= "item_ward_observer" then
                        onlyWardInStash = false
                    end
                    if nm == "item_gauntlets" then
                        stashHasGauntlets = true
                    end
                    if nm == "item_flask" then
                        stashHasFlask = true
                    end
                    if nm == "item_enchanted_mango" then
                        stashHasMango = true
                    end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" or nm == "item_clarity" then
                        urgentCourier = true
                    end
                end
            end

            local courierItemsCount = 0
            for slot = 0, 8 do
                local okI, cItem = pcall(myCourier.GetItemInSlot, myCourier, slot)
                if okI and cItem then
                    courierItemsCount = courierItemsCount + 1
                    local nm = cItem:GetName()
                    if nm == "item_flask" then courierHasFlask = true end
                    if nm == "item_boots" or nm == "item_power_treads" then courierHasBoots = true end
                    if nm == "item_enchanted_mango" then courierHasMango = true end
                    if nm == "item_flask" or nm == "item_boots" or nm == "item_power_treads" or nm == "item_enchanted_mango" or nm == "item_clarity" then
                        urgentCourier = true
                    end
                end
            end

            local hasStash = stashItemsCount > 0 or (bot.GetStashValue and (bot:GetStashValue() or 0) > 0)
            local hasOnCourier = courierItemsCount > 0 or (bot.GetCourierValue and (bot:GetCourierValue() or 0) > 0)
            local courierDistFnt = fntLoc and GetUnitToLocationDistance(myCourier, fntLoc) or math.huge
            local courierAtShopPickupRange = courierDistFnt <= 1050
            local courierNearBase = courierDistFnt <= 1850
            -- NEVER hold back `gauntlets` when `recipe_bracer` is ALREADY owned or on courier (completes Bracer #1!),
            -- AND never starve SF of `+3 STR (+66 HP, +3 DMG)` for `41-92s` (`auto-20261031-0230` `00:36-02:08` Fix):
            -- batch solo `gauntlets` for at most `18s` while healthy (`> 68% HP`), then dispatch immediately!
            if stashHasGauntlets then
                if not state.gauntletsStashSince or now < state.gauntletsStashSince then
                    state.gauntletsStashSince = now
                end
            else
                state.gauntletsStashSince = nil
            end
            local gauntletsWaitedLong = state.gauntletsStashSince and ((now - state.gauntletsStashSince) >= 18.0) or false
            local gauntletsCompletesBracerNow = stashHasGauntlets and owns("item_recipe_bracer")
            local onlySoloGauntlets = (stashItemsCount == 1) and stashHasGauntlets
                and not gauntletsCompletesBracerNow and not gauntletsWaitedLong
                and (hpPctNow > 0.68) and not hasOnCourier
                and not urgentCourier and (DotaTime() < 300)
            -- Dispatch courier immediately for the `4:30` Night Observer Ward (`DotaTime() >= 265`) instead of leaving
            -- mid highground blind in Night FoW while saving `1000g` for `Blade of Alacrity`!
            local holdSoloWardPreHornOnly = (stashItemsCount == 1 and onlyWardInStash and DotaTime() < 265)
            local holdBatch = holdSoloWardPreHornOnly or onlySoloGauntlets
            -- `v7.9.17-pro` (`1507 @ 02:20–03:20` Zero-Bounce Courier Delivery Fix!):
            -- NEVER yank an outbound `DELIVERING_ITEMS` courier `1,850..3,800u` back to Fountain when it is ALREADY carrying
            -- items mid-flight (which stranded `Bracer`/`Mango`/`Flask` for `45–59s`!). Only turn back right inside base (`<= 950..1,450u`)!
            local needFlaskTurnback = (state_c == COURIER_STATE_DELIVERING_ITEMS)
                and stashHasFlask and not courierHasFlask and not courierHasBoots
                and not U.HasItem(bot, "item_flask") and not bot:HasModifier("modifier_flask_healing")
                and ((hpPctNow <= 0.45 and courierDistFnt <= 1550) or courierDistFnt <= 1100)
            local needMangoTurnback = (state_c == COURIER_STATE_DELIVERING_ITEMS)
                and stashHasMango and not courierHasFlask and not courierHasBoots and not courierHasMango
                and ((bot:GetMana() or 0) < 75) and not U.HasItem(bot, "item_enchanted_mango")
                and courierDistFnt <= 1250
            local turnbackReady = (GameTime() - (state.lastCourierCallTime or -10)) >= 1.6
            local dispatchReady = (GameTime() - (state.lastCourierCallTime or -10)) >= 1.25
            -- `auto-20261102-0007` (`5:31..9:33` `0.53s` `TAKE_AND_TRANSFER_ITEMS` Spam Fix):
            -- Throttle ALL courier dispatches (`>= 1.25s`) AND check that SF either has >= 1 free hero/backpack slot (`0..8`)
            -- or owns a combinable recipe/stackable item before ordering delivery (preventing futile 2Hz courier bounce loops!).
            local heroFreeSlots = 0
            local heroHasMango = false
            local heroHasObsWard = false
            for hs = 0, 8 do
                local hIt = bot:GetItemInSlot(hs)
                if not hIt then
                    heroFreeSlots = heroFreeSlots + 1
                else
                    local hNm = hIt:GetName()
                    if hNm == "item_enchanted_mango" then heroHasMango = true end
                    if hNm == "item_ward_observer" then heroHasObsWard = true end
                end
            end
            local canCombineBracer = owns("item_circlet") and owns("item_gauntlets") and owns("item_recipe_bracer")
            local canCombineTreads = owns("item_boots") and owns("item_belt_of_strength") and owns("item_gloves")
            local canAcceptDelivery = (heroFreeSlots > 0)
                or canCombineBracer
                or canCombineTreads
                or (heroHasMango and (stashHasMango or courierHasMango))
                or (heroHasObsWard and stashItemsCount >= 1)
            local stalledMovingCourier = (state_c == COURIER_STATE_MOVING)
                and ((GameTime() - (state.lastCourierCallTime or -10)) >= 4.0)
            local needShortBatchTurnback = (courierDistFnt <= 920)
                and state_c == COURIER_STATE_DELIVERING_ITEMS
                and not courierHasFlask and not courierHasBoots
                and turnbackReady
            if hasStash and not holdBatch and canAcceptDelivery and courierItemsCount < 9 then
                if ((state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                        or stalledMovingCourier
                        or (state_c == COURIER_STATE_RETURNING_TO_BASE and courierAtShopPickupRange)) and dispatchReady)
                    or ((needFlaskTurnback or needMangoTurnback) and turnbackReady)
                    or needShortBatchTurnback then
                    bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
                    if urgentCourier and canBurst then
                        pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                    end
                    state.lastCourierCallTime = GameTime()
                end
            elseif hasOnCourier and canAcceptDelivery and dispatchReady
                and (state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE
                    or stalledMovingCourier
                    or state_c == COURIER_STATE_RETURNING_TO_BASE) then
                bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TRANSFER_ITEMS)
                if urgentCourier and canBurst then
                    pcall(bot.ActionImmediate_Courier, bot, myCourier, COURIER_ACTION_BURST)
                end
                state.lastCourierCallTime = GameTime()
            end
        end
    end
end
