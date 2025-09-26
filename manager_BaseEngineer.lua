-- Created by Ruanuku/Cavthena
-- Base Engineer Manager

-- local handle = BaseEngineer.Start{
--     brain           = ArmyBrains[Army],
--     baseMarker      = 'marker',
--     baseTag         = 'tag',
--     radius          = 65,
--     difficulty      = Difficulty,
--     structGroups    = {'UnitGroup'},

--     counts          = {{0,0,0}, {0,0,0}, {0,0,0}, {0,0,0}} -- T1, T2, T3, SCU. {Easy, Normal, Hard}
--     priority        = 120,
--     wantFactories   = 1,
--     spawnSpread     = 2,
--     _alloc          = self.GetAllocator(ArmyBrains[Army]),

--     tasks = {
--         min         = {BUILD = 0, ASSIST = 0, EXP = 0},
--         max         = {BUILD = 1, ASSIST = 1, EXP = 1},
--         exp = {
--             marker  = 'marker',
--             cooldown= 180,
--             bp      = 'bp',
--             attackFn= Function,
--             attackData= {},
--         },
--     },
-- }

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

local function _ArmyNameFromBrain(brain)
    if not brain then return nil end
    local idx = brain.GetArmyIndex and brain:GetArmyIndex()
    if not idx then return nil end
    if ArmyBrains and ArmyBrains[idx] and ArmyBrains[idx].Name then
        return ArmyBrains[idx].Name    -- fallback
    end
    return ('ARMY_' .. tostring(idx))  -- last-ditch
end

local function _TryGetUnitsFromGroup(name)
    if not name then return {} end
    local list = {}

    local ok, g = pcall(function() return ScenarioUtils.GetUnitGroup(name) end)
    if ok and type(g) == 'table' then
        for _, u in pairs(g) do table.insert(list, u) end
    end

    if (table.getn(list) == 0) and ScenarioInfo and ScenarioInfo.Groups and ScenarioInfo.Groups[name] then
        local gg = ScenarioInfo.Groups[name]
        if gg and gg.Units then
            for _, rec in ipairs(gg.Units) do
                if rec and rec.Unit then table.insert(list, rec.Unit) end
            end
        end
    end
    return list
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
        self.engTask[id] = nil
        self:Dbg(('Engineer lost: id=%d tier=%s'):format(id, tostring(tier)))
    end
end

function M:_TagAndTrack(u, tier)
    if not u then return end
    u.be_tag   = self.tag
    u._be_tier = tier
    local id = u:GetEntityId()
    self.tracked[tier] = self.tracked[tier] or {}
    self.tracked[tier][id] = u
    self.engTask = self.engTask or {}
    self.engTask[id] = self.engTask[id] or 'IDLE'

    if u.AddUnitCallback then
        u:AddUnitCallback(function(unit) self:_OnEngineerGone(unit) end, 'OnKilled')
        u:AddUnitCallback(function(unit) self:_OnEngineerGone(unit) end, 'OnCaptured')
        u:AddUnitCallback(function(unit) self:_OnEngineerGone(unit) end, 'OnReclaimed')
    end
end

function M:_CreateStructGroups()
    local groups = self.params.structGroups or {}
    if table.getn(groups) == 0 then return end

    local armyName = _ArmyNameFromBrain(self.brain)
    if not armyName then
        self:Warn('StructGroups: unable to resolve army from brain; skip spawning')
        return
    end

    for _, gname in ipairs(groups) do
        -- Skip if the group is already present in the world (e.g., spawned earlier)
        local existing = _TryGetUnitsFromGroup(gname)
        if table.getn(existing) > 0 then
            if self.params.debug then
                self:Dbg(('StructGroups: "%s" already present (%d units); skip create')
                    :format(gname, table.getn(existing)))
            end
        else
            -- Create the group for our brain's army
            local ok, units = pcall(function()
                return ScenarioUtils.CreateArmyGroup(armyName, gname, false)
            end)
            if ok then
                -- NEW: remember the actual unit instances we just created
                self.structGroupUnits = self.structGroupUnits or {}
                self.structGroupUnits[gname] = units or {}
                if self.params.debug then
                    local count = (units and table.getn(units)) or 0
                    self:Dbg(('StructGroups: created "%s" (%d units)'):format(gname, count))
                end
            else
                self:Warn(('StructGroups: failed to create "%s"'):format(tostring(gname)))
            end
        end
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
    self.engTask[id] = self.engTask[id] or 'IDLE'
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

