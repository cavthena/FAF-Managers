-- /maps/.../manager_BaseEngineer.lua
-- Base Engineer Manager
--
-- What it does
--   • Keeps a fixed headcount of engineers (T1 T2 T3 SCU) in a base, sustained via manager_UnitBuilder (mode 3).
--   • Distributes engineers across idle (patrol reclaim repair), assist factories, rebuild (callback driven),
--     and experimental construction (optional, with cooldown plus attack handoff).
--   • Engineers managed by this file are tagged and treated as a dedicated pool, isolated from other managers.
--
-- Public API
--   local BaseEng = import('/maps/.../manager_BaseEngineer.lua')
--   local h = BaseEng.Start{
--     brain            = ArmyBrains[ScenarioInfo.UEF],
--     baseMarker       = 'UEF_MainBase_Zone',
--     difficulty       = ScenarioInfo.Options.Difficulty or 2,  -- 1..3
--
--     -- Desired headcounts (per tech) to KEEP inside the base. Tables are {easy, normal, hard}.
--     wantT1           = {6, 8, 10},
--     wantT2           = {2, 3, 4},
--     wantT3           = {1, 2, 3},
--     wantSCU          = {0, 0, 1},
--
--     -- Builder controls (uses manager_UnitBuilder in mode 3)
--     builderSpawnFirst= true,       -- direct spawn the first batch at the rally base marker
--     wantFactories    = 0,          -- 0  any available
--     factoryPriority  = 120,
--     leaseRadius      = 60,         -- factories near baseMarker
--
--     -- Task policy
--     taskMin          = { idle=1, assist=1, rebuild=0, experimental=0 },  -- hard floor per task
--     taskDesired      = { idle=2, assist=4, rebuild=2, experimental=6 },  -- soft target per task
--     assistPerFactory = 2,          -- spread assists across concurrently building factories
--     patrolRadius     = 35,         -- random patrol points inside base
--     scanRadius       = 60,         -- search radius for factories repairs reclaim around base
--
--     -- Rebuild source (no custom rebuildOrdersFn needed)
--     -- If baseManager is provided, we snapshot the structures that exist inside scanRadius at startup.
--     -- Else we snapshot whatever allied structures exist inside scanRadius at startup.
--
--     -- Experimental (optional)
--     experimentalBp     = nil,                    -- for example url0402
--     experimentalMarker = 'UEF_MainBase_Zone',    -- build location marker
--     experimentalCooldown = 600,                  -- seconds between experimentals
--     experimentalAttackFn = 'Platoon_BasicAttack',-- function or _G name; handed the completed unit as a platoon
--
--     -- Debug
--     debug            = false,
--   }
--   BaseEng.Stop(h)
--
-- Notes
--   - Internally spawns a manager_UnitBuilder with composition made of the faction engineer blueprints.
--   - The builder is run in MODE 3 so headcount is kept topped up automatically.
--   - Engineers stay inside a single engineer platoon; this manager issues their orders.
--   - You can run multiple BaseEngineer managers in parallel.
--

local ScenarioUtils     = import('/lua/sim/ScenarioUtilities.lua')
local FactoryAllocMod   = import('/maps/faf_coop_U01.v0001/manager_FactoryHandler.lua')
local UnitBuilderMod    = import('/maps/faf_coop_U01.v0001/manager_UnitBuilder.lua')

-- ========= helpers =========
local function summarizeCounts(tbl)
    local parts = {}
    for bp, n in pairs(tbl or {}) do
        local s = tostring(bp) .. '=' .. tostring(n or 0)
        table.insert(parts, s)
    end
    table.sort(parts)
    return table.concat(parts, ', ')
end

local function markerPos(mark)
    if mark then
        return ScenarioUtils.MarkerToPosition(mark)
    end
    return nil
end

local function clamp(x,a,b)
    if x<a then return a elseif x>b then return b else return x end
end

local function isComplete(u)
    if not u or u.Dead then return false end
    if u.GetFractionComplete and u:GetFractionComplete() < 1 then return false end
    if u.IsUnitState and u:IsUnitState('BeingBuilt') then return false end
    return true
end

local function unitBpId(u)
    local id = (u.BlueprintID or (u:GetBlueprint() and u:GetBlueprint().BlueprintId))
    if not id then return nil end
    id = string.lower(id)
    local m = string.match(id, '/units/([^/]+)/')
    if m then
        return m
    end
    return id
