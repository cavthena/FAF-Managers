local NavUtils = import('/lua/sim/NavUtils.lua')

local SegmentPassable
local RouteStamp = 0

local DirectClearance = 6
local SimplifyClearance = 5
local CornerAngleThreshold = 28
local WideCornerAngleThreshold = 55
local CornerSampleDistance = 18
local SegmentReachDistanceSq = 36
local ContinuousReachDistanceSq = 64
local ContinuousQueueDistanceSq = 196
local FinalAttackDistanceSq = 40 * 40

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

local function CopyMetadata(fromPos, toPos)
    if type(fromPos) ~= 'table' or type(toPos) ~= 'table' then
        return
    end

    toPos._curve = rawget(fromPos, '_curve')
    toPos._centered = rawget(fromPos, '_centered')
    toPos._corridor = rawget(fromPos, '_corridor')
    toPos._ingress = rawget(fromPos, '_ingress')
    toPos._ingressEdge = rawget(fromPos, '_ingressEdge')
    toPos._anchor = rawget(fromPos, '_anchor')
end

local function CopyVec(v)
    if not v then
        return nil
    end

    local copy = {
        VecX(v),
        VecY(v),
        VecZ(v),
    }
    CopyMetadata(v, copy)
    return copy
end

local function BuildPoint(x, y, z)
    return { x, y or 0, z }
end

local function DistSq(a, b)
    if not (a and b) then
        return math.huge
    end

    local dx = VecX(a) - VecX(b)
    local dz = VecZ(a) - VecZ(b)
    return dx * dx + dz * dz
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

local function DirectionBetween(a, b)
    if not (a and b) then
        return 0, 0, 0
    end

    return Normalize2D(VecX(b) - VecX(a), VecZ(b) - VecZ(a))
end

local function SegmentLength(a, b)
    local _, _, length = DirectionBetween(a, b)
    return length
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

local function OffsetPoint(point, dx, dz, y)
    if not point then
        return nil
    end

    local shifted = { VecX(point) + dx, y or VecY(point), VecZ(point) + dz }
    CopyMetadata(point, shifted)
    return shifted
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

    return VecX(pos) >= area[1]
        and VecX(pos) <= area[3]
        and VecZ(pos) >= area[2]
        and VecZ(pos) <= area[4]
end

local function ClampToPlayableArea(pos, area, margin)
    if not (pos and area) then
        return CopyVec(pos)
    end

    local buffer = math.max(0, margin or 0)
    local minX = area[1] + buffer
    local maxX = area[3] - buffer
    local minZ = area[2] + buffer
    local maxZ = area[4] - buffer

    if minX > maxX then
        local midX = (area[1] + area[3]) * 0.5
        minX = midX
        maxX = midX
    end
    if minZ > maxZ then
        local midZ = (area[2] + area[4]) * 0.5
        minZ = midZ
        maxZ = midZ
    end

    local x = math.min(math.max(VecX(pos), minX), maxX)
    local z = math.min(math.max(VecZ(pos), minZ), maxZ)
    return { x, VecY(pos), z }
end

local function SurfaceHeightForLayer(layer, x, z)
    if layer == 'Water' or layer == 'Naval' then
        return GetSurfaceHeight(x, z)
    end

    return math.max(GetTerrainHeight(x, z), GetSurfaceHeight(x, z))
end

local function SetPointSurface(point, layer)
    if not point then
        return nil
    end

    point[2] = SurfaceHeightForLayer(layer, point[1], point[3])
    return point
end

local function PointPassable(layer, position)
    if not position then
        return false
    end

    local ok, passable = pcall(NavUtils.CanPathTo, layer, position, position)
    return ok and passable
end

