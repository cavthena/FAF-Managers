--[[
================================================================================
 Base Engineer Manager
================================================================================

Overview
    Spawns a base layout, keeps a dedicated engineer platoon alive, rebuilds/repairs
    structures, manages experimental projects, and exposes a factory allocator
    that other systems (such as manager_UnitBuilder) can lease through. Also
    maintains an untagged master platoon for freshly completed units.

Usage
    local BaseManager = import('/maps/.../manager_BaseEngineer.lua')
    local baseHandle = BaseManager.Start{
        brain        = ArmyBrains[armyIndex],         -- required
        baseMarker   = 'Base_Marker',                 -- required Scenario marker name
        baseTag      = 'UEF_Main',                    -- required unique tag used for lookups/logging
        radius       = 70,                            -- required operating radius for engineers/factories
        structGroups = {'BaseLayout_T1', 'BaseWalls'},-- required army group names to spawn
        engineers    = {                              -- required engineer headcount per tier/difficulty
            T1  = {3, 4, 5},                          -- {easy, normal, hard}; accepts tier index tables too
            T2  = {1, 2, 2},
            T3  = {0, 1, 1},
            SCU = {0, 0, 1},
        },

        difficulty   = ScenarioInfo.Options.Difficulty or 2, -- optional, clamped 1..3 (default 2)
        spawnSpread  = 2,                                    -- optional engineer spread when respawning
        engineerFactoryPriority = 200,                       -- optional build request priority (0..200)
        engineerFactoryCount    = 1,                         -- optional factories to lease for engineers (0:any)
        factoryStallTimeout     = 30,                        -- optional seconds before idle leases are revoked (default 30)
        masterInterval          = 1,                         -- optional seconds between master platoon sweeps
        tasks = {                                            -- optional engineer task preferences
            weights = { BUILD = 1.0, ASSIST = 1.0, EXP = 1.25 }, -- severity multipliers (higher == more coverage)
            exp     = { marker = 'Base_Marker', cooldown = 0, bp = nil, attackFn = nil, attackData = {} }, -- experimental build config
        },
        debug = false,
    }

Public API
    BaseManager.Start(params)
        Creates (or refreshes) the named base and returns a handle. The handle
        is also stored in ScenarioInfo.BaseManagers[baseTag].

    BaseManager.Stop(handle)
        Stops and cleans up the provided base handle.

    BaseManager.GetBase(baseTag)
        Returns the base handle previously created with Start.

    Handle methods
        baseHandle:RequestFactories{ priority, want, domain, markerPos/markerName, radius }
            -- Requests asking for 0 factories are treated as "take what you can" but will share fairly with other leases
        baseHandle:ReturnLease(leaseId[, reason])
            -- Leases revoked for stalls trigger `reason == 'stall'` before being removed
        baseHandle:GetGrantedUnits(leaseId)
        baseHandle:GetMasterPlatoon()
        baseHandle:PushEngineerBuildTask(bpId, positionOrMarker, facing)
        baseHandle:AssignEngineerUnit(unitOrPlatoon)
            -- Accepts a single unit or platoon; valid types are T1/T2/T3/SCU/ACU engineers
        baseHandle:UpdateEngineerTasks(preferencesTable)
            -- Accepts Start.tasks fields (weights/exp) to tweak severity or experimental config at runtime
        baseHandle:GetStructureSnapshot()
        baseHandle:AddBuildGroup(structGroupName)
        baseHandle:RemoveBuildGroup(structGroupName)
        baseHandle:ReplaceBuildGroup(oldGroupName, newGroupName)
        baseHandle:GetEngineerHandle()
        baseHandle:Stop()

    Legacy helpers (advanced)
        BaseManager.StartEngineer(params)
        BaseManager.StopEngineer(handle)
        These expose only the engineer subsystem for specialized scenarios.
]]

local ScenarioUtils     = import('/lua/sim/ScenarioUtilities.lua')

