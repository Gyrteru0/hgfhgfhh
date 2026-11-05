--
-- The per-tick world snapshot: collect the unit lists, the enemy, the towers and the enemy's presence
-- (alive / when last seen) once. The W.s table is reused (no per-tick allocations).

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local W = {}

-- Buffers for the filtered unit lists (reused every tick — zero per-tick GC allocations)
local ENEMY_CREEPS_BUF, ALLY_CREEPS_BUF, ENEMY_TOWERS_BUF, ALLY_TOWERS_BUF = {}, {}, {}, {}
local ENEMY_CREEPS_AT_T1_BUF, ALLY_CREEPS_BEHIND_T1_BUF = {}, {}
local MID_ACTIVE_ALLY_CREEPS_BUF, MID_ACTIVE_ENEMY_CREEPS_BUF = {}, {}
local function FilterQueryable(list, buf)
    for i = #buf, 1, -1 do buf[i] = nil end
    if not list then return buf end
    local n = 0
    for _, u in pairs(list) do
        if U.CanQuery(u) then
            n = n + 1
            buf[n] = u
        end
    end
    return buf
end

W.s = {
    now = 0,
    bot = nil,
    enemy = nil, -- The visible enemy hero (queryable) or nil
    enemyAny = nil, -- The enemy handle even if not visible (may not be queryable)
    enemyVisible = false,
    enemyAlive = true,
    enemyLastSeen = -1, -- The GameTime when he was last seen
    enemyLastLoc = nil,
    enemyAbsentFor = 0, -- seconds unseen (0 if visible)
    enemyDist = 99999,
    enemyCreeps = nil,
    allyCreeps = nil,
    enemyTowers = nil,
    allyTowers = nil,
    enemyT1 = nil, -- The enemy T1 handle (if alive and accessible)
    enemyT1Alive = true,
    allyT1 = nil,
    myKills = 0,
    myDeaths = 0,
    enemyKills = 0,
    enemyDeaths = 0,
}

local EMPTY = {}

local function FindT1(towers)
    for _, t in pairs(towers or EMPTY) do
        if t and t:IsAlive() then
            local name = t:GetUnitName() or ""
            if name:find("tower1") then return t end
        end
    end
    return nil
end

local function SafeGetTower(team, idx)
    if type(GetTower) ~= "function" then return nil end
    local ok, t = pcall(GetTower, team, idx)
    if ok then return t end
    return nil
end

-- Filler Beastmaster anti-AFK bot filter (`hero_selection.lua` spawns 4 `npc_dota_hero_beastmaster` bots in base):
-- Ensures `W.s.enemy`, `enemyPlayerId`, `enemyLastLoc`, and `incomingEnemyTPs` lock ONLY onto the real 1v1 mid opponent!
local function IsFillerBeastmasterPid(pid)
    if type(pid) ~= "number" or pid < 0 then return false end
    if type(GetSelectedHeroName) ~= "function" then return false end
    local okN, hName = pcall(GetSelectedHeroName, pid)
    if not okN or hName ~= "npc_dota_hero_beastmaster" then return false end
    if type(IsPlayerBot) == "function" then
        local okB, isB = pcall(IsPlayerBot, pid)
        if okB and isB == false then return false end
    end
    return true
end

local function IsFillerBeastmasterUnit(u)
    if not u or not u.GetUnitName then return false end
    local okN, nm = pcall(u.GetUnitName, u)
    if not okN or nm ~= "npc_dota_hero_beastmaster" then return false end
    if type(IsPlayerBot) == "function" and u.GetPlayerID then
        local okP, pid = pcall(u.GetPlayerID, u)
        if okP and type(pid) == "number" and pid >= 0 then
            local okB, isB = pcall(IsPlayerBot, pid)
            if okB and isB == false then return false end
        end
    end
    return true
end

W.IsFillerBeastmasterPid  = IsFillerBeastmasterPid
W.IsFillerBeastmasterUnit = IsFillerBeastmasterUnit

local INCOMING_TPS_BUF = {}