function SegmentPassable(layer, fromPos, toPos)
    if not (fromPos and toPos) then
        return false
    end

    local ok, passable = pcall(NavUtils.CanPathTo, layer, fromPos, toPos)
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

    local maxCheck = maxDistance or 18
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

    local clearance = desiredClearance or SimplifyClearance
    local samples = math.max(2, math.floor(length / 6))
    for i = 0, samples do
        local t = i / samples
        local sample = {
            Lerp(VecX(fromPos), VecX(toPos), t),
            Lerp(VecY(fromPos), VecY(toPos), t),
            Lerp(VecZ(fromPos), VecZ(toPos), t),
        }

        local left, right = SamplePointClearance(layer, sample, dirX, dirZ, clearance, math.max(1, clearance * 0.5))
        if left < clearance and right < clearance then
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
            local offsetDx = VecX(point) - ((VecX(prev) + VecX(nextPoint)) * 0.5)
            local offsetDz = VecZ(point) - ((VecZ(prev) + VecZ(nextPoint)) * 0.5)
            local offsetSq = (offsetDx * offsetDx) + (offsetDz * offsetDz)
            if rawget(point, '_anchor') or rawget(point, '_ingress') or rawget(point, '_corridor') then
                table.insert(cleaned, CopyVec(point))
            elseif dot < -0.35 and offsetSq < 36 then
                -- Skip hard reversals that do not materially contribute to the route.
            else
                table.insert(cleaned, CopyVec(point))
            end
        end
    end

    table.insert(cleaned, CopyVec(route[table.getn(route)]))
    return cleaned
end

local function DetermineStartState(platoon, opts)
    if not platoon then
        return nil, nil, false
    end

    local startPos = opts and opts.RouteStart and CopyVec(opts.RouteStart)
        or (platoon.GetPlatoonPosition and CopyVec(platoon:GetPlatoonPosition()))
    if not startPos then
        return nil, nil, false
    end

    local area = GetPlayableArea()
    local startedOutside = false

    if opts and opts.StartedOutsidePlayableArea ~= nil then
        startedOutside = opts.StartedOutsidePlayableArea and true or false
    elseif platoon.PlatoonData and platoon.PlatoonData.StartedOutsidePlayableArea ~= nil then
        startedOutside = platoon.PlatoonData.StartedOutsidePlayableArea and true or false
    elseif area then
        startedOutside = not PositionInPlayableArea(startPos, area)
    end

    if area and PositionInPlayableArea(startPos, area) then
        startPos = ClampToPlayableArea(startPos, area, 0)
    end

    return SetPointSurface(startPos, ResolveLayer(platoon, opts)), area, startedOutside
end

function PlatoonNeedsIngress(platoon, opts)
    local startPos, area, startedOutside = DetermineStartState(platoon, opts)
    if not (startPos and area) then
        return false
    end

    if not startedOutside then
        return false
    end

    if opts and opts.DisableIngress then
        return false
    end

    local source = (opts and opts.RouteSource)
        or (platoon and platoon.PlatoonData and platoon.PlatoonData.RouteSource)
    return source == 'UnitSpawner'
end