-- faction maps (1 UEF, 2 Aeon, 3 Cybran, 4 Seraphim)
local EngBp = {
    [1] = { T1='uel0105', T2='uel0208', T3='uel0309', SCU='uel0301' },
    [2] = { T1='ual0105', T2='ual0208', T3='ual0309', SCU='ual0301' },
    [3] = { T1='url0105', T2='url0208', T3='url0309', SCU='url0301' },
    [4] = { T1='xsl0105', T2='xsl0208', T3='xsl0309', SCU='xsl0301' },
}
local ACUBp = {
    [1] = 'uel0001',
    [2] = 'ual0001',
    [3] = 'url0001',
    [4] = 'xsl0001',
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

local function _safeIs(u, state)
    if not (u and u.IsUnitState and (not u.Dead)) then return false end
    local ok, res = pcall(function() return u:IsUnitState(state) end)
    return ok and res or false
end

local function isComplete(u)
    if not u or u.Dead then return false end
    if u.GetFractionComplete and u:GetFractionComplete() < 1 then return false end
    if _safeIs(u, 'BeingBuilt') then return false end
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

local function _EnsureEngineerPlatoon(brain, name)
    if not (brain and name) then return nil end
    local platoon = nil
    if brain.GetPlatoonUniquelyNamed then
        platoon = brain:GetPlatoonUniquelyNamed(name)
        if platoon then
            return platoon
        end
    end
    return brain:MakePlatoon(name, '')
end

local function _EnsureMasterPlatoon(brain, name)
    if not (brain and name) then return nil end
    local platoon = nil
    if brain.GetPlatoonUniquelyNamed then
        platoon = brain:GetPlatoonUniquelyNamed(name)
        if platoon then
            return platoon
        end
    end
    return brain:MakePlatoon(name, '')
end

local function _RegisterEngineerPlatoon(name, platoon)
    if not (name and platoon) then return end
    ScenarioInfo.BaseEngineerPlatoons = ScenarioInfo.BaseEngineerPlatoons or {}
    ScenarioInfo.BaseEngineerPlatoons[name] = platoon
end

local function _safeCQ(u)
    if not (u and u.GetCommandQueue and (not u.Dead)) then return {} end
    local ok, res = pcall(function() return u:GetCommandQueue() end)
    if ok and type(res) == 'table' then return res end
    return {}
end

local M = {}
M.__index = M

function M:Log(msg) LOG(('[BE:%s] %s'):format(self.tag, msg)) end
function M:Warn(msg) WARN(('[BE:%s] %s'):format(self.tag, msg)) end
function M:Dbg(msg) if self.params.debug then self:Log(msg) end end

function M:_FindEngineerPlatoon()
    if not (self.brain and self.platoonName) then return nil end
    local platoon = nil
    if self.brain.GetPlatoonUniquelyNamed then
        platoon = self.brain:GetPlatoonUniquelyNamed(self.platoonName)
    end
    if not platoon then
        local existing = self.engineerPlatoon
        if existing and self.brain.PlatoonExists and self.brain:PlatoonExists(existing) then
            platoon = existing
        end
    end
    if platoon then
        self.engineerPlatoon = platoon
        _RegisterEngineerPlatoon(self.platoonName, platoon)
    end
    return platoon
end

function M:_GetEngineerPlatoon()
    local platoon = self:_FindEngineerPlatoon()
    if platoon then return platoon end
    if not (self.brain and self.platoonName) then return nil end
    platoon = _EnsureEngineerPlatoon(self.brain, self.platoonName)
    if platoon then
        self.engineerPlatoon = platoon
        _RegisterEngineerPlatoon(self.platoonName, platoon)
    end
    return platoon
end

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
    end
end

local function _TierForEngineer(u, faction)
    local bp = unitBpId(u)
    if not bp then return nil end
    local map = EngBp[faction] or EngBp[1]
    if bp == map.T1 then return 'T1' end
    if bp == map.T2 then return 'T2' end
    if bp == map.T3 then return 'T3' end
    if bp == map.SCU then return 'SCU' end
    if bp == (ACUBp[faction] or ACUBp[1]) then return 'SCU' end -- treat ACU as SCU tier for tasking
    return nil
end

function M:_AbsorbEngineerUnit(u)
    if not (u and not u.Dead and self.brain and u:GetAIBrain() == self.brain) then return false end
    if u.be_tag and u.be_tag ~= self.tag then return false end
    local tier = _TierForEngineer(u, self.faction)
    if not tier then return false end

    self.engTask = self.engTask or {}

    -- already ours? ensure bookkeeping is present
    if u.be_tag == self.tag then
        local id = u:GetEntityId()
        self.tracked[tier] = self.tracked[tier] or {}
        if not self.tracked[tier][id] then
            self.tracked[tier][id] = u
            self.engTask[id] = self.engTask[id] or 'IDLE'
        end
        return true
    end

    self:_TagAndTrack(u, tier)
    return true
end

function M:AssignEngineerUnits(units)
    if not units then return 0 end
    local assigned = 0
    if units.GetPlatoonUnits then
        units = units:GetPlatoonUnits() or {}
    elseif units.GetAIBrain then
        units = {units}
    end
    if type(units) ~= 'table' then
        return 0
    end
    for _, u in ipairs(units) do
        if self:_AbsorbEngineerUnit(u) then
            assigned = assigned + 1
        end
    end
    return assigned
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

    if self.brain and self.brain.AssignUnitsToPlatoon then
        local platoon = self:_GetEngineerPlatoon()
        if platoon then
            self.brain:AssignUnitsToPlatoon(platoon, {u}, 'Support', 'None')
        end
    end

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
        else
            -- Create the group for our brain's army
            local ok, units = pcall(function()
                return ScenarioUtils.CreateArmyGroup(armyName, gname, false)
            end)
            if ok then
                -- NEW: remember the actual unit instances we just created
                self.structGroupUnits = self.structGroupUnits or {}
                self.structGroupUnits[gname] = units or {}
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

function M:_ReleaseLeaseLocal(reason)
    local leaseId = self.leaseId
    self.leaseId = nil
    self.leased = {}
    self.pending = {}
    if leaseId then
        self.alloc:ReturnLease(leaseId, reason)
    end
end

function M:OnLeaseGranted(factories, leaseId)
    if self.stopped then return end
    if leaseId ~= self.leaseId then return end
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
    self:QueueNeededBuilds()
end

function M:OnLeaseUpdated(factories, leaseId)
    if self.stopped then return end
    if leaseId ~= self.leaseId then return end
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
                local up = _safeIs(f, 'Upgrading')
                local gd = _safeIs(f, 'Guarding')
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
            self:_ReleaseLeaseLocal()
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
--  * IDLE timings & radius are fixed; moveRadius == self.params.radius
--  * ASSIST always includes factories and experimentals
--  * EXP requires explicit tasks.exp.bp (no faction table). Engineers return to pool during cooldown.
--  * BUILD uses BaseManager BuildGroup info via standard methods; falls back to queue providers.
--  * Severity weights determine how many engineers pursue BUILD/ASSIST/EXP; IDLE is the shared pool.

local function _copy(t)
    local o = {}
    for k,v in pairs(t or {}) do o[k] = v end
    return o
end

local function _NormalizeTasks(p)
    local t = p.tasks or {}
    local weights = _copy(t.weights or {})
    if weights.BUILD == nil then weights.BUILD = 1.0 end
    if weights.ASSIST == nil then weights.ASSIST = 1.0 end
    if weights.EXP == nil then weights.EXP = 1.25 end

    local exp = _copy(t.exp or {})
    exp.marker = exp.marker or p.baseMarker
    exp.cooldown = exp.cooldown or 0
    exp.bp = exp.bp

    return { weights = weights, exp = exp }
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
    self.activeBuilds = {}
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

function M:_IsBuildLocked(id, u)
    if not (self.activeBuilds and id) then return false end
    local rec = self.activeBuilds[id]
    if not rec then return false end

    local target = rec.target
    if target and (target.Dead or isComplete(target)) then
        self.activeBuilds[id] = nil
        return false
    end

    if _safeIs(u, 'Building') then
        return true
    end

    if target and (not target.Dead) then
        return true
    end

    local cq = _safeCQ(u)
    if table.getn(cq) > 0 then
        return true
    end

    local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
    if (now - (rec.startedAt or now)) < 10 then
        return true
    end

    self.activeBuilds[id] = nil
    return false
end

function M:_WatchBuild(u, id, rec)
    while not self.stopped and self.activeBuilds and self.activeBuilds[id] == rec do
        if not (u and not u.Dead) then
            break
        end

        if (not rec.target) or rec.target.Dead then
            rec.target = u.UnitBeingBuilt or (u.GetFocusUnit and u:GetFocusUnit())
        end

        local target = rec.target
        if target and isComplete(target) then
            break
        end

        local cq = _safeCQ(u)
        if _safeIs(u, 'Building') or (target and (not target.Dead)) or table.getn(cq) > 0 then
            WaitSeconds(1)
        else
            local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
            local elapsed = now - (rec.startedAt or now)
            if elapsed < 10 then
                WaitSeconds(1)
            else
                break
            end
        end
    end

    if self.activeBuilds and self.activeBuilds[id] == rec then
        self.activeBuilds[id] = nil
        if not self.stopped then
            self:_AssignEngineer(id, u, 'IDLE')
        end
    end
end

function M:_AssignEngineer(id, u, task)
    if task ~= 'BUILD' and self:_IsBuildLocked(id, u) then
        return
    end

    local prev = self.engTask[id]
    if prev ~= task then
        self.engTask[id] = task
        if u and not u.Dead then
            IssueClearCommands({u})
        end
    end
end

local function _SpecPosition(spec)
    if not spec then return nil end
    return spec.Position or spec.position or spec.Pos or spec.pos
end

local function _SpecFacing(spec)
    if not spec then return 0 end
    local o = spec.Orientation or spec.orientation or {}
    return o[1] or 0
end

local function _SpecBlueprintId(spec)
    if not spec then return nil end
    local id = spec.type or spec.bp or spec.bpId or spec.BlueprintId or spec.blueprintId or spec.UnitId
    if type(id) == 'string' then
        return string.lower(id)
    end
    return nil
end

function M:_StructKey(bp, pos)
    if not (bp and pos and pos[1] and pos[3]) then return nil end
    return string.format('%s@%.1f,%.1f,%.1f', bp, pos[1], pos[2] or 0, pos[3])
end

function M:_StructPosKey(pos)
    if not (pos and pos[1] and pos[3]) then return nil end
    return string.format('%.1f,%.1f,%.1f', pos[1], pos[2] or 0, pos[3])
end

local function _TaskPosition(task)
    if not task then return nil end
    local pos = task.pos or task.position
    if type(pos) == 'string' then
        pos = ScenarioUtils.MarkerToPosition(pos)
    end
    return pos
end

function M:_HasQueuedBuildForKey(key)
    if not key then return false end
    for _, task in ipairs(self.buildQueue or {}) do
        local bp = task.bp or task.blueprint or task.bpId
        local pos = _TaskPosition(task)
        if self:_StructKey(bp, pos) == key then
            return true
        end
    end
    return false
end

function M:_ConsumeBuildTaskByKey(key)
    if not key then return nil end
    for idx, task in ipairs(self.buildQueue or {}) do
        local bp = task.bp or task.blueprint or task.bpId
        local pos = _TaskPosition(task)
        if self:_StructKey(bp, pos) == key then
            return table.remove(self.buildQueue, idx)
        end
    end
    return nil
end

local function _Distance2DSq(a, b)
    if not (a and b and a[1] and a[3] and b[1] and b[3]) then return math.huge end
    local dx = a[1] - b[1]
    local dz = a[3] - b[3]
    return dx*dx + dz*dz
end

function M:_BuildTasks()
    local tasks = {}
    local seen = {}
    for _, task in ipairs(self.buildQueue or {}) do
        local bp = task.bp or task.blueprint or task.bpId
        local pos = _TaskPosition(task)
        local key = self:_StructKey(bp, pos)
        if bp and pos and key and (not seen[key]) then
            table.insert(tasks, { task = task, key = key })
            seen[key] = true
        end
    end
    return tasks
end

function M:_PlanBuildAssignments(builders, tasks)
    local plan = {}
    tasks = tasks or self:_BuildTasks()
    if table.getn(tasks) == 0 or table.getn(builders or {}) == 0 then
        return plan
    end

    local unclaimed = {}
    for _, entry in ipairs(tasks) do
        table.insert(unclaimed, entry)
    end

    local function pickNearest(unit, pool)
        if not (unit and unit.GetPosition) then return nil end
        local uPos = unit:GetPosition()
        local bestIdx, bestDist
        for idx, entry in ipairs(pool) do
            local pos = _TaskPosition(entry.task)
            local dist = _Distance2DSq(uPos, pos)
            if not bestDist or dist < bestDist then
                bestDist = dist
                bestIdx = idx
            end
        end
        return bestIdx
    end

    local available = table.getn(unclaimed)
    for _, rec in ipairs(builders) do
        local pool = (available > 0) and unclaimed or tasks
        local pickIdx = pickNearest(rec.u, pool)
        if pickIdx then
            local entry = pool[pickIdx]
            plan[rec.id] = {
                task    = entry.task,
                key     = entry.key,
                primary = (available > 0),
            }
            if available > 0 then
                table.remove(unclaimed, pickIdx)
                available = available - 1
            end
        end
    end

    return plan
end

function M:_EnsureStructState()
    self.struct = self.struct or { slots = {} }
    self.structKeys = self.structKeys or {}
end

function M:_GetGroupUnitsOrSpec(gname)
    if not gname then return {}, false end

    local liveUnits = (self.structGroupUnits and self.structGroupUnits[gname]) or _TryGetUnitsFromGroup(gname) or {}
    if table.getn(liveUnits) > 0 then
        return liveUnits, true
    end

    local armyName = _ArmyNameFromBrain(self.brain)
    if armyName and ScenarioUtils.AssembleArmyGroup then
        local ok, spec = pcall(function() return ScenarioUtils.AssembleArmyGroup(armyName, gname) end)
        if ok and type(spec) == 'table' and next(spec) then
            return spec, false
        end
    end

    return {}, false
end

function M:_AbsorbStructGroup(gname)
    if not gname then return 0 end
    self:_EnsureStructState()

    local slotsAdded = 0
    local slots, isLive = self:_GetGroupUnitsOrSpec(gname)

    local function addSlot(bpTarget, pos, facing)
        if not (bpTarget and pos and pos[1] and pos[3]) then return end
        local target = string.lower(bpTarget)
        local key = self:_StructKey(target, pos)
        if key and not self.structKeys[key] then
            table.insert(self.struct.slots, {
                bpTarget = target,
                bpRoot   = _ChainRoot(target) or target,
                pos      = pos,
                facing   = facing or 0,
            })
            self.structKeys[key] = true
            slotsAdded = slotsAdded + 1
        end
    end

    if isLive then
        for i = 1, table.getn(slots) do
            local u = slots[i]
            if _unitIsStructure(u) then
                addSlot(_bpIdFromUnit(u), _posOf(u), _headingOf(u))
            end
        end
    else
        for _, spec in pairs(slots or {}) do
            addSlot(_SpecBlueprintId(spec), _SpecPosition(spec), _SpecFacing(spec))
        end
    end

    return slotsAdded
end

function M:_CollectStructGroupSlots(gname)
    if not gname then return {} end
    local slots, isLive = self:_GetGroupUnitsOrSpec(gname)
    local collected = {}

    local function addSlot(bpTarget, pos, facing)
        if not (bpTarget and pos and pos[1] and pos[3]) then return end
        local target = string.lower(bpTarget)
        local key = self:_StructKey(target, pos)
        local posKey = self:_StructPosKey(pos)
        if key then
            table.insert(collected, {
                bpTarget = target,
                bpRoot   = _ChainRoot(target) or target,
                pos      = pos,
                facing   = facing or 0,
                key      = key,
                posKey   = posKey,
            })
        end
    end

    if isLive then
        for i = 1, table.getn(slots) do
            local u = slots[i]
            if _unitIsStructure(u) then
                addSlot(_bpIdFromUnit(u), _posOf(u), _headingOf(u))
            end
        end
    else
        for _, spec in pairs(slots or {}) do
            addSlot(_SpecBlueprintId(spec), _SpecPosition(spec), _SpecFacing(spec))
        end
    end

    return collected
end

function M:_CollectStructSlotsForGroups(groups)
    local slots = {}
    local keySet = {}
    local posSet = {}

    for _, gname in ipairs(groups or {}) do
        for _, slot in ipairs(self:_CollectStructGroupSlots(gname)) do
            if slot.key and not keySet[slot.key] then
                table.insert(slots, {
                    bpTarget = slot.bpTarget,
                    bpRoot   = slot.bpRoot,
                    pos      = slot.pos,
                    facing   = slot.facing,
                })
                keySet[slot.key] = true
            end
            if slot.posKey then
                posSet[slot.posKey] = true
            end
        end
    end

    return slots, keySet, posSet
end

function M:_GetLiveEngineers()
    local engineers = {}
    for _, tier in pairs(self.tracked or {}) do
        for _, unit in pairs(tier or {}) do
            if unit and (not unit.Dead) and unit.GetAIBrain and unit:GetAIBrain() == self.brain then
                table.insert(engineers, unit)
            end
        end
    end
    return engineers
end

function M:_IssueReclaimTargets(targets)
    if table.getn(targets or {}) == 0 then return 0 end
    local engineers = self:_GetLiveEngineers()
    if table.getn(engineers) == 0 then return 0 end
    local issued = 0
    for _, target in ipairs(targets) do
        if target and not target.Dead then
            IssueReclaim(engineers, target)
            issued = issued + 1
        end
    end
    return issued
end

function M:_InitStructTemplate()
    self.struct = { slots = {} }
    self.structKeys = {}

    local total = 0
    for _, gname in ipairs(self.params.structGroups or {}) do
        total = total + (self:_AbsorbStructGroup(gname) or 0)
    end
end

function M:AddBuildGroup(gname)
    if not gname then return 0 end
    self.params.structGroups = self.params.structGroups or {}
    local exists = false
    for _, name in ipairs(self.params.structGroups) do
        if name == gname then
            exists = true
            break
        end
    end
    if not exists then
        table.insert(self.params.structGroups, gname)
    end

    local added = self:_AbsorbStructGroup(gname) or 0
    if added > 0 then
        self:_SyncStructureDemand()
    end
    return added
end

function M:RemoveBuildGroup(gname)
    if not gname then return 0 end
    self.params.structGroups = self.params.structGroups or {}

    local updated = {}
    local removed = false
    for _, name in ipairs(self.params.structGroups) do
        if name ~= gname then
            table.insert(updated, name)
        else
            removed = true
        end
    end
    if not removed then return 0 end

    local removedSlots = self:_CollectStructGroupSlots(gname)
    self.params.structGroups = updated

    local newSlots, newKeySet, newPosSet = self:_CollectStructSlotsForGroups(updated)

    local reclaimTargets = {}
    local removedCount = 0
    for _, slot in ipairs(removedSlots) do
        if slot.key and not newKeySet[slot.key] then
            self:_ConsumeBuildTaskByKey(slot.key)
            removedCount = removedCount + 1
        end
        if slot.posKey and not newPosSet[slot.posKey] then
            local present = _FindStructureForSlot(self.brain, slot)
            if present then
                table.insert(reclaimTargets, present)
            end
        end
    end

    self.struct = { slots = newSlots }
    self.structKeys = newKeySet

    self:_IssueReclaimTargets(reclaimTargets)
    self:_SyncStructureDemand()
    return removedCount
end

function M:ReplaceBuildGroup(oldGroup, newGroup)
    if not (oldGroup and newGroup) then return 0 end
    self.params.structGroups = self.params.structGroups or {}

    local updated = {}
    local removed = false
    local seenNew = false
    for _, name in ipairs(self.params.structGroups) do
        if name == oldGroup then
            removed = true
        else
            if name == newGroup then
                seenNew = true
            end
            table.insert(updated, name)
        end
    end
    if not seenNew then
        table.insert(updated, newGroup)
    end
    if not removed and seenNew then
        return 0
    end

    local removedSlots = self:_CollectStructGroupSlots(oldGroup)
    self.params.structGroups = updated

    local newSlots, newKeySet, newPosSet = self:_CollectStructSlotsForGroups(updated)
    local reclaimTargets = {}
    local removedCount = 0
    for _, slot in ipairs(removedSlots) do
        if slot.key and not newKeySet[slot.key] then
            self:_ConsumeBuildTaskByKey(slot.key)
            removedCount = removedCount + 1
        end
        if slot.posKey and not newPosSet[slot.posKey] then
            local present = _FindStructureForSlot(self.brain, slot)
            if present then
                table.insert(reclaimTargets, present)
            end
        end
    end

    self.struct = { slots = newSlots }
    self.structKeys = newKeySet

    self:_IssueReclaimTargets(reclaimTargets)
    self:_SyncStructureDemand()
    return removedCount
end

function M:_SyncStructureDemand()
    if not (self.struct and self.struct.slots) then return end

    for _, slot in ipairs(self.struct.slots) do
        local present = _FindStructureForSlot(self.brain, slot)

        if not present then
            -- Missing/destroyed -> build chain root
            local key = self:_StructKey(slot.bpRoot, slot.pos)
            if not self:_HasQueuedBuildForKey(key) then
                self:PushBuildTask(slot.bpRoot, slot.pos, slot.facing or 0)
            end
        else
            local cur = _bpIdFromUnit(present)
            if cur ~= slot.bpTarget then
                -- Same chain and below -> upgrade one step
                if _IsSameChainAndNotAbove(cur, slot.bpTarget) then
                    if not _safeIs(present, 'Upgrading') then
                        local nxt = _ChainNext(cur)
                        if nxt then
                            IssueUpgrade({present}, nxt)
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
                local active = _safeIs(f, 'Building')
                if (not active) then
                    local q = _safeCQ(f)
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
                if u and (not u.Dead) and _safeIs(u, 'BeingBuilt') then
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

function M:_TickBuild(u, id, now, assignment)
    if not u or u.Dead then return end
    self.activeBuilds = self.activeBuilds or {}
    if _safeIs(u, 'Building') then
        if not self.activeBuilds[id] then
            local rec = { startedAt = now }
            self.activeBuilds[id] = rec
            self.brain:ForkThread(function() self:_WatchBuild(u, id, rec) end)
        end
        return
    end

    local task = assignment and assignment.task
    if assignment and assignment.primary and assignment.key then
        self:_ConsumeBuildTaskByKey(assignment.key)
    end

    if not task then
        task = table.remove(self.buildQueue, 1)
    end
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
        local shouldRequeue = (not assignment) or assignment.primary
        if shouldRequeue then
            table.insert(self.buildQueue, 1, {bp=bp, pos=pos, facing=face})
        end
        self:_AssignEngineer(id, u, 'IDLE')
        return
    end

    local rec = { bp = bp, pos = pos, facing = face, key = assignment and assignment.key, startedAt = now }
    self.activeBuilds[id] = rec
    self.brain:ForkThread(function() self:_WatchBuild(u, id, rec) end)
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
    self:_InitTasking()
    self.brain:ForkThread(function() self:_ExpWatcher() end)

    while not self.stopped do
        local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
        local all = self:_EnumerateEngineers()
        local assistTargets = self:_FindAssistTargets() or {}
        local assistCount = table.getn(assistTargets)
        local buildTasks = self:_BuildTasks()
        local buildDemand = table.getn(buildTasks)

        local function computeExpDemand(ts)
            local ex = self.expState or {}
            if ex.active then return 1, true end
            local cfg = (self.tasks and self.tasks.exp) or {}
            if not cfg.bp then return 0, false end
            local elapsed = ts - (ex.lastDoneAt or 0)
            if elapsed < (cfg.cooldown or 0) then return 0, false end
            local marker = cfg.marker or self.params.baseMarker
            local pos = marker and ScenarioUtils.MarkerToPosition(marker) or self.basePos
            if not pos then return 0, false end
            return 1, false
        end

        local expDemand, expActive = computeExpDemand(now)

        local weights = (self.tasks and self.tasks.weights) or {}
        local severity = {
            BUILD = (buildDemand > 0) and ((1 + buildDemand) * (weights.BUILD or 1.0)) or 0,
            ASSIST = (assistCount > 0) and ((1 + assistCount) * (weights.ASSIST or 1.0)) or 0,
            EXP   = (expDemand > 0) and (((expActive and 2) or 1) * (weights.EXP or 1.25)) or 0,
        }

        local cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
        for _, rec in ipairs(all) do
            local id = rec.id
            local t = self.engTask[id] or 'IDLE'
            cnt[t] = (cnt[t] or 0) + 1
        end

        local function recount()
            cnt = { IDLE=0, BUILD=0, ASSIST=0, EXP=0 }
            for _, rec in ipairs(all) do
                local id = rec.id
                local t = self.engTask[id] or 'IDLE'
                cnt[t] = (cnt[t] or 0) + 1
            end
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
                        taken = taken + 1
                    end
                end
                if taken >= need then break end
                idx = idx + 1
            end
            if taken > 0 then recount() end
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
                end
            end
            if moved > 0 then recount() end
            return moved
        end

        local severityList = {
            { task = 'BUILD', score = severity.BUILD },
            { task = 'ASSIST', score = severity.ASSIST },
            { task = 'EXP',   score = severity.EXP },
        }
        table.sort(severityList, function(a, b)
            if a.score == b.score then return a.task < b.task end
            return a.score > b.score
        end)

        local severitySum = 0
        for _, entry in ipairs(severityList) do
            severitySum = severitySum + (entry.score or 0)
        end

        local totalEng = table.getn(all)
        local desired = { BUILD = 0, ASSIST = 0, EXP = 0 }
        local taskCaps = { BUILD = buildDemand, ASSIST = assistCount, EXP = expDemand }
        local eligibleExp = 0
        if expDemand > 0 then
            for _, rec in ipairs(all) do
                if rec.tier == 'T3' or rec.tier == 'SCU' then
                    eligibleExp = eligibleExp + 1
                end
            end
            taskCaps.EXP = math.min(expDemand, eligibleExp)
        end

        if severitySum > 0 and totalEng > 0 then
            local remaining = totalEng
            for _, entry in ipairs(severityList) do
                if (entry.score or 0) <= 0 then break end
                local share = entry.score / severitySum
                local want = math.floor((share * totalEng) + 0.5)
                if want < 1 then want = 1 end
                if want > remaining then want = remaining end
                desired[entry.task] = want
                remaining = remaining - want
                if remaining <= 0 then break end
            end

            local allocated = desired.BUILD + desired.ASSIST + desired.EXP
            local leftover = totalEng - allocated
            local idx = 1
            while leftover > 0 and idx <= table.getn(severityList) do
                local entry = severityList[idx]
                if (entry.score or 0) > 0 then
                    desired[entry.task] = desired[entry.task] + 1
                    leftover = leftover - 1
                else
                    break
                end
                idx = idx + 1
                if idx > table.getn(severityList) then idx = 1 end
            end
        end

        if buildDemand <= 0 then desired.BUILD = 0 end
        if assistCount <= 0 then desired.ASSIST = 0 end

        if taskCaps.EXP <= 0 then
            desired.EXP = 0
        elseif eligibleExp > 0 then
            desired.EXP = math.max(1, math.min(desired.EXP, taskCaps.EXP, eligibleExp))
        end

        if taskCaps.BUILD > 0 then
            desired.BUILD = math.min(desired.BUILD, taskCaps.BUILD)
        end
        if taskCaps.ASSIST > 0 then
            desired.ASSIST = math.min(desired.ASSIST, taskCaps.ASSIST)
        end

        local allocatedAfterCap = desired.BUILD + desired.ASSIST + desired.EXP
        if allocatedAfterCap > totalEng then
            local excess = allocatedAfterCap - totalEng
            for idx = table.getn(severityList), 1, -1 do
                if excess <= 0 then break end
                local task = severityList[idx].task
                local take = math.min(excess, desired[task])
                desired[task] = desired[task] - take
                excess = excess - take
            end
            allocatedAfterCap = desired.BUILD + desired.ASSIST + desired.EXP
        end

        local leftoverAfterCap = totalEng - allocatedAfterCap
        if leftoverAfterCap > 0 then
            local function fillCoverage()
                local updated = false
                for _, entry in ipairs(severityList) do
                    local cap = taskCaps[entry.task] or 0
                    if (entry.score or 0) > 0 and cap > 0 and desired[entry.task] < cap and leftoverAfterCap > 0 then
                        desired[entry.task] = desired[entry.task] + 1
                        leftoverAfterCap = leftoverAfterCap - 1
                        updated = true
                        if leftoverAfterCap <= 0 then break end
                    end
                end
                return updated
            end

            while leftoverAfterCap > 0 and fillCoverage() do end

            local idx = 1
            while leftoverAfterCap > 0 and idx <= table.getn(severityList) do
                local entry = severityList[idx]
                if (entry.score or 0) > 0 then
                    desired[entry.task] = desired[entry.task] + 1
                    leftoverAfterCap = leftoverAfterCap - 1
                else
                    break
                end
                idx = idx + 1
                if idx > table.getn(severityList) then idx = 1 end
            end
        end

        local ascending = {}
        for i = table.getn(severityList), 1, -1 do
            table.insert(ascending, severityList[i])
        end

        for _, entry in ipairs(ascending) do
            local task = entry.task
            local want = desired[task] or 0
            local have = cnt[task] or 0
            local extra = have - want
            if extra > 0 then
                steal({task}, extra)
            end
        end

        for _, entry in ipairs(severityList) do
            if (entry.score or 0) > 0 then
                local task = entry.task
                local want = desired[task] or 0
                local have = cnt[task] or 0
                local need = want - have
                if need > 0 then
                    local filter = nil
                    if task == 'EXP' then
                        filter = function(rec) return rec.tier == 'T3' or rec.tier == 'SCU' end
                    end
                    promote(task, need, filter)
                end
            end
        end

        recount()

        local buildAssignments = {}
        if buildDemand > 0 then
            local builders = {}
            for _, rec in ipairs(all) do
                if (self.engTask[rec.id] or 'IDLE') == 'BUILD' then
                    table.insert(builders, rec)
                end
            end
            buildAssignments = self:_PlanBuildAssignments(builders, buildTasks)
        end

        local distrib = {}
        for _, rec in ipairs(all) do
            local id, u = rec.id, rec.u
            local t = self.engTask[id] or 'IDLE'
            if t == 'BUILD' then
                self:_TickBuild(u, id, now, buildAssignments[id])
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
end
-- ===================== Threads =====================
function M:MonitorLoop()
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

        if missing <= 0 and self.leaseId then
            self:_ReleaseLeaseLocal()
        end

        WaitSeconds(1)
    end
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
        self:_ReleaseLeaseLocal()
    end
    if self.monitorThread then
        KillThread(self.monitorThread)
        self.monitorThread = nil
    end
    if self.taskThread then
        KillThread(self.taskThread)
        self.taskThread = nil
    end
        if ScenarioInfo.BaseEngineerPlatoons and self.platoonName then
        ScenarioInfo.BaseEngineerPlatoons[self.platoonName] = nil
    end
    local platoon = self:_FindEngineerPlatoon()
    if platoon and self.brain and self.brain.PlatoonExists and self.brain:PlatoonExists(platoon) then
        self.brain:DisbandPlatoon(platoon)
    end
    self.engineerPlatoon = nil
end

local function NormalizeEngineerParams(p)
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
        priority     = p.priority or 200,
        wantFactories= p.wantFactories or 1,
        spawnSpread  = (p.spawnSpread ~= nil) and p.spawnSpread or 2,
        debug        = p.debug and true or false,
        platoonName  = p.platoonName,
    }
