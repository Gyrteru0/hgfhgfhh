--[[
================================================================================
 WAR CORE v1.1 (Patch 7.41f Exact) — Predictive Duel Simulator for SF 1v1 Mid
================================================================================
 Pure Lua 5.1 forward simulator (zero Dota API calls).

 Unified v6.6.0 fixes over v6.5.0:
   1. Exact Patch 7.41f constants:
        RAZE_BASE      = { 85, 150, 215, 280 }
        RAZE_STACK     = { 35, 50, 65, 80 }
        STACK_DURATION = 6.0s (7.41e/f debuff duration)
        ATK_RANGE      = 525u
        TOWER_DMG      = 65 post-class/armor fallback
   2. Emergency burst heal (`faerie` +85 HP, `stick_charges` * 15 HP/MP) simulated
      accurately on both heroes (`9068560663.dem` 01:53 fix).
   3. Fixed undeclared global `worstPlan` leak in `WAR.Evaluate`.
================================================================================
]]

local WAR = {}

local C = {
    DT              = 1.0 / 30.0,

    RAZE_MANA       = 75,
    RAZE_CD         = 9.0,
    RAZE_CAST       = 0.55,
    RAZE_DIST       = { 200, 450, 700 },
    RAZE_RADIUS     = 250,
    RAZE_HERO_RADIUS= 274, -- Exact Source 2 FindUnitsInRadius: 250 + 24 hero hull
    RAZE_BASE       = { 85, 150, 215, 280 },
    RAZE_STACK      = { 35, 50, 65, 80 },
    RAZE_PER_SOUL   = 2,
    STACK_DURATION  = 6.0,
    MAX_STACKS      = 4,

    ATK_RANGE       = 525,
    ATK_POINT       = 0.50,
    PROJ_SPEED      = 1200,
    BAT             = 1.60,
    TURN_RATE       = 30.0, -- Exact Source 2 SF turn rate: 0.9 rad / 0.03s = 30.0 rad/s (1718.9 deg/s)
    MAGIC_RESIST    = 0.25,

    TOWER_RANGE     = 868,
    TOWER_LEASH     = 1080,
    TOWER_DMG       = 65,
    TOWER_INTERVAL  = 0.8182,
    TOWER_WINDUP    = 0.60,
    TOWER_PROJECTILE= 750,
    TOWER_FIRST     = 0.35,

    HORIZON         = 3.4,
    INCOMING_LAND   = 0.18,

    CREEP = {
        melee  = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        ranged = { dmg = 23.5, bat = 1.0, range = 500, proj = 900,  hp = 300 },
        siege  = { dmg = 40.5, bat = 3.0, range = 690, proj = 1100, hp = 935 },
        flag   = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        HULL_PAD = 45,
    },

    W_HP            = 1.0,
    W_MANA          = 0.28,
    W_TOWER         = 0.0,
    W_STAND         = 0.45,
    DEATH_COST      = 1.0e6,
    KILL_BONUS      = 3.2e5,
    SAFE_HP_ABS     = 135,
}
WAR.C = C

local m_sqrt  = math.sqrt
local m_min   = math.min
local m_max   = math.max
local m_abs   = math.abs
local m_floor = math.floor
local m_cos   = math.cos
local m_sin   = math.sin
local m_atan2 = math.atan2
local m_pi    = math.pi
local TWO_PI  = 2.0 * math.pi

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function distance(ax, ay, bx, by) local dx, dy = ax - bx, ay - by return m_sqrt(dx * dx + dy * dy) end

WAR.clamp = clamp
WAR.dist = distance

local RAZE_BASE_TBL  = C.RAZE_BASE
local RAZE_STACK_TBL = C.RAZE_STACK
local RAZE_DIST_TBL  = C.RAZE_DIST
local RAZE_MANA_COST = C.RAZE_MANA
local RAZE_HERO_RAD  = C.RAZE_HERO_RADIUS
local RAZE_CAST_PT   = C.RAZE_CAST
local RAZE_CD_DUR    = C.RAZE_CD
local DEF_MAGIC_RES  = C.MAGIC_RESIST
local MAX_STKS       = C.MAX_STACKS
local RANK_MAP       = { poor = 0, solid = 1, lock = 2, clean = 3 }

--------------------------------------------------------------------------------
-- damage model (Patch 7.41f exact + Spell Amp + Infused Raindrop 120 block)
--------------------------------------------------------------------------------
local function razeDamageFast(level, stacks, souls, stackTalent, spellAmp)
    level = clamp(level or 1, 1, 4)
    local d = RAZE_BASE_TBL[level]
        + (stacks or 0) * (RAZE_STACK_TBL[level] + (stackTalent or 0))
        + (souls or 0) * 2
    return d * (spellAmp or 1.0)
end
WAR.RazeDamage = razeDamageFast

local function razeAppliedFast(level, stacks, souls, mr, stackTalent, spellAmp, magicBlock)
    mr = mr or DEF_MAGIC_RES
    local raw = razeDamageFast(level, stacks, souls, stackTalent, spellAmp)
    if magicBlock and magicBlock > 0 and raw >= 75 then
        raw = raw - magicBlock
        if raw < 0 then raw = 0 end
    end
    return raw * (1.0 - mr)
end
WAR.RazeApplied = razeAppliedFast

function WAR.VolleyDamage(level, stacks, souls, n, mr, stackTalent, spellAmp, magicBlock)
    local total, st = 0, stacks or 0
    for i = 1, (n or 0) do
        local blk = (i == 1) and (magicBlock or 0) or 0
        total = total + razeAppliedFast(level, st, souls, mr, stackTalent, spellAmp, blk)
        if st < MAX_STKS then st = st + 1 end
    end
    return total
