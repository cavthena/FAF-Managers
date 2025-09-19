--[[
manager_BaseEngineer.lua  — consolidated header (updated 2025-09-19)

Summary
  Base Engineer Manager that:
    • Owns base engineers/SCUs for a base (by builderTag) and replaces losses via leased factories
    • Rebuilds structures using BaseManager build groups or manual AddBuildGroup()
    • Assists actively-building factories within scanRadius
    • Builds experimentals at a marker, hands them off (incl. platoon_AttackFunctions), and respects cooldown
    • Idles extras to wander within patrolRadius with opportunistic repair/reclaim
    • Clean Stop() tears down threads and returns factory leases

New in this version
  • BaseManager integration: pass `baseManager` (and optional `fetchRebuildGroups`) to auto-ingest rebuild groups.
  • platoon_AttackFunctions handoff: pass a string AI name (e.g., 'Raid', 'WaveAttack') or a table
    `{ ai='Raid', data={...} }` to create a platoon and fork that AI for the finished experimental.

Parameters (Start)
  brain (AIBrain)                 — owner brain (ArmyBrains[...])
  baseMarker (string)             — editor marker for base location
  difficulty (1..3)               — used to pick wantT1/2/3/SCU from {easy, med, hard} arrays
  builderTag (string)             — tag to reserve engineers/SCUs for this manager
  spawnFirst (bool)               — spawn initial roster instantly at baseMarker
  wantFactories (int)             — number of factories to lease for replacements (0 = no leasing)
  radius (number)                 — factory search radius around base
  scanRadius (number)             — radius for assist/repair/reclaim/rebuild scanning
  patrolRadius (number)           — idle wander radius
  wantT1|wantT2|wantT3|wantSCU    — tables {e,m,h} for alive counts per difficulty
  taskMin, taskMax (tables)       — minima/maxima for Rebuild/Assist/Experimental (Idle has no max)
  experimentalBp (string|nil)     — BP id of experimental to build (optional)
  experimentalMarker (string|nil) — marker where the experimental is placed (optional)
  experimentalCooldown (number)   — delay after completion before the next experimental
  experimentalHandoff             — one of:
                                    * function(unit) — custom callback (legacy)
                                    * 'Raid'|'WaveAttack' — AI name in platoon_AttackFunctions
                                    * { ai='Raid', data={...} } — AI name plus PlatoonData table
  experimentalAIFile (string|nil) — override path to platoon_AttackFunctions.lua (optional)
  baseManager (table|nil)         — BaseManager handle to mirror rebuild groups from (optional)
  fetchRebuildGroups (func|nil)   — custom getter: function(bm)->{{bp=...,pos=...,heading=...}} (optional)
  priority (number)               — factory allocator priority
  debug (bool)                    — verbose logs

Public API
  local BE = import('/maps/.../manager_BaseEngineer.lua')
  local h = BE.Start{ ...params... }
  BE.AddBuildGroup(h, tbl)    -- still supported; merges with BaseManager feed
  BE.Stop(h)

Tasking Priority & Assignment
  Rebuild > Assist > Experimental > Idle
  1) Fill each task to taskMin (from Idle)
  2) Top to taskMax (from Idle)
  3) Only excess goes Idle; Idlers wander and opportunistically repair/reclaim

Experimental Handoff examples
  -- Name only (requires platoon_AttackFunctions.lua discoverable)
  experimentalHandoff = 'Raid',

  -- Name + PlatoonData (passed into platoon.PlatoonData)
  experimentalHandoff = { ai='WaveAttack', data={ areaRadius=60, moveInFormation=true } },

  -- Custom function (legacy)
  experimentalHandoff = function(exp) LOG('Custom handoff for '.. exp.UnitId) end,

BaseManager usage (example)
  ScenarioInfo.CFNBEngi = EngiMgr.Start{
    brain = ArmyBrains[ScenarioInfo.Cybran],
    baseMarker = 'Cybran_ForwardNorthBase_Zone',
    difficulty = Difficulty,
    builderTag = 'CFNB',
    spawnFirst = true,
    wantFactories = 1, radius = 30, scanRadius = 30, patrolRadius = 35,
    wantT1={1,1,2}, wantT2={0,0,0}, wantT3={0,0,0}, wantSCU={0,0,0},
    taskMin={Rebuild=1, Assist=0, Experimental=0},
    taskMax={Rebuild=1, Assist=2, Experimental=0},
    baseManager = ScenarioInfo.Cybran_FNB,
    -- optional if file not on MapPath: experimentalAIFile = '/maps/.../platoon_AttackFunctions.lua',
  }