end

local function EngineerStart(params)
    assert(params and params.brain and params.baseMarker and params.counts, 'brain, baseMarker, counts are required')

    local o = setmetatable({}, M)
    o.params   = NormalizeEngineerParams(params)
    o.brain    = o.params.brain
    o.basePos  = markerPos(o.params.baseMarker)
    if not o.basePos then error('Invalid baseMarker: '.. tostring(o.params.baseMarker)) end

    o.tag      = params.baseTag or ('BE_'.. math.floor(100000 * Random()))
    o.alloc    = params._alloc
    assert(o.alloc, 'BaseEngineer requires a factory allocator (_alloc)')
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

    o.platoonName = o.params.platoonName or (o.tag .. '_Engineers')
    o.engineerPlatoon = o:_GetEngineerPlatoon()

    o:Start()
    return o
end

local function EngineerStop(handle)
    if handle and handle.Stop then handle:Stop() end
end

-- ============================================================================
-- Integrated Base Controller
-- ============================================================================

ScenarioInfo.BaseManagers = ScenarioInfo.BaseManagers or {}

local function ClampDifficulty(d)
    if not d then return 2 end
    if d < 1 then return 1 end
    if d > 3 then return 3 end
    return d
end

local function ArmyNameFromBrain(brain)
    if not brain then return nil end
    local idx = brain.GetArmyIndex and brain:GetArmyIndex()
    if not idx then return nil end
    if ArmyBrains and ArmyBrains[idx] and ArmyBrains[idx].Name then
        return ArmyBrains[idx].Name
    end
    return 'ARMY_' .. tostring(idx)
