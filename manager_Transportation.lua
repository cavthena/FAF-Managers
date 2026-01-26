--[[
================================================================================
 Transportation Manager (Lua 5.0 safe)
================================================================================

Overview
    Manages a shared pool of transport-capable air units for an AI brain. The
    manager maintains a desired composition of transport types, requests air
    factories from BaseEngineer managers to build missing units, assigns idle
    transports to staging bases, and services prioritized transport requests.

Usage
    local TransportManager = import('/maps/.../manager_Transportation.lua')
    local handle = TransportManager.Start{
        brain = ArmyBrains[armyIndex],
        composition = {
            LightAirTransports = 6,
            AirTransports      = 4,
            Gunships           = 2, -- UEF only
            HeavyAirTransports = 1, -- UEF only
        },
        baseTag   = 'UEF_Main', -- optional base tag for build fallback
        priority  = 120,        -- optional factory lease priority (0..200)
        debug     = false,
    }

    -- Request transports for a platoon
    handle:RequestTransports{
        platoon       = platoon,
        destination   = {x, y, z},
        transportType = 'Air',   -- 'Light' | 'Air' | 'Heavy' | 'Gunship'
        priority      = 50,      -- 0..200 (increases over time)
    }

Public API
    TransportManager.Start(params)
    TransportManager.Stop(handle)

    Handle methods
        handle:RequestTransports(request)
            -- Returns requestId on success, nil otherwise
        handle:CancelRequest(requestId)
            -- Cancels queued or active request
]]

local ScenarioUtils     = import('/lua/sim/ScenarioUtilities.lua')

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

local BaseManager = ResolveBaseManagerModule()

-- transport blueprint maps
local TransportBp = {
    [1] = { -- UEF
        Light = 'uea0107',
        Air   = 'uea0104',
        Heavy = 'uea0104', -- no vanilla heavy transport; fallback to air transport
        Gunship = 'uea0203',
    },
    [2] = { -- Aeon
        Light = 'uaa0107',
        Air   = 'uaa0104',
        Heavy = nil,
        Gunship = nil,
    },
    [3] = { -- Cybran
        Light = 'ura0107',
        Air   = 'ura0104',
        Heavy = nil,
        Gunship = nil,
    },
    [4] = { -- Seraphim
        Light = 'xsa0107',
        Air   = 'xsa0104',
        Heavy = nil,
        Gunship = nil,
    },
}


local function tgetn(t)
    return table.getn(t or {})
end

local function _safeCQ(u)
    if not (u and u.GetCommandQueue and (not u.Dead)) then return {} end
    local ok, res = pcall(function() return u:GetCommandQueue() end)
    if ok and type(res) == 'table' then return res end
    return {}
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

local function clamp(val, min, max)
    if val < min then return min end
    if val > max then return max end
    return val
end


local function _safeIs(u, state)
    if not (u and u.IsUnitState and (not u.Dead)) then return false end
    local ok, res = pcall(function() return u:IsUnitState(state) end)
    return ok and res or false
end

local function _isComplete(u)
    if not u or u.Dead then return false end
    if u.GetFractionComplete and u:GetFractionComplete() < 1 then return false end
    if _safeIs(u, 'BeingBuilt') then return false end
    return true
end

local function _transportSlots(bp)
    if not bp then return 1 end
    local t = bp.Transport or bp.TransportClass or bp.TransportSlot
    if bp.Transport and bp.Transport.TransportSlots then
        return bp.Transport.TransportSlots
    end
    if t and t.TransportSlots then return t.TransportSlots end
    if t and t.Slots then return t.Slots end
    return 1
end

local function _unitTransportClass(bp)
    if not bp then return 1 end
    if bp.Transport and bp.Transport.TransportClass then
        return bp.Transport.TransportClass
    end
    return bp.TransportClass or 1
end

local function _GetBrainFaction(brain)
    if not brain or not brain.GetFactionIndex then return 1 end
    return brain:GetFactionIndex() or 1
end

local function _GetBaseManagersForBrain(brain)
    local out = {}
    if not (ScenarioInfo and ScenarioInfo.BaseManagers and brain) then return out end
    for _, base in pairs(ScenarioInfo.BaseManagers) do
        if base and base.brain == brain then
            table.insert(out, base)
        end
    end
    return out