local function BuildCardinalIngress(startPos, area, layer)
    if not (startPos and area) then
        return nil, nil
    end

    local safeBuffer = 6
    local sx = VecX(startPos)
    local sz = VecZ(startPos)
    local candidates = {}

    if sx < area[1] and sz >= area[2] and sz <= area[4] then
        table.insert(candidates, { edge = 'left', point = { area[1] + safeBuffer, 0, sz } })
    end
    if sx > area[3] and sz >= area[2] and sz <= area[4] then
        table.insert(candidates, { edge = 'right', point = { area[3] - safeBuffer, 0, sz } })
    end
    if sz < area[2] and sx >= area[1] and sx <= area[3] then
        table.insert(candidates, { edge = 'bottom', point = { sx, 0, area[2] + safeBuffer } })
    end
    if sz > area[4] and sx >= area[1] and sx <= area[3] then
        table.insert(candidates, { edge = 'top', point = { sx, 0, area[4] - safeBuffer } })
    end

    if table.getn(candidates) == 0 then
        local distances = {
            { edge = 'left', distance = math.abs(sx - area[1]), point = { area[1] + safeBuffer, 0, math.min(math.max(sz, area[2] + safeBuffer), area[4] - safeBuffer) } },
            { edge = 'right', distance = math.abs(sx - area[3]), point = { area[3] - safeBuffer, 0, math.min(math.max(sz, area[2] + safeBuffer), area[4] - safeBuffer) } },
            { edge = 'bottom', distance = math.abs(sz - area[2]), point = { math.min(math.max(sx, area[1] + safeBuffer), area[3] - safeBuffer), 0, area[2] + safeBuffer } },
            { edge = 'top', distance = math.abs(sz - area[4]), point = { math.min(math.max(sx, area[1] + safeBuffer), area[3] - safeBuffer), 0, area[4] - safeBuffer } },
        }
        table.sort(distances, function(a, b)
            return a.distance < b.distance
        end)
        candidates = distances
    end

    for _, candidate in ipairs(candidates) do
        local ingress = ClampToPlayableArea(candidate.point, area, safeBuffer)
        ingress._ingress = true
        ingress._anchor = true
        ingress._ingressEdge = candidate.edge
        SetPointSurface(ingress, layer)
        if PointPassable(layer, ingress) then
            return ingress, candidate.edge
        end
    end

    local fallback = ClampToPlayableArea(candidates[1].point, area, safeBuffer)
    fallback._ingress = true
    fallback._anchor = true
    fallback._ingressEdge = candidates[1].edge
    return SetPointSurface(fallback, layer), candidates[1].edge
end

local function BuildBasePath(layer, startPos, target)
    if not (startPos and target) then
        return nil
    end

    local route = { CopyVec(startPos) }
    local directAllowed = SegmentHasClearance(layer, startPos, target, DirectClearance)
    if directAllowed then
        table.insert(route, CopyVec(target))
        return route
    end

    local ok, navPath = pcall(NavUtils.PathTo, layer, startPos, target)
    if ok and navPath and table.getn(navPath) > 0 then
        for _, point in ipairs(navPath) do
            table.insert(route, CopyVec(point))
        end
    else
        table.insert(route, CopyVec(target))
    end

    local last = route[table.getn(route)]
    if DistSq(last, target) > 1 then
        table.insert(route, CopyVec(target))
    end

    return route
end

local function BalancePointInCorridor(route, index, layer, area)
    local point = route[index]
    local prev = route[index - 1] or point
    local nextPoint = route[index + 1] or point
    if not (point and prev and nextPoint) then
        return CopyVec(point)
    end

    local inX, inZ = DirectionBetween(prev, point)
    local outX, outZ = DirectionBetween(point, nextPoint)
    local tangentX = inX + outX
    local tangentZ = inZ + outZ
    if math.abs(tangentX) < 0.001 and math.abs(tangentZ) < 0.001 then
        tangentX, tangentZ = DirectionBetween(prev, nextPoint)
    end
    tangentX, tangentZ = Normalize2D(tangentX, tangentZ)
    if math.abs(tangentX) < 0.001 and math.abs(tangentZ) < 0.001 then
        return CopyVec(point)
    end

    local left, right, nx, nz = SamplePointClearance(layer, point, tangentX, tangentZ, CornerSampleDistance, 1.5)
    local corridorWidth = left + right
    if corridorWidth <= 0 then
        return CopyVec(point)
    end

    local targetShift = (right - left) * 0.5
    if math.abs(targetShift) < 0.35 then
        local stable = CopyVec(point)
        if math.min(left, right) <= 5 then
            stable._corridor = true
            stable._centered = true
            stable._anchor = true
        end
        return stable
    end

    local maxShift = math.min(7, math.max(left, right) * 0.7)
    targetShift = math.max(-maxShift, math.min(maxShift, targetShift))
    local candidate = OffsetPoint(point, -nx * targetShift, -nz * targetShift)
    if area then
        candidate = ClampToPlayableArea(candidate, area, 0)
    end
    SetPointSurface(candidate, layer)

    if PointPassable(layer, candidate)
        and SegmentPassable(layer, prev, candidate)
        and SegmentPassable(layer, candidate, nextPoint)
    then
        candidate._centered = true
        if math.min(left, right) <= 6 or math.abs(targetShift) >= 1 then
            candidate._corridor = true
            candidate._anchor = true
        end
        return candidate
    end

    local fallback = CopyVec(point)
    if math.min(left, right) <= 5 then
        fallback._corridor = true
        fallback._centered = true
        fallback._anchor = true
    end
    return fallback
