local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
local NavUtils = import('/lua/sim/NavUtils.lua')

local function CopyVec(v)
    if not v then
        return nil
    end

    return { v[1] or 0, v[2] or 0, v[3] or 0 }
end

local function DistSq(a, b)
    if not (a and b) then
        return math.huge
    end

    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return dx * dx + dz * dz
end

local function HeadingDegrees(a, b)
    if not (a and b) then
        return 0
    end

    local dx = (b[1] or 0) - (a[1] or 0)
    local dz = (b[3] or 0) - (a[3] or 0)
    if math.abs(dx) < 0.001 and math.abs(dz) < 0.001 then
        return 0
    end

    return math.deg((math.atan2 or math.atan)(dz, dx))
end

local function ResolveLayer(platoon, opts)
    local override = opts and opts.RouteLayer
    if override then
        return override
    end

    if not platoon then
        return 'Land'
    end

    local movement = platoon.MovementLayer
    if movement == 'Air' then
        return 'Air'
    end
    if movement == 'Water' or movement == 'Naval' then
        return 'Water'
    end
    if movement == 'Amphibious' or (opts and opts.Amphibious) then
        return 'Amphibious'
    end

    return 'Land'
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
        return pos
    end

    local buffer = margin or 0
    local x = math.min(math.max(pos[1], area[1] + buffer), area[3] - buffer)
    local z = math.min(math.max(pos[3], area[2] + buffer), area[4] - buffer)
    return { x, pos[2] or GetTerrainHeight(x, z), z }
end

local function SurfaceHeightForLayer(layer, x, z)
    if layer == 'Water' or layer == 'Naval' then
        return GetSurfaceHeight(x, z)
    end

    return math.max(GetTerrainHeight(x, z), GetSurfaceHeight(x, z))
end

local function PointPassable(layer, position)
    if not position then
        return false
    end

    local ok, passable = pcall(NavUtils.CanPathTo, layer, position, position)
    return ok and passable
end

local function SegmentPassable(layer, fromPos, toPos)
    if not (fromPos and toPos) then
        return false
    end

    local ok, passable = pcall(NavUtils.CanPathTo, layer, fromPos, toPos)
    return ok and passable
end

local function BuildCardinalIngress(startPos, area)
    if not (startPos and area) then
        return nil, nil
    end

    local distances = {
        left = math.abs(startPos[1] - area[1]),
        right = math.abs(area[3] - startPos[1]),
        bottom = math.abs(startPos[3] - area[2]),
        top = math.abs(area[4] - startPos[3]),
    }

    local bestEdge = 'left'
    local bestDistance = distances.left
    for edge, distance in pairs(distances) do
        if distance < bestDistance then
            bestEdge = edge
            bestDistance = distance
        end
    end

    local ingress = CopyVec(startPos)
    if bestEdge == 'left' then
        ingress[1] = area[1] + 5
    elseif bestEdge == 'right' then
        ingress[1] = area[3] - 5
    elseif bestEdge == 'bottom' then
        ingress[3] = area[2] + 5
    else
        ingress[3] = area[4] - 5
    end

    ingress[2] = SurfaceHeightForLayer('Land', ingress[1], ingress[3])
    return ingress, bestEdge
end

local function ExpandCurveWaypoints(route)
    if not route or table.getn(route) <= 2 then
        return route
    end

    local expanded = { route[1] }
    for i = 2, table.getn(route) - 1 do
        local prev = expanded[table.getn(expanded)]
        local corner = route[i]
        local nextPoint = route[i + 1]

        table.insert(expanded, corner)

        if prev and corner and nextPoint then
            local h1 = HeadingDegrees(prev, corner)
            local h2 = HeadingDegrees(corner, nextPoint)
            local diff = math.abs(h2 - h1)
            if diff > 180 then
                diff = 360 - diff
            end

            if diff > 45 then
                local c1 = { (prev[1] + corner[1]) * 0.5, corner[2], (prev[3] + corner[3]) * 0.5, _curve = true }
                local c2 = { (corner[1] + nextPoint[1]) * 0.5, corner[2], (corner[3] + nextPoint[3]) * 0.5, _curve = true }
                table.insert(expanded, c1)
                table.insert(expanded, c2)
            end
        end
    end

    table.insert(expanded, route[table.getn(route)])
    return expanded
end

function PlatoonNeedsIngress(platoon, opts)
    local area = GetPlayableArea()
    local position = platoon and platoon.GetPlatoonPosition and platoon:GetPlatoonPosition()
    if not (area and position) then
        return false
    end

    if PositionInPlayableArea(position, area) then
        return false
    end

    if opts and opts.DisableIngress then
        return false
    end

    local source = (opts and opts.RouteSource) or (platoon and platoon.PlatoonData and platoon.PlatoonData.RouteSource)
    return source == 'UnitSpawner'
