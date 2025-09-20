-- /maps/faf_coop_U01.v0001/manager_BaseEngineer.lua
-- Base Engineer Manager (Part 1) — v4 (callback‑free)
--
-- Why v4?
--   • Removes ALL factory AddUnitCallback hooks to avoid nil‑category crashes in DoOnUnitBuiltCallbacks.
--   • Still isolates ownership: we only tag engineers rolled off our currently leased factories
--     that match a pending build we queued AND only while there is a deficit for that tier.
--   • Keeps headcount/rebuild + periodic debug headcount.
--   • Lua 5.0 safe (no '#', '%', or 'goto').
--
-- Public API
--   local BaseEng = import('/maps/.../manager_BaseEngineer.lua')
--   local handle = BaseEng.Start{
--     brain=..., baseMarker='...', difficulty=1..3, baseManager=nil, baseTag='...',
--     counts={{1,2,3},{1,2,3},{1,2,3},{0,0,1}}, radius=60, priority=120, wantFactories=1,
--     spawnSpread=2, debug=false, _alloc=nil }
--   BaseEng.Stop(handle)

local ScenarioUtils     = import('/lua/sim/ScenarioUtilities.lua')
local FactoryAllocMod   = import('/maps/faf_coop_U01.v0001/manager_FactoryHandler.lua')

ScenarioInfo.AllocByBrain = ScenarioInfo.AllocByBrain or {}
local function GetAllocator(brain)
    local alloc = ScenarioInfo.AllocByBrain[brain]
    if not alloc then
        alloc = FactoryAllocMod.New(brain)
        ScenarioInfo.AllocByBrain[brain] = alloc
    end
    return alloc
end

-- faction maps (1 UEF, 2 Aeon, 3 Cybran, 4 Seraphim)
local EngBp = {
    [1] = { T1='uel0105', T2='uel0208', T3='uel0309', SCU='uel0301' },
    [2] = { T1='ual0105', T2='ual0208', T3='ual0309', SCU='ual0301' },
    [3] = { T1='url0105', T2='url0208', T3='url0309', SCU='url0301' },
    [4] = { T1='xsl0105', T2='xsl0208', T3='xsl0309', SCU='xsl0301' },
}

local function clampDifficulty(d)
    if not d then return 2 end
    if d < 1 then return 1 end
    if d > 3 then return 3 end
    return d
end

local function markerPos(mark)
    if not mark then return nil end
    return ScenarioUtils.MarkerToPosition(mark)
end

local function isComplete(u)
    if not u or u.Dead then return false end
    if u.GetFractionComplete and u:GetFractionComplete() < 1 then return false end
    if u.IsUnitState and u:IsUnitState('BeingBuilt') then return false end
    return true
end

local function unitBpId(u)
    if not u then return nil end
    local id = u.BlueprintID
    if (not id) and u.GetBlueprint then
        local bp = u:GetBlueprint()
        if bp then id = bp.BlueprintId end
    end
    if not id then return nil end
    id = string.lower(id)
    local short = string.match(id, '/units/([^/]+)/') or id
    return short
end

local function tgetn(t)
    return table.getn(t or {})
end

local M = {}
M.__index = M

function M:Log(msg) LOG(('[BE:%s] %s'):format(self.tag, msg)) end
function M:Warn(msg) WARN(('[BE:%s] %s'):format(self.tag, msg)) end
function M:Dbg(msg) if self.params.debug then self:Log(msg) end end

local function _sum(tbl)
    local s = 0; for _,n in pairs(tbl or {}) do s = s + (n or 0) end; return s
end

function M:_AliveCountTier(tier)
    local count = 0
    local set = self.tracked[tier]
    if not set then return 0 end
    for id, u in pairs(set) do
        if u and not u.Dead and isComplete(u) and u:GetAIBrain() == self.brain then
            count = count + 1
        else
            set[id] = nil
        end
    end
    return count
end

function M:_WantedByBp()
    local bpmap = {}
    local map = EngBp[self.faction] or EngBp[1]
    if (self.desired.T1 or 0) > 0 then bpmap[map.T1] = (bpmap[map.T1] or 0) + (self.desired.T1 or 0) end
    if (self.desired.T2 or 0) > 0 then bpmap[map.T2] = (bpmap[map.T2] or 0) + (self.desired.T2 or 0) end
    if (self.desired.T3 or 0) > 0 then bpmap[map.T3] = (bpmap[map.T3] or 0) + (self.desired.T3 or 0) end
    if (self.desired.SCU or 0) > 0 then bpmap[map.SCU] = (bpmap[map.SCU] or 0) + (self.desired.SCU or 0) end
    return bpmap
end

function M:_AliveByBp()
    local out = {}
    local map = EngBp[self.faction] or EngBp[1]
    local function add(bp, n) out[bp] = (out[bp] or 0) + (n or 0) end
    add(map.T1, self:_AliveCountTier('T1'))
    add(map.T2, self:_AliveCountTier('T2'))
    add(map.T3, self:_AliveCountTier('T3'))
    add(map.SCU, self:_AliveCountTier('SCU'))
    return out
end

function M:_ComputeDeficit()
    local want = self:_WantedByBp()
    local have = self:_AliveByBp()
    local d = {}
    for bp, w in pairs(want) do
        local h = have[bp] or 0
        if h < (w or 0) then d[bp] = (w or 0) - h end
    end
    return d
end

function M:_OnEngineerGone(u)
    if not u then return end
    local id = u:GetEntityId()
    local tier = u._be_tier
    if tier and self.tracked[tier] then
        self.tracked[tier][id] = nil
        self:Dbg(('Engineer lost: id=%d tier=%s'):format(id, tostring(tier)))
    end
end

function M:_TagAndTrack(u, tier)
    if not u then return end
    u.be_tag  = self.tag
    u._be_tier = tier
    local id = u:GetEntityId()
    self.tracked[tier] = self.tracked[tier] or {}
    self.tracked[tier][id] = u
    if u.AddUnitCallback then
        u:AddUnitCallback(function(unit) self:_OnEngineerGone(unit) end, 'OnKilled')
        u:AddUnitCallback(function(unit) self:_OnEngineerGone(unit) end, 'OnCaptured')
        u:AddUnitCallback(function(unit) self:_OnEngineerGone(unit) end, 'OnReclaimed')
    end
end

function M:_SpawnInitial()
    local pos = self.basePos
    if not pos then
        self:Warn('SpawnInitial: invalid basePos')
        return
    end
    local spread = self.params.spawnSpread or 0
    local map = EngBp[self.faction] or EngBp[1]

    local function spawnMany(bp, tier, n)
        local i = 1
        while i <= (n or 0) do
            local ox = (spread > 0) and (Random()*2 - 1) * spread or 0
            local oz = (spread > 0) and (Random()*2 - 1) * spread or 0
            local u = CreateUnitHPR(bp, self.brain:GetArmyIndex(), pos[1]+ox, pos[2], pos[3]+oz, 0,0,0)
            if u then self:_TagAndTrack(u, tier) end
            i = i + 1
        end
    end

    spawnMany(map.T1, 'T1',  self.desired.T1 or 0)
    spawnMany(map.T2, 'T2',  self.desired.T2 or 0)
    spawnMany(map.T3, 'T3',  self.desired.T3 or 0)
    spawnMany(map.SCU, 'SCU', self.desired.SCU or 0)

    self:Dbg(('Initial spawn done: T1=%d T2=%d T3=%d SCU=%d')
        :format(self.desired.T1 or 0, self.desired.T2 or 0, self.desired.T3 or 0, self.desired.SCU or 0))
end

-- ===================== Factory lease + build =====================

function M:_LeaseParams()
    return {
        markerName = self.params.baseMarker,
        markerPos  = self.basePos,
        radius     = self.params.radius or 60,
        domain     = 'AUTO',
        wantFactories = self.params.wantFactories or 1,
        priority   = self.params.priority or 120,
        onGrant    = function(f, id) self:OnLeaseGranted(f, id) end,
        onUpdate   = function(f, id) self:OnLeaseUpdated(f, id) end,
        onRevoke   = function(l, id, why) self:OnLeaseRevoked(l, id, why) end,
        onComplete = function(id) end,
    }
end

function M:RequestLease()
    self.leaseId = self.alloc:RequestFactories(self:_LeaseParams())
    return self.leaseId
end

function M:OnLeaseGranted(factories, leaseId)
    if self.stopped then return end
    self.leased = {}
    self.pending = {}
    local i = 1
    while i <= tgetn(factories) do
        local f = factories[i]
        if f and not f.Dead then
            self.leased[f:GetEntityId()] = f
            self.pending[f:GetEntityId()] = {}
        end
        i = i + 1
    end
    self:Dbg(('Lease granted: %d factories'):format(tgetn(factories)))
    self:QueueNeededBuilds()
end

function M:OnLeaseUpdated(factories, leaseId)
    if self.stopped then return end
    self.leased = self.leased or {}
    self.pending = self.pending or {}
    local i = 1
    while i <= tgetn(factories) do
        local f = factories[i]
        if f and not f.Dead then
            local id = f:GetEntityId()
            self.leased[id] = f
            self.pending[id] = self.pending[id] or {}
        end
        i = i + 1
    end
    self:QueueNeededBuilds()
end

function M:OnLeaseRevoked(list, leaseId, reason)
    if self.stopped then return end
    for entId, _ in pairs(list or {}) do
        self.leased[entId] = nil
        self.pending[entId] = nil
    end
end

function M:_QueuedCounts()
    local byBp = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead and f.GetCommandQueue then
            local q = f:GetCommandQueue() or {}
            local j = 1
            while j <= tgetn(q) do
                local cmd = q[j]
                local bid = nil
                if type(cmd) == 'table' then
                    if type(cmd.blueprintId) == 'string' then
                        bid = cmd.blueprintId
                    elseif type(cmd.blueprint) == 'table' and type(cmd.blueprint.BlueprintId) == 'string' then
                        bid = cmd.blueprint.BlueprintId
                    elseif type(cmd.unitId) == 'string' then
                        bid = cmd.unitId
                    elseif type(cmd.id) == 'string' then
                        bid = cmd.id
                    end
                end
                if type(bid) == 'string' then
                    bid = string.lower(bid)
                    local short = string.match(bid, '/units/([^/]+)/') or bid
                    byBp[short] = (byBp[short] or 0) + 1
                end
                j = j + 1
            end
        end
    end
    return byBp
end

function M:_FactoriesList(usableOnly)
    local flist = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then
            if usableOnly then
                local up = (f.IsUnitState and f:IsUnitState('Upgrading'))
                local gd = (f.IsUnitState and f:IsUnitState('Guarding'))
                local ps = (f.IsPaused and f:IsPaused())
                if not (up or gd or ps) then table.insert(flist, f) end
            else
                table.insert(flist, f)
            end
        end
    end
    return flist
end

function M:QueueNeededBuilds()
    if self.holdBuild then return end

    if not self.leaseId then
        self:RequestLease()
        return
    end

    local flist = self:_FactoriesList(true)
    if tgetn(flist) == 0 then
        return
    end

    local want = self:_ComputeDeficit()
    local queued = self:_QueuedCounts()

    local pipeline = {}
    for bp, need in pairs(want) do
        local q = queued[bp] or 0
        if need > q then pipeline[bp] = need - q end
    end

    local any = false
    local rr = self._rr or 1

    for bp, need in pairs(pipeline) do
        local left = need
        local spins = 0
        while left > 0 and tgetn(flist) > 0 do
            local idx = rr
            if idx < 1 or idx > tgetn(flist) then idx = 1 end
            local f = flist[idx]
            local landed = false
            if f and not f.Dead then
                local cq0 = 0
                if f.GetCommandQueue then
                    local q0 = f:GetCommandQueue() or {}
                    cq0 = tgetn(q0)
                end
                IssueBuildFactory({f}, bp, 1)
                local cq1 = cq0
                if f.GetCommandQueue then
                    local q1 = f:GetCommandQueue() or {}
                    cq1 = tgetn(q1)
                end
                landed = (cq1 > cq0)
                if landed then
                    local id = f:GetEntityId()
                    self.pending[id] = self.pending[id] or {}
                    self.pending[id][bp] = (self.pending[id][bp] or 0) + 1
                    if self.params.debug then
                        self:Log(('Queued %s at f=%d; pending for that bp now %d'):format(bp, id, self.pending[id][bp]))
                    end
                end
            end

            if landed then
                any = true
                left = left - 1
                spins = 0
            else
                spins = spins + 1
            end

            rr = idx + 1
            if rr > tgetn(flist) then rr = 1 end

            if spins >= tgetn(flist) then
                break
            end
        end
    end

    self._rr = rr

    if not any then
        local d = self:_ComputeDeficit()
        local missing = 0
        for _, n in pairs(d) do missing = missing + (n or 0) end
        if missing <= 0 and self.leaseId then
            self.alloc:ReturnLease(self.leaseId)
            self.leaseId = nil
            self:Dbg('Headcount satisfied; lease returned')
        end
    end
end

-- Only verify/tag already‑tagged engineers, and also claim ONLY our pending roll‑offs
function M:_CollectorSweep()
    -- Merge search lists around leased factories and base
    local near = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then
            local around = self.brain:GetUnitsAroundPoint(categories.MOBILE, f:GetPosition(), 35, 'Ally') or {}
            local i = 1
            while i <= tgetn(around) do table.insert(near, around[i]); i = i + 1 end
        end
    end
    if self.basePos then
        local aroundB = self.brain:GetUnitsAroundPoint(categories.MOBILE, self.basePos, 35, 'Ally') or {}
        local j = 1
        while j <= tgetn(aroundB) do table.insert(near, aroundB[j]); j = j + 1 end
    end

    local map = EngBp[self.faction] or EngBp[1]
    local wantedBp = { [map.T1]=true, [map.T2]=true, [map.T3]=true, [map.SCU]=true }

    local k = 1
    while k <= tgetn(near) do
        local u = near[k]
        if u and not u.Dead and isComplete(u) and u:GetAIBrain() == self.brain then
            local bp = unitBpId(u)
            if bp and wantedBp[bp] then
                local tier = (bp==map.T1 and 'T1') or (bp==map.T2 and 'T2') or (bp==map.T3 and 'T3') or (bp==map.SCU and 'SCU') or nil
                if tier then
                    -- Case A: already ours, ensure tracked
                    if u.be_tag == self.tag then
                        local id = u:GetEntityId()
                        self.tracked[tier] = self.tracked[tier] or {}
                        if not self.tracked[tier][id] then
                            self.tracked[tier][id] = u
                            self:Dbg(('Collector verify ours: id=%d tier=%s'):format(id, tier))
                        end
                    -- Case B: untagged AND we have a pending slot for this bp at any leased factory
                    elseif not u.be_tag then
                        local needNow = (self:_AliveCountTier(tier) < (self.desired[tier] or 0))
                        if needNow then
                            -- Check if this unit is near any factory with pending count for this bp
                            local claimed = false
                            for fid, f in pairs(self.leased or {}) do
                                if f and not f.Dead then
                                    local fp = f:GetPosition()
                                    local up = u:GetPosition()
                                    local dx = (fp[1] or 0) - (up[1] or 0)
                                    local dz = (fp[3] or 0) - (up[3] or 0)
                                    local d2 = dx*dx + dz*dz
                                    if d2 <= (40*40) then
                                        local ptab = self.pending and self.pending[fid]
                                        local pend = ptab and ptab[bp] or 0
                                        if pend > 0 then
                                            -- Claim it for this manager
                                            self:_TagAndTrack(u, tier)
                                            ptab[bp] = pend - 1
                                            claimed = true
                                            if self.params.debug then
                                                self:Log(('Claimed roll-off bp=%s near f=%d; pending now %d'):format(bp, fid, ptab[bp]))
                                            end
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        k = k + 1
    end
end

-- DEBUG: periodic headcount summary
function M:_DebugHeadcount()
    if not self.params.debug then return end
    self._dbgTick = (self._dbgTick or 0) + 1
    if self._dbgTick >= 5 then -- roughly every 5 seconds (loop sleeps 1s)
        self._dbgTick = 0
        local a1 = self:_AliveCountTier('T1')
        local a2 = self:_AliveCountTier('T2')
        local a3 = self:_AliveCountTier('T3')
        local as = self:_AliveCountTier('SCU')
        self:Log(('Headcount T1:%d/%d T2:%d/%d T3:%d/%d SCU:%d/%d (missing=%d)')
            :format(a1, self.desired.T1 or 0, a2, self.desired.T2 or 0, a3, self.desired.T3 or 0, as, self.desired.SCU or 0,
                    _sum(self:_ComputeDeficit())))
    end
end

-- ===================== Threads =====================
function M:MonitorLoop()
    self:Dbg('MonitorLoop start')
    while not self.stopped do
        local def = self:_ComputeDeficit()
        local missing = 0
        for _, n in pairs(def) do missing = missing + (n or 0) end

        if missing > 0 and (not self.leaseId) then
            self:RequestLease()
        end

        if missing > 0 then
            self:QueueNeededBuilds()
        end

        self:_CollectorSweep()
        self:_DebugHeadcount()

        if missing <= 0 and self.leaseId then
            self.alloc:ReturnLease(self.leaseId)
            self.leaseId = nil
            self:Dbg('Monitor: satisfied -> lease returned')
        end

        WaitSeconds(1)
    end
    self:Dbg('MonitorLoop end')
end

function M:Start()
    self:_SpawnInitial()
    self.monitorThread = self.brain:ForkThread(function() self:MonitorLoop() end)
end

function M:Stop()
    if self.stopped then return end
    self.stopped = true
    if self.leaseId then
        self.alloc:ReturnLease(self.leaseId)
        self.leaseId = nil
    end
    if self.monitorThread then
        KillThread(self.monitorThread)
        self.monitorThread = nil
    end
end

local function NormalizeParams(p)
    local d = clampDifficulty(p.difficulty or 2)
    local counts = p.counts or { {0,0,0}, {0,0,0}, {0,0,0}, {0,0,0} }
    local function tri(t)
        local a = t[1] or 0
        local b = t[2] or a
        local c = t[3] or b
        return {a,b,c}
    end
    local C1 = tri(counts[1] or {})
    local C2 = tri(counts[2] or {})
    local C3 = tri(counts[3] or {})
    local CS = tri(counts[4] or {})

    return {
        brain        = p.brain,
        baseMarker   = p.baseMarker,
        difficulty   = d,
        baseManager  = p.baseManager,
        baseTag      = p.baseTag,
        counts       = {C1, C2, C3, CS},
        radius       = p.radius or 60,
        priority     = p.priority or 120,
        wantFactories= p.wantFactories or 1,
        spawnSpread  = (p.spawnSpread ~= nil) and p.spawnSpread or 2,
        debug        = p.debug and true or false,
        _alloc       = p._alloc,
    }
end

function Start(params)
    assert(params and params.brain and params.baseMarker and params.counts, 'brain, baseMarker, counts are required')

    local o = setmetatable({}, M)
    o.params   = NormalizeParams(params)
    o.brain    = o.params.brain
    o.basePos  = markerPos(o.params.baseMarker)
    if not o.basePos then error('Invalid baseMarker: '.. tostring(o.params.baseMarker)) end

    o.tag      = params.baseTag or ('BE_'.. math.floor(100000 * Random()))
    o.alloc    = params._alloc or GetAllocator(o.brain)
    o.stopped  = false
    o.tracked  = { T1={}, T2={}, T3={}, SCU={} }
    o.faction  = (o.brain.GetFactionIndex and o.brain:GetFactionIndex()) or 1

    local C = o.params.counts
    local d = o.params.difficulty
    o.desired = {
        T1  = (C[1] and C[1][d]) or 0,
        T2  = (C[2] and C[2][d]) or 0,
        T3  = (C[3] and C[3][d]) or 0,
        SCU = (C[4] and C[4][d]) or 0,
    }

    o.leased   = {}
    o.pending  = {}
    o.leaseId  = nil

    o:Start()
    return o
end

function Stop(handle)
    if handle and handle.Stop then handle:Stop() end
end

return { Start = Start, Stop = Stop }
