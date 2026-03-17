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

        AggressiveMove (boolean, default = false)
            Route using aggressive move orders instead of normal move orders.
            Supported by WaveAttack, RaidAttack, and HuntAttack. Always enabled
            for AreaPatrol and DefensePatrol.

WaveAttack specifics
        Type (string, default = 'closest')
            Determines how targets are prioritised: 'closest', 'cluster', or
            'value'.  Search areas are 50 units wide and the platoon clears all
            structures within an area before moving on.
        Bombard (boolean, default = false)
            When true, the platoon halts at its longest weapon range and
            attacks from distance instead of pushing into direct fire.
        RandomizeRoute (boolean, default = false)
            Chooses from multiple distinct valid corridors (including flank
            routes) instead of always taking the shortest route.
        AggressiveMove (boolean, default = false)
            Optional. Uses aggressive move while routing to each target area.

RaidAttack specifics
        Category (string, default = 'ECO')
            Requested structure category: 'ECO', 'BLD', 'INT', 'DEF', or 'SMT'.
            Areas are 25 units wide.  The priority chain is always
            Requested > ECO > BLD > INT > DEF.
        RandomizeRoute (boolean, default = false)
            Chooses from multiple distinct valid corridors (including flank
            routes) instead of always taking the shortest route.
        AggressiveMove (boolean, default = false)
            Optional. Uses aggressive move while routing to each target area.

ScoutAttack specifics
        Designed for AIR platoons.  Each unit continuously receives move
        targets and immediately selects a new destination after arriving.
        Destinations are random map positions with a 25% chance of being the
        hottest or coolest area on the threat map.

AreaPatrol specifics
        Always routes with aggressive move enabled.
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
        blip. `AggressiveMove` is optional (default false) and applies to
        routing while tracking the target. Setting `Vulnerable` forces the
        platoon to avoid defended
        targets, waiting for them to leave the threat ring or switching if
        another safe target exists.  If no targets are available, the platoon
        idles at `Marker`/`IdleMarker` (air platoons orbit).

DefensePatrol specifics
        Always routes with aggressive move enabled.
        The platoon defends the specified base marker/position by patrolling a
        perimeter at `PatrolDistance`.  When enemy units enter
        `InterceptDistance` of the base, the platoon moves to intercept before
        resuming the perimeter loop.
================================================================================
]]

local ScenarioFramework = import('/lua/ScenarioFramework.lua')
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

local function ResolveRoutingModule()
    local ok, info = pcall(debug.getinfo, 1, 'S')
    if ok and info and info.source then
        local src = info.source
        if type(src) == 'string' and string.sub(src, 1, 1) == '@' then
            local dir = string.match(src, '^@(.*/)[^/]*$')
            if dir then
                local path = dir .. 'platoon_Routing.lua'
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
                local path = dir .. '/platoon_Routing.lua'
                local okImport, mod = pcall(import, path)
                if okImport and mod then
                    return mod
                end
            end
        end
    end

    return import('/maps/faf_coop_U01.v0001/platoon_Routing.lua')
end

local Routing = ResolveRoutingModule()
GetTerrainHeight  = GetTerrainHeight
GetSurfaceHeight  = GetSurfaceHeight

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
local RouteAlternateAttempts   = 18
local RouteMinHeadingSeparation = 30
local RouteMinPathSeparation    = 80
local RouteMinPathSeparationRatio = 0.25
local RouteMaxLengthRatio       = 2.6
local RouteMinFlankSideRatio    = 0.2
local CorridorNearDistance     = 180
local CorridorDesiredClearance = 14
local CorridorProbeMax         = 40
local CorridorProbeStep        = 2
local CorridorMaxShiftPerPass  = 6
local CorridorPasses           = 2
local CorridorDirections       = 8
local CorridorSimplifyAngle    = 6
local RouteBacktrackMinDistanceSq = 16
local RouteZigZagAngle          = 22
local RouteCornerRoundAngle     = 28
local RouteCornerRoundRatio     = 0.28
local SegmentDirectMinDistance = 10
local SegmentDirectMaxRatio    = 1.2
local SegmentSampleStep        = 2
local SegmentSampleMaxPerLeg   = 200
local SegmentPathProbeDistance = 0.75
local FirebaseSafeRadius       = 40
local FirebaseStructureRadius  = 4
local RoutingDebug             = false

local ClampPathToPlayableArea
local CanPathBetween

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

local function RoutingLog(message, param1, param2, param3, param4, param5)
    if RoutingDebug and LOG then
        LOG('[AttackRouting]', message, param1, param2, param3, param4, param5)
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
    return (units and table.getn(units) > 0)
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
    return math.sqrt(DistanceSq(a, b))
end

local function PrependWaypoint(path, waypoint)
    if not waypoint then
        return path
    end

    path = path or {}
    local count = table.getn(path)

    if count == 0 then
        table.insert(path, CopyVector(waypoint))
        return path
    end

    local first = path[1]
    if not first then
        table.insert(path, 1, CopyVector(waypoint))
        return path
    end

    if DistanceSq(first, waypoint) > 1 then
        table.insert(path, 1, CopyVector(waypoint))
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
    local aggressiveMove = opts.AggressiveMove
    if aggressiveMove == nil then
        aggressiveMove = opts.Aggressive or opts.UseAggressiveMove
    end
    opts.AggressiveMove = aggressiveMove and true or false
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

    local x = math.min(math.max(position[1], minX), maxX)
    local z = math.min(math.max(position[3], minZ), maxZ)
    local y = GetSurfaceHeight(x, z)

    return { x, y, z }
end

local function DistanceToPlayableEdge(position, area)
    if not (position and area) then
        return (math.huge or 1e9)
    end

    local left = position[1] - area[1]
    local right = area[3] - position[1]
    local bottom = position[3] - area[2]
    local top = area[4] - position[3]
    return math.min(math.min(left, right), math.min(bottom, top))
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
        local len = math.sqrt(dirX * dirX + dirZ * dirZ)
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

local function ComputeNearestEdgeIngress(startPos, area, buffer)
    if not (startPos and area) then
        return nil
    end

    if PositionInPlayableArea(startPos, area) then
        return ClampToPlayableArea(startPos, area, math.max(buffer or 0, 0)), nil, nil
    end

    local minX, minZ, maxX, maxZ = area[1], area[2], area[3], area[4]
    local sx = startPos[1]
    local sz = startPos[3]

    -- Only allow ingress discovery via cardinal vectors from the spawn point.
    -- The first boundary crossing (smallest forward distance) is selected.
    local cardinal = {
        { edge = 'left', dx = 1, dz = 0 },
        { edge = 'right', dx = -1, dz = 0 },
        { edge = 'bottom', dx = 0, dz = 1 },
        { edge = 'top', dx = 0, dz = -1 },
    }

    local best = nil
    local bestT = (math.huge or 1e9)
    for _, ray in ipairs(cardinal) do
        local t = nil
        local hitX = nil
        local hitZ = nil

        if ray.dx > 0 then
            if sz >= minZ and sz <= maxZ and sx < minX then
                t = minX - sx
                hitX = minX
                hitZ = sz
            end
        elseif ray.dx < 0 then
            if sz >= minZ and sz <= maxZ and sx > maxX then
                t = sx - maxX
                hitX = maxX
                hitZ = sz
            end
        elseif ray.dz > 0 then
            if sx >= minX and sx <= maxX and sz < minZ then
                t = minZ - sz
                hitX = sx
                hitZ = minZ
            end
        else
            if sx >= minX and sx <= maxX and sz > maxZ then
                t = sz - maxZ
                hitX = sx
                hitZ = maxZ
            end
        end

        if t and t >= 0 and t < bestT then
            bestT = t
            best = {
                edge = ray.edge,
                x = hitX,
                z = hitZ,
                dx = ray.dx,
                dz = ray.dz,
            }
        end
    end

    if not best then
        return nil
    end

    local safeBuffer = math.max(buffer or 0, 4)
    local ingressX = best.x + (best.dx or 0) * safeBuffer
    local ingressZ = best.z + (best.dz or 0) * safeBuffer

    local ingress = ClampToPlayableArea({ ingressX, 0, ingressZ }, area, safeBuffer)
    return ingress, best.edge, best
end

local function BuildIngressCandidates(startPos, area, buffer, destination)
    local ingress, edge, edgeInfo = ComputeNearestEdgeIngress(startPos, area, buffer)
    if not (ingress and area) then
        return {}, edge
    end

    local minX, minZ, maxX, maxZ = area[1], area[2], area[3], area[4]
    local safeBuffer = math.max(buffer or 0, 4)

    local function addCandidate(list, candidate)
        if not candidate then
            return
        end
        for _, existing in ipairs(list) do
            if DistanceSq(existing, candidate) <= 4 then
                return
            end
        end
        table.insert(list, candidate)
    end

    local candidates = {}
    addCandidate(candidates, ingress)

    local sampleRatios = { 0.25, 0.5, 0.75 }
    local inward = {
        left = { 1, 0 },
        right = { -1, 0 },
        bottom = { 0, 1 },
        top = { 0, -1 },
    }

    if edgeInfo and inward[edgeInfo.edge] then
        local dir = inward[edgeInfo.edge]

        if edgeInfo.edge == 'top' or edgeInfo.edge == 'bottom' then
            for _, ratio in ipairs(sampleRatios) do
                local x = minX + (maxX - minX) * ratio
                local z = (edgeInfo.edge == 'top') and maxZ or minZ
                local probe = ClampToPlayableArea({ x + dir[1] * safeBuffer, 0, z + dir[2] * safeBuffer }, area, safeBuffer)
                addCandidate(candidates, probe)
            end
        else
            for _, ratio in ipairs(sampleRatios) do
                local x = (edgeInfo.edge == 'left') and minX or maxX
                local z = minZ + (maxZ - minZ) * ratio
                local probe = ClampToPlayableArea({ x + dir[1] * safeBuffer, 0, z + dir[2] * safeBuffer }, area, safeBuffer)
                addCandidate(candidates, probe)
            end
        end

        if destination then
            local projected = nil
            if edgeInfo.edge == 'top' or edgeInfo.edge == 'bottom' then
                local z = (edgeInfo.edge == 'top') and maxZ or minZ
                projected = ClampToPlayableArea({ destination[1] + dir[1] * safeBuffer, 0, z + dir[2] * safeBuffer }, area, safeBuffer)
            else
                local x = (edgeInfo.edge == 'left') and minX or maxX
                projected = ClampToPlayableArea({ x + dir[1] * safeBuffer, 0, destination[3] + dir[2] * safeBuffer }, area, safeBuffer)
            end
            addCandidate(candidates, projected)
        end
    end

    return candidates, edge
end

local function ClosestReachableIngress(startPos, area, layer)
    if not (startPos and area) then
        return nil
    end

    local ingress = ComputeNearestEdgeIngress(startPos, area, PlayableIngressBuffer)
    return ingress
end

local function NearestPlayablePointOnPath(startPos, path, area, layer)
    if PositionInPlayableArea(startPos, area) then
        return SurfacePoint(startPos)
    end

    local entryPoint = ClosestReachableIngress(startPos, area, layer)

    if path and table.getn(path) > 0 then
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
                table.remove(path, 1)
            end

            for i = table.getn(path), 1, -1 do
                if not PositionInPlayableArea(path[i], area) then
                    path[i] = ClampToPlayableArea(path[i], area, PlayableIngressBuffer)
                end
            end
        else
            for i = table.getn(path), 1, -1 do
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
                table.insert(enemies, idx)
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
            table.insert(filtered, idx)
        end
    end

    -- fall back to all enemies if filter didn't match anything
    return (table.getn(filtered) > 0) and filtered or enemies
end


local function AreaUnits(brain, enemies, position, radius, category, intelOnly)
    if not position then return {} end
    radius = radius or 1

    -- Intel path: current behaviour (uses fog-of-war)
    if intelOnly then
        local list = brain:GetUnitsAroundPoint(category, position, radius, 'Enemy') or {}
        if not enemies or table.getn(enemies) == 0 then
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
                    table.insert(units, unit)
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
                            table.insert(units, unit)
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
            table.insert(out, unit)
        end
    end
    return out
end

local function ScoreStructureCluster(units, mode, distance)
    if table.getn(units) == 0 then
        return -(math.huge or 1e9)
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
        return table.getn(units)
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
            table.insert(results, { pos = pos, threat = threat })
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
        return string.format('%d:%d', math.floor(pos[1] / FloodFillCell), math.floor(pos[3] / FloodFillCell))
    end

    while table.getn(queue) > 0 do
        local pos = table.remove(queue, 1)
        local k = key(pos)
        if not visited[k] then
            visited[k] = true
            table.insert(results, { pos = pos })
            if Distance(startPos, pos) < FloodFillMaxRadius then
                local offsets = {
                    { FloodFillCell, 0, 0 },
                    { -FloodFillCell, 0, 0 },
                    { 0, 0, FloodFillCell },
                    { 0, 0, -FloodFillCell },
                }
                for _, off in ipairs(offsets) do
                    local nextPos = VectorAdd(pos, off)
                    nextPos[1] = math.min(math.max(nextPos[1], 0), size[1])
                    nextPos[3] = math.min(math.max(nextPos[3], 0), size[2])
                    nextPos[2] = GetSurfaceHeight(nextPos[1], nextPos[3])
                    table.insert(queue, nextPos)
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
        if math.abs(ta - tb) < 0.001 then
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
    local minThreat = (math.huge or 1e9)

    for _, structure in ipairs(structures) do
        if structure and not structure.Dead then
            local pos = structure:GetPosition()
            if pos then
                local threat = DefenseThreatNear(brain, pos, layer)
                threat = tonumber(threat) or 0
                minThreat = math.min(minThreat, threat)
                table.insert(scored, { unit = structure, threat = threat })
            end
        end
    end

    if table.getn(scored) == 0 then
        return {}
    end

    table.sort(scored, function(a, b)
        if math.abs(a.threat - b.threat) < 0.001 then
            return (a.unit.EntityId or 0) < (b.unit.EntityId or 0)
        end
        return a.threat < b.threat
    end)

    local threshold = minThreat + 0.1
    local selected = {}
    for _, entry in ipairs(scored) do
        if entry.threat <= threshold then
            table.insert(selected, entry.unit)
        else
            break
        end
    end

    if table.getn(selected) == 0 then
        table.insert(selected, scored[1].unit)
    end

    return selected
end

local CanPathTo

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
            if table.getn(units) > 0 then
                if not opts.Transport and not CanPathTo(platoon, layer, pos) then
                    -- Skip unreachable areas so wave attacks don't repeatedly
                    -- retarget locations they cannot move toward.
                    units = {}
                end
            end

            if table.getn(units) > 0 then
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
                            local count = table.getn(units)
                            if count > 0 then
                                local score = count / math.max(1, threat + 1)
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
                            if table.getn(selected) > 0 then
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
                    local bestThreat   = (math.huge or 1e9)   -- lowest local defence wins
                    local bestDistance = (math.huge or 1e9)   -- tie-breaker: closer is better
                    local bestCount    = -1          -- secondary tie-breaker: more eco in that area

                    for _, entry in ipairs(candidates) do
                        local pos = entry.pos
                        if pos then
                            local units = AreaUnits(brain, enemies, pos, RaidAreaRadius, category, opts.IntelOnly)
                            units = FilterUnits(units, layer, opts.Submersible)
                            local count = table.getn(units)
                            if count > 0 then
                                -- Find the least defended structure *in this area*
                                local selected = LeastDefendedStructures(brain, layer, units)
                                if table.getn(selected) > 0 then
                                    local structure = selected[1]
                                    if structure and not structure.Dead then
                                        local sPos        = structure:GetPosition()
                                        local localThreat = DefenseThreatNear(brain, sPos, layer)
                                        local distance    = Distance(startPos, sPos)

                                        -- Compare by threat, then by distance, then by how much eco is nearby
                                        local better =
                                            (localThreat < bestThreat - 0.001) or
                                            (math.abs(localThreat - bestThreat) < 0.001 and distance < bestDistance - 0.1) or
                                            (math.abs(localThreat - bestThreat) < 0.001 and math.abs(distance - bestDistance) < 0.1 and count > bestCount)

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

CanPathTo = function(platoon, layer, destination)
    if not (Routing and Routing.CanPathTo) then
        return false
    end
    return Routing.CanPathTo(platoon, layer, destination)
end

CanPathBetween = function(layer, a, b)
    if not (Routing and Routing.CanPathBetween) then
        return false
    end
    return Routing.CanPathBetween(layer, a, b)
end

local function BuildPathSegment(layer, startPos, destination)
    if not (Routing and Routing.BuildPathSegment) then
        return nil
    end
    return Routing.BuildPathSegment(layer, startPos, destination)
end

local function FindSafePath(platoon, layer, destination, startOverride, opts)
    if not (Routing and Routing.FindSafePath) then
        return nil
    end
    return Routing.FindSafePath(platoon, layer, destination, startOverride, CopyOptions(opts))
end

local function RecomputePathWithFallback(platoon, layer, destination, opts)
    if not (Routing and Routing.RecomputePathWithFallback) then
        return nil
    end
    return Routing.RecomputePathWithFallback(platoon, layer, destination, CopyOptions(opts))
end

ClampPathToPlayableArea = function(path, buffer)
    return path
end

local function MoveAlongPath(platoon, path, formation, aggressiveFinal, layer, aggressiveRoute)
    if not (Routing and Routing.MoveAlongPath) then
        return false
    end
    return Routing.MoveAlongPath(platoon, path, formation, aggressiveFinal, layer, aggressiveRoute)
end

local function MoveToNearestPlayableIngress(platoon, layer, area, formation, destination)
    if not (Routing and Routing.MoveToNearestPlayableIngress) then
        return false, nil, nil
    end
    return Routing.MoveToNearestPlayableIngress(platoon, layer, area, formation, destination)
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
        drop[1] = math.min(math.max(drop[1] - TransportStagingOffset, 0), size[1])
        drop[3] = math.min(math.max(drop[3] - TransportStagingOffset, 0), size[2])
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

local function UpdateStructureAttacks(platoon, target, opts, brain, enemyBrains, layer, issuedTargets)
    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
        return 'fail'
    end

    local category = target.category or StructureCategory
    local combined = {}
    if target.units then
        for _, structure in ipairs(target.units) do
            table.insert(combined, structure)
        end
    end

    local restrictStructures = target and target.restrictStructures
    if not restrictStructures then
        local radius = (target.radius or 0) + AreaClearRadius
        local areaUnits = AreaUnits(brain, enemyBrains, target.position, radius, category, opts.IntelOnly) or {}
        for _, structure in ipairs(areaUnits) do
            table.insert(combined, structure)
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
                table.insert(remaining, structure)
            end
        end
    end

    if table.getn(remaining) == 0 then
        return 'success'
    end

    local newTargets = {}
    for _, structure in ipairs(remaining) do
        local id = structure.EntityId
        if id and not issuedTargets[id] then
            issuedTargets[id] = true
            table.insert(newTargets, structure)
        end
    end

    if table.getn(newTargets) > 0 then
        for _, structure in ipairs(newTargets) do
            if structure and not structure.Dead then
                IssueAttack(units, structure)
            end
        end
    end

    return 'continue'
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

    local targetPos = target.position
    if area then
        targetPos = ClampToPlayableArea(targetPos, area, 0)
    else
        targetPos = CopyVector(targetPos)
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
        local ingressReached, ingress, ingressEdge
        ingressReached, ingress, ingressEdge = MoveToNearestPlayableIngress(platoon, layer, area, opts.Formation, targetPos)
        if not ingressReached then
            return 'repath'
        end

        local currentPos = GetPlatoonPosition(platoon)
        if area and currentPos then
            currentPos = ClampToPlayableArea(currentPos, area, 0)
        end

        local routeStart = currentPos or ingress

        path = FindSafePath(platoon, layer, targetPos, routeStart, opts)
        if not (path and table.getn(path) > 0) then
            path = BuildPathSegment(layer, routeStart, targetPos)
        end

        if path and table.getn(path) > 1 and area and currentPos then
            local currentEdgeDistance = DistanceToPlayableEdge(currentPos, area)
            while table.getn(path) > 1 do
                local first = path[1]
                if not first then
                    table.remove(path, 1)
                else
                    local firstEdgeDistance = DistanceToPlayableEdge(first, area)
                    if firstEdgeDistance + 1 < currentEdgeDistance then
                        table.remove(path, 1)
                    else
                        break
                    end
                end
            end
        end

    else
        path = FindSafePath(platoon, layer, targetPos, nil, opts)
    end

    local canPath = CanPathTo(platoon, layer, targetPos)
    if not canPath and ingress then
        canPath = CanPathBetween(layer, ingress, targetPos)
    end
    if not canPath then
        if opts.Transport then
            if not TransportAndMove(platoon, targetPos, opts) then
                return 'fail'
            end
            path = FindSafePath(platoon, layer, targetPos, nil, opts)
        else
            return 'fail'
        end
    elseif not path then
        path = FindSafePath(platoon, layer, targetPos, nil, opts)
    end

    if not path then
        return 'fail'
    end

    if bombardRange then
        path = ShortenPathForBombard(path, targetPos, bombardRange)
    end

    local issued = MoveAlongPath(platoon, path, opts.Formation, false, layer, opts.AggressiveMove)
    if not issued then
        RoutingLog('Initial path issue failed; attempting repath')
        path = RecomputePathWithFallback(platoon, layer, targetPos, opts)
        if not path then
            if opts.Transport then
                RoutingLog('Path repath failed; attempting transport fallback')
                if not TransportAndMove(platoon, targetPos, opts) then
                    return 'repath'
                end
                path = RecomputePathWithFallback(platoon, layer, targetPos, opts)
            end
        end

        if not path then
            return 'repath'
        end

        if bombardRange then
            path = ShortenPathForBombard(path, targetPos, bombardRange)
        end

        issued = MoveAlongPath(platoon, path, opts.Formation, false, layer, opts.AggressiveMove)
        if not issued then
            return 'repath'
        end
    end

    local arrived = false
    local epsilon = 5
    local attackTransitionRadius = (target.radius or 0) + 40
    local units = platoon:GetPlatoonUnits() or {}
    local stuckSeconds = 0
    local lastPos = GetPlatoonPosition(platoon)
    local lastDistSq = lastPos and DistanceSq(lastPos, targetPos) or nil
    while PlatoonAlive(platoon) do
        local pos = GetPlatoonPosition(platoon)
        if not pos then break end
        local arrivalRadius = target.radius + epsilon
        if attackTransitionRadius > arrivalRadius then
            arrivalRadius = attackTransitionRadius
        end
        if bombardRange and bombardRange > arrivalRadius then
            arrivalRadius = bombardRange
        end
        if DistanceSq(pos, targetPos) < (arrivalRadius * arrivalRadius) then
            arrived = true
            break
        end
        SafeWait(1)
        local updatedPos = GetPlatoonPosition(platoon)
        if not updatedPos then break end
        local distSq = DistanceSq(updatedPos, targetPos)
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
    if table.getn(units) == 0 then
        return 'fail'
    end

    IssueClearCommands(units)
    local formation = opts.Formation or 'GrowthFormation'
    if opts.Bombard and bombardRange then
        platoon:SetPlatoonFormationOverride(formation)
        -- Hold position and engage at range
    else
        -- Final assault stage: always transition into combat movement so platoons
        -- push through the approach ring instead of idling at the perimeter.
        if formation ~= 'NoFormation' then
            platoon:SetPlatoonFormationOverride(formation)
        else
            platoon:SetPlatoonFormationOverride('NoFormation')
        end
        local finalAggressive = target and target.finalAggressiveMove
        if finalAggressive == nil then
            finalAggressive = true
        end
        if finalAggressive then
            if formation ~= 'NoFormation' then
                local approachDegrees = HeadingDegrees(GetPlatoonPosition(platoon), targetPos)
                IssueFormAggressiveMove(units, targetPos, formation, approachDegrees)
            else
                IssueAggressiveMove(units, targetPos)
            end
        else
            IssueMove(units, targetPos)
        end
    end

    local issuedTargets = {}
    local enemyBrains = BrainEnemies(brain, opts.TargetArmy)
    local attackState = UpdateStructureAttacks(platoon, target, opts, brain, enemyBrains, layer, issuedTargets)
    if attackState == 'fail' then
        return 'fail'
    end

    while PlatoonAlive(platoon) and attackState ~= 'success' do
        SafeWait(3)
        attackState = UpdateStructureAttacks(platoon, target, opts, brain, enemyBrains, layer, issuedTargets)
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

    local area = GetPlayableArea()
    local minX = 0
    local minZ = 0
    local maxX = 512
    local maxZ = 512

    if area then
        minX = area[1]
        minZ = area[2]
        maxX = area[3]
        maxZ = area[4]
    else
        local size = ScenarioInfo.size or ScenarioInfo.MapSize or { 512, 512 }
        maxX = size[1]
        maxZ = size[2]
    end

    local x = math.random(minX, maxX)
    local z = math.random(minZ, maxZ)
    local y = GetSurfaceHeight(x, z)
    return ClampToPlayableArea({ x, y, z }, area, PlayableIngressBuffer)
end

local function HottestColdestPosition(brain, hottest)
    if not ScenarioInfo then
        return RandomPoint()
    end
    local size = ScenarioInfo.size or ScenarioInfo.MapSize or { 512, 512 }
    local start = { size[1] * 0.5, 0, size[2] * 0.5 }
    start[2] = GetSurfaceHeight(start[1], start[3])
    local list = FindThreatLocations(brain, start, 'Air')
    if table.getn(list) == 0 then
        return RandomPoint()
    end
    table.sort(list, function(a, b)
        if hottest then
            return (a.threat or 0) > (b.threat or 0)
        else
            return (a.threat or 0) < (b.threat or 0)
        end
    end)
    local area = GetPlayableArea()
    return ClampToPlayableArea(CopyVector(list[1].pos), area, PlayableIngressBuffer)
end

local function SelectScoutDestination(brain, opts)
    local roll = math.random()
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
        local x = center[1] + math.cos(angle) * radius
        local z = center[3] + math.sin(angle) * radius
        local y = GetSurfaceHeight(x, z)
        table.insert(list, { x, y, z })
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
            table.insert(list, cat)
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
    if not (unit and categoriesList and table.getn(categoriesList) > 0) then
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
            table.insert(points, { pos[1], pos[2] or GetSurfaceHeight(pos[1], pos[3]), pos[3] })
        end
    end
    return points
end

local function NormalizePatrolPoints(points, layer)
    local out = {}
    for _, pos in ipairs(points or {}) do
        if pos and pos[1] and pos[3] then
            local y = AmphibiousSurfaceHeight(layer, pos[1], pos[3])
            table.insert(out, { pos[1], y, pos[3] })
        end
    end
    return out
end

local function BuildPingPongRoute(points)
    local out = {}
    local count = table.getn(points)
    for i = 1, count do
        table.insert(out, points[i])
    end
    for i = count - 1, 2, -1 do
        table.insert(out, points[i])
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
                    table.insert(locations, { marker = marker, group = group })
                end
            end
        end
    elseif type(data.Markers) == 'table' then
        local groups = data.Groups or data.StructureGroups or data.GroupNames
        for i, marker in ipairs(data.Markers) do
            table.insert(locations, { marker = marker, group = groups and groups[i] or nil })
        end
    end

    return locations
end

local function FirebaseLocationSafe(brain, pos, safeRadius, opts)
    local enemies = BrainEnemies(brain, opts and opts.TargetArmy)
    local units = AreaUnits(brain, enemies, pos, safeRadius, categories.ALLUNITS, opts and opts.IntelOnly)
    return table.getn(units) == 0
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
                table.insert(missing, { bp = bp, pos = pos, facing = facing })
            end
        end
    end
    return missing
end

local function IssueFirebaseBuilds(platoon, builds)
    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
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
    if table.getn(units) == 0 then return end
    IssueClearCommands(units)
    if layer == 'Air' then
        local waypoints = OrbitWaypoints(markerPos, HuntOrbitPoints, HuntOrbitRadius)
        for _, point in ipairs(waypoints) do
            IssuePatrol(units, point)
        end
        if table.getn(waypoints) > 0 then
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

local function IssuePatrolRoute(platoon, points, formation)
    if not (platoon and points and table.getn(points) > 0) then
        return
    end
    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
        return
    end

    IssueClearCommands(units)
    platoon:SetPlatoonFormationOverride(formation or 'GrowthFormation')

    IssueMove(units, points[1])

    for i = 2, table.getn(points) do
        local point = points[i]
        IssuePatrol(units, point)
    end

    -- close the loop
    IssuePatrol(units, points[1])
end

local function BuildLoopRoute(points)
    local route = {}
    for _, point in ipairs(points or {}) do
        table.insert(route, point)
    end

    if table.getn(route) > 1 then
        table.insert(route, route[1])
    end

    return route
end

local function BuildPerimeterPoints(layer, basePos, distance)
    local points = {}
    local count = 6
    for i = 1, count do
        local angle = (i / count) * 6.28318
        local x = basePos[1] + math.cos(angle) * distance
        local z = basePos[3] + math.sin(angle) * distance
        local point = { x, AmphibiousSurfaceHeight(layer, x, z), z }
        if CanPathBetween(layer, basePos, point) then
            table.insert(points, point)
        end
    end

    if table.getn(points) == 0 then
        table.insert(points, basePos)
    end
    return points
end

local function FindIntruder(brain, layer, basePos, interceptRadius, opts)
    local enemies = BrainEnemies(brain, opts and opts.TargetArmy)
    local units = AreaUnits(brain, enemies, basePos, interceptRadius, categories.ALLUNITS, opts and opts.IntelOnly)
    units = FilterUnits(units, layer, opts and opts.Submersible)

    local closest
    local closestDist = (math.huge or 1e9)
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
    local hasCategories = opts and opts.HuntCategories and table.getn(opts.HuntCategories) > 0
    if not (brain and platoon and (hasBlueprints or hasCategories)) then
        return nil
    end
    local startPos = GetPlatoonPosition(platoon)
    if not startPos then
        return nil
    end
    local enemies = BrainEnemies(brain, opts.TargetArmy)
    local excludedSet = excluded or {}
    local best, bestDist = nil, (math.huge or 1e9)
    local bestSafe, bestSafeDist = nil, (math.huge or 1e9)
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
                    MoveAlongPath(platoon, path, opts.Formation, true, nil, opts.AggressiveMove)
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
            if table.getn(units) == 0 then
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
    opts.AggressiveMove = opts.AggressiveMove and true or false
    if not data or data.RandomizeRoute == nil then
        opts.RandomizeRoute = false
    end
    opts.Type = opts.Type or opts.TargetType or 'closest'
    local function resolver(brain, p, o, layer)
        return ChooseBestArea(brain, p, o, layer, WaveAreaRadius, opts.Type, StructureCategory)
    end
    AttackLoop(platoon, resolver, opts)
end

function RaidAttack(platoon, data)
    local opts = CopyOptions(data)
    opts.AggressiveMove = opts.AggressiveMove and true or false
    if not data or data.RandomizeRoute == nil then
        opts.RandomizeRoute = false
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
    if table.getn(units) == 0 then return end

    local state = {}
    for _, unit in ipairs(units) do
        state[unit.EntityId] = { destination = SelectScoutDestination(brain, opts) }
        AssignScoutOrder(unit, state[unit.EntityId].destination)
    end

    while PlatoonAlive(platoon) do
        SafeWait(ScoutRecheckDelay)
        units = platoon:GetPlatoonUnits() or {}
        if table.getn(units) == 0 then break end
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
    opts.AggressiveMove = true
    local layer = DetermineLayer(platoon, opts.Amphibious)
    if not layer then return end

    local chainName = data and (data.Chain or data.ChainName or data.PatrolChain or data.MarkerChain)
    local points = ResolveChainPositions(chainName)

    if data and type(data.Markers) == 'table' then
        for _, marker in ipairs(data.Markers) do
            local pos = ResolveMarkerPosition(marker)
            if pos then
                table.insert(points, pos)
            end
        end
    end

    points = NormalizePatrolPoints(points, layer)
    if table.getn(points) < 2 then
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

    local useFormationMoves = layer ~= 'Air' and opts.Formation and opts.Formation ~= 'NoFormation'
    if useFormationMoves then
        local arrivalRadiusSq = 20 * 20
        local maxTravelSeconds = 120
        local routeCount = table.getn(route)
        local index = 1

        while PlatoonAlive(platoon) do
            local destination = route[index]
            if not destination then
                break
            end

            local path = FindSafePath(platoon, layer, destination, nil, opts)
            if path then
                MoveAlongPath(platoon, path, opts.Formation, false, nil, opts.AggressiveMove)
            else
                MoveAlongPath(platoon, { destination }, opts.Formation, false, nil, opts.AggressiveMove)
            end

            local elapsed = 0
            while PlatoonAlive(platoon) do
                local pos = GetPlatoonPosition(platoon)
                if pos and destination and DistanceSq(pos, destination) <= arrivalRadiusSq then
                    break
                end

                elapsed = elapsed + 1
                if elapsed >= maxTravelSeconds then
                    break
                end
                SafeWait(1)
            end

            index = index + 1
            if index > routeCount then
                index = 1
            end

            SafeWait(1)
        end
    else
        IssuePatrolRoute(platoon, route, opts.Formation)

        while PlatoonAlive(platoon) do
            SafeWait(RecheckDelay)
        end
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
                if table.getn(missing) > 0 then
                    acted = true
                    local path = FindSafePath(platoon, layer, pos, nil, opts)
                    if path then
                        MoveAlongPath(platoon, path, opts.Formation, true)
                    else
                        local units = platoon:GetPlatoonUnits() or {}
                        if table.getn(units) > 0 then
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
                    if table.getn(units) > 0 then
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
    opts.AggressiveMove = opts.AggressiveMove and true or false
    opts.Vulnerable = opts.Vulnerable and true or false
    local blueprintData = data and (data.Blueprints or data.Blueprint or data.TargetBlueprints or data.TargetBPs or data.TargetBP)
    opts.HuntSet = NormalizeBlueprintSet(blueprintData)
    opts.HuntCategories = NormalizeCategoryList(data and (data.Category or data.Categories or data.TargetCategory or data.TargetCategories))
    if not (next(opts.HuntSet) or table.getn(opts.HuntCategories) > 0) then
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
    opts.AggressiveMove = true
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
                    MoveAlongPath(platoon, path, opts.Formation, true, nil, opts.AggressiveMove)
                else
                    local units = platoon:GetPlatoonUnits() or {}
                    if table.getn(units) > 0 then
                        if opts.Formation and opts.Formation ~= 'NoFormation' then
                            local interceptDegrees = HeadingDegrees(GetPlatoonPosition(platoon), targetPos)
                            IssueFormAggressiveMove(units, targetPos, opts.Formation, interceptDegrees)
                        else
                            IssueAggressiveMove(units, targetPos)
                        end
                    end
                end

                local units = platoon:GetPlatoonUnits() or {}
                if table.getn(units) > 0 then
                    IssueAttack(units, intruder)
                end

                local elapsed = 0
                local maxIntercept = math.max(interceptRadius * 1.5, interceptRadius + 32)
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