end

function BuildPlatoonRoute(platoon, destination, opts)
    if not (platoon and destination) then
        return nil
    end

    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
        return nil
    end

    local layer = ResolveLayer(platoon, opts)
    local startPos = platoon:GetPlatoonPosition()
    if not startPos then
        return nil
    end

    local area = GetPlayableArea()
    local target = area and ClampToPlayableArea(destination, area, 0) or CopyVec(destination)

    local waypoints = {}
    local routingStart = startPos
    if PlatoonNeedsIngress(platoon, opts) then
        local ingress, edge = BuildCardinalIngress(startPos, area)
        if ingress then
            table.insert(waypoints, { pos = ingress, type = 'ingress', ingressEdge = edge })
            routingStart = ingress
        end
    end

    local path = nil
    local ok, navPath = pcall(NavUtils.PathTo, layer, routingStart, target)
    if ok and navPath and table.getn(navPath) > 0 then
        path = navPath
    else
        path = { target }
    end

    for _, point in ipairs(path) do
        table.insert(waypoints, { pos = CopyVec(point), type = 'transit' })
    end

    local route = {}
    for _, waypoint in ipairs(waypoints) do
        table.insert(route, waypoint.pos)
    end

    route = ExpandCurveWaypoints(route)

    local metadata = {}
    for i, point in ipairs(route) do
        point[2] = SurfaceHeightForLayer(layer, point[1], point[3])

        local nextPoint = route[i + 1]
        local waypointType = 'transit'
        if i == 1 and PlatoonNeedsIngress(platoon, opts) then
            waypointType = 'ingress'
        elseif i == table.getn(route) then
            waypointType = 'pre-attack'
        end
        if point._curve then
            waypointType = 'curve'
        end

        metadata[i] = {
            position = point,
            useFormation = (opts and opts.Formation and opts.Formation ~= 'NoFormation' and not point._curve) and true or false,
            aggressiveMove = opts and opts.AggressiveMove and true or false,
            facing = nextPoint and HeadingDegrees(point, nextPoint) or 0,
            waypointType = waypointType,
        }
    end

    platoon._storedRoute = {
        createdAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0,
        destination = CopyVec(target),
        layer = layer,
        waypoints = metadata,
    }

    return platoon._storedRoute
end

function RebuildPlatoonRouteIfNeeded(platoon, destination, opts)
    if not platoon then
        return nil
    end

    local stored = platoon._storedRoute
    if not stored or not stored.destination then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    if DistSq(stored.destination, destination) > (20 * 20) then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    return stored
end

function FollowStoredPlatoonRoute(platoon, destination, opts)
    if not platoon then
        return 'fail'
    end

    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
        return 'fail'
    end

    local stored = RebuildPlatoonRouteIfNeeded(platoon, destination, opts)
    if not (stored and stored.waypoints and table.getn(stored.waypoints) > 0) then
        return 'repath'
    end

    IssueClearCommands(units)

    local previous = platoon:GetPlatoonPosition()
    for _, waypoint in ipairs(stored.waypoints) do
        local position = waypoint.position
        if position and PointPassable(stored.layer, position) and (not previous or SegmentPassable(stored.layer, previous, position)) then
            if waypoint.useFormation and opts and opts.Formation and opts.Formation ~= 'NoFormation' then
                platoon:SetPlatoonFormationOverride(opts.Formation)
                if waypoint.aggressiveMove then
                    IssueFormAggressiveMove(units, position, opts.Formation, waypoint.facing or 0)
                else
                    IssueFormMove(units, position, opts.Formation, waypoint.facing or 0)
                end
            else
                platoon:SetPlatoonFormationOverride('NoFormation')
                if waypoint.aggressiveMove then
                    IssueAggressiveMove(units, position)
                else
                    IssueMove(units, position)
                end
            end
            previous = position
        end
    end

    local timeout = 90
    while timeout > 0 do
        local pos = platoon:GetPlatoonPosition()
        if not pos then
            return 'fail'
        end

        if DistSq(pos, destination) <= (40 * 40) then
            return 'attack'
        end

        timeout = timeout - 1
        WaitSeconds(1)
    end

    return 'repath'
end


function CanPathBetween(layer, fromPos, toPos)
    return SegmentPassable(layer, fromPos, toPos)
end

