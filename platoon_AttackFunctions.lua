--[[
================================================================================
Platoon Attack Functions -- Created by Cavthena
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

    -- Hunt attack -------------------------------------------------------------
    function AssassinateExperimentals(platoon)
        local data = {
            TargetCategories = { categories.AIR },
            Blueprints  = { 'uel0401', 'xrl0403', 'xsl0401', 'ual0401' },
            Marker      = 'Base_Staging_A',
            IntelOnly   = true,
            Vulnerable  = true,
            Formation   = 'GrowthFormation',
        }
        AttackFns.HuntAttack(platoon, data)
    end

    -- Defense patrol ---------------------------------------------------------
    function GuardApproaches(platoon)
        local data = {
            BaseMarker     = 'Main_Base_Marker', -- marker or position to defend
            VectorMargin   = 12,                 -- bucket size for approach angles (degrees)
            PatrolWidth    = 80,                 -- width of the patrol arc (degrees)
            PatrolDistance = 100,                -- distance from base for patrol points
            Formation      = 'GrowthFormation',
        }
        AttackFns.DefensePatrol(platoon, data)
    end

    -- Area patrol ------------------------------------------------------------
    function PatrolChain(platoon)
        local data = {
            Chain      = 'Patrol_Chain_1',
            Continuous = false,
            Formation  = 'GrowthFormation',
        }
        AttackFns.AreaPatrol(platoon, data)
    end

    -- Firebase ----------------------------------------------------------------
    function BuildFirebases(platoon)
        local data = {
            Locations = {
                { marker = 'Firebase_A', group = 'Firebase_A_Structs' },
                { marker = 'Firebase_B', group = 'Firebase_B_Structs' },
            },
            WaitMarker  = 'Firebase_Wait',
            SafeRadius  = 40,
            Formation   = 'GrowthFormation',
        }
        AttackFns.Firebase(platoon, data)
    end

    -- Support base ------------------------------------------------------------
    function ReinforceBase(platoon)
        local data = {
            BaseTags   = { 'UEF_Main', 'UEF_Forward' },
            WaitMarker = 'Engineer_Wait',
            Formation  = 'GrowthFormation',
        }
        AttackFns.Supportbase(platoon, data)
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
        Bombard (boolean, default = false)
            When true, the platoon halts at its longest weapon range and
            attacks from distance instead of pushing into direct fire.
        RandomizeRoute (boolean, default = true)
            Has a 25% chance to choose a wide flanking route instead of the
            shortest path.

RaidAttack specifics
        Category (string, default = 'ECO')
            Requested structure category: 'ECO', 'BLD', 'INT', 'DEF', or 'SMT'.
            Areas are 25 units wide.  The priority chain is always
            Requested > ECO > BLD > INT > DEF.
        RandomizeRoute (boolean, default = true)
            Has a 25% chance to choose a wide flanking route instead of the
            shortest path.

ScoutAttack specifics
        Designed for AIR platoons.  Each unit continuously receives move
        targets and immediately selects a new destination after arriving.
        Destinations are random map positions with a 25% chance of being the
        hottest or coolest area on the threat map.

AreaPatrol specifics
        Patrols along a marker chain specified by `Chain`/`ChainName`. When
        `Continuous` is true the platoon loops from the first marker to the
        last and back to the first. When false, the patrol bounces back and
        forth from the last marker to the first.

Firebase specifics
        Engineer-only behavior that visits a list of location markers and
        associated structure groups. If the location is safe (no enemy units
        within `SafeRadius`), the platoon builds any missing structures from
        the group before proceeding to the next location. Locations with all
        structures already built are skipped. If no locations are available,
        the platoon waits at `WaitMarker`.

Supportbase specifics
        Engineer-only behavior that assigns the platoon to the first base tag
        without factories and without engineers, using
        `manager_BaseEngineer.AssignEngineerUnit`. If every base has factories
        and engineers, the platoon waits at `WaitMarker`.

HuntAttack specifics
        Accepts `Blueprint`, `Blueprints`, `TargetBP`, or `TargetBlueprints`
        containing a single id or list of blueprint ids to pursue.  Category
        targeting is available through `Category`, `Categories`,
        `TargetCategory`, or `TargetCategories`.  The platoon locks on to the
        closest matching unit, travelling through safe paths and refusing to
        switch targets until the victim is destroyed or intel contact is lost.
        When `IntelOnly` is true the target must be scouted or have an existing
        blip.  Setting `Vulnerable` forces the platoon to avoid defended
        targets, waiting for them to leave the threat ring or switching if
        another safe target exists.  If no targets are available, the platoon
        idles at `Marker`/`IdleMarker` (air platoons orbit).

DefensePatrol specifics
        The platoon defends the specified base marker/position by patrolling a
        perimeter at `PatrolDistance`.  When enemy units enter
        `InterceptDistance` of the base, the platoon moves to intercept before
        resuming the perimeter loop.
================================================================================
]]

local ScenarioFramework = import('/lua/ScenarioFramework.lua')
local ScenarioUtils     = import('/lua/sim/ScenarioUtilities.lua')
local NavUtils          = import('/lua/sim/NavUtils.lua')

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
local GetTerrainHeight  = GetTerrainHeight
local GetSurfaceHeight  = GetSurfaceHeight
local table_getn    = table.getn
local table_insert  = table.insert
local table_remove  = table.remove
local math_sqrt     = math.sqrt
local math_abs      = math.abs
local math_min      = math.min
local math_max      = math.max
local math_floor    = math.floor
local math_atan2    = math.atan2 or math.atan
local math_random   = math.random
local math_cos      = math.cos
local math_sin      = math.sin
local math_pi       = math.pi
local math_huge     = math.huge or 1e9
local math_mod      = math.mod or math.fmod

local RecheckDelay            = 60
local ScoutRecheckDelay       = 1
local TravelStuckSeconds      = 12
local TravelProgressEpsilonSq = 25
local WaveAreaRadius          = 50
local RaidAreaRadius          = 25
local AreaClearRadius         = 35
local TransportStagingOffset  = 28
local HotColdChance           = 0.25
local FloodFillCell           = 32
local FloodFillMaxRadius      = 512
local ThreatSampleRing        = 48
local AvoidThreatMultiplier   = 1.5
local PlayableIngressTimeout  = 60
local PlayableIngressBuffer   = 10
local HuntRepathDistanceSq    = 400
local HuntAttackDistanceSq    = 2500
local HuntDefenseWait         = 5
local HuntRecheckInterval     = 1
local HuntOrbitPoints         = 8
local HuntOrbitRadius         = 32
local DefaultPatrolDistance   = 80
local DefaultInterceptDistance = 120
local RouteClearanceOffset    = 6
local RouteFlankChance        = 0.25
local RouteAlternateAttempts  = 3
local RouteAlternateAttempts  = 3
local RouteDetourMin          = 48
local RouteDetourMax          = 192
local CorridorNearDistance     = 180
local CorridorDesiredClearance = 14
local CorridorProbeMax         = 40
local CorridorProbeStep        = 2
local CorridorMaxShiftPerPass  = 6
local CorridorPasses           = 2
local CorridorDirections       = 8
local CorridorSimplifyAngle    = 6
local SegmentDirectMinDistance = 10
local SegmentDirectMaxRatio    = 1.2
local FirebaseSafeRadius       = 40
local FirebaseStructureRadius  = 4

local ClampPathToPlayableArea

local StructureCategory = categories.STRUCTURE - categories.WALL
local NavalStructure    = categories.STRUCTURE * categories.NAVAL
local LandStructure     = categories.STRUCTURE - categories.NAVAL
local SubmersibleCat    = categories.SUBMERSIBLE

local RaidCategories = {
    ECO = (categories.MASSEXTRACTION + categories.MASSPRODUCTION + categories.ENERGYPRODUCTION + categories.HYDROCARBON + categories.MASSSTORAGE + categories.ENERGYSTORAGE) - categories.COMMAND,
    BLD = (categories.FACTORY + categories.ENGINEER + (categories.STRUCTURE * categories.ENGINEERSTATION)) - categories.COMMAND,
    INT = (categories.RADAR + categories.SONAR) - categories.COMMAND,
    DEF = (categories.DEFENSE + categories.ANTIMISSILE + categories.SHIELD) - categories.COMMAND,
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

local function SafeGetBrain(platoon)
    if not platoon then
        return nil
    end

    if platoon.BeenDestroyed and platoon:BeenDestroyed() then
        return nil
    end

    local ok, brain = pcall(platoon.GetBrain, platoon)
    if not ok then
        return nil
    end

    return brain
end

local function PlatoonAlive(platoon)
    if not platoon then return false end
    local brain = SafeGetBrain(platoon)
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
    opts.RandomizeRoute = opts.RandomizeRoute and true or false
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

    local entryPoint = ClampToPlayableArea(startPos, area, PlayableIngressBuffer)

    if path and table_getn(path) > 0 then
        -- Remove any waypoints that are still outside the playable area so we
        -- don't order the platoon to leave the map again after ingress.
        local firstInside = nil
        for index, waypoint in ipairs(path) do
            if PositionInPlayableArea(waypoint, area) then
                firstInside = index
                break
            end
        end

        if firstInside then
            for _ = 1, firstInside - 1 do
                table_remove(path, 1)
            end
        else
            for i = table_getn(path), 1, -1 do
                path[i] = nil
            end
        end
    end

    return entryPoint
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


local function AreaUnits(brain, enemies, position, radius, category, intelOnly)
    if not position then return {} end
    radius = radius or 1

    -- Intel path: current behaviour (uses fog-of-war)
    if intelOnly then
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
                local idx, name = nil, nil
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

    -- Non-intel path: build our own "threat map" from enemy brains, ignoring fog-of-war
    local units = {}
    local r2 = radius * radius
    enemies = enemies or BrainEnemies(brain, nil)

    for _, enemyIndex in ipairs(enemies) do
        local eBrain = ArmyBrains[enemyIndex]
        if eBrain then
            -- This returns all units owned by that brain, regardless of our intel
            local list = eBrain:GetListOfUnits(category or categories.ALLUNITS, false) or {}
            for _, unit in ipairs(list) do
                if unit and not unit.Dead then
                    local pos = unit:GetPosition()
                    if pos then
                        local dx = pos[1] - position[1]
                        local dz = pos[3] - position[3]
                        if dx * dx + dz * dz <= r2 then
                            table_insert(units, unit)
                        end
                    end
                end
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

local function CollectAdjustedCandidates(brain, startPos, opts, layer)
    local candidates = CollectCandidateAreas(brain, startPos, opts, layer)
    if opts.AvoidDef then
        AdjustForAvoidance(brain, candidates, layer)
    end
    return candidates
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

local function ChooseBestArea(brain, platoon, opts, layer, areaRadius, mode, category)
    local startPos = GetPlatoonPosition(platoon)
    if not startPos then return nil end

    local candidates = CollectAdjustedCandidates(brain, startPos, opts, layer)

    local enemies = BrainEnemies(brain, opts.TargetArmy)
    local bestScore = -1e9
    local best = nil

    for _, entry in ipairs(candidates) do
        local pos = entry.pos
        if pos then
            local units = AreaUnits(brain, enemies, pos, areaRadius, category, opts.IntelOnly)
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
                local candidates = CollectAdjustedCandidates(brain, startPos, opts, layer)
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
                            local units = AreaUnits(brain, enemies, pos, RaidAreaRadius, cat, opts.IntelOnly)
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
                                -- Move towards the least-defended structure instead of the area center
                                local targetPos = pos
                                if selected[1] and not selected[1].Dead then
                                    targetPos = selected[1]:GetPosition()
                                end

                                best = {
                                    position            = targetPos,
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
                    local candidates = CollectAdjustedCandidates(brain, startPos, opts, layer)

                    local best
                    local bestThreat   = math_huge   -- lowest local defence wins
                    local bestDistance = math_huge   -- tie-breaker: closer is better
                    local bestCount    = -1          -- secondary tie-breaker: more eco in that area

                    for _, entry in ipairs(candidates) do
                        local pos = entry.pos
                        if pos then
                            local units = AreaUnits(brain, enemies, pos, RaidAreaRadius, category, opts.IntelOnly)
                            units = FilterUnits(units, layer, opts.Submersible)
                            local count = table_getn(units)
                            if count > 0 then
                                -- Find the least defended structure *in this area*
                                local selected = LeastDefendedStructures(brain, layer, units)
                                if table_getn(selected) > 0 then
                                    local structure = selected[1]
                                    if structure and not structure.Dead then
                                        local sPos        = structure:GetPosition()
                                        local localThreat = DefenseThreatNear(brain, sPos, layer)
                                        local distance    = Distance(startPos, sPos)

                                        -- Compare by threat, then by distance, then by how much eco is nearby
                                        local better =
                                            (localThreat < bestThreat - 0.001) or
                                            (math_abs(localThreat - bestThreat) < 0.001 and distance < bestDistance - 0.1) or
                                            (math_abs(localThreat - bestThreat) < 0.001 and math_abs(distance - bestDistance) < 0.1 and count > bestCount)

                                        if better then
                                            bestThreat   = localThreat
                                            bestDistance = distance
                                            bestCount    = count

                                            best = {
                                                position            = sPos,
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

local function CanPathBetween(layer, a, b)
    if not (a and b) then
        return false
    end
    local ok, can = pcall(NavUtils.CanPathTo, layer, a, b)
    return ok and can
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

local function BuildPathSegment(layer, startPos, destination)
    local ok, path = pcall(NavUtils.PathTo, layer, startPos, destination)
    if ok and path then
        return AppendDestination(path, destination)
    end
    return nil
end

local function PathLength(path)
    if not (path and table_getn(path) >= 2) then
        return 0
    end
    local total = 0
    for i = 2, table_getn(path) do
        local a = path[i - 1]
        local b = path[i]
        if a and b then
            total = total + Distance(a, b)
        end
    end
    return total
end

local function IsDirectPathSegment(layer, a, b)
    if not (a and b) then
        return false
    end

    local straight = Distance(a, b)
    if straight <= SegmentDirectMinDistance then
        return CanPathBetween(layer, a, b)
    end

    local path = BuildPathSegment(layer, a, b)
    if not path then
        return false
    end

    local navLength = PathLength(path)
    if navLength <= 0 then
        return false
    end

    return (navLength / straight) <= SegmentDirectMaxRatio
end

local function HeadingDegrees(a, b)
    if not (a and b) then
        return 0
    end
    local dx = b[1] - a[1]
    local dz = b[3] - a[3]
    if dx == 0 and dz == 0 then
        return 0
    end
    return math_atan2(dz, dx) * 180 / math_pi
end

local function AngleDifferenceDegrees(a, b)
    local diff = math_abs(NormalizeDegrees(a) - NormalizeDegrees(b))
    if diff > 180 then
        diff = 360 - diff
    end
    return diff
end

local function FinalApproachHeading(path, startPos, destination)
    if not destination then
        return nil
    end
    local prev = startPos
    if path and table_getn(path) >= 2 then
        prev = path[table_getn(path) - 1]
        destination = path[table_getn(path)] or destination
    end
    if not prev then
        return nil
    end
    return HeadingDegrees(prev, destination)
end

local function RandomDetourPoint(layer, startPos, destination)
    local dx = destination[1] - startPos[1]
    local dz = destination[3] - startPos[3]
    local baseAngle = math_atan2(dz, dx)
    local offset = (0.35 + math_random() * 0.45) * math_pi
    if math_random() < 0.5 then
        offset = -offset
    end

    local distance = Distance(startPos, destination)
    local detourDist = math_min(math_max(distance * 0.4, RouteDetourMin), RouteDetourMax)
    local angle = baseAngle + offset

    local x = startPos[1] + math_cos(angle) * detourDist
    local z = startPos[3] + math_sin(angle) * detourDist

    local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize) or { 512, 512 }
    x = math_min(math_max(x, 0), size[1])
    z = math_min(math_max(z, 0), size[2])

    return { x, AmphibiousSurfaceHeight(layer, x, z), z }
end

local function PathThreatScore(brain, layer, path)
    if not (brain and path) then
        return 0
    end
    local maxThreat = 0
    for _, waypoint in ipairs(path) do
        maxThreat = math_max(maxThreat, DefenseThreatNear(brain, waypoint, layer))
    end
    return maxThreat
end

local function MergePathSegments(segments)
    local merged = {}
    if not segments then
        return merged
    end

    for _, segment in ipairs(segments) do
        if segment then
            for _, waypoint in ipairs(segment) do
                if waypoint then
                    local last = merged[table_getn(merged)]
                    if not (last and DistanceSq(last, waypoint) < 1) then
                        table_insert(merged, CopyVector(waypoint))
                    end
                end
            end
        end
    end

    return merged
end

local function TryAlternatePath(platoon, layer, startPos, destination, opts)
    if not (opts and opts.RandomizeRoute) or opts._repathing then
        return nil
    end
    if math_random() >= RouteFlankChance then
        return nil
    end

    local brain = platoon:GetBrain()
    local baseline = BuildPathSegment(layer, startPos, destination)
    if not baseline then
        return nil
    end

    local baselineLength = PathLength(baseline)
    local baselineHeading = FinalApproachHeading(baseline, startPos, destination)
    if baselineLength <= 0 or not baselineHeading then
        return nil
    end

    local baseAngle = math_atan2(startPos[3] - destination[3], startPos[1] - destination[1])
    local bestPath = nil
    local bestThreat = math_huge
    local bestAngleDiff = 0
    local bestLengthRatio = 0

    for _ = 1, RouteAlternateAttempts do
        local offsetDeg = 90 + math_random() * 50
        local offsetRad = offsetDeg * math_pi / 180
        if math_random() < 0.5 then
            offsetRad = -offsetRad
        end

        local radius = 80 + math_random() * 120
        local angle = baseAngle + offsetRad
        local x = destination[1] + math_cos(angle) * radius
        local z = destination[3] + math_sin(angle) * radius

        local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize) or { 512, 512 }
        x = math_min(math_max(x, 0), size[1])
        z = math_min(math_max(z, 0), size[2])

        local approach = { x, AmphibiousSurfaceHeight(layer, x, z), z }
        if approach and CanPathBetween(layer, startPos, approach) and CanPathBetween(layer, approach, destination) then
            local first = BuildPathSegment(layer, startPos, approach)
            local second = BuildPathSegment(layer, approach, destination)
            if first and second then
                local candidate = MergePathSegments({ first, second })
                local candidateHeading = FinalApproachHeading(candidate, startPos, destination)
                local angleDiff = candidateHeading and AngleDifferenceDegrees(candidateHeading, baselineHeading) or 0
                if angleDiff >= 60 then
                    local candidateLength = PathLength(candidate)
                    local lengthRatio = candidateLength / baselineLength
                    local threat = opts.AvoidDef and PathThreatScore(brain, layer, candidate) or 0
                    local better = false
                    if not bestPath then
                        better = true
                    elseif angleDiff > bestAngleDiff + 0.5 then
                        better = true
                    elseif math_abs(angleDiff - bestAngleDiff) <= 0.5 then
                        if (lengthRatio >= 1.10 and bestLengthRatio < 1.10) or lengthRatio > bestLengthRatio + 0.01 then
                            better = true
                        elseif math_abs(lengthRatio - bestLengthRatio) <= 0.01 and opts.AvoidDef and threat < bestThreat - 0.01 then
                            better = true
                        end
                    end
                    if better then
                        bestPath = candidate
                        bestAngleDiff = angleDiff
                        bestLengthRatio = lengthRatio
                        bestThreat = threat
                    end
                end
            end
        end
    end

    return bestPath
end

local function OffsetCorner(prev, corner, next, layer)
    local inDx = corner[1] - prev[1]
    local inDz = corner[3] - prev[3]
    local outDx = next[1] - corner[1]
    local outDz = next[3] - corner[3]

    local inLen = math_sqrt(inDx * inDx + inDz * inDz)
    local outLen = math_sqrt(outDx * outDx + outDz * outDz)
    if inLen < 0.001 or outLen < 0.001 then
        return CopyVector(corner)
    end

    local clamp = math_min(RouteClearanceOffset, inLen * 0.5, outLen * 0.5)
    local sumX = (inDx / inLen) + (outDx / outLen)
    local sumZ = (inDz / inLen) + (outDz / outLen)
    local sumLen = math_sqrt(sumX * sumX + sumZ * sumZ)
    if sumLen < 0.001 then
        return CopyVector(corner)
    end

    local offsetX = sumX / sumLen * clamp
    local offsetZ = sumZ / sumLen * clamp
    local adjusted = {
        corner[1] - offsetX,
        AmphibiousSurfaceHeight(layer, corner[1] - offsetX, corner[3] - offsetZ),
        corner[3] - offsetZ,
    }

    if IsDirectPathSegment(layer, prev, adjusted) and IsDirectPathSegment(layer, adjusted, next) then
        return adjusted
    end

    return CopyVector(corner)
end

local function ApplyPathClearance(path, layer)
    if not (path and table_getn(path) >= 3) then
        return path
    end

    local widened = { CopyVector(path[1]) }
    for i = 2, table_getn(path) - 1 do
        local prev = widened[table_getn(widened)] or path[i - 1]
        local corner = path[i]
        local next = path[i + 1]
        if prev and corner and next then
            table_insert(widened, OffsetCorner(prev, corner, next, layer))
        end
    end

    table_insert(widened, CopyVector(path[table_getn(path)]))
    return widened
end

local function Normalize2D(dx, dz)
    local len = math_sqrt(dx * dx + dz * dz)
    if len < 0.001 then
        return 0, 0
    end
    return dx / len, dz / len
end

local function GetClearanceEstimate(layer, pos)
    if not pos then
        return CorridorProbeMax + 1, nil
    end

    local directions = {
        { 0, 1 },
        { 1, 1 },
        { 1, 0 },
        { 1, -1 },
        { 0, -1 },
        { -1, -1 },
        { -1, 0 },
        { -1, 1 },
    }
    if CorridorDirections and CorridorDirections <= 4 then
        directions = {
            { 0, 1 },
            { 1, 0 },
            { 0, -1 },
            { -1, 0 },
        }
    end

    local x = pos[1]
    local z = pos[3]
    local minDistance = CorridorProbeMax + 1
    local minDirX = nil
    local minDirZ = nil

    for _, direction in ipairs(directions) do
        local dirX, dirZ = Normalize2D(direction[1], direction[2])
        local blocked = nil
        for distance = CorridorProbeStep, CorridorProbeMax, CorridorProbeStep do
            local testX = x + dirX * distance
            local testZ = z + dirZ * distance
            local testPos = { testX, AmphibiousSurfaceHeight(layer, testX, testZ), testZ }
            if not IsDirectPathSegment(layer, pos, testPos) then
                blocked = distance
                break
            end
        end

        local clearance = blocked or (CorridorProbeMax + 1)
        if clearance < minDistance then
            minDistance = clearance
            minDirX = dirX
            minDirZ = dirZ
        end
    end

    if minDirX then
        local pushX, pushZ = Normalize2D(-minDirX, -minDirZ)
        return minDistance, { pushX, 0, pushZ }
    end

    return minDistance, nil
end

local function ApplyCorridorCentering(path, layer, startPos, destination, opts)
    path = ApplyPathClearance(path, layer)
    if not (path and table_getn(path) >= 3) then
        return path
    end

    local cumulative = {}
    local total = 0
    local prev = startPos
    for i = 1, table_getn(path) do
        local point = path[i]
        if prev and point then
            total = total + Distance(prev, point)
        end
        cumulative[i] = total
        prev = point
    end

    for _ = 1, CorridorPasses do
        for i = 2, table_getn(path) - 1 do
            if cumulative[i] <= CorridorNearDistance then
                local prevPoint = path[i - 1]
                local current = path[i]
                local nextPoint = path[i + 1]
                if prevPoint and current and nextPoint then
                    local clearance, pushDir = GetClearanceEstimate(layer, current)
                    if pushDir and clearance < CorridorDesiredClearance then
                        local pushAmount = math_min(CorridorMaxShiftPerPass, CorridorDesiredClearance - clearance)
                        local attemptAmounts = { pushAmount, pushAmount * 0.5, pushAmount * 0.25 }
                        local accepted = false

                        for _, amount in ipairs(attemptAmounts) do
                            local newX = current[1] + pushDir[1] * amount
                            local newZ = current[3] + pushDir[3] * amount
                            local candidate = { newX, AmphibiousSurfaceHeight(layer, newX, newZ), newZ }

                            if ClampPathToPlayableArea then
                                local clamped = ClampPathToPlayableArea({ candidate }, 0)
                                if clamped and clamped[1] then
                                    candidate = clamped[1]
                                end
                            end

                            if IsDirectPathSegment(layer, prevPoint, candidate) and IsDirectPathSegment(layer, candidate, nextPoint) then
                                path[i] = candidate
                                accepted = true
                                break
                            end
                        end

                        if not accepted then
                            path[i] = current
                        end
                    end
                end
            end
        end
    end

    if CorridorSimplifyAngle and CorridorSimplifyAngle > 0 and table_getn(path) >= 3 then
        local simplified = { path[1] }
        local cosThreshold = math_cos(CorridorSimplifyAngle * math_pi / 180)
        for i = 2, table_getn(path) - 1 do
            local a = simplified[table_getn(simplified)]
            local b = path[i]
            local c = path[i + 1]
            if a and b and c then
                local abX, abZ = Normalize2D(b[1] - a[1], b[3] - a[3])
                local bcX, bcZ = Normalize2D(c[1] - b[1], c[3] - b[3])
                local dot = abX * bcX + abZ * bcZ
                if dot >= cosThreshold and IsDirectPathSegment(layer, a, c) then
                    -- skip b
                else
                    table_insert(simplified, b)
                end
            end
        end
        table_insert(simplified, path[table_getn(path)])
        path = simplified
    end

    return path
end

local function FindSafePath(platoon, layer, destination, startOverride, opts)
    opts = opts or {}

    local startPos = startOverride or GetPlatoonPosition(platoon)
    if not (startPos and destination) then return nil end

    local path = BuildPathSegment(layer, startPos, destination)
    if not path then
        return nil
    end

    local alternate = TryAlternatePath(platoon, layer, startPos, destination, opts)
    if alternate then
        path = alternate
    end

    if opts.CorridorCentering == false then
        return ApplyPathClearance(path, layer)
    end

    return ApplyCorridorCentering(path, layer, startPos, destination, opts)
end

local function MaxWeaponRange(platoon)
    local units = platoon and platoon:GetPlatoonUnits() or {}
    local maxRange = 0
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            local bp = unit:GetBlueprint()
            if bp and bp.Weapon then
                for _, weapon in ipairs(bp.Weapon) do
                    if weapon.MaxRadius and weapon.MaxRadius > maxRange then
                        maxRange = weapon.MaxRadius
                    end
                end
            end
        end
    end
    return maxRange
end

local function ShortenPathForBombard(path, targetPos, range)
    if not (path and targetPos and range and range > 0 and table_getn(path) > 0) then
        return path
    end

    local last = path[table_getn(path)]
    if not last then
        return path
    end

    local dx = targetPos[1] - last[1]
    local dz = targetPos[3] - last[3]
    local dist = math_sqrt(dx * dx + dz * dz)
    if dist < 0.001 then
        return path
    end

    local desired = math_max(range * 0.9, 5)
    local scale = (dist - desired) / dist
    if scale <= 0 then
        return path
    end

    local adjusted = {
        last[1] + dx * scale,
        last[2],
        last[3] + dz * scale,
    }

    path[table_getn(path)] = adjusted
    return path
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

ClampPathToPlayableArea = function(path, buffer)
    local area = GetPlayableArea()
    if not (area and path and table_getn(path) > 0) then
        return path
    end

    buffer = buffer or 0

    local clamped = {}
    for _, waypoint in ipairs(path) do
        if waypoint then
            table_insert(clamped, ClampToPlayableArea(waypoint, area, buffer))
        end
    end

    return clamped
end

local function MoveAlongPath(platoon, path, formation, aggressiveFinal)
    if not (path and table_getn(path) > 0) then return end

    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then return end

    -- Make sure we never issue move orders outside the playable area
    path = ClampPathToPlayableArea(path, PlayableIngressBuffer)

    local useFormation = formation and formation ~= 'NoFormation'
    if useFormation then
        platoon:SetPlatoonFormationOverride(formation)
    else
        platoon:SetPlatoonFormationOverride('NoFormation')
    end

    IssueClearCommands(units)

    local minPointSpacingSq = 20 * 20
    local lastIssued = nil
    local count = table_getn(path)
    for index, waypoint in ipairs(path) do
        if not (lastIssued and DistanceSq(lastIssued, waypoint) < minPointSpacingSq) then
            local isFinal = index == count
            if useFormation then
                IssueFormMove(units, waypoint, formation, 0)
            else
                if aggressiveFinal and isFinal then
                    IssueAggressiveMove(units, waypoint)
                else
                    IssueMove(units, waypoint)
                end
            end

            lastIssued = waypoint
        end
    end
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
    local bombardRange = nil
    if opts.Bombard then
        bombardRange = MaxWeaponRange(platoon)
        if bombardRange <= 0 then
            bombardRange = nil
        end
    end

    local path = nil
    local ingress = nil
    if startedOutside then
        ingress = NearestPlayablePointOnPath(startPos, nil, area)
        if ingress then
            path = FindSafePath(platoon, layer, target.position, ingress, opts)
            if not (path and table_getn(path) > 0) then
                path = BuildPathSegment(layer, ingress, target.position)
            end

            if path and table_getn(path) > 0 then
                local first = path[1]
                if not (first and DistanceSq(first, ingress) < 1) then
                    table_insert(path, 1, CopyVector(ingress))
                end
            else
                path = { CopyVector(ingress) }
            end
        end
    else
        path = FindSafePath(platoon, layer, target.position, nil, opts)
    end

    local canPath = CanPathTo(platoon, layer, target.position)
    if not canPath and ingress then
        canPath = CanPathBetween(layer, ingress, target.position)
    end
    if not canPath then
        if opts.Transport then
            if not TransportAndMove(platoon, target.position, opts) then
                return 'fail'
            end
            path = FindSafePath(platoon, layer, target.position, nil, opts)
        else
            return 'fail'
        end
    elseif not path then
        path = FindSafePath(platoon, layer, target.position, nil, opts)
    end

    if not path then
        return 'fail'
    end

    if bombardRange then
        path = ShortenPathForBombard(path, target.position, bombardRange)
    end

    MoveAlongPath(platoon, path, opts.Formation)
    
    local arrived = false
    local epsilon = 5
    local units = platoon:GetPlatoonUnits() or {}
    local stuckSeconds = 0
    local lastPos = GetPlatoonPosition(platoon)
    local lastDistSq = lastPos and DistanceSq(lastPos, target.position) or nil
    while PlatoonAlive(platoon) do
        local pos = GetPlatoonPosition(platoon)
        if not pos then break end
        local arrivalRadius = target.radius + epsilon
        if bombardRange and bombardRange > arrivalRadius then
            arrivalRadius = bombardRange
        end
        if DistanceSq(pos, target.position) < (arrivalRadius * arrivalRadius) then
            arrived = true
            break
        end
        SafeWait(1)
        local updatedPos = GetPlatoonPosition(platoon)
        if not updatedPos then break end
        local distSq = DistanceSq(updatedPos, target.position)
        local movedSq = lastPos and DistanceSq(updatedPos, lastPos) or 0
        if lastDistSq and (lastDistSq - distSq) > TravelProgressEpsilonSq then
            stuckSeconds = 0
        elseif movedSq > TravelProgressEpsilonSq then
            stuckSeconds = 0
        else
            stuckSeconds = stuckSeconds + 1
        end
        lastDistSq = distSq
        lastPos = CopyVector(updatedPos)
        if stuckSeconds >= TravelStuckSeconds then
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
    local formation = opts.Formation or 'GrowthFormation'
    if opts.Bombard and bombardRange then
        platoon:SetPlatoonFormationOverride(formation)
        -- Hold position and engage at range
    elseif formation ~= 'NoFormation' then
        platoon:SetPlatoonFormationOverride(formation)
        IssueFormMove(units, target.position, formation, 0)
    else
        local finalAggressive = target and target.finalAggressiveMove
        if finalAggressive == nil then
            finalAggressive = true
        end
        if finalAggressive then
            IssueAggressiveMove(units, target.position)
        else
            IssueMove(units, target.position)
        end
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
            local areaUnits = AreaUnits(brain, enemyBrains, target.position, radius, category, opts.IntelOnly) or {}
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
                opts._repathing = nil
                SafeWait(1)
            elseif result == 'repath' then
                opts._repathing = true
                SafeWait(1)
            else
                currentTarget = nil
                opts._repathing = nil
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

local function OrbitWaypoints(center, count, radius)
    local list = {}
    if not center then
        return list
    end
    for i = 1, count do
        local angle = (i / count) * 6.28318
        local x = center[1] + math_cos(angle) * radius
        local z = center[3] + math_sin(angle) * radius
        local y = GetSurfaceHeight(x, z)
        table_insert(list, { x, y, z })
    end
    return list
end

local function NormalizeBlueprintSet(value)
    local set = {}
    if type(value) == 'string' then
        set[string.lower(value)] = true
    elseif type(value) == 'table' then
        for _, entry in ipairs(value) do
            if type(entry) == 'string' then
                set[string.lower(entry)] = true
            end
        end
    end
    return set
end

local function NormalizeCategoryList(value)
    local list = {}
    local function add(cat)
        if cat then
            table_insert(list, cat)
        end
    end
    local function parse(entry)
        if type(entry) == 'string' then
            local parser = _G.ParseEntityCategoryProper or _G.ParseEntityCategory
            if parser then
                local ok, parsed = pcall(parser, entry)
                if ok then
                    return parsed
                end
            end
        end
        return entry
    end

    if type(value) == 'table' then
        for _, entry in ipairs(value) do
            add(parse(entry))
        end
    elseif value then
        add(parse(value))
    end

    return list
end

local function SpecPosition(spec)
    if not spec then return nil end
    if spec.GetPosition then
        return spec:GetPosition()
    end
    return spec.Position or spec.position or spec.Pos or spec.pos
end

local function SpecFacing(spec)
    if not spec then return 0 end
    if spec.GetOrientation then
        local o = spec:GetOrientation() or {}
        return o[1] or 0
    end
    local o = spec.Orientation or spec.orientation or {}
    return o[1] or 0
end

local function SpecBlueprintId(spec)
    if not spec then return nil end
    if spec.BlueprintID then
        return string.lower(spec.BlueprintID)
    end
    if spec.GetBlueprint then
        local bp = spec:GetBlueprint()
        if bp and bp.BlueprintId then
            return string.lower(bp.BlueprintId)
        end
    end
    local id = spec.type or spec.bp or spec.bpId or spec.BlueprintId or spec.blueprintId or spec.UnitId
    if type(id) == 'string' then
        return string.lower(id)
    end
    return nil
end

local function ArmyNameFromBrain(brain)
    if not brain then return nil end
    local idx = brain.GetArmyIndex and brain:GetArmyIndex()
    if not idx then return nil end
    if ArmyBrains and ArmyBrains[idx] and ArmyBrains[idx].Name then
        return ArmyBrains[idx].Name
    end
    return ('ARMY_' .. tostring(idx))
end

local function GetGroupSpecs(brain, groupName)
    if not groupName then return {} end
    local armyName = ArmyNameFromBrain(brain)
    if armyName and ScenarioUtils.AssembleArmyGroup then
        local ok, spec = pcall(function() return ScenarioUtils.AssembleArmyGroup(armyName, groupName) end)
        if ok and type(spec) == 'table' and next(spec) then
            return spec
        end
    end

    if ScenarioInfo and ScenarioInfo.Groups and ScenarioInfo.Groups[groupName] and ScenarioInfo.Groups[groupName].Units then
        return ScenarioInfo.Groups[groupName].Units
    end

    local ok, units = pcall(function() return ScenarioUtils.GetUnitGroup(groupName) end)
    if ok and type(units) == 'table' then
        return units
    end

    return {}
end

local function UnitBlueprintId(unit)
    if not unit then return nil end
    if unit.BlueprintID then
        return string.lower(unit.BlueprintID)
    end
    local bp = unit:GetBlueprint()
    if bp and bp.BlueprintId then
        return string.lower(bp.BlueprintId)
    end
    return nil
end

local function UnitMatchesBlueprint(unit, set)
    if not (unit and set) then
        return false
    end
    local id = UnitBlueprintId(unit)
    if not id then
        return false
    end
    return set[id] == true
end

local function UnitMatchesCategory(unit, categoriesList)
    if not (unit and categoriesList and table_getn(categoriesList) > 0) then
        return false
    end
    for _, category in ipairs(categoriesList) do
        if category and EntityCategoryContains(category, unit) then
            return true
        end
    end
    return false
end

local function HasIntelOnUnit(brain, unit, intelOnly)
    if not intelOnly then
        return true
    end
    if not (brain and unit and not unit.Dead) then
        return false
    end
    local army = brain:GetArmyIndex()
    if not army then
        return false
    end
    local ok, visible = pcall(IsUnitVisible, army, unit)
    if ok and visible then
        return true
    end
    local hasBlip = false
    local success, blip = pcall(unit.GetBlip, unit, army)
    if success and blip then
        hasBlip = true
    end
    return hasBlip
end

local function ResolveMarkerPosition(marker)
    if type(marker) == 'table' then
        if marker[1] and marker[3] then
            local y = marker[2] or GetSurfaceHeight(marker[1], marker[3])
            return { marker[1], y, marker[3] }
        end
    elseif type(marker) == 'string' then
        local ok, pos = pcall(ScenarioUtils.MarkerToPosition, marker)
        if ok and pos then
            return { pos[1], pos[2], pos[3] }
        end
    end
    return nil
end

local function ResolveChainPositions(chainName)
    if not chainName then
        return {}
    end
    local ok, chain = pcall(ScenarioUtils.ChainToPositions, chainName)
    if not ok or type(chain) ~= 'table' then
        return {}
    end
    local points = {}
    for _, pos in ipairs(chain) do
        if pos and pos[1] and pos[3] then
            table_insert(points, { pos[1], pos[2] or GetSurfaceHeight(pos[1], pos[3]), pos[3] })
        end
    end
    return points
end

local function NormalizePatrolPoints(points, layer)
    local out = {}
    for _, pos in ipairs(points or {}) do
        if pos and pos[1] and pos[3] then
            local y = AmphibiousSurfaceHeight(layer, pos[1], pos[3])
            table_insert(out, { pos[1], y, pos[3] })
        end
    end
    return out
end

local function BuildPingPongRoute(points)
    local out = {}
    local count = table_getn(points)
    for i = 1, count do
        table_insert(out, points[i])
    end
    for i = count - 1, 2, -1 do
        table_insert(out, points[i])
    end
    return out
end

local function FirebaseLocationsFromData(data)
    local locations = {}
    if not data then
        return locations
    end

    if type(data.Locations) == 'table' then
        for _, entry in ipairs(data.Locations) do
            if type(entry) == 'table' then
                local marker = entry.marker or entry.Marker or entry.location or entry.Location or entry[1]
                local group = entry.group or entry.Group or entry.structGroup or entry.StructGroup or entry[2]
                if marker or group then
                    table_insert(locations, { marker = marker, group = group })
                end
            end
        end
    elseif type(data.Markers) == 'table' then
        local groups = data.Groups or data.StructureGroups or data.GroupNames
        for i, marker in ipairs(data.Markers) do
            table_insert(locations, { marker = marker, group = groups and groups[i] or nil })
        end
    end

    return locations
end

local function FirebaseLocationSafe(brain, pos, safeRadius, opts)
    local enemies = BrainEnemies(brain, opts and opts.TargetArmy)
    local units = AreaUnits(brain, enemies, pos, safeRadius, categories.ALLUNITS, opts and opts.IntelOnly)
    return table_getn(units) == 0
end

local function FirebaseMissingStructures(brain, groupName, radius)
    local missing = {}
    local specs = GetGroupSpecs(brain, groupName)
    for _, spec in pairs(specs or {}) do
        local bp = SpecBlueprintId(spec)
        local pos = SpecPosition(spec)
        local facing = SpecFacing(spec)
        if bp and pos and pos[1] and pos[3] then
            local found = false
            local units = brain:GetUnitsAroundPoint(categories.STRUCTURE, pos, radius or FirebaseStructureRadius, 'Ally') or {}
            for _, unit in ipairs(units) do
                if unit and not unit.Dead and UnitBlueprintId(unit) == bp then
                    found = true
                    break
                end
            end
            if not found then
                table_insert(missing, { bp = bp, pos = pos, facing = facing })
            end
        end
    end
    return missing
end

local function IssueFirebaseBuilds(platoon, builds)
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then
        return
    end
    IssueClearCommands(units)
    for _, spec in ipairs(builds or {}) do
        if spec.bp and spec.pos then
            IssueBuildMobile(units, spec.pos, spec.bp, spec.facing or 0)
        end
    end
end

local function FirebaseBuildsComplete(brain, builds, radius)
    for _, spec in ipairs(builds or {}) do
        local pos = spec.pos
        local bp = spec.bp
        if pos and bp then
            local found = false
            local units = brain:GetUnitsAroundPoint(categories.STRUCTURE, pos, radius or FirebaseStructureRadius, 'Ally') or {}
            for _, unit in ipairs(units) do
                if unit and not unit.Dead and UnitBlueprintId(unit) == bp then
                    found = true
                    break
                end
            end
            if not found then
                return false
            end
        end
    end
    return true
end

local function CountFactories(base)
    if not base or not base.GetFactoryControl then
        return 0
    end
    local control = base:GetFactoryControl()
    if not (control and control.factoryState) then
        return 0
    end
    local count = 0
    for _, state in pairs(control.factoryState) do
        local unit = state and state.unit
        if unit and not unit.Dead then
            count = count + 1
        end
    end
    return count
end

local function CountEngineers(base)
    if not base or not base.GetEngineerHandle then
        return 0
    end
    local handle = base:GetEngineerHandle()
    if not (handle and handle.tracked) then
        return 0
    end
    local count = 0
    for _, set in pairs(handle.tracked) do
        for _, unit in pairs(set or {}) do
            if unit and not unit.Dead then
                count = count + 1
            end
        end
    end
    return count
end

local function IdleAtMarker(platoon, markerPos, layer, formation)
    if not (platoon and markerPos) then return end
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then return end
    IssueClearCommands(units)
    if layer == 'Air' then
        local waypoints = OrbitWaypoints(markerPos, HuntOrbitPoints, HuntOrbitRadius)
        for _, point in ipairs(waypoints) do
            IssuePatrol(units, point)
        end
        if table_getn(waypoints) > 0 then
            IssuePatrol(units, waypoints[1])
        end
    else
        if formation ~= 'NoFormation' then
            platoon:SetPlatoonFormationOverride(formation)
            IssueFormMove(units, markerPos, formation, 0)
        else
            IssueMove(units, markerPos)
        end
    end
end

local function NormalizeDegrees(deg)
    deg = math_mod(deg, 360)
    if deg < 0 then
        deg = deg + 360
    end
    return deg
end

local function IssuePatrolRoute(platoon, points, formation)
    if not (platoon and points and table_getn(points) > 0) then
        return
    end
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then
        return
    end

    IssueClearCommands(units)
    platoon:SetPlatoonFormationOverride(formation or 'GrowthFormation')

    IssueMove(units, points[1])

    for i = 2, table_getn(points) do
        local point = points[i]
        IssuePatrol(units, point)
    end

    -- close the loop
    IssuePatrol(units, points[1])
end

local function BuildPerimeterPoints(layer, basePos, distance)
    local points = {}
    local count = 6
    for i = 1, count do
        local angle = (i / count) * 6.28318
        local x = basePos[1] + math_cos(angle) * distance
        local z = basePos[3] + math_sin(angle) * distance
        local point = { x, AmphibiousSurfaceHeight(layer, x, z), z }
        if CanPathBetween(layer, basePos, point) then
            table_insert(points, point)
        end
    end

    if table_getn(points) == 0 then
        table_insert(points, basePos)
    end
    return points
end

local function FindIntruder(brain, layer, basePos, interceptRadius, opts)
    local enemies = BrainEnemies(brain, opts and opts.TargetArmy)
    local units = AreaUnits(brain, enemies, basePos, interceptRadius, categories.ALLUNITS, opts and opts.IntelOnly)
    units = FilterUnits(units, layer, opts and opts.Submersible)

    local closest
    local closestDist = math_huge
    for _, unit in ipairs(units) do
        if unit and not unit.Dead and CanTargetUnit(layer, opts and opts.Submersible, unit) then
            local pos = unit:GetPosition()
            if pos then
                local dist = DistanceSq(basePos, pos)
                if dist < closestDist then
                    closestDist = dist
                    closest = unit
                end
            end
        end
    end
    return closest
end

local function FindHuntTarget(brain, platoon, opts, layer, excluded, requireSafe)
    local hasBlueprints = opts and opts.HuntSet and next(opts.HuntSet)
    local hasCategories = opts and opts.HuntCategories and table_getn(opts.HuntCategories) > 0
    if not (brain and platoon and (hasBlueprints or hasCategories)) then
        return nil
    end
    local startPos = GetPlatoonPosition(platoon)
    if not startPos then
        return nil
    end
    local enemies = BrainEnemies(brain, opts.TargetArmy)
    local excludedSet = excluded or {}
    local best, bestDist = nil, math_huge
    local bestSafe, bestSafeDist = nil, math_huge
    for _, enemyIndex in ipairs(enemies) do
        local eBrain = ArmyBrains[enemyIndex]
        if eBrain then
            local list = eBrain:GetListOfUnits(categories.ALLUNITS, false) or {}
            for _, unit in ipairs(list) do
                if unit and not unit.Dead then
                    local id = unit.EntityId
                    if not (id and excludedSet[id]) then
                        if (UnitMatchesBlueprint(unit, opts.HuntSet) or UnitMatchesCategory(unit, opts.HuntCategories)) and CanTargetUnit(layer, opts.Submersible, unit) then
                            if not opts.IntelOnly or HasIntelOnUnit(brain, unit, true) then
                                local unitPos = unit:GetPosition()
                                if unitPos then
                                    local dist = DistanceSq(startPos, unitPos)
                                    local threat = opts.Vulnerable and DefenseThreatNear(brain, unitPos, layer) or 0
                                    local info = {
                                        unit = unit,
                                        position = CopyVector(unitPos),
                                        distance = dist,
                                        threat = threat,
                                    }
                                    if dist < bestDist then
                                        best = info
                                        bestDist = dist
                                    end
                                    if threat <= 0 and dist < bestSafeDist then
                                        bestSafe = info
                                        bestSafeDist = dist
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if requireSafe then
        return bestSafe
    end
    if opts.Vulnerable and bestSafe then
        return bestSafe
    end
    return best
end

local function TrackHuntTarget(platoon, targetInfo, opts, layer)
    local brain = platoon:GetBrain()
    if not (brain and targetInfo and targetInfo.unit) then
        return 'fail'
    end
    local unit = targetInfo.unit
    local lastCommandPos = nil
    while PlatoonAlive(platoon) do
        if not (unit and not unit.Dead) then
            return 'destroyed'
        end
        if not HasIntelOnUnit(brain, unit, opts.IntelOnly) then
            return 'intel'
        end
        local skipIteration = false
        local unitPos = unit:GetPosition()
        if not unitPos then
            SafeWait(1)
            skipIteration = true
        end
        if not skipIteration and opts.Vulnerable then
            local threat = DefenseThreatNear(brain, unitPos, layer)
            if threat > 0 then
                return 'defended'
            end
        end
        if not skipIteration and (not lastCommandPos or DistanceSq(lastCommandPos, unitPos) > HuntRepathDistanceSq) then
            if not CanPathTo(platoon, layer, unitPos) then
                if not TransportAndMove(platoon, unitPos, opts) then
                    SafeWait(RecheckDelay)
                    skipIteration = true
                end
            end
            if not skipIteration then
                local path = FindSafePath(platoon, layer, unitPos, nil, opts)
                if not path then
                    SafeWait(RecheckDelay)
                    skipIteration = true
                else
                    MoveAlongPath(platoon, path, opts.Formation, true)
                    lastCommandPos = CopyVector(unitPos)
                end
            end
        end
        local platoonPos = nil
        if not skipIteration then
            platoonPos = GetPlatoonPosition(platoon)
            if not platoonPos then
                SafeWait(1)
                skipIteration = true
            end
        end
        if not skipIteration and DistanceSq(platoonPos, unitPos) <= HuntAttackDistanceSq then
            local units = platoon:GetPlatoonUnits() or {}
            if table_getn(units) == 0 then
                return 'fail'
            end
            IssueAttack(units, unit)
            local elapsed = 0
            while PlatoonAlive(platoon) do
                if not (unit and not unit.Dead) then
                    return 'destroyed'
                end
                if opts.IntelOnly and not HasIntelOnUnit(brain, unit, true) then
                    return 'intel'
                end
                if opts.Vulnerable then
                    local threat = DefenseThreatNear(brain, unit:GetPosition(), layer)
                    if threat > 0 then
                        return 'defended'
                    end
                end
                SafeWait(1)
                elapsed = elapsed + 1
                if elapsed >= RecheckDelay then
                    break
                end
            end
        elseif not skipIteration then
            SafeWait(1)
        end
    end
    return 'fail'
end

function WaveAttack(platoon, data)
    local opts = CopyOptions(data)
    if not data or data.RandomizeRoute == nil then
        opts.RandomizeRoute = true
    end
    opts.Type = opts.Type or opts.TargetType or 'closest'
    local function resolver(brain, p, o, layer)
        return ChooseBestArea(brain, p, o, layer, WaveAreaRadius, opts.Type, StructureCategory)
    end
    AttackLoop(platoon, resolver, opts)
end

function RaidAttack(platoon, data)
    local opts = CopyOptions(data)
    if not data or data.RandomizeRoute == nil then
        opts.RandomizeRoute = true
    end
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
        state[unit.EntityId] = { destination = SelectScoutDestination(brain, opts) }
        AssignScoutOrder(unit, state[unit.EntityId].destination)
    end

    while PlatoonAlive(platoon) do
        SafeWait(ScoutRecheckDelay)
        units = platoon:GetPlatoonUnits() or {}
        if table_getn(units) == 0 then break end
        for _, unit in ipairs(units) do
            if unit and not unit.Dead then
                local info = state[unit.EntityId]
                if not info then
                    info = { destination = SelectScoutDestination(brain, opts) }
                    state[unit.EntityId] = info
                    AssignScoutOrder(unit, info.destination)
                end

                local pos = unit:GetPosition()
                local dest = info.destination
                if (not dest) or (dest and pos and DistanceSq(pos, dest) < 400) then
                    info.destination = SelectScoutDestination(brain, opts)
                    AssignScoutOrder(unit, info.destination)
                end
            end
        end
    end
end

function AreaPatrol(platoon, data)
    local opts = CopyOptions(data)
    local layer = DetermineLayer(platoon, opts.Amphibious)
    if not layer then return end

    local chainName = data and (data.Chain or data.ChainName or data.PatrolChain or data.MarkerChain)
    local points = ResolveChainPositions(chainName)

    if data and type(data.Markers) == 'table' then
        for _, marker in ipairs(data.Markers) do
            local pos = ResolveMarkerPosition(marker)
            if pos then
                table_insert(points, pos)
            end
        end
    end

    points = NormalizePatrolPoints(points, layer)
    if table_getn(points) < 2 then
        return
    end

    local continuous = true
    if data and data.Continuous ~= nil then
        continuous = data.Continuous and true or false
    end

    local route = points
    if not continuous then
        route = BuildPingPongRoute(points)
    end

    IssuePatrolRoute(platoon, route, opts.Formation)

    while PlatoonAlive(platoon) do
        SafeWait(RecheckDelay)
    end
end

function Firebase(platoon, data)
    local opts = CopyOptions(data)
    local brain = platoon:GetBrain()
    if not brain then return end
    local layer = DetermineLayer(platoon, opts.Amphibious)
    local locations = FirebaseLocationsFromData(data)
    local waitPos = ResolveMarkerPosition(data and (data.WaitMarker or data.Marker or data.IdleMarker))
    local safeRadius = (data and (data.SafeRadius or data.SafeRange or data.Radius)) or FirebaseSafeRadius
    local structureRadius = (data and (data.StructureRadius or data.BuildRadius)) or FirebaseStructureRadius

    while PlatoonAlive(platoon) do
        local acted = false
        for _, loc in ipairs(locations) do
            local pos = ResolveMarkerPosition(loc.marker) or loc.position
            if pos and FirebaseLocationSafe(brain, pos, safeRadius, opts) then
                local missing = FirebaseMissingStructures(brain, loc.group, structureRadius)
                if table_getn(missing) > 0 then
                    acted = true
                    local path = FindSafePath(platoon, layer, pos, nil, opts)
                    if path then
                        MoveAlongPath(platoon, path, opts.Formation, true)
                    else
                        local units = platoon:GetPlatoonUnits() or {}
                        if table_getn(units) > 0 then
                            IssueMove(units, pos)
                        end
                    end

                    IssueFirebaseBuilds(platoon, missing)

                    while PlatoonAlive(platoon) do
                        if FirebaseBuildsComplete(brain, missing, structureRadius) then
                            break
                        end
                        SafeWait(5)
                    end
                end
            end
        end

        if not acted then
            if waitPos then
                IdleAtMarker(platoon, waitPos, layer, opts.Formation)
            end
            SafeWait(RecheckDelay)
        end
    end
end

function Supportbase(platoon, data)
    local opts = CopyOptions(data)
    local brain = platoon:GetBrain()
    if not brain then return end
    local layer = DetermineLayer(platoon, opts.Amphibious)
    local waitPos = ResolveMarkerPosition(data and (data.WaitMarker or data.Marker or data.IdleMarker))

    local tags = {}
    local rawTags = data and (data.BaseTags or data.BaseTag or data.Tags or data.Tag)
    if type(rawTags) == 'table' then
        tags = rawTags
    elseif rawTags then
        tags = { rawTags }
    end

    while PlatoonAlive(platoon) do
        local targetBase = nil
        for _, tag in ipairs(tags) do
            local base = BaseManager and BaseManager.GetBase and BaseManager.GetBase(tag)
            if base then
                local factories = CountFactories(base)
                local engineers = CountEngineers(base)
                if factories == 0 and engineers == 0 then
                    targetBase = base
                    break
                end
            end
        end

        if targetBase then
            local basePos = targetBase.basePos
            if not basePos and targetBase.params and targetBase.params.baseMarker then
                basePos = ResolveMarkerPosition(targetBase.params.baseMarker)
            end

            if basePos then
                local path = FindSafePath(platoon, layer, basePos, nil, opts)
                if path then
                    MoveAlongPath(platoon, path, opts.Formation, true)
                else
                    local units = platoon:GetPlatoonUnits() or {}
                    if table_getn(units) > 0 then
                        IssueMove(units, basePos)
                    end
                end
            end

            if targetBase.AssignEngineerUnit then
                targetBase:AssignEngineerUnit(platoon)
            end
            if brain and brain.PlatoonExists and brain:PlatoonExists(platoon) then
                brain:DisbandPlatoon(platoon)
            end
            return
        end

        if waitPos then
            IdleAtMarker(platoon, waitPos, layer, opts.Formation)
        end
        SafeWait(RecheckDelay)
    end
end

function HuntAttack(platoon, data)
    local opts = CopyOptions(data)
    opts.Vulnerable = opts.Vulnerable and true or false
    local blueprintData = data and (data.Blueprints or data.Blueprint or data.TargetBlueprints or data.TargetBPs or data.TargetBP)
    opts.HuntSet = NormalizeBlueprintSet(blueprintData)
    opts.HuntCategories = NormalizeCategoryList(data and (data.Category or data.Categories or data.TargetCategory or data.TargetCategories))
    if not (next(opts.HuntSet) or table_getn(opts.HuntCategories) > 0) then
        return
    end

    opts.MarkerPosition = ResolveMarkerPosition(opts.Marker or opts.IdleMarker)

    local brain = platoon:GetBrain()
    if not brain then return end
    local layer = DetermineLayer(platoon, opts.Amphibious)

    local currentTarget = nil
    local idleIssued = false
    local excludedIntel = {}

    while PlatoonAlive(platoon) do
        if currentTarget then
            local status = TrackHuntTarget(platoon, currentTarget, opts, layer)
            if status == 'destroyed' or status == 'intel' or status == 'fail' then
                if status == 'intel' and currentTarget.unit and currentTarget.unit.EntityId then
                    excludedIntel[currentTarget.unit.EntityId] = true
                end
                currentTarget = nil
            elseif status == 'defended' then
                local excluded = {}
                if currentTarget.unit and currentTarget.unit.EntityId then
                    excluded[currentTarget.unit.EntityId] = true
                end
                local alternative = FindHuntTarget(brain, platoon, opts, layer, excluded, true)
                if alternative then
                    currentTarget = alternative
                else
                    SafeWait(HuntDefenseWait)
                end
            else
                SafeWait(RecheckDelay)
            end
        else
            local target = FindHuntTarget(brain, platoon, opts, layer, excludedIntel)
            if target then
                currentTarget = target
                excludedIntel = {}
                idleIssued = false
            else
                if opts.MarkerPosition and not idleIssued then
                    IdleAtMarker(platoon, opts.MarkerPosition, layer, opts.Formation)
                    idleIssued = true
                end
                WaitForTargets(brain, HuntRecheckInterval)
            end
        end
    end
end

function DefensePatrol(platoon, data)
    local opts = CopyOptions(data)
    local brain = platoon:GetBrain()
    if not brain then return end
    local layer = DetermineLayer(platoon, opts.Amphibious)

    local basePos = ResolveMarkerPosition(data and (data.BaseMarker or data.BasePosition)) or GetPlatoonPosition(platoon)
    if not basePos then
        return
    end
    basePos = SurfacePoint(basePos)

    local patrolDistance   = (data and (data.PatrolDistance or data.Distance)) or DefaultPatrolDistance
    local interceptRadius  = (data and (data.InterceptDistance or data.InterceptRadius or data.InterceptRange)) or DefaultInterceptDistance

    local patrolPoints = BuildPerimeterPoints(layer, basePos, patrolDistance)
    IssuePatrolRoute(platoon, patrolPoints, opts.Formation)

    while PlatoonAlive(platoon) do
        local intruder = FindIntruder(brain, layer, basePos, interceptRadius, opts)
        if intruder then
            local targetPos = intruder:GetPosition()
            if targetPos then
                local path = FindSafePath(platoon, layer, targetPos, nil, opts)
                if path then
                    MoveAlongPath(platoon, path, opts.Formation, true)
                else
                    local units = platoon:GetPlatoonUnits() or {}
                    if table_getn(units) > 0 then
                        IssueAggressiveMove(units, targetPos)
                    end
                end

                local units = platoon:GetPlatoonUnits() or {}
                if table_getn(units) > 0 then
                    IssueAttack(units, intruder)
                end

                local elapsed = 0
                local maxIntercept = math_max(interceptRadius * 1.5, interceptRadius + 32)
                while PlatoonAlive(platoon) and intruder and not intruder.Dead do
                    local pos = intruder:GetPosition()
                    if not pos or DistanceSq(pos, basePos) > (maxIntercept * maxIntercept) then
                        break
                    end
                    SafeWait(1)
                    elapsed = elapsed + 1
                    if elapsed >= RecheckDelay then
                        break
                    end
                end
            end
            IssuePatrolRoute(platoon, patrolPoints, opts.Formation)
        else
            SafeWait(5)
        end
    end
end

return {
    WaveAttack = WaveAttack,
    RaidAttack = RaidAttack,
    ScoutAttack = ScoutAttack,
    AreaPatrol = AreaPatrol,
    Firebase = Firebase,
    Supportbase = Supportbase,
    HuntAttack = HuntAttack,
    DefensePatrol = DefensePatrol,
}