end

--------------------------------------------------------------------------------
-- unit normalisation & emergency burst consumables
--------------------------------------------------------------------------------
function WAR.Prep(u)
    u = u or {}
    u.hp = u.hp or 1
    u.hp_max = u.hp_max or u.hp
    u.mana = u.mana or 0
    u.dmg = u.dmg or 0
    u.souls = u.souls or 0
    u.raze_level = u.raze_level or 0
    u.stack_talent = u.stack_talent or 0
    u.raze_ready = u.raze_ready or { 0, 0, 0 }
    u.atk_range = u.atk_range or C.ATK_RANGE
    u.atk_ready = u.atk_ready or 0
    u.ms = u.ms or 305
    u.regen_hp = u.regen_hp or 0
    u.regen_mana = u.regen_mana or 0
    u.magic_resist = u.magic_resist or C.MAGIC_RESIST
    u.spell_amp = u.spell_amp or 1.0
    u.magic_block = u.magic_block or 0
    u.raindrop_used = false
    u.alive = (u.alive ~= false)
    u.stacks = u.stacks or 0
    u.stack_t = u.stack_t or -1e9
    u.facing = u.facing or 0
    u.cast_until = u.cast_until or -1
    u.aim_x, u.aim_y = u.aim_x, u.aim_y
    u.atk_until = u.atk_until or -1
    u.proj = nil
    u.incoming = u.incoming or 0
    u.incoming_at = u.incoming_at or C.INCOMING_LAND
    u.pending_raze = nil
    u.stick_charges = u.stick_charges or 0
    if type(u.mango_charges) == "number" then
        u.mango_left = math.max(0, u.mango_charges)
    else
        u.mango_left = (u.mango and not u.mango_used) and 1 or 0
    end
    u.mango = u.mango_left > 0
    u.faerie = u.faerie and true or false
    u.faerie_used = false
    u.stick_used = false
    u.mango_used = (u.mango_left <= 0)
    return u
end

local function try_emergency_heal(u)
    if not u.alive then return end
    if u.stick_charges and u.stick_charges > 0 and not u.stick_used and u.hp <= u.hp_max * 0.30 then
        local gain = u.stick_charges * 15
        u.hp = math.min(u.hp_max, u.hp + gain)
        u.mana = u.mana + gain
        u.stick_used = true
    end
    if u.faerie and not u.faerie_used and u.hp <= math.max(110, u.hp_max * 0.22) then
        u.hp = math.min(u.hp_max, u.hp + 85)
        u.faerie_used = true
    end
end

local function apply_damage(victim, dmg, now)
    if not victim or not victim.alive or dmg <= 0 then return end
    victim.hp = victim.hp - dmg
    victim.hp_taken = (victim.hp_taken or 0) + dmg
    if victim.hp <= 0 then
        -- Pop unused Faerie/Stick right BEFORE lethal hit (mirrors emergency consumable reflex!)
        if victim.stick_charges and victim.stick_charges > 0 and not victim.stick_used then
            local gain = victim.stick_charges * 15
            victim.hp = victim.hp + gain
            victim.mana = victim.mana + gain
            victim.stick_used = true
        end
        if victim.hp <= 0 and victim.faerie and not victim.faerie_used then
            victim.hp = victim.hp + 85
            victim.faerie_used = true
        end
    end
    if victim.hp <= 0 then
        victim.hp = 0
        victim.alive = false
        victim.died_at = now
    else
        try_emergency_heal(victim)
    end
end

local function clone_unit(u)
    local c = {}
    for k, v in pairs(u) do
        if k == "proj" or k == "pending_raze" or k == "pending_attack" then
            -- re-initialised below
        elseif type(v) == "table" then
            if k == "raze_ready" then c[k] = { v[1] or 0, v[2] or 0, v[3] or 0 }
            else local n = {} for kk, vv in pairs(v) do n[kk] = vv end c[k] = n end
        else
            c[k] = v
        end
    end
    c.proj = nil
    c.pending_raze = nil
    c.pending_attack = nil
    return c
end

--------------------------------------------------------------------------------
-- readiness
--------------------------------------------------------------------------------
local function unit_mango_count(u)
    if not u then return 0 end
    if type(u.mango_left) == "number" then return u.mango_left > 0 and u.mango_left or 0 end
    if type(u.mango_charges) == "number" then return u.mango_charges > 0 and u.mango_charges or 0 end
    return (u.mango and not u.mango_used) and 1 or 0
end

local function affordableFast(u, _now)
    local mana = u.mana or 0
    if not u.stick_used then mana = mana + (u.stick_charges or 0) * 15 end
    mana = mana + unit_mango_count(u) * 100
    return m_floor((mana + (u.regen_mana or 0) * 1.0) / RAZE_MANA_COST)
end
WAR.Affordable = affordableFast

local function readyCountFast(u, now)
    local rr = u.raze_ready
    local n = 0
    if (rr[1] or 0) <= now then n = n + 1 end
    if (rr[2] or 0) <= now then n = n + 1 end
    if (rr[3] or 0) <= now then n = n + 1 end
    local budget = affordableFast(u, now)
    if n > budget then n = budget end
    return n
end
WAR.ReadyCount = readyCountFast

function WAR.ReadyLabels(u, now, horizon)
    local out = {}
    local lim = now + (horizon or 0)
    for i = 1, 3 do
        if (u.raze_ready[i] or 0) <= lim then out[#out + 1] = i end
    end
    return out
end

local function burstFast(attacker, victim, horizon, now, opts)
    if not attacker or (attacker.raze_level or 0) <= 0 then return 0, 0 end
    now = now or 0
    local lim = now + horizon
    local rr = attacker.raze_ready
    local n = 0
    if (rr[1] or 0) <= lim then n = n + 1 end
    if (rr[2] or 0) <= lim then n = n + 1 end
    if (rr[3] or 0) <= lim then n = n + 1 end
    local budget = affordableFast(attacker, now)
    if budget < n then n = budget end
    if n > 3 then n = 3 end
    if opts and opts.max and n > opts.max then n = opts.max end
    if not victim or n <= 0 then return 0, n end
    local total, st = 0, victim.stacks or 0
    local lvl = attacker.raze_level
    local mr = victim.magic_resist or DEF_MAGIC_RES
    local spellAmp = attacker.spell_amp or 1.0
    local firstBlock = (not victim.raindrop_used) and (victim.magic_block or 0) or 0
    local souls = attacker.souls
    local stackTalent = attacker.stack_talent
    for i = 1, n do
        local blk = (i == 1) and firstBlock or 0
        total = total + razeAppliedFast(lvl, st, souls, mr, stackTalent, spellAmp, blk)
        if st < MAX_STKS then st = st + 1 end
    end
    return total, n
end
WAR.Burst = burstFast

--------------------------------------------------------------------------------
-- aiming & step simulation
--------------------------------------------------------------------------------
local function findShotFast(u, foe, now, minQuality)
    if (u.raze_level or 0) <= 0 or not foe or not foe.alive then return nil end
    local effMana = (u.mana or 0) + unit_mango_count(u) * 100
        + ((not u.stick_used) and ((u.stick_charges or 0) * 15) or 0)
    if effMana < RAZE_MANA_COST then return nil end

    local locked = (foe.atk_until and foe.atk_until > now) or (foe.cast_until and foe.cast_until > now)
    local lockTime = 0
    if foe.atk_until and foe.atk_until > now then lockTime = foe.atk_until - now end
    if foe.cast_until and foe.cast_until > now then lockTime = m_max(lockTime, foe.cast_until - now) end
    local escape = locked and m_max(0, (foe.ms or 305) * m_max(0, RAZE_CAST_PT - lockTime))
                           or ((foe.ms or 305) * RAZE_CAST_PT)

    local tx = foe.x + (foe.vx or 0) * RAZE_CAST_PT
    local ty = foe.y + (foe.vy or 0) * RAZE_CAST_PT
    local dd = distance(u.x, u.y, tx, ty)

    local rr = u.raze_ready
    local best, bestSlack = nil, -1e9
    local hitSlackBase = (RAZE_HERO_RAD - 18) - escape
    for i = 1, 3 do
        if (rr[i] or 0) <= now then
            local slack = hitSlackBase - m_abs(dd - RAZE_DIST_TBL[i])
            if slack > bestSlack then
                best, bestSlack = i, slack
            end
        end
    end
    if not best then return nil end
    local quality = "poor"
    if locked and bestSlack > -180 then quality = "lock" end
    if bestSlack >= 0 then quality = locked and "lock" or "solid" end
    if bestSlack >= 60 then quality = "clean" end
    minQuality = minQuality or "solid"
    if RANK_MAP[quality] < RANK_MAP[minQuality] then return nil, bestSlack, quality end
    return best, bestSlack, quality
end
WAR.FindShot = findShotFast

local function start_attack(u, tgt, now)
    local d = distance(u.x, u.y, tgt.x, tgt.y)
    if d > (u.atk_range or C.ATK_RANGE) + 25 then return false end
    if u.atk_ready > now or u.cast_until > now then return false end
    if u.pending_attack then return false end
    u.atk_until = now + C.ATK_POINT
    u.pending_attack = {
        t = now + C.ATK_POINT, dmg = u.dmg, target = tgt,
        ready = now + math.max(0.85, C.BAT * 0.78),
    }
    return true
end

local function resolve_pending_attack(u, now)
    local a = u.pending_attack
    if not a or a.t > now then return end
    u.pending_attack = nil
    u.atk_ready = a.ready
    local t = a.target
    if not t or not t.alive then return end
    local d = distance(u.x, u.y, t.x, t.y)
    local pr = u.proj
    if not pr then pr = {}; u.proj = pr end
    pr[#pr + 1] = { t = now + d / C.PROJ_SPEED, dmg = a.dmg, target = t }
end

local function cancel_attack(u)
    if u.pending_attack then
        u.pending_attack = nil
        u.atk_until = -1
        return true
    end
    return false
end

local function apply_projectiles(u, now)
    local pr = u.proj
    if not pr then return end
    local n = #pr
    if n == 0 then return end
    local w = 0
    for i = 1, n do
        local p = pr[i]
        if p.t <= now then
            apply_damage(p.target, p.dmg, now)
        else
            w = w + 1
            if w ~= i then pr[w] = p end
        end
    end
    for i = w + 1, n do pr[i] = nil end
end

local function resolve_raze(u, now)
    local p = u.pending_raze
    if not p or p.t > now then return end
    u.pending_raze = nil
    if p.live_cast then
        u.mana = m_max(0, (u.mana or 0) - RAZE_MANA_COST)
        if u.raze_ready and p.idx then
            u.raze_ready[p.idx] = now + RAZE_CD_DUR
        end
    end
    local tgt = p.target
    if not tgt or not tgt.alive then return end
    local d = RAZE_DIST_TBL[p.idx]
    local cx = u.x + m_cos(u.facing) * d
    local cy = u.y + m_sin(u.facing) * d
    if distance(cx, cy, tgt.x, tgt.y) <= RAZE_HERO_RAD then
        local liveStacks = tgt.stacks or 0
        local liveRawDmg = ((u.raze_level or 0) > 0)
            and razeDamageFast(u.raze_level, liveStacks, u.souls, u.stack_talent, u.spell_amp)
            or (p.raw_dmg or p.dmg or 0)
        local appliedDmg = ((u.raze_level or 0) > 0)
            and razeAppliedFast(u.raze_level, liveStacks, u.souls, tgt.magic_resist, u.stack_talent, u.spell_amp, 0)
            or (p.dmg or 0)
        if (tgt.magic_block or 0) > 0 and not tgt.raindrop_used and liveRawDmg >= 75 then
            local mr = tgt.magic_resist or DEF_MAGIC_RES
            local reducedRaw = m_max(0, liveRawDmg - tgt.magic_block)
            appliedDmg = reducedRaw * (1.0 - mr)
            tgt.raindrop_used = true
        end
        apply_damage(tgt, appliedDmg, now)
        tgt.stacks = m_min(MAX_STKS, liveStacks + 1)
        tgt.stack_t = now
        tgt.last_raze_hit_at = now
        tgt.hit_by_raze = (tgt.hit_by_raze or 0) + 1
    else
        u.raze_missed = (u.raze_missed or 0) + 1
    end
end

local function step_toward(u, gx, gy, dt, now)
    if not u.alive then return end
    if u.cast_until > now then return end
    if u.atk_until and u.atk_until > now then return end
    local d = distance(u.x, u.y, gx, gy)
    if d < 2 then return end
    local step = m_min(d, u.ms * dt)
    local nx, ny = (gx - u.x) / d, (gy - u.y) / d
    u.x = u.x + nx * step
    u.y = u.y + ny * step
    u.vx, u.vy = nx * u.ms, ny * u.ms
    if u.atk_until <= now then u.facing = m_atan2(ny, nx) end
end

local function control(u, foe, plan, now, dt)
    if not u.alive then return "dead" end

    local hold = plan.hold_dist or 440
    local pol = plan.raze_policy or "none"
    local attackOn = plan.attack ~= false
    if plan.adaptive and foe and foe.alive then
        local foeEff = foe.hp + ((foe.faerie and not foe.faerie_used) and 85 or 0)
        local myEff = u.hp + ((u.faerie and not u.faerie_used) and 85 or 0)
        local canFinish = (burstFast(u, foe, 1.6, now) + u.dmg * 2) >= foeEff
        local inDanger = (burstFast(foe, u, 1.6, now) + foe.dmg * 2) >= myEff
        if canFinish then
            hold = m_min(hold, 260)
            pol = "burst"
            attackOn = true
        elseif inDanger and plan.punish_danger ~= false then
            hold = m_max(hold, 620)
        end
    end

    if u.cast_until > now then
        if u.aim_x and u.aim_y then
            local want = m_atan2(u.aim_y - u.y, u.aim_x - u.x)
            local diff = want - u.facing
            while diff > m_pi do diff = diff - TWO_PI end
            while diff < -m_pi do diff = diff + TWO_PI end
            local maxTurn = C.TURN_RATE * dt
            u.facing = u.facing + clamp(diff, -maxTurn, maxTurn)
        end
        return "casting"
    end

    local d = foe and foe.alive and distance(u.x, u.y, foe.x, foe.y) or 1e9

    if plan.dodge ~= false and foe and foe.alive and foe.cast_until > now and foe.cast_label then
        local bandD = RAZE_DIST_TBL[foe.cast_label] or 450
        local cx = foe.x + m_cos(foe.facing) * bandD
        local cy = foe.y + m_sin(foe.facing) * bandD
        local dc = distance(u.x, u.y, cx, cy)
        if dc <= RAZE_HERO_RAD + 14 then
            if plan.cancel_dodge ~= false then cancel_attack(u) end
            local rx, ry = u.x - cx, u.y - cy
            local rl = m_sqrt(rx * rx + ry * ry)
            if rl < 1e-3 then rx, ry, rl = 1, 0, 1 end
            step_toward(u, u.x + (rx / rl) * 195, u.y + (ry / rl) * 195, dt, now)
            return "dodge"
        end
    end

    local want, quality = false, nil
    if pol == "burst" then
        want, quality = true, (plan.raze_quality or "solid")
    elseif pol == "single" then
        want, quality = (now - (u.last_volley_at or -1e9) > 2.0), (plan.raze_quality or "solid")
    elseif pol == "trade" then
        local hisReady = (foe and readyCountFast(foe, now)) or 0
        local myBurst = burstFast(u, foe, 2.2, now)
        local hisBurst = foe and burstFast(foe, u, 2.2, now) or 0
        want = (hisReady == 0)
            or (myBurst >= 0.85 * hisBurst and myBurst > 0)
            or (foe and foe.hp < (plan.finish_hp or 260))
        if foe and foe.cast_until and foe.cast_until > now then want = true end
        quality = (hisReady == 0) and (plan.raze_quality or "solid") or "poor"
    elseif pol == "lethal" then
        want = foe and (burstFast(u, foe, 1.8, now) >= foe.hp + 25)
        quality = "poor"
    elseif pol == "answer" then
        want = (foe and foe.last_raze_hit_at and now - foe.last_raze_hit_at <= 0.7) or false
        quality = "poor"
    end
    if want and foe and foe.alive then
        local idx = findShotFast(u, foe, now, quality)
        if idx then
            while u.mana < RAZE_MANA_COST and unit_mango_count(u) > 0 do
                u.mana = u.mana + 100
                u.mango_left = unit_mango_count(u) - 1
                u.mango_used = (u.mango_left <= 0)
                u.mango = (u.mango_left > 0)
            end
            if u.mana < RAZE_MANA_COST and (u.stick_charges or 0) > 0 and not u.stick_used then
                local g = u.stick_charges * 15
                u.mana = u.mana + g
                u.hp = math.min(u.hp_max, u.hp + g)
                u.stick_used = true
            end
            if u.mana >= RAZE_MANA_COST then
                local stacks = foe.stacks or 0
                local rawDmg = razeDamageFast(u.raze_level, stacks, u.souls, u.stack_talent, u.spell_amp)
                local dmg = razeAppliedFast(u.raze_level, stacks, u.souls, foe.magic_resist, u.stack_talent, u.spell_amp, 0)
                u.mana = u.mana - RAZE_MANA_COST
                u.raze_ready[idx] = now + RAZE_CD_DUR
                u.cast_until = now + RAZE_CAST_PT
                u.cast_label = idx
                u.razes_cast = (u.razes_cast or 0) + 1
                u.last_volley_at = now
                u.aim_x = foe.x + (foe.vx or 0) * RAZE_CAST_PT
                u.aim_y = foe.y + (foe.vy or 0) * RAZE_CAST_PT
                u.pending_raze = { t = now + RAZE_CAST_PT, idx = idx, dmg = dmg, raw_dmg = rawDmg, target = foe }
                return "raze"
            end
        end
    end

    if plan.flee then
        step_toward(u, plan.flee_x or u.x, plan.flee_y or u.y, dt, now)
        return "flee"
    end
    if foe and foe.alive then
        if plan.engage ~= false then
            if d > hold + 45 then
                local k = (d - hold) / d
                step_toward(u, u.x + (foe.x - u.x) * k, u.y + (foe.y - u.y) * k, dt, now)
            elseif d < hold - 120 then
                local k = (hold - d) / d
                step_toward(u, u.x - (foe.x - u.x) * k, u.y - (foe.y - u.y) * k, dt, now)
            end
        end
        if attackOn and d <= (u.atk_range or C.ATK_RANGE) + 25 and u.atk_until <= now then
            if start_attack(u, foe, now) then return "attack" end
        end
    end
    return "hold"
end

local EMPTY_PLAN = {}

local function apply_shots_inplace(q, t, victim)
    if not q then return end
    local n = #q
    if n == 0 then return end
    local w = 0
    for i = 1, n do
        local e = q[i]
        if e.t <= t then
            if victim.alive then
                victim.tower_hits = (victim.tower_hits or 0) + 1
                apply_damage(victim, e.dmg, t)
            end
        else
            w = w + 1
            if w ~= i then q[w] = e end
        end
    end
    for i = w + 1, n do q[i] = nil end
end

function WAR.Simulate(state, myPlan, hisPlan, horizon)
    horizon = horizon or C.HORIZON
    local t0 = state.t or 0
    local me = WAR.Prep(clone_unit(state.me))
    local him = WAR.Prep(clone_unit(state.him))
    local stkDurInit = C.STACK_DURATION
    if state.me_stacks ~= nil then me.stacks = state.me_stacks end
    if state.him_stacks ~= nil then him.stacks = state.him_stacks end
    if (me.stacks or 0) > 0 then
        local remM = state.me_stack_rem or me.stack_rem
        me.stack_t = (type(remM) == "number" and remM > 0) and (t0 - stkDurInit + m_min(stkDurInit, remM)) or t0
    end
    if (him.stacks or 0) > 0 then
        local remH = state.him_stack_rem or him.stack_rem
        him.stack_t = (type(remH) == "number" and remH > 0) and (t0 - stkDurInit + m_min(stkDurInit, remH)) or t0
    end
    -- Materialize in-progress native Shadowraze cast phases (`cast_left` + `cast_band`) into rollout state at `t0`:
    if (me.cast_left or 0) > 0.01 and me.cast_until <= t0 then
        me.cast_until = t0 + me.cast_left
        if me.cast_band and RAZE_DIST_TBL[me.cast_band] then
            me.cast_label = me.cast_band
            if not me.facing_set and him then
                me.facing = m_atan2(him.y - me.y, him.x - me.x)
            end
            me.pending_raze = { t = t0 + me.cast_left, idx = me.cast_band, target = him, live_cast = true }
        end
    end
    if (him.cast_left or 0) > 0.01 and him.cast_until <= t0 then
        him.cast_until = t0 + him.cast_left
        if him.cast_band and RAZE_DIST_TBL[him.cast_band] then
            him.cast_label = him.cast_band
            if not him.facing_set and me then
                him.facing = m_atan2(me.y - him.y, me.x - him.x)
            end
            him.pending_raze = { t = t0 + him.cast_left, idx = him.cast_band, target = me, live_cast = true }
        end
    end

    if (me.incoming or 0) > 0 then
        him.proj = { { t = t0 + (me.incoming_at or C.INCOMING_LAND), dmg = me.incoming, target = me } }
    end
    if (him.incoming or 0) > 0 then
        me.proj = { { t = t0 + (him.incoming_at or C.INCOMING_LAND), dmg = him.incoming, target = him } }
    end

    local mp = myPlan or EMPTY_PLAN
    local hp = hisPlan or EMPTY_PLAN
    local tower = state.tower
    local ownTower = state.own_tower
    local me0, him0 = me.hp, him.hp

    local dt = state.dt or C.DT
    local steps = math.floor(horizon / dt + 0.5)
    local aggroMe, aggroHim = false, false
    local windup = (tower and tower.windup) or C.TOWER_WINDUP
    local projSpeed = (tower and tower.proj_speed) or C.TOWER_PROJECTILE
    local ownWindup = (ownTower and ownTower.windup) or C.TOWER_WINDUP
    local ownProjSpeed = (ownTower and ownTower.proj_speed) or C.TOWER_PROJECTILE
    local qMe, qHim = nil, nil
    local function queue_shot(q, fire_t, dmg, dist, wu, ps)
        if not q then q = {} end
        q[#q + 1] = {
            t = fire_t + (wu or C.TOWER_WINDUP) + dist / math.max(1, ps or C.TOWER_PROJECTILE),
            dmg = dmg,
        }
        return q
    end

    local tFirst = (tower and tower.next_shot) or C.TOWER_FIRST
    local nextMe, nextHim = t0 + tFirst, t0 + C.TOWER_FIRST
    local waveAggroUntil = -1
    local aggroCdUntil = state.my_aggro_cd_until or 0
    local t = t0

    local enWave = state.enemy_wave
    local nWave = enWave and #enWave or 0
    local stkDur = C.STACK_DURATION
    local atkRangeDef = C.ATK_RANGE
    local twRangeDef = C.TOWER_RANGE
    local twLeashDef = C.TOWER_LEASH
    local twIntDef = C.TOWER_INTERVAL
    local twDmgDef = C.TOWER_DMG
    local crDpsMe = state.creep_dps_on_me or 0
    local crDpsHim = state.creep_dps_on_him or 0

    for i = 0, steps do
        t = t0 + i * dt
        if me.alive then
            local nh = me.hp + me.regen_hp * dt
            me.hp = nh < me.hp_max and nh or me.hp_max
        end
        if him.alive then
            local nh = him.hp + him.regen_hp * dt
            him.hp = nh < him.hp_max and nh or him.hp_max
        end

        if me.alive and him.alive then
            control(me, him, mp, t, dt)
            control(him, me, hp, t, dt)
            if nWave > 0 and mp.attack and distance(me.x, me.y, him.x, him.y) <= (me.atk_range or atkRangeDef) + 35 then
                if t >= aggroCdUntil then
                    local mx, my = me.x, me.y
                    for w = 1, nWave do
                        local cw = enWave[w]
                        local dxw, dyw = mx - cw.x, my - cw.y
                        if (dxw * dxw + dyw * dyw) <= 250000 then
                            local nxt = t + 2.3
                            if nxt > waveAggroUntil then waveAggroUntil = nxt end
                            aggroCdUntil = t + 3.0
                            break
                        end
                    end
                end
            end
        elseif me.alive then
            if mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
        elseif him.alive then
            if hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
        end

        if qMe then apply_shots_inplace(qMe, t, me) end
        if qHim then apply_shots_inplace(qHim, t, him) end
        resolve_pending_attack(me, t)
        resolve_pending_attack(him, t)
        -- Expire stale Shadowraze debuff stacks BEFORE `resolve_raze` so expired stacks never deal bonus coil damage!
        if t - me.stack_t > stkDur then me.stacks = 0 end
        if t - him.stack_t > stkDur then him.stacks = 0 end
        resolve_raze(me, t)
        resolve_raze(him, t)
        if me.proj then apply_projectiles(me, t) end
        if him.proj then apply_projectiles(him, t) end

        if me.alive then
            -- `v7.9.17-pro` (`REVIEW_7_9_16_RU.html` Exact `v7.9.14` Aggro-Reach Equivalence + Zero `sqrt`):
            --   1. Branch on `enWave ~= nil` (explicit empty wave `{}` = 0 lane creeps = 0 DPS; `nil` = `crDpsMe` fallback).
            --   2. Combine `cw.aggro_me` (`reach + 260`) and `aggActive` (`reach + chaseExtra`, up to `reach + 441`) via `m_max`
            --      so an already-aggroed creep (`cw.aggro_me == true`) NEVER loses `chaseExtra` reach at `406..586u`!
            if enWave ~= nil then
                if nWave > 0 then
                    local dynWaveDps = 0
                    local aggActive = (waveAggroUntil > t)
                    local chaseExtra = aggActive and (315 * m_min(1.4, m_max(0, t - t0))) or 0
                    local mx, my = me.x, me.y
                    local mpEng = mp.engage
                    for w = 1, nWave do
                        local cw = enWave[w]
                        local dxw, dyw = mx - cw.x, my - cw.y
                        local dSq = dxw * dxw + dyw * dyw
                        local reach = (cw.range or 100) + 45
                        local rAgg = 0
                        if cw.aggro_me then
                            rAgg = reach + 260
                            if aggActive then
                                local rChase = reach + chaseExtra
                                if rChase > rAgg then rAgg = rChase end
                            end
                        elseif aggActive then
                            rAgg = reach + chaseExtra
                        end
                        if rAgg > 0 and dSq <= rAgg * rAgg then
                            dynWaveDps = dynWaveDps + cw.dps
                        elseif mpEng then
                            local r3 = reach < 155 and reach or 155
                            if dSq <= r3 * r3 then dynWaveDps = dynWaveDps + cw.dps * 0.65 end
                        end
                    end
                    if dynWaveDps > 0 then apply_damage(me, dynWaveDps * dt, t) end
                end
            elseif crDpsMe > 0 then
                apply_damage(me, crDpsMe * dt, t)
            end
        end
        if him.alive and crDpsHim > 0 then
            apply_damage(him, crDpsHim * dt, t)
        end

        if tower and me.alive then
            local d = distance(me.x, me.y, tower.x, tower.y)
            if tower.aggro_me then aggroMe = true end
            if d <= (tower.range or twRangeDef) then aggroMe = true end
            if aggroMe and d > twLeashDef then aggroMe = false end
            if aggroMe and t >= nextMe then
                nextMe = t + (tower.interval or twIntDef)
                qMe = queue_shot(qMe, t, (tower.dmg or twDmgDef), d, windup, projSpeed)
            end
        end
        if ownTower and him.alive then
            local d = distance(him.x, him.y, ownTower.x, ownTower.y)
            if ownTower.aggro_me then aggroHim = true end
            if d <= (ownTower.range or twRangeDef) then aggroHim = true end
            if aggroHim and d > twLeashDef then aggroHim = false end
            if aggroHim and t >= nextHim then
                nextHim = t + (ownTower.interval or twIntDef)
                qHim = queue_shot(qHim, t, (ownTower.dmg or twDmgDef), d, ownWindup, ownProjSpeed)
            end
        end

        if not me.alive or not him.alive then
            for j = i + 1, steps do
                t = t0 + j * dt
                if me.alive and mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
                if him.alive and hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
                if tower and me.alive then
                    local d = distance(me.x, me.y, tower.x, tower.y)
                    if tower.aggro_me then aggroMe = true end
                    if d <= (tower.range or C.TOWER_RANGE) then aggroMe = true end
                    if aggroMe and d > C.TOWER_LEASH then aggroMe = false end
                    if aggroMe and t >= nextMe then
                        nextMe = t + (tower.interval or C.TOWER_INTERVAL)
                        qMe = queue_shot(qMe, t, (tower.dmg or C.TOWER_DMG), d, windup, projSpeed)
                    end
                    if qMe then apply_shots_inplace(qMe, t, me) end
                    if not me.alive then break end
                end
            end
            break
        end
    end

    local res = {
        my_hp = me.hp, his_hp = him.hp,
        my_dead = not me.alive, his_dead = not him.alive,
        dealt = him0 - him.hp,
        taken = me0 - me.hp,
        mana_left = me.mana,
        razes_cast = me.razes_cast or 0,
        my_x = me.x, my_y = me.y,
        his_x = him.x, his_y = him.y,
        t_end = t,
        horizon = horizon,
        tower_hits_taken = me.tower_hits or 0,
    }
    res.net = res.dealt - res.taken
    return res
end

--------------------------------------------------------------------------------
-- plan generation & minimax evaluation
--------------------------------------------------------------------------------
local DEFAULT_MY_PLANS = {
    { name = "hold500_none",  hold_dist = 500, raze_policy = "none",  engage = true, attack = true },
    { name = "hold500_trade", hold_dist = 500, raze_policy = "trade", engage = true, attack = true },
    { name = "hold500_burst", hold_dist = 500, raze_policy = "burst", engage = true, attack = true },
    { name = "hold700_none",  hold_dist = 700, raze_policy = "none",  engage = true, attack = true },
    { name = "hold700_trade", hold_dist = 700, raze_policy = "trade", engage = true, attack = true },
    { name = "hold700_burst", hold_dist = 700, raze_policy = "burst", engage = true, attack = true },
    { name = "hold260_none",  hold_dist = 260, raze_policy = "none",  engage = true, attack = true },
    { name = "hold260_trade", hold_dist = 260, raze_policy = "trade", engage = true, attack = true },
    { name = "hold260_burst", hold_dist = 260, raze_policy = "burst", engage = true, attack = true },
}

local DEFAULT_HIS_PLANS = {
    { name = "aggressive", hold_dist = 320, raze_policy = "burst", engage = true, attack = true, adaptive = true },
    { name = "reactive",   hold_dist = 440, raze_policy = "trade", engage = true, attack = true,
      adaptive = true, cancel_dodge = true, raze_quality = "lock" },
    { name = "passive",    hold_dist = 700, raze_policy = "none",  engage = false, attack = true },
}

function WAR.MyPlans(_state, opts)
    opts = opts or {}
    if not opts.holds and not opts.pols and not opts.flee_points then
        return DEFAULT_MY_PLANS
    end
    local plans = {}
    if not opts.holds and not opts.pols then
        for i = 1, 9 do plans[i] = DEFAULT_MY_PLANS[i] end
    else
        -- Order `500, 700, 260` + `"none", "trade", "burst"` so equal-utility ties (e.g. 0 razes / OOM!)
        -- ALWAYS resolve to `hold500_none` (`HOLD` at max attack range) instead of `hold250_burst` (`W2 02:28` fix)!
        local holds = opts.holds or { 500, 700, 260 }
        local pols = opts.pols or { "none", "trade", "burst" }
        for _, h in ipairs(holds) do
            for _, p in ipairs(pols) do
                plans[#plans + 1] = {
                    name = string.format("hold%d_%s", h, p),
                    hold_dist = h, raze_policy = p, engage = true, attack = true,
                }
            end
        end
    end
    if opts.flee_points then
        for i, fp in ipairs(opts.flee_points) do
            plans[#plans + 1] = {
                name = "flee" .. i, flee = true, flee_x = fp.x, flee_y = fp.y,
                raze_policy = opts.flee_pol or "lethal", attack = false, engage = false,
            }
        end
    end
    return plans
end

function WAR.HisPlans(state, opts)
    opts = opts or {}
    local hf = opts.his_flee or state.his_flee
    if not hf then return DEFAULT_HIS_PLANS end
    return {
        DEFAULT_HIS_PLANS[1],
        DEFAULT_HIS_PLANS[2],
        DEFAULT_HIS_PLANS[3],
        {
            name = "retreat_tower", flee = true, flee_x = hf.x, flee_y = hf.y,
            attack = false, engage = false, raze_policy = "lethal",
        },
    }
end

local function utility(state, res)
    local me, him = state.me, state.him
    local u = 0
    if res.my_dead then
        u = u - C.DEATH_COST
    elseif res.my_hp < C.SAFE_HP_ABS then
        u = u - (C.SAFE_HP_ABS - res.my_hp) * 1.35
    end
    if res.his_dead then u = u + C.KILL_BONUS end
    u = u + C.W_HP * ((him.hp - res.his_hp) - (me.hp - res.my_hp))
    u = u + C.W_MANA * (res.mana_left - me.mana)
    local mePct = res.my_hp / math.max(1, me.hp_max)
    local himTrueMax = math.max(1, him.true_hp_max or him.hp_max)
    local himScale = himTrueMax / math.max(1, him.hp_max)
    local himPct = (res.his_hp * himScale) / himTrueMax
    u = u + C.W_STAND * (mePct - himPct) * math.max(me.hp_max, himTrueMax)
    return u
end
WAR.Utility = utility

function WAR.Evaluate(state, opts)
    opts = opts or {}
    local myPlans = WAR.MyPlans(state, opts)
    local hisPlans = WAR.HisPlans(state, opts)
    local horizon = opts.horizon or C.HORIZON
    state.dt = opts.dt or C.DT

    local scored = {}
    local simFn = WAR.Simulate
    for _, mp in ipairs(myPlans) do
        local worst, best, sum, n = nil, nil, 0, 0
        local worstUtil = 1e18
        local bestUtil = -1e18
        local dieCount = 0
        local killAll = true
        for _, hp in ipairs(hisPlans) do
            local r = simFn(state, mp, hp, horizon)
            local u = utility(state, r)
            sum = sum + u; n = n + 1
            if u < worstUtil then worstUtil = u; worst = r end
            if not best or u > bestUtil then bestUtil = u; best = r end
            if r.my_dead then dieCount = dieCount + 1 end
            if not r.his_dead then killAll = false end
        end
        scored[#scored + 1] = {
            plan = mp,
            worstUtil = worstUtil,
            avgUtil = sum / n,
            worst = worst,
            best = best,
            dieCount = dieCount,
            dieProb = dieCount / n,
            killAll = killAll,
        }
    end

    for _, s in ipairs(scored) do
        if s.dieCount == 0 and s.killAll then
            return {
                mode = "KILL", plan = s.plan, ev = s.worst,
                worst = s.worst, score = s.worstUtil,
                why = "guaranteed kill under every enemy response",
            }
        end
    end

    local bestSafe
    for _, s in ipairs(scored) do
        if s.dieCount == 0 and (not bestSafe or s.worstUtil > bestSafe.worstUtil) then
            bestSafe = s
        end
    end

    if not bestSafe then
        local lowest = 1
        for _, s in ipairs(scored) do if s.dieProb < lowest then lowest = s.dieProb end end
        local cand
        for _, s in ipairs(scored) do
            if s.dieProb <= lowest + 1e-9 and (not cand or s.worstUtil > cand.worstUtil) then cand = s end
        end
        if cand and cand.dieProb > 0 then
            return {
                mode = "ESCAPE", plan = cand.plan, ev = cand.worst, worst = cand.worst,
                score = cand.worstUtil, danger = true,
                why = "every plan risks death: minimise loss",
            }
        end
    end

    local s = bestSafe
    local mode = "HOLD"
    -- NEVER emit `TRADE` on a plan that casts 0 Razes (`W2 02:28` dry-mana 6 MP suicide fix!):
    if (s.plan.raze_policy == "burst" or s.plan.raze_policy == "trade" or s.plan.raze_policy == "lethal")
        and (s.worst.razes_cast or 0) > 0 then
        mode = "TRADE"
    end
    if s.plan.flee then mode = "ESCAPE" end

    if mode == "TRADE" and (s.worst.his_hp - s.worst.my_hp) <= 0 and (s.worst.net or 0) <= 0 then
        for _, c in ipairs(scored) do
            if c.dieCount == 0 and c.plan.raze_policy == "none" and c.worstUtil > s.worstUtil then
                s = c; mode = "HOLD"; break
            end
        end
    end

    return {
        mode = mode, plan = s.plan, ev = s.worst, worst = s.worst,
        avg = s.avgUtil, score = s.worstUtil,
        why = "best worst-case safe plan",
    }
end

function WAR.SelfTest()
    local fails = {}
    local function check(name, got, want, tol)
        tol = tol or 1e-6
        if math.abs(got - want) > tol then
            fails[#fails + 1] = string.format("%s: got %.3f want %.3f", name, got, want)
        end
    end
    -- Patch 7.41f: L1 base 85 * 0.75 = 63.75
    check("raze L1 base 7.41f", WAR.RazeApplied(1, 0, 0, 0.25), 63.75)
    -- Patch 7.41f: L4 base 280 + 2*80 + 10*2 = 460 * 0.75 = 345.0
    check("raze L4 stacked 7.41f", WAR.RazeApplied(4, 2, 10, 0.25), 345.0)
    -- Patch 7.41f: volley of 3 at L3 (215/65), 8 souls (+16): (231 + 296 + 361) * 0.75 = 666.0
    check("volley3 7.41f", WAR.VolleyDamage(3, 0, 8, 3, 0.25), 666.0)
    return #fails == 0, fails
end

return WAR