end

local function _hasStructuresNear(brain, pos, radius)
    if not (brain and pos and radius) then return false end
    if not brain.GetUnitsAroundPoint then return false end
    local units = brain:GetUnitsAroundPoint(categories.STRUCTURE, pos, radius, 'Ally') or {}
    return tgetn(units) > 0
end

local function _pickStagingPoints(bases, brain)
    local staging = {}
    for _, base in ipairs(bases or {}) do
        if base and base.basePos and base.radius then
            if _hasStructuresNear(brain, base.basePos, base.radius) then
                table.insert(staging, {
                    pos = base.basePos,
                    radius = base.radius,
                    tag = base.tag,
                })
            end
        end
    end
    return staging
end

local function _pickBuildBase(bases)
    for _, base in ipairs(bases or {}) do
        if base and base.basePos and base.radius then
            return base
        end
    end
    return nil
end

local function _makeOrbitPoints(pos, radius)
    local r = radius or 25
    return {
        { pos[1] + r, pos[2], pos[3] },
        { pos[1], pos[2], pos[3] + r },
        { pos[1] - r, pos[2], pos[3] },
        { pos[1], pos[2], pos[3] - r },
    }
end

local M = {}
M.__index = M

function M:Log(msg) LOG(('[TM:%s] %s'):format(self.tag, msg)) end
function M:Warn(msg) WARN(('[TM:%s] %s'):format(self.tag, msg)) end
function M:Dbg(msg) if self.params.debug then self:Log(msg) end end

function M:_NormalizeComposition()
    local comp = self.params.composition or {}
    self.composition = {
        Light = comp.LightAirTransports or comp.Light or 0,
        Air   = comp.AirTransports or comp.Air or 0,
        Gunship = comp.Gunships or comp.Gunship or 0,
        Heavy = comp.HeavyAirTransports or comp.Heavy or 0,
    }
end

function M:_GetBlueprint(typeKey)
    local faction = _GetBrainFaction(self.brain)
    local map = TransportBp[faction] or TransportBp[1]
    return map[typeKey]
end

function M:_FindStaging()
    local bases = _GetBaseManagersForBrain(self.brain)
    self.bases = bases
    self.staging = _pickStagingPoints(bases, self.brain)
end