end

local function MarkerPosition(marker)
    if type(marker) == 'string' then
        return ScenarioUtils.MarkerToPosition(marker)
    end
    if type(marker) == 'table' then
        return { marker[1], marker[2], marker[3] }
    end
    return nil
end

local function CopyTable(tbl)
    local copy = {}
    if type(tbl) ~= 'table' then
        return copy
    end
    for k, v in pairs(tbl) do
        if type(v) == 'table' then
            copy[k] = CopyTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

local FactoryControl = {}
FactoryControl.__index = FactoryControl

local AGE_RATE   = 0.33  -- points per second (20 per minute)
local PRI_MIN, PRI_MAX = 0, 200

local function EffectivePriority(req, now)
    if not req then return 0 end
    local base = math.max(PRI_MIN, math.min(PRI_MAX, req.priority or 0))
    local age  = 0
    if req.enqueuedAt and now then
        age = math.max(0, now - req.enqueuedAt)
    end
    local eff = base + (age * AGE_RATE)
    if eff > PRI_MAX then eff = PRI_MAX end
    return eff
end

local function DomainCategories(domain)
    if domain == 'LAND' then
        return categories.FACTORY * categories.LAND
    elseif domain == 'AIR' then
        return categories.FACTORY * categories.AIR
    elseif domain == 'NAVAL' then
        return categories.FACTORY * categories.NAVAL
    end
    return categories.FACTORY