end

local function isIdleEngineer(u)
    if not u or u.Dead then return false end
    if u.IsUnitState then
        if u:IsUnitState('Building') or u:IsUnitState('Repairing') or u:IsUnitState('Guarding') or
           u:IsUnitState('Moving') or u:IsUnitState('Attacking') or u:IsUnitState('Enhancing') or
           u:IsUnitState('Upgrading') then
            return false
        end
    end
    if u.GetCommandQueue and u:GetCommandQueue() and table.getn(u:GetCommandQueue()) > 0 then
        return false
    end
    return true
end

local function randomMove(unit, center, radius)
    if not (unit and center and radius) then return end
    local ox = (Random()*2 - 1) * radius
    local oz = (Random()*2 - 1) * radius
    local p  = {center[1] + ox, center[2], center[3] + oz}
    IssueClearCommands({unit})
    IssueMove({unit}, p)
end

local function rectFromCenter(center, r)
    return Rect(center[1]-r, center[3]-r, center[1]+r, center[3]+r)
end

-- Try repair, then reclaim, else just wander via a single IssueMove.
-- This is intentionally lightweight so higher priority tasks can preempt it at any time.
local function idleMicro(brain, unit, center, scanR, patrolR)
    if not unit or unit.Dead then return end

    -- repairs
    local allies = brain:GetUnitsAroundPoint(categories.STRUCTURE, center, scanR, 'Ally') or {}
    for _,s in ipairs(allies) do
        if s and not s.Dead and s.GetHealth and s.GetMaxHealth then
            local hp, mhp = s:GetHealth(), s:GetMaxHealth()
            if mhp and mhp > 0 and (hp / mhp) < 0.98 then
                IssueClearCommands({unit})
                IssueRepair({unit}, s)
                return
            end
        end
    end

    -- reclaim sweep
    local rect = rectFromCenter(center, scanR)
    local rec  = GetReclaimablesInRect(rect) or {}
    if rec and table.getn(rec) > 0 then
        IssueClearCommands({unit})
        IssueReclaim({unit}, rec)
        return
    end

    -- wander
    randomMove(unit, center, patrolR or 35)
end

-- faction engineer BP map
local function engineerBpsForBrain(brain)
    local t1,t2,t3,scu = 'uel0105','uel0208','uel0309','uel0301'
    local factionIndex = brain and brain:GetFactionIndex() or 1
    if factionIndex == 2 then
        t1,t2,t3,scu = 'ual0105','ual0208','ual0309','ual0301'
    elseif factionIndex == 3 then
        t1,t2,t3,scu = 'url0105','url0208','url0309','url0301'
    elseif factionIndex == 4 then
        t1,t2,t3,scu = 'xsl0105','xsl0208','xsl0309','xsl0301'
    end
    return {T1=t1, T2=t2, T3=t3, SCU=scu}
end

--============= managers ============
local Manager = {}
Manager.__index = Manager

function Manager:Log(msg) LOG('[BE:' .. tostring(self.tag) .. '] ' .. tostring(msg)) end
function Manager:Warn(msg) WARN('[BE:' .. tostring(self.tag) .. '] ' .. tostring(msg)) end
function Manager:Dbg(msg) if self.params.debug then self:Log(msg) end end

-- tracked baseline: array of { bp, x, y, z, heading }
function Manager:_SnapshotExistingInRadius()
    local brain  = self.brain
    local center = self.basePos
    local r      = self.params.scanRadius or 60
    local structs = brain:GetUnitsAroundPoint(categories.STRUCTURE, center, r, 'Ally') or {}
    local list, idx = {}, {}
    for _,u in ipairs(structs) do
        if u and not u.Dead then
            local bp = unitBpId(u)
            if bp then
                local pos = u:GetPosition()
                local h   = (u.GetHeading and u:GetHeading()) or 0
                local key = bp .. '@' .. tostring(math.floor((pos[1] + 0.5) / 1.0)) .. '@' .. tostring(math.floor((pos[3] + 0.5) / 1.0))
                if not idx[key] then
                    idx[key] = true
                    table.insert(list, {bp, pos[1], pos[2], pos[3], h})
                end
            end
        end
    end
    return list, idx
end

function Manager:_SnapshotFromBaseManager()
    if not self.params.baseManager then
        return self:_SnapshotExistingInRadius()
    end
    -- robust approach  snapshot what is on the ground
    return self:_SnapshotExistingInRadius()