Stop()
  Cancels loops, returns any active factory lease, and ends the BaseManager watcher.

]]

local ScenarioUtils     = import('/lua/sim/ScenarioUtilities.lua')
local FactoryAllocMod   = import('/maps/faf_coop_U01.v0001/manager_FactoryHandler.lua')  -- allocator API  :contentReference[oaicite:2]{index=2}

-- Shared allocator per-brain (same pattern as UnitBuilder)
ScenarioInfo.AllocByBrain = ScenarioInfo.AllocByBrain or {}
local function GetAllocator(brain)
    local a = ScenarioInfo.AllocByBrain[brain]
    if not a then
        a = FactoryAllocMod.New(brain)
        ScenarioInfo.AllocByBrain[brain] = a
    end
    return a
end

-- ===== helpers =====
local function markerPos(mark) return mark and ScenarioUtils.MarkerToPosition(mark) or nil end

local function dist2d(a, b)
    if not a or not b then return 1e9 end
    local dx, dz = (a[1] or 0)-(b[1] or 0), (a[3] or 0)-(b[3] or 0)
    return math.sqrt(dx*dx + dz*dz)
end

local function isComplete(u)
    if not u or u.Dead then return false end
    if u.GetFractionComplete and u:GetFractionComplete() < 1 then return false end
    if u.IsUnitState and u:IsUnitState('BeingBuilt') then return false end
    return true
end

local function now() return GetGameTimeSeconds() end

local function clamp01(x) return math.max(0, math.min(1, x or 0)) end

local function pickDifficulty(v, d)
    if type(v) == 'table' then return v[math.max(1, math.min(3, d or 2))] or 0 end
    return v or 0
end

local function factionIndex(brain)
    local idx = (brain.GetFactionIndex and brain:GetFactionIndex()) or (brain.FactionIndex) or 1
    return math.max(1, math.min(4, idx))
end

local EngineerBp = {
    -- T1, T2, T3, SCU
    [1] = { T1='uel0105', T2='uel0208', T3='uel0309', SCU='uel0301' }, -- UEF
    [2] = { T1='ual0105', T2='ual0208', T3='ual0309', SCU='ual0301' }, -- Aeon
    [3] = { T1='url0105', T2='url0208', T3='url0309', SCU='url0301' }, -- Cybran
    [4] = { T1='xsl0105', T2='xsl0208', T3='xsl0309', SCU='xsl0301' }, -- Seraphim
}

local function unitId(u)
    local id = (u.BlueprintID or (u.GetBlueprint and u:GetBlueprint() and u:GetBlueprint().BlueprintId))
    if type(id) == 'string' then
        id = string.lower(id)
        return string.match(id, '/units/([^/]+)/') or id
    end
    return nil
end

local function isOurEngineer(u, brain, tag)
    if not u or u.Dead then return false end
    if u:GetAIBrain() ~= brain then return false end
    if not (u.BlueprintID or (u.GetBlueprint and u:GetBlueprint())) then return false end
    if not (u:IsInCategory(categories.ENGINEER) or u:IsInCategory(categories.SUBCOMMANDER)) then return false end
    local okTag = (not u.be_tag) or (u.be_tag == tag)
    return okTag
end

-- ===== class =====
local M = {}
M.__index = M

function M:Log(m) LOG(('[BE:%s] %s'):format(self.tag, m)) end
function M:Warn(m) WARN(('[BE:%s] %s'):format(self.tag, m)) end
function M:Dbg(m) if self.debug then self:Log(m) end end