end

function FactoryControl.New(base)
    local self = setmetatable({}, FactoryControl)
    self.base            = base
    self.brain           = base.brain
    self.requests        = {}
    self.queue           = {}
    self.reqSeq          = 0
    self.factoryState    = {}
    self.updateInterval  = 0.5
    self.stallTimeout    = 30
    self.running         = false
    self.thread          = nil
    return self
end

function FactoryControl:_Dbg(msg)
    if self.base and self.base.Dbg then
        self.base:Dbg(msg)
    end
end

function FactoryControl:_RefreshFactoryRoster()
    local brain = self.brain
    if not brain or not brain.GetListOfUnits then return end

    local list = brain:GetListOfUnits(categories.FACTORY) or {}
    local i = 1
    while i <= table.getn(list) do
        local fac = list[i]
        if fac and not fac:IsDead() and fac:GetAIBrain() == brain and self:_WithinBase(fac, self.base.basePos, self.base.radius) then
            local id = fac:GetEntityId()
            local state = self.factoryState[id]
            if not state then
                self.factoryState[id] = { unit = fac, leased = false, leaseId = nil }
            else
                state.unit = fac
            end
        end
        i = i + 1
    end
end

function FactoryControl:_FindLeaseOwner(entId)
    for _, req in pairs(self.requests or {}) do
        if req and req.granted and req.granted[entId] then
            return req
        end
    end
    return nil
end

function FactoryControl:_FactoryMatchesDomain(unit, domain)
    if not unit or unit:IsDead() then return false end
    if domain == 'LAND' then
        return EntityCategoryContains(categories.FACTORY * categories.LAND, unit)
    elseif domain == 'AIR' then
        return EntityCategoryContains(categories.FACTORY * categories.AIR, unit)
    elseif domain == 'NAVAL' then
        return EntityCategoryContains(categories.FACTORY * categories.NAVAL, unit)
    end
    return EntityCategoryContains(categories.FACTORY, unit)
end

function FactoryControl:_EligibleFactoryCount(req)
    local count = 0
    for _, state in pairs(self.factoryState) do
        local unit = state.unit
        if unit and not unit:IsDead() and unit:GetAIBrain() == self.brain and self:_WithinBase(unit, req.markerPos, req.radius) then
            if self:_FactoryMatchesDomain(unit, req.domain) then
                count = count + 1
            end
        end
    end
    return count
end

function FactoryControl:_GrantedCount(req)
    local have = 0
    for _ in pairs(req.granted or {}) do
        have = have + 1
    end
    return have
end

local function _DomainsOverlap(a, b)
    if a == 'AUTO' or b == 'AUTO' then
        return true
    end
    return a == b
end

function FactoryControl:_RequestsCompete(a, b)
    if not a or not b or a == b then return false end
    if not _DomainsOverlap(a.domain, b.domain) then return false end
    return true
end

function FactoryControl:_ShareFor(req)
    local total = self:_EligibleFactoryCount(req)
    if total <= 0 then return 0 end
    local peers = 1
    for _, other in pairs(self.requests) do
        if self:_RequestsCompete(req, other) then
            peers = peers + 1
        end
    end
    if peers <= 1 then return total end
    local share = math.floor(total / peers)
    if share < 1 then share = 1 end
    return share
end

function FactoryControl:_CompetitorNeeds(req)
    for _, other in pairs(self.requests) do
        if self:_RequestsCompete(req, other) then
            local have = self:_GrantedCount(other)
            local target
            if (other.want or 0) > 0 then
                target = other.want
            else
                target = self:_ShareFor(other)
            end
            if have < target then
                return true
            end
        end
    end
    return false
end

function FactoryControl:_UpdateDesiredCaps()
    for _, req in pairs(self.requests) do
        if req then
            if (req.want or 0) > 0 then
                local total = self:_EligibleFactoryCount(req)
                req.desired = math.min(req.want, total > 0 and total or req.want)
            else
                local total = self:_EligibleFactoryCount(req)
                if total <= 0 then
                    req.desired = 0
                elseif self:_CompetitorNeeds(req) then
                    req.desired = self:_ShareFor(req)
                else
                    req.desired = total
                end
            end
        end
    end