-- This API exposes only visible teleport effects, not hidden cast destinations.
function W.ReadIncomingTeleports(bot, s)
    local out = INCOMING_TPS_BUF
    for i = #out, 1, -1 do out[i] = nil end
    s.incomingEnemyTPs = out
    if type(GetIncomingTeleports) ~= "function" then return end
    local ok, list = pcall(GetIncomingTeleports)
    if not ok or type(list) ~= "table" or next(list) == nil then return end
    local myPid = (bot and bot.GetPlayerID and bot:GetPlayerID()) or -999

    local allyIds = {}
    if myPid >= 0 then allyIds[myPid] = true end
    local enemyIds = {}
    if type(s.enemyPlayerId) == "number" and s.enemyPlayerId >= 0 and not IsFillerBeastmasterPid(s.enemyPlayerId) then
        enemyIds[s.enemyPlayerId] = true
    end
    local known = s.enemyAny or s.enemy
    if known and not IsFillerBeastmasterUnit(known) and known.GetPlayerID then
        local okId, pid = pcall(known.GetPlayerID, known)
        if okId and type(pid) == "number" and pid >= 0 and not IsFillerBeastmasterPid(pid) then
            enemyIds[pid] = true
            s.enemyPlayerId = pid
        end
    end
    if type(GetTeamPlayers) == "function" then
        local allyTeam = bot:GetTeam()
        for _, id in pairs(GetTeamPlayers(allyTeam) or {}) do allyIds[id] = true end
        local enemyTeam = allyTeam == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
        for _, id in pairs(GetTeamPlayers(enemyTeam) or {}) do
            if not IsFillerBeastmasterPid(id) then
                enemyIds[id] = true
            end
        end
    end
    for _, tp in pairs(list) do
        local pid = tp and tp.playerid
        local isEnemyTP = (pid ~= nil) and not IsFillerBeastmasterPid(pid)
            and (enemyIds[pid] or (type(pid) == "number" and not allyIds[pid]))
        if isEnemyTP and tp.location and type(tp.location.x) == "number" and type(tp.location.y) == "number"
            and type(tp.time_remaining) == "number" and tp.time_remaining >= 0 and tp.time_remaining <= 15 then
            s.incomingEnemyTPs[#s.incomingEnemyTPs + 1] = tp
        end
    end
end

function W.Update(bot)
    local s = W.s
    local now = GameTime()
    if s.bot ~= bot or (s.now and s.now > 0 and now < s.now - 1.0) then
        s.enemyLastSeen = -1
        s.enemyLastLoc = nil
        s.enemyAbsentFor = 0
        s.enemyAlive = true
        s.enemyLastHealth = nil
        s.enemyLastMana = nil
        s.enemyT1Alive = true
        s.enemyT1Loc = nil
        s.enemyT1LastHp = nil
    end
    s.now = now
    s.bot = bot
    if type(GetTimeOfDay) == "function" then
        local okTod, tod = pcall(GetTimeOfDay)
        s.timeOfDay = (okTod and type(tod) == "number") and tod or 0.5
    else
        s.timeOfDay = 0.5
    end
    s.isNight = (s.timeOfDay < 0.25) or (s.timeOfDay >= 0.75)
    s.enemyVisionRange = s.isNight and 800 or 1800

    -- The enemy: first from the global list (visibility/presence), then the nearby list.
    -- Strictly ignore filler Beastmaster bots, preferring `npc_dota_hero_nevermore` (or closest real opponent).
    local enemy = nil
    local enemyAny = nil
    local bestEnemyScore = -1e9
    local function considerHero(h)
        if not h or IsFillerBeastmasterUnit(h) then return end
        -- Source 2 C++ `CDOTA_Bot_Script::IsIllusion` logs a `[Developer]` console warning every tick
        -- if called on any non-teammate entity! Guard strictly by `h:GetTeam() == bot:GetTeam()`.
        if h.GetTeam and bot.GetTeam and h:GetTeam() == bot:GetTeam() and h.IsIllusion then
            local okIll, isIll = pcall(h.IsIllusion, h)
            if okIll and isIll then return end
        end
        enemyAny = enemyAny or h
        if U.CanQuery(h) then
            local nm = (h.GetUnitName and h:GetUnitName()) or ""
            local d = GetUnitToLocationDistance(bot, h:GetLocation())
            local score = ((nm == "npc_dota_hero_nevermore") and 100000 or 0) - d
            if score > bestEnemyScore then
                bestEnemyScore = score
                enemy = h
            end
        end
    end
    if type(GetUnitList) == "function" and UNIT_LIST_ENEMY_HEROES then
        local list = GetUnitList(UNIT_LIST_ENEMY_HEROES)
        for _, h in pairs(list or EMPTY) do
            considerHero(h)
        end
    end
    if not enemy then
        local near = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
        for _, h in pairs(near or EMPTY) do
            considerHero(h)
        end
    end
    s.enemy = enemy
    s.enemyAny = enemyAny or enemy
    s.enemyVisible = enemy ~= nil
    if (type(s.enemyPlayerId) ~= "number" or IsFillerBeastmasterPid(s.enemyPlayerId)) and type(GetTeamPlayers) == "function" then
        local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
        for _, pid in pairs(GetTeamPlayers(enemyTeam) or {}) do
            if not IsFillerBeastmasterPid(pid) then
                s.enemyPlayerId = pid
                break
            end
        end
    end
    if enemy then
        s.enemyLastSeen = now
        s.enemyLastLoc = enemy:GetLocation()
        s.enemyAbsentFor = 0
        s.enemyDist = GetUnitToLocationDistance(bot, s.enemyLastLoc)
        s.enemyAlive = enemy:IsAlive()
        if enemy.GetPlayerID then
            local okId, pid = pcall(enemy.GetPlayerID, enemy)
            if okId and type(pid) == "number" and pid >= 0 and not IsFillerBeastmasterPid(pid) then
                s.enemyPlayerId = pid
            end
        end
        if enemy.GetLevel then
            local okLv, lv = pcall(enemy.GetLevel, enemy)
            if okLv and type(lv) == "number" and lv > 0 then s.enemyLastLevel = lv end
        end
        if enemy.GetMaxHealth then
            local okMh, mh = pcall(enemy.GetMaxHealth, enemy)
            if okMh and type(mh) == "number" and mh > 0 then s.enemyLastMaxHealth = mh end
        end
        if enemy.GetAttackDamage then
            local okAd, ad = pcall(enemy.GetAttackDamage, enemy)
            if okAd and type(ad) == "number" and ad > 0 then s.enemyLastAttackDmg = ad end
        end
        if enemy.GetHealth then
            local okHp, hp = pcall(enemy.GetHealth, enemy)
            if okHp and type(hp) == "number" and hp >= 0 then s.enemyLastHealth = hp end
        end
        if enemy.GetMana then
            local okMp, mp = pcall(enemy.GetMana, enemy)
            if okMp and type(mp) == "number" and mp >= 0 then s.enemyLastMana = mp end
        end
    else
        if s.enemyLastSeen >= 0 then
            s.enemyAbsentFor = now - s.enemyLastSeen
        else
            s.enemyAbsentFor = (type(DotaTime) == "function" and math.max(0, DotaTime())) or now
        end
        s.enemyDist = 99999
        -- Is the invisible enemy alive: MUST query `GetTeamPlayers(enemyTeam)` + `IsHeroAlive(pid)` directly!
        -- CRITICAL FIX (`HUD 09:01` `auto-20261021-1810`): When the enemy hero dies in Source 2 C++,
        -- `GetUnitList(UNIT_LIST_ENEMY_HEROES)` returns `{}` so `s.enemyAny` is `nil`! Checking only `s.enemyAny`
        -- falsely left `s.enemyAlive == true` for all 28 seconds of the enemy's death timer!
        local alive = true
        local respawnRem = nil
        if type(IsHeroAlive) == "function" then
            local checked = false
            local deadPid = nil
            local h = s.enemyAny
            if h and h.GetPlayerID then
                local ok, pid = pcall(h.GetPlayerID, h)
                if ok and pid and pid >= 0 then
                    local ok2, res = pcall(IsHeroAlive, pid)
                    if ok2 and res ~= nil then
                        alive = res; checked = true
                        if res == false then deadPid = pid end
                    end
                end
            end
            if not checked and type(s.enemyPlayerId) == "number" and s.enemyPlayerId >= 0 then
                local ok2, res = pcall(IsHeroAlive, s.enemyPlayerId)
                if ok2 and res ~= nil then
                    alive = res; checked = true
                    if res == false then deadPid = s.enemyPlayerId end
                end
            end
            if not checked and type(GetTeamPlayers) == "function" then
                local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
                for _, pid in pairs(GetTeamPlayers(enemyTeam) or {}) do
                    local ok2, res = pcall(IsHeroAlive, pid)
                    if ok2 and res == false then
                        alive = false; deadPid = pid; break
                    end
                end
            end
            if not alive and deadPid and type(GetHeroRespawnTime) == "function" then
                local okR, rt = pcall(GetHeroRespawnTime, deadPid)
                if okR and type(rt) == "number" and rt >= 0 then respawnRem = rt end
            end
        end
        s.enemyAlive = alive
        s.enemyRespawnRemaining = respawnRem
    end
    if s.enemyAlive then s.enemyRespawnRemaining = nil end

    -- Score (tracks real opponent `s.enemyPlayerId` even while dead or in Fog of War)
    if type(GetHeroKills) == "function" then
        local ePid = (s.enemyAny and not IsFillerBeastmasterUnit(s.enemyAny) and s.enemyAny.GetPlayerID and s.enemyAny:GetPlayerID()) or s.enemyPlayerId
        if type(ePid) == "number" and ePid >= 0 and not IsFillerBeastmasterPid(ePid) then
            local ok1, k = pcall(GetHeroKills, ePid)
            local ok2, d = pcall(GetHeroDeaths, ePid)
            if ok1 and k then s.enemyKills = k end
            if ok2 and d then s.enemyDeaths = d end
        end
        local pid = bot:GetPlayerID()
        local ok1, k = pcall(GetHeroKills, pid)
        local ok2, d = pcall(GetHeroDeaths, pid)
        if ok1 and k then s.myKills = k end
        if ok2 and d then s.myDeaths = d end
    end
    s.matchPointKill    = (s.myKills or 0) >= 1
    s.suddenDeathDanger = (s.enemyKills or 0) >= 1

    -- Units
    -- GetNearbyLaneCreeps(..., true) may return enemy creeps in fog (the handle exists but
    -- cannot be queried): every GetHealth/GetLocation on such a creep logs "[Developer] ... cannot be
    -- seen" to the console and a last hit/push on it is an order into thin air. We filter via CanQuery into two
    -- reused tables (no per-tick allocations).
    s.enemyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1600, true), ENEMY_CREEPS_BUF)
    s.allyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1600, false), ALLY_CREEPS_BUF)
    -- CRITICAL C++ Engine Fix (`9056774541.dem` `tk=6340`): `bot:GetNearbyTowers(1600, true)` and `GetTower(...)`
    -- return handles to alive enemy towers standing on highground Fog of War (`CanBeSeen() == false`), where calling
    -- `:GetHealth()` / `:GetMaxHealth()` / `:GetAttackTarget()` spams C++ `[Developer] ... cannot be seen!` AND returns `-1`!
    -- Therefore:
    --   1. `s.enemyTowers` and `s.enemyT1` ONLY ever hold strictly `U.CanQuery(t)` (`CanBeSeen() == true`) towers!
    --   2. `s.enemyT1Alive` and `s.enemyT1Loc` preserve exact tower liveness & static mid T1 coordinates EVEN IN FULL FoW,
    --      so `HandleEnemyTowerSafety` evacuates immediately at `0.000s` when the last allied creep dies under highground T1!
    s.enemyTowers = FilterQueryable(bot:GetNearbyTowers(1600, true), ENEMY_TOWERS_BUF)
    s.allyTowers = FilterQueryable(bot:GetNearbyTowers(1600, false), ALLY_TOWERS_BUF)

    local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
    local staticEnemyT1Loc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local rawT1 = nil
    if TOWER_MID_1 ~= nil then
        rawT1 = SafeGetTower(enemyTeam, TOWER_MID_1)
    end
    local visibleT1 = nil
    if rawT1 then
        local okAlive, alive = pcall(rawT1.IsAlive, rawT1)
        if okAlive and alive == false then
            s.enemyT1Alive = false
            s.enemyT1Loc = nil
        else
            s.enemyT1Alive = true
            if U.CanQuery(rawT1) then
                visibleT1 = rawT1
                local okLoc, loc = pcall(rawT1.GetLocation, rawT1)
                if okLoc and loc then s.enemyT1Loc = loc end
                local okHp, hp = pcall(rawT1.GetHealth, rawT1)
                if okHp and type(hp) == "number" and hp > 0 then s.enemyT1LastHp = hp end
            else
                -- Tower is alive in highground Fog of War (`CanBeSeen() == false`): keep exact cached/static coordinates!
                s.enemyT1Loc = s.enemyT1Loc or staticEnemyT1Loc
            end
        end
    else
        local nearT1 = FindT1(s.enemyTowers)
        if nearT1 and U.CanQuery(nearT1) then
            visibleT1 = nearT1
            s.enemyT1Alive = true
            s.enemyT1Loc = nearT1:GetLocation()
            local okHp, hp = pcall(nearT1.GetHealth, nearT1)
            if okHp and type(hp) == "number" and hp > 0 then s.enemyT1LastHp = hp end
        elseif TOWER_MID_1 ~= nil then
            -- `GetTower(enemyTeam, TOWER_MID_1)` returned `nil` -> enemy Mid T1 has been destroyed!
            s.enemyT1Alive = false
            s.enemyT1Loc = nil
        elseif s.enemyT1Alive ~= false then
            s.enemyT1Loc = s.enemyT1Loc or staticEnemyT1Loc
        end
    end
    s.enemyT1 = visibleT1

    -- `v7.9.11-pro` (`2213 @ 10:54..12:59` Anti-Creep-Cut & Global `allyT1` Siege Awareness Fix!):
    -- Previously `s.allyT1 = FindT1(s.allyTowers)` used `bot:GetNearbyTowers(1600, false)`, returning `nil` whenever `bot`
    -- was `> 1,600u` from its own Mid T1 (e.g. pushing river or in side-jungle `(3094, 82)` while `4` enemy creeps hammered
    -- Dire T1 down to `535 HP`!). Always resolve `SafeGetTower(myTeam, TOWER_MID_1)` globally AND track visible enemy creeps
    -- near `allyT1` + allied creeps behind `allyT1` (between `allyT1` and `allyT2`)!
    local myTeam = bot:GetTeam()
    local staticAllyT1Loc = (myTeam == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
    local fntLoc = (myTeam == TEAM_RADIANT) and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
    local rawAllyT1 = (TOWER_MID_1 ~= nil) and SafeGetTower(myTeam, TOWER_MID_1) or nil
    local liveAllyT1 = nil
    if rawAllyT1 then
        local okAl, al = pcall(rawAllyT1.IsAlive, rawAllyT1)
        if okAl and al then
            liveAllyT1 = rawAllyT1
        end
    end
    if not liveAllyT1 then
        liveAllyT1 = FindT1(s.allyTowers)
    end
    s.allyT1 = liveAllyT1
    s.allyT1Alive = (liveAllyT1 ~= nil)
    if liveAllyT1 and U.CanQuery(liveAllyT1) then
        s.allyT1Loc = liveAllyT1:GetLocation() or staticAllyT1Loc
        s.allyT1Hp = liveAllyT1:GetHealth() or 1800
        s.allyT1MaxHp = math.max(1, liveAllyT1:GetMaxHealth() or 1800)
    else
        s.allyT1Loc = liveAllyT1 and staticAllyT1Loc or nil
        s.allyT1Hp = liveAllyT1 and 1800 or 0
        s.allyT1MaxHp = 1800
    end

    for i = #ENEMY_CREEPS_AT_T1_BUF, 1, -1 do ENEMY_CREEPS_AT_T1_BUF[i] = nil end
    for i = #ALLY_CREEPS_BEHIND_T1_BUF, 1, -1 do ALLY_CREEPS_BEHIND_T1_BUF[i] = nil end
    if s.allyT1Alive and s.allyT1Loc and type(GetUnitList) == "function" then
        local dT1ToFnt = U.DistanceBetweenLocations(s.allyT1Loc, fntLoc)
        if UNIT_LIST_ENEMY_CREEPS then
            local nEc = 0
            for _, ec in pairs(GetUnitList(UNIT_LIST_ENEMY_CREEPS) or EMPTY) do
                if U.CanQuery(ec) and ec:IsAlive() then
                    local ecLoc = ec:GetLocation()
                    if ecLoc and U.DistanceBetweenLocations(ecLoc, s.allyT1Loc) <= 1380 then
                        nEc = nEc + 1
                        ENEMY_CREEPS_AT_T1_BUF[nEc] = ec
                    end
                end
            end
        end
        if UNIT_LIST_ALLIED_CREEPS then
            local nAc = 0
            for _, ac in pairs(GetUnitList(UNIT_LIST_ALLIED_CREEPS) or EMPTY) do
                if U.CanQuery(ac) and ac:IsAlive() then
                    local acLoc = ac:GetLocation()
                    if acLoc then
                        local dAcT1 = U.DistanceBetweenLocations(acLoc, s.allyT1Loc)
                        local dAcFnt = U.DistanceBetweenLocations(acLoc, fntLoc)
                        if dAcT1 <= 2650 and dAcFnt <= dT1ToFnt - 120 then
                            nAc = nAc + 1
                            ALLY_CREEPS_BEHIND_T1_BUF[nAc] = ac
                        end
                    end
                end
            end
        end
    end
    s.enemyCreepsNearAllyT1 = ENEMY_CREEPS_AT_T1_BUF
    s.allyCreepsBehindT1 = ALLY_CREEPS_BEHIND_T1_BUF

    -- Resolve allied Mid T2 location (`(2496, 2112)` Dire / `(-3536, -2784)` Radiant) for clean `215u` retreat hull clearance:
    local staticAllyT2Loc = (myTeam == TEAM_RADIANT) and C.POSITIONS.RADIANT_T2 or C.POSITIONS.DIRE_T2
    local rawAllyT2 = (TOWER_MID_2 ~= nil) and SafeGetTower(myTeam, TOWER_MID_2) or nil
    if rawAllyT2 then
        local okA2, al2 = pcall(rawAllyT2.IsAlive, rawAllyT2)
        if okA2 and al2 then
            s.allyT2Alive = true
            s.allyT2Loc = (U.CanQuery(rawAllyT2) and rawAllyT2:GetLocation()) or staticAllyT2Loc
        else
            s.allyT2Alive = false
            s.allyT2Loc = nil
        end
    else
        s.allyT2Alive = true
        s.allyT2Loc = staticAllyT2Loc
    end

    -- `v7.9.12-pro` (`2319 @ 00:54..01:12, 02:20..02:26, 02:55..03:12` Global Mid-Corridor Staircase Wave Awareness):
    -- Source 2 C++ `bot:GetNearbyLaneCreeps(nRadius, bEnemies)` is HARD-CAPPED at `1,600u`! When `bot` stands near/behind
    -- `allyT1` (`(625, 513)`) and the enemy SF freezes the wave on his own staircase (`(-625, -437)`, `d = 1,620..2,250u`),
    -- `s.allyCreeps` and `s.enemyCreeps` (`<= 1,600u`) are empty (`0` creeps) even though `GetUnitList(UNIT_LIST_ALLIED_CREEPS)`
    -- sees 100% of our creeps globally AND `GetUnitList(UNIT_LIST_ENEMY_CREEPS)` sees 100% of enemy creeps revealed by them!
    -- Keep `s.allyCreeps` / `s.enemyCreeps` strictly at `1,600u` (preserving all local shield/aggro assumptions), and populate
    -- `s.midActiveAllyCreeps` / `s.midActiveEnemyCreeps` across the active mid battle corridor between `allyT1` and `enemyT1`!
    for i = #MID_ACTIVE_ALLY_CREEPS_BUF, 1, -1 do MID_ACTIVE_ALLY_CREEPS_BUF[i] = nil end
    for i = #MID_ACTIVE_ENEMY_CREEPS_BUF, 1, -1 do MID_ACTIVE_ENEMY_CREEPS_BUF[i] = nil end
    s.activeMidClashLoc = nil
    s.hasDistantMidWaveClash = false
    if type(GetUnitList) == "function" then
        local aT1Ref = s.allyT1Loc or staticAllyT1Loc
        local eT1Ref = s.enemyT1Loc or staticEnemyT1Loc
        local myStairRef = (myTeam == TEAM_RADIANT) and C.POSITIONS.RADIANT_STAIRCASE or C.POSITIONS.DIRE_STAIRCASE
        local segVec = eT1Ref - aT1Ref
        local segLen = math.max(1.0, U.DistanceBetweenLocations(aT1Ref, eT1Ref))
        local ax, ay = segVec.x / segLen, segVec.y / segLen
        local stairProj = (myStairRef.x - aT1Ref.x) * ax + (myStairRef.y - aT1Ref.y) * ay
        local function isMidLaneCreepInBattleZone(c, minProj)
            if not (c and U.CanQuery(c) and c:IsAlive()) then return false, 0 end
            local nm = (c.GetUnitName and c:GetUnitName()) or ""
            if nm ~= "" and not (string.find(nm, "creep", 1, true) or string.find(nm, "siege", 1, true)) then
                return false, 0
            end
            if string.find(nm, "neutral", 1, true) then return false, 0 end
            local cl = c:GetLocation()
            if not cl then return false, 0 end
            local rx, ry = cl.x - aT1Ref.x, cl.y - aT1Ref.y
            local proj = rx * ax + ry * ay
            if proj < minProj or proj > (segLen + 260) then return false, 0 end
            local px, py = rx - ax * proj, ry - ay * proj
            if (px * px + py * py) > (840 * 840) then return false, 0 end
            return true, proj
        end

        local closestEnemyClashLoc, minEnemyProj = nil, math.huge
        if UNIT_LIST_ENEMY_CREEPS then
            local nME = 0
            for _, ec in pairs(GetUnitList(UNIT_LIST_ENEMY_CREEPS) or EMPTY) do
                local okZ, proj = isMidLaneCreepInBattleZone(ec, -340)
                if okZ then
                    nME = nME + 1
                    MID_ACTIVE_ENEMY_CREEPS_BUF[nME] = ec
                    if proj < minEnemyProj then
                        minEnemyProj = proj
                        closestEnemyClashLoc = ec:GetLocation()
                    end
                end
            end
        end

        local frontAllyClashLoc, maxAllyProj = nil, -1e9
        local anyActivelyFightingAlly = false
        if UNIT_LIST_ALLIED_CREEPS then
            local nMA = 0
            for _, ac in pairs(GetUnitList(UNIT_LIST_ALLIED_CREEPS) or EMPTY) do
                -- `minProj = -120`: strictly excludes newly-spawned waves marching between Fountain/T3/T2 and `allyT1`!
                local okZ, proj = isMidLaneCreepInBattleZone(ac, -120)
                if okZ then
                    nMA = nMA + 1
                    MID_ACTIVE_ALLY_CREEPS_BUF[nMA] = ac
                    -- `v7.9.17-pro`: ONLY treat allied creeps as a `hasDistantMidWaveClash` when an allied creep is ACTUALLY
                    -- attacking a target (`GetAttackTarget() ~= nil`, e.g. fighting an unseen enemy wave on enemy highground)!
                    -- Leftover unengaged allied creeps walking toward enemy T1 with `0` enemy creeps (`closestEnemyClashLoc == nil`)
                    -- must NEVER set `hasDistantMidWaveClash = true` (which previously blocked recurring staircase creep-blocking!).
                    local activelyFighting = (ac.GetAttackTarget and ac:GetAttackTarget() ~= nil)
                    if activelyFighting then
                        anyActivelyFightingAlly = true
                    end
                    if proj > maxAllyProj then
                        maxAllyProj = proj
                        frontAllyClashLoc = ac:GetLocation()
                    end
                end
            end
        end

        if closestEnemyClashLoc then
            s.activeMidClashLoc = closestEnemyClashLoc
            s.hasDistantMidWaveClash = true
        elseif anyActivelyFightingAlly and frontAllyClashLoc then
            s.activeMidClashLoc = frontAllyClashLoc
            s.hasDistantMidWaveClash = true
        end
    end
    s.midActiveAllyCreeps = MID_ACTIVE_ALLY_CREEPS_BUF
    s.midActiveEnemyCreeps = MID_ACTIVE_ENEMY_CREEPS_BUF

    W.ReadIncomingTeleports(bot, s)
    if U.ObserveWorldTick then
        U.ObserveWorldTick(bot, s)
    end

    return s
end

-- The enemy is "absent": dead or unseen for longer than absentSec.
function W.EnemyAbsent(absentSec)
    local s = W.s
    if not s.enemyAlive then return true end
    if s.enemyVisible then return false end
    return s.enemyAbsentFor >= (absentSec or 5.0)
end

-- Hook for utils (utils cannot require world because of the cycle)
U._W = W

return W