local function _normalize(p)
    return {
        brain         = p.brain,
        baseMarker    = p.baseMarker,
        difficulty    = p.difficulty or 2,
        builderTag    = p.builderTag or ('BE_'.. math.floor(100000*Random())),
        spawnFirst    = p.spawnFirst and true or false,
        wantFactories = math.max(0, p.wantFactories or 0),
        radius        = p.radius or 60,
        scanRadius    = p.scanRadius or 70,
        patrolRadius  = p.patrolRadius or 30,
        wantT1        = p.wantT1 or {0,0,0},
        wantT2        = p.wantT2 or {0,0,0},
        wantT3        = p.wantT3 or {0,0,0},
        wantSCU       = p.wantSCU or {0,0,0},
        taskMin       = p.taskMin or { Rebuild=1, Assist=1, Experimental=0 },
        taskMax       = p.taskMax or { Rebuild=6, Assist=6, Experimental=6 },
        experimentalBp       = p.experimentalBp,
        experimentalMarker   = p.experimentalMarker,
        experimentalCooldown = p.experimentalCooldown or 0,
        experimentalHandoff  = p.experimentalHandoff,
        priority      = p.priority or 200,
        debug         = p.debug and true or false,
        _alloc        = p._alloc,
    }
end

-- allocator lease params
function M:_MakeLease()
    return {
        markerName   = self.params.baseMarker,
        markerPos    = self.basePos,
        radius       = self.params.radius or 60,
        domain       = 'LAND',                 -- engineers are produced at land factories
        wantFactories= self.params.wantFactories or 0,
        priority     = self.params.priority or 200,
        onGrant      = function(list, id) self:OnLeaseGranted(list, id) end,
        onUpdate     = function(list, id) self:OnLeaseUpdated(list, id) end,
        onRevoke     = function(rev, id, why) self:OnLeaseRevoked(rev, id, why) end,
        onComplete   = function(id) end,
    }
end

-- ===== lifecycle =====
function M:Start()
    -- initial spawn
    if self.params.spawnFirst then
        self:SpawnInitial()
    end
    -- threads
    self.collectThread = self.brain:ForkThread(function() self:CollectLoop() end)
    self.mainThread    = self.brain:ForkThread(function() self:MainLoop() end)
    if self.params.experimentalBp and self.params.experimentalMarker then
        self.expThread = self.brain:ForkThread(function() self:ExperimentalLoop() end)
    end

if self.params.baseManager or self.params.fetchRebuildGroups then
    self.rebuildThread = self.brain:ForkThread(function() self:RebuildSourceLoop() end)
end

end

function M:Stop()
    if self.stopped then return end
    self.stopped = true
    if self.leaseId then
        self.alloc:ReturnLease(self.leaseId)
        self.leaseId = nil
    end
    if self.collectThread then KillThread(self.collectThread) self.collectThread = nil end
    if self.mainThread    then KillThread(self.mainThread)    self.mainThread    = nil end
    if self.expThread     then KillThread(self.expThread)     self.expThread     = nil end
    if self.rebuildThread then KillThread(self.rebuildThread) self.rebuildThread = nil end

end

-- ===== counts / wants =====
function M:_WantedCounts()
    local d = self.params.difficulty or 2
    return {
        T1  = pickDifficulty(self.params.wantT1, d),
        T2  = pickDifficulty(self.params.wantT2, d),
        T3  = pickDifficulty(self.params.wantT3, d),
        SCU = pickDifficulty(self.params.wantSCU, d),
    }
end

function M:_CountOwned()
    local c = { T1=0, T2=0, T3=0, SCU=0 }
    for _, u in pairs(self.owned or {}) do
        if u and not u.Dead then
            if u:IsInCategory(categories.SUBCOMMANDER) then
                c.SCU = c.SCU + 1
            elseif u:IsInCategory(categories.ENGINEER) then
                -- classify by tech
                if u:IsInCategory(categories.TECH3) then c.T3 = c.T3 + 1
                elseif u:IsInCategory(categories.TECH2) then c.T2 = c.T2 + 1
                else c.T1 = c.T1 + 1 end
            end
        end
    end
    return c
end

local function _sum(tbl) local s=0; for _,n in pairs(tbl or {}) do s=s+(n or 0) end return s end