end

function Manager:_SnapshotFromEditorGroups()
    -- Best effort reader removed to avoid pattern tokens
    -- Fallback to present on map snapshot
    return self:_SnapshotExistingInRadius()
end

function Manager:_InitRebuildTracker()
    local baseline
    if self.params.rebuildUseBaseMgr ~= false and self.params.baseManager then
        baseline = self:_SnapshotFromBaseManager()
        local count = table.getn(baseline or {})
        self:Dbg('Rebuild baseline from BaseManager, count ' .. tostring(count))
    elseif self.params.rebuildGroupNames then
        baseline = self:_SnapshotFromEditorGroups()
        local count = table.getn(baseline or {})
        self:Dbg('Rebuild baseline from editor groups, count ' .. tostring(count))
    else
        baseline = self:_SnapshotExistingInRadius()
        local count = table.getn(baseline or {})
        self:Dbg('Rebuild baseline from map snapshot, count ' .. tostring(count))
    end
    self.rebuildBaseline = baseline or {}
end

-- Produce rebuild orders for any missing baseline structure.
-- We test presence by checking for any allied structure of same bp within small radius of the target spot.
function Manager:_MakeRebuildOrders()
    local brain  = self.brain
    local orders = {}
    local checkR = 3.5
    for _,rec in ipairs(self.rebuildBaseline or {}) do
        local bp, x, y, z, h = rec[1], rec[2], rec[3], rec[4], rec[5]
        local present = false
        local around = brain:GetUnitsAroundPoint(categories.STRUCTURE, {x,y,z}, checkR, 'Ally') or {}
        for _,u in ipairs(around) do
            if u and not u.Dead then
                local id = unitBpId(u)
                if id == bp then
                    present = true
                    break
                end
            end
        end
        if not present then
            table.insert(orders, {bp, x, y, z, h or 0})
        end
    end
    return orders
end

-- Build UnitBuilder composition from per tech wants
function Manager:_MakeComposition()
    local bp = self.bp
    local wT1 = self.params.wantT1 or {0,0,0}
    local wT2 = self.params.wantT2 or {0,0,0}
    local wT3 = self.params.wantT3 or {0,0,0}
    local wSC = self.params.wantSCU or {0,0,0}
    local comp = {}
    if (wT1[1] or 0)+(wT1[2] or 0)+(wT1[3] or 0) > 0 then table.insert(comp, {bp.T1, wT1, 'T1Eng'}) end
    if (wT2[1] or 0)+(wT2[2] or 0)+(wT2[3] or 0) > 0 then table.insert(comp, {bp.T2, wT2, 'T2Eng'}) end
    if (wT3[1] or 0)+(wT3[2] or 0)+(wT3[3] or 0) > 0 then table.insert(comp, {bp.T3, wT3, 'T3Eng'}) end
    if (wSC[1] or 0)+(wSC[2] or 0)+(wSC[3] or 0) > 0 then table.insert(comp, {bp.SCU, wSC, 'SCU'}) end
    return comp
end