-- === Structure template from editor groups; hardcoded rebuild+upgrade-to-target ===
local function _unitIsStructure(u)
    if not (u and (not u.Dead)) then return false end
    if not u.GetBlueprint then return false end
    -- count true structures AND wall sections
    return EntityCategoryContains(categories.STRUCTURE, u)
        or EntityCategoryContains(categories.WALL, u)
end

local function _posOf(u)
    if not u or not u.GetPosition then return nil end
    local p = u:GetPosition(); return p and {p[1], p[2], p[3]} or nil
end

local function _headingOf(u)
    if not u or not u.GetOrientation then return 0 end
    local o = u:GetOrientation(); return (type(o) == 'number') and o or 0
end

local function _bpIdFromUnit(u)
    if unitBpId then return unitBpId(u) end
    if _shortBpId then return _shortBpId(u) end
    local bp = u and u.GetBlueprint and u:GetBlueprint()
    return bp and string.lower(bp.BlueprintId or '') or nil
end

local function _FindStructureNear(brain, pos, bp, radius)
    if not (brain and pos) then return nil end
    local r = radius or 2.5
    local cats = categories.STRUCTURE + categories.WALL
    local around = brain:GetUnitsAroundPoint(cats, pos, r, 'Ally') or {}
    for i = 1, table.getn(around) do
        local s = around[i]
        if s and (not s.Dead) and _unitIsStructure(s) then
            if (not bp) or (_bpIdFromUnit(s) == string.lower(bp)) then
                return s
            end
        end
    end
    return nil
end

-- === Upgrade-chain helpers (hardcoded policy: match target blueprint) ===
local function _Bp(bpId) return __blueprints and __blueprints[bpId] end

local function _ChainRoot(bpId)
    if not bpId then return nil end
    local cur = string.lower(bpId)
    local seen = {}
    while cur and _Bp(cur) and not seen[cur] do
        seen[cur] = true
        local prev = _Bp(cur).General and _Bp(cur).General.UpgradesFrom
        if type(prev) == 'string' then
            prev = string.lower(prev)
            -- STOP if empty or 'none'
            if prev ~= '' and prev ~= 'none' then
                cur = prev
            else
                break
            end
        else
            break
        end
    end
    -- safety: never return 'none'
    if cur == 'none' then return nil end
    return cur
end

local function _ChainNext(bpId)
    if not bpId then return nil end
    local up = _Bp(bpId) and _Bp(bpId).General and _Bp(bpId).General.UpgradesTo
    return (type(up) == 'string' and up ~= '') and string.lower(up) or nil
end

-- Is cur in the same chain and not higher than target? (cur == target or below it)
local function _IsSameChainAndNotAbove(cur, target)
    if not (cur and target) then return false end
    cur, target = string.lower(cur), string.lower(target)
    -- Walk backwards from target via UpgradesFrom; if we hit cur, cur is <= target in same chain
    local seen, t = {}, target
    while t and _Bp(t) and not seen[t] do
        if t == cur then return true end
        seen[t] = true
        local prev = _Bp(t).General and _Bp(t).General.UpgradesFrom
        if type(prev) == 'string' and prev ~= '' then t = string.lower(prev) else break end
    end
    return false
end

local function _FindStructureForSlot(brain, slot)
    if not (brain and slot and slot.pos) then return nil end
    local r = 2.0  -- tighter than 2.5 to reduce neighbors; adjust if needed
    local around = brain:GetUnitsAroundPoint(categories.STRUCTURE + categories.WALL, slot.pos, r, 'Ally') or {}
    local exact, chainOK = nil, nil
    local target = string.lower(slot.bpTarget)

    for i = 1, table.getn(around) do
        local s = around[i]
        if s and (not s.Dead) and _unitIsStructure(s) then
            local cur = _bpIdFromUnit(s)
            if cur then
                if cur == target then
                    exact = s
                    break
                elseif _IsSameChainAndNotAbove(cur, target) then
                    chainOK = chainOK or s
                end
            end
        end
    end

    return exact or chainOK
end


-- ===================== Tasking (IDLE / BUILD / ASSIST / EXP) =====================
-- (Hardcoded options per user request)
--  * IDLE timings & radius are fixed; moveRadius == self.params.radius
--  * ASSIST always includes factories and experimentals
--  * EXP requires explicit tasks.exp.bp (no faction table). Engineers return to pool during cooldown.
--  * BUILD uses BaseManager BuildGroup info via standard methods; falls back to queue providers.
--  * Priority: BUILD > ASSIST > EXP > IDLE; IDLE is the pool (no max).