end

function FactoryControl:_RebalanceLeases()
    for _, req in pairs(self.requests) do
        if req and req.desired then
            local cap = req.desired
            local have = self:_GrantedCount(req)
            if have > cap and cap >= 0 and self:_CompetitorNeeds(req) then
                local toRelease = have - cap
                local revoke = {}
                for entId, unit in pairs(req.granted) do
                    if toRelease <= 0 then break end
                    local state = self.factoryState[entId]
                    if state then
                        state.leased = false
                        state.leaseId = nil
                    end
                    revoke[entId] = unit
                    req.granted[entId] = nil
                    toRelease = toRelease - 1
                end
                if next(revoke) and req.onRevoke then
                    pcall(req.onRevoke, revoke, req.id, 'rebalanced')
                end
            end
        end
    end
end

local function _FactoryIdle(unit)
    if not unit or unit:IsDead() then return true end
    if unit.IsUnitState then
        if unit:IsUnitState('Building') then return false end
        if unit:IsUnitState('Upgrading') then return false end
        if unit:IsUnitState('Guarding') then return false end
    end
    if unit.GetCommandQueue then
        local q = unit:GetCommandQueue() or {}
        if table.getn(q) > 0 then
            return false
        end
    end
    if unit.IsPaused and unit:IsPaused() then
        return true
    end
    return true
end

function FactoryControl:_CheckStalls(dt)
    local revokeIds = {}
    for id, req in pairs(self.requests) do
        if req then
            local anyGranted = false
            local active = false
            for entId, unit in pairs(req.granted or {}) do
                if unit and not unit:IsDead() and unit:GetAIBrain() == self.brain and self:_WithinBase(unit, req.markerPos, req.radius) then
                    anyGranted = true
                    if not _FactoryIdle(unit) then
                        active = true
                        break
                    end
                else
                    req.granted[entId] = nil
                    local state = self.factoryState[entId]
                    if state then
                        state.leased = false
                        state.leaseId = nil
                    end
                end
            end

            if anyGranted then
                if active then
                    req._idleSeconds = 0
                else
                    req._idleSeconds = (req._idleSeconds or 0) + dt
                    local threshold = req.stallTimeout or self.stallTimeout
                    if threshold and req._idleSeconds >= threshold then
                        table.insert(revokeIds, id)
                    end
                end
            else
                req._idleSeconds = 0
            end
        end
    end

    if table.getn(revokeIds) > 0 then
        for _, id in ipairs(revokeIds) do
            if self.requests[id] then
                self:ReturnLease(id, 'stall')
            end
        end
    end
end

function FactoryControl:Start()
    if self.running then return end
    self.running = true
    self.thread = self.brain:ForkThread(function()
        while self.running do
            self:Tick()
            WaitSeconds(self.updateInterval)
        end
    end)
end

function FactoryControl:Shutdown()
    self.running = false
    if self.thread then
        KillThread(self.thread)
        self.thread = nil
    end
    local ids = {}
    for id in pairs(self.requests) do
        table.insert(ids, id)
    end
    local i = 1
    while i <= table.getn(ids) do
        local rid = ids[i]
        if self.requests[rid] then
            self:ReturnLease(rid, 'shutdown')
        end
        i = i + 1
    end
    self.requests = {}
    self.queue = {}
    self.factoryState = {}
end

function FactoryControl:_WithinBase(unit, pos, radius)
    local baseRadius = self.base.radius or radius
    if not baseRadius then return false end
    local p = pos or (self.base and self.base.basePos)
    if not p then return false end
    local up = unit:GetPosition()
    local dx = (up[1] or 0) - (p[1] or 0)
    local dz = (up[3] or 0) - (p[3] or 0)
    return (dx*dx + dz*dz) <= (baseRadius * baseRadius)
end

function FactoryControl:RequestFactories(params)
    if not params then return nil end
    self.reqSeq = self.reqSeq + 1
    local id = self.reqSeq

    local req = {
        id          = id,
        markerName  = params.markerName,
        markerPos   = params.markerPos or MarkerPosition(params.markerName) or self.base.basePos,
        radius      = params.radius or self.base.radius,
        domain      = (params.domain or 'AUTO'):upper(),
        want        = math.max(0, params.wantFactories or 0),
        priority    = params.priority or 50,
        onGrant     = params.onGrant,
        onUpdate    = params.onUpdate,
        onRevoke    = params.onRevoke,
        onComplete  = params.onComplete,
        requesterTag= params.requesterTag,
        granted     = {},
        stallTimeout= params.stallTimeout,
        _idleSeconds= 0,
    }

    if req.priority < PRI_MIN then
        req.priority = PRI_MIN
    elseif req.priority > PRI_MAX then
        req.priority = PRI_MAX
    end

    if req.radius and self.base.radius then
        if req.radius > self.base.radius then
            req.radius = self.base.radius
        end
    else
        req.radius = self.base.radius
    end

    if not (req.markerPos and req.markerPos[1] and req.markerPos[3]) then
        WARN(('[BaseFactory:%s] Invalid marker position for request %d'):format(self.base.tag, id))
        return nil
    end

    self.requests[id] = req
    if GetGameTimeSeconds then
        req.enqueuedAt = GetGameTimeSeconds()
    else
        req.enqueuedAt = 0
    end

    table.insert(self.queue, id)
    self:SortQueue()

    local requester = req.requesterTag or 'unknown'
    self:_Dbg(('Factory lease request %d from %s (domain=%s want=%d radius=%s)'):format(
        id,
        requester,
        tostring(req.domain),
        req.want or 0,
        tostring(req.radius)
    ))

    return id
end

function FactoryControl:ReturnLease(leaseId, reason)
    local req = self.requests[leaseId]
    if not req then return end
    local requester = req.requesterTag or 'unknown'
    local revoke = {}
    for entId, unit in pairs(req.granted) do
        local fs = self.factoryState[entId]
        if fs then
            fs.leased  = false
            fs.leaseId = nil
        end
        revoke[entId] = unit
        self:_Dbg(('Factory %d returned from %s (reason=%s)'):format(
            entId,
            requester,
            tostring(reason or 'complete')
        ))
    end
    req.granted = {}
    if reason then
        if next(revoke) and req.onRevoke then
            pcall(req.onRevoke, revoke, leaseId, reason)
        end
    elseif req.onComplete then
        pcall(req.onComplete, leaseId)
    end
    local i = 1
    while i <= table.getn(self.queue) do
        if self.queue[i] == leaseId then
            table.remove(self.queue, i)
        else
            i = i + 1
        end
    end
    self.requests[leaseId] = nil
end

function FactoryControl:GetGrantedUnits(leaseId)
    local req = self.requests[leaseId]
    if not req then return {} end
    local out = {}
    for _, u in pairs(req.granted) do
        table.insert(out, u)
    end
    return out
end

function FactoryControl:SortQueue()
    local now = 0
    if GetGameTimeSeconds then
        now = GetGameTimeSeconds()
    end
    table.sort(self.queue, function(a, b)
        local ra = self.requests[a]
        local rb = self.requests[b]
        if not ra or not rb then return a < b end
        local pa = EffectivePriority(ra, now)
        local pb = EffectivePriority(rb, now)
        if pa == pb then
            return (ra.id or 0) < (rb.id or 0)
        end
        return pa > pb
    end)
end

function FactoryControl:Tick()
    local brain = self.brain
    if not brain then return end

    self:_RefreshFactoryRoster()

    for entId, state in pairs(self.factoryState) do
        local unit = state.unit
        if (not unit) or unit:IsDead() or unit:GetAIBrain() ~= brain then
            if state.leased and state.leaseId then
                local req = self.requests[state.leaseId]
                -- Keep req.granted in sync immediately
                if req and req.granted then
                    req.granted[entId] = nil
                end
                if req and req.onRevoke then
                    pcall(req.onRevoke, { [entId] = unit }, state.leaseId, 'lost')
                end
            end
            self.factoryState[entId] = nil
        end
    end

    self:SortQueue()
    self:_UpdateDesiredCaps()
    self:_RebalanceLeases()
    self:_CheckStalls(self.updateInterval or 1)

    local i = 1
    while i <= table.getn(self.queue) do
        local id = self.queue[i]
        local req = self.requests[id]
        if req then
            self:ServiceRequest(req)
            i = i + 1
        else
            table.remove(self.queue, i)
        end
    end
end