-- Called by UnitBuilder when the engineer platoon is ready (mode 3 will keep it topped up)
function Manager:EngineerPlatoonAI(platoon)
    self.platoon = platoon
    self:Dbg('EngineerPlatoonAI begin')
    local brain   = self.brain
    local center  = self.basePos
    local scanR   = self.params.scanRadius or 60

    local lastExpTime = -999

    while not self.stopped and platoon and brain:PlatoonExists(platoon) do
        if self.builderHandle and self.builderHandle.CollectForPlatoon then
            self.builderHandle:CollectForPlatoon(platoon)
        end

        do
            local near = brain:GetUnitsAroundPoint(categories.ENGINEER, center, scanR, 'Ally') or {}
            local attach = {}
            for _,u in ipairs(near) do
                if u and not u.Dead and u.ub_tag == self.tag and isComplete(u) then
                    table.insert(attach, u)
                end
            end
            if table.getn(attach) > 0 and brain:PlatoonExists(platoon) then
                brain:AssignUnitsToPlatoon(platoon, attach, 'Attack', 'GrowthFormation')
            end
        end

        local haveByBp = {}
        for _, u in ipairs(platoon:GetPlatoonUnits() or {}) do
            if isComplete(u) then
                local bp = unitBpId(u)
                if bp then haveByBp[bp] = (haveByBp[bp] or 0) + 1 end
            end
        end
        local inPlatoon = {}
        for _, u in ipairs(platoon:GetPlatoonUnits() or {}) do
            if u and not u.Dead then inPlatoon[u:GetEntityId()] = true end
        end
        do
            local near = brain:GetUnitsAroundPoint(categories.ENGINEER, center, scanR, 'Ally') or {}
            for _, u in ipairs(near) do
                if u and not u.Dead and isComplete(u) and u.ub_tag == self.tag and not inPlatoon[u:GetEntityId()] then
                    local bp = unitBpId(u)
                    if bp then haveByBp[bp] = (haveByBp[bp] or 0) + 1 end
                end
            end
        end

        -- Manual headcount override for direct-spawned first wave
        if self.firstWaveApply and self.spawnFirstDirect and self.builderHandle and self.builderHandle.wanted then
            haveByBp = {}
            for bp, wanted in pairs(self.builderHandle.wanted) do
                haveByBp[bp] = wanted or 0
            end
        end

        local needTotal = 0
        if self.builderHandle and self.builderHandle.wanted then
            for bp, wanted in pairs(self.builderHandle.wanted) do
                local have = haveByBp[bp] or 0
                if (wanted or 0) > have then
                    needTotal = needTotal + (wanted - have)
                end
            end
        end

        if self.params.debug then
            local wantS = summarizeCounts(self.builderHandle and self.builderHandle.wanted or {})
            local haveS = summarizeCounts(haveByBp)
            self:Dbg('Headcount have {' .. haveS .. '} want {' .. wantS .. '} needTotal ' .. tostring(needTotal))
        end

        if self.builderHandle and self.builderHandle.SetHoldBuild then
            self.builderHandle:SetHoldBuild(needTotal <= 0)
        end
        -- Disable first-wave override once we actually see engineers or after 10 seconds grace
        if self.firstWaveApply then
            local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
            local count = 0
            for _, u in ipairs(platoon:GetPlatoonUnits() or {}) do
                if u and not u.Dead then count = count + 1 end
            end
            if count > 0 or (now - (self.firstWaveStartTime or now)) > 10 then
                self.firstWaveApply = false
            end
        end

        local all = {}
        for _,u in ipairs(platoon:GetPlatoonUnits() or {}) do
            if u and not u.Dead then
                local id = unitBpId(u)
                if id then
                    if not u.ub_tag then
                        u.ub_tag = self.tag
                    end
                    table.insert(all, u)
                end
            end
        end

        local pool = {}
        for _, u in ipairs(all) do
            if isIdleEngineer(u) then
                table.insert(pool, u)
            end
        end

        local mins = self.params.taskMin or {}
        local des  = self.params.taskDesired or {}

        local wantRebuild = clamp(des.rebuild or 0, mins.rebuild or 0, 1000)
        local wantAssist  = clamp(des.assist  or 0, mins.assist  or 0, 1000)
        local wantExp     = clamp(des.experimental or 0, mins.experimental or 0, 1000)
        local wantIdle    = clamp(des.idle    or 0, mins.idle    or 0, 1000)

        local reserveIdle = math.min(mins.idle or 0, table.getn(pool))
        local free        = table.getn(pool) - reserveIdle

        -- 1 Rebuild
        local assignedRebuild = 0
        local orders = nil
        if wantRebuild > 0 then
            if type(self.params.rebuildOrdersFn) == 'function' then
                orders = self.params.rebuildOrdersFn(self)
            else
                orders = self:_MakeRebuildOrders()
            end
        end
        if free > 0 and wantRebuild > 0 then
            if type(orders) == 'table' and table.getn(orders) > 0 then
                local cap = math.min(wantRebuild, free)
                for _,ord in ipairs(orders) do
                    if table.getn(pool) <= 0 or assignedRebuild >= cap then break end
                    local bp,x,y,z,h = ord[1], ord[2], ord[3], ord[4], ord[5] or 0
                    local u = table.remove(pool)
                    if u and not u.Dead then
                        IssueClearCommands({u})
                        if x and y and z and bp then
                            IssueBuildMobile({u}, {x,y,z}, bp, {{x,z}})
                        end
                        assignedRebuild = assignedRebuild + 1
                        free = free - 1
                    end
                end
            end
        elseif wantRebuild > 0 then
            local guards = {}
            for _, gu in ipairs(all) do
                if gu and not gu.Dead and gu.IsUnitState and gu:IsUnitState('Guarding') then
                    table.insert(guards, gu)
                end
            end
            local keepAssist = mins.assist or 0
            local canRecall  = math.max(0, table.getn(guards) - keepAssist)
            local ordCount   = (type(orders) == 'table') and table.getn(orders) or 0
            local need       = math.min(wantRebuild, ordCount)

            local take = math.min(need, canRecall)
            for i = 1, take do
                local gu = table.remove(guards)
                if gu and not gu.Dead then
                    IssueClearCommands({gu})
                    table.insert(pool, gu)
                    free = free + 1
                end
            end

            if type(orders) == 'table' and table.getn(orders) > 0 and free > 0 then
                local cap = math.min(wantRebuild, free)
                for _, ord in ipairs(orders) do
                    if table.getn(pool) <= 0 or assignedRebuild >= cap then break end
                    local bp,x,y,z,h = ord[1], ord[2], ord[3], ord[4], ord[5] or 0
                    local u = table.remove(pool)
                    if u and not u.Dead then
                        IssueClearCommands({u})
                        if x and y and z and bp then
                            IssueBuildMobile({u}, {x,y,z}, bp, {{x,z}})
                        end
                        assignedRebuild = assignedRebuild + 1
                        free = free - 1
                    end
                end
            end
        end

        -- 2 Assist
        local assignedAssist = 0
        if free > 0 and wantAssist > 0 then
            local pendingRebuild = 0
            do
                local _ords = type(self.params.rebuildOrdersFn) == 'function'
                    and self.params.rebuildOrdersFn(self)
                    or self:_MakeRebuildOrders()
                pendingRebuild = (type(_ords) == 'table') and table.getn(_ords) or 0
            end

            if pendingRebuild > 0 and free > 0 and wantRebuild > 0 then
                free = math.max(0, free - 1)
            end

            local facs = brain:GetUnitsAroundPoint(categories.FACTORY, center, scanR, 'Ally') or {}
            local actives = {}
            for _,f in ipairs(facs) do
                if f and not f.Dead and f.IsUnitState and f:IsUnitState('Building') then
                    table.insert(actives, f)
                end
            end
            if table.getn(actives) == 0 then
                for _,u in ipairs(all) do
                    if u and not u.Dead and u.IsUnitState and u:IsUnitState('Guarding') then
                        IssueClearCommands({u})
                    end
                end
            else
                local cap = math.min(wantAssist, free)
                local needPer = clamp(self.params.assistPerFactory or 2, 0, 8)
                local needMap = {}
                for _,f in ipairs(actives) do needMap[f:GetEntityId()] = 0 end
                local idx, nact = 1, table.getn(actives)
                while table.getn(pool) > 0 and assignedAssist < cap do
                    local f = actives[idx]
                    if not f or f.Dead then break end
                    local fid = f:GetEntityId()
                    if needMap[fid] < needPer then
                        local u = table.remove(pool)
                        if u and not u.Dead then
                            IssueClearCommands({u})
                            IssueGuard({u}, f)
                            needMap[fid] = needMap[fid] + 1
                            assignedAssist = assignedAssist + 1
                            free = free - 1
                        end
                    end
                    idx = idx + 1
                    if idx > nact then idx = 1 end
                    local totalNeed = 0
                    for _,n in pairs(needMap) do totalNeed = totalNeed + math.max(0, needPer - n) end
                    if totalNeed <= 0 then break end
                end
            end
        end

        -- 3 Experimental
        local assignedExp = 0
        do
            local expBp  = self.params.experimentalBp
            local expPos = markerPos(self.params.experimentalMarker or self.params.baseMarker)
            local expCd  = self.params.experimentalCooldown or 600
            if free > 0 and wantExp > 0 and expBp and expPos then
                local around = brain:GetUnitsAroundPoint(categories.EXPERIMENTAL, expPos, 15, 'Ally') or {}
                local haveExp, completeUnit = false, nil
                for _,u in ipairs(around) do
                    if u and not u.Dead then
                        local id = unitBpId(u)
                        if id == expBp then
                            haveExp = true
                            if isComplete(u) then completeUnit = u end
                        end
                    end
                end
                if completeUnit then
                    if self.params.experimentalAttackFn then
                        local p = brain:MakePlatoon('' .. self.tag .. '_Experimental', '')
                        brain:AssignUnitsToPlatoon(p, {completeUnit}, 'Attack', 'GrowthFormation')
                        local fn = self.params.experimentalAttackFn
                        local function _AttackWrapper(pl, fnv)
                            if type(fnv) == 'function' then return fnv(pl) end
                            if type(fnv) == 'string' and _G and type(_G[fnv]) == 'function' then return _G[fnv](pl) end
                        end
                        p:ForkAIThread(_AttackWrapper, fn)
                    end
                    lastExpTime = GetGameTimeSeconds() or 0
                elseif not haveExp then
                    local now = GetGameTimeSeconds() or 0
                    local cdDone = (now - lastExpTime) >= expCd
                    if cdDone then
                        local cap = math.min(wantExp, free)
                        if cap > 0 and table.getn(pool) > 0 then
                            local builders = {}
                            while table.getn(pool) > 0 and assignedExp < cap do
                                local u = table.remove(pool)
                                if u and not u.Dead then
                                    table.insert(builders, u)
                                    assignedExp = assignedExp + 1
                                    free = free - 1
                                end
                            end
                            local valid = {}
                            for _,u in ipairs(builders) do if u and not u.Dead then table.insert(valid, u) end end
                            if table.getn(valid) > 0 then
                                for _,u in ipairs(valid) do
                                    IssueClearCommands({u})
                                    -- per-unit IssueBuildMobile avoids multi-unit cells ambiguity in simhooks
                                    if expPos and expPos[1] and expPos[2] and expPos[3] then
                                        IssueBuildMobile({u}, expPos, expBp, {{expPos[1], expPos[3]}})
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- 4 Idle
        local idleTarget = math.min(math.max(0, wantIdle), table.getn(pool))
        for i = 1, idleTarget do
            local u = table.remove(pool)
            if u and not u.Dead then
                idleMicro(brain, u, center, self.params.scanRadius or 60, self.params.patrolRadius or 35)
            end
        end

        local didWork = (assignedRebuild > 0) or (assignedAssist > 0) or (assignedExp > 0)
        if didWork then
            WaitSeconds(0.5)
        else
            WaitSeconds(2)
        end
    end
    self:Dbg('EngineerPlatoonAI end')