local function _copy(t)
    local o = {}
    for k,v in pairs(t or {}) do o[k] = v end
    return o
end

local function _NormalizeTasks(p)
    local t = p.tasks or {}
    local min = _copy(t.min or {})
    local max = _copy(t.max or {})
    if min.IDLE  == nil then min.IDLE = 0 end
    if min.BUILD == nil then min.BUILD = 0 end
    if min.ASSIST== nil then min.ASSIST= 0 end
    if min.EXP   == nil then min.EXP   = 0 end
    if max.BUILD == nil then max.BUILD = 999 end
    if max.ASSIST== nil then max.ASSIST= 999 end
    if max.EXP   == nil then max.EXP   = 1 end

    local exp = t.exp or {}
    exp.marker = exp.marker or p.baseMarker
    exp.cooldown = exp.cooldown or 0
    -- exp.bp must be provided manually by caller
    exp.bp = exp.bp

    local assist = t.assist or {}
    local idle = t.idle or {}

    local build = t.build or {}

    return { min=min, max=max, exp=exp, assist=assist, idle=idle, build=build }
end

local function _shortBpId(u)
    if unitBpId then return unitBpId(u) end
    if not u then return nil end
    local id = (u.BlueprintID or (u.GetBlueprint and u:GetBlueprint() and u:GetBlueprint().BlueprintId))
    if not id then return nil end
    id = string.lower(id)
    local short = string.match(id, '/units/([^/]+)/') or id
    return short
end

local function _TryIssueBuildMobile(u, bp, pos, facing)
    if not (u and (not u.Dead)) then return false end
    if not bp then return false end

    -- Accept marker names defensively
    if type(pos) == 'string' then
        pos = ScenarioUtils.MarkerToPosition(pos)
    end
    if type(pos) ~= 'table' or not pos[1] or not pos[3] then
        return false
    end

    local cq0 = 0
    if u.GetCommandQueue then
        cq0 = table.getn(u:GetCommandQueue() or {})
    end

    -- NOTE: FAF expects (units, POS, BP, facing)
    IssueBuildMobile({u}, pos, bp, {})

    local cq1 = cq0
    if u.GetCommandQueue then
        cq1 = table.getn(u:GetCommandQueue() or {})
    end
    return cq1 > cq0
end


local function _ForkAttackUnit(brain, unit, attackFn, attackData, tag)
    if not (brain and unit and (not unit.Dead)) then return end
    local name = (tag or 'BE') .. '_ExpAttack_' .. tostring(unit:GetEntityId())
    local p = brain:MakePlatoon(name, '')
    brain:AssignUnitsToPlatoon(p, {unit}, 'Attack', 'GrowthFormation')
    if attackFn then
        local fn = attackFn
        if type(fn) == 'string' then fn = rawget(_G, fn) end
        if type(fn) == 'function' then
            p.PlatoonData = attackData or {}
            p:ForkAIThread(function(pl) return fn(pl, pl.PlatoonData) end)
        end
    end
end

function M:_InitTasking()
    self.tasks = _NormalizeTasks(self.params)
    self.engTask = {}   
    self.expState = { active=false, lastDoneAt=0, startedAt=0, bp=nil, pos=nil }
    self.buildQueue = {}  
end

function M:UpdateTaskPrefs(newPrefs)
    self.params.tasks = self.params.tasks or {}
    for k,v in pairs(newPrefs or {}) do self.params.tasks[k] = v end
    self.tasks = _NormalizeTasks(self.params)
end

function M:PushBuildTask(bp, pos, facing)
    table.insert(self.buildQueue, {bp=bp, pos=pos, facing=facing or 0})
end

function M:ClearBuildQueue() self.buildQueue = {} end

function M:_EnumerateEngineers()
    local list = {}
    for tier, set in pairs(self.tracked or {}) do
        for id, u in pairs(set or {}) do
            if u and (not u.Dead) and isComplete(u) and u:GetAIBrain()==self.brain then
                u._be_tier = tier
                table.insert(list, {id=id, u=u, tier=tier})
            end
        end
    end
    return list
end

