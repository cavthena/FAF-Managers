-- /maps/faf_coop_U01.v0001/manager_FactoryHandler.lua
-- Lightweight Factory Allocator (leases factories to requesters)
-- Clean build: debug prints removed, stable API

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local Alloc = {}
Alloc.__index = Alloc

ScenarioInfo.AllocByBrain = ScenarioInfo.AllocByBrain or {}
function GetAllocator(brain)
    if not brain then return nil end
    local alloc = ScenarioInfo.AllocByBrain[brain]
    if not alloc then
        alloc = Alloc.New(brain)
        ScenarioInfo.AllocByBrain[brain] = alloc
    end
    return alloc
end

local function FactoryDomainCats(domain)
    if domain == 'LAND' then
        return categories.FACTORY * categories.LAND
    elseif domain == 'AIR' then
        return categories.FACTORY * categories.AIR
    elseif domain == 'NAVAL' then
        -- Avoid SEABED here; some builds don’t expose it at import time
        return categories.FACTORY * categories.NAVAL
    else
        return categories.FACTORY
    end
end

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

function Alloc.New(armyBrain)
    local self = setmetatable({}, Alloc)
    self.Brain          = armyBrain
    self.ReqSeq         = 0
    self.Requests       = {}     -- [id] = req
    self.Queue          = {}     -- req ids, priority-sorted
    self.FactoryState   = {}     -- [entId] = { unit, leased=false, leaseId=nil }
    self.UpdateInterval = 0.5
    self.Running        = true
    self.MainThread     = armyBrain:ForkThread(function() self:MainLoop() end)
    return self
end

-- ================= Public API =================
-- params:
--   markerName | markerPos
--   radius (default 60)
--   domain: 'LAND'|'AIR'|'NAVAL'|'AUTO'
--   wantFactories: number (0 = all available)
--   priority: number (higher first, default 50)
--   onGrant(factories_tbl, leaseId)
--   onUpdate(factories_tbl, leaseId)
--   onRevoke(revoked_tbl, leaseId, reason)
--   onComplete(leaseId)
function Alloc:RequestFactories(params)
    self.ReqSeq = self.ReqSeq + 1
    local id = self.ReqSeq

    local req = {
        id          = id,
        markerName  = params.markerName,
        markerPos   = params.markerPos,
        radius      = params.radius or 60,
        domain      = (params.domain or 'AUTO'):upper(),
        want        = math.max(0, params.wantFactories or 0),
        priority    = params.priority or 50,
        onGrant     = params.onGrant,
        onUpdate    = params.onUpdate,
        onRevoke    = params.onRevoke,
        onComplete  = params.onComplete,
        granted     = {}, -- [entId] = unit
    }

    if not req.markerPos then
        local pos = ScenarioUtils.MarkerToPosition(req.markerName)
        if not pos then
            WARN('[FactoryAlloc] Marker not found for lease request: '.. tostring(req.markerName))
            return nil
        end
        req.markerPos = pos
    end

    self.Requests[id] = req
    req.enqueuedAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0
    self:Enqueue(id)
    return id
end

function Alloc:ReturnLease(leaseId)
    local req = self.Requests[leaseId]
    if not req then return end
    for entId, unit in pairs(req.granted) do
        local fs = self.FactoryState[entId]
        if fs then
            fs.leased  = false
            fs.leaseId = nil
        end
    end
    req.granted = {}
    if req.onComplete then pcall(req.onComplete, leaseId) end
    for i, v in ipairs(self.Queue) do
        if v == leaseId then table.remove(self.Queue, i) break end
    end
    self.Requests[leaseId] = nil
end

function Alloc:GetGrantedUnits(leaseId)
    local req = self.Requests[leaseId]
    if not req then return {} end
    local out = {}
    for _, u in pairs(req.granted) do table.insert(out, u) end
    return out
end

function Alloc:Shutdown()
    self.Running = false
    if self.MainThread then
        KillThread(self.MainThread)
        self.MainThread = nil
    end
end

-- ================= Internals =================

function Alloc:HasHigherPriorityWaiter(myPriority)
    local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
    for _, id in ipairs(self.Queue or {}) do
        local req = self.Requests[id]
        if req then
            local have = 0
            for _ in pairs(req.granted or {}) do have = have + 1 end
            local target = (req.want == 0) and math.huge or (req.want or 0)
            local need = math.max(0, target - have)
            local eff = EffectivePriority(req, now)
            if need > 0 and eff > (myPriority or 0) then
                return true
            end
        end
    end
    return false
end

function Alloc:Enqueue(id)
    table.insert(self.Queue, id)
    table.sort(self.Queue, function(a, b)
        local ra, rb = self.Requests[a], self.Requests[b]
        if not ra or not rb then return a < b end
        if ra.priority == rb.priority then return a < b end
        return ra.priority > rb.priority
    end)
end

function Alloc:MainLoop()
    while self.Running do
        self:Tick()
        WaitSeconds(self.UpdateInterval)
    end
end

function Alloc:Tick()
    -- Clean up lost/dead factories and revoke from holders
    for entId, fs in pairs(self.FactoryState) do
        local u = fs.unit
        if (not u) or u:IsDead() or u:GetAIBrain() ~= self.Brain then
            if fs.leased and fs.leaseId and self.Requests[fs.leaseId] then
                local req = self.Requests[fs.leaseId]
                req.granted[entId] = nil
                if req.onRevoke then pcall(req.onRevoke, { [entId] = u }, fs.leaseId, 'lost') end
                if next(req.granted) == nil and req.onComplete then pcall(req.onComplete, fs.leaseId) end
            end
            self.FactoryState[entId] = nil
        end
    end

    -- Re-sort queue each tick by aged priority (higher first)
    local now = GetGameTimeSeconds and GetGameTimeSeconds() or 0
    table.sort(self.Queue, function(a, b)
        local ra, rb = self.Requests[a], self.Requests[b]
        if not ra or not rb then return (a or 0) < (b or 0) end
        local pa, pb = EffectivePriority(ra, now), EffectivePriority(rb, now)
        if pa == pb then return (ra.id or 0) < (rb.id or 0) end -- FIFO among equals
        return pa > pb
    end)

    -- Service requests in priority order
    for _, id in ipairs(self.Queue) do
        local req = self.Requests[id]
        if req then self:Service(req) end
    end

    -- Clean empty requests
    local i = 1
    while i <= table.getn(self.Queue) do
        local id = self.Queue[i]
        local req = self.Requests[id]
        if not req then
            table.remove(self.Queue, i)
        else
            i = i + 1
        end
    end
end

function Alloc:Service(req)
    local domainCats = (req.domain == 'AUTO') and categories.FACTORY or FactoryDomainCats(req.domain)

    if not (req.markerPos and tonumber(req.markerPos[1]) and tonumber(req.markerPos[3])) then
        WARN('[FactoryAlloc] bad markerPos for request '.. tostring(req.id))
        return
    end

    local list = self.Brain:GetListOfUnits(domainCats) or {}

    local candidates = {}
    for _, u in ipairs(list) do
        if u and not u:IsDead() and u:GetAIBrain() == self.Brain and self:IsNear(u, req.markerPos, req.radius) then
            local entId = u:GetEntityId()
            local fs = self.FactoryState[entId]
            if not fs then
                fs = { unit = u, leased = false, leaseId = nil }
                self.FactoryState[entId] = fs
            end
            if not fs.leased then
                table.insert(candidates, u)
            end
        end
    end

    -- How many do we still want?
    local have = 0
    for _ in pairs(req.granted) do have = have + 1 end

    local target = (req.want == 0) and math.huge or req.want
    local need = math.max(0, target - have)

    -- Try to lease any unleased candidates first (existing code)
    if need > 0 then
        local grantedNow = {}
        for _, u in ipairs(candidates) do
            if need <= 0 then break end
            local entId = u:GetEntityId()
            local fs = self.FactoryState[entId]
            if fs and not fs.leased then
                fs.leased = true
                fs.leaseId = req.id
                req.granted[entId] = u
                table.insert(grantedNow, u)
                need = need - 1
            end
        end
        if table.getn(grantedNow) > 0 then
            if have == 0 and req.onGrant then
                pcall(req.onGrant, grantedNow, req.id)
            elseif req.onUpdate then
                pcall(req.onUpdate, grantedNow, req.id)
            end
            have = have + table.getn(grantedNow)
        end
    end
end

function Alloc:IsNear(unit, pos, radius)
    local up = unit:GetPosition()
    local dx, dz = up[1]-pos[1], up[3]-pos[3]
    return (dx*dx + dz*dz) <= (radius*radius)
end


return {
    New = Alloc.New,
    GetAllocator = GetAllocator,
}