end

function Manager:Start()
    self:_InitRebuildTracker()
    local comp = self:_MakeComposition()
    local builderParams = {
        brain            = self.brain,
        baseMarker       = self.params.baseMarker,
        domain           = 'LAND',
        composition      = comp,
        difficulty       = self.params.difficulty or 2,
        wantFactories    = self.params.wantFactories or 0,
        priority         = self.params.factoryPriority or 100,
        rallyMarker      = self.params.baseMarker,
        waveCooldown     = 0,
        attackFn         = function(p) self:EngineerPlatoonAI(p) end,
        spawnFirstDirect = (self.params.builderSpawnFirst ~= false),
        builderTag       = self.tag,
        radius           = self.params.leaseRadius or 60,
        _alloc           = self.alloc,
        debug            = self.params.debug and true or false,
        mode             = 3,
    }
    self.spawnFirstDirect = (self.params.builderSpawnFirst ~= false)
self.firstWaveApply = self.spawnFirstDirect
self.firstWaveStartTime = GetGameTimeSeconds and GetGameTimeSeconds() or 0
self.builderHandle = UnitBuilderMod.Start(builderParams)
    -- Prevent early factory builds when we spawn the first wave directly
    if self.spawnFirstDirect and self.builderHandle and self.builderHandle.SetHoldBuild then
        self.builderHandle:SetHoldBuild(true)
    end

end

function Manager:Stop()
    if self.stopped then return end
    self.stopped = true
    if self.builderHandle then
        UnitBuilderMod.Stop(self.builderHandle)
        self.builderHandle = nil
    end
end

-- ========= Public API =========
function Start(params)
    assert(params and params.brain and params.baseMarker, 'brain and baseMarker are required')
    local o = setmetatable({}, Manager)
    o.params  = params
    o.brain   = params.brain
    o.basePos = markerPos(params.baseMarker)
    if not o.basePos then error('Invalid baseMarker: '.. tostring(params.baseMarker)) end
    o.tag     = params.builderTag or ('BE_' .. math.floor(100000 * Random()))
    o.alloc   = params._alloc or FactoryAllocMod.New(o.brain)
    o.bp      = engineerBpsForBrain(o.brain)
    o.stopped = false
    o:Start()
    return o
end

function Stop(handle)
    if handle and handle.Stop then handle:Stop() end
end