function FactoryControl:ServiceRequest(req)
    local brain = self.brain
    local domainCats
    if req.domain == 'AUTO' then
        domainCats = categories.FACTORY
    else
        domainCats = DomainCategories(req.domain)
    end
    local list = brain:GetListOfUnits(domainCats) or {}
    local candidates = {}
    local idx = 1
    while idx <= table.getn(list) do
        local fac = list[idx]
        if fac and not fac:IsDead() and fac:GetAIBrain() == brain and self:_WithinBase(fac, req.markerPos, req.radius) then
            local entId = fac:GetEntityId()
            local state = self.factoryState[entId]
            if not state then
                state = { unit = fac, leased = false, leaseId = nil }
                self.factoryState[entId] = state
            end

            local owner = nil
            if state.leaseId then
                owner = self.requests[state.leaseId]
                if not owner then
                    state.leased = false
                    state.leaseId = nil
                end
            end
            if not owner then
                owner = self:_FindLeaseOwner(entId)
                if owner then
                    state.leased = true
                    state.leaseId = owner.id
                end
            end

            if owner then
                -- IMPORTANT: keep allocator state consistent.
                -- If a factory is marked as owned by `owner`, ensure `owner.granted` also contains it.
                owner.granted = owner.granted or {}
                owner.granted[entId] = fac

                -- Also ensure the currently serviced request sees its own grants (redundant but harmless)
                if owner == req then
                    req.granted[entId] = fac
                end

                state.leased = true
                state.leaseId = owner.id
            elseif not state.leased then
                table.insert(candidates, fac)
            end
        end
        idx = idx + 1
    end

    local have = self:_GrantedCount(req)

    local target = req.desired
    if not target then
        if req.want == 0 then
            target = table.getn(candidates)
            if target <= 0 then
                target = 0
            end
        else
            target = req.want
        end
    end
    local need = math.max(0, target - have)

    if need <= 0 then return end

    local grantedNow = {}
    local remainingUnleased = table.getn(candidates)
    local j = 1
    while j <= table.getn(candidates) and need > 0 do
        local fac = candidates[j]
        local entId = fac:GetEntityId()
        local state = self.factoryState[entId]
        if state and not state.leased then
            state.leased = true
            state.leaseId = req.id
            req.granted[entId] = fac
            table.insert(grantedNow, fac)
            remainingUnleased = remainingUnleased - 1
            self:_Dbg(('Factory %d leased to %s; %d unleased remaining'):format(
                entId,
                req.requesterTag or 'unknown',
                math.max(0, remainingUnleased)
            ))
            need = need - 1
        end
        j = j + 1
    end

    if table.getn(grantedNow) > 0 then
        if have == 0 and req.onGrant then
            pcall(req.onGrant, grantedNow, req.id)
        elseif req.onUpdate then
            pcall(req.onUpdate, grantedNow, req.id)
        end
    end
end

local Base = {}
Base.__index = Base

function Base:Log(msg)
    LOG(('[Base:%s] %s'):format(self.tag or '??', msg))
end

function Base:Warn(msg)
    WARN(('[Base:%s] %s'):format(self.tag or '??', msg))
end

function Base:Dbg(msg)
    if self.params and self.params.debug then
        self:Log(msg)
    end
end

local function ResolveEngineerCounts(tbl, difficulty)
    local d = ClampDifficulty(difficulty)
    local tiers = { 'T1', 'T2', 'T3', 'SCU' }
    local out = { {}, {}, {}, {} }
    local i = 1
    while i <= table.getn(tiers) do
        local entry = tbl[tiers[i]] or tbl[i] or {0,0,0}
        if type(entry) == 'number' then
            out[i] = { entry, entry, entry }
        elseif type(entry) == 'table' then
            out[i] = { entry[1] or 0, entry[2] or (entry[1] or 0), entry[3] or (entry[2] or entry[1] or 0) }
        else
            out[i] = {0,0,0}
        end
        i = i + 1
    end
    return out, d
end

function Base:_CreateStructures()
    local groups = self.params.structGroups or {}
    local armyName = ArmyNameFromBrain(self.brain)
    local created = {}
    self.spawnedGroups = {}

    local i = 1
    while i <= table.getn(groups) do
        local gname = groups[i]
        if gname then
            local ok, units = pcall(function() return ScenarioUtils.CreateArmyGroup(armyName, gname, false) end)
            if ok and units then
                self.spawnedGroups[gname] = units
                local j = 1
                while units[j] do
                    table.insert(created, units[j])
                    j = j + 1
                end
            else
                self:Warn('Failed to create structure group '.. tostring(gname))
            end
        end
        i = i + 1
    end

    self.structures = created
end

function Base:_SetupFactoryControl()
    self.factoryControl = FactoryControl.New(self)
    if self.params.factoryStallTimeout then
        self.factoryControl.stallTimeout = self.params.factoryStallTimeout
    end
    self.factoryControl:Start()
end

function Base:_SetupEngineerManager()
    local counts, difficulty = ResolveEngineerCounts(self.params.engineers or {}, self.params.difficulty)

    local beParams = {
        brain        = self.brain,
        baseMarker   = self.params.baseMarker,
        baseTag      = self.tag,
        difficulty   = difficulty,
        structGroups = self.params.structGroups,
        counts       = counts,
        radius       = self.radius,
        priority     = self.params.engineerFactoryPriority or 200,
        wantFactories= self.params.engineerFactoryCount or 1,
        spawnSpread  = self.params.spawnSpread or 2,
        debug        = self.params.debug,
        _alloc       = self.factoryControl,
        tasks        = self.params.tasks,
    }

    self.engineers = EngineerStart(beParams)
    if self.engineers then
        self.engineerPlatoonName = self.engineers.platoonName
    end
end

function Base:_SetupMasterPlatoon()
    self.masterPlatoonName = string.format('%s_Master', self.tag or 'Base')
    self.masterPlatoon = _EnsureMasterPlatoon(self.brain, self.masterPlatoonName)
    self.masterTracked = {}
    self.masterInterval = self.params.masterInterval or 1.0
    if self.masterThread then
        KillThread(self.masterThread)
        self.masterThread = nil
    end
    if self.brain and self.masterPlatoon then
        self.masterThread = self.brain:ForkThread(function()
            while self.masterThread do
                self:_MasterPlatoonLoop()
                WaitSeconds(self.masterInterval)
            end
        end)
    end
end

function Base:_MasterPlatoonLoop()
    local platoon = self.masterPlatoon
    if not (platoon and self.brain and self.brain.PlatoonExists and self.brain:PlatoonExists(platoon)) then
        self.masterPlatoon = _EnsureMasterPlatoon(self.brain, self.masterPlatoonName)
        platoon = self.masterPlatoon
        if not platoon then return end
    end

    self.masterTracked = self.masterTracked or {}
    for id, u in pairs(self.masterTracked) do
        if not (u and not u.Dead and u:GetAIBrain() == self.brain) then
            self.masterTracked[id] = nil
        end
    end

    for _, u in ipairs(platoon:GetPlatoonUnits() or {}) do
        if u and not u.Dead and u:GetAIBrain() == self.brain then
            self.masterTracked[u:GetEntityId()] = u
        end
    end

    local near = {}
    local seen = {}
    local function addAround(pos, radius)
        if not pos then return end
        local around = self.brain:GetUnitsAroundPoint(categories.MOBILE, pos, radius, 'Ally') or {}
        local i = 1
        while i <= table.getn(around) do
            local u = around[i]
            if u and not seen[u] then
                seen[u] = true
                table.insert(near, u)
            end
            i = i + 1
        end
    end

    if self.factoryControl and self.factoryControl.factoryState then
        for _, state in pairs(self.factoryControl.factoryState) do
            local f = state and state.unit
            if f and not f:IsDead() and f:GetAIBrain() == self.brain then
                addAround(f:GetPosition(), 35)
            end
        end
    end

    if self.basePos then
        addAround(self.basePos, 35)
    end

    local k = 1
    while k <= table.getn(near) do
        local u = near[k]
        if u and not u.Dead and isComplete(u) and u:GetAIBrain() == self.brain then
            if not u.ub_tag and not EntityCategoryContains(categories.ENGINEER + categories.COMMAND, u) then
                local id = u:GetEntityId()
                if not self.masterTracked[id] then
                    self.masterTracked[id] = u
                    self.brain:AssignUnitsToPlatoon(platoon, { u }, 'Attack', 'GrowthFormation')
                    self:Dbg(('MasterPlatoon: added unit id=%d bp=%s to %s')
                        :format(id, _bpIdFromUnit(u) or 'unknown', self.masterPlatoonName or 'master'))
                end
            end
        end
        k = k + 1
    end