end

local function CenterRouteThroughCorridors(route, layer, area)
    if not route or table.getn(route) <= 2 then
        return route
    end

    local current = route
    for _ = 1, 3 do
        local balanced = { CopyVec(current[1]) }
        for i = 2, table.getn(current) - 1 do
            table.insert(balanced, BalancePointInCorridor(current, i, layer, area))
        end
        table.insert(balanced, CopyVec(current[table.getn(current)]))
        current = RemoveDuplicateRoutePoints(balanced, 2)
        current = RemoveRouteDoubleBack(current)
    end

    return current
end

local function BuildCornerCurve(prev, corner, nextPoint, layer, area)
    if not (prev and corner and nextPoint) then
        return nil
    end

    local inX, inZ, inLength = DirectionBetween(prev, corner)
    local outX, outZ, outLength = DirectionBetween(corner, nextPoint)
    if inLength < 2 or outLength < 2 then
        return nil
    end

    local dot = math.max(-1, math.min(1, (inX * outX) + (inZ * outZ)))
    local turnAngle = math.deg(math.acos(dot))
    if turnAngle < CornerAngleThreshold then
        return nil
    end

    local left, right = SamplePointClearance(layer, corner, inX + outX, inZ + outZ, CornerSampleDistance, 1.5)
    local localClearance = math.min(left, right)
    local radius = math.min(inLength * 0.35, outLength * 0.35, math.max(3, localClearance))
    if turnAngle >= WideCornerAngleThreshold then
        radius = math.min(inLength * 0.42, outLength * 0.42, math.max(4, localClearance + 1))
    end
    radius = math.max(2.5, radius)

    local entry = OffsetPoint(corner, -inX * radius, -inZ * radius)
    local exit = OffsetPoint(corner, outX * radius, outZ * radius)
    if area then
        entry = ClampToPlayableArea(entry, area, 0)
        exit = ClampToPlayableArea(exit, area, 0)
    end
    SetPointSurface(entry, layer)
    SetPointSurface(exit, layer)

    if not (PointPassable(layer, entry) and PointPassable(layer, exit)) then
        return nil
    end

    local curve = { entry }
    local blendWeights = { 0.2, 0.4, 0.6, 0.8 }
    for _, t in ipairs(blendWeights) do
        local oneMinus = 1 - t
        local x = (oneMinus * oneMinus * VecX(entry)) + (2 * oneMinus * t * VecX(corner)) + (t * t * VecX(exit))
        local z = (oneMinus * oneMinus * VecZ(entry)) + (2 * oneMinus * t * VecZ(corner)) + (t * t * VecZ(exit))
        local sample = BuildPoint(x, 0, z)
        if area then
            sample = ClampToPlayableArea(sample, area, 0)
        end
        SetPointSurface(sample, layer)
        if not PointPassable(layer, sample) then
            return nil
        end
        sample._curve = true
        sample._anchor = true
        table.insert(curve, sample)
    end
    table.insert(curve, exit)

    curve[1]._curve = true
    curve[1]._anchor = true
    curve[table.getn(curve)]._curve = true
    curve[table.getn(curve)]._anchor = true

    local previous = prev
    for _, sample in ipairs(curve) do
        if not SegmentPassable(layer, previous, sample) then
            return nil
        end
        previous = sample
    end
    if not SegmentPassable(layer, previous, nextPoint) then
        return nil
    end

    return curve