-- ===== initial spawn =====
function M:SpawnInitial()
    local f = EngineerBp[self.faction]
    local want = self:_WantedCounts()
    local spawnAt = self.basePos
    local function _make(bp, n)
        for i=1, n or 0 do
            local u = CreateUnitHPR(bp, self.brain:GetArmyIndex(), spawnAt[1], spawnAt[2], spawnAt[3], 0,0,0)
            if u then
                u.be_tag = self.tag
                self.owned[u:GetEntityId()] = u
            end
        end
    end
    _make(f.T1,  want.T1)
    _make(f.T2,  want.T2)
    _make(f.T3,  want.T3)
    _make(f.SCU, want.SCU)
    self:Dbg(('SpawnInitial: T1=%d T2=%d T3=%d SCU=%d'):format(want.T1, want.T2, want.T3, want.SCU))
end

-- ===== leasing & replacements =====
function M:_EnsureLease()
    if (self.params.wantFactories or 0) == 0 then return end
    if self.leaseId then return end
    self.leaseId = self.alloc:RequestFactories(self:_MakeLease())
end

function M:OnLeaseGranted(list, id)
    self.leased = self.leased or {}
    local rp = self.basePos
    for _, f in ipairs(list or {}) do
        if f and not f.Dead then
            self.leased[f:GetEntityId()] = f
            IssueClearFactoryCommands({f})
            if rp then IssueFactoryRallyPoint({f}, rp) end
        end
    end
    self:QueueNeededBuilds()
end

function M:OnLeaseUpdated(list, id)
    self.leased = self.leased or {}
    local rp = self.basePos
    for _, f in ipairs(list or {}) do
        if f and not f.Dead then
            self.leased[f:GetEntityId()] = f
            IssueClearFactoryCommands({f})
            if rp then IssueFactoryRallyPoint({f}, rp) end
        end
    end
    self:QueueNeededBuilds()
end

function M:OnLeaseRevoked(rev, id, why)
    if not self.leased then return end
    for entId, _ in pairs(rev or {}) do self.leased[entId] = nil end
    -- if none remain, drop leaseId so we can request again later
    local any = false
    for _, f in pairs(self.leased) do if f and not f.Dead then any = true break end end
    if not any then self.leaseId = nil end
end

function M:_LiveFactories(usableOnly)
    local out = {}
    for _, f in pairs(self.leased or {}) do
        if f and not f.Dead then
            if not usableOnly then
                table.insert(out, f)
            else
                local up = f.IsUnitState and f:IsUnitState('Upgrading')
                local gd = f.IsUnitState and f:IsUnitState('Guarding')
                local ps = f.IsPaused and f:IsPaused()
                if not (up or gd or ps) then table.insert(out, f) end
            end
        end
    end
    return out
end

function M:QueueNeededBuilds()
    -- compute deficit
    local want = self:_WantedCounts()
    local have = self:_CountOwned()
    local d = {
        T1  = math.max(0, (want.T1 or 0) - (have.T1 or 0)),
        T2  = math.max(0, (want.T2 or 0) - (have.T2 or 0)),
        T3  = math.max(0, (want.T3 or 0) - (have.T3 or 0)),
        SCU = math.max(0, (want.SCU or 0) - (have.SCU or 0)),
    }
    local total = _sum(d)
    if total <= 0 then
        -- release lease if we hold one
        if self.leaseId then
            IssueClearFactoryCommands(self:_LiveFactories(false))
            self.alloc:ReturnLease(self.leaseId)
            self.leaseId = nil
        end
        return
    end

    self:_EnsureLease()
    local flist = self:_LiveFactories(true)
    if table.getn(flist) == 0 then return end

    -- RR queue builders
    local rr = 1
    local f   = EngineerBp[self.faction]
    local order = {
        { f.SCU, d.SCU },
        { f.T3,  d.T3  },
        { f.T2,  d.T2  },
        { f.T1,  d.T1  },
    }
    for _, pair in ipairs(order) do
        local bp, need = pair[1], pair[2]
        while need > 0 and table.getn(flist) > 0 do
            if rr > table.getn(flist) then rr = 1 end
            local fac = flist[rr]
            if fac and not fac.Dead then
                local q0 = 0
                if fac.GetCommandQueue then q0 = table.getn(fac:GetCommandQueue() or {}) end
                IssueBuildFactory({fac}, bp, 1)  -- same approach as UnitBuilder  :contentReference[oaicite:3]{index=3}
                local q1 = q0
                if fac.GetCommandQueue then q1 = table.getn(fac:GetCommandQueue() or {}) end
                if q1 > q0 then need = need - 1 end
                rr = rr + 1
            else
                rr = rr + 1
            end
        end
    end