function M:_AssignEngineer(id, u, task)
    local prev = self.engTask[id]
    if prev ~= task then
        self.engTask[id] = task
        if u and not u.Dead then
            IssueClearCommands({u})
        end
    end
end

function M:_InitStructTemplate()
    self.struct = { slots = {} }
    local seen = {}

    for _, gname in ipairs(self.params.structGroups or {}) do
        -- NEW: prefer the live units we spawned; fall back to editor group lookup
        local units = (self.structGroupUnits and self.structGroupUnits[gname]) or _TryGetUnitsFromGroup(gname) or {}
        for i = 1, table.getn(units) do
            local u = units[i]
            if _unitIsStructure(u) then
                local targetBp = _bpIdFromUnit(u)
                local pos      = _posOf(u)
                if targetBp and pos then
                    local slot = {
                        bpTarget = targetBp,
                        bpRoot   = _ChainRoot(targetBp) or targetBp,
                        pos      = pos,
                        facing   = _headingOf(u),
                    }
                    local key = string.format('%s@%.1f,%.1f,%.1f', slot.bpTarget, pos[1], pos[2], pos[3])
                    if not seen[key] then
                        table.insert(self.struct.slots, slot)
                        seen[key] = true
                    end
                end
            end
        end
    end

    if self.params.debug then
        self:Dbg(('StructTemplate: %d slots captured from %d group(s)')
            :format(table.getn(self.struct.slots or {}), table.getn(self.params.structGroups or {})))
    end
end

function M:_SyncStructureDemand()
    if not (self.struct and self.struct.slots) then return end

    for _, slot in ipairs(self.struct.slots) do
        local present = _FindStructureForSlot(self.brain, slot)

        if not present then
            -- Missing/destroyed -> build chain root
            self:PushBuildTask(slot.bpRoot, slot.pos, slot.facing or 0)
            if self.params.debug then
                self:Dbg(('Rebuild queued: want=%s (root=%s) at (%.1f,%.1f,%.1f)')
                    :format(slot.bpTarget, slot.bpRoot, slot.pos[1], slot.pos[2], slot.pos[3]))
            end
        else
            local cur = _bpIdFromUnit(present)
            if cur ~= slot.bpTarget then
                -- Same chain and below -> upgrade one step
                if _IsSameChainAndNotAbove(cur, slot.bpTarget) then
                    if present.IsUnitState and not present:IsUnitState('Upgrading') then
                        local nxt = _ChainNext(cur)
                        if nxt then
                            IssueUpgrade({present}, nxt)
                            if self.params.debug then
                                self:Dbg(('Upgrade issued: %s → %s at (%.1f,%.1f,%.1f)')
                                    :format(cur or '?', nxt, slot.pos[1], slot.pos[2], slot.pos[3]))
                            end
                        end
                    end
                else
                    -- Different chain/type very near the slot — likely a neighbor; ignore.
                    -- (No warning spam.)
                end
            end
        end
    end
end


function M:_FindDamagedStructure()
    local pos = self.basePos
    if not pos then return nil end
    local r = self.params.radius or 60
    local around = self.brain:GetUnitsAroundPoint(categories.STRUCTURE, pos, r, 'Ally') or {}
    local i = 1
    while i <= table.getn(around) do
        local s = around[i]
        if s and (not s.Dead) and s.GetHealth and s.GetMaxHealth then
            local hp = s:GetHealth()
            local mx = s:GetMaxHealth()
            if hp and mx and mx > 0 and hp < mx then
                return s
            end
        end
        i = i + 1
    end
    return nil
end

function M:_FindAssistTargets()
    local targ = {}
    local pos = self.basePos
    local r = self.params.radius or 60

    do -- includeFactories always true
        local fac = self.brain:GetUnitsAroundPoint(categories.FACTORY, pos, r, 'Ally') or {}
        local i = 1
        while i <= table.getn(fac) do
            local f = fac[i]
            if f and (not f.Dead) then
                local active = false
                if f.IsUnitState and f:IsUnitState('Building') then active = true end
                if (not active) and f.GetCommandQueue then
                    local q = f:GetCommandQueue() or {}
                    if table.getn(q) > 0 then active = true end
                end
                if active then table.insert(targ, f) end
            end
            i = i + 1
        end
    end

    do -- includeExperimentals always true
        if self.expState.active and self.expState.builder and (not self.expState.builder.Dead) then
            table.insert(targ, self.expState.builder)
        else
            local ex = self.brain:GetUnitsAroundPoint(categories.EXPERIMENTAL, pos, r + 20, 'Ally') or {}
            local j = 1
            while j <= table.getn(ex) do
                local u = ex[j]
                if u and (not u.Dead) and u.IsUnitState and u:IsUnitState('BeingBuilt') then
                    table.insert(targ, u)
                end
                j = j + 1
            end
        end
    end

    return targ
end

function M:_TickIdle(u, id, now)
    if not u or u.Dead then return end
    local s = self:_FindDamagedStructure()
    if s then
        IssueRepair({u}, s)
        return
    end
    local q = (u.GetCommandQueue and u:GetCommandQueue()) or {}
    if table.getn(q) == 0 then
        local pos = self.basePos
        if not pos then return end
        local rr = (self.params.radius or 60) -- hardcoded moveRadius == base radius
        local ox = (Random()*2 - 1) * rr
        local oz = (Random()*2 - 1) * rr
        IssueMove({u}, {pos[1] + ox, pos[2], pos[3] + oz})
    end
end

function M:_TickAssist(u, id, now, targets, distrib)
    if not u or u.Dead then return end
    if table.getn(targets) == 0 then
        self:_AssignEngineer(id, u, 'IDLE')
        return
    end
    local pickIdx = 1
    local bestCount = 999999
    local i = 1
    while i <= table.getn(targets) do
        local t = targets[i]
        if t and (not t.Dead) then
            local tid = t:GetEntityId()
            local c = (distrib[tid] or 0)
            if c < bestCount then
                bestCount = c
                pickIdx = i
            end
        end
        i = i + 1
    end
    local tgt = targets[pickIdx]
    if tgt and (not tgt.Dead) then
        distrib[tgt:GetEntityId()] = (distrib[tgt:GetEntityId()] or 0) + 1
        IssueGuard({u}, tgt)
    else
        self:_AssignEngineer(id, u, 'IDLE')
    end
end

function M:_TickBuild(u, id, now)
    if not u or u.Dead then return end
    if u.IsUnitState and u:IsUnitState('Building') then return end

    local task = table.remove(self.buildQueue, 1)
    if not task then
        self:_AssignEngineer(id, u, 'IDLE')
        return
    end

    local bp = task.bp or task.blueprint or task.bpId
    local pos = task.pos or task.position
    local face = task.facing or 0
    if not (bp and pos) then
        self:Warn('BUILD task missing bp or pos; skipping')
        return
    end

    local landed = _TryIssueBuildMobile(u, bp, pos, face)
    if not landed then
        table.insert(self.buildQueue, 1, {bp=bp, pos=pos, facing=face})
        self:_AssignEngineer(id, u, 'IDLE')
        return
    end

    self.brain:ForkThread(function()
        local waited = 0
        local timeout = 1200
        while not (u.Dead) and waited < timeout do
            WaitSeconds(1)
            waited = waited + 1
            if u.IsUnitState and (not u:IsUnitState('Building')) then
                break
            end
        end
    end)
end

function M:_TickExp(u, id, now)
    if not u or u.Dead then return end
    if not (u._be_tier == 'T3' or u._be_tier == 'SCU') then
        self:_AssignEngineer(id, u, 'IDLE')
        return
    end

    local ex = self.expState
    if (not ex.active) then
        local elapsed = now - (ex.lastDoneAt or 0)
        if elapsed < (self.tasks.exp.cooldown or 0) then
            self:_AssignEngineer(id, u, 'IDLE')
            return
        end
        local marker = self.tasks.exp.marker or self.params.baseMarker
        local pos = marker and ScenarioUtils.MarkerToPosition(marker) or self.basePos
        if not pos then
            self:Warn('EXP: invalid marker/pos; returning engineers to pool')
            self:_AssignEngineer(id, u, 'IDLE')
            return
        end
        if not self.tasks.exp.bp then
            self:_AssignEngineer(id, u, 'IDLE')
            return
        end
        ex.bp = self.tasks.exp.bp
        ex.pos = pos
        ex.startedAt = now
        ex.active = true
        ex.builder = u
    end

    if ex.active and ex.bp and ex.pos then
        _TryIssueBuildMobile(u, ex.bp, ex.pos, 0)
    end
end

function M:_ExpWatcher()
    while not self.stopped do
        if self.expState.active and self.expState.bp and self.expState.pos then
            local pos = self.expState.pos
            local r = 18
            local around = self.brain:GetUnitsAroundPoint(categories.EXPERIMENTAL, pos, r, 'Ally') or {}
            local i = 1
            while i <= table.getn(around) do
                local u = around[i]
                if u and (not u.Dead) and isComplete(u) then
                    local bid = _shortBpId(u)
                    if bid == string.lower(self.expState.bp) then
                        _ForkAttackUnit(self.brain, u, self.tasks.exp.attackFn, self.tasks.exp.attackData, self.tag)
                        self:Dbg('EXP: build complete; handoff + start cooldown')
                        self.expState.active = false
                        self.expState.lastDoneAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0
                        self.expState.bp, self.expState.pos, self.expState.builder = nil, nil, nil
                        for id, task in pairs(self.engTask or {}) do
                            if task == 'EXP' then
                                local e = nil
                                local tierSet = self.tracked
                                if tierSet then
                                    if tierSet.T1 and tierSet.T1[id] then e = tierSet.T1[id] end
                                    if (not e) and tierSet.T2 and tierSet.T2[id] then e = tierSet.T2[id] end
                                    if (not e) and tierSet.T3 and tierSet.T3[id] then e = tierSet.T3[id] end
                                    if (not e) and tierSet.SCU and tierSet.SCU[id] then e = tierSet.SCU[id] end
                                end
                                if e then
                                    self:_AssignEngineer(id, e, 'IDLE')
                                end
                            end
                        end
                        break
                    end
                end
                i = i + 1
            end
        end
        WaitSeconds(1)
    end
end

function M:TaskLoop()
    self:Dbg('TaskLoop start')
    self:_InitTasking()
    self.brain:ForkThread(function() self:_ExpWatcher() end)

    while not self.stopped do
        local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
        local all = self:_EnumerateEngineers()

        -- demand signals (keep local inside TaskLoop)
        local function hasAssistDemand()
            local t = self:_FindAssistTargets() or {}
            return table.getn(t) > 0
        end

        local function hasBuildDemand()
            return (table.getn(self.buildQueue or {}) > 0)
        end

        local function hasExpDemand(now)
            local ex = self.expState or {}
            if ex.active then return true end
            local cfg = (self.tasks and self.tasks.exp) or {}
            if not cfg.bp then return false end
            local elapsed = now - (ex.lastDoneAt or 0)
            if elapsed < (cfg.cooldown or 0) then return false end
            local marker = cfg.marker or self.params.baseMarker
            local pos = marker and ScenarioUtils.MarkerToPosition(marker) or self.basePos
            return pos ~= nil
        end

        local cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
        for _, rec in ipairs(all) do
            local id = rec.id
            local t = self.engTask[id] or 'IDLE'
            cnt[t] = (cnt[t] or 0) + 1
        end

        local function steal(fromList, need)
            if need <= 0 then return 0 end
            local taken = 0
            local idx = 1
            while idx <= table.getn(fromList) do
                local fromTask = fromList[idx]
                for _, rec in ipairs(all) do
                    if taken >= need then break end
                    local id = rec.id
                    if (self.engTask[id] or 'IDLE') == fromTask then
                        self:_AssignEngineer(id, rec.u, 'IDLE')
                        cnt[fromTask] = (cnt[fromTask] or 0) - 1
                        cnt.IDLE = (cnt.IDLE or 0) + 1
                        taken = taken + 1
                    end
                end
                if taken >= need then break end
                idx = idx + 1
            end
            return taken
        end

        -- helper: move up to `need` IDLE engineers into `task`
        local function promote(task, need, filterFn)
            if need <= 0 then return 0 end
            local moved = 0
            for _, rec in ipairs(all) do
                if moved >= need then break end
                local id, u, tier = rec.id, rec.u, rec.tier
                local cur = self.engTask[id] or 'IDLE'
                if cur == 'IDLE' and (not filterFn or filterFn(rec)) then
                    self:_AssignEngineer(id, u, task)
                    moved = moved + 1
                    if self.params.debug then self:Dbg(('Promote %s -> %s'):format(id, task)) end
                end
            end
            return moved
        end

        -- ---------- ensure minimums (Build > Assist > Exp), but only if there is demand ----------
        local min = self.tasks.min

        local needBuild  = math.max(0, (min.BUILD  or 0) - (cnt.BUILD  or 0))
        if needBuild > 0 and hasBuildDemand() then
            promote('BUILD', needBuild)
        end
        cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
        for _, rec in ipairs(all) do cnt[self.engTask[rec.id] or 'IDLE'] = (cnt[self.engTask[rec.id] or 'IDLE'] or 0) + 1 end

        local needAssist = math.max(0, (min.ASSIST or 0) - (cnt.ASSIST or 0))
        if needAssist > 0 and hasAssistDemand() then
            promote('ASSIST', needAssist)
        end
        cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
        for _, rec in ipairs(all) do cnt[self.engTask[rec.id] or 'IDLE'] = (cnt[self.engTask[rec.id] or 'IDLE'] or 0) + 1 end

        local needExp    = math.max(0, (min.EXP    or 0) - (cnt.EXP    or 0))
        if needExp > 0 and hasExpDemand(now) then
            -- gate EXP to T3/SCU only
            promote('EXP', needExp, function(rec) return rec.tier == 'T3' or rec.tier == 'SCU' end)
        end
        cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
        for _, rec in ipairs(all) do cnt[self.engTask[rec.id] or 'IDLE'] = (cnt[self.engTask[rec.id] or 'IDLE'] or 0) + 1 end

        -- ---------- if minimums are met, top up to caps, still demand-gated ----------
        local minsMet = (cnt.BUILD >= (min.BUILD or 0)) and (cnt.ASSIST >= (min.ASSIST or 0)) and (cnt.EXP >= (min.EXP or 0))
        if minsMet then
            local max = self.tasks.max

            local capBuild  = math.max(0, (max.BUILD  or 0) - (cnt.BUILD  or 0))
            if capBuild > 0 and hasBuildDemand() then
                promote('BUILD', math.min(capBuild, cnt.IDLE or 0))
                cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
                for _, rec in ipairs(all) do cnt[self.engTask[rec.id] or 'IDLE'] = (cnt[self.engTask[rec.id] or 'IDLE'] or 0) + 1 end
            end

            local capAssist = math.max(0, (max.ASSIST or 0) - (cnt.ASSIST or 0))
            if capAssist > 0 and hasAssistDemand() then
                promote('ASSIST', math.min(capAssist, cnt.IDLE or 0))
                cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
                for _, rec in ipairs(all) do cnt[self.engTask[rec.id] or 'IDLE'] = (cnt[self.engTask[rec.id] or 'IDLE'] or 0) + 1 end
            end

            local capExp    = math.max(0, (max.EXP    or 0) - (cnt.EXP    or 0))
            if capExp > 0 and hasExpDemand(now) then
                promote('EXP', math.min(capExp, cnt.IDLE or 0), function(rec) return rec.tier == 'T3' or rec.tier == 'SCU' end)
                cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
                for _, rec in ipairs(all) do cnt[self.engTask[rec.id] or 'IDLE'] = (cnt[self.engTask[rec.id] or 'IDLE'] or 0) + 1 end
            end
        end

        local assistTargets = self:_FindAssistTargets()
        local distrib = {}
        for _, rec in ipairs(all) do
            local id, u = rec.id, rec.u
            local t = self.engTask[id] or 'IDLE'
            if t == 'BUILD' then
                self:_TickBuild(u, id, now)
            elseif t == 'ASSIST' then
                self:_TickAssist(u, id, now, assistTargets, distrib)
            elseif t == 'EXP' then
                self:_TickExp(u, id, now)
            else
                self:_TickIdle(u, id, now)
            end
        end

        for _, rec in ipairs(all) do
            local id = rec.id
            if not self.engTask[id] then
                self:_AssignEngineer(id, rec.u, 'IDLE')
            end
        end

        WaitSeconds(1)
    end
    self:Dbg('TaskLoop end')
end
-- ===================== Threads =====================
function M:MonitorLoop()
    self:Dbg('MonitorLoop start')
    while not self.stopped do
        self:_SyncStructureDemand()
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
    self:_CreateStructGroups()
    self:_InitStructTemplate()
    self.monitorThread = self.brain:ForkThread(function() self:MonitorLoop() end)
    self.taskThread = self.brain:ForkThread(function() self:TaskLoop() end)
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
    if self.taskThread then
        KillThread(self.taskThread)
        self.taskThread = nil
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
        structGroups = p.structGroups,
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

    o.structGroupUnits = {}

    o:Start()
    return o
end

function Stop(handle)
    if handle and handle.Stop then handle:Stop() end
end

return { Start = Start, Stop = Stop }