end

local function SmoothRouteCorners(route, layer, area)
    if not route or table.getn(route) <= 2 then
        return route
    end

    local smoothed = { CopyVec(route[1]) }
    for i = 2, table.getn(route) - 1 do
        local prev = smoothed[table.getn(smoothed)]
        local corner = route[i]
        local nextPoint = route[i + 1]
        local curve = BuildCornerCurve(prev, corner, nextPoint, layer, area)
        if curve then
            for _, sample in ipairs(curve) do
                table.insert(smoothed, sample)
            end
        else
            table.insert(smoothed, CopyVec(corner))
        end
    end
    table.insert(smoothed, CopyVec(route[table.getn(route)]))

    return RemoveDuplicateRoutePoints(smoothed, 2)
end

local function CanSkipWaypoint(route, fromIndex, toIndex, layer)
    if not route[fromIndex] or not route[toIndex] then
        return false
    end

    for index = fromIndex + 1, toIndex - 1 do
        local point = route[index]
        if point and (point._anchor or point._ingress or point._corridor or point._curve) then
            return false
        end
    end

    return SegmentHasClearance(layer, route[fromIndex], route[toIndex], SimplifyClearance)
end

local function SimplifyRoutePreservingSafety(route, layer)
    if not route or table.getn(route) <= 2 then
        return route
    end

    local simplified = { CopyVec(route[1]) }
    local index = 1
    while index < table.getn(route) do
        local best = index + 1
        for candidate = table.getn(route), index + 1, -1 do
            if CanSkipWaypoint(route, index, candidate, layer) then
                best = candidate
                break
            end
        end
        table.insert(simplified, CopyVec(route[best]))
        index = best
    end

    simplified = RemoveDuplicateRoutePoints(simplified, 4)
    simplified = RemoveRouteDoubleBack(simplified)
    return simplified
end

local function BuildWaypointMetadata(route, destination, opts, layer, startedOutside, ingressEdge)
    local metadata = {}
    local formation = opts and opts.Formation or nil
    local aggressiveMove = opts and opts.AggressiveMove and true or false

    for i = 2, table.getn(route) do
        local point = CopyVec(route[i])
        SetPointSurface(point, layer)
        local prevPoint = route[i - 1] or point
        local nextPoint = route[i + 1] or point
        local waypointType = 'transit'
        if point._ingress then
            waypointType = 'ingress'
        elseif i == table.getn(route) then
            waypointType = 'pre-attack'
        elseif point._curve then
            waypointType = 'curve'
        elseif point._corridor then
            waypointType = 'corridor'
        end

        local arrivalFacing = HeadingDegrees(prevPoint, point)
        local departureFacing = HeadingDegrees(point, nextPoint)
        if i == table.getn(route) or DistSq(point, nextPoint) <= 1 then
            departureFacing = arrivalFacing
        end

        local staging = waypointType == 'pre-attack' or waypointType == 'ingress' or point._anchor and true or false
        local continuous = not staging

        table.insert(metadata, {
            position = point,
            useFormation = formation and formation ~= 'NoFormation' and true or false,
            aggressiveMove = aggressiveMove,
            facing = arrivalFacing,
            arrivalFacing = arrivalFacing,
            departureFacing = departureFacing,
            waypointType = waypointType,
            staging = staging,
            continuous = continuous,
            allowReform = staging,
            reachDistanceSq = continuous and ContinuousReachDistanceSq or SegmentReachDistanceSq,
            queueDistanceSq = continuous and ContinuousQueueDistanceSq or SegmentReachDistanceSq,
            segmentStart = CopyVec(prevPoint),
            segmentEnd = CopyVec(point),
            nextSegmentEnd = CopyVec(nextPoint),
        })
    end

    RouteStamp = RouteStamp + 1
    return {
        stamp = RouteStamp,
        createdAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0,
        currentIndex = 1,
        destination = CopyVec(destination),
        targetPosition = opts and opts.TargetPosition and CopyVec(opts.TargetPosition) or CopyVec(destination),
        targetZone = opts and opts.TargetZone or nil,
        layer = layer,
        aggressiveMove = aggressiveMove,
        formation = formation,
        routeSource = opts and opts.RouteSource or nil,
        startedOutsidePlayableArea = startedOutside and true or false,
        ingressEdge = ingressEdge,
        waypoints = metadata,
    }
end

local function SyncRouteOptions(route, opts)
    if not route then
        return nil
    end

    if opts and opts.Formation ~= nil then
        route.formation = opts.Formation
    end
    if opts and opts.AggressiveMove ~= nil then
        route.aggressiveMove = opts.AggressiveMove and true or false
    end
    if opts and opts.TargetPosition then
        route.targetPosition = CopyVec(opts.TargetPosition)
    end
    if opts and opts.TargetZone ~= nil then
        route.targetZone = opts.TargetZone
    end
    if opts and opts.RouteSource ~= nil then
        route.routeSource = opts.RouteSource
    end
    if opts and opts.StartedOutsidePlayableArea ~= nil then
        route.startedOutsidePlayableArea = opts.StartedOutsidePlayableArea and true or false
    end

    for _, waypoint in ipairs(route.waypoints or {}) do
        waypoint.useFormation = route.formation and route.formation ~= 'NoFormation' and true or false
        waypoint.aggressiveMove = route.aggressiveMove
        if waypoint.segmentStart and waypoint.segmentEnd then
            waypoint.arrivalFacing = HeadingDegrees(waypoint.segmentStart, waypoint.segmentEnd)
            waypoint.facing = waypoint.arrivalFacing
        end
        if waypoint.segmentEnd and waypoint.nextSegmentEnd then
            waypoint.departureFacing = HeadingDegrees(waypoint.segmentEnd, waypoint.nextSegmentEnd)
            if DistSq(waypoint.segmentEnd, waypoint.nextSegmentEnd) <= 1 then
                waypoint.departureFacing = waypoint.arrivalFacing or waypoint.departureFacing
            end
        else
            waypoint.departureFacing = waypoint.arrivalFacing or waypoint.facing
        end
    end

    return route
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
    local startPos, area, startedOutside = DetermineStartState(platoon, opts)
    if not startPos then
        return nil
    end

    local target = area and ClampToPlayableArea(destination, area, 0) or CopyVec(destination)
    SetPointSurface(target, layer)

    local route = { CopyVec(startPos) }
    local routingStart = CopyVec(startPos)
    local ingressEdge = nil

    if PlatoonNeedsIngress(platoon, opts) then
        local ingress
        ingress, ingressEdge = BuildCardinalIngress(startPos, area, layer)
        if ingress then
            table.insert(route, CopyVec(ingress))
            routingStart = CopyVec(ingress)
        end
    end

    local basePath = BuildBasePath(layer, routingStart, target)
    if not basePath then
        return nil
    end

    for i = 2, table.getn(basePath) do
        table.insert(route, CopyVec(basePath[i]))
    end

    route = RemoveDuplicateRoutePoints(route, 2)
    route = RemoveRouteDoubleBack(route)
    route = CenterRouteThroughCorridors(route, layer, area)
    route = SmoothRouteCorners(route, layer, area)
    route = CenterRouteThroughCorridors(route, layer, area)
    route = SimplifyRoutePreservingSafety(route, layer)

    local stored = BuildWaypointMetadata(route, target, opts, layer, startedOutside, ingressEdge)
    SyncRouteOptions(stored, opts)
    platoon._storedRoute = stored
    return stored
end

