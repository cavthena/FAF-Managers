--[[
================================================================================
 Unit Builder Manager (Lua 5.0 safe)
================================================================================

Overview
    Factory consumer that leases production from a base created via
    manager_BaseEngineer. Builds a fixed composition, stages the units at a
    rally marker, and hands the completed platoon to a user-supplied attack
    function. Supports wave, loss-gated, and sustain modes.

Usage
    local UnitBuilder = import('/maps/.../manager_UnitBuilder.lua')
    local handle = UnitBuilder.Start{
        brain            = ArmyBrains[armyIndex],     -- required
        baseMarker       = 'Base_Marker',             -- required marker used for factory lookup fallback
        domain           = 'LAND',                    -- required: 'LAND' | 'AIR' | 'NAVAL' | 'AUTO'
        composition      = {                          -- required table of { bp, {easy,normal,hard}, [label] }
            {'url0106', {2, 2, 2}, 'LightBots'},
            {'url0107', {1, 1, 1}, 'LightTanks'},
        },

        baseHandle       = baseHandle,                -- optional explicit handle from BaseManager.Start
        baseTag          = 'UEF_Main',                -- optional tag used to resolve baseHandle when not supplied
        difficulty       = ScenarioInfo.Options.Difficulty or 2, -- optional, defaults to 2
        wantFactories    = 0,                         -- optional, 0 = any available
        priority         = 150,                       -- optional request priority (0..200, default 50 when nil)
        radius           = 60,                        -- optional search radius (defaults to base radius or 60)
        rallyMarker      = 'Attack_Rally_1',          -- optional; falls back to baseMarker
        waveCooldown     = 0,                         -- optional seconds between waves (modes 1/2)
        spawnFirstDirect = false,                     -- optional, true spawns first wave at rallyMarker
        attackFn         = function(platoon) end,     -- optional; may also be a global function name
        attackData       = {},                        -- optional table copied to platoon.PlatoonData
        builderTag       = 'Forward_UB',              -- optional unique tag (defaults to auto-generated)
        mode             = 1,                         -- optional: 1=waves, 2=loss-gated, 3=sustain
        mode2LossThreshold = 0.5,                     -- optional [0..1] loss fraction before next wave in mode 2
        escalationPercent = 0,                       -- optional percent increase applied cumulatively per escalationFrequency
        escalationFrequency = 0,                     -- optional waves between each escalation step (1 = every wave)
        debug            = false,                     -- optional verbose logging
    }

    Public API
        UnitBuilder.Start(params)
            Validates the request, acquires a base handle, and starts the builder.

        UnitBuilder.Stop(handle)
            Stops the running builder and frees any factory leases.

        UnitBuilder.AddCallback(handle, fn, eventName)
            Registers a platoon callback using the same shape as unit callbacks
            (function or global name, optional event string; defaults to 'OnHandoff').

    Platoon callback events
        OnHandoff   Fired after the platoon is created and handed to attackFn
                    (wave handoff, sustain handoff, cleanup/Stop handoff).

Behavioral notes
    * Units must be complete and within 18 units of the rally marker before
      handoff.
    * Base managers revoke factory leases after prolonged idling; the builder
      automatically re-requests a lease when notified of a stall.
    * Factory leasing automatically nudges towards `wantFactories` while active.
    * When `manager_BaseEngineer.lua` sits beside this script it will be imported
      automatically; otherwise adjust the fallback path below.
    * Legacy parameters from original FAF scripts (patrolChain, spawnMarker,
      rallyReadyRadius, rallyReadyTimeout, requeueOnRegression, stuckSeconds,
      scanRadius) are intentionally ignored.
]]

local ScenarioUtils      = import('/lua/sim/ScenarioUtilities.lua')
local ScenarioFramework  = import('/lua/ScenarioFramework.lua')

local function ResolveBaseManagerModule()
    local ok, info = pcall(debug.getinfo, 1, 'S')
    if ok and info and info.source then
        local src = info.source
        if type(src) == 'string' and string.sub(src, 1, 1) == '@' then
            local dir = string.match(src, '^@(.*/)[^/]*$')
            if dir then
                local path = dir .. 'manager_BaseEngineer.lua'
                local okImport, mod = pcall(import, path)
                if okImport and mod then
                    return mod
                end
            end
        end
    end

    if ScenarioInfo and ScenarioInfo.MapPath then
        local mp = ScenarioInfo.MapPath
        if type(mp) == 'string' then
            local dir = string.match(mp, '^(.-)/[^/]*$') or mp
            if dir then
                if string.sub(dir, 1, 1) ~= '/' then
                    dir = '/' .. dir
                end
                local path = dir .. '/manager_BaseEngineer.lua'
                local okImport, mod = pcall(import, path)
                if okImport and mod then
                    return mod
                end
            end
        end
    end

    return import('/maps/faf_coop_U01.v0001/manager_BaseEngineer.lua')
end

local BaseManager        = ResolveBaseManagerModule()

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
        brain            = p.brain,
        baseMarker       = p.baseMarker,
        domain           = p.domain,
        composition      = copyComposition(p.composition),
        difficulty       = p.difficulty,
        wantFactories    = p.wantFactories,
        priority         = p.priority,
        rallyMarker      = p.rallyMarker,
        waveCooldown     = p.waveCooldown,
        attackFn         = p.attackFn,
        attackData       = p.attackData,
        spawnFirstDirect = p.spawnFirstDirect,
        builderTag       = p.builderTag,
        radius           = p.radius,
        baseTag          = p.baseTag,
        baseHandle       = p.baseHandle,
        debug            = p.debug and true or false,
        mode             = p.mode or 1,
        mode2LossThreshold = (p.mode2LossThreshold ~= nil) and p.mode2LossThreshold or 0.5,
        escalationPercent = p.escalationPercent,
        escalationFrequency = p.escalationFrequency,
    }
end

local function _ForkAttack(platoon, fn, opts, tag)
    -- resolve by name if needed
    if type(fn) == 'string' then
        fn = rawget(_G, fn)
    end
    if type(fn) ~= 'function' then
        WARN(('[UB:%s] No valid attackFn; not forking AI thread'):format(tag or '?'))
        return
    end

    local brain = platoon and platoon:GetBrain()
    if not (brain and brain.PlatoonExists and brain:PlatoonExists(platoon)) then
        WARN(('[UB:%s] attack platoon missing at handoff'):format(tag or '?'))
        return
    end

    -- Trampoline on a brain thread, then fork the AI on the platoon
    brain:ForkThread(function()
        -- let platoon membership/queues settle
        WaitTicks(2)
        if brain:PlatoonExists(platoon) then
            -- clear any transient orders from staging/rally
            local units = platoon:GetPlatoonUnits() or {}
            if table.getn(units) > 0 then
                IssueClearCommands(units)
            end
            platoon.PlatoonData = opts or platoon.PlatoonData or {}
            platoon:ForkAIThread(function(p) return fn(p, p.PlatoonData) end)
        end
    end)
end

local function _NormalizeCallbacks(spec, defaultEvent, tag)
    local out = {}
    defaultEvent = defaultEvent or 'OnHandoff'

    local function add(fn, ev)
        if type(fn) == 'string' then
            fn = rawget(_G, fn)
        end
        if type(fn) ~= 'function' then
            WARN(('[UB:%s] platoon callback is not callable; skipping'):format(tag or '?'))
            return
        end
        table.insert(out, { fn, ev or defaultEvent })
    end

    if spec == nil then
        return out
    end

    local stype = type(spec)
    if stype == 'function' or stype == 'string' then
        add(spec, defaultEvent)
    elseif stype == 'table' then
        local first = spec[1]
        if type(first) == 'function' or type(first) == 'string' then
            add(first, spec[2] or defaultEvent)
        else
            for _, entry in ipairs(spec) do
                if type(entry) == 'function' or type(entry) == 'string' then
                    add(entry, defaultEvent)
                elseif type(entry) == 'table' then
                    add(entry[1], entry[2] or defaultEvent)
                end
            end
        end
    end

    return out
end

local function _CallPlatoonCallbacks(callbacks, platoon, eventName, tag)
    if not callbacks or table.getn(callbacks) == 0 then
        return
    end
    for _, cb in ipairs(callbacks) do
        local fn, ev = cb[1], cb[2] or eventName
        local ok, err = pcall(fn, platoon, ev or eventName)
        if not ok then
            WARN(('[UB:%s] platoon callback error: %s'):format(tag or '?', tostring(err)))
        end
    end
end

local function _AppendCallbacks(target, spec, defaultEvent, tag)
    if not target then return end
    local entries = _NormalizeCallbacks(spec, defaultEvent, tag)
    for _, cb in ipairs(entries) do
        table.insert(target, cb)
    end
end

local function flattenCounts(composition, difficulty)
    local wanted, order = {}, {}
    for _, entry in ipairs(composition or {}) do
        local bp   = entry[1]
        local cnt  = entry[2]
        local want = (type(cnt) == 'table') and cnt[math.max(1, math.min(3, difficulty or 2))] or cnt
        if want and want > 0 then
            wanted[bp] = (wanted[bp] or 0) + want
            table.insert(order, bp)
        end
    end
    return wanted, order
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

local function scaledWanted(baseWanted, factor)
    local out = {}
    for bp, cnt in pairs(baseWanted or {}) do
        local use = cnt or 0
        if factor ~= 1 then
            use = math.max(0, math.floor(use * factor))
        end
        out[bp] = use
    end
    return out
end

local function chainFirstPos(chainName)
    local chain = chainName and ScenarioUtils.ChainToPositions(chainName)
    if chain and chain[1] then return { chain[1][1], chain[1][2], chain[1][3] } end
    return nil
end

local function markerPos(mark)
    return mark and ScenarioUtils.MarkerToPosition(mark) or nil
end

local function getRallyPos(params)
    return markerPos(params.rallyMarker) or markerPos(params.baseMarker)
end

local function setFactoryRally(factory, pos)
    if factory and pos then
        IssueFactoryRallyPoint({factory}, pos)
    end
end

-- Clear queues on a list of factories and immediately restore this builder's rally
local function _ClearQueuesRestoreRally(self)
    if not self then return end
    local flist = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then table.insert(flist, f) end
    end
    if table.getn(flist) == 0 then return end
    local rpos = getRallyPos(self.params) or self.basePos
    IssueClearFactoryCommands(flist)
    if rpos then
        for _, f in ipairs(flist) do
            setFactoryRally(f, rpos)
        end
    end
end

local function unitBpId(u)
    local id = (u.BlueprintID or (u:GetBlueprint() and u:GetBlueprint().BlueprintId))
    if not id then return nil end
    id = string.lower(id)
    local short = string.match(id, '/units/([^/]+)/') or id
    return short
end

local function dist2d(a, b)
    if not a or not b then return 999999 end
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt(dx*dx + dz*dz)
end

-- treat only fully-built units as "complete"
local function isComplete(u)
    if not u or u.Dead then return false end
    if u.GetFractionComplete and u:GetFractionComplete() < 1 then return false end
    if u.IsUnitState and u:IsUnitState('BeingBuilt') then return false end
    return true
end

-- Sweep nearby units that belong to this builder (or are candidates for it) to the rally.
local function _RallySweep(self)
    local rpos = getRallyPos(self.params) or self.basePos
    if not rpos then return end

    local nearby = {}
    -- around leased factories
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then
            local around = self.brain:GetUnitsAroundPoint(categories.MOBILE, f:GetPosition(), 35, 'Ally') or {}
            for _, u in ipairs(around) do table.insert(nearby, u) end
        end
    end
    -- around rally
    local aroundRally = self.brain:GetUnitsAroundPoint(categories.MOBILE, rpos, 35, 'Ally') or {}
    for _, u in ipairs(aroundRally) do table.insert(nearby, u) end

    for _, u in ipairs(nearby) do
        if u and not u.Dead and isComplete(u) and u:GetAIBrain()==self.brain then
            local bp = unitBpId(u)
            if self.wanted and self.wanted[bp] then
                -- only touch unowned or ours
                if (not u.ub_tag) or (u.ub_tag == self.tag) then
                    local pos = u:GetPosition()
                    if dist2d(pos, rpos) > 18 then
                        local q = (u.GetCommandQueue and u:GetCommandQueue()) or {}
                        if table.getn(q) == 0 then
                            IssueMove({u}, rpos)
                        end
                    end
                end
            end
        end
    end
end

local function countAliveByBp(units, tag)
    local t = {}
    if not units then return t end
    for _, u in ipairs(units) do
        if u and not u.Dead and (not tag or u.ub_tag == tag) then
            local bp = unitBpId(u)
            if bp then t[bp] = (t[bp] or 0) + 1 end
        end
    end
    return t
end

local function countCompleteByBp(units, tag)
    local t = {}
    if not units then return t end
    for _, u in ipairs(units) do
        if isComplete(u) and (not tag or u.ub_tag == tag) then
            local bp = unitBpId(u)
            if bp then t[bp] = (t[bp] or 0) + 1 end
        end
    end
    return t
end

local function sumCounts(tbl)
    local s = 0
    for _, n in pairs(tbl or {}) do s = s + (n or 0) end
    return s
end

local function computeDeficit(wanted, have)
    local d = {}
    for bp, n in pairs(wanted or {}) do
        local hv = (have and have[bp]) or 0
        if hv < (n or 0) then d[bp] = (n or 0) - hv end
    end
    return d
end

local function deficitTotal(d)
    local s = 0
    for _, n in pairs(d or {}) do s = s + (n or 0) end
    return s
end

local function cmpCounts(a, b)
    for bp, want in pairs(a) do
        if (b[bp] or 0) < want then return false end
    end
    return true
end

local function roundrobinQueueBuilds(factories, deficit, rr)
    if not factories or table.getn(factories) == 0 then return rr end
    rr = rr or 1
    local fcount = table.getn(factories)
    for bp, need in pairs(deficit) do
        local left = need
        while left > 0 and fcount > 0 do
            local f = factories[rr]
            if f and not f.Dead then
                IssueBuildFactory({f}, bp, 1)
                left = left - 1
                rr = rr + 1
                if rr > fcount then rr = 1 end
            else
                rr = rr + 1
                if rr > fcount then rr = 1 end
            end
        end
    end
    return rr
end

-- NEW: live/usable factories list for lease (and various checks)
local function _LiveFactoriesList(self, usableOnly)
    local flist = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then
            if usableOnly then
                local isUpgrading = f.IsUnitState and f:IsUnitState('Upgrading')
                local isGuarding  = f.IsUnitState and f:IsUnitState('Guarding')
                local isPaused    = f.IsPaused    and f:IsPaused()
                if not (isUpgrading or isGuarding or isPaused) then
                    table.insert(flist, f)
                end
            else
                table.insert(flist, f)
            end
        end
    end
    return flist
end

-- ========== Builder class ==========
local Builder = {}
Builder.__index = Builder

function Builder:Log(msg) LOG(('[UB:%s] %s'):format(self.tag, msg)) end
function Builder:Warn(msg) WARN(('[UB:%s] %s'):format(self.tag, msg)) end
function Builder:Dbg(msg) if self.params.debug then self:Log(msg) end end

-- Gate building when an external controller (e.g., BaseEngineer) says we're full
function Builder:SetHoldBuild(flag)
    self.holdBuild = flag and true or false
    if self.params.debug then
        self:Dbg('HoldBuild=' .. tostring(self.holdBuild))
    end
end

-- Register a platoon callback at any time (function or global name, optional event)
function Builder:AddCallback(fn, eventName)
    if self.stopped then return end
    self.platoonCallbacks = self.platoonCallbacks or {}
    _AppendCallbacks(self.platoonCallbacks, { fn, eventName }, eventName or 'OnHandoff', self.tag)
end

-- Ask allocator to try to raise us to wantFactories if currently short
function Builder:EnsureFactoryQuota()
    local want = math.max(0, (self.params and self.params.wantFactories) or 0)
    if want == 0 then return end
    local have = table.getn(_LiveFactoriesList(self, false))
    if have < want then
        if not self.leaseId then
            self:Dbg(('EnsureFactoryQuota: have=%d want=%d -> requesting lease'):format(have, want))
            self:RequestLease()
        else
            self:Dbg(('EnsureFactoryQuota: have=%d want=%d but lease %d already active; waiting for allocator rebalance')
                :format(have, want, self.leaseId))
        end
    end
end

-- Are all leased factories idle (no Building state and empty queue)?
function Builder:_AllFactoriesIdle()
    local any = false
    local allIdle = true
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then
            any = true
            if f.IsUnitState and f:IsUnitState('Building') then
                allIdle = false
                break
            end
            if f.GetCommandQueue then
                local q = f:GetCommandQueue() or {}
                if table.getn(q) > 0 then
                    allIdle = false
                    break
                end
            end
        end
    end
    return any and allIdle
end

function Builder:_HandOffPlatoon(units, label)
    local platoon = self.brain:MakePlatoon(label or (self.tag .. '_Attack'), '')
    local assign = {}
    for _, u in ipairs(units or {}) do
        if u and not u.Dead then
            table.insert(assign, u)
        end
    end

    if table.getn(assign) > 0 then
        IssueClearCommands(assign)
        self.brain:AssignUnitsToPlatoon(platoon, assign, 'Attack', 'GrowthFormation')
    end

    if self.params.attackFn then
        platoon.PlatoonData = self.params.attackData or {}
        _ForkAttack(platoon, self.params.attackFn, platoon.PlatoonData, self.tag)
    else
        self:Warn('No attackFn provided; platoon will idle')
    end

    _CallPlatoonCallbacks(self.platoonCallbacks, platoon, 'OnHandoff', self.tag)
    return platoon
end

function Builder:EarlyHandoff(aliveList)
    local flist = _LiveFactoriesList(self, false)
    _ClearQueuesRestoreRally(self)

    -- Always create a fresh attack platoon and only add units with our tag
    local assign = {}
    for _, u in ipairs(aliveList or {}) do
        if isComplete(u) and u.ub_tag == self.tag then
            table.insert(assign, u)
        end
    end

    local attackPlatoon = self:_HandOffPlatoon(assign, self.attackName or (self.tag..'_Attack'))
    if not attackPlatoon then
        self:Warn('EarlyHandoff: no platoon created for handoff')
    end

    if self.leaseId then
        self.base:ReturnLease(self.leaseId)
        self.leaseId = nil
        self:Dbg('EarlyHandoff: returned factory lease')
    end

    local mode = self.params.mode or 1
    if mode == 3 then
        self:Dbg('EarlyHandoff -> Mode3 sustain loop')
        self:Mode3Loop(attackPlatoon)
        return
    elseif mode == 2 then
        self:WaitForMode2Gate(attackPlatoon)
    end

    WaitSeconds(math.max(0, self.params.waveCooldown or 0))
    self:RunCleanup()

    if not self.stopped then
        self:BeginWaveLoop()
    end
end

-- Returns a map { bpId -> count } of actual build orders in leased factory queues.
function Builder:_GetQueuedCounts()
    local byBp = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead and f.GetCommandQueue then
            local q = f:GetCommandQueue() or {}
            for _, cmd in ipairs(q) do
                -- Try to discover the blueprint id on this queue entry
                local bid = nil
                -- common fields seen in FAF:
                --   cmd.blueprintId | cmd.blueprint.BlueprintId | cmd.unitId | cmd.id (sometimes the bp)
                if type(cmd.blueprintId) == 'string' then
                    bid = cmd.blueprintId
                elseif type(cmd.blueprint) == 'table' and type(cmd.blueprint.BlueprintId) == 'string' then
                    bid = cmd.blueprint.BlueprintId
                elseif type(cmd.unitId) == 'string' then
                    bid = cmd.unitId
                elseif type(cmd.id) == 'string' then
                    -- some builds present the bp directly in id
                    bid = cmd.id
                end
                if type(bid) == 'string' then
                    bid = string.lower(bid)
                    local short = string.match(bid, '/units/([^/]+)/') or bid
                    -- only count things we actually want for this builder
                    if self.wanted and self.wanted[short] then
                        byBp[short] = (byBp[short] or 0) + 1
                    end
                end
            end
        end
    end
    return byBp
end

function Builder:_ResetPipeline(haveTbl)
    -- zero our idea of what's 'in production'
    self.inProd = {}
    self.rrIndex = 1
    -- clear factory build queues for this lease (via helper)
    local flist = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then table.insert(flist, f) end
    end
    _ClearQueuesRestoreRally(self)
    -- requeue exactly what's missing right now
    self:QueueNeededBuilds(haveTbl or {})
end

-- Visible pipeline counter: count units under construction near leased factories
function Builder:CountUnderConstruction()
    local t = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then
            local fpos = f:GetPosition()
            local around = self.brain:GetUnitsAroundPoint(categories.MOBILE, fpos, 20, 'Ally') or {}
            for _, u in ipairs(around) do
                if u and not u.Dead and u.IsUnitState and u:IsUnitState('BeingBuilt') then
                    local bp = unitBpId(u)
                    if bp and self.wanted and self.wanted[bp] then
                        t[bp] = (t[bp] or 0) + 1
                    end
                end
            end
        end
    end
    return t
end

-- Ensure inProd mirrors what's REALLY in factory queues; also cap to what's still needed.
function Builder:SanitizeInProd(haveTbl)
    self.inProd = self.inProd or {}
    haveTbl = haveTbl or {}
    local realQ = self:_GetQueuedCounts()
    local under = self:CountUnderConstruction()

    for bp, want in pairs(self.wanted or {}) do
        local have     = haveTbl[bp] or 0
        local queuedQ  = realQ[bp] or 0
        local queuedUC = under[bp] or 0
        local remembered = self.inProd[bp] or 0
        local pipeline   = math.max(queuedQ + queuedUC, remembered)
        local needed = math.max(0, (want or 0) - have)
        local use    = math.min(pipeline, needed)
        if (self.inProd[bp] or -1) ~= use then
            self:Dbg(('SanitizeInProd: bp=%s realQ=%d under=%d have=%d want=%d -> inProd=%d')
                :format(bp, queuedQ, queuedUC, have, want or 0, use))
        end
        self.inProd[bp] = use
    end
end

-- Lease helpers: build params and request/refresh a lease on factories near the base
function Builder:_MakeLeaseParams()
    return {
        markerName     = self.params.baseMarker,
        markerPos      = self.basePos,
        radius         = self.params.radius or self.base.radius or 60,
        domain         = (self.params.domain or 'AUTO'):upper(),
        wantFactories  = math.max(0, self.params.wantFactories or 0),
        priority       = math.max(0, math.min(200, self.params.priority or 50)),
        onGrant        = function(f, id) self:OnLeaseGranted(f, id) end,
        onUpdate       = function(f, id) self:OnLeaseUpdated(f, id) end,
        onRevoke       = function(list, id, reason) self:OnLeaseRevoked(list, id, reason) end,
        onComplete     = function(id) end,
    }
end

function Builder:RequestLease()
    self.leaseId = self.base:RequestFactories(self:_MakeLeaseParams())
    return self.leaseId
end

function Builder:GetEscalationFactor(waveNo)
    return escalationFactor(self.params, waveNo)
end

function Builder:GetWantedForWave(waveNo)
    return scaledWanted(self.baseWanted or {}, self:GetEscalationFactor(waveNo or 1))
end

function Builder:Start()
    if not self.cleanupTimerThread and self.brain and self.brain.ForkThread then
        self._cleanupDue = false
        self.cleanupTimerThread = self.brain:ForkThread(function() self:CleanupTimerLoop() end)
    end

    if self.params.spawnFirstDirect then
        self.wave = (self.wave or 0) + 1
        self.wanted = self:GetWantedForWave(self.wave)
        local p = self:SpawnDirectAndSend(self.wave)

        if (self.params.mode or 1) == 3 then
            -- Sustain the platoon we just spawned; no “new wave” bookkeeping.
            self.monitorThread = self.brain:ForkThread(function()
                self:Mode3Loop(p)
            end)
        else
            self.brain:ForkThread(function()
                WaitSeconds(math.max(0, self.params.waveCooldown or 0))
                self:RunCleanup()
                if not self.stopped then
                    self:BeginWaveLoop()
                end
            end)
        end
    else
        self:BeginWaveLoop()
    end
end

function Builder:BeginWaveLoop()
    if self.stopped then return end

    self.wave = (self.wave or 0) + 1
    self.wanted = self:GetWantedForWave(self.wave)
    self.stagingName   = string.format('%s_Stage_%d', self.tag, self.wave)
    self.attackName    = string.format('%s_Attack_%d', self.tag, self.wave)
    self.stagingPlatoon = self.brain:MakePlatoon(self.stagingName, '')
    self.stagingSet     = {}     -- [entId]=unit tracked for THIS wave
    self.inProd         = {}     -- [bp]=count queued but not yet collected
    self.rrIndex        = 1

    -- progress watchdog
    self._haveSum      = 0
    self._idleAllCounter = 0   -- NEW: global idle counter for early handoff

    -- Request factories
    self:RequestLease()
    if not self.leaseId then
        self:Warn('Factory lease request failed; will retry in 15s')
        self.brain:ForkThread(function()
            WaitSeconds(15)
            if not self.stopped then self:BeginWaveLoop() end
        end)
        return
    end

    -- Threads
    self.collectThread = self.brain:ForkThread(function() self:CollectorLoop() end)
    self.monitorThread = self.brain:ForkThread(function() self:MonitorLoop() end)
    -- NEW: periodic rally keeper (every 10s)
    self.rallyKeeperThread = self.brain:ForkThread(function() self:RallyKeeperLoop() end)
end

function Builder:OnLeaseGranted(factories, leaseId)
    if self.stopped then return end
    self.leased = {}
    local rpos = getRallyPos(self.params)
    for _, f in ipairs(factories) do
        self.leased[f:GetEntityId()] = f
        IssueClearFactoryCommands({f})
        setFactoryRally(f, rpos)
        self:Dbg(('%s: leased factory %d, rally->(%.1f,%.1f,%.1f)')
            :format(self.params.domain or 'AUTO', f:GetEntityId(), rpos and rpos[1] or -1, rpos and rpos[2] or -1, rpos and rpos[3] or -1))
    end
    -- Fail-safe: make sure anything already on the ground heads to rally
    _RallySweep(self)
    self:QueueNeededBuilds()
    -- NEW: try to reach our full requested factory count
    self:EnsureFactoryQuota()
end

function Builder:OnLeaseUpdated(factories, leaseId)
    if self.stopped then return end
    self.leased = self.leased or {}
    local rpos = getRallyPos(self.params)
    for _, f in ipairs(factories) do
        if f and not f.Dead then
            self.leased[f:GetEntityId()] = f
            IssueClearFactoryCommands({f})
            setFactoryRally(f, rpos)
            self:Dbg(('%s: leased factory %d, rally->(%.1f,%.1f,%.1f)')
                :format(self.params.domain or 'AUTO', f:GetEntityId(), rpos and rpos[1] or -1, rpos and rpos[2] or -1, rpos and rpos[3] or -1))
        end
    end
    -- Fail-safe on updates too
    _RallySweep(self)
    self:QueueNeededBuilds()
    -- NEW: keep nudging allocator to satisfy wantFactories when we can
    self:EnsureFactoryQuota()
end

function Builder:OnLeaseRevoked(list, leaseId, reason)
    if self.stopped then return end
    local stall = (reason == 'stall')
    if stall then
        self:Warn('LeaseRevoked: base detected production stall; clearing in-progress bookkeeping')
        self.inProd = {}
        self._idleAllCounter = 0
    end
    local toClear = {}
    for entId, fac in pairs(list or {}) do
        self.leased[entId] = nil
        if fac and not fac.Dead then
            table.insert(toClear, fac)
        end
    end
    if table.getn(toClear) > 0 then
        IssueClearFactoryCommands(toClear)
    end
    -- if all leased factories are gone, clear leaseId so we can request a new lease
    local hasAny = false
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then hasAny = true break end
    end
    if not hasAny then
        self.leaseId = nil
        self:Dbg('LeaseRevoked: no factories remain; leaseId cleared')
        if stall and not self.stopped then
            local brain = self.brain
            if brain and brain.ForkThread then
                brain:ForkThread(function()
                    WaitSeconds(1)
                    if not self.stopped and not self.leaseId then
                        self:Dbg('LeaseRevoked: requesting new lease after stall')
                        self:RequestLease()
                    end
                end)
            end
        end
    end
end

function Builder:SpawnDirectAndSend(waveNo)
    local spawnPos = getRallyPos(self.params)
    if not spawnPos then
        self:Warn('spawnFirstDirect=true but rallyMarker (spawn) is invalid')
        return
    end
    local spawned = {}
    for bp, count in pairs(self.wanted) do
        for i = 1, count do
            local u = CreateUnitHPR(bp, self.brain:GetArmyIndex(), spawnPos[1], spawnPos[2], spawnPos[3], 0, 0, 0)
            if u then
                u.ub_tag = self.tag
                table.insert(spawned, u)
            end
        end
    end
    return self:_HandOffPlatoon(spawned, string.format('%s_Attack_%d', self.tag, waveNo or 1))
end

function Builder:CollectorLoop()
    -- Collect units produced by our leased factories, attach to staging platoon (for tracking only).
    self:Dbg('CollectorLoop: start')
    while not self.stopped and self.stagingPlatoon do
        -- Gather nearby roll-offs (around leased factories and around rally)
        local nearby, facCount = {}, 0
        for _, f in pairs(self.leased or {}) do
            if f and not f.Dead then
                facCount = facCount + 1
                local fpos = f:GetPosition()
                local around = self.brain:GetUnitsAroundPoint(categories.MOBILE, fpos, 35, 'Ally') or {}
                for _, u in ipairs(around) do table.insert(nearby, u) end
            end
        end
        if facCount > 0 then
            local first = getRallyPos(self.params) or self.basePos
            local aroundRally = self.brain:GetUnitsAroundPoint(categories.MOBILE, first, 18, 'Ally') or {}
            for _, u in ipairs(aroundRally) do table.insert(nearby, u) end
        end
        self:Dbg(('Collector: fac=%d nearFactories+rally=%d'):format(facCount, table.getn(nearby)))

        -- how many we already staged (by BP)
        local aliveTbl = {}
        if self.stagingPlatoon then
            aliveTbl = countCompleteByBp(self.stagingPlatoon:GetPlatoonUnits() or {}, self.tag)
        end

        -- collect untagged roll-offs ONLY if needed
        for _, u in ipairs(nearby) do
            if not self.stagingPlatoon then break end
            if u and not u.Dead and not u.ub_tag and u:GetAIBrain() == self.brain then
                local bp   = unitBpId(u)
                local want = self.wanted[bp]
                local have = aliveTbl[bp] or 0
                if want and have < want and isComplete(u) then
                    local id = u:GetEntityId()
                    self.stagingSet[id] = u
                    u.ub_tag = self.tag
                    if not self.stagingPlatoon or not self.brain:PlatoonExists(self.stagingPlatoon) then break end
                    self.brain:AssignUnitsToPlatoon(self.stagingPlatoon, {u}, 'Attack', 'GrowthFormation')

                    local q = self.inProd[bp] or 0
                    if q > 0 then self.inProd[bp] = q - 1 end
                    aliveTbl[bp] = have + 1
                    self:Dbg(('Collector: +unit id=%d bp=%s (need->%d/%d)'):format(id, bp, aliveTbl[bp], want))
                end
            end
        end
        local __sleep = (facCount == 0) and 15 or 1
        if facCount == 0 then self:Dbg('Collector: no live factories; sleeping 15s') end
        WaitSeconds(__sleep)
    end
    self:Dbg('CollectorLoop: end')
end

function Builder:MonitorLoop()
    -- Wait until FULL (all requested units are BUILT), then hand off immediately.
    self:Dbg('MonitorLoop: start')
    local attackPlatoon = nil
    while not self.stopped do
        if not self.stagingPlatoon then break end

        -- Completed units tracked for this wave
        local aliveList = {}
        for id, u in pairs(self.stagingSet) do
            if isComplete(u) and u.ub_tag == self.tag then table.insert(aliveList, u) end
        end
        local haveTbl   = countCompleteByBp(aliveList, self.tag)
        local full      = cmpCounts(self.wanted, haveTbl)
        local wantTotal = sumCounts(self.wanted)
        local haveTotal = sumCounts(haveTbl)
        self:Dbg(('Monitor: alive=%d (%d/%d) full=%s'):format(table.getn(aliveList), haveTotal, wantTotal, tostring(full)))

        if not full then
            -- NEW: keep nudging allocator to reach our target factory count
            self:EnsureFactoryQuota()

            -- regression: completed count dropped → clear pipeline and requeue
            if (self._haveSum or 0) > haveTotal then
                self:Warn(("Monitor: REGRESSION detected (completed %d -> %d); reconciling without reset"):format(self._haveSum or 0, haveTotal))
                self:SanitizeInProd(haveTbl)
                self:QueueNeededBuilds(haveTbl)
                self._idleAllCounter = 0
            end

            self:QueueNeededBuilds(haveTbl or {})

            -- Early-handoff idle tracker (10s). Stall revocation handled by base manager.
            local allIdle = self:_AllFactoriesIdle()
            if self._haveSum ~= haveTotal then
                self._haveSum = haveTotal
                self._idleAllCounter = 0
            else
                if allIdle then
                    self._idleAllCounter = (self._idleAllCounter or 0) + 1
                    -- Early handoff after 10 consecutive idle seconds
                    if self._idleAllCounter >= 10 then
                        self:Warn(('Monitor: factories idle for %ds -> EarlyHandoff with %d/%d units')
                            :format(self._idleAllCounter, haveTotal, wantTotal))
                        self.stagingPlatoon = self.stagingPlatoon
                        self:EarlyHandoff(aliveList)
                        return
                    end
                else
                    self._idleAllCounter = 0
                end
            end

            WaitSeconds(1)
        else
            -- Before handoff, require ALL expected units are assembled at the rally point
            local rpos    = getRallyPos(self.params) or self.basePos
            local radius  = 18
            local timeout = 30
            local waited  = 0
            local ready   = false

            while not self.stopped do
                -- recompute completed units from tracking set (not relying on platoon handle)
                aliveList = {}
                for id, u in pairs(self.stagingSet) do
                    if isComplete(u) and u.ub_tag == self.tag then
                        table.insert(aliveList, u)
                    end
                end
                haveTbl = countCompleteByBp(aliveList, self.tag)

                -- if composition regressed (death), reconcile deficit (no reset)
                if not cmpCounts(self.wanted, haveTbl) then
                    self:Dbg('HandoffWait: composition dropped below wanted; reconciling deficit (no reset)')
                    self:SanitizeInProd(haveTbl)
                    self:QueueNeededBuilds(haveTbl)
                end

                -- count completed units at rally
                local at = 0
                for _, u in ipairs(aliveList) do
                    local pos = u:GetPosition()
                    if dist2d(pos, rpos) <= radius then
                        at = at + 1
                    end
                end
                self:Dbg(('HandoffWait: complete-at-rally=%d/%d (radius=%.1f) waited=%.1fs')
                    :format(at, wantTotal, radius, waited))

                if at >= wantTotal then
                    WaitTicks(10)
                    local haveFinal
                    if self.stagingPlatoon and self.brain:PlatoonExists(self.stagingPlatoon) then
                        haveFinal = countCompleteByBp(self.stagingPlatoon:GetPlatoonUnits() or {}, self.tag)
                    else
                        haveFinal = countCompleteByBp(aliveList or {}, self.tag)
                    end

                    local deficitTbl = computeDeficit(self.wanted, haveFinal)
                    local missing = deficitTotal(deficitTbl)

                    if missing == 0 then
                        ready = true
                        break
                    end

                    self:Warn(('FinalCheck: deficit %d before handoff -> queue replacements and keep waiting'):format(missing))
                    self:SanitizeInProd(haveFinal)
                    self:QueueNeededBuilds(haveFinal)
                end

                WaitSeconds(0.5)
                waited = waited + 0.5
                if timeout > 0 and waited >= timeout then
                    self:Warn(('HandoffWait: TIMEOUT after %.1fs (at %d/%d); proceeding anyway'):format(waited, at, wantTotal))
                    ready = true
                    break
                end
            end

            if not ready then
                WaitSeconds(0.5)
            else
                -- =============== HANDOFF ===============
                _ClearQueuesRestoreRally(self)

                -- Build the attack platoon strictly from our tagged aliveList
                local assign = {}
                for _, u in ipairs(aliveList or {}) do
                    if isComplete(u) and u.ub_tag == self.tag then
                        table.insert(assign, u)
                    end
                end

                attackPlatoon = self:_HandOffPlatoon(assign, self.attackName)
                local units = attackPlatoon and attackPlatoon:GetPlatoonUnits() or {}
                self:Dbg(('Handoff: attackPlatoon label=%s units=%d exists=%s')
                    :format((attackPlatoon and attackPlatoon.GetPlatoonLabel and attackPlatoon:GetPlatoonLabel()) or 'nil',
                            table.getn(units),
                            tostring(attackPlatoon and self.brain:PlatoonExists(attackPlatoon))))

                if self.leaseId then
                    self.base:ReturnLease(self.leaseId)
                    self.leaseId = nil
                    self:Dbg('Handoff: returned factory lease; entering post-handoff mode gate')
                end

                local mode = self.params.mode or 1
                if mode == 3 then
                    self:Dbg('Mode3: entering sustain loop')
                    self:Mode3Loop(attackPlatoon)
                    return
                elseif mode == 2 then
                    self:WaitForMode2Gate(attackPlatoon)
                end

                WaitSeconds(math.max(0, self.params.waveCooldown or 0))
                self:RunCleanup()
                if not self.stopped then
                    self:BeginWaveLoop()
                end
                return
            end
        end
    end
    self:Dbg('MonitorLoop: end')
end

function Builder:QueueNeededBuilds(currentCounts)
    if self.holdBuild then
        self:Dbg('QueueNeededBuilds: holdBuild=true; skipping queue')
        return
    end

    if not self.leased then return end
    if type(currentCounts) ~= 'table' then currentCounts = {} end

    -- Build raw list of leased factories that still exist
    local flist = {}
    for _, f in pairs(self.leased) do
        if f and not f.Dead then table.insert(flist, f) end
    end
    if table.getn(flist) == 0 then
        self:Warn('QueueNeededBuilds: no live factories — requesting lease; sleeping 15s before retry')
        self:RequestLease()
        WaitSeconds(15)
        return
    end

    -- Rally sweep + reconcile our inProd view against real queues/UC
    _RallySweep(self)
    self:SanitizeInProd(currentCounts)
    self.inProd  = self.inProd or {}
    self.rrIndex = self.rrIndex or 1

    -- Filter out factories that cannot accept a build order (assist/paused/upgrading)
    local usable = {}
    for _, f in ipairs(flist) do
        local ok = true
        local isUpgrading = f.IsUnitState and f:IsUnitState('Upgrading')
        local isGuarding  = f.IsUnitState and f:IsUnitState('Guarding')
        local isPaused    = f.IsPaused    and f:IsPaused()
        if isUpgrading or isGuarding or isPaused then
            ok = false
        end
        if ok then table.insert(usable, f) end
    end

    local fcount = table.getn(usable)

    -- NEW: If we have fewer factories than asked, keep (politely) requesting more.
    self:EnsureFactoryQuota()

    if fcount == 0 then
        self:Dbg('QueueNeededBuilds: no usable factories (all assisting/paused/upgrading)')
        return
    end

    local any = false
    for bp, want in pairs(self.wanted) do
        local have    = currentCounts[bp] or 0
        local queued  = self.inProd[bp] or 0
        local toQueue = want - (have + queued)

        if toQueue > 0 then
            any = true
            self:Dbg(('QueueNeededBuilds: bp=%s have=%d queued=%d want=%d -> toQueue=%d')
                :format(bp, have, queued, want, toQueue))

            -- Try to place orders across factories in round-robin
            local spinsWithoutLanding = 0
            while toQueue > 0 do
                local idx = self.rrIndex
                if idx < 1 or idx > fcount then idx = 1 end
                local f = usable[idx]

                local landed = false
                if f and not f.Dead then
                    local cq0 = 0
                    if f.GetCommandQueue then
                        local q = f:GetCommandQueue() or {}
                        cq0 = table.getn(q)
                    end

                    IssueBuildFactory({f}, bp, 1)

                    local cq1 = cq0
                    if f.GetCommandQueue then
                        local q2 = f:GetCommandQueue() or {}
                        cq1 = table.getn(q2)
                    end
                    landed = (cq1 > cq0)

                    if landed then
                        self.inProd[bp] = (self.inProd[bp] or 0) + 1
                        self:Dbg(('Build: queued %s on factory %d (inProd=%d)')
                            :format(bp, f:GetEntityId(), self.inProd[bp]))
                        toQueue = toQueue - 1
                        spinsWithoutLanding = 0
                    else
                        self:Dbg(('Build: order for %s did not land on factory %d; trying next')
                            :format(bp, f:GetEntityId()))
                        spinsWithoutLanding = spinsWithoutLanding + 1
                    end
                else
                    spinsWithoutLanding = spinsWithoutLanding + 1
                end

                -- Advance RR pointer
                self.rrIndex = idx + 1
                if self.rrIndex > fcount then self.rrIndex = 1 end

                -- Safety: if we made a full pass without landing anything, bail out for now
                if spinsWithoutLanding >= fcount then
                    self:Dbg(('Build: no factories accepted orders for %s this pass; will retry later')
                        :format(bp))
                    break
                end
            end
        end
    end

    if not any then
        self:Dbg('QueueNeededBuilds: satisfied (no new orders).')
    end
end

function Builder:RallyKeeperLoop()
    while not self.stopped do
        _RallySweep(self)
        WaitSeconds(10)
    end
end

function Builder:CleanupTimerLoop()
    -- Fires a "cleanup due" flag every 5 minutes.
    while not self.stopped do
        WaitSeconds(300)  -- 5 minutes
        if self.stopped then break end
        self._cleanupDue = true
        self:Dbg('CleanupTimer: cleanup due flag set')
    end
end

-- Scan the base radius for idle units with this builder's tag and hand them
-- off to the attackFn as a small cleanup platoon (once per timer tick).
function Builder:RunCleanup()
    if self.stopped or not self._cleanupDue then
        return
    end

    self._cleanupDue = false

    local center = self.basePos or (self.base and self.base.basePos)
    local radius = (self.params and self.params.radius) or (self.base and self.base.radius) or 60
    local brain  = self.brain

    if not (center and brain) then
        return
    end

    local units = brain:GetUnitsAroundPoint(categories.MOBILE, center, radius, 'Ally') or {}
    local idle = {}

    for _, u in ipairs(units) do
        if u and not u.Dead and isComplete(u) and u:GetAIBrain() == brain and u.ub_tag == self.tag then
            local q = (u.GetCommandQueue and u:GetCommandQueue()) or {}
            if table.getn(q) == 0 then
                table.insert(idle, u)
            end
        end
    end

    local count = table.getn(idle)
    if count == 0 then
        self:Dbg('Cleanup: no idle tagged units in base radius')
        return
    end

    self.cleanupWave = (self.cleanupWave or 0) + 1
    local label = string.format('%s_Cleanup_%d', self.tag, self.cleanupWave)
    self:Dbg(('Cleanup: handed %d idle units to attackFn as platoon %s')
        :format(count, label))
    self:_HandOffPlatoon(idle, label)
end

function Builder:WaitForMode2Gate(p)
    local thr = math.max(0, math.min(1, self.params.mode2LossThreshold or 0.5))
    local wantTotal = sumCounts(self.wanted)
    while not self.stopped do
        if not p or not self.brain:PlatoonExists(p) then
            self:Dbg('Mode2Gate: previous platoon gone; gate passed')
            return
        end
        local alive = 0
        for _, u in ipairs(p:GetPlatoonUnits() or {}) do if isComplete(u) then alive = alive + 1 end end
        local lost = math.max(0, wantTotal - alive)
        local frac = (wantTotal > 0) and (lost / wantTotal) or 1
        self:Dbg(('Mode2Gate: alive=%d lost=%d frac=%.2f thr=%.2f'):format(alive, lost, frac, thr))
        if frac >= thr then return end
        WaitSeconds(2)
    end
end

function Builder:CollectForPlatoon(platoon)
    -- Ensure a platoon exists; create one if missing (sustain mode safety)
    if (not platoon) or (not (self.brain and self.brain.PlatoonExists and self.brain:PlatoonExists(platoon))) then
        local name = self.attackName or (self.tag .. '_Attack_' .. tostring((self.wave or 1)))
        platoon = self.brain:MakePlatoon(name, '')
    end
    if not platoon or not self.wanted then return end

    -- Count what we already have in the platoon by blueprint id
    local haveTbl = {}
    local units = platoon:GetPlatoonUnits() or {}
    for _, pu in ipairs(units) do
        if pu and not pu.Dead then
            local bp = unitBpId(pu)
            haveTbl[bp] = (haveTbl[bp] or 0) + 1
        end
    end

    -- Build a search list near leased factories and the rally point
    local rpos = (self.params and (markerPos(self.params.rallyMarker) or markerPos(self.params.baseMarker))) or self.basePos
    local nearby = {}

    if self.leased then
        for _, f in pairs(self.leased) do
            if f and not f.Dead then
                local around = self.brain:GetUnitsAroundPoint(categories.MOBILE, f:GetPosition(), 35, 'Ally') or {}
                for _, u in ipairs(around) do table.insert(nearby, u) end
            end
        end
    end
    if rpos then
        local aroundR = self.brain:GetUnitsAroundPoint(categories.MOBILE, rpos, 35, 'Ally') or {}
        for _, u in ipairs(aroundR) do table.insert(nearby, u) end
    end

    -- Attach matching units that are unowned or already ours (tag matches)
    for _, u in ipairs(nearby) do
        if u and not u.Dead and isComplete(u) and u:GetAIBrain() == self.brain then
            local allowed = (not u.ub_tag) or (u.ub_tag == self.tag)
            if allowed then
                local bp   = unitBpId(u)
                local want = self.wanted[bp]
                local have = haveTbl[bp] or 0
                if want and have < want then
                    u.ub_tag = self.tag
                    self.brain:AssignUnitsToPlatoon(platoon, {u}, 'Attack', 'GrowthFormation')
                    haveTbl[bp] = have + 1
                    local q = self.inProd[bp] or 0
                    if q > 0 then self.inProd[bp] = q - 1 end
                    self:Dbg(('Reinforce: +unit id=%d bp=%s now=%d/%d'):format(u:GetEntityId(), bp, haveTbl[bp], want))
                end
            end
        end
    end
    return platoon
end

function Builder:Mode3Loop(p)
    local wantTotal = sumCounts(self.wanted)
    while not self.stopped do
        local exists = p and self.brain:PlatoonExists(p)
        if exists then
            -- try a quick collect to scoop any fresh roll-offs/rally units
            p = self:CollectForPlatoon(p)
        end

        local haveTbl = exists and countCompleteByBp(p:GetPlatoonUnits() or {}, self.tag) or {}
        local needTbl = computeDeficit(self.wanted, haveTbl)
        local needTotal = deficitTotal(needTbl)

        if not exists or table.getn(p:GetPlatoonUnits() or {}) == 0 then
            -- Reform a new platoon to full strength
            self.wave = (self.wave or 0) + 1
            self.wanted = self:GetWantedForWave(self.wave)
            self.attackName = string.format('%s_Attack_%d', self.tag, self.wave)
            wantTotal = sumCounts(self.wanted)
            p = self.brain:MakePlatoon(self.attackName, '')
            self.inProd = {}
            -- request factories if needed
            if not self.leaseId then
                self:RequestLease()
            end
            -- fill to full
            while not self.stopped do
                haveTbl = countCompleteByBp(p:GetPlatoonUnits() or {}, self.tag)
                needTbl = computeDeficit(self.wanted, haveTbl)
                needTotal = deficitTotal(needTbl)
                if needTotal <= 0 then break end
                self:QueueNeededBuilds(haveTbl)
                p = self:CollectForPlatoon(p)
                WaitSeconds(0.5)
            end
            -- wait at rally
            local rpos, radius, timeout = getRallyPos(self.params) or self.basePos, 12, 30
            local waited = 0
            while not self.stopped and self.brain:PlatoonExists(p) do
                local at = 0
                for _, u in ipairs(p:GetPlatoonUnits() or {}) do
                    if isComplete(u) then
                        local pos = u:GetPosition()
                        if dist2d(pos, rpos) <= radius then at = at + 1 end
                    end
                end
                self:Dbg(('Mode3: reform wait, at rally %d/%d'):format(at, wantTotal))
                if at >= wantTotal then break end
                WaitSeconds(0.5)
                waited = waited + 0.5
                if waited >= timeout then self:Warn('Mode3: reform wait TIMEOUT; proceeding') break end
            end
            -- start AI if needed
            if self.params.attackFn then
                _ForkAttack(p, self.params.attackFn, self.params.attackData or {}, self.tag)
            else
                self:Warn('Mode3: no attackFn provided; sustain platoon will idle')
            end
            _CallPlatoonCallbacks(self.platoonCallbacks, p, 'OnHandoff', self.tag)
            if self.leaseId then
                self.base:ReturnLease(self.leaseId)
                self.leaseId = nil
            end
        else
            -- Top up missing units
            if needTotal > 0 then
                if not self.leaseId then
                    self:RequestLease()
                end
                self:QueueNeededBuilds(haveTbl)
                p = self:CollectForPlatoon(p)
                if not self.holdBuild then
                    if not self.leaseId then
                        self:RequestLease()
                    end
                    self:QueueNeededBuilds(haveTbl)
                    p = self:CollectForPlatoon(p)
                else
                    -- ensure we're not accidentally building while held
                    if self.leaseId then
                        _ClearQueuesRestoreRally(self)
                        self.base:ReturnLease(self.leaseId)
                        self.leaseId = nil
                    end
                end
            else
                -- no deficit; release any lease we hold
                if self.leaseId then
                    _ClearQueuesRestoreRally(self)
                    self.base:ReturnLease(self.leaseId)
                    self.leaseId = nil
                end
            end
            WaitSeconds(1)
        end
    end
end

function Builder:_CollectStopHandoffUnits()
    local collected, seen = {}, {}
    local function add(u, requireIdle)
        if not (u and not u.Dead and isComplete(u) and u:GetAIBrain() == self.brain and u.ub_tag == self.tag) then
            return
        end
        if requireIdle then
            local q = (u.GetCommandQueue and u:GetCommandQueue()) or {}
            if table.getn(q) > 0 then
                return
            end
        end
        local id = u:GetEntityId()
        if not seen[id] then
            seen[id] = true
            table.insert(collected, u)
        end
    end

    for _, u in pairs(self.stagingSet or {}) do
        add(u, false)
    end
    if self.stagingPlatoon and self.brain:PlatoonExists(self.stagingPlatoon) then
        for _, u in ipairs(self.stagingPlatoon:GetPlatoonUnits() or {}) do
            add(u, false)
        end
    end

    local center = self.basePos or (self.base and self.base.basePos)
    local radius = (self.params and self.params.radius) or (self.base and self.base.radius) or 60
    if center and self.brain then
        for _, u in ipairs(self.brain:GetUnitsAroundPoint(categories.MOBILE, center, radius, 'Ally') or {}) do
            add(u, true)
        end
    end

    return collected
end

function Builder:Stop()
    if self.stopped then return end
    self.stopped = true

    local handoff = self:_CollectStopHandoffUnits()
    local handoffCount = table.getn(handoff)

    if self.collectThread then KillThread(self.collectThread) self.collectThread = nil end
    if self.monitorThread then KillThread(self.monitorThread) self.monitorThread = nil end
    if self.rallyKeeperThread then KillThread(self.rallyKeeperThread) self.rallyKeeperThread = nil end
    if self.cleanupTimerThread then KillThread(self.cleanupTimerThread) self.cleanupTimerThread = nil end

    _ClearQueuesRestoreRally(self)
    if self.leaseId then
        self.base:ReturnLease(self.leaseId)
        self.leaseId = nil
    end

    if handoffCount > 0 then
        self:Dbg(('Stop: handing off %d units before shutdown'):format(handoffCount))
        self:_HandOffPlatoon(handoff, self.attackName or (self.tag .. '_Stop'))
    end
end

-- ========== Public API ==========
function Start(params)
    assert(params and params.brain and params.baseMarker, 'brain and baseMarker are required')
    local brain = params.brain

    local o = setmetatable({}, Builder)
    o.brain   = brain
    o.params  = normalizeParams(params)
    o.tag     = params.builderTag or ('UB_'..math.floor(100000*Random()))

    o.base    = params.baseHandle or params.base or o.params.baseHandle
    if (not o.base) and (o.params.baseTag or params.baseTag) then
        o.base = BaseManager.GetBase(o.params.baseTag or params.baseTag)
    end
    assert(o.base, 'UnitBuilder requires a baseHandle or baseTag to request factories')

    o.basePos = ScenarioUtils.MarkerToPosition(o.params.baseMarker) or o.base.basePos
    o.stopped = false
    if not o.basePos then error('Invalid baseMarker: '.. tostring(params.baseMarker)) end
    o.baseWanted, o.bpOrder = flattenCounts(params.composition, params.difficulty or 2)
    o.wanted = o:GetWantedForWave(1)
    o.platoonCallbacks = _NormalizeCallbacks(o.params.platoonCallbacks, 'OnHandoff', o.tag)
    o:Start()
    return o
end

function Stop(handle) if handle and handle.Stop then handle:Stop() end end

-- Add a platoon callback after creation; fn may be a function or global name; eventName defaults to 'OnHandoff'.
function AddCallback(handle, fn, eventName)
    if handle and handle.AddCallback then
        handle:AddCallback(fn, eventName)
    end
end