end

-- ===== adoption loop (collect roll-offs + adopt locals) =====
function M:CollectLoop()
    self:Dbg('CollectLoop: start')
    while not self.stopped do
        -- scoop untagged engies/SCUs near factories and base
        local near = {}
        -- around leased factories
        for _, f in pairs(self.leased or {}) do
            if f and not f.Dead then
                local around = self.brain:GetUnitsAroundPoint(categories.MOBILE, f:GetPosition(), 35, 'Ally') or {}
                for _, u in ipairs(around) do table.insert(near, u) end
            end
        end
        -- around base
        local aroundBase = self.brain:GetUnitsAroundPoint(categories.MOBILE, self.basePos, 35, 'Ally') or {}
        for _, u in ipairs(aroundBase) do table.insert(near, u) end

        for _, u in ipairs(near) do
            if isOurEngineer(u, self.brain, self.params.builderTag) then
                if not self.owned[u:GetEntityId()] and isComplete(u) then
                    u.be_tag = self.tag
                    self.owned[u:GetEntityId()] = u
                end
            end
        end

        -- periodically nudge builds if short
        self:QueueNeededBuilds()
        WaitSeconds(1)
    end
    self:Dbg('CollectLoop: end')
end

-- ===== tasking =====
function M:_TaskSnapshot()
    local snap = { Rebuild={}, Assist={}, Experimental={}, Idle={} }
    for id, u in pairs(self.owned or {}) do
        if u and not u.Dead then
            local t = self.assignment[id] or 'Idle'
            table.insert(snap[t], u)
        end
    end
    return snap
end

function M:_Assign(units, task)
    for _, u in ipairs(units or {}) do
        if u and not u.Dead then
            self.assignment[u:GetEntityId()] = task
            self:_PushOrders(u, task)
        end
    end
end

-- find a factory currently building to assist
function M:_PickFactoryToAssist()
    local list = self.brain:GetListOfUnits(categories.FACTORY) or {}
    local best, bestd = nil, 1e9
    for _, fac in ipairs(list) do
        if fac and not fac.Dead and fac:GetAIBrain()==self.brain then
            if dist2d(fac:GetPosition(), self.basePos) <= (self.params.scanRadius or 60) then
                local building = fac.IsUnitState and fac:IsUnitState('Building')
                local upgrading= fac.IsUnitState and fac:IsUnitState('Upgrading')
                if building or upgrading then
                    local d = dist2d(fac:GetPosition(), self.basePos)
                    if d < bestd then best, bestd = fac, d end
                end
            end
        end
    end
    return best
end

-- get next missing structure from rebuild plans
function M:_NextRebuildTarget()
    for i, e in ipairs(self.rebuild or {}) do
        if not e.done then
            -- check present structure
            local here = self.brain:GetUnitsAroundPoint(categories.STRUCTURE, e.pos, 3, 'Ally') or {}
            local exists = false
            for _, su in ipairs(here) do
                if not su.Dead then
                    local bid = unitId(su)
                    if type(bid)=='string' and string.find(bid, string.lower(e.bp), 1, true) then
                        exists = true; break
                    end
                end
            end
            if not exists then
                return i, e
            else
                self.rebuild[i].done = true
            end
        end
    end
    return nil, nil
end

function M:_PushOrders(u, task)
    if task == 'Assist' then
        local fac = self:_PickFactoryToAssist()
        if fac then
            IssueClearCommands({u})
            IssueGuard({u}, fac)
        end
    elseif task == 'Rebuild' then
        local idx, entry = self:_NextRebuildTarget()
        if entry then
            IssueClearCommands({u})
            -- Build placement: typical call is IssueBuildMobile({eng}, bp, pos, 0)
            -- If your build helper swaps params, feel free to flip them here.
            IssueBuildMobile({u}, entry.bp, entry.pos, 0)
        else
            -- nothing to rebuild, demote to Assist this tick
            local fac = self:_PickFactoryToAssist()
            if fac then
                IssueClearCommands({u})
                IssueGuard({u}, fac)
            end
        end
    elseif task == 'Experimental' then
        -- Orders are orchestrated by ExperimentalLoop (lead builder + assists).
        -- Here we just “stage” them at the pad so ExpLoop can find/use them.
        local pad = self.expPos
        if pad then
            local q = u.GetCommandQueue and u:GetCommandQueue() or {}
            if table.getn(q) == 0 then
                IssueMove({u}, pad)
            end
        end
    else -- Idle
        -- short wander; opportunistic repair/reclaim is handled in MainLoop tick
        local r = self.params.patrolRadius or 30
        local ang = Random() * 2 * math.pi
        local off = { self.basePos[1] + math.cos(ang)*r*Random(),
                      self.basePos[2],
                      self.basePos[3] + math.sin(ang)*r*Random() }
        IssueMove({u}, off)
    end
end

-- Opportunistic repair/reclaim for a single unit near base (cheap & safe)
function M:_OpportunisticWork(u)
    if not u or u.Dead then return end
    -- quick repair try
    local hurt = self.brain:GetUnitsAroundPoint(categories.STRUCTURE, u:GetPosition(), 18, 'Ally') or {}
    for _, t in ipairs(hurt) do
        if t and not t.Dead and (t.GetHealth and t.GetMaxHealth and t:GetHealth() < t:GetMaxHealth()) then
            IssueRepair({u}, t)
            return
        end
    end
    -- quick reclaim (if engine exposes a helper; guard with pcall)
    local ok, rect = pcall(GetReclaimablesInRect, Rect(self.basePos[1]-self.params.scanRadius, self.basePos[3]-self.params.scanRadius, self.basePos[1]+self.params.scanRadius, self.basePos[3]+self.params.scanRadius))
    if ok and rect and table.getn(rect) > 0 then
        -- pick the closest reclaim to this engineer
        local up = u:GetPosition()
        local best, bd = nil, 1e9
        for _, r in ipairs(rect) do
            if r and r.CanBeReclaimed and r:CanBeReclaimed() then
                local p = r.CachePosition or r:GetPosition()
                local d = dist2d(up, p)
                if d < bd then best, bd = r, d end
            end
        end
        if best then IssueReclaim({u}, best) return end
    end
end

-- ===== experimental loop =====


-- ===== experimental handoff helpers (platoon_AttackFunctions compatibility) =====
-- Supports:
--   • params.experimentalHandoff = function(unit) ... end            -- custom
--   • params.experimentalHandoff = 'Raid' | 'WaveAttack'             -- AI name from module
--   • params.experimentalHandoff = { ai='Raid', data={...} }         -- AI + PlatoonData
-- Optional:
--   • params.experimentalAIFile = '/maps/.../platoon_AttackFunctions.lua'
function M:_ImportPlatoonAI()
    local path = self.params.experimentalAIFile or '/maps/.../platoon_AttackFunctions.lua'
    local ok, mod = pcall(import, path)
    if ok and type(mod) == 'table' then return mod end
    -- fallback: try relative map path if available
    if type(ScenarioInfo) == 'table' and type(ScenarioInfo.MapPath) == 'string' then
        local alt = ScenarioInfo.MapPath .. 'platoon_AttackFunctions.lua'
        local ok2, mod2 = pcall(import, alt)
        if ok2 and type(mod2) == 'table' then return mod2 end
    end
    return nil
end

function M:_HandoffExperimentalViaPlatoon(expUnit, spec)
    if not expUnit or expUnit.Dead then return end
    local aiName = nil
    local pData  = nil
    if type(spec) == 'string' then aiName = spec
    elseif type(spec) == 'table' then aiName = spec.ai; pData = spec.data end
    if not aiName then return end

    local aiMod = self:_ImportPlatoonAI()
    if not aiMod then
        self:Warn('Experimental handoff requested platoon AI "'.. tostring(aiName) ..'", but platoon_AttackFunctions could not be imported')
        return
    end
    local aiFunc = aiMod[aiName]
    if type(aiFunc) ~= 'function' then
        self:Warn('Experimental handoff: AI "'.. tostring(aiName) ..'" not found in platoon_AttackFunctions')
        return
    end

    -- Create a fresh platoon and assign the experimental to it
    local brain = self.brain
    local okMake, platoon = pcall(function() return brain:MakePlatoon('', '') end)
    if not okMake or not platoon then
        self:Warn('Experimental handoff: failed to MakePlatoon')
        return
    end

    -- Assign and set a benign formation (GrowthFormation works well with our AI)
    pcall(function() brain:AssignUnitsToPlatoon(platoon, { expUnit }, 'Attack', 'GrowthFormation') end)
    pcall(function() platoon:SetPlatoonLabel('BE_Experimental') end)

    -- Attach user-specified PlatoonData if provided
    if type(pData) == 'table' then
        platoon.PlatoonData = pData
    else
        platoon.PlatoonData = {}
    end

    -- Kick the AI (forked so our manager thread is not blocked)
    platoon:ForkThread(function(p) aiFunc(p) end, platoon)
end
function M:ExperimentalLoop()
    self:Dbg('ExperimentalLoop: start')
    self.expPos = markerPos(self.params.experimentalMarker) or self.basePos
    local bp    = self.params.experimentalBp
    local cd    = math.max(0, self.params.experimentalCooldown or 0)
    local nextOk= now()

    local function _findExpUnderConstruction()
        local near = self.brain:GetUnitsAroundPoint(categories.EXPERIMENTAL, self.expPos, 12, 'Ally') or {}
        for _, u in ipairs(near) do
            if u and not u.Dead and u:GetAIBrain()==self.brain then
                local id = unitId(u) or ''
                if string.find(id, string.lower(bp), 1, true) then
                    return u
                end
            end
        end
        return nil
    end

    while not self.stopped do
        local assigned = 0
        for _, u in pairs(self.owned or {}) do
            if self.assignment[u:GetEntityId()] == 'Experimental' then
                assigned = assigned + (isComplete(u) and 1 or 0)
            end
        end

        if assigned > 0 and now() >= nextOk then
            local current = _findExpUnderConstruction()
            if not current then
                -- pick a lead builder and start it, others will help
                local lead = nil
                for _, u in pairs(self.owned or {}) do
                    if self.assignment[u:GetEntityId()] == 'Experimental' and isComplete(u) then
                        lead = u; break
                    end
                end
                if lead then
                    IssueClearCommands({lead})
                    IssueBuildMobile({lead}, bp, self.expPos, 0)
                    -- helpers guard the construction after a moment
                    self.brain:ForkThread(function()
                        WaitSeconds(1)
                        local target = _findExpUnderConstruction()
                        if target then
                            for _, u in pairs(self.owned or {}) do
                                if u ~= lead and self.assignment[u:GetEntityId()] == 'Experimental' and isComplete(u) then
                                    IssueClearCommands({u})
                                    IssueGuard({u}, target)
                                end
                            end
                        end
                    end)
                end
            else
                -- if it exists, watch for completion
                if current.GetFractionComplete and current:GetFractionComplete() >= 1 then
                    -- handoff
                    local fn = self.params.experimentalHandoff
                    if type(fn) == 'string' then fn = rawget(_G, fn) end
                    if type(fn) == 'function' then pcall(fn, current) elseif type(self.params.experimentalHandoff) == 'string' or type(self.params.experimentalHandoff) == 'table' then self:_HandoffExperimentalViaPlatoon(current, self.params.experimentalHandoff) end nextOk = now() + cd
                end
            end
        end
        WaitSeconds(1)
    end
    self:Dbg('ExperimentalLoop: end')
end

-- ===== main balance loop =====
function M:MainLoop()
    self:Dbg('MainLoop: start')
    while not self.stopped do
        -- prune dead / out of brain
        for id, u in pairs(self.owned or {}) do
            if (not u) or u.Dead or u:GetAIBrain() ~= self.brain then
                self.owned[id] = nil
                self.assignment[id] = nil
            end
        end

        -- compute need and keep replacement pipeline alive
        self:QueueNeededBuilds()

        -- task rebalance
        local snap = self:_TaskSnapshot()
        local min  = self.params.taskMin or {}
        local max  = self.params.taskMax or {}
        local order = { 'Rebuild', 'Assist', 'Experimental' }

        local idle = snap.Idle
        local function take(n)
            local out = {}
            n = math.max(0, n or 0)
            while n > 0 and table.getn(idle) > 0 do
                table.insert(out, table.remove(idle)) n = n - 1
            end
            return out
        end

        -- 1) ensure minima
        for _, name in ipairs(order) do
            local cur = table.getn(snap[name] or {})
            local need = math.max(0, (min[name] or 0) - cur)
            if need > 0 then
                self:_Assign(take(need), name)
            end
        end

        -- refresh snapshot (some Idles moved)
        snap = self:_TaskSnapshot()
        idle = snap.Idle

        -- 2) top up to maxima (purely from Idle)
        for _, name in ipairs(order) do
            local cur = table.getn(snap[name] or {})
            local room = math.max(0, (max[name] or 0) - cur)
            if room > 0 then
                self:_Assign(take(room), name)
            end
        end

        -- 3) opportunistic work for idlers (lightweight)
        for _, u in ipairs(idle or {}) do
            self:_OpportunisticWork(u)
        end

        WaitSeconds(1)
    end
    self:Dbg('MainLoop: end')
end

-- ===== ctor / API =====
local function Start(p)
    assert(p and p.brain and p.baseMarker, 'brain and baseMarker are required')
    local o = setmetatable({}, M)
    o.params     = _normalize(p)
    o.brain      = o.params.brain
    o.tag        = o.params.builderTag or ('BE_'.. math.floor(100000*Random()))
    o.basePos    = markerPos(o.params.baseMarker)
    if not o.basePos then error('Invalid baseMarker: '.. tostring(o.params.baseMarker)) end
    o.alloc      = o.params._alloc or GetAllocator(o.brain)
    o.debug      = o.params.debug
    o.faction    = factionIndex(o.brain)
    o.owned      = {}
    o.assignment = {}
    o.rebuild    = {}         -- filled via AddBuildGroup
    o.stopped    = false
    o:Start()
    return o
end

local function AddBuildGroup(handle, groupTbl)
    if not (handle and handle.rebuild) then return end
    if type(groupTbl) ~= 'table' then return end
    for _, e in ipairs(groupTbl) do
        if e and e.bp and e.pos then
            table.insert(handle.rebuild, { bp=e.bp, pos=e.pos, heading=e.heading or 0, done=false })
        end
    end
end

local function Stop(handle) if handle and handle.Stop then handle:Stop() end end


-- ===== external rebuild groups (BaseManager integration) =====
function M:_FetchExternalRebuildGroups()
    -- Prefer explicit fetcher
    if type(self.params.fetchRebuildGroups) == 'function' then
        local ok, list = pcall(self.params.fetchRebuildGroups, self.params.baseManager)
        if ok and type(list) == 'table' then return list end
    end
    local bm = self.params.baseManager
    if not bm then return nil end

    -- Try method forms
    if type(bm.GetRebuildGroups) == 'function' then
        local ok, list = pcall(bm.GetRebuildGroups, bm)
        if ok and type(list) == 'table' then return list end
    end
    if type(bm.GetBuildGroups) == 'function' then
        local ok, list = pcall(bm.GetBuildGroups, bm)
        if ok and type(list) == 'table' then return list end
    end

    -- Try common fields
    if type(bm.RebuildGroups) == 'table' then return bm.RebuildGroups end
    if type(bm.BuildGroups)   == 'table' then return bm.BuildGroups   end

    return nil
end

function M:RebuildSourceLoop()
    self:Dbg('RebuildSourceLoop: start')
    local seen = {}
    local function key(e)
        if not e or not e.bp or not e.pos then return nil end
        local x = math.floor((e.pos[1] or 0) + 0.5)
        local z = math.floor((e.pos[3] or 0) + 0.5)
        return string.format('%s@%d@%d', string.lower(e.bp), x, z)
    end

    while not self.stopped do
        local ext = self:_FetchExternalRebuildGroups()
        if type(ext) == 'table' then
            for _, e in ipairs(ext) do
                if e and e.bp and e.pos then
                    local k = key(e)
                    if k and not seen[k] then
                        table.insert(self.rebuild, { bp=e.bp, pos=e.pos, heading=e.heading or 0, done=false })
                        seen[k] = true
                    end
                end
            end
        end
        WaitSeconds(2)
    end
    self:Dbg('RebuildSourceLoop: end')
end


-- export
function StartManager(params) return Start(params) end
Start = StartManager
AddBuildGroup = AddBuildGroup
Stop = Stop