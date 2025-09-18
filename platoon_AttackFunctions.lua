-- /maps/.../platoon_AttackFunctions.lua
-- Platoon Attack Manager: Wave & Raid attacks (autonomous target finding)
--
-- WaveAttack: clears areas of enemy structures by clustering (closest or concentration).
-- Raid: hunts specific structure types (ECO/FAB/DEF), avoids domain-relevant defenses when possible,
--       travels with non‑aggressive formation moves (no aggro-move), and only destroys the requested type.
--
-- Common knobs (PlatoonData):
--   areaRadius        : number  (default 45)   -- engage/scan radius around an area/target
--   intelOnly         : bool    (default false) -- true: only use known intel; false: allow threatmap to seed areas
--   moveInFormation   : bool    (default true)  -- use platoon formation for movement
--   useTransports     : bool    (default false) -- LAND only; reasserts formation after drop
--   transportEachHop  : bool    (default false) -- LAND only; if using transports, reuse each hop
--   canHitUnderwater  : bool|nil (default auto) -- override auto-detect for torpedo/underwater capability
--   domain            : 'LAND'|'AIR'|'NAVAL'|nil -- nil auto-detects from units
--   debug             : bool
--
-- Wave-specific:
--   selectBy          : 'closest'|'concentration' (default 'closest')
--     'closest'        -> attack nearest viable area
--     'concentration'  -> attack densest/most valuable cluster
--
-- Raid-specific:
--   selectBy          : 'ECO'|'FAB'|'INT'|'DEF'|'RAN'|'SMT'
--     'ECO'            -> target Mass Extractors, Mass Fabs, Power Generators
--     'FAB'            -> target Factories, Quantum Gates, Nuke Launchers/Defenders
--     'DEF'            -> target AA turrets, PD (direct fire), Artillery, TML
--     'INT'            -> target Intelligence structures: Radar, Omni, Sonar
--     'RAN'            -> randomly pick one of ECO/FAB/INT/DEF at selection time
--     'SMT'            -> smart pick: choose the type with the MOST undefended targets;
--                         ties broken by LOWEST average defense near targets
--   Behavior details:
--     • Domain-aware avoidance while traveling:
--         AIR  avoids AA; ignores PD/arty.
--         LAND avoids PD/arty/TML; ignores AA.
--         NAVAL best-effort avoids torpedo/naval defenses/TML.
--     • Movement is non-aggressive: uses formation-preserving MoveToLocation/IssueFormMove only.
--     • Strict type-only engagement in the area (does not clear unrelated structures).
--     • Fallback chain over the whole map remains: selectedType → ECO → FAB → INT → DEF.
--       (If selectBy is 'RAN' or 'SMT', the “requestedType” is the result of that mode.)
--
local ScenarioUtils     = import('/lua/sim/ScenarioUtilities.lua')
local ScenarioFramework = import('/lua/ScenarioFramework.lua')

-- ===== Utilities =====
local function log(p, msg)
    if not p then return end
    local lbl = (p.GetPlatoonLabel and p:GetPlatoonLabel()) or 'Platoon'
    LOG(string.format('[PlatoonMgr:%s] %s', lbl, tostring(msg)))
end
local function dbg(p, flag, msg) if flag then log(p, msg) end end

local function dist2d(a, b)
    if not a or not b then return 9e9 end
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt(dx*dx + dz*dz)
end
local function len(t) if type(t) ~= 'table' then return 0 end return table.getn(t) end
local function getMapCenterAndRadius()
    local w, h = GetMapSize()
    local r = math.sqrt((w*w + h*h)) * 0.6
    return { w*0.5, 0, h*0.5 }, r
end
local function isWater(x, z)
    local th = GetTerrainHeight(x, z)
    local sh = GetSurfaceHeight(x, z)
    return sh > th
end
local function adjustToDomainSurface(domain, pos)
    if not pos then return nil end
    local x = pos[1]; local z = pos[3]
    if domain == 'NAVAL' then
        if not isWater(x, z) then
            local r = 8; local step = 2; local twoPi = 6.28318
            local a = 0
            while a < twoPi do
                local nx = x + math.cos(a) * r
                local nz = z + math.sin(a) * r
                if isWater(nx, nz) then return { nx, 0, nz } end
                a = a + (step / r)
            end
        end
        return { x, 0, z }
    elseif domain == 'LAND' then
        if isWater(x, z) then
            local r = 8; local step = 2; local twoPi = 6.28318
            local a = 0
            while a < twoPi do
                local nx = x + math.cos(a) * r
                local nz = z + math.sin(a) * r
                if not isWater(nx, nz) then return { nx, 0, nz } end
                a = a + (step / r)
            end
        end
        return { x, 0, z }
    else
        return { x, 0, z }
    end
end
local function firstAlive(platoon)
    local units = platoon and platoon:GetPlatoonUnits() or {}
    for i = 1, table.getn(units) do local u = units[i]; if u and not u.Dead then return u end end
    return nil
end
local function platoonDomain(platoon)
    local units = platoon and platoon:GetPlatoonUnits() or {}
    local dom = 'LAND'
    for i = 1, table.getn(units) do
        local u = units[i]
        if u and not u.Dead then
            if EntityCategoryContains(categories.NAVAL, u) then return 'NAVAL' end
            if EntityCategoryContains(categories.AIR,   u) then dom = 'AIR' end
        end
    end
    return dom
end
local function allUnits(platoon)
    local list = {}
    local units = platoon:GetPlatoonUnits() or {}
    for i = 1, table.getn(units) do local u = units[i]; if u and not u.Dead then table.insert(list, u) end end
    return list
end
local function anyAlive(platoon)
    local units = platoon and platoon:GetPlatoonUnits() or {}
    for i = 1, table.getn(units) do local u = units[i]; if u and not u.Dead then return true end end
    return false
end
local function waitUntilAtOrTimeout(platoon, dest, r, timeout)
    local waited = 0
    local step = 0.5
    while anyAlive(platoon) do
        local units = platoon:GetPlatoonUnits() or {}
        local at = 0
        for i = 1, table.getn(units) do
            local u = units[i]
            if u and not u.Dead then
                local pos = u:GetPosition()
                if dist2d(pos, dest) <= r then at = at + 1 end
            end
        end
        if at > 0 then return true end
        if timeout and waited >= timeout then return false end
        WaitSeconds(step)
        waited = waited + step
    end
    return false
end

local function issueFormMovePlatoon(platoon, pos, moveForm)
    local units = allUnits(platoon); if len(units) <= 0 then return end
    IssueClearCommands(units)
    if moveForm and platoon.SetPlatoonFormationOverride then
        pcall(function() platoon:SetPlatoonFormationOverride('GrowthFormation') end)
    end
    local ok = false
    if platoon.MoveToLocation then
        local s1 = pcall(function() platoon:MoveToLocation(pos, false) end)
        ok = s1 and true or false
    end
    if not ok and moveForm and IssueFormMove then
        local s2 = pcall(function() IssueFormMove(units, pos, 'GrowthFormation') end)
        ok = s2 and true or false
    end
    if not ok then
        IssueMove(units, pos)
    end
end

local function issueAggroMove(platoon, pos, moveForm)
    local units = allUnits(platoon); if len(units) <= 0 then return end
    IssueClearCommands(units)
    if moveForm and platoon.SetPlatoonFormationOverride then
        pcall(function() platoon:SetPlatoonFormationOverride('GrowthFormation') end)
    end
    local ok = false
    if platoon.AggressiveMoveToLocation then
        local s1 = pcall(function() platoon:AggressiveMoveToLocation(pos) end)
        ok = s1 and true or false
    end
    if not ok and moveForm and IssueFormAggressiveMove then
        local s2 = pcall(function() IssueFormAggressiveMove(units, pos, 'GrowthFormation') end)
        ok = s2 and true or false
    end
    if not ok and moveForm and IssueFormMove then
        local s3 = pcall(function() IssueFormMove(units, pos, 'GrowthFormation') end)
        ok = s3 and true or false
    end
    if not ok then
        IssueAggressiveMove(units, pos)
    end
end

local function issueGroupAttack(platoon, targetUnit)
    local units = allUnits(platoon)
    if len(units) <= 0 then return end
    IssueClearCommands(units)
    IssueAttack(units, targetUnit)
end
local function useTransportsIfWanted(platoon, want, dest)
    if not want then return false end
    local brain = platoon:GetBrain()
    local units = allUnits(platoon)
    if len(units) <= 0 then return false end
    local ok = false
    pcall(function() ok = ScenarioFramework.UseTransports(units, brain, dest, true) end)
    return ok and true or false
end

-- ===== Targeting helpers =====
local function canHitUnderwater(platoon)
    local pd = platoon.PlatoonData or {}
    if pd.canHitUnderwater ~= nil then return pd.canHitUnderwater and true or false end
    local units = platoon:GetPlatoonUnits() or {}
    for i = 1, table.getn(units) do
        local u = units[i]
        if u and not u.Dead then
            local bp = u:GetBlueprint()
            local weps = bp and bp.Weapon or nil
            if type(weps) == 'table' then
                for j = 1, table.getn(weps) do
                    local w = weps[j]
                    if type(w) == 'table' then
                        local caps = w.FireTargetLayerCapsTable
                        if type(caps) == 'table' then if caps.Sub or caps.Seabed then return true end end
                        local wepCat = w.WeaponCategory or w.Label or ''
                        if type(wepCat) == 'string' then local s = string.lower(wepCat); if string.find(s, 'torpedo') then return true end end
                    end
                end
            end
        end
    end
    return false
end

-- Domain filter for structures
local function buildTargetCategory(domain, allowUnderwater)
    local base = categories.STRUCTURE
    if domain == 'LAND' then
        return base - categories.NAVAL
    elseif domain == 'NAVAL' then
        local cat = base * categories.NAVAL
        if allowUnderwater and categories.SEABED then cat = cat + (base * categories.SEABED) end
        return cat
    else -- AIR
        local cat = base
        if allowUnderwater and categories.SEABED then cat = cat + (base * categories.SEABED) end
        return cat
    end
end

-- Value scoring for prioritizing within an area
local function structureScore(u)
    if not u or u.Dead then return 0 end
    local bp = u:GetBlueprint(); if not bp then return 1 end
    local econ = bp.Economy or {}; local mass = econ.BuildCostMass or 1; local en = econ.BuildCostEnergy or 0
    local val  = mass + (en * 0.02)
    local cats = bp.CategoriesHash or {}
    if cats.FACTORY then val = val + 400 end
    if cats.EXPERIMENTAL then val = val + 1500 end
    if cats.TECH3 then val = val + 150 end
    if cats.TECH2 then val = val + 60 end
    if cats.MASSEXTRACTION then val = val + 120 end
    if cats.ENERGYPRODUCTION then val = val + 100 end
    if cats.DEFENSE then val = val + 80 end
    if cats.ANTIAIR then val = val + 60 end
    if cats.ANTIMISSILE then val = val + 140 end
    if cats.SHIELD then val = val + 120 end
    return val
end

local function structuresInArea(brain, allowCat, center, r)
    local found = brain:GetUnitsAroundPoint(allowCat, center, r, 'Enemy') or {}
    local out = {}
    for i = 1, table.getn(found) do local u = found[i]; if u and not u.Dead then table.insert(out, {u, structureScore(u)}) end end
    table.sort(out, function(a, b) return (a[2] or 0) > (b[2] or 0) end)
    return out
end

-- ===== WaveAttack =====

-- cluster scan of known structures -> { {pos,value,count}, ... }
local function scanKnownAreas(brain, allowCat, areaR)
    local center, bigR = getMapCenterAndRadius()
    local all = brain:GetUnitsAroundPoint(allowCat, center, bigR, 'Enemy') or {}
    local bins = {}; local order = {}
    for i = 1, table.getn(all) do
        local u = all[i]
        if u and not u.Dead then
            local pos = u:GetPosition(); local gx = math.floor(pos[1] / areaR); local gz = math.floor(pos[3] / areaR)
            local key = tostring(gx)..':'..tostring(gz)
            local b = bins[key]
            if not b then b = { sum=0, count=0, cx=0, cz=0 }; bins[key]=b; table.insert(order, key) end
            local sc = structureScore(u); b.sum = b.sum + sc; b.count = b.count + 1; b.cx = b.cx + pos[1]; b.cz = b.cz + pos[3]
        end
    end
    local out = {}
    for i = 1, table.getn(order) do local b=bins[order[i]]; if b and b.count>0 then table.insert(out, { {b.cx/b.count,0,b.cz/b.count}, b.sum, b.count }) end end
    return out
end

-- threatmap scan -> { {pos,threat,0}, ... }
local function scanThreatAreas(brain, myPos, domain, areaR)
    local candidates = {}
    local function readThreat(ttype, rings)
        local ok, res = pcall(function() return brain:GetThreatsAroundPosition(myPos, rings, ttype) end)
        if not ok or type(res) ~= 'table' then return end
        for i = 1, table.getn(res) do
            local e = res[i]; local pos=nil; local threat=0
            if type(e) == 'table' then
                if type(e[1]) == 'table' then pos = { e[1][1] or myPos[1], 0, e[1][2] or myPos[3] }; threat = e[2] or 0
                else pos = { e[1] or myPos[1], 0, e[2] or myPos[3] }; threat = e[3] or 0 end
            end
            if pos and threat and threat > 0 then table.insert(candidates, { pos, threat, 0 }) end
        end
    end
    local rings = 16
    readThreat('Economy', rings); readThreat('Structures', rings); if len(candidates) <= 0 then readThreat('Overall', rings) end
    local filtered = {}; for i = 1, table.getn(candidates) do local pos=candidates[i][1]; local adj=adjustToDomainSurface(domain,pos); if adj then table.insert(filtered,{adj,candidates[i][2],0}) end end
    return filtered
end

local function pickArea(platoon, areas, mode)
    local u = firstAlive(platoon); if not u then return nil end
    local my = u:GetPosition()
    if mode == 'concentration' then
        local best=nil; local bestMeasure=-1; local bestDist=9e9
        for i=1,table.getn(areas) do local e=areas[i]; local pos=e[1]; local measure=e[3] or e[2] or 0; local d=dist2d(my,pos)
            if (measure>bestMeasure) or (measure==bestMeasure and d<bestDist) then bestMeasure=measure; bestDist=d; best=pos end
        end
        return best
    else
        local best=nil; local bestD=9e9
        for i=1,table.getn(areas) do local pos=areas[i][1]; local d=dist2d(my,pos); if d<bestD then bestD=d; best=pos end end
        return best
    end
end

local function clearArea(platoon, allowCat, center, r, intelOnly, debugFlag)
    local brain = platoon:GetBrain(); local idleCycles=0; local idleCap=8
    while anyAlive(platoon) do
        local targets = structuresInArea(brain, allowCat, center, r)
        if len(targets) <= 0 then
            if intelOnly then dbg(platoon, debugFlag, 'Area clear or no intel; leaving (intelOnly)'); return
            else idleCycles = idleCycles + 1; if idleCycles >= idleCap then dbg(platoon, debugFlag, 'Area clear (no targets after linger)'); return end; WaitSeconds(1) end
        else
            idleCycles = 0; local pick = targets[1][1]
            if pick and not pick.Dead then
                issueGroupAttack(platoon, pick)
                local t=0; while anyAlive(platoon) do if not pick or pick.Dead then break end; if t>=45 then break end; WaitSeconds(1); t=t+1 end
            end
        end
        WaitSeconds(0.2)
    end
end

local function findNextTargetArea(platoon, allowCat, areaR, intelOnly, domain, selectBy, debugFlag)
    local brain = platoon:GetBrain()
    local u = firstAlive(platoon); if not u then return nil end
    local myPos = u:GetPosition()
    if intelOnly then
        local areas = scanKnownAreas(brain, allowCat, areaR); if len(areas) <= 0 then dbg(platoon, debugFlag, 'No known enemy structures (intelOnly)'); return nil end
        return pickArea(platoon, areas, selectBy)
    else
        local spots = scanThreatAreas(brain, myPos, domain, areaR)
        if len(spots) <= 0 then local areas = scanKnownAreas(brain, allowCat, areaR); if len(areas) <= 0 then dbg(platoon, debugFlag, 'No threat spots or known structures'); return nil end; return pickArea(platoon, areas, selectBy) end
        return pickArea(platoon, spots, selectBy)
    end
end

function WaveAttack(platoon)
    if not platoon then return end
    local pd = platoon.PlatoonData or {}
    local dbgFlag = pd.debug and true or false
    local domain = pd.domain or platoonDomain(platoon)
    local uw = canHitUnderwater(platoon)
    local allowCat = buildTargetCategory(domain, uw)
    local areaR      = pd.areaRadius or 45
    local intelOnly  = (pd.intelOnly and true or false)        -- default false
    local moveForm   = (pd.moveInFormation ~= false)           -- default true
    local wantTrans  = (domain == 'LAND') and (pd.useTransports == true) -- default false
    local hopTrans   = (domain == 'LAND') and (pd.transportEachHop and true or false)
    local selectBy   = (pd.selectBy == 'concentration') and 'concentration' or 'closest'

    if moveForm and platoon.SetPlatoonFormationOverride then pcall(function() platoon:SetPlatoonFormationOverride('GrowthFormation') end) end

    while anyAlive(platoon) do
        local dest = findNextTargetArea(platoon, allowCat, areaR, intelOnly, domain, selectBy, dbgFlag)
        if not dest then WaitSeconds(3)
        else
            dest = adjustToDomainSurface(domain, dest) or dest
            local movedByTrans = false
            if wantTrans and (hopTrans or true) then movedByTrans = useTransportsIfWanted(platoon, true, dest); if movedByTrans then WaitSeconds(2) end end
            if not movedByTrans then issueFormMovePlatoon(platoon, dest, moveForm) end
            waitUntilAtOrTimeout(platoon, dest, areaR * 1.2, 60)
            clearArea(platoon, allowCat, dest, areaR, intelOnly, dbgFlag)
            WaitSeconds(1)
        end
    end
end

-- ===== Raid Attack =====

-- small helpers
local function catUnion(a, b) if not a then return b end return a + b end

-- Build category for target type (ECO/FAB/DEF) intersected with STRUCTURE
local function targetTypeCategory(t)
    local c = nil
    if t == 'ECO' then
        if categories.MASSEXTRACTION then c = catUnion(c, categories.MASSEXTRACTION) end
-- === Raid selection helpers ===
local function safeRandomChoice(list)
    local n = type(list) == 'table' and table.getn(list) or 0
    if n <= 0 then return nil end
    local r = math.random(1, n)
    return list[r]
end

local function gatherTypeCandidates(brain, allowDomainCat, t)
    local typeCat = targetTypeCategory(t)
    local finalCat = allowDomainCat * typeCat
    local center, bigR = getMapCenterAndRadius()
    return brain:GetUnitsAroundPoint(finalCat, center, bigR, 'Enemy') or {}
end

local function smartPickType(platoon, domain, uw, areaR, intelOnly)
    local brain = platoon:GetBrain()
    local allowDomainCat = buildTargetCategory(domain, uw)
    local types = { 'ECO', 'FAB', 'INT', 'DEF' }
    local bestType = 'ECO'
    local bestUndef = -1
    local bestAvg = 1e9

    for i = 1, table.getn(types) do
        local t = types[i]
        local cands = gatherTypeCandidates(brain, allowDomainCat, t)
        local count = table.getn(cands)
        if count > 0 then
            local undef = 0
            local sumDef = 0
            for j = 1, count do
                local u = cands[j]
                if u and not u.Dead then
                    local pos = u:GetPosition()
                    local ds = defenseScoreAtFiltered(brain, pos, domain, areaR * 1.2)
                    sumDef = sumDef + ds
                    if ds <= 0 then undef = undef + 1 end
                end
            end
            local avg = sumDef / count
            if (undef > bestUndef) or (undef == bestUndef and avg < bestAvg) then
                bestUndef = undef
                bestAvg = avg
                bestType = t
            end
        end
    end
    return bestType
end

        if categories.MASSFABRICATION then c = catUnion(c, categories.MASSFABRICATION) end
        if categories.ENERGYPRODUCTION then c = catUnion(c, categories.ENERGYPRODUCTION) end
    elseif t == 'FAB' then
        if categories.FACTORY then c = catUnion(c, categories.FACTORY) end
        if categories.GATE then c = catUnion(c, categories.GATE) end
        if categories.QUANTUMGATE then c = catUnion(c, categories.QUANTUMGATE) end
        if categories.NUKE then c = catUnion(c, categories.NUKE) end
        if categories.STRATEGICMISSILELAUNCHER then c = catUnion(c, categories.STRATEGICMISSILELAUNCHER) end
        if categories.STRATEGICMISSILEPLATFORM then c = catUnion(c, categories.STRATEGICMISSILEPLATFORM) end
    elseif t == 'DEF' then
        local aa = nil; if categories.DEFENSE and categories.ANTIAIR then aa = categories.DEFENSE * categories.ANTIAIR end
    elseif t == 'INT' then
        if categories.RADAR then c = (c and (c + categories.RADAR)) or categories.RADAR end
        if categories.OMNI then c = (c and (c + categories.OMNI)) or categories.OMNI end
        if categories.SONAR then c = (c and (c + categories.SONAR)) or categories.SONAR end
        local pd = nil; if categories.DEFENSE and categories.DIRECTFIRE then pd = categories.DEFENSE * categories.DIRECTFIRE end
        local arty = categories.ARTILLERY or nil
        local tml = categories.TACTICALMISSILEPLATFORM or nil
        c = catUnion(c, aa); c = catUnion(c, pd); if arty then c = catUnion(c, arty) end; if tml then c = catUnion(c, tml) end
    end
    if c then return categories.STRUCTURE * c end
    return categories.STRUCTURE
end

-- Build chain: requested -> ECO -> FAB -> DEF (dedup)
local function buildRaidChain(req)
    local order = { req, 'ECO', 'FAB', 'INT', 'DEF' }
    local out = {}
    local seen = {}
    for i = 1, table.getn(order) do
        local t = order[i]
        if type(t) == 'string' and not seen[t] then
            seen[t] = true
            table.insert(out, t)
        end
    end
    return out
end

-- Determine if a defense unit can hit the given domain (category heuristics + weapon caps)
local function defenseHitsDomain(defU, domain)
    if not defU or defU.Dead then return false end
    local bp = defU.Blueprint or defU:GetBlueprint() or {}
    local cats = bp.CategoriesHash or {}
    if domain == 'AIR' then
        if cats.ANTIAIR then return true end
    elseif domain == 'LAND' then
        if cats.DIRECTFIRE or cats.INDIRECTFIRE or cats.ARTILLERY or cats.TACTICALMISSILEPLATFORM then return true end
    elseif domain == 'NAVAL' then
        if cats.TORPEDO or (cats.NAVAL and (cats.DIRECTFIRE or cats.ARTILLERY)) then return true end
    end
    local weps = bp.Weapon or {}
    if type(weps) == 'table' then
        for i = 1, table.getn(weps) do
            local w = weps[i]; if type(w) == 'table' then
                local caps = w.FireTargetLayerCapsTable
                if type(caps) == 'table' then
                    if domain == 'AIR' and caps.Air then return true end
                    if domain == 'LAND' and (caps.Land or caps.Water) then return true end
                    if domain == 'NAVAL' and (caps.Water or caps.Sub or caps.Seabed) then return true end
                end
            end
        end
    end
    return false
end

-- Count defenses near a position that can hit our domain
local function defenseScoreAt(brain, pos, domain, r)
    local defCat = categories.DEFENSE
    if categories.ARTILLERY then defCat = defCat + categories.ARTILLERY end
    if categories.TACTICALMISSILEPLATFORM then defCat = defCat + categories.TACTICALMISSILEPLATFORM end
    local found = brain:GetUnitsAroundPoint(defCat, pos, r, 'Enemy') or {}
    local n = 0
    for i = 1, table.getn(found) do
        local u = found[i]
        if u and not u.Dead and defenseHitsDomain(u, domain) then n = n + 1 end
    end
    return n
end

-- Threatmap scan (reused) -> spots list
local function scanThreatAreasForRaid(brain, myPos, domain, areaR)
    return scanThreatAreas(brain, myPos, domain, areaR)
end

-- Find next raid target (returns position and the active type)
local function findNextRaidTarget(platoon, reqType, domain, uw, intelOnly, areaR, debugFlag)
    local brain = platoon:GetBrain()
    local chain = buildRaidChain(reqType)
    local allowDomain = buildTargetCategory(domain, uw)

    local uAlive = firstAlive(platoon); if not uAlive then return nil, nil end
    local myPos = uAlive:GetPosition()

    -- try chain with known intel first
    for i = 1, table.getn(chain) do
        local t = chain[i]
        local typeCat = targetTypeCategory(t)
        local finalCat = allowDomain * typeCat
        local center, bigR = getMapCenterAndRadius()
        local candidates = brain:GetUnitsAroundPoint(finalCat, center, bigR, 'Enemy') or {}

        if len(candidates) > 0 then
            -- pick by least defenses (tie: closest)
            local bestU = nil; local bestDef = 1e9; local bestD = 1e9
            for j = 1, table.getn(candidates) do
                local u = candidates[j]
                if u and not u.Dead then
                    local pos = u:GetPosition()
                    local defScore = defenseScoreAt(brain, pos, domain, areaR * 1.2)
                    local d = dist2d(myPos, pos)
                    if (defScore < bestDef) or (defScore == bestDef and d < bestD) then
                        bestDef = defScore; bestD = d; bestU = u
                    end
                end
            end
            if bestU then return bestU:GetPosition(), t end
        end
        if not intelOnly then
            -- threat-based probe (type hint via which threat to favor is implicit)
            local spots = scanThreatAreasForRaid(brain, myPos, domain, areaR)
            if len(spots) > 0 then
                local bestPos=nil; local bestDef=1e9; local bestD=1e9
                for k=1,table.getn(spots) do
                    local pos = spots[k][1]
                    local defScore = defenseScoreAt(brain, pos, domain, areaR * 1.2)
                    local d = dist2d(myPos, pos)
                    if (defScore < bestDef) or (defScore == bestDef and d < bestD) then
                        bestDef = defScore; bestD = d; bestPos = pos
                    end
                end
                if bestPos then return bestPos, t end
            end
        end
    end

    return nil, nil
end

-- Engage only the requested target type inside the area, then return
local function clearRaidArea(platoon, domain, uw, raidType, center, r, intelOnly, debugFlag)
    local brain = platoon:GetBrain()
    local allowDomain = buildTargetCategory(domain, uw)
    local typeCat = targetTypeCategory(raidType)
    local finalCat = allowDomain * typeCat

    local idleCycles = 0; local idleCap = 6
    while anyAlive(platoon) do
        local candidates = brain:GetUnitsAroundPoint(finalCat, center, r, 'Enemy') or {}
        if len(candidates) <= 0 then
            if intelOnly then dbg(platoon, debugFlag, 'Raid area: no targets of requested type (intelOnly); leaving'); return
            else idleCycles = idleCycles + 1; if idleCycles >= idleCap then dbg(platoon, debugFlag, 'Raid area: no targets after linger; leaving'); return end; WaitSeconds(1) end
        else
            -- focus the highest-value target among this type in the area
            local best=nil; local bestVal=-1
            for i=1,table.getn(candidates) do local u=candidates[i]; if u and not u.Dead then local v=structureScore(u); if v>bestVal then bestVal=v; best=u end end end
            if best then
                issueGroupAttack(platoon, best)
                local t=0; while anyAlive(platoon) do if not best or best.Dead then break end; if t>=45 then break end; WaitSeconds(1); t=t+1 end
            end
        end
        WaitSeconds(0.2)
    end
end

function Raid(platoon)
    if not platoon then return end
    local pd = platoon.PlatoonData or {}
    local dbgFlag = pd.debug and true or false
    local domain = pd.domain or platoonDomain(platoon)
    local uw = canHitUnderwater(platoon)
    local areaR      = pd.areaRadius or 45
    local intelOnly  = (pd.intelOnly and true or false)        -- default false
    local moveForm   = (pd.moveInFormation ~= false)           -- default true
    local wantTrans  = (domain == 'LAND') and (pd.useTransports == true) -- default false
    local hopTrans   = (domain == 'LAND') and (pd.transportEachHop and true or false)
    local reqType    = pd.raidType or 'ECO'                    -- default ECO if omitted

    if moveForm and platoon.SetPlatoonFormationOverride then pcall(function() platoon:SetPlatoonFormationOverride('GrowthFormation') end) end

    while anyAlive(platoon) do
        local dest, activeType = findNextRaidTarget(platoon, reqType, domain, uw, intelOnly, areaR, dbgFlag)
        if not dest then
            WaitSeconds(3)
        else
            dest = adjustToDomainSurface(domain, dest) or dest
            local movedByTrans = false
            if wantTrans and (hopTrans or true) then movedByTrans = useTransportsIfWanted(platoon, true, dest); if movedByTrans then WaitSeconds(2) end end
            if not movedByTrans then issueFormMovePlatoon(platoon, dest, moveForm) end

            waitUntilAtOrTimeout(platoon, dest, areaR * 1.2, 60)
            clearRaidArea(platoon, domain, uw, activeType or reqType, dest, areaR, intelOnly, dbgFlag)
            WaitSeconds(1)
        end
    end
end

-- Module export
local M = {
    WaveAttack = WaveAttack,
    Raid = Raid,
}
return M
