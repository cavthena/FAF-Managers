local NavUtils = import('/lua/sim/NavUtils.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local RouteCache = {}
local RouteStamp = 0
local Metrics = {
    routeQueries = 0,
    astarSearches = 0,
    fallbackPathTo = 0,
    disconnectedFastFails = 0,
}

local ArrivalDistanceSq = 14 * 14
local WaypointTimeoutSeconds = 90
local StuckSeconds = 12
local RepathTargetDeltaSq = 16 * 16

local function Vec(x, y, z)
    return { x or 0, y or 0, z or 0 }
end

local function CopyVec(v)
    if not v then
        return nil
    end
    return { v[1] or 0, v[2] or 0, v[3] or 0 }
end

local function DistanceSq(a, b)
    if not (a and b) then
        return math.huge
    end
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return (dx * dx) + (dz * dz)
end

local function Distance(a, b)
    return math.sqrt(DistanceSq(a, b))
end

local function Normalize2(dx, dz)
    local mag = math.sqrt((dx * dx) + (dz * dz))
    if mag < 0.001 then
        return 0, 0
    end
    return dx / mag, dz / mag
end

local function HeadingDegrees(a, b)
    if not (a and b) then
        return 0
    end
    return math.deg(math.atan2((b[1] or 0) - (a[1] or 0), (b[3] or 0) - (a[3] or 0)))
end

local function PlatoonAlive(platoon)
    local brain = platoon and platoon:GetBrain()
    return brain and brain.PlatoonExists and brain:PlatoonExists(platoon)
end

local function GetPlatoonPosition(platoon)
    if not platoon then
        return nil
    end
    if platoon.GetPlatoonPosition then
        return platoon:GetPlatoonPosition()
    end
    local units = platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    if units and units[1] and not units[1].Dead then
        return units[1]:GetPosition()
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

local function PositionInPlayableArea(pos, area)
    if not (pos and area) then
        return true
    end
    return pos[1] >= area[1] and pos[1] <= area[3] and pos[3] >= area[2] and pos[3] <= area[4]
end

local function ClampToPlayableArea(pos, area, margin)
    if not (pos and area) then
        return CopyVec(pos)
    end
    margin = margin or 0
    local x = math.max(area[1] + margin, math.min(area[3] - margin, pos[1]))
    local z = math.max(area[2] + margin, math.min(area[4] - margin, pos[3]))
    return Vec(x, pos[2] or GetTerrainHeight(x, z), z)
end

local function DetermineLayer(platoon, opts)
    if opts and opts.RouteLayer then
        return opts.RouteLayer
    end

    if platoon then
        if platoon.MovementLayer and platoon.MovementLayer ~= 'Amphibious' then
            return platoon.MovementLayer
        end

        local movementLayer = platoon.GetNavigationalLayer and platoon:GetNavigationalLayer()
        if movementLayer then
            return movementLayer
        end
    end

    return 'Land'
end

local function IsAggressiveForWaypoint(defaultAggressive, waypointIndex, waypointCount, aggressiveFinal)
    if waypointIndex == waypointCount then
        if aggressiveFinal ~= nil then
            return aggressiveFinal and true or false
        end
        return defaultAggressive and true or false
    end
    return defaultAggressive and true or false
end

local function CanPathBetween(layer, a, b)
    if not (layer and a and b) then
        return false
    end
    local ok, result = pcall(NavUtils.CanPathTo, layer, a, b)
    return ok and result and true or false
end

local function BuildPathSegment(layer, startPos, destination)
    if not (layer and startPos and destination) then
        return nil
    end

    Metrics.astarSearches = Metrics.astarSearches + 1
    local ok, path = pcall(NavUtils.PathTo, layer, startPos, destination)
    if ok and type(path) == 'table' and table.getn(path) > 0 then
        local out = {}
        for _, p in ipairs(path) do
            table.insert(out, CopyVec(p))
        end
        return out
    end

    if CanPathBetween(layer, startPos, destination) then
        return { CopyVec(destination) }
    end

    return nil
end

local function PathClearanceScore(layer, point, probe)
    probe = probe or 6
    local score = 0
    local dirs = {
        { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
        { 0.707, 0.707 }, { -0.707, 0.707 }, { 0.707, -0.707 }, { -0.707, -0.707 },
    }

    for _, d in ipairs(dirs) do
        local sx = (point[1] or 0) + (d[1] * probe)
        local sz = (point[3] or 0) + (d[2] * probe)
        local sample = Vec(sx, GetTerrainHeight(sx, sz), sz)
        if CanPathBetween(layer, point, sample) then
            score = score + 1
        end
    end

    return score
end

local function NudgePointForClearance(layer, prevPoint, point, nextPoint)
    if not point then
        return nil
    end

    local fx, fz = 0, 1
    if prevPoint and nextPoint then
        fx, fz = Normalize2((nextPoint[1] or 0) - (prevPoint[1] or 0), (nextPoint[3] or 0) - (prevPoint[3] or 0))
        if fx == 0 and fz == 0 then
            fx, fz = 0, 1
        end
    end

    local px, pz = -fz, fx
    local candidates = {
        CopyVec(point),
        Vec(point[1] + (px * 3), point[2], point[3] + (pz * 3)),
        Vec(point[1] - (px * 3), point[2], point[3] - (pz * 3)),
        Vec(point[1] + (px * 6), point[2], point[3] + (pz * 6)),
        Vec(point[1] - (px * 6), point[2], point[3] - (pz * 6)),
        Vec(point[1] + (fx * 2), point[2], point[3] + (fz * 2)),
        Vec(point[1] - (fx * 2), point[2], point[3] - (fz * 2)),
    }

    local best = CopyVec(point)
    local bestScore = -1e9
    local original = CopyVec(point)

    for _, candidate in ipairs(candidates) do
        candidate[2] = GetTerrainHeight(candidate[1], candidate[3])

        local valid = true
        if prevPoint and not CanPathBetween(layer, prevPoint, candidate) then
            valid = false
        end
        if valid and nextPoint and not CanPathBetween(layer, candidate, nextPoint) then
            valid = false
        end

        if valid then
            local clearance = PathClearanceScore(layer, candidate, 5)
            local driftPenalty = Distance(candidate, original) * 0.45
            local score = clearance - driftPenalty
            if score > bestScore then
                bestScore = score
                best = candidate
            end
        end
    end

    return best
end

local function ShapePathForClearance(layer, path)
    if type(path) ~= 'table' or table.getn(path) < 3 then
        return path
    end

    local shaped = {}
    for i, point in ipairs(path) do
        if i == 1 or i == table.getn(path) then
            table.insert(shaped, CopyVec(point))
        else
            local prevPoint = path[i - 1]
            local nextPoint = path[i + 1]
            table.insert(shaped, NudgePointForClearance(layer, prevPoint, point, nextPoint) or CopyVec(point))
        end
    end

    return shaped
end

local function SimplifyPath(path)
    if type(path) ~= 'table' or table.getn(path) == 0 then
        return nil
    end

    local out = {}
    for _, point in ipairs(path) do
        if not out[1] or DistanceSq(out[table.getn(out)], point) > (3 * 3) then
            table.insert(out, CopyVec(point))
        end
    end

    if table.getn(out) == 0 then
        return nil
    end

    return out
end

local function ResolveChainNames(platoon, opts)
    local names = {}
    local seen = {}

    local function addValue(value)
        if type(value) == 'string' and value ~= '' then
            if not seen[value] then
                seen[value] = true
                table.insert(names, value)
            end
        elseif type(value) == 'table' then
            for _, entry in ipairs(value) do
                addValue(entry)
            end
        end
    end

    local pdata = platoon and platoon.PlatoonData or nil
    addValue(opts and (opts.RouteChains or opts.RouteChain or opts.MarkerChains or opts.MarkerChain or opts.ChainNames or opts.ChainName or opts.Chain))
    addValue(pdata and (pdata.RouteChains or pdata.RouteChain or pdata.MarkerChains or pdata.MarkerChain or pdata.ChainNames or pdata.ChainName or pdata.Chain))

    return names
end

local function ChainToPositions(chainName)
    if type(chainName) ~= 'string' or chainName == '' then
        return nil
    end

    local ok, positions = pcall(ScenarioUtils.ChainToPositions, chainName)
    if not ok or type(positions) ~= 'table' then
        return nil
    end

    local out = {}
    for _, pos in ipairs(positions) do
        if pos then
            table.insert(out, CopyVec(pos))
        end
    end

    if table.getn(out) == 0 then
        return nil
    end

    return out
end

local function BuildRouteFromPoints(layer, startPos, points, target)
    local cursor = CopyVec(startPos)
    local waypoints = {}

    local function appendSegment(dest)
        local segment = BuildPathSegment(layer, cursor, dest)
        if not segment then
            return false
        end
        for _, p in ipairs(segment) do
            table.insert(waypoints, CopyVec(p))
        end
        cursor = CopyVec(dest)
        return true
    end

    for _, point in ipairs(points or {}) do
        if not appendSegment(point) then
            return nil
        end
    end

    if not appendSegment(target) then
        return nil
    end

    return waypoints
end

local function BuildRandomizedAlternates(layer, startPos, targetPos)
    local dx = (targetPos[1] or 0) - (startPos[1] or 0)
    local dz = (targetPos[3] or 0) - (startPos[3] or 0)
    local nx, nz = Normalize2(dx, dz)
    local px, pz = -nz, nx
    local dist = math.max(18, math.min(96, Distance(startPos, targetPos) * 0.28))

    local midX = ((startPos[1] or 0) + (targetPos[1] or 0)) * 0.5
    local midZ = ((startPos[3] or 0) + (targetPos[3] or 0)) * 0.5

    local mids = {
        Vec(midX + (px * dist), GetTerrainHeight(midX + (px * dist), midZ + (pz * dist)), midZ + (pz * dist)),
        Vec(midX - (px * dist), GetTerrainHeight(midX - (px * dist), midZ - (pz * dist)), midZ - (pz * dist)),
        Vec(midX + (px * dist * 0.55), GetTerrainHeight(midX + (px * dist * 0.55), midZ + (pz * dist * 0.55)), midZ + (pz * dist * 0.55)),
        Vec(midX - (px * dist * 0.55), GetTerrainHeight(midX - (px * dist * 0.55), midZ - (pz * dist * 0.55)), midZ - (pz * dist * 0.55)),
    }

    local alternates = {}
    for _, mid in ipairs(mids) do
        if CanPathBetween(layer, startPos, mid) and CanPathBetween(layer, mid, targetPos) then
            local route = BuildRouteFromPoints(layer, startPos, { mid }, targetPos)
            if route then
                table.insert(alternates, route)
            end
        end
    end

    return alternates
end

local function CreateIngressWaypoint(area, position, destination)
    if not (area and position) then
        return nil
    end

    local clamped = ClampToPlayableArea(position, area, 6)
    if not destination then
        return clamped
    end

    local dx = (destination[1] or 0) - (clamped[1] or 0)
    local dz = (destination[3] or 0) - (clamped[3] or 0)
    local nx, nz = Normalize2(dx, dz)

    local ingress = Vec(
        clamped[1] + (nx * 10),
        GetTerrainHeight(clamped[1] + (nx * 10), clamped[3] + (nz * 10)),
        clamped[3] + (nz * 10)
    )

    return ClampToPlayableArea(ingress, area, 4)
end

local function BuildRoute(platoon, startPos, targetPos, opts)
    Metrics.routeQueries = Metrics.routeQueries + 1

    local layer = DetermineLayer(platoon, opts)
    local area = GetPlayableArea()
    local start = CopyVec(startPos or GetPlatoonPosition(platoon))
    local target = CopyVec(targetPos)

    if not (start and target) then
        Metrics.disconnectedFastFails = Metrics.disconnectedFastFails + 1
        return nil
    end

    if area then
        target = ClampToPlayableArea(target, area, 0)
    end

    local routeSource = opts and opts.RouteSource or (platoon and platoon.PlatoonData and platoon.PlatoonData.RouteSource) or nil
    local cacheKey = string.format('%s|%s|%d|%d|%d|%d|%s|%s',
        tostring(routeSource or 'none'),
        tostring(layer or 'Land'),
        math.floor((start[1] or 0) / 8),
        math.floor((start[3] or 0) / 8),
        math.floor((target[1] or 0) / 8),
        math.floor((target[3] or 0) / 8),
        tostring(opts and opts.RandomizeRoute and true or false),
        tostring(opts and (opts.RouteChain or opts.Chain or opts.ChainName or opts.MarkerChain) or false)
    )

    if not (opts and opts.ForceRepath) and RouteCache[cacheKey] then
        local cached = RouteCache[cacheKey]
        local copy = {}
        for i, w in ipairs(cached.waypoints or {}) do
            copy[i] = { position = CopyVec(w.position), arrivalFacing = w.arrivalFacing, aggressiveMove = w.aggressiveMove, moveMode = w.moveMode }
        end
        local cloned = {
            stamp = cached.stamp,
            routeType = cached.routeType,
            routeChainUsed = cached.routeChainUsed,
            graphUsed = false,
            waypoints = copy,
            destination = CopyVec(cached.destination),
            aggressiveMove = cached.aggressiveMove,
            randomizeRoute = cached.randomizeRoute,
            routeSource = cached.routeSource,
            startedOutsidePlayableArea = cached.startedOutsidePlayableArea,
            formation = cached.formation,
        }
        platoon._storedRoute = cloned
        return cloned
    end

    local rawPath = nil
    local usedChain = nil

    local chainNames = ResolveChainNames(platoon, opts)
    for _, chainName in ipairs(chainNames) do
        local points = ChainToPositions(chainName)
        if points and table.getn(points) > 0 then
            local candidate = BuildRouteFromPoints(layer, start, points, target)
            if candidate then
                rawPath = candidate
                usedChain = chainName
                break
            end
        end
    end

    if not rawPath then
        local outside = opts and opts.StartedOutsidePlayableArea
        if outside == nil and platoon and platoon.PlatoonData and platoon.PlatoonData.StartedOutsidePlayableArea ~= nil then
            outside = platoon.PlatoonData.StartedOutsidePlayableArea
        end
        local disableIngress = opts and opts.DisableIngress
        if disableIngress == nil and platoon and platoon.PlatoonData and platoon.PlatoonData.DisableIngress ~= nil then
            disableIngress = platoon.PlatoonData.DisableIngress
        end

        local points = {}
        if outside and not disableIngress and area and not PositionInPlayableArea(start, area) then
            local ingress = CreateIngressWaypoint(area, start, target)
            if ingress then
                table.insert(points, ingress)
            end
        end

        rawPath = BuildRouteFromPoints(layer, start, points, target)
    end

    if not rawPath then
        rawPath = BuildPathSegment(layer, start, target)
    end

    if not rawPath then
        if opts and opts.Transport then
            Metrics.fallbackPathTo = Metrics.fallbackPathTo + 1
        else
            Metrics.disconnectedFastFails = Metrics.disconnectedFastFails + 1
        end
        return nil
    end

    if opts and opts.RandomizeRoute then
        local alternates = BuildRandomizedAlternates(layer, start, target)
        if alternates and table.getn(alternates) > 0 then
            table.insert(alternates, 1, rawPath)
            rawPath = alternates[Random(1, table.getn(alternates))]
        end
    end

    rawPath = SimplifyPath(rawPath)
    rawPath = ShapePathForClearance(layer, rawPath)

    if not rawPath or table.getn(rawPath) == 0 then
        return nil
    end

    RouteStamp = RouteStamp + 1
    local route = {
        stamp = RouteStamp,
        routeType = usedChain and 'chain' or 'engine',
        routeChainUsed = usedChain,
        graphUsed = false,
        waypoints = {},
        destination = CopyVec(target),
        aggressiveMove = opts and opts.AggressiveMove and true or false,
        randomizeRoute = opts and opts.RandomizeRoute and true or false,
        routeSource = routeSource,
        startedOutsidePlayableArea = opts and opts.StartedOutsidePlayableArea and true or false,
        formation = opts and opts.Formation or 'GrowthFormation',
    }

    local count = table.getn(rawPath)
    for i, point in ipairs(rawPath) do
        local prev = i > 1 and rawPath[i - 1] or start
        route.waypoints[i] = {
            position = CopyVec(point),
            arrivalFacing = HeadingDegrees(prev, point),
            aggressiveMove = IsAggressiveForWaypoint(route.aggressiveMove, i, count, nil),
            moveMode = IsAggressiveForWaypoint(route.aggressiveMove, i, count, nil) and 'aggressive' or 'move',
        }
    end

    RouteCache[cacheKey] = route
    platoon._storedRoute = route
    return route
end

local function ShouldRepath(platoon, route, opts)
    if not route then
        return true, 'missing_route'
    end

    if opts and opts.ForceRepath then
        return true, 'forced'
    end

    local pos = GetPlatoonPosition(platoon)
    if pos and route.destination and DistanceSq(pos, route.destination) < ArrivalDistanceSq then
        return false, 'arrived'
    end

    local target = opts and opts.TargetPosition
    if target and route.destination and DistanceSq(target, route.destination) > RepathTargetDeltaSq then
        return true, 'target_shifted'
    end

    return false, 'ok'
end

local function IssueWaypointMove(units, waypoint, formation)
    if not (units and waypoint and waypoint.position) then
        return
    end

    local useFormation = formation and formation ~= 'NoFormation'
    if waypoint.aggressiveMove then
        if useFormation then
            IssueFormAggressiveMove(units, waypoint.position, formation, waypoint.arrivalFacing or 0)
        else
            IssueAggressiveMove(units, waypoint.position)
        end
    else
        if useFormation then
            IssueFormMove(units, waypoint.position, formation, waypoint.arrivalFacing or 0)
        else
            IssueMove(units, waypoint.position)
        end
    end
end

local function MoveAlongPath(platoon, path, formation, aggressiveFinal, layer, aggressiveRoute)
    if not PlatoonAlive(platoon) then
        return false
    end

    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
        return false
    end

    IssueClearCommands(units)

    local waypointCount = table.getn(path or {})
    for i, point in ipairs(path or {}) do
        local prev = i > 1 and path[i - 1] or GetPlatoonPosition(platoon) or point
        local waypoint = {
            position = CopyVec(point),
            arrivalFacing = HeadingDegrees(prev, point),
            aggressiveMove = IsAggressiveForWaypoint(aggressiveRoute, i, waypointCount, aggressiveFinal),
        }
        IssueWaypointMove(units, waypoint, formation)
    end

    return true
end

local function FollowRoute(platoon, route, opts)
    if not (PlatoonAlive(platoon) and route and route.waypoints) then
        return 'repath'
    end

    local formation = (opts and opts.Formation) or route.formation or 'GrowthFormation'
    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
        return 'fail'
    end

    IssueClearCommands(units)

    for _, waypoint in ipairs(route.waypoints) do
        units = platoon:GetPlatoonUnits() or {}
        if table.getn(units) == 0 then
            return 'fail'
        end

        IssueWaypointMove(units, waypoint, formation)

        local elapsed = 0
        local stalled = 0
        local lastDistSq = math.huge
        while PlatoonAlive(platoon) do
            local pos = GetPlatoonPosition(platoon)
            if not pos then
                return 'repath'
            end

            local distSq = DistanceSq(pos, waypoint.position)
            if distSq <= ArrivalDistanceSq then
                break
            end

            if distSq < (lastDistSq - 9) then
                stalled = 0
                lastDistSq = distSq
            else
                stalled = stalled + 1
            end

            elapsed = elapsed + 1
            if elapsed >= WaypointTimeoutSeconds then
                return 'repath'
            end
            if stalled >= StuckSeconds then
                return 'repath'
            end

            WaitSeconds(1)
        end
    end

    platoon._storedRoute = route
    return 'attack'
end

local function CanPathTo(platoon, layer, destination)
    if not (platoon and destination) then
        return false
    end
    local origin = GetPlatoonPosition(platoon)
    if not origin then
        return false
    end
    return CanPathBetween(layer or DetermineLayer(platoon), origin, destination)
end

local function FindSafePath(platoon, layer, destination, startOverride, opts)
    local start = CopyVec(startOverride or GetPlatoonPosition(platoon))
    if not (start and destination) then
        return nil
    end

    local route = BuildRoute(platoon, start, destination, opts or { RouteLayer = layer })
    if route and route.waypoints then
        local out = {}
        for _, waypoint in ipairs(route.waypoints) do
            table.insert(out, CopyVec(waypoint.position))
        end
        return out
    end

    return nil
end

local function RecomputePathWithFallback(platoon, layer, destination, opts)
    opts = opts or {}
    opts.ForceRepath = true
    return FindSafePath(platoon, layer, destination, nil, opts)
end

local function MoveToNearestPlayableIngress(platoon, layer, area, formation, destination)
    if not PlatoonAlive(platoon) then
        return false, nil, nil
    end

    area = area or GetPlayableArea()
    local pos = GetPlatoonPosition(platoon)
    if not (pos and area) then
        return false, nil, nil
    end

    local ingress = CreateIngressWaypoint(area, pos, destination)
    if not ingress then
        return false, nil, nil
    end

    local path = BuildPathSegment(layer or DetermineLayer(platoon), pos, ingress)
    if not path then
        return false, ingress, nil
    end

    MoveAlongPath(platoon, path, formation, false, layer, false)
    return true, ingress, path
end

local function InitializeRoutingSystem(opts)
    RouteCache = {}
    return Metrics
end

local function PrimeRoutingGraph(opts)
    return InitializeRoutingSystem(opts)
end

local function GetRoutingMetrics()
    return Metrics
end

return {
    CanPathTo = CanPathTo,
    CanPathBetween = CanPathBetween,
    BuildPathSegment = BuildPathSegment,
    FindSafePath = FindSafePath,
    RecomputePathWithFallback = RecomputePathWithFallback,
    MoveAlongPath = MoveAlongPath,
    MoveToNearestPlayableIngress = MoveToNearestPlayableIngress,
    BuildRoute = BuildRoute,
    ShouldRepath = ShouldRepath,
    FollowRoute = FollowRoute,

    InitializeRoutingSystem = InitializeRoutingSystem,
    PrimeRoutingGraph = PrimeRoutingGraph,
    GetRoutingMetrics = GetRoutingMetrics,
}