function M:_UpdatePool()
    if not (self.brain and self.brain.GetListOfUnits) then return end

    local units = self.brain:GetListOfUnits(categories.AIR, false) or {}
    local seen = {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead and _isComplete(unit) then
            local bpId = unitBpId(unit)
            if bpId then
                local typeKey = self.blueprintToType[bpId]
                if typeKey then
                    local entId = unit:GetEntityId()
                    seen[entId] = true
                    if not self.pool[entId] then
                        local bpData = __blueprints and __blueprints[bpId]
                        self.pool[entId] = {
                            unit = unit,
                            type = typeKey,
                            status = 'idle',
                            slots = _transportSlots(bpData or {}),
                        }
                        if self.pendingBuilds[typeKey] and self.pendingBuilds[typeKey] > 0 then
                            self.pendingBuilds[typeKey] = math.max(0, self.pendingBuilds[typeKey] - 1)
                        end
                    end
                end
            end
        end
    end

    for entId, entry in pairs(self.pool) do
        local unit = entry.unit
        if not (unit and not unit.Dead) then
            self.pool[entId] = nil
        elseif not seen[entId] then
            -- still alive but not matching blueprint map
            self.pool[entId] = nil
        end
    end
end

function M:_IdleTransports()
    local staging = self.staging or {}
    if tgetn(staging) == 0 then return end

    local idx = self._stagingIndex or 1
    local s = staging[idx]
    if not s then return end

    local orbit = _makeOrbitPoints(s.pos, math.max(15, math.min(40, s.radius * 0.3)))
    for _, entry in pairs(self.pool) do
        if entry.status == 'idle' and entry.unit and not entry.unit.Dead then
            local queue = _safeCQ(entry.unit)
            if tgetn(queue) == 0 then
                IssueClearCommands({entry.unit})
                for _, pt in ipairs(orbit) do
                    IssuePatrol({entry.unit}, pt)
                end
            end
        end
    end

    idx = idx + 1
    if idx > tgetn(staging) then idx = 1 end
    self._stagingIndex = idx
end

function M:_CountPool()
    local counts = { Light = 0, Air = 0, Heavy = 0, Gunship = 0 }
    for _, entry in pairs(self.pool) do
        if entry.unit and not entry.unit.Dead then
            counts[entry.type] = (counts[entry.type] or 0) + 1
        end
    end
    return counts
end

function M:_EnsureLease()
    if self.leaseId or not self.buildBase then return end
    self.leaseId = self.buildBase:RequestFactories{
        markerName   = self.params.baseMarker,
        markerPos    = self.buildBase.basePos,
        radius       = self.buildBase.radius,
        domain       = 'AIR',
        wantFactories= math.max(0, self.params.wantFactories or 0),
        priority     = clamp(self.params.priority or 100, 0, 200),
        requesterTag = self.tag,
        onGrant      = function(f, id) self:OnLeaseGranted(f, id) end,
        onUpdate     = function(f, id) self:OnLeaseUpdated(f, id) end,
        onRevoke     = function(list, id, reason) self:OnLeaseRevoked(list, id, reason) end,
        onComplete   = function(id) end,
    }
end

function M:_ReleaseLease(reason)
    if self.leaseId and self.buildBase then
        self.buildBase:ReturnLease(self.leaseId, reason or 'complete')
    end
    self.leaseId = nil
    self.leased = {}
end

function M:OnLeaseGranted(factories, leaseId)
    self.leased = {}
    for _, f in ipairs(factories or {}) do
        if f and not f.Dead then
            self.leased[f:GetEntityId()] = f
            IssueClearFactoryCommands({f})
        end
    end
    self:QueueMissingBuilds()
end

function M:OnLeaseUpdated(factories, leaseId)
    self.leased = self.leased or {}
    for _, f in ipairs(factories or {}) do
        if f and not f.Dead then
            self.leased[f:GetEntityId()] = f
            IssueClearFactoryCommands({f})
        end
    end
    self:QueueMissingBuilds()
end

function M:OnLeaseRevoked(list, leaseId, reason)
    for entId, fac in pairs(list or {}) do
        self.leased[entId] = nil
        if fac and not fac.Dead then
            IssueClearFactoryCommands({fac})
        end
    end
    if reason == 'stall' then
        self.pendingBuilds = { Light = 0, Air = 0, Heavy = 0, Gunship = 0 }
    end
    local hasAny = false
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then hasAny = true break end
    end
    if not hasAny then
        self.leaseId = nil
    end
end

function M:_FactoryCanBuild(factory, bp)
    if not (factory and bp) then return false end
    if factory.CanBuild then
        local ok, res = pcall(function() return factory:CanBuild(bp) end)
        if ok then return res end
    end
    return true
end

function M:_IssueBuild(factory, bp)
    if not (factory and bp) then return end
    if not self:_FactoryCanBuild(factory, bp) then return end
    IssueBuildFactory({factory}, bp, 1)
end

function M:QueueMissingBuilds()
    if not self.buildBase then return end

    local counts = self:_CountPool()
    local missing = {}
    for typeKey, want in pairs(self.composition or {}) do
        local have = (counts[typeKey] or 0) + (self.pendingBuilds[typeKey] or 0)
        if want > have then
            missing[typeKey] = want - have
        end
    end

    local totalMissing = 0
    for _, v in pairs(missing) do totalMissing = totalMissing + v end
    if totalMissing == 0 then
        self:_ReleaseLease('complete')
        return
    end

    self:_EnsureLease()
    if not self.leaseId then return end

    for _, factory in pairs(self.leased or {}) do
        if factory and not factory.Dead then
            for typeKey, count in pairs(missing) do
                if count > 0 then
                    local bp = self:_GetBlueprint(typeKey)
                    if bp then
                        self:_IssueBuild(factory, bp)
                        missing[typeKey] = count - 1
                        self.pendingBuilds[typeKey] = (self.pendingBuilds[typeKey] or 0) + 1
                    else
                        self:Warn('No blueprint for transport type ' .. tostring(typeKey) .. ' in this faction')
                        missing[typeKey] = 0
                    end
                end
            end
        end
    end
end

function M:_SlotsNeededForPlatoon(platoon)
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    local needed = 0
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            local bp = unit:GetBlueprint()
            needed = needed + _unitTransportClass(bp)
        end
    end
    return math.max(0, needed)
end

function M:_TransportSlotsForType(typeKey)
    local bp = self:_GetBlueprint(typeKey)
    if not bp then return 0 end
    local bpData = __blueprints and __blueprints[bp]
    return _transportSlots(bpData or {})
end

function M:_AssignTransports(request)
    local desiredSlots = request.slotsNeeded or 0
    if desiredSlots <= 0 then return false end

    local assigned = {}
    local availableSlots = 0
    for entId, entry in pairs(self.pool) do
        if entry.status == 'idle' and entry.type == request.transportType then
            entry.status = 'assigned'
            entry.requestId = request.id
            table.insert(assigned, entry)
            availableSlots = availableSlots + (entry.slots or self:_TransportSlotsForType(entry.type) or 0)
            if availableSlots >= desiredSlots then
                break
            end
        end
    end

    if tgetn(assigned) == 0 then
        return false
    end

    request.assigned = assigned
    request.assignedSlots = availableSlots
    return true
end

function M:_ReleaseRequestTransports(request)
    for _, entry in ipairs(request.assigned or {}) do
        if entry and entry.unit and not entry.unit.Dead then
            entry.status = 'idle'
            entry.requestId = nil
        end
    end
    request.assigned = nil
    request.assignedSlots = 0
end

function M:_ExecuteTransport(request)
    local platoon = request.platoon
    local destination = request.destination
    if not (platoon and destination) then
        return false
    end

    local units = platoon:GetPlatoonUnits() or {}
    local transports = {}
    for _, entry in ipairs(request.assigned or {}) do
        if entry.unit and not entry.unit.Dead then
            table.insert(transports, entry.unit)
        end
    end

    if tgetn(transports) == 0 or tgetn(units) == 0 then
        return false
    end

    IssueClearCommands(transports)
    IssueClearCommands(units)

    local okLoad, errLoad = pcall(IssueTransportLoad, transports, units)
    if not okLoad then
        self:Warn('Transport load failed: ' .. tostring(errLoad))
        return false
    end

    -- wait for load or timeout
    local loadTimeout = self.params.loadTimeout or 30
    local waited = 0
    while waited < loadTimeout do
        local allLoaded = true
        for _, unit in ipairs(units) do
            if unit and not unit.Dead and not _safeIs(unit, 'Attached') then
                allLoaded = false
                break
            end
        end
        if allLoaded then break end
        WaitSeconds(1)
        waited = waited + 1
    end

    IssueMove(transports, destination)
    IssueTransportUnload(transports, destination)

    local unloadTimeout = self.params.unloadTimeout or 40
    waited = 0
    while waited < unloadTimeout do
        local anyAttached = false
        for _, unit in ipairs(units) do
            if unit and not unit.Dead and _safeIs(unit, 'Attached') then
                anyAttached = true
                break
            end
        end
        if not anyAttached then break end
        WaitSeconds(1)
        waited = waited + 1
    end

    return true
end

function M:_ProcessRequests()
    local queue = self.queue
    if not queue or tgetn(queue) == 0 then return end

    local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
    for _, req in ipairs(queue) do
        local elapsed = math.max(0, now - (req.enqueuedAt or now))
        req.effectivePriority = clamp((req.priority or 0) + elapsed * (self.params.priorityRamp or 0.25), 0, 200)
    end

    table.sort(queue, function(a, b)
        return (a.effectivePriority or 0) > (b.effectivePriority or 0)
    end)

    local i = 1
    while i <= tgetn(queue) do
        local req = queue[i]
        if req.cancelled then
            table.remove(queue, i)
        elseif not req.inProgress then
            req.slotsNeeded = req.slotsNeeded or self:_SlotsNeededForPlatoon(req.platoon)
            local slotsPerTransport = self:_TransportSlotsForType(req.transportType)
            if req.slotsNeeded > 0 and slotsPerTransport > 0 then
                local okAssign = self:_AssignTransports(req)
                if okAssign then
                    req.inProgress = true
                    self.brain:ForkThread(function()
                        local ok = self:_ExecuteTransport(req)
                        self:_ReleaseRequestTransports(req)
                        req.inProgress = false
                        if ok then
                            req.completed = true
                        end
                    end)
                    table.remove(queue, i)
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

function M:RequestTransports(req)
    if not (req and req.platoon and req.destination) then return nil end
    self.reqSeq = (self.reqSeq or 0) + 1
    local id = self.reqSeq

    local typeKey = req.transportType or 'Air'
    local validTypes = { Light = true, Air = true, Heavy = true, Gunship = true }
    if not validTypes[typeKey] then
        typeKey = 'Air'
    end

    if not self:_GetBlueprint(typeKey) then
        self:Warn('Transport type ' .. tostring(typeKey) .. ' not available for this faction')
        return nil
    end

    local priority = clamp(req.priority or 0, 0, 200)
    local request = {
        id = id,
        platoon = req.platoon,
        destination = req.destination,
        transportType = typeKey,
        priority = priority,
        enqueuedAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0,
        assigned = {},
    }

    table.insert(self.queue, request)
    return id
end

function M:CancelRequest(id)
    for _, req in ipairs(self.queue or {}) do
        if req.id == id then
            req.cancelled = true
            return true
        end
    end
    return false
end

function M:Start()
    self:_NormalizeComposition()
    self.blueprintToType = {}
    for _, map in pairs(TransportBp) do
        for typeKey, bp in pairs(map or {}) do
            if bp then
                self.blueprintToType[bp] = typeKey
            end
        end
    end

    self.pool = {}
    self.pendingBuilds = { Light = 0, Air = 0, Heavy = 0, Gunship = 0 }
    self.queue = {}
    self:_FindStaging()
    if not self.buildBase then
        self.buildBase = _pickBuildBase(self.bases)
    end

    self.poolThread = self.brain:ForkThread(function()
        while not self.stopped do
            self:_FindStaging()
            self:_UpdatePool()
            self:_IdleTransports()
            self:QueueMissingBuilds()
            WaitSeconds(self.params.poolInterval or 5)
        end
    end)

    self.queueThread = self.brain:ForkThread(function()
        while not self.stopped do
            self:_ProcessRequests()
            WaitSeconds(self.params.queueInterval or 2)
        end
    end)
end

function M:Stop()
    self.stopped = true
    if self.poolThread then
        KillThread(self.poolThread)
        self.poolThread = nil
    end
    if self.queueThread then
        KillThread(self.queueThread)
        self.queueThread = nil
    end
    self:_ReleaseLease('shutdown')
    self.queue = {}
    self.pool = {}
end

local function NormalizeParams(p)
    assert(p and p.brain, 'brain is required')
    return {
        brain        = p.brain,
        baseTag      = p.baseTag,
        baseMarker   = p.baseMarker,
        composition  = p.composition or {},
        priority     = p.priority or 100,
        wantFactories= p.wantFactories or 1,
        debug        = p.debug and true or false,
        poolInterval = p.poolInterval,
        queueInterval= p.queueInterval,
        priorityRamp = p.priorityRamp,
        loadTimeout  = p.loadTimeout,
        unloadTimeout= p.unloadTimeout,
    }
end

local function Start(params)
    local p = NormalizeParams(params or {})
    local tag = p.baseTag or 'Transport'
    local manager = setmetatable({
        brain = p.brain,
        params = p,
        tag = tag,
    }, M)

    if p.baseTag and BaseManager and BaseManager.GetBase then
        manager.buildBase = BaseManager.GetBase(p.baseTag)
    end
    if not manager.buildBase then
        manager:_FindStaging()
        manager.buildBase = _pickBuildBase(manager.bases)
    end

    manager:Start()
    return manager
end

local function Stop(handle)
    if handle and handle.Stop then
        handle:Stop()
    end
end

return {
    Start = Start,
    Stop  = Stop,
}