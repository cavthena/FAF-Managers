-- Created by Ruanuku/Cavthena
-- AI Unit Spawner (direct spawn, wave & loss-gated modes)
--
-- What it does
--   • Spawns a platoon at a given marker using a composition { {bp, {e,n,h}, [label]}, ... }
--   • Hands the platoon to your attack function immediately (ForkAIThread)
--   • Two modes:
--       1) Wave: spawn → handoff → wait waveCooldown → next wave
--       2) Loss-gated: spawn → handoff → wait until the platoon has lost >= mode2LossThreshold → next wave,
--          and if (and only if) the current platoon has been wiped out, apply waveCooldown before spawning again.
--   • Can be cancelled at any time via Stop(handle)
--   • Safe to run multiple spawners in parallel (unique tag per instance; no shared state)
--
-- Public API
--   local Spawner = import('/maps/.../manager_UnitSpawner.lua')
--   local handle = Spawner.Start{
--     brain              = ArmyBrains[ScenarioInfo.Cybran],
--     spawnMarker        = 'AREA2_NORTHATTACK_SPAWNER',
--     composition        = {
--         {'url0106', {3, 4, 5}, 'LABs'},
--         {'url0107', {2, 3, 4}, 'LTs'},
--     },
--     difficulty         = ScenarioInfo.Options.Difficulty or 2,  -- 1..3
--     attackFn           = 'Platoon_BasicAttack',                 -- function or global function name
--     waveCooldown       = 15,                                    -- seconds; in mode 2 it is applied only after a wipe
--     mode               = 1,                                     -- 1: cooldown, 2: gate by losses
--     mode2LossThreshold = 0.50,                                  -- fraction lost to trigger next wave
--     spawnerTag         = 'NorthWaves',                          -- optional unique tag
--     spawnSpread        = 6,                                     -- random XY spread around marker
--     formation          = 'GrowthFormation',                     -- assigned formation
--     debug              = false,
--   }
--   Spawner.Stop(handle)

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

-- ========== small helpers ==========
local function copyComposition(comp)
    local out = {}
    for i, entry in ipairs(comp or {}) do
        local bp    = entry[1]
        local cnt   = entry[2]
        local label = entry[3]
        local cntcopy = cnt
        if type(cnt) == 'table' then
            cntcopy = { cnt[1] or 0, cnt[2] or (cnt[1] or 0), cnt[3] or (cnt[2] or cnt[1] or 0) }
        end
        out[i] = { bp, cntcopy, label }
    end
    return out
end

local function normalizeParams(p)
    return {
        brain              = p.brain,
        spawnMarker        = p.spawnMarker,
        composition        = copyComposition(p.composition),
        difficulty         = p.difficulty or 2,
        attackFn           = p.attackFn,
        waveCooldown       = p.waveCooldown or 0,
        mode               = p.mode or 1,
        mode2LossThreshold = (p.mode2LossThreshold ~= nil) and p.mode2LossThreshold or 0.5,
        spawnerTag         = p.spawnerTag,
        spawnSpread        = (p.spawnSpread ~= nil) and p.spawnSpread or 6,
        formation          = p.formation or 'GrowthFormation',
        debug              = p.debug and true or false,
    }
end

local function flattenCounts(composition, difficulty)
    local wanted, order = {}, {}
    local d = math.max(1, math.min(3, difficulty or 2))
    for _, entry in ipairs(composition or {}) do
        local bp   = entry[1]
        local cnt  = entry[2]
        local want = (type(cnt) == 'table') and cnt[d] or cnt
        if want and want > 0 then
            want = math.floor(want)
            if want > 0 then
                wanted[bp] = (wanted[bp] or 0) + want
                table.insert(order, bp)
            end
        end
    end
    return wanted, order
end

local function markerPos(mark)
    return mark and ScenarioUtils.MarkerToPosition(mark) or nil
end

local function isComplete(u)
    if not u or u.Dead then return false end
    if u.GetFractionComplete and u:GetFractionComplete() < 1 then return false end
    if u.IsUnitState and u:IsUnitState('BeingBuilt') then return false end
    return true
end

local function countComplete(units)
    local n = 0
    if not units then return 0 end
    for _, u in ipairs(units) do if isComplete(u) then n = n + 1 end end
    return n
end

local function sumCounts(tbl)
    local s = 0
    for _, n in pairs(tbl or {}) do s = s + (n or 0) end
    return s
end

-- ========== class ==========
local Spawner = {}
Spawner.__index = Spawner

function Spawner:Log(msg) LOG(('[US:%s] %s'):format(self.tag, msg)) end
function Spawner:Warn(msg) WARN(('[US:%s] %s'):format(self.tag, msg)) end
function Spawner:Dbg(msg) if self.params.debug then self:Log(msg) end end

-- spawn a single wave and return the platoon
function Spawner:SpawnWave(waveNo)
    local pos = self.spawnPos
    if not pos then
        self:Warn('SpawnWave: invalid spawnMarker position')
        return nil
    end

    local spawned = {}
    local spread  = math.max(0, self.params.spawnSpread or 0)
    for bp, count in pairs(self.wanted or {}) do
        for i = 1, count do
            local ox = (spread > 0) and (Random() * 2 - 1) * spread or 0
            local oz = (spread > 0) and (Random() * 2 - 1) * spread or 0
            local u = CreateUnitHPR(bp, self.brain:GetArmyIndex(), pos[1] + ox, pos[2], pos[3] + oz, 0, 0, 0)
            if u then
                u.us_tag = self.tag
                table.insert(spawned, u)
            else
                self:Warn(('SpawnWave: failed to create unit bp=%s'):format(tostring(bp)))
            end
        end
    end

    local label = string.format('%s_Wave_%d', self.tag, waveNo or 1)
    local p = self.brain:MakePlatoon(label, '')
    if table.getn(spawned) > 0 then
        self.brain:AssignUnitsToPlatoon(p, spawned, 'Attack', self.params.formation or 'GrowthFormation')
    end

    -- handoff to attack AI
    if self.params.attackFn then
        local function _AttackWrapper(platoon, fn)
            self:Dbg(('AttackWrapper: label=%s units=%d fnType=%s')
                :format((platoon.GetPlatoonLabel and platoon:GetPlatoonLabel()) or '?',
                        table.getn(platoon:GetPlatoonUnits() or {}),
                        type(fn)))
            if type(fn) == 'function' then
                return fn(platoon)
            elseif type(fn) == 'string' then
                local ref = _G and _G[fn] or nil
                if type(ref) == 'function' then
                    return ref(platoon)
                else
                    self:Warn('AttackWrapper: string attackFn not found in _G: '.. tostring(fn))
                end
            else
                self:Warn('AttackWrapper: attackFn is not callable: '.. tostring(fn))
            end
        end
        p:ForkAIThread(_AttackWrapper, self.params.attackFn)
    else
        self:Warn('No attackFn provided; spawned platoon will idle.')
    end

    self:Dbg(('SpawnWave: spawned %d units as %s'):format(table.getn(spawned), label))
    return p
end

function Spawner:WaitForLossGate(platoon)
    local thr = math.max(0, math.min(1, self.params.mode2LossThreshold or 0.5))
    local wantTotal = sumCounts(self.wanted)
    while not self.stopped do
        if not platoon or not self.brain:PlatoonExists(platoon) then
            self:Dbg('Mode2Gate: platoon gone; gate passed')
            return
        end
        local alive = countComplete(platoon:GetPlatoonUnits() or {})
        local lost = math.max(0, wantTotal - alive)
        local frac = (wantTotal > 0) and (lost / wantTotal) or 1
        self:Dbg(('Mode2Gate: alive=%d lost=%d frac=%.2f thr=%.2f'):format(alive, lost, frac, thr))
        if frac >= thr then return end
        WaitSeconds(2)
    end
end

local function PlatoonIsDead(brain, platoon)
    if not platoon then return true end
    if not brain:PlatoonExists(platoon) then return true end
    local units = platoon:GetPlatoonUnits() or {}
    return countComplete(units) == 0
end

function Spawner:MainLoop()
    self:Dbg('MainLoop: start')
    while not self.stopped do
        self.wave = (self.wave or 0) + 1
        local p = self:SpawnWave(self.wave)

        local mode = self.params.mode or 1
        if mode == 2 then
            -- Gate the *next* wave by losses of the current one
            self:WaitForLossGate(p)

            -- Only apply cooldown once the current platoon is fully dead (wiped).
            -- This preserves overlap behavior while preventing instant respawns on wipes.
            if PlatoonIsDead(self.brain, p) then
                WaitSeconds(math.max(0, self.params.waveCooldown or 0))
            end
        else
            WaitSeconds(math.max(0, self.params.waveCooldown or 0))
        end
    end
    self:Dbg('MainLoop: end')
end

function Spawner:Start()
    self.mainThread = self.brain:ForkThread(function() self:MainLoop() end)
end

function Spawner:Stop()
    if self.stopped then return end
    self.stopped = true
    if self.mainThread then
        KillThread(self.mainThread)
        self.mainThread = nil
    end
end

-- ========== Public API ==========
function Start(params)
    assert(params and params.brain and params.spawnMarker, 'brain and spawnMarker are required')
    local o = setmetatable({}, Spawner)
    o.params   = normalizeParams(params)
    o.brain    = o.params.brain
    o.tag      = params.spawnerTag or ('US_'.. math.floor(100000 * Random()))
    o.spawnPos = markerPos(o.params.spawnMarker)
    if not o.spawnPos then
        error('Invalid spawnMarker: '.. tostring(o.params.spawnMarker))
    end
    o.stopped  = false
    o.wanted, o.bpOrder = flattenCounts(o.params.composition, o.params.difficulty)
    o.wave = 0
    o:Start()
    return o
end

function Stop(handle)
    if handle and handle.Stop then handle:Stop() end
end