function CanPathTo(platoon, layer, destination)
    local startPos = platoon and platoon.GetPlatoonPosition and platoon:GetPlatoonPosition()
    if not (startPos and destination) then
        return false
    end

    return SegmentPassable(layer, startPos, destination)
end

function BuildPathSegment(layer, startPos, destination)
    if not (startPos and destination) then
        return nil
    end

    local area = GetPlayableArea()
    local fromPos = area and ClampToPlayableArea(startPos, area, 0) or CopyVec(startPos)
    local toPos = area and ClampToPlayableArea(destination, area, 0) or CopyVec(destination)

    local ok, path = pcall(NavUtils.PathTo, layer, fromPos, toPos)
    if ok and path and table.getn(path) > 0 then
        local out = {}
        for _, point in ipairs(path) do
            table.insert(out, CopyVec(point))
        end
        return out
    end

    if SegmentPassable(layer, fromPos, toPos) then
        return { CopyVec(toPos) }
    end

    return nil
end

function FindSafePath(platoon, layer, destination, startOverride, opts)
    if not (platoon and destination) then
        return nil
    end

    local localOpts = opts or {}
    localOpts.RouteLayer = layer

    local route = BuildPlatoonRoute(platoon, destination, localOpts)
    if not (route and route.waypoints) then
        return nil
    end

    local path = {}
    for _, waypoint in ipairs(route.waypoints) do
        if waypoint and waypoint.position then
            table.insert(path, CopyVec(waypoint.position))
        end
    end

    return path
end

function RecomputePathWithFallback(platoon, layer, destination, opts)
    if not (platoon and destination) then
        return nil
    end

    local localOpts = opts or {}
    localOpts.RouteLayer = layer

    local route = RebuildPlatoonRouteIfNeeded(platoon, destination, localOpts)
    if not (route and route.waypoints) then
        return nil
    end

    local path = {}
    for _, waypoint in ipairs(route.waypoints) do
        if waypoint and waypoint.position then
            table.insert(path, CopyVec(waypoint.position))
        end
    end

    return path
end

function MoveAlongPath(platoon, path, formation, aggressiveFinal, layer, aggressiveRoute)
    if not (platoon and path and table.getn(path) > 0) then
        return false
    end

    local destination = path[table.getn(path)]
    if not destination then
        return false
    end

    local route = {
        destination = CopyVec(destination),
        layer = layer,
        waypoints = {},
    }

    for index, waypoint in ipairs(path) do
        local nextWaypoint = path[index + 1]
        table.insert(route.waypoints, {
            position = CopyVec(waypoint),
            useFormation = formation and formation ~= 'NoFormation' and true or false,
            aggressiveMove = aggressiveRoute or (aggressiveFinal and index == table.getn(path)),
            facing = HeadingDegrees(waypoint, nextWaypoint or waypoint),
            waypointType = index == table.getn(path) and 'pre-attack' or 'transit',
        })
    end

    platoon._storedRoute = route

    local status = FollowStoredPlatoonRoute(platoon, destination, {
        Formation = formation,
        AggressiveMove = aggressiveRoute and true or false,
        RouteLayer = layer,
        DisableIngress = true,
    })

    return status == 'attack' or status == 'success'
end

function MoveToNearestPlayableIngress(platoon, layer, area, formation, destination)
    local opts = {
        Formation = formation,
        AggressiveMove = false,
        RouteLayer = layer,
        RouteSource = 'UnitSpawner',
    }

    local route = BuildPlatoonRoute(platoon, destination, opts)
    if not (route and route.waypoints and table.getn(route.waypoints) > 0) then
        return false, nil, nil
    end

    local ingress = nil
    for _, waypoint in ipairs(route.waypoints) do
        if waypoint and waypoint.waypointType == 'ingress' then
            ingress = waypoint.position
            break
        end
    end

    local status = FollowStoredPlatoonRoute(platoon, destination, opts)
    return status == 'attack' or status == 'success', ingress, 'cardinal'
end

return {
    BuildPlatoonRoute = BuildPlatoonRoute,
    FollowStoredPlatoonRoute = FollowStoredPlatoonRoute,
    RebuildPlatoonRouteIfNeeded = RebuildPlatoonRouteIfNeeded,
    PlatoonNeedsIngress = PlatoonNeedsIngress,
    CanPathBetween = CanPathBetween,
    CanPathTo = CanPathTo,
    BuildPathSegment = BuildPathSegment,
    FindSafePath = FindSafePath,
    RecomputePathWithFallback = RecomputePathWithFallback,
    MoveAlongPath = MoveAlongPath,
    MoveToNearestPlayableIngress = MoveToNearestPlayableIngress,
}