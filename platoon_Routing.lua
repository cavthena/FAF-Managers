local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
local NavUtils = import('/lua/sim/NavUtils.lua')

local SegmentPassable

local function ReadVecComponent(v, numericIndex, axisName)
    if v == nil then
        return nil
    end

    if type(v) == 'table' then
        local value = rawget(v, numericIndex)
        if value == nil then
            value = rawget(v, axisName)
        end
        return value
    end

    local ok, value = pcall(function()
        return v[axisName]
    end)
    if ok then
        return value
    end

    return nil
end

local function VecX(v)
    return ReadVecComponent(v, 1, 'x') or 0
end

local function VecY(v)
    return ReadVecComponent(v, 2, 'y') or 0
end

local function VecZ(v)
    return ReadVecComponent(v, 3, 'z') or 0
end

local function ReadVecMetadata(v, fieldName)
    if type(v) ~= 'table' then
        return nil
    end

    return rawget(v, fieldName)
end

local function CopyVec(v)
    if not v then
        return nil
    end

    local copy = {
        VecX(v),
        VecY(v),
        VecZ(v)
    }
    copy._curve = ReadVecMetadata(v, '_curve')
    copy._centered = ReadVecMetadata(v, '_centered')
    copy._ingress = ReadVecMetadata(v, '_ingress')
    copy._ingressEdge = ReadVecMetadata(v, '_ingressEdge')
    return copy
end

local function DistSq(a, b)
    if not (a and b) then
        return math.huge
    end

    local dx = VecX(a) - VecX(b)
    local dz = VecZ(a) - VecZ(b)
    return dx * dx + dz * dz
end

local function HeadingDegrees(a, b)
    if not (a and b) then
        return 0
    end

    local dx = VecX(b) - VecX(a)
    local dz = VecZ(b) - VecZ(a)
    if math.abs(dx) < 0.001 and math.abs(dz) < 0.001 then
        return 0
    end

    return math.deg((math.atan2 or math.atan)(dz, dx))
end

local function Lerp(a, b, t)
    return a + (b - a) * t
end

local function Length2D(x, z)
    return math.sqrt((x * x) + (z * z))
end

local function Normalize2D(x, z)
    local length = Length2D(x, z)
    if length < 0.001 then
        return 0, 0, 0
    end

    return x / length, z / length, length
end

local function BuildPoint(x, y, z)
    return { x, y or 0, z }
end

local function DirectionBetween(a, b)
    if not (a and b) then
        return 0, 0, 0
    end

    return Normalize2D(VecX(b) - VecX(a), VecZ(b) - VecZ(a))
end

local function OffsetPoint(point, dx, dz, y)
    if not point then
        return nil
    end

    return { VecX(point) + dx, y or VecY(point), VecZ(point) + dz }
end

local function SegmentLength(a, b)
    local _, _, length = DirectionBetween(a, b)
    return length
end

local function DistanceToLine(point, lineA, lineB)
    if not (point and lineA and lineB) then
        return math.huge
    end

    local dx = VecX(lineB) - VecX(lineA)
    local dz = VecZ(lineB) - VecZ(lineA)
    local lengthSq = dx * dx + dz * dz
    if lengthSq < 0.001 then
        return math.sqrt(DistSq(point, lineA))
    end

    local t = ((VecX(point) - VecX(lineA)) * dx + (VecZ(point) - VecZ(lineA)) * dz) / lengthSq
    local projX = VecX(lineA) + dx * t
    local projZ = VecZ(lineA) + dz * t
    local diffX = VecX(point) - projX
    local diffZ = VecZ(point) - projZ
    return math.sqrt((diffX * diffX) + (diffZ * diffZ))
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

    return VecX(pos) >= area[1] and VecX(pos) <= area[3] and VecZ(pos) >= area[2] and VecZ(pos) <= area[4]
end

local function ClampToPlayableArea(pos, area, margin)
    if not (pos and area) then
        return pos
    end

    local buffer = margin or 0
    local x = math.min(math.max(VecX(pos), area[1] + buffer), area[3] - buffer)
    local z = math.min(math.max(VecZ(pos), area[2] + buffer), area[4] - buffer)
    return { x, ReadVecComponent(pos, 2, 'y') or GetTerrainHeight(x, z), z }
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

local function SamplePointClearance(layer, point, tangentX, tangentZ, maxDistance, stepSize)
    if not point then
        return 0, 0, 0, 0
    end

    local nx, nz = -tangentZ, tangentX
    local normalLength = Length2D(nx, nz)
    if normalLength < 0.001 then
        nx, nz = 0, 1
    else
        nx = nx / normalLength
        nz = nz / normalLength
    end

    local maxCheck = maxDistance or 16
    local step = stepSize or 2
    local leftClearance = 0
    local rightClearance = 0

    local distance = step
    while distance <= maxCheck do
        local left = OffsetPoint(point, nx * distance, nz * distance)
        local right = OffsetPoint(point, -nx * distance, -nz * distance)

        if PointPassable(layer, left) then
            leftClearance = distance
        end
        if PointPassable(layer, right) then
            rightClearance = distance
        end

        distance = distance + step
    end

    return leftClearance, rightClearance, nx, nz
end

local function SegmentHasClearance(layer, fromPos, toPos, desiredClearance)
    if not SegmentPassable(layer, fromPos, toPos) then
        return false
    end

    local dirX, dirZ, length = DirectionBetween(fromPos, toPos)
    if length < 0.001 then
        return PointPassable(layer, fromPos)
    end

    local clearance = desiredClearance or 4
    local samples = math.max(2, math.floor(length / 6))
    for i = 0, samples do
        local t = i / samples
        local sample = {
            Lerp(VecX(fromPos), VecX(toPos), t),
            Lerp(ReadVecComponent(fromPos, 2, 'y') or 0, ReadVecComponent(toPos, 2, 'y') or 0, t),
            Lerp(VecZ(fromPos), VecZ(toPos), t),
        }

        local left, right = SamplePointClearance(layer, sample, dirX, dirZ, clearance, math.max(1, clearance * 0.5))
        local nearWallLeft = left < clearance
        local nearWallRight = right < clearance
        if nearWallLeft and nearWallRight then
            return false
        end
    end

    return true
end

local function RemoveDuplicateRoutePoints(route, minDistanceSq)
    if not route or table.getn(route) <= 1 then
        return route
    end

    local minSq = minDistanceSq or 1
    local cleaned = { CopyVec(route[1]) }
    for i = 2, table.getn(route) do
        local point = route[i]
        if point and DistSq(cleaned[table.getn(cleaned)], point) > minSq then
            table.insert(cleaned, CopyVec(point))
        end
    end

    return cleaned
end

local function RemoveRouteDoubleBack(route)
    if not route or table.getn(route) <= 2 then
        return route
    end

    local cleaned = { CopyVec(route[1]) }
    for i = 2, table.getn(route) - 1 do
        local point = route[i]
        local prev = cleaned[table.getn(cleaned)]
        local nextPoint = route[i + 1]
        if prev and point and nextPoint then
            local inX, inZ = DirectionBetween(prev, point)
            local outX, outZ = DirectionBetween(point, nextPoint)
            local dot = (inX * outX) + (inZ * outZ)
            local offset = DistanceToLine(point, prev, nextPoint)
            if dot < -0.25 and offset < 6 then
                -- Skip hard reversals that do not materially contribute to the route.
            else
                table.insert(cleaned, CopyVec(point))
            end
        end
    end

    table.insert(cleaned, CopyVec(route[table.getn(route)]))
    return cleaned
end

local function SimplifyRouteSegments(route, layer)
    if not route or table.getn(route) <= 2 then
        return route
    end

    local simplified = { CopyVec(route[1]) }
    local index = 1
    while index < table.getn(route) do
        local best = index + 1
        local current = route[index]
        for candidate = table.getn(route), index + 1, -1 do
            if SegmentHasClearance(layer, current, route[candidate], 5) then
                best = candidate
                break
            end
        end

        table.insert(simplified, CopyVec(route[best]))
        index = best
    end

    return simplified
end

local function AdjustPointForClearance(route, index, layer, area)
    local point = route[index]
    if not point then
        return nil
    end

    local prev = route[index - 1] or point
    local nextPoint = route[index + 1] or point
    local inX, inZ = DirectionBetween(prev, point)
    local outX, outZ = DirectionBetween(point, nextPoint)
    local tangentX = inX + outX
    local tangentZ = inZ + outZ
    if math.abs(tangentX) < 0.001 and math.abs(tangentZ) < 0.001 then
        tangentX, tangentZ = outX, outZ
    end
    tangentX, tangentZ = Normalize2D(tangentX, tangentZ)
    if math.abs(tangentX) < 0.001 and math.abs(tangentZ) < 0.001 then
        tangentX, tangentZ = 1, 0
    end

    local left, right, nx, nz = SamplePointClearance(layer, point, tangentX, tangentZ, 18, 2)
    local shift = (right - left) * 0.5
    if math.abs(shift) < 0.5 then
        return CopyVec(point)
    end

    local maxShift = math.min(8, math.max(left, right))
    shift = math.max(-maxShift, math.min(maxShift, shift))
    local adjusted = OffsetPoint(point, -nx * shift, -nz * shift)
    adjusted = area and ClampToPlayableArea(adjusted, area, 0) or adjusted

    if PointPassable(layer, adjusted) then
        local before = route[index - 1]
        local after = route[index + 1]
        if (not before or SegmentPassable(layer, before, adjusted)) and (not after or SegmentPassable(layer, adjusted, after)) then
            adjusted._centered = true
            return adjusted
        end
    end

    return CopyVec(point)
end

local function RefineRoute(route, layer, area)
    if not route or table.getn(route) == 0 then
        return route
    end

    local cleaned = RemoveDuplicateRoutePoints(route, 4)
    cleaned = RemoveRouteDoubleBack(cleaned)
    cleaned = SimplifyRouteSegments(cleaned, layer)

    local refined = {}
    for i, point in ipairs(cleaned) do
        if i == 1 or i == table.getn(cleaned) then
            table.insert(refined, CopyVec(point))
        else
            table.insert(refined, AdjustPointForClearance(cleaned, i, layer, area))
        end
    end

    refined = RemoveDuplicateRoutePoints(refined, 4)
    refined = RemoveRouteDoubleBack(refined)
    return refined
end

local function BuildCurveSamples(prev, corner, nextPoint, layer, area)
    if not (prev and corner and nextPoint) then
        return nil
    end

    local inX, inZ, inLength = DirectionBetween(prev, corner)
    local outX, outZ, outLength = DirectionBetween(corner, nextPoint)
    if inLength < 0.001 or outLength < 0.001 then
        return nil
    end

    local dot = math.max(-1, math.min(1, (inX * outX) + (inZ * outZ)))
    local turnAngle = math.deg(math.acos(dot))
    if turnAngle < 25 then
        return nil
    end

    local radius = math.min(12, inLength * 0.35, outLength * 0.35)
    radius = math.max(radius, 4)
    local entry = OffsetPoint(corner, -inX * radius, -inZ * radius)
    local exit = OffsetPoint(corner, outX * radius, outZ * radius)
    if area then
        entry = ClampToPlayableArea(entry, area, 0)
        exit = ClampToPlayableArea(exit, area, 0)
    end

    local samples = {}
    for _, t in ipairs({ 0.25, 0.5, 0.75 }) do
        local oneMinus = 1 - t
        local x = (oneMinus * oneMinus * entry[1]) + (2 * oneMinus * t * corner[1]) + (t * t * exit[1])
        local z = (oneMinus * oneMinus * entry[3]) + (2 * oneMinus * t * corner[3]) + (t * t * exit[3])
        local point = BuildPoint(x, corner[2], z)
        if area then
            point = ClampToPlayableArea(point, area, 0)
        end
        if PointPassable(layer, point) then
            point._curve = true
            table.insert(samples, point)
        end
    end

    if table.getn(samples) < 2 then
        return nil
    end

    local curveRoute = { entry }
    for _, point in ipairs(samples) do
        table.insert(curveRoute, point)
    end
    table.insert(curveRoute, exit)

    for i = 1, table.getn(curveRoute) - 1 do
        if not SegmentPassable(layer, curveRoute[i], curveRoute[i + 1]) then
            return nil
        end
    end

    curveRoute[1]._curve = true
    curveRoute[table.getn(curveRoute)]._curve = true
    return curveRoute
end

local function AddRouteCurves(route, layer, area)
    if not route or table.getn(route) <= 2 then
        return route
    end

    local curved = { CopyVec(route[1]) }
    for i = 2, table.getn(route) - 1 do
        local prev = curved[table.getn(curved)]
        local corner = route[i]
        local nextPoint = route[i + 1]
        local samples = BuildCurveSamples(prev, corner, nextPoint, layer, area)
        if samples then
            for _, point in ipairs(samples) do
                table.insert(curved, point)
            end
        else
            table.insert(curved, CopyVec(corner))
        end
    end
    table.insert(curved, CopyVec(route[table.getn(route)]))

    return RemoveDuplicateRoutePoints(curved, 2)
end

function SegmentPassable(layer, fromPos, toPos)
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
        left = math.abs(VecX(startPos) - area[1]),
        right = math.abs(area[3] - VecX(startPos)),
        bottom = math.abs(VecZ(startPos) - area[2]),
        top = math.abs(area[4] - VecZ(startPos)),
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
    local startPos = CopyVec(platoon:GetPlatoonPosition())
    if not startPos then
        return nil
    end

    local area = GetPlayableArea()
    local target = area and ClampToPlayableArea(destination, area, 0) or CopyVec(destination)

    local routingStart = startPos
    local route = { CopyVec(startPos) }
    if PlatoonNeedsIngress(platoon, opts) then
        local ingress, edge = BuildCardinalIngress(startPos, area)
        if ingress then
            ingress._ingress = true
            ingress._ingressEdge = edge
            table.insert(route, ingress)
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

    if SegmentHasClearance(layer, routingStart, target, 5) then
        if DistSq(route[table.getn(route)], target) > 1 then
            table.insert(route, CopyVec(target))
        end
    else
        for _, point in ipairs(path) do
            table.insert(route, CopyVec(point))
        end
    end

    route = RefineRoute(route, layer, area)
    route = AddRouteCurves(route, layer, area)
    route = RefineRoute(route, layer, area)

    local metadata = {}
    for i = 2, table.getn(route) do
        local point = route[i]
        point[2] = SurfaceHeightForLayer(layer, point[1], point[3])

        local prevPoint = route[i - 1]
        local waypointType = 'transit'
        if point._ingress then
            waypointType = 'ingress'
        elseif i == table.getn(route) then
            waypointType = 'pre-attack'
        end
        if point._curve then
            waypointType = 'curve'
        end

        table.insert(metadata, {
            position = point,
            useFormation = (opts and opts.Formation and opts.Formation ~= 'NoFormation' and not point._curve) and true or false,
            aggressiveMove = opts and opts.AggressiveMove and true or false,
            facing = prevPoint and HeadingDegrees(prevPoint, point) or 0,
            waypointType = waypointType,
        })
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
        local prevWaypoint = index > 1 and path[index - 1] or platoon:GetPlatoonPosition()
        table.insert(route.waypoints, {
            position = CopyVec(waypoint),
            useFormation = formation and formation ~= 'NoFormation' and true or false,
            aggressiveMove = aggressiveRoute or (aggressiveFinal and index == table.getn(path)),
            facing = HeadingDegrees(prevWaypoint or waypoint, waypoint),
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