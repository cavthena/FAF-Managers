-- /maps/faf_coop_U01.v0001/manager_UnitBuilder.lua
-- AI Unit Build Manager (rally-only, wave + sustain modes)
--
-- What it does
--   • Leases factories near a base marker via manager_FactoryHandler
--   • Queues ONLY the requested composition; units roll off and move to a single rally point
--   • Hands off a UNIQUE platoon to your attack function when all units are complete & at rally
--   • Safe to run multiple builders in parallel (per-unit ub_tag and per-wave platoon names)
--   • No patrols are used; rally-only flow
--
-- Modes
--   1: Wave (default)
--      Build requested composition → wait until all are complete & at rally → handoff → cooldown → next wave.
--   2: Wave, gated by losses
--      Same as Mode 1, but the NEXT wave only starts when the PREVIOUS wave has lost at least `mode2LossThreshold`
--      fraction of its original strength (or is destroyed).
--   3: Sustain & Reinforce
--      After handoff, keep the active platoon at full strength by rebuilding losses and adding the replacements
--      directly into the live platoon. If the platoon is wiped or disappears, reform a fresh full-strength platoon
--      and continue sustaining.
--
-- Public API
--   local Builder = import('/maps/.../manager_UnitBuilder.lua')
--   local handle = Builder.Start{
--     brain            = ArmyBrains[ScenarioInfo.Cybran],
--     baseMarker       = 'Cybran_ForwardNorthBase_Zone',
--     domain           = 'LAND',             -- 'LAND'|'AIR'|'NAVAL'|'AUTO'
--     composition      = {                   -- list of { bp, {e,n,h}, [label] }
--         {'url0106', {2, 2, 2}, 'LightBots'},
--         {'url0107', {2, 2, 2}, 'LightTanks'},
--     },
--     difficulty       = ScenarioInfo.Options.Difficulty or 2,
--     wantFactories    = 1,                  -- 0 = any available
--     priority         = 150,                -- 0..200 (higher wins)
--     rallyMarker      = 'AREA2_NORTHATTACK_SPAWNER', -- also used for direct spawn when spawnFirstDirect=true
--     waveCooldown     = 10,                 -- seconds between waves (modes 1/2)
--     attackFn         = function(platoon) ... end,  -- or 'FunctionName' to resolve from _G at runtime
--     attackData       = p.attackData,       -- Function Data
--     spawnFirstDirect = false,              -- if true, first wave spawns at rallyMarker
--     builderTag       = 'CFNB',             -- unique tag to avoid overlap with other builders
--     radius           = 60,                 -- factory search radius around baseMarker
--     debug            = false,
--     _alloc           = nil,                -- optional shared allocator instance
--     mode             = 1,                  -- 1: waves; 2: next wave gated by losses; 3: sustain & reinforce
--     mode2LossThreshold = 0.5,             -- [0..1] fraction lost before mode 2 starts next wave
--   }
--   Builder.Stop(handle)
--
-- Hard-coded behavior / constants
--   * Units must be fully built AND within 12 of rallyMarker before handoff.
--   * If composition regresses before handoff we reset inProd and requeue immediately.
--   * Stall watchdog: if no increase in completed units for 900s (15 min), reset/requeue.
--   * Rally sweep radius is 12 (unified with handoff gate).
--   * Removed/ignored params: patrolChain, spawnMarker, rallyReadyRadius, rallyReadyTimeout,
--       requeueOnRegression, stuckSeconds, scanRadius.

local ScenarioUtils      = import('/lua/sim/ScenarioUtilities.lua')
local ScenarioFramework  = import('/lua/ScenarioFramework.lua')
local FactoryAllocMod    = import('/maps/faf_coop_U01.v0001/manager_FactoryHandler.lua')

ScenarioInfo.AllocByBrain = ScenarioInfo.AllocByBrain or {}
function GetAllocator(brain)
    local alloc = ScenarioInfo.AllocByBrain[brain]
    if not alloc then
        alloc = FactoryAllocMod.New(brain)
        ScenarioInfo.AllocByBrain[brain] = alloc
    end
    return alloc
end

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
        _alloc           = p._alloc,
        debug            = p.debug and true or false,
        mode             = p.mode or 1,
        mode2LossThreshold = (p.mode2LossThreshold ~= nil) and p.mode2LossThreshold or 0.5,
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
                    if dist2d(pos, rpos) > 12 then
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

local function countAliveByBp(units)
    local t = {}
    if not units then return t end
    for _, u in ipairs(units) do
        if u and not u.Dead then
            local bp = unitBpId(u)
            if bp then t[bp] = (t[bp] or 0) + 1 end
        end
    end
    return t
end

local function countCompleteByBp(units)
    local t = {}
    if not units then return t end
    for _, u in ipairs(units) do
        if isComplete(u) then
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

-- NEW: Ask allocator to try to raise us to wantFactories if currently short
function Builder:EnsureFactoryQuota()
    local want = math.max(0, (self.params and self.params.wantFactories) or 0)
    if want == 0 then return end
    local have = table.getn(_LiveFactoriesList(self, false))
    if have < want then
        self:Dbg(('EnsureFactoryQuota: have=%d want=%d -> requesting more'):format(have, want))
        self:RequestLease()
    end
end

-- NEW: Are all leased factories idle (no Building state and empty queue)?
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

-- NEW: Immediate handoff with whatever we have right now
function Builder:EarlyHandoff(aliveList)
    local flist = _LiveFactoriesList(self, false)
    _ClearQueuesRestoreRally(self)

    local attackPlatoon = nil
    if self.stagingPlatoon and self.brain:PlatoonExists(self.stagingPlatoon) then
        if self.stagingPlatoon.SetPlatoonLabel then
            self.stagingPlatoon:SetPlatoonLabel(self.attackName)
        end
        attackPlatoon = self.stagingPlatoon
    else
        attackPlatoon = self.brain:MakePlatoon(self.attackName or (self.tag..'_Attack'), '')
        local assign = {}
        for _, u in ipairs(aliveList or {}) do
            if isComplete(u) then table.insert(assign, u) end
        end
        if table.getn(assign) > 0 then
            IssueClearCommands(assign)
            self.brain:AssignUnitsToPlatoon(attackPlatoon, assign, 'Attack', 'GrowthFormation')
        end
    end

    if self.params.attackFn then
        attackPlatoon.PlatoonData = self.params.attackData or {}
        _ForkAttack(attackPlatoon, self.params.attackFn, attackPlatoon.PlatoonData, self.tag)
    else
        self:Warn('EarlyHandoff: no attackFn; platoon will idle')
    end

    if self.leaseId then
        self.alloc:ReturnLease(self.leaseId)
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
    if not self.stopped then self:BeginWaveLoop() end
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
        radius         = self.params.radius or 60,
        domain         = (self.params.domain or 'AUTO'):upper(),
        wantFactories  = math.max(0, self.params.wantFactories or 0),
        priority       = self.params.priority or 50,
        onGrant        = function(f, id) self:OnLeaseGranted(f, id) end,
        onUpdate       = function(f, id) self:OnLeaseUpdated(f, id) end,
        onRevoke       = function(list, id, reason) self:OnLeaseRevoked(list, id, reason) end,
        onComplete     = function(id) end,
    }
end

function Builder:RequestLease()
    self.leaseId = self.alloc:RequestFactories(self:_MakeLeaseParams())
    return self.leaseId
end

function Builder:Start()
    if self.params.spawnFirstDirect then
        self.wave = (self.wave or 0) + 1
        local p = self:SpawnDirectAndSend(self.wave)

        if (self.params.mode or 1) == 3 then
            -- Sustain the platoon we just spawned; no “new wave” bookkeeping.
            self.monitorThread = self.brain:ForkThread(function()
                self:Mode3Loop(p)
            end)
        else
            self.brain:ForkThread(function()
                WaitSeconds(math.max(0, self.params.waveCooldown or 0))
                self:BeginWaveLoop()
            end)
        end
    else
        self:BeginWaveLoop()
    end
end

function Builder:BeginWaveLoop()
    if self.stopped then return end

    self.wave = (self.wave or 0) + 1
    self.stagingName   = string.format('%s_Stage_%d', self.tag, self.wave)
    self.attackName    = string.format('%s_Attack_%d', self.tag, self.wave)
    self.stagingPlatoon = self.brain:MakePlatoon(self.stagingName, '')
    self.stagingSet     = {}     -- [entId]=unit tracked for THIS wave
    self.inProd         = {}     -- [bp]=count queued but not yet collected
    self.rrIndex        = 1

    -- progress watchdog
    self._stuckCounter = 0
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
    for entId, _ in pairs(list or {}) do
        self.leased[entId] = nil
    end
    -- if all leased factories are gone, clear leaseId so we can request a new lease
    local hasAny = false
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then hasAny = true break end
    end
    if not hasAny then
        self.leaseId = nil
        self:Dbg('LeaseRevoked: no factories remain; leaseId cleared')
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
    local p = self.brain:MakePlatoon(string.format('%s_Attack_%d', self.tag, waveNo or 1), '')
    self.brain:AssignUnitsToPlatoon(p, spawned, 'Attack', 'GrowthFormation')
    if self.params.attackFn then
        p.PlatoonData = self.params.attackData or {}
        _ForkAttack(p, self.params.attackFn, p.PlatoonData, self.tag)
    else
        WARN(('[UB:%s] No attackFn provided; spawned platoon will idle.'):format(self.tag))
    end
end

function Builder:CollectorLoop()
    -- Collect units produced by our leased factories, attach to staging platoon (for tracking only).
    local neededBP = {}
    for bp, _ in pairs(self.wanted) do neededBP[bp] = true end

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
            local aroundRally = self.brain:GetUnitsAroundPoint(categories.MOBILE, first, 12, 'Ally') or {}
            for _, u in ipairs(aroundRally) do table.insert(nearby, u) end
        end
        self:Dbg(('Collector: fac=%d nearFactories+rally=%d'):format(facCount, table.getn(nearby)))

        -- how many we already staged (by BP)
        local aliveTbl = {}
        if self.stagingPlatoon then
            aliveTbl = countCompleteByBp(self.stagingPlatoon:GetPlatoonUnits() or {})
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
            if isComplete(u) then table.insert(aliveList, u) end
        end
        local haveTbl   = countCompleteByBp(aliveList)
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
                self._stuckCounter = 0
                self._idleAllCounter = 0
            end

            self:QueueNeededBuilds(haveTbl or {})

            -- stall watchdog (15 min) + NEW early-handoff idle tracker (30s)
            local allIdle = self:_AllFactoriesIdle()
            if self._haveSum ~= haveTotal then
                self._haveSum = haveTotal
                self._stuckCounter = 0
                self._idleAllCounter = 0
            else
                if allIdle then
                    self._stuckCounter = (self._stuckCounter or 0) + 1
                    self._idleAllCounter = (self._idleAllCounter or 0) + 1
                    if self._stuckCounter >= 900 then
                        self:Warn(('Monitor: STALL (idle, no completed increase for %ds) -> resetting inProd and requeue'):format(self._stuckCounter))
                        self.inProd = {}
                        self._stuckCounter = 0
                        self:QueueNeededBuilds(haveTbl or {})
                    end
                    -- NEW: Early handoff after 30 consecutive idle seconds
                    if self._idleAllCounter >= 30 then
                        self:Warn(('Monitor: factories idle for %ds -> EarlyHandoff with %d/%d units')
                            :format(self._idleAllCounter, haveTotal, wantTotal))
                        self.stagingPlatoon = self.stagingPlatoon
                        self:EarlyHandoff(aliveList)
                        return
                    end
                else
                    self._stuckCounter = 0
                    self._idleAllCounter = 0
                end
            end

            WaitSeconds(1)
        else
            -- Before handoff, require ALL expected units are assembled at the rally point
            local rpos    = getRallyPos(self.params) or self.basePos
            local radius  = 12
            local timeout = 900
            local waited  = 0
            local ready   = false

            while not self.stopped do
                -- recompute completed units from tracking set (not relying on platoon handle)
                aliveList = {}
                for id, u in pairs(self.stagingSet) do
                    if isComplete(u) then
                        table.insert(aliveList, u)
                    end
                end
                haveTbl = countCompleteByBp(aliveList)

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
                        haveFinal = countCompleteByBp(self.stagingPlatoon:GetPlatoonUnits() or {})
                    else
                        haveFinal = countCompleteByBp(aliveList or {})
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

                local staged = self.stagingPlatoon
                local stagedExists = staged and self.brain:PlatoonExists(staged) or false

                self.stagingPlatoon = nil

                if stagedExists then
                    if staged.SetPlatoonLabel then staged:SetPlatoonLabel(self.attackName) end
                    attackPlatoon = staged
                else
                    self:Warn('Handoff Fallback: staging platoon missing; creating new attack platoon and assigning alive units')
                    attackPlatoon = self.brain:MakePlatoon(self.attackName, '')
                    local assign = {}
                    for _, u in ipairs(aliveList or {}) do if isComplete(u) then table.insert(assign, u) end end
                    if table.getn(assign) > 0 then
                        IssueClearCommands(assign)
                        self.brain:AssignUnitsToPlatoon(attackPlatoon, assign, 'Attack', 'GrowthFormation')
                    end
                end

                local units = attackPlatoon:GetPlatoonUnits() or {}
                self:Dbg(('Handoff: attackPlatoon label=%s units=%d exists=%s')
                    :format((attackPlatoon.GetPlatoonLabel and attackPlatoon:GetPlatoonLabel()) or 'nil', table.getn(units), tostring(self.brain:PlatoonExists(attackPlatoon))))

                if self.params.attackFn then
                    attackPlatoon.PlatoonData = self.params.attackData or {}
                    _ForkAttack(attackPlatoon, self.params.attackFn, attackPlatoon.PlatoonData, self.tag)
                else
                    self:Warn('No attackFn provided; not forking AI thread')
                end

                if self.leaseId then
                    self.alloc:ReturnLease(self.leaseId)
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
                if not self.stopped then self:BeginWaveLoop() end
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
end

function Builder:Mode3Loop(p)
    local wantTotal = sumCounts(self.wanted)
    while not self.stopped do
        local exists = p and self.brain:PlatoonExists(p)
        if exists then
            -- try a quick collect to scoop any fresh roll-offs/rally units
            self:CollectForPlatoon(p)
        end

        local haveTbl = exists and countCompleteByBp(p:GetPlatoonUnits() or {}) or {}
        local needTbl = computeDeficit(self.wanted, haveTbl)
        local needTotal = deficitTotal(needTbl)

        if not exists or table.getn(p:GetPlatoonUnits() or {}) == 0 then
            -- Reform a new platoon to full strength
            self.wave = (self.wave or 0) + 1
            self.attackName = string.format('%s_Attack_%d', self.tag, self.wave)
            p = self.brain:MakePlatoon(self.attackName, '')
            self.inProd = {}
            -- request factories if needed
            if not self.leaseId then
                self:RequestLease()
            end
            -- fill to full
            while not self.stopped do
                haveTbl = countCompleteByBp(p:GetPlatoonUnits() or {})
                needTbl = computeDeficit(self.wanted, haveTbl)
                needTotal = deficitTotal(needTbl)
                if needTotal <= 0 then break end
                self:QueueNeededBuilds(haveTbl)
                self:CollectForPlatoon(p)
                WaitSeconds(0.5)
            end
            -- wait at rally
            local rpos, radius, timeout = getRallyPos(self.params) or self.basePos, 12, 900
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
                p:ForkAIThread(self.params.attackFn)
            end
            if self.leaseId then
                self.alloc:ReturnLease(self.leaseId)
                self.leaseId = nil
            end
        else
            -- Top up missing units
            if needTotal > 0 then
                if not self.leaseId then
                    self:RequestLease()
                end
                self:QueueNeededBuilds(haveTbl)
                self:CollectForPlatoon(p)
                if not self.holdBuild then
                    if not self.leaseId then
                        self:RequestLease()
                    end
                    self:QueueNeededBuilds(haveTbl)
                    self:CollectForPlatoon(p)
                else
                    -- ensure we're not accidentally building while held
                    if self.leaseId then
                        _ClearQueuesRestoreRally(self)
                        self.alloc:ReturnLease(self.leaseId)
                        self.leaseId = nil
                    end
                end
            else
                -- no deficit; release any lease we hold
                if self.leaseId then
                    _ClearQueuesRestoreRally(self)
                    self.alloc:ReturnLease(self.leaseId)
                    self.leaseId = nil
                end
            end
            WaitSeconds(1)
        end
    end
end

function Builder:Stop()
    if self.stopped then return end
    self.stopped = true

    if self.leaseId then
        self.alloc:ReturnLease(self.leaseId)
        self.leaseId = nil
    end
    if self.collectThread then KillThread(self.collectThread) self.collectThread = nil end
    if self.monitorThread then KillThread(self.monitorThread) self.monitorThread = nil end
    if self.rallyKeeperThread then KillThread(self.rallyKeeperThread) self.rallyKeeperThread = nil end
end

-- ========== Public API ==========
function Start(params)
    assert(params and params.brain and params.baseMarker, 'brain and baseMarker are required')
    local brain = params.brain

    local o = setmetatable({}, Builder)
    o.brain   = brain
    o.params  = normalizeParams(params)
    o.tag     = params.builderTag or ('UB_'..math.floor(100000*Random()))
    o.basePos = ScenarioUtils.MarkerToPosition(params.baseMarker)
    o.alloc   = params._alloc or FactoryAllocMod.New(brain)
    o.stopped = false
    o.wanted, o.bpOrder = flattenCounts(params.composition, params.difficulty or 2)
    if not o.basePos then error('Invalid baseMarker: '.. tostring(params.baseMarker)) end
    o:Start()
    return o
end

function Stop(handle) if handle and handle.Stop then handle:Stop() end end