end

function Base:GetFactoryControl()
    return self.factoryControl
end

function Base:GetMasterPlatoon()
    if not (self.brain and self.masterPlatoonName) then return nil end
    local platoon = self.masterPlatoon
    if platoon and self.brain.PlatoonExists and self.brain:PlatoonExists(platoon) then
        return platoon
    end
    self.masterPlatoon = _EnsureMasterPlatoon(self.brain, self.masterPlatoonName)
    return self.masterPlatoon
end

function Base:RequestMasterUnits(requested, targetPlatoon, tag)
    local mp = self:GetMasterPlatoon()
    if not (mp and mp.GetPlatoonUnits and self.brain) then return {} end
    if not (targetPlatoon and self.brain.PlatoonExists and self.brain:PlatoonExists(targetPlatoon)) then
        return {}
    end

    local need = {}
    local totalNeed = 0
    for bp, count in pairs(requested or {}) do
        if count and count > 0 then
            local key = string.lower(bp)
            need[key] = (need[key] or 0) + count
            totalNeed = totalNeed + count
        end
    end
    if totalNeed == 0 then return {} end

    self:Dbg(('MasterPlatoon: request for %d units (%s)'):format(
        totalNeed, table.concat((function()
            local list = {}
            for bp, count in pairs(need) do
                table.insert(list, string.format('%s:%d', bp, count))
            end
            return list
        end)(), ', ')
    ))

    local provided = {}
    for _, u in ipairs(mp:GetPlatoonUnits() or {}) do
        if u and not u.Dead and isComplete(u) and u:GetAIBrain() == self.brain then
            if not u.ub_tag then
                local bp = _bpIdFromUnit(u)
                local want = bp and need[bp]
                if want and want > 0 then
                    if tag then
                        u.ub_tag = tag
                    end
                    self.brain:AssignUnitsToPlatoon(targetPlatoon, {u}, 'Attack', 'GrowthFormation')
                    need[bp] = want - 1
                    table.insert(provided, u)
                    totalNeed = totalNeed - 1
                    if totalNeed <= 0 then
                        break
                    end
                end
            end
        end
    end

    if table.getn(provided) > 0 then
        self:Dbg(('MasterPlatoon: provided %d units to %s'):format(
            table.getn(provided),
            (targetPlatoon.GetPlatoonLabel and targetPlatoon:GetPlatoonLabel()) or 'platoon'
        ))
    end

    return provided
end

function Base:RequestFactories(params)
    if not self.factoryControl then return nil end
    if params and not params.markerPos and not params.markerName then
        params.markerPos = self.basePos
    end
    if params and not params.radius then
        params.radius = self.radius
    end
    return self.factoryControl:RequestFactories(params)
end

function Base:ReturnLease(id, reason)
    if not id or not self.factoryControl then return end
    self.factoryControl:ReturnLease(id, reason)
end

function Base:GetGrantedUnits(leaseId)
    if not self.factoryControl then return {} end
    return self.factoryControl:GetGrantedUnits(leaseId)
end

function Base:GetEngineerHandle()
    return self.engineers
end

function Base:PushEngineerBuildTask(bp, pos, facing)
    if self.engineers and self.engineers.PushBuildTask then
        self.engineers:PushBuildTask(bp, pos, facing)
    end
end

function Base:AddBuildGroup(groupName)
    if not groupName then return 0 end
    self.params.structGroups = self.params.structGroups or {}
    local seen = false
    for _, name in ipairs(self.params.structGroups) do
        if name == groupName then
            seen = true
            break
        end
    end
    if not seen then
        table.insert(self.params.structGroups, groupName)
    end

    if self.engineers and self.engineers.AddBuildGroup then
        return self.engineers:AddBuildGroup(groupName)
    end
    return 0
end

function Base:RemoveBuildGroup(groupName)
    if not groupName then return 0 end
    if self.engineers and self.engineers.RemoveBuildGroup then
        return self.engineers:RemoveBuildGroup(groupName)
    end
    self.params.structGroups = self.params.structGroups or {}
    local updated = {}
    local removed = false
    for _, name in ipairs(self.params.structGroups) do
        if name ~= groupName then
            table.insert(updated, name)
        else
            removed = true
        end
    end
    if removed then
        self.params.structGroups = updated
        return 1
    end
    return 0
end

function Base:ReplaceBuildGroup(oldGroup, newGroup)
    if not (oldGroup and newGroup) then return 0 end
    if self.engineers and self.engineers.ReplaceBuildGroup then
        return self.engineers:ReplaceBuildGroup(oldGroup, newGroup)
    end
    self.params.structGroups = self.params.structGroups or {}
    local updated = {}
    local removed = false
    local seenNew = false
    for _, name in ipairs(self.params.structGroups) do
        if name == oldGroup then
            removed = true
        else
            if name == newGroup then
                seenNew = true
            end
            table.insert(updated, name)
        end
    end
    if not seenNew then
        table.insert(updated, newGroup)
    end
    if removed or not seenNew then
        self.params.structGroups = updated
        return 1
    end
    return 0
end

function Base:AssignEngineerUnit(unitOrPlatoon)
    if self.engineers and self.engineers.AssignEngineerUnits then
        return self.engineers:AssignEngineerUnits(unitOrPlatoon)
    end
    return 0
end

function Base:AssignEngineerPlatoon(platoon)
    if self.engineers and self.engineers.AssignEngineerUnits then
        return self.engineers:AssignEngineerUnits(platoon)
    end
    return 0
end

function Base:UpdateEngineerTasks(prefs)
    if self.engineers and self.engineers.UpdateTaskPrefs then
        self.engineers:UpdateTaskPrefs(prefs)
    end
end

function Base:GetStructureSnapshot()
    if self.engineers and self.engineers.struct then
        return self.engineers.struct
    end
    return CopyTable(self.structures or {})
end

function Base:Stop()
    if self.engineers then
        EngineerStop(self.engineers)
        self.engineers = nil
    end
    if self.factoryControl then
        self.factoryControl:Shutdown()
        self.factoryControl = nil
    end
    if self.masterThread then
        KillThread(self.masterThread)
        self.masterThread = nil
    end
    self.masterTracked = nil
    self.masterPlatoon = nil
    self.masterPlatoonName = nil
    if ScenarioInfo.BaseEngineerPlatoons and self.engineerPlatoonName then
        ScenarioInfo.BaseEngineerPlatoons[self.engineerPlatoonName] = nil
    end
    ScenarioInfo.BaseManagers[self.tag] = nil
end

local function NormalizeBaseParams(p)
    assert(p.brain, 'brain is required')
    assert(p.baseMarker, 'baseMarker is required')
    assert(p.baseTag, 'baseTag is required')
    assert(p.radius, 'radius is required')
    assert(p.structGroups, 'structGroups table is required')
    assert(p.engineers, 'engineers table is required')

    local pos = MarkerPosition(p.baseMarker)
    if not pos then
        error('Invalid baseMarker '.. tostring(p.baseMarker))
    end

    return {
        brain        = p.brain,
        baseMarker   = p.baseMarker,
        baseTag      = p.baseTag,
        basePos      = pos,
        radius       = p.radius,
        structGroups = CopyTable(p.structGroups),
        engineers    = CopyTable(p.engineers),
        difficulty   = p.difficulty,
        tasks        = CopyTable(p.tasks or {}),
        debug        = p.debug and true or false,
        spawnSpread           = p.spawnSpread,
        engineerFactoryPriority = p.engineerFactoryPriority,
        engineerFactoryCount    = p.engineerFactoryCount,
        factoryStallTimeout     = p.factoryStallTimeout,
        masterInterval          = p.masterInterval,
    }
end

local function BaseStart(params)
    local p = NormalizeBaseParams(params or {})
    local base = setmetatable({
        brain    = p.brain,
        tag      = p.baseTag,
        params   = p,
        radius   = p.radius,
        basePos  = p.basePos,
    }, Base)

    base:_SetupFactoryControl()
    base:_SetupEngineerManager()
    base:_SetupMasterPlatoon()

    ScenarioInfo.BaseManagers[base.tag] = base
    return base
end

local function BaseStop(handle)
    if handle and handle.Stop then
        handle:Stop()
    end
end

function GetBase(tag)
    if not tag then return nil end
    return ScenarioInfo.BaseManagers[tag]
end

function Start(params)
    return BaseStart(params)
end

function Stop(handle)
    return BaseStop(handle)
end

return {
    Start              = Start,
    Stop               = Stop,
    GetBase            = GetBase,
    StartEngineer      = EngineerStart,
    StopEngineer       = EngineerStop,
}