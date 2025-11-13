--[[
================================================================================
Platoon Attack Functions (Lua 5.0, FAF safe)
================================================================================

Overview
    Drop-in attack behaviours for the FAF Manager suite.  They can be assigned
    directly to a platoon via `platoon:ForkAIThread` or indirectly by providing
    `attackFn` and `attackData` when starting the UnitBuilder or UnitSpawner
    managers.

    local AttackFns = import('/maps/<map>/platoon_AttackFunctions.lua')

    -- Wave attack -------------------------------------------------------------
    function SpawnWave(platoon)
        local data = {
            Type        = 'cluster',       -- 'closest' | 'cluster' | 'value'
            IntelOnly   = false,
            TargetArmy  = { 'PLAYER_1' },
            Formation   = 'GrowthFormation',
            AvoidDef    = true,
            Transport   = true,
            Amphibious  = false,
        }
        AttackFns.WaveAttack(platoon, data)
    end

    -- Raid attack -------------------------------------------------------------
    function LaunchRaid(platoon)
        local data = {
            Category    = 'ECO',           -- 'ECO' | 'BLD' | 'INT' | 'DEF' | 'SMT'
            IntelOnly   = true,
            TargetArmy  = { 2, 4 },
            Formation   = 'AttackFormation',
            Submersible = false,
            Transport   = false,
        }
        AttackFns.RaidAttack(platoon, data)
    end

    -- Scout attack ------------------------------------------------------------
    function PatrolScouts(platoon)
        local data = {
            IntelOnly = true,
        }
        AttackFns.ScoutAttack(platoon, data)
    end

Universal parameters
    All attack functions accept the arguments listed below through their
    `attackData` table.  Missing fields fall back to the stated defaults.

        IntelOnly   (boolean, default = false)
            Search for targets only in areas with existing intel.  Threat heat
            maps are sampled to find candidate positions.  When false, a
            flood-fill search around the platoon's position discovers potential
            locations.

        TargetArmy  (table | nil)
            List of army indices or names that may be targeted.  Nil allows all
            enemy armies.

        Formation   (string, default = 'GrowthFormation')
            Movement formation used for move orders.  Allowed values are
            'AttackFormation', 'GrowthFormation', or 'NoFormation'.

        Submersible (boolean, default = false)
            Include units with the SUBMERSIBLE category when evaluating targets.

        AvoidDef    (boolean, default = false)
            Attempt to route around defensive structures that can harm the
            platoon's movement layer while travelling to a target.  When no
            alternative exists the least threatening path is chosen.

        Transport   (boolean, default = false)
            Allow the platoon to request transports to bypass impassable
            terrain.  Transports are loaded at the platoon's current position
            and unloaded near the target, after which the platoon proceeds under
            its own power.

        Amphibious  (boolean, default = false)
            Treat both land and water as passable terrain when routing.

WaveAttack specifics
        Type (string, default = 'closest')
            Determines how targets are prioritised: 'closest', 'cluster', or
            'value'.  Search areas are 50 units wide and the platoon clears all
            structures within an area before moving on.

RaidAttack specifics
        Category (string, default = 'ECO')
            Requested structure category: 'ECO', 'BLD', 'INT', 'DEF', or 'SMT'.
            Areas are 25 units wide.  The priority chain is always
            Requested > ECO > BLD > INT > DEF.

ScoutAttack specifics
        Designed for AIR platoons.  Each unit receives a move target.  Upon
        arriving, the unit either selects a new destination or has a 10% chance
        to orbit the location for up to two minutes.  Destinations are random
        map positions with a 25% chance of being the hottest or coolest area on
        the threat map.
================================================================================
]]

local ScenarioFramework = import('/lua/ScenarioFramework.lua')
local NavUtils           = import('/lua/sim/NavUtils.lua')
local GetTerrainHeight   = GetTerrainHeight
local GetSurfaceHeight   = GetSurfaceHeight

local table_getn    = table.getn
local table_insert  = table.insert
local table_remove  = table.remove
local math_sqrt     = math.sqrt
local math_abs      = math.abs
local math_min      = math.min
local math_max      = math.max
local math_floor    = math.floor
local math_random   = math.random
local math_cos      = math.cos
local math_sin      = math.sin
local math_huge     = math.huge or 1e9

local RecheckDelay            = 10
local WaveAreaRadius          = 50
local RaidAreaRadius          = 25
local AreaClearRadius         = 35
local TransportStagingOffset  = 28
local OrbitChance             = 0.10
local HotColdChance           = 0.25
local MaxScoutOrbitTime       = 120
local FloodFillCell           = 32
local FloodFillMaxRadius      = 512
local ThreatSampleRing        = 32
local AvoidThreatMultiplier   = 1.5
local PlayableIngressTimeout  = 60
local PlayableIngressBuffer   = 10

local StructureCategory = categories.STRUCTURE - categories.WALL
local NavalStructure    = categories.STRUCTURE * categories.NAVAL
local LandStructure     = categories.STRUCTURE - categories.NAVAL
local SubmersibleCat    = categories.SUBMERSIBLE

local RaidCategories = {
    ECO = categories.MASSEXTRACTION + categories.MASSPRODUCTION + categories.ENERGYPRODUCTION + categories.HYDROCARBON + categories.MASSSTORAGE + categories.ENERGYSTORAGE,
    BLD = categories.FACTORY + categories.ENGINEER + (categories.STRUCTURE * categories.ENGINEERSTATION),
    INT = categories.RADAR + categories.SONAR,
    DEF = categories.DEFENSE + categories.ANTIMISSILE + categories.SHIELD,
}

local LayerMapping = {
    LAND  = 'Land',
    LAND1 = 'Land',
    LAND2 = 'Land',
    AIR   = 'Air',
    NAVAL = 'Water',
    WATER = 'Water',
    HOVER = 'Amphibious',
    AMPHIBIOUS = 'Amphibious',
}

local FormationOptions = {
    AttackFormation = true,
    GrowthFormation = true,
    NoFormation     = true,
}

local function SafeWait(seconds)
    if seconds and seconds > 0 then
        WaitSeconds(seconds)
    else
        WaitTicks(1)
    end
end

local function PlatoonAlive(platoon)
    if not platoon then return false end
    local brain = platoon:GetBrain()
    if not brain then return false end
    if not brain:PlatoonExists(platoon) then return false end
    local units = platoon:GetPlatoonUnits()
    return (units and table_getn(units) > 0)
end

local function CopyVector(vec)
    if not vec then return nil end
    return { vec[1], vec[2], vec[3] }
end

local function VectorAdd(a, b)
    return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
end

local function DistanceSq(a, b)
    local dx = a[1] - b[1]
    local dz = a[3] - b[3]
    return dx * dx + dz * dz
end

local function Distance(a, b)
    return math_sqrt(DistanceSq(a, b))
end

local function PrependWaypoint(path, waypoint)
    if not waypoint then
        return path
    end

    path = path or {}
    local count = table_getn(path)

    if count == 0 then
        table_insert(path, CopyVector(waypoint))
        return path
    end

    local first = path[1]
    if not first then
        table_insert(path, 1, CopyVector(waypoint))
        return path
    end

    if DistanceSq(first, waypoint) > 1 then
        table_insert(path, 1, CopyVector(waypoint))
    end

    return path
end

local function DetermineLayer(platoon, amphibious)
    if amphibious then
        return 'Amphibious'
    end

    if platoon.MovementLayer then
        return LayerMapping[string.upper(platoon.MovementLayer)] or platoon.MovementLayer
    end

    local units = platoon:GetPlatoonUnits() or {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            if EntityCategoryContains(categories.AIR, unit) then
                return 'Air'
            elseif EntityCategoryContains(categories.AMPHIBIOUS, unit) or EntityCategoryContains(categories.HOVER, unit) then
                return amphibious and 'Amphibious' or 'Land'
            elseif EntityCategoryContains(categories.NAVAL, unit) then
                return 'Water'
            else
                return 'Land'
            end
        end
    end

    return 'Land'
end

local function ValidateFormation(value)
    if value and FormationOptions[value] then
        return value
    end
    return 'GrowthFormation'
end

local function CopyOptions(data)
    local opts = {}
    if type(data) == 'table' then
        for k, v in pairs(data) do
            opts[k] = v
        end
    end
    opts.IntelOnly   = opts.IntelOnly   and true or false
    opts.Submersible = opts.Submersible and true or false
    opts.AvoidDef    = opts.AvoidDef    and true or false
    opts.Transport   = opts.Transport   and true or false
    opts.Amphibious  = opts.Amphibious  and true or false
    opts.Formation   = ValidateFormation(opts.Formation)
    return opts
end

local function GetPlatoonPosition(platoon)
    local pos = platoon:GetPlatoonPosition()
    if pos then
        return { pos[1], pos[2], pos[3] }
    end
    local units = platoon:GetPlatoonUnits() or {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            return { unit:GetPositionXYZ() }
        end
    end
    return nil
end

local function GetPlayableArea()
    if not ScenarioInfo then
        return nil
    end

    if ScenarioInfo.PlayableArea then
        return ScenarioInfo.PlayableArea
    end

    local size = ScenarioInfo.size or ScenarioInfo.MapSize
    if size then
        return { 0, 0, size[1], size[2] }
    end

    return nil
end

local function PositionInPlayableArea(position, area)
    if not (position and area) then
        return true
    end

    return position[1] >= area[1]
        and position[1] <= area[3]
        and position[3] >= area[2]
        and position[3] <= area[4]
end

local function ClampToPlayableArea(position, area, buffer)
    if not (position and area) then
        return position
    end

    buffer = buffer or 0
    local minX = area[1] + buffer
    local maxX = area[3] - buffer
    if minX > maxX then
        local mid = (area[1] + area[3]) * 0.5
        minX = mid
        maxX = mid
    end
    local minZ = area[2] + buffer
    local maxZ = area[4] - buffer
    if minZ > maxZ then
        local mid = (area[2] + area[4]) * 0.5
        minZ = mid
        maxZ = mid
    end

    local x = math_min(math_max(position[1], minX), maxX)
    local z = math_min(math_max(position[3], minZ), maxZ)
    local y = GetSurfaceHeight(x, z)

    return { x, y, z }
end

local function Midpoint(a, b)
    return { (a[1] + b[1]) * 0.5, 0, (a[3] + b[3]) * 0.5 }
end

local function SurfacePoint(vec)
    if not vec then return nil end
    local x = vec[1]
    local z = vec[3]
    return { x, GetSurfaceHeight(x, z), z }
end

local function SegmentPlayableIngress(outside, inside, area)
    if not (outside and inside and area) then
        return nil
    end

    -- Binary search along the segment until we find a point just inside the playable area
    local entry = CopyVector(inside)
    local exit = CopyVector(outside)

    for _ = 1, 12 do
        local mid = Midpoint(entry, exit)
        if PositionInPlayableArea(mid, area) then
            entry = mid
        else
            exit = mid
        end
    end

    local entryPoint = SurfacePoint(entry)
    if not entryPoint then
        return nil
    end

    if PlayableIngressBuffer > 0 then
        local dirX = entry[1] - exit[1]
        local dirZ = entry[3] - exit[3]
        local len = math_sqrt(dirX * dirX + dirZ * dirZ)
        if len > 0 then
            local scale = PlayableIngressBuffer / len
            entryPoint[1] = entryPoint[1] + dirX * scale
            entryPoint[3] = entryPoint[3] + dirZ * scale
            entryPoint[2] = GetSurfaceHeight(entryPoint[1], entryPoint[3])
        end
        entryPoint = ClampToPlayableArea(entryPoint, area, PlayableIngressBuffer)
    end

    return entryPoint
end

local function NearestPlayablePointOnPath(startPos, path, area)
    if PositionInPlayableArea(startPos, area) then
        return SurfacePoint(startPos)
    end

    if not (path and table_getn(path) > 0) then
        return ClampToPlayableArea(startPos, area, PlayableIngressBuffer)
    end

    local previous = startPos
    for index, waypoint in ipairs(path) do
        if PositionInPlayableArea(waypoint, area) then
            -- Remove any waypoints that are still outside the playable area so we
            -- don't order the platoon to leave the map again after ingress.
            for _ = 1, index - 1 do
                table_remove(path, 1)
            end
            return SegmentPlayableIngress(previous, waypoint, area) or SurfacePoint(waypoint)
        end
        previous = waypoint
    end

    -- If no point on the path is inside, fall back to clamping the final
    -- waypoint and clear the path so that we only order the platoon to move to
    -- the entry point. The full path will be recalculated once the platoon is
    -- inside the playable area.
    local last = path[table_getn(path)]
    for i = table_getn(path), 1, -1 do
        path[i] = nil
    end
    return ClampToPlayableArea(last, area, PlayableIngressBuffer)
end

local function BrainEnemies(brain, targetArmy)
    if not brain then
        return {}
    end

    -- collect all enemy army indices
    local myIndex = brain:GetArmyIndex()
    local enemies = {}
    for idx, ab in ipairs(ArmyBrains) do
        -- skip invalid / destroyed brains and self
        if ab and idx ~= myIndex then
            local ok, isEnemy = pcall(IsEnemy, myIndex, idx)
            if ok and isEnemy then
                table_insert(enemies, idx)
            end
        end
    end

    -- if no filter requested, we're done
    if not targetArmy then
        return enemies
    end

    -- build allow-list that can match either indices or army nicknames
    local allow = {}
    if type(targetArmy) == 'table' then
        for _, entry in ipairs(targetArmy) do
            allow[entry] = true
        end
    else
        allow[targetArmy] = true
    end

    local filtered = {}
    for _, idx in ipairs(enemies) do
        local name = ArmyBrains[idx] and ArmyBrains[idx].Nickname
        if allow[idx] or (name and allow[name]) then
            table_insert(filtered, idx)
        end
    end

    -- fall back to all enemies if filter didn't match anything
    return (table_getn(filtered) > 0) and filtered or enemies
end


local function AreaUnits(brain, enemies, position, radius, category)
    if not position then return {} end
    local list = brain:GetUnitsAroundPoint(category, position, radius, 'Enemy') or {}
    if not enemies or table_getn(enemies) == 0 then
        return list
    end
    local allow = {}
    for _, enemy in ipairs(enemies) do
        allow[enemy] = true
    end
    local units = {}
    for _, unit in ipairs(list) do
        if unit and not unit.Dead then
            local ub = unit:GetAIBrain()
            local idx = nil
            local name = nil
            if ub then
                local ok, ai = pcall(ub.GetArmyIndex, ub)
                if ok and ai then
                    idx = ai
                end
                name = ub.Nickname
            end
            if (idx and allow[idx]) or (name and allow[name]) then
                table_insert(units, unit)
            end
        end
    end
    return units
end

local function CanTargetUnit(layer, submersible, unit)
    if not unit or unit.Dead then
        return false
    end

    if not submersible and EntityCategoryContains(SubmersibleCat, unit) then
        return false
    end

    if layer == 'Water' then
        return EntityCategoryContains(categories.NAVAL + NavalStructure, unit)
    elseif layer == 'Amphibious' then
        return true
    elseif layer == 'Air' then
        return true
    end

    -- default to land movement layer
    return not EntityCategoryContains(categories.NAVAL + NavalStructure, unit)
end

local function FilterUnits(units, layer, submersible)
    local out = {}
    for _, unit in ipairs(units) do
        if CanTargetUnit(layer, submersible, unit) then
            table_insert(out, unit)
        end
    end
    return out
end

local function ScoreStructureCluster(units, mode, distance)
    if table_getn(units) == 0 then
        return -math_huge
    end
    if mode == 'closest' then
        local dist = distance or 1
        return -dist
    elseif mode == 'value' then
        local score = 0
        for _, unit in ipairs(units) do
            local bp = unit:GetBlueprint()
            if bp and bp.Economy then
                score = score + (bp.Economy.BuildCostMass or 1) + (bp.Economy.BuildCostEnergy or 0) * 0.002
            else
                score = score + 1
            end
        end
        return score
    else
        return table_getn(units)
    end
end

local function SampleThreat(brain, position, threatType)
    if not brain or not position then
        return 0
    end
    local ok, value = pcall(brain.GetThreatAtPosition, brain, position, ThreatSampleRing, true, threatType or 'AntiSurface')
    if ok and value then
        return value
    end
    return 0
end

local function FindThreatLocations(brain, startPos, layer)
    local results = {}
    local ok, threats = pcall(brain.GetThreatsAroundPoint, brain, startPos, 16, true, 'Economy')
    if not (ok and threats) then
        return results
    end
    for _, entry in ipairs(threats) do
        local threat = entry[3] or entry[1]
        local x = entry[1]
        local z = entry[2]
        if type(entry[1]) ~= 'number' or type(entry[2]) ~= 'number' then
            x = entry[2]
            z = entry[3]
            threat = entry[1]
        end
        if threat and threat > 0 and type(x) == 'number' and type(z) == 'number' then
            local pos = { x, GetSurfaceHeight(x, z), z }
            table_insert(results, { pos = pos, threat = threat })
        end
    end
    return results
end

local function FloodFillLocations(brain, startPos)
    local visited = {}
    local queue = { startPos }
    local results = {}
    local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize) or { 512, 512 }
    local function key(pos)
        return string.format('%d:%d', math_floor(pos[1] / FloodFillCell), math_floor(pos[3] / FloodFillCell))
    end

    while table_getn(queue) > 0 do
        local pos = table_remove(queue, 1)
        local k = key(pos)
        if not visited[k] then
            visited[k] = true
            table_insert(results, { pos = pos })
            if Distance(startPos, pos) < FloodFillMaxRadius then
                local offsets = {
                    { FloodFillCell, 0, 0 },
                    { -FloodFillCell, 0, 0 },
                    { 0, 0, FloodFillCell },
                    { 0, 0, -FloodFillCell },
                }
                for _, off in ipairs(offsets) do
                    local nextPos = VectorAdd(pos, off)
                    nextPos[1] = math_min(math_max(nextPos[1], 0), size[1])
                    nextPos[3] = math_min(math_max(nextPos[3], 0), size[2])
                    nextPos[2] = GetSurfaceHeight(nextPos[1], nextPos[3])
                    table_insert(queue, nextPos)
                end
            end
        end
    end

    return results
end

local function CollectCandidateAreas(brain, startPos, opts, layer)
    if not startPos then
        return {}
    end
    if opts.IntelOnly then
        return FindThreatLocations(brain, startPos, layer)
    else
        return FloodFillLocations(brain, startPos)
    end
end

local function DefenseThreatNear(brain, position, layer)
    if not position then return 0 end
    local threatType = (layer == 'Air') and 'AntiAir' or 'AntiSurface'
    return SampleThreat(brain, position, threatType)
end

local function LeastDefendedStructures(brain, layer, structures)
    if not (brain and layer and structures) then
        return {}
    end

    local scored = {}
    local minThreat = math_huge

    for _, structure in ipairs(structures) do
        if structure and not structure.Dead then
            local pos = structure:GetPosition()
            if pos then
                local threat = DefenseThreatNear(brain, pos, layer)
                threat = tonumber(threat) or 0
                minThreat = math_min(minThreat, threat)
                table_insert(scored, { unit = structure, threat = threat })
            end
        end
    end

    if table_getn(scored) == 0 then
        return {}
    end

    table.sort(scored, function(a, b)
        if math_abs(a.threat - b.threat) < 0.001 then
            return (a.unit.EntityId or 0) < (b.unit.EntityId or 0)
        end
        return a.threat < b.threat
    end)

    local threshold = minThreat + 0.1
    local selected = {}
    for _, entry in ipairs(scored) do
        if entry.threat <= threshold then
            table_insert(selected, entry.unit)
        else
            break
        end
    end

    if table_getn(selected) == 0 then
        table_insert(selected, scored[1].unit)
    end

    return selected
end

local function AdjustForAvoidance(brain, candidates, layer)
    if not candidates then return candidates end
    for _, c in ipairs(candidates) do
        c.threat = (c.threat or 0) + DefenseThreatNear(brain, c.pos, layer)
    end
    table.sort(candidates, function(a, b)
        local ta = a.threat or 0
        local tb = b.threat or 0
        if math_abs(ta - tb) < 0.001 then
            return (a.pos[1] + a.pos[3]) < (b.pos[1] + b.pos[3])
        end
        return ta < tb
    end)
    return candidates
end

local function ChooseBestArea(brain, platoon, opts, layer, areaRadius, mode, category)
    local startPos = GetPlatoonPosition(platoon)
    if not startPos then return nil end

    local candidates = CollectCandidateAreas(brain, startPos, opts, layer)
    if opts.AvoidDef then
        AdjustForAvoidance(brain, candidates, layer)
    end

    local enemies = BrainEnemies(brain, opts.TargetArmy)
    local bestScore = -1e9
    local best = nil

    for _, entry in ipairs(candidates) do
        local pos = entry.pos
        if pos then
            local units = AreaUnits(brain, enemies, pos, areaRadius, category)
            units = FilterUnits(units, layer, opts.Submersible)
            if table_getn(units) > 0 then
                local distance = Distance(startPos, pos)
                local score = ScoreStructureCluster(units, mode, distance)
                if opts.AvoidDef then
                    score = score / (1 + DefenseThreatNear(brain, pos, layer) * AvoidThreatMultiplier)
                end
                if score > bestScore then
                    bestScore = score
                    best = {
                        position = pos,
                        units    = units,
                        score    = score,
                        radius   = areaRadius,
                    }
                end
            end
        end
    end

    return best
end

local function FindRaidTarget(brain, platoon, opts, layer)
    local startPos = GetPlatoonPosition(platoon)
    if not startPos then return nil end

    local priority = { opts.Category or 'ECO', 'ECO', 'BLD', 'INT', 'DEF' }
    local considered = {}
    local enemies = BrainEnemies(brain, opts.TargetArmy)

    for _, id in ipairs(priority) do
        if not considered[id] then
            considered[id] = true
            if id == 'SMT' then
                local candidates = CollectCandidateAreas(brain, startPos, opts, layer)
                if opts.AvoidDef then
                    AdjustForAvoidance(brain, candidates, layer)
                end
                local bestScore = -1
                local best
                local labels = { 'ECO', 'BLD', 'INT', 'DEF' }
                for _, entry in ipairs(candidates) do
                    local pos = entry.pos
                    if pos then
                        local threat = DefenseThreatNear(brain, pos, layer)
                        local localBestScore = -1
                        local localBestCategory = nil
                        local localUnits = nil
                        for _, label in ipairs(labels) do
                            local cat = RaidCategories[label]
                            local units = AreaUnits(brain, enemies, pos, RaidAreaRadius, cat)
                            units = FilterUnits(units, layer, opts.Submersible)
                            local count = table_getn(units)
                            if count > 0 then
                                local score = count / math_max(1, threat + 1)
                                if score > localBestScore then
                                    localBestScore = score
                                    localBestCategory = cat
                                    localUnits = units
                                end
                            end
                        end
                        if localBestCategory and localBestScore > bestScore then
                            bestScore = localBestScore
                            local selected = LeastDefendedStructures(brain, layer, localUnits)
                            if table_getn(selected) > 0 then
                                best = {
                                    position            = pos,
                                    units               = selected,
                                    radius              = RaidAreaRadius,
                                    category            = localBestCategory,
                                    restrictStructures  = true,
                                    finalAggressiveMove = false,
                                }
                            end
                        end
                    end
                end
                if best then
                    return best
                end
            else
                local category = RaidCategories[id]
                if category then
                    local candidates = CollectCandidateAreas(brain, startPos, opts, layer)
                    if opts.AvoidDef then
                        AdjustForAvoidance(brain, candidates, layer)
                    end
                    local bestScore = -1
                    local best
                    for _, entry in ipairs(candidates) do
                        local pos = entry.pos
                        if pos then
                            local units = AreaUnits(brain, enemies, pos, RaidAreaRadius, category)
                            units = FilterUnits(units, layer, opts.Submersible)
                            if table_getn(units) > 0 then
                                local threatPenalty = opts.AvoidDef and (1 + DefenseThreatNear(brain, pos, layer) * AvoidThreatMultiplier) or 1
                                local score = table_getn(units) / threatPenalty
                                if score > bestScore then
                                    bestScore = score
                                    local selected = LeastDefendedStructures(brain, layer, units)
                                    if table_getn(selected) > 0 then
                                        best = {
                                            position            = pos,
                                            units               = selected,
                                            radius              = RaidAreaRadius,
                                            category            = category,
                                            restrictStructures  = true,
                                            finalAggressiveMove = false,
                                        }
                                    end
                                end
                            end
                        end
                    end
                    if best then
                        return best
                    end
                end
            end
        end
    end

    return nil
end

local function AmphibiousSurfaceHeight(layer, x, z)
    if layer == 'Water' then
        return GetSurfaceHeight(x, z)
    end
    return GetTerrainHeight(x, z)
end

local function CanPathTo(platoon, layer, destination)
    local startPos = GetPlatoonPosition(platoon)
    if not (startPos and destination) then
        return false
    end
    local ok, can = pcall(NavUtils.CanPathTo, layer, startPos, destination)
    if not ok then
        return false
    end
    return can
end

local function AppendDestination(path, destination)
    path = path or {}
    if not destination then return path end
    local function close(a, b) return DistanceSq(a, b) < 4 end -- ~2 units
    if table.getn(path) == 0 then
        table_insert(path, CopyVector(destination))
        return path
    end
    local last = path[table_getn(path)]
    if not close(last, destination) then
        table_insert(path, CopyVector(destination))
    end
    return path
end

local function FindSafePath(platoon, layer, destination)
    local startPos = GetPlatoonPosition(platoon)
    if not (startPos and destination) then return nil end

    local ok, path = pcall(NavUtils.PathTo, layer, startPos, destination)
    if ok and path then
        return AppendDestination(path, destination)
    end
    return { CopyVector(destination) }
end

local function RequestTransports(brain, platoon, destination)
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then
        return false
    end

    local ok, transports = pcall(ScenarioFramework.UseTransports, units, brain, destination)
    if ok and transports then
        return true
    end

    return false
end

local function MoveAlongPath(platoon, path, formation)
    if not (path and table_getn(path) > 0) then return end

    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then return end

    if formation ~= 'NoFormation' then
        platoon:SetPlatoonFormationOverride(formation)
    else
        platoon:SetPlatoonFormationOverride('NoFormation')
    end

    IssueClearCommands(units)

    if formation == 'NoFormation' then
        for _, waypoint in ipairs(path) do
            IssueMove(units, waypoint)
        end
    else
        for _, waypoint in ipairs(path) do
            IssueFormMove(units, waypoint, formation, 0)
        end
    end
end

local function WaitForPlayableIngress(platoon, area, timeout)
    area = area or GetPlayableArea()
    if not area then
        return true
    end

    local elapsed = 0
    while PlatoonAlive(platoon) do
        SafeWait(1)
        elapsed = elapsed + 1

        local pos = GetPlatoonPosition(platoon)
        if pos and PositionInPlayableArea(pos, area) then
            return true
        end

        if timeout and elapsed >= timeout then
            break
        end
    end

    return false
end

local function TransportAndMove(platoon, destination, opts)
    local brain = platoon:GetBrain()
    if not brain then return false end
    if not opts.Transport then
        return false
    end

    local startPos = GetPlatoonPosition(platoon)
    if not startPos then return false end

    local drop = CopyVector(destination)
    if drop then
        local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize) or { 512, 512 }
        drop[1] = math_min(math_max(drop[1] - TransportStagingOffset, 0), size[1])
        drop[3] = math_min(math_max(drop[3] - TransportStagingOffset, 0), size[2])
    else
        drop = startPos
    end

    local loaded = RequestTransports(brain, platoon, drop)
    if loaded then
        SafeWait(1)
        return true
    end

    return false
end

local function AttackTargetArea(platoon, target, opts)
    local brain = platoon:GetBrain()
    if not brain or not target or not target.position then
        return 'fail'
    end

    local layer = DetermineLayer(platoon, opts.Amphibious)
    local area = GetPlayableArea()
    local startPos = GetPlatoonPosition(platoon)
    if not startPos then
        return 'fail'
    end

    local startedOutside = area and not PositionInPlayableArea(startPos, area)

    local path = FindSafePath(platoon, layer, target.position)
    local needsIngressRepath = false
    if startedOutside then
        local ingress = NearestPlayablePointOnPath(startPos, path, area)
        if ingress then
            if not (path and table_getn(path) > 0) then
                needsIngressRepath = true
            end
            path = PrependWaypoint(path, ingress)
        end
    end

    if not CanPathTo(platoon, layer, target.position) then
        if opts.Transport then
            if not TransportAndMove(platoon, target.position, opts) then
                return 'fail'
            end
        else
            return 'fail'
        end
    end

    MoveAlongPath(platoon, path, opts.Formation)

    if startedOutside then
        if not WaitForPlayableIngress(platoon, area, PlayableIngressTimeout * 2) then
            return 'fail'
        end

        local insidePos = GetPlatoonPosition(platoon)
        if insidePos then
            local newPath = FindSafePath(platoon, layer, target.position)
            MoveAlongPath(platoon, newPath, opts.Formation)
        end
    end

    local arrived = false
    local epsilon = 5
    local units = platoon:GetPlatoonUnits() or {}
    local elapsed = 0
    while PlatoonAlive(platoon) do
        local pos = GetPlatoonPosition(platoon)
        if not pos then break end
        if DistanceSq(pos, target.position) < ((target.radius + epsilon) * (target.radius + epsilon)) then
            arrived = true
            break
        end
        SafeWait(1)
        elapsed = elapsed + 1
        if elapsed >= RecheckDelay then
            return 'repath'
        end
    end

    if not arrived then
        return 'fail'
    end

    units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then
        return 'fail'
    end

    IssueClearCommands(units)
    local finalAggressive = target and target.finalAggressiveMove
    if finalAggressive == nil then
        finalAggressive = true
    end
    if finalAggressive then
        IssueAggressiveMove(units, target.position)
    else
        IssueMove(units, target.position)
    end

    local issuedTargets = {}
    local enemyBrains = BrainEnemies(brain, opts.TargetArmy)
    local function UpdateStructureAttacks()
        units = platoon:GetPlatoonUnits() or {}
        if table_getn(units) == 0 then
            return 'fail'
        end

        local category = target.category or StructureCategory
        local combined = {}
        if target.units then
            for _, structure in ipairs(target.units) do
                table_insert(combined, structure)
            end
        end

        local restrictStructures = target and target.restrictStructures
        if not restrictStructures then
            local radius = (target.radius or 0) + AreaClearRadius
            local areaUnits = AreaUnits(brain, enemyBrains, target.position, radius, category) or {}
            for _, structure in ipairs(areaUnits) do
                table_insert(combined, structure)
            end
        end

        combined = FilterUnits(combined, layer, opts.Submersible)

        local unique = {}
        local remaining = {}
        for _, structure in ipairs(combined) do
            if structure and not structure.Dead then
                local id = structure.EntityId
                if id and not unique[id] then
                    unique[id] = true
                    table_insert(remaining, structure)
                end
            end
        end

        if table_getn(remaining) == 0 then
            return 'success'
        end

        local newTargets = {}
        for _, structure in ipairs(remaining) do
            local id = structure.EntityId
            if id and not issuedTargets[id] then
                issuedTargets[id] = true
                table_insert(newTargets, structure)
            end
        end

        if table_getn(newTargets) > 0 then
            for _, structure in ipairs(newTargets) do
                if structure and not structure.Dead then
                    IssueAttack(units, structure)
                end
            end
        end

        return 'continue'
    end

    local attackState = UpdateStructureAttacks()
    if attackState == 'fail' then
        return 'fail'
    end

    while PlatoonAlive(platoon) and attackState ~= 'success' do
        SafeWait(3)
        attackState = UpdateStructureAttacks()
        if attackState == 'fail' then
            return 'fail'
        end
    end

    return 'success'
end

local function WaitForTargets(brain, delay)
    SafeWait(delay or RecheckDelay)
end

local function AttackLoop(platoon, resolver, opts)
    local brain = platoon:GetBrain()
    if not brain then return end
    local layer = DetermineLayer(platoon, opts.Amphibious)

    local currentTarget = nil

    while PlatoonAlive(platoon) do
        if not currentTarget then
            currentTarget = resolver(brain, platoon, opts, layer)
            if not currentTarget then
                WaitForTargets(brain, RecheckDelay)
            end
        end

        if currentTarget then
            local result = AttackTargetArea(platoon, currentTarget, opts)
            if result == 'success' then
                currentTarget = nil
                SafeWait(1)
            elseif result == 'repath' then
                local newTarget = resolver(brain, platoon, opts, layer)
                if newTarget then
                    currentTarget = newTarget
                else
                    currentTarget = nil
                    WaitForTargets(brain, RecheckDelay)
                end
            else
                currentTarget = nil
                SafeWait(RecheckDelay)
            end
        end
    end
end

local function RandomPoint()
    if not ScenarioInfo then
        return { 0, 0, 0 }
    end
    local size = ScenarioInfo.size or ScenarioInfo.MapSize or { 512, 512 }
    local x = math_random(0, size[1])
    local z = math_random(0, size[2])
    local y = GetSurfaceHeight(x, z)
    return { x, y, z }
end

local function HottestColdestPosition(brain, hottest)
    if not ScenarioInfo then
        return RandomPoint()
    end
    local size = ScenarioInfo.size or ScenarioInfo.MapSize or { 512, 512 }
    local start = { size[1] * 0.5, 0, size[2] * 0.5 }
    start[2] = GetSurfaceHeight(start[1], start[3])
    local list = FindThreatLocations(brain, start, 'Air')
    if table_getn(list) == 0 then
        return RandomPoint()
    end
    table.sort(list, function(a, b)
        if hottest then
            return (a.threat or 0) > (b.threat or 0)
        else
            return (a.threat or 0) < (b.threat or 0)
        end
    end)
    return CopyVector(list[1].pos)
end

local function SelectScoutDestination(brain, opts)
    local roll = math_random()
    if opts.IntelOnly and roll < HotColdChance then
        return HottestColdestPosition(brain, true)
    elseif opts.IntelOnly and roll < HotColdChance * 2 then
        return HottestColdestPosition(brain, false)
    else
        return RandomPoint()
    end
end

local function AssignScoutOrder(unit, destination)
    if not unit or unit.Dead then return end
    IssueClearCommands({ unit })
    IssueMove({ unit }, destination)
end

local function OrbitUnit(unit, center)
    if not unit or unit.Dead then return end
    local points = 6
    local radius = 30
    for i = 1, points do
        local angle = (i / points) * 6.28318
        local x = center[1] + math_cos(angle) * radius
        local z = center[3] + math_sin(angle) * radius
        local y = GetSurfaceHeight(x, z)
        IssueMove({ unit }, { x, y, z })
    end
end

function WaveAttack(platoon, data)
    local opts = CopyOptions(data)
    opts.Type = opts.Type or opts.TargetType or 'closest'
    local function resolver(brain, p, o, layer)
        return ChooseBestArea(brain, p, o, layer, WaveAreaRadius, opts.Type, StructureCategory)
    end
    AttackLoop(platoon, resolver, opts)
end

function RaidAttack(platoon, data)
    local opts = CopyOptions(data)
    opts.Category = opts.Category or opts.TargetType or 'ECO'
    local function resolver(brain, p, o, layer)
        return FindRaidTarget(brain, p, o, layer)
    end
    AttackLoop(platoon, resolver, opts)
end

function ScoutAttack(platoon, data)
    local opts = CopyOptions(data)
    local brain = platoon:GetBrain()
    if not brain then return end
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then return end

    local state = {}
    for _, unit in ipairs(units) do
        state[unit.EntityId] = { destination = SelectScoutDestination(brain, opts), orbiting = false, orbitTime = 0 }
        AssignScoutOrder(unit, state[unit.EntityId].destination)
    end

    while PlatoonAlive(platoon) do
        SafeWait(RecheckDelay)
        units = platoon:GetPlatoonUnits() or {}
        if table_getn(units) == 0 then break end
        for _, unit in ipairs(units) do
            if unit and not unit.Dead then
                local info = state[unit.EntityId]
                if not info then
                    info = { destination = SelectScoutDestination(brain, opts), orbiting = false, orbitTime = 0 }
                    state[unit.EntityId] = info
                    AssignScoutOrder(unit, info.destination)
                end
                if info.orbiting then
                    info.orbitTime = info.orbitTime - RecheckDelay
                    if info.orbitTime <= 0 then
                        info.orbiting = false
                        info.destination = SelectScoutDestination(brain, opts)
                        AssignScoutOrder(unit, info.destination)
                    end
                end
                local pos = unit:GetPosition()
                local dest = info.destination
                if dest and pos and DistanceSq(pos, dest) < 400 then
                    if not info.orbiting and math_random() < OrbitChance then
                        info.orbiting = true
                        info.orbitTime = math_random(10, MaxScoutOrbitTime)
                        OrbitUnit(unit, dest)
                    elseif not info.orbiting then
                        info.destination = SelectScoutDestination(brain, opts)
                        AssignScoutOrder(unit, info.destination)
                    end
                end
            end
        end
    end
end

return {
    WaveAttack = WaveAttack,
    RaidAttack = RaidAttack,
    ScoutAttack = ScoutAttack,
}