-- Created by Ruanuku/Cavthena
-- AI Unit Spawner (direct spawn, wave, loss-gated & wave-count modes)
--
-- What it does
--   • Spawns a platoon at a given marker using a composition { {bp, {e,n,h}, [label], [waveStart]}, ... }
--   • Hands the platoon to your attack function immediately (ForkAIThread)
--   • Four modes:
--       1) Wave: spawn → handoff → wait waveCooldown → next wave
--       2) Loss-gated: spawn → handoff → wait until the platoon has lost >= mode2LossThreshold → next wave,
--          and if (and only if) the current platoon has been wiped out, apply waveCooldown before spawning again.
--       3) Limited waves: spawn → handoff → wait a shrinking waveCooldown → next wave, until mode3WaveCount is reached.
--          Composition entries can specify the wave they join via a 4th field (wave start, 1-indexed).
--       4) Batched window: spawn a fixed number of platoons (mode4PlatoonCount) evenly spaced over waveCooldown, then stop.
--   • Can be cancelled at any time via Stop(handle)
--   • Safe to run multiple spawners in parallel (unique tag per instance; no shared state)
--
-- Public API
--   local Spawner = import('/maps/.../manager_UnitSpawner.lua')
--   local handle = Spawner.Start{
--     brain              = ArmyBrains[ScenarioInfo.Cybran],
--     spawnMarker        = 'AREA2_NORTHATTACK_SPAWNER',
--     composition        = {
--         {'url0106', {3, 4, 5}, 'LABs', 1},
--         {'url0107', {2, 3, 4}, 'LTs', 2},
--     },
--     difficulty         = ScenarioInfo.Options.Difficulty or 2,  -- 1..3
--     attackFn           = 'Platoon_BasicAttack',                 -- function or global function name
--     waveCooldown       = 15,                                    -- seconds; in mode 2 it is applied only after a wipe
--     mode               = 1,                                     -- 1: cooldown, 2: gate by losses, 3: finite waves, 4: batched waves
--     mode2LossThreshold = 0.50,                                  -- fraction lost to trigger next wave
--     mode3WaveCount     = 5,                                     -- number of waves for mode 3
--     mode4PlatoonCount  = 3,                                     -- platoons per cooldown window for mode 4
--     spawnerTag         = 'NorthWaves',                          -- optional unique tag
--     spawnSpread        = 6,                                     -- random XY spread around marker
--     formation          = 'GrowthFormation',                     -- assigned formation
--     escalationPercent  = 0,                                     -- optional percent increase applied cumulatively per escalationFrequency
--     escalationFrequency= 0,                                     -- optional waves between each escalation step (1 = every wave)
--     debug              = false,
--   }
--
-- Callbacks can be added at any time (before or after Start) just like unit callbacks:
--   handle:AddCallback(fn, 'OnWaveCreated')
--   handle:AddCallback(fn, 'OnWaveNumber', targetWaveNumber)   -- targetWaveNumber is required for this event
--   handle:AddCallback(fn, 'OnSpawnerComplete')
--   handle:AddCallback(fn, 'OnMode2ThresholdMet')
-- Optional callbacks (function handle or global function name). They are skipped when nil/false.
--   OnWaveCreated(spawner, waveIndex, platoon, unitCount, wanted)
--       • Returns true by default; return false to stop the spawner after the callback finishes.
--       • Use this to gate later waves based on scenario logic or to confirm creation.
--   OnWaveNumber(spawner, waveIndex, platoon, unitCount, wanted)
--       • Invoked only when the wave number matches the callback’s registered target wave. Returns true by default.
--   OnSpawnerComplete(spawner, mode, waveCount)
--       • Invoked when mode 3 or mode 4 finishes normally. Returns true by default.
--   OnMode2ThresholdMet(spawner, platoon, aliveCount, expectedCount, threshold)
--       • Invoked in mode 2 when the loss-gated threshold is met. Returns true by default.
-- Example defaults (no custom behaviour):
--   OnWaveCreated    = nil
--   OnWaveNumber     = nil
--   OnSpawnerComplete = nil
--   OnMode2ThresholdMet = nil
--   Spawner.Stop(handle)

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

-- ========== small helpers ==========
 local function normalizeCounts(cnt)
     if type(cnt) == 'table' then
         return { cnt[1] or 0, cnt[2] or (cnt[1] or 0), cnt[3] or (cnt[2] or cnt[1] or 0) }
     end
     local value = cnt or 0
     return { value, value, value }
 end
 
 local function normalizeComposition(comp)
     local out = {}
     for i, entry in ipairs(comp or {}) do
         local bp        = entry[1]
         local cnt       = normalizeCounts(entry[2])
         local label     = entry[3]
         local waveStart = entry[4]

        if type(label) == 'number' and waveStart == nil then
            waveStart = label
            label     = nil
        end
        waveStart = waveStart or 1

         out[i] = {
             blueprint = bp,
             counts    = cnt,
             label     = label,
             waveStart = math.max(1, math.floor(waveStart)),
         }
     end
     return out
 end

local function escalationFactor(params, waveNo)
    local pct   = math.max(0, params and params.escalationPercent or 0)
    local every = math.floor(params and params.escalationFrequency or 0)
    if pct <= 0 or every <= 0 then return 1 end

    local wave = math.max(1, waveNo or 1)
    local steps = math.floor((wave - 1) / every)
    if steps <= 0 then return 1 end

    return (1 + pct / 100) ^ steps
end

local function markerPos(mark)
    if not mark then return nil end
    local t = type(mark)
    if t == 'string' then
        return ScenarioUtils.MarkerToPosition(mark)
    elseif t == 'table' then
        -- Marker table from ScenarioUtils.GetMarker(...)
        if mark.position then return mark.position end
        if mark.Position then return mark.Position end
        if mark.Pos      then return mark.Pos end
        -- Raw {x,y,z}
        if type(mark[1])=='number' and type(mark[2])=='number' and type(mark[3])=='number' then
            return mark
        end
    end
    return nil
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
 
local function tableIsEmpty(tbl)
    if not tbl then return true end
    for _ in pairs(tbl) do
        return false
    end
    return true
end

local function resolveCallback(cb)
    if type(cb) == 'function' then
        return cb
    elseif type(cb) == 'string' then
        local ref = _G and _G[cb]
        if type(ref) == 'function' then
            return ref
        end
    end
    return nil
end

local function resolveUnitCount(units)
    if type(units) == 'table' then
        return table.getn(units)
    elseif type(units) == 'number' then
        return math.max(0, math.floor(units))
    end
    return 0
end

local function resolveSpawnList(spawnMarker)
    local out = {}

    local function addOne(m)
        local p = markerPos(m)
        if p then table.insert(out, p) end
    end

    if type(spawnMarker) == 'table' then
        -- Heuristic: if it looks like a single marker/position table, treat as one.
        local looksLikeSingle =
            spawnMarker.position or spawnMarker.Position or spawnMarker.Pos or
            (type(spawnMarker[1])=='number' and type(spawnMarker[2])=='number' and type(spawnMarker[3])=='number' and spawnMarker[4]==nil)

        if looksLikeSingle then
            addOne(spawnMarker)
        else
            for i = 1, table.getn(spawnMarker) do
                addOne(spawnMarker[i])
            end
        end
    else
        addOne(spawnMarker)
    end

    return out
end

local function _PickIndex(n, avoid)
    local i = math.floor(Random() * n) + 1
    if n > 1 and i == avoid then
        i = (i == n) and 1 or (i + 1)
    end
    return i
end

-- ========== class ==========
local Spawner = {}
Spawner.__index = Spawner

function Spawner:Log(msg) LOG(('[US:%s] %s'):format(self.tag, msg)) end
 function Spawner:Warn(msg) WARN(('[US:%s] %s'):format(self.tag, msg)) end
 function Spawner:Dbg(msg) if self.params.debug then self:Log(msg) end end
 
 function Spawner:GetEntryCount(entry)
     local d = math.max(1, math.min(3, self.params.difficulty or 2))
     local want = entry.counts[d] or 0
     want = math.max(0, math.floor(want))
     return want
 end
 
function Spawner:GetEscalationFactor(waveNo)
    return escalationFactor(self.params, waveNo)
end

function Spawner:GetNextSpawnPos()
    local list = self.spawnPositions or {}
    local n = table.getn(list)
    if n == 0 then return nil end
    if n == 1 then
        self.lastSpawnIndex = 1
        return list[1]
    end
    local idx = _PickIndex(n, self.lastSpawnIndex or 0)
    self.lastSpawnIndex = idx
    return list[idx]
end

function Spawner:BuildWantedForWave(waveNo)
    local wanted = {}
    local factor = self:GetEscalationFactor(waveNo or 1)
    for _, entry in ipairs(self.composition) do
        if not waveNo or (self.params.mode == 3 and waveNo >= entry.waveStart) or (self.params.mode ~= 3) then
            local count = self:GetEntryCount(entry)
            if factor ~= 1 then
                count = math.max(0, math.floor(count * factor))
            end
            if count > 0 then
                wanted[entry.blueprint] = (wanted[entry.blueprint] or 0) + count
            end
        end
    end
    return wanted
end

function Spawner:CreatePlatoon(label, units)
    local platoon = self.brain:MakePlatoon(label, '')
    if units and table.getn(units) > 0 then
        self.brain:AssignUnitsToPlatoon(platoon, units, 'Attack', self.params.formation or 'GrowthFormation')
    end
    return platoon
end

function Spawner:AddCallback(cb, eventName, eventData)
    if not cb or not eventName then
        return
    end
    self.callbacks = self.callbacks or {}
    self.callbacks[eventName] = self.callbacks[eventName] or {}
    table.insert(self.callbacks[eventName], { fn = cb, data = eventData })
end

local function _CallbackEntry(cb)
    if type(cb) == 'table' then
        return cb.fn or cb[1], cb.data or cb[2]
    end
    return cb, nil
end

function Spawner:InvokeBooleanCallbacks(eventName, defaultReturn, a, b, c, d, e)
    local list = self.callbacks and self.callbacks[eventName]
    if not list or table.getn(list) == 0 then
        return defaultReturn
    end

    local result = defaultReturn
    for _, cb in ipairs(list) do
        local fn, data = _CallbackEntry(cb)
        local shouldProcess = true
        if eventName == 'OnWaveNumber' and data ~= nil and data ~= a then
            shouldProcess = false
        end

        if shouldProcess then
            fn = resolveCallback(fn)
            if not fn then
                self:Warn(('Callback %s is not callable: %s'):format(eventName, tostring(cb)))
            else
                local ok, r1 = pcall(fn, self, a, b, c, d, e)
                if not ok then
                    self:Warn(('Callback %s failed: %s'):format(eventName, tostring(r1)))
                elseif r1 ~= nil then
                    if r1 == false then
                        result = false
                    elseif result ~= false then
                        result = r1
                    end
                end
            end
        end
    end
    return result
end

function Spawner:RegisterInitialCallbacks()
    local initial = {
        OnWaveCreated        = self.params.onWaveCreated or self.params.OnWaveCreated,
        OnWaveNumber         = self.params.onWaveNumber or self.params.OnWaveNumber,
        OnSpawnerComplete    = self.params.onSpawnerComplete or self.params.OnSpawnerComplete,
        OnMode2ThresholdMet  = self.params.onMode2ThresholdMet or self.params.OnMode2ThresholdMet,
    }

    for eventName, cb in pairs(initial) do
        if cb then
            self:AddCallback(cb, eventName)
        end
    end
end


function Spawner:HandOffToAttack(platoon)
    if not self.params.attackFn then
        self:Warn('No attackFn provided; spawned platoon will idle.')
        return
    end
 
     local function _AttackWrapper(p, fn)
         self:Dbg(('AttackWrapper: label=%s units=%d fnType=%s')
             :format((p.GetPlatoonLabel and p:GetPlatoonLabel()) or '?',
                     table.getn(p:GetPlatoonUnits() or {}),
                     type(fn)))
        if type(fn) == 'function' then
            return fn(p, self.params.attackData)
        elseif type(fn) == 'string' then
            local ref = _G and _G[fn]
            if type(ref) == 'function' then
                return ref(p, self.params.attackData)
            else
                self:Warn('AttackWrapper: string attackFn not found in _G: '.. tostring(fn))
            end
        else
            self:Warn('AttackWrapper: attackFn is not callable: '.. tostring(fn))
        end
     end
 
     platoon:ForkAIThread(_AttackWrapper, self.params.attackFn)
 end
 
function Spawner:SpawnWave(waveNo, wanted)
    local pos = self:GetNextSpawnPos()
    if not pos then
        self:Warn('SpawnWave: invalid spawnMarker position')
        return nil, 0
     end
 
    local spawned = {}
    local spread  = math.max(0, self.params.spawnSpread or 0)
    for bp, count in pairs(wanted or {}) do
        for _ = 1, count do
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
    local platoon = self:CreatePlatoon(label, spawned)

    self:HandOffToAttack(platoon)

    local unitCount = resolveUnitCount(spawned)
    self:Dbg(('SpawnWave: spawned %d units as %s'):format(unitCount, label))
    return platoon, spawned, unitCount, wanted
end
 
 function Spawner:WaitForLossGate(platoon, expectedCount)
     local thr = math.max(0, math.min(1, self.params.mode2LossThreshold or 0.5))
     local wantTotal = expectedCount or 0
     if wantTotal <= 0 then
         return
     end
 
     while not self.stopped do
        if not platoon or not self.brain:PlatoonExists(platoon) then
            local alive = countComplete((platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits()) or {})
            self:Dbg('Mode2Gate: platoon gone; gate passed')
            self:InvokeBooleanCallbacks('OnMode2ThresholdMet', true, platoon, alive, wantTotal, thr)
            return
        end
         local alive = countComplete(platoon:GetPlatoonUnits() or {})
         local lost = math.max(0, wantTotal - alive)
         local frac = (wantTotal > 0) and (lost / wantTotal) or 1
         self:Dbg(('Mode2Gate: alive=%d lost=%d frac=%.2f thr=%.2f'):format(alive, lost, frac, thr))
        if frac >= thr then
            self:InvokeBooleanCallbacks('OnMode2ThresholdMet', true, platoon, alive, wantTotal, thr)
            return
        end
         WaitSeconds(2)
     end
 end
 
 local function PlatoonIsDead(brain, platoon)
     if not platoon then return true end
     if not brain:PlatoonExists(platoon) then return true end
     local units = platoon:GetPlatoonUnits() or {}
     return countComplete(units) == 0
 end
 
 function Spawner:GetMode3Cooldown(waveIndex, totalWaves)
     local base = math.max(0, self.params.waveCooldown or 0)
     local intervals = math.max(0, totalWaves - 1)
     if intervals <= 0 then
         return 0
     end
     local decrement = base / intervals
     local remaining = math.max(0, base - decrement * (waveIndex - 1))
     return remaining
 end
 
function Spawner:RunMode1()
    while not self.stopped do
        self.wave = (self.wave or 0) + 1
        local platoon, units, unitCount, wanted = self:SpawnWave(self.wave, self:BuildWantedForWave(self.wave))
        local keepRunning = self:InvokeBooleanCallbacks('OnWaveNumber', true, self.wave, platoon, unitCount, wanted)
        if keepRunning ~= false then
            keepRunning = self:InvokeBooleanCallbacks('OnWaveCreated', keepRunning, self.wave, platoon, unitCount, wanted)
        end
        if keepRunning == false then
            self:Stop()
            break
        end
        WaitSeconds(math.max(0, self.params.waveCooldown or 0))
    end
end

function Spawner:RunMode2()
    while not self.stopped do
        self.wave = (self.wave or 0) + 1
        local platoon, units, unitCount, wanted = self:SpawnWave(self.wave, self:BuildWantedForWave(self.wave))
        local keepRunning = self:InvokeBooleanCallbacks('OnWaveNumber', true, self.wave, platoon, unitCount, wanted)
        if keepRunning ~= false then
            keepRunning = self:InvokeBooleanCallbacks('OnWaveCreated', keepRunning, self.wave, platoon, unitCount, wanted)
        end
        if keepRunning == false then
            self:Stop()
        end
        if self.stopped then break end
        self:WaitForLossGate(platoon, unitCount)
        if self.stopped then break end
        if PlatoonIsDead(self.brain, platoon) then
            WaitSeconds(math.max(0, self.params.waveCooldown or 0))
        end
    end
end

function Spawner:RunMode3()
    local totalWaves = math.max(0, math.floor(self.params.mode3WaveCount or 0))
     if totalWaves <= 0 then
         self:Warn('Mode 3 selected but mode3WaveCount <= 0; stopping spawner.')
         return
     end
 
     for wave = 1, totalWaves do
         if self.stopped then break end
         self.wave = wave
        local wanted = self:BuildWantedForWave(wave)
        if tableIsEmpty(wanted) then
            self:Dbg(('Mode3: wave %d has no units to spawn'):format(wave))
        end
        local platoon, units, unitCount, usedWanted = self:SpawnWave(wave, wanted)
        local keepRunning = self:InvokeBooleanCallbacks('OnWaveNumber', true, wave, platoon, unitCount, usedWanted)
        if keepRunning ~= false then
            keepRunning = self:InvokeBooleanCallbacks('OnWaveCreated', keepRunning, wave, platoon, unitCount, usedWanted)
        end
        if keepRunning == false then
            self:Stop()
            break
        end
        if wave < totalWaves and not self.stopped then
            local cooldown = self:GetMode3Cooldown(wave, totalWaves)
            if cooldown > 0 then
                WaitSeconds(cooldown)
            end
        end
    end
    if not self.stopped then
        self:InvokeBooleanCallbacks('OnSpawnerComplete', true, 3, totalWaves)
    end
    self.stopped = true
end

function Spawner:RunMode4()
    local batchCount = math.max(1, math.floor(self.params.mode4PlatoonCount or 1))
    local totalWindow = math.max(0, self.params.waveCooldown or 0)
    local interval = (batchCount > 0) and (totalWindow / batchCount) or 0

    for _ = 1, batchCount do
        if self.stopped then break end
        self.wave = (self.wave or 0) + 1
        local platoon, units, unitCount, wanted = self:SpawnWave(self.wave, self:BuildWantedForWave(self.wave))
        local keepRunning = self:InvokeBooleanCallbacks('OnWaveNumber', true, self.wave, platoon, unitCount, wanted)
        if keepRunning ~= false then
            keepRunning = self:InvokeBooleanCallbacks('OnWaveCreated', keepRunning, self.wave, platoon, unitCount, wanted)
        end
        if keepRunning == false then
            self:Stop()
        end
        if self.stopped then break end
        if interval > 0 then
            WaitSeconds(interval)
        end
    end
    if not self.stopped then
        self:InvokeBooleanCallbacks('OnSpawnerComplete', true, 4, self.wave or batchCount)
    end
    self.stopped = true
end
 
function Spawner:MainLoop()
    self:Dbg('MainLoop: start')
    local mode = self.params.mode or 1
    if mode == 2 then
        self:RunMode2()
    elseif mode == 3 then
        self:RunMode3()
    elseif mode == 4 then
        self:RunMode4()
    else
        self:RunMode1()
    end
    self:Dbg('MainLoop: end')
    self.mainThread = nil
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
 
 local function normalizeParams(p)
     return {
         brain              = p.brain,
         spawnMarker        = p.spawnMarker,
         composition        = normalizeComposition(p.composition),
         difficulty         = p.difficulty or 2,
         attackFn           = p.attackFn,
         attackData         = p.attackData,
         waveCooldown       = p.waveCooldown or 0,
         mode               = p.mode or 1,
        mode2LossThreshold = (p.mode2LossThreshold ~= nil) and p.mode2LossThreshold or 0.5,
        mode3WaveCount     = p.mode3WaveCount or 0,
        mode4PlatoonCount  = (p.mode4PlatoonCount ~= nil) and p.mode4PlatoonCount or 1,
        spawnerTag         = p.spawnerTag,
        spawnSpread        = (p.spawnSpread ~= nil) and p.spawnSpread or 6,
        formation          = p.formation or 'GrowthFormation',
        debug              = p.debug and true or false,
        onWaveCreated      = p.onWaveCreated,
        onWaveNumber       = p.onWaveNumber,
        onSpawnerComplete  = p.onSpawnerComplete,
        onMode2ThresholdMet = p.onMode2ThresholdMet,
        escalationPercent  = p.escalationPercent or 0,
        escalationFrequency= p.escalationFrequency or 0,
    }
end
 
 -- ========== Public API ==========
 function Start(params)
     assert(params and params.brain and params.spawnMarker, 'brain and spawnMarker are required')
     local o = setmetatable({}, Spawner)
     o.params      = normalizeParams(params)
     o.brain       = o.params.brain
     o.tag         = o.params.spawnerTag or ('US_'.. math.floor(100000 * Random()))
     o.params.spawnerTag = o.tag
     o.spawnPositions = resolveSpawnList(o.params.spawnMarker)
     if table.getn(o.spawnPositions) == 0 then
         error('Invalid spawnMarker: '.. tostring(o.params.spawnMarker))
     end
    o.lastSpawnIndex = 0
    o.stopped     = false
    o.wave        = 0
    o.composition = o.params.composition
    o.baseWanted  = o:BuildWantedForWave(1)
    o.callbacks   = {}
    o:RegisterInitialCallbacks()
    o:Start()
    return o
end
 
function Stop(handle)
     if handle and handle.Stop then handle:Stop() end
 end
 