function RebuildPlatoonRouteIfNeeded(platoon, destination, opts)
    if not platoon then
        return nil
    end

    local stored = platoon._storedRoute
    local layer = ResolveLayer(platoon, opts)
    local expectedSource = (opts and opts.RouteSource)
        or (platoon.PlatoonData and platoon.PlatoonData.RouteSource)
    local expectedOutside = nil
    if opts and opts.StartedOutsidePlayableArea ~= nil then
        expectedOutside = opts.StartedOutsidePlayableArea and true or false
    elseif platoon.PlatoonData and platoon.PlatoonData.StartedOutsidePlayableArea ~= nil then
        expectedOutside = platoon.PlatoonData.StartedOutsidePlayableArea and true or false
    end

    if opts and opts.ForceRepath then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    if not (stored and stored.destination and stored.waypoints and table.getn(stored.waypoints) > 0) then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    if DistSq(stored.destination, destination) > 400 then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    if stored.layer ~= layer then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    if expectedSource and stored.routeSource ~= expectedSource then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    if expectedOutside ~= nil and stored.startedOutsidePlayableArea ~= expectedOutside then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    return SyncRouteOptions(stored, opts)
end

local function IssueWaypointCommand(platoon, units, route, waypoint)
    if not (platoon and units and route and waypoint and waypoint.position) then
        return false
    end

    local formation = route.formation
    local position = waypoint.position
    if waypoint.useFormation and formation and formation ~= 'NoFormation' then
        platoon:SetPlatoonFormationOverride(formation)
        if waypoint.aggressiveMove then
            IssueFormAggressiveMove(units, position, formation, waypoint.facing or 0)
        else
            IssueFormMove(units, position, formation, waypoint.facing or 0)
        end
    else
        platoon:SetPlatoonFormationOverride('NoFormation')
        if waypoint.aggressiveMove then
            IssueAggressiveMove(units, position)
        else
            IssueMove(units, position)
        end
    end

    return true
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

    local queuedWaypointIndex = nil
    local index = math.max(1, math.min(stored.currentIndex or 1, table.getn(stored.waypoints)))
    while index <= table.getn(stored.waypoints) do
        local waypoint = stored.waypoints[index]
        if not waypoint then
            return 'repath'
        end

        local position = waypoint.position
        if not (position and PointPassable(stored.layer, position)) then
            return 'repath'
        end

        local platoonPos = platoon:GetPlatoonPosition()
        if not platoonPos then
            return 'fail'
        end

        if DistSq(platoonPos, stored.destination) <= FinalAttackDistanceSq then
            stored.currentIndex = index
            return 'attack'
        end

        local reachDistanceSq = waypoint.reachDistanceSq or SegmentReachDistanceSq
        if DistSq(platoonPos, position) <= reachDistanceSq then
            index = index + 1
            stored.currentIndex = index
        else
            if not SegmentPassable(stored.layer, platoonPos, position) and index > 1 then
                return 'repath'
            end

            local commandQueued = queuedWaypointIndex == index
            if commandQueued then
                queuedWaypointIndex = nil
            end

            if not commandQueued and not IssueWaypointCommand(platoon, units, stored, waypoint) then
                return 'repath'
            end

            local segmentTimeout = math.max(10, math.min(45, math.floor(SegmentLength(platoonPos, position) * 0.75) + 8))
            local stuckSeconds = 0
            local lastPos = CopyVec(platoonPos)
            local lastDistSq = DistSq(platoonPos, position)
            local nextWaypoint = stored.waypoints[index + 1]
            local queuedNextWaypoint = false

            while segmentTimeout > 0 do
                WaitSeconds(1)
                segmentTimeout = segmentTimeout - 1

                local currentPos = platoon:GetPlatoonPosition()
                if not currentPos then
                    return 'fail'
                end

                if DistSq(currentPos, stored.destination) <= FinalAttackDistanceSq then
                    stored.currentIndex = index
                    return 'attack'
                end

                local distSq = DistSq(currentPos, position)
                if waypoint.continuous and not queuedNextWaypoint and nextWaypoint and distSq <= (waypoint.queueDistanceSq or reachDistanceSq) then
                    if not IssueWaypointCommand(platoon, units, stored, nextWaypoint) then
                        return 'repath'
                    end
                    queuedWaypointIndex = index + 1
                    queuedNextWaypoint = true
                end

                if distSq <= reachDistanceSq then
                    index = index + 1
                    stored.currentIndex = index
                    break
                end

                local movedSq = DistSq(currentPos, lastPos)
                if (lastDistSq - distSq) > 4 or movedSq > 4 then
                    stuckSeconds = 0
                else
                    stuckSeconds = stuckSeconds + 1
                end

                if stuckSeconds >= 6 then
                    return 'repath'
                end

                lastPos = CopyVec(currentPos)
                lastDistSq = distSq
            end

            if segmentTimeout <= 0 and index <= table.getn(stored.waypoints) then
                return 'repath'
            end
        end
    end

    stored.currentIndex = table.getn(stored.waypoints) + 1
    if destination and DistSq(platoon:GetPlatoonPosition(), destination) <= FinalAttackDistanceSq then
        return 'attack'
    end

    return 'success'
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
    SetPointSurface(fromPos, layer)
    SetPointSurface(toPos, layer)

    local base = BuildBasePath(layer, fromPos, toPos)
    if not base then
        return nil
    end

    local centered = CenterRouteThroughCorridors(base, layer, area)
    centered = SmoothRouteCorners(centered, layer, area)
    centered = CenterRouteThroughCorridors(centered, layer, area)
    centered = SimplifyRoutePreservingSafety(centered, layer)

    local out = {}
    for i = 2, table.getn(centered) do
        table.insert(out, CopyVec(centered[i]))
    end
    return out
end

function FindSafePath(platoon, layer, destination, startOverride, opts)
    if not (platoon and destination) then
        return nil
    end

    local localOpts = {}
    if type(opts) == 'table' then
        for k, v in pairs(opts) do
            localOpts[k] = v
        end
    end
    localOpts.RouteLayer = layer
    localOpts.RouteStart = startOverride or localOpts.RouteStart

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

    local localOpts = {}
    if type(opts) == 'table' then
        for k, v in pairs(opts) do
            localOpts[k] = v
        end
    end
    localOpts.RouteLayer = layer
    localOpts.ForceRepath = true

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

function MoveAlongPath(platoon, path, formation, aggressiveFinal, layer, aggressiveRoute)
    if not (platoon and path and table.getn(path) > 0) then
        return false
    end

    local destination = path[table.getn(path)]
    if not destination then
        return false
    end

    local startPos = platoon:GetPlatoonPosition()
    if not startPos then
        return false
    end

    local routePoints = { CopyVec(startPos) }
    for _, waypoint in ipairs(path) do
        table.insert(routePoints, CopyVec(waypoint))
    end

    local metadata = BuildWaypointMetadata(routePoints, destination, {
        Formation = formation,
        AggressiveMove = aggressiveRoute and true or false,
    }, layer or ResolveLayer(platoon, nil), false, nil)

    if aggressiveFinal and table.getn(metadata.waypoints) > 0 then
        metadata.waypoints[table.getn(metadata.waypoints)].aggressiveMove = true
    end

    metadata.formation = formation
    metadata.aggressiveMove = aggressiveRoute and true or false
    platoon._storedRoute = metadata

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
        StartedOutsidePlayableArea = true,
    }

    local route = BuildPlatoonRoute(platoon, destination, opts)
    if not (route and route.waypoints and table.getn(route.waypoints) > 0) then
        return false, nil, nil
    end

    local ingress = nil
    local ingressEdge = route.ingressEdge
    for _, waypoint in ipairs(route.waypoints) do
        if waypoint and waypoint.waypointType == 'ingress' then
            ingress = waypoint.position
            break
        end
    end

    local status = FollowStoredPlatoonRoute(platoon, destination, opts)
    return status == 'attack' or status == 'success', ingress, ingressEdge or 'cardinal'
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