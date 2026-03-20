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

local CohesionMainBodyRadiusSq = 30 * 30
local CohesionStragglerDistanceSq = 54 * 54
local CohesionWorstOutlierDistanceSq = 62 * 62
local CohesionReformOutlierRatio = 0.40
local CohesionReformMinMissingUnits = 2
local CohesionPersistentSamples = 3
local CohesionRecoverySamples = 2
local CohesionReformCooldown = 14
local CohesionReformGracePeriod = 6
local PlatoonTraversalQueueWindow = 3
local RouteStuckTimeout = 10
local RandomizedRouteMaxCandidates = 3
local RandomizedRouteLengthSlack = 1.35

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

local function UnitDistanceSqToPoint(unit, point)
    if not (unit and point and unit.GetPosition) then
        return math.huge
    end

    local pos = unit:GetPosition()
    if not pos then
        return math.huge
    end

    local dx = (pos[1] or 0) - VecX(point)
    local dz = (pos[3] or 0) - VecZ(point)
    return (dx * dx) + (dz * dz)
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
    if not platoon then
        return false
    end

    local brain = SafeGetBrain(platoon)
    if not brain then
        return false
    end

    if not brain:PlatoonExists(platoon) then
        return false
    end

    local units = platoon:GetPlatoonUnits()
    return units and table.getn(units) > 0
end

local function GetRandomInt(minValue, maxValue)
    if maxValue <= minValue then
        return minValue
    end

    if Random then
        return Random(minValue, maxValue)
    end

    return math.random(minValue, maxValue)
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

local function NormalizeAngleDegrees(angle)
    local value = angle or 0
    local turns = value >= 0 and math.floor(value / 360) or math.ceil(value / 360)
    local normalized = value - (turns * 360)
    if normalized > 180 then
        normalized = normalized - 360
    elseif normalized < -180 then
        normalized = normalized + 360
    end
    return normalized
end

local function AngleDeltaDegrees(a, b)
    return math.abs(NormalizeAngleDegrees((b or 0) - (a or 0)))
end

local function ProjectionAlongSegment(point, segmentStart, segmentEnd)
    if not (point and segmentStart and segmentEnd) then
        return 0, 0
    end

    local dirX, dirZ, length = DirectionBetween(segmentStart, segmentEnd)
    if length < 0.001 then
        return 0, 0
    end

    local fromStartX = VecX(point) - VecX(segmentStart)
    local fromStartZ = VecZ(point) - VecZ(segmentStart)
    return (fromStartX * dirX) + (fromStartZ * dirZ), length
end

local function DetermineWaypointFacing(prevPoint, point, nextPoint, waypointType, continuous)
    local arrivalFacing = HeadingDegrees(prevPoint, point)
    local departureFacing = HeadingDegrees(point, nextPoint)
    local nextDistanceSq = DistSq(point, nextPoint)

    if not nextPoint or nextDistanceSq <= 1 then
        departureFacing = arrivalFacing
    end

    local flowFacing = arrivalFacing
    if nextPoint and nextDistanceSq > 1 then
        flowFacing = HeadingDegrees(prevPoint, nextPoint)
    end

    local commandFacing = arrivalFacing
    if continuous then
        if waypointType == 'curve' then
            commandFacing = departureFacing
        else
            commandFacing = flowFacing
        end
    elseif waypointType == 'pre-attack' or waypointType == 'staging' then
        commandFacing = arrivalFacing
    elseif waypointType == 'curve' then
        commandFacing = departureFacing
    elseif waypointType == 'transit' or waypointType == 'corridor' or waypointType == 'ingress' then
        commandFacing = flowFacing
    end

    return arrivalFacing, departureFacing, flowFacing, commandFacing
end

local function DetermineWaypointQueueDistanceSq(waypointType, segmentLength, nextSegmentLength, turnAngle)
    if waypointType == 'pre-attack' or waypointType == 'staging' then
        return SegmentReachDistanceSq
    end

    local lookahead = math.max(10, math.min(segmentLength * 0.45, 24))
    if waypointType == 'corridor' then
        lookahead = math.max(12, math.min(segmentLength * 0.50, 20))
    elseif waypointType == 'curve' then
        lookahead = math.max(10, math.min(segmentLength * 0.40, 16))
    elseif waypointType == 'ingress' then
        lookahead = math.max(11, math.min(segmentLength * 0.45, 18))
    end

    if nextSegmentLength and nextSegmentLength > 0 then
        lookahead = math.min(lookahead, math.max(8, nextSegmentLength * 0.50))
    end

    if turnAngle >= 95 then
        lookahead = math.max(7, lookahead * 0.60)
    elseif turnAngle >= 55 then
        lookahead = math.max(8, lookahead * 0.75)
    elseif turnAngle <= 20 then
        lookahead = math.min(24, lookahead * 1.15)
    end

    return math.max(SegmentReachDistanceSq, lookahead * lookahead)
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

local function AppendRouteSegment(route, segment)
    if not (route and segment and table.getn(segment) > 0) then
        return route
    end

    for index = 1, table.getn(segment) do
        local point = segment[index]
        if point then
            local shouldInsert = true
            if table.getn(route) > 0 and DistSq(route[table.getn(route)], point) <= 1 then
                shouldInsert = false
            end
            if shouldInsert then
                table.insert(route, CopyVec(point))
            end
        end
    end

    return route
end

local function ComputeRouteLength(route)
    if not route or table.getn(route) <= 1 then
        return 0
    end

    local length = 0
    for i = 2, table.getn(route) do
        length = length + SegmentLength(route[i - 1], route[i])
    end
    return length
end

local function BuildPathViaAnchors(layer, startPos, target, anchors)
    if not (startPos and target) then
        return nil
    end

    local route = { CopyVec(startPos) }
    local current = startPos

    for _, anchor in ipairs(anchors or {}) do
        local segment = BuildBasePath(layer, current, anchor)
        if not segment then
            return nil
        end
        AppendRouteSegment(route, segment)
        current = anchor
    end

    local finalSegment = BuildBasePath(layer, current, target)
    if not finalSegment then
        return nil
    end
    AppendRouteSegment(route, finalSegment)
    return route
end

local function BuildRandomizedRouteVariant(layer, startPos, target, area, sideSign)
    if not (startPos and target and sideSign and sideSign ~= 0) then
        return nil
    end

    local dirX, dirZ, totalLength = DirectionBetween(startPos, target)
    if totalLength < 24 then
        return nil
    end

    local normalX = -dirZ * sideSign
    local normalZ = dirX * sideSign
    local offsetDistance = math.max(18, math.min(totalLength * 0.22, 56))
    local leadDistance = math.max(10, math.min(totalLength * 0.18, 28))
    local fractions = { 0.35, 0.65 }
    local anchors = {}

    for _, fraction in ipairs(fractions) do
        local alongDistance = totalLength * fraction
        local anchor = {
            VecX(startPos) + (dirX * alongDistance) + (normalX * offsetDistance),
            0,
            VecZ(startPos) + (dirZ * alongDistance) + (normalZ * offsetDistance),
        }
        anchor = OffsetPoint(anchor, dirX * leadDistance, dirZ * leadDistance)
        if area then
            anchor = ClampToPlayableArea(anchor, area, 8)
        end
        SetPointSurface(anchor, layer)

        if PointPassable(layer, anchor) then
            anchor._anchor = true
            table.insert(anchors, anchor)
        end
    end

    if table.getn(anchors) == 0 then
        return nil
    end

    return BuildPathViaAnchors(layer, startPos, target, anchors)
end

local function CollectRouteCandidates(layer, startPos, target, opts, area)
    local candidates = {}
    local baseRoute = BuildBasePath(layer, startPos, target)
    if baseRoute then
        table.insert(candidates, {
            path = baseRoute,
            routeType = 'default',
            quality = ComputeRouteLength(baseRoute),
        })
    end

    if opts and opts.RandomizeRoute then
        for _, sideSign in ipairs({ -1, 1 }) do
            local variant = BuildRandomizedRouteVariant(layer, startPos, target, area, sideSign)
            if variant and table.getn(variant) > 1 then
                table.insert(candidates, {
                    path = variant,
                    routeType = sideSign < 0 and 'left-flank' or 'right-flank',
                    quality = ComputeRouteLength(variant),
                })
            end
        end
    end

    if table.getn(candidates) == 0 then
        return nil
    end

    table.sort(candidates, function(a, b)
        return (a.quality or math.huge) < (b.quality or math.huge)
    end)
    return candidates
end

local function SelectRouteCandidate(candidates, opts)
    if not (candidates and table.getn(candidates) > 0) then
        return nil
    end

    local best = candidates[1]
    if not (opts and opts.RandomizeRoute) then
        return best
    end

    local bestLength = best.quality or math.huge
    local viable = {}
    for _, candidate in ipairs(candidates) do
        local quality = candidate.quality or math.huge
        if quality <= (bestLength * RandomizedRouteLengthSlack) then
            table.insert(viable, candidate)
        end
        if table.getn(viable) >= RandomizedRouteMaxCandidates then
            break
        end
    end

    if table.getn(viable) == 0 then
        return best
    end

    return viable[GetRandomInt(1, table.getn(viable))]
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

local function DetermineWaypointType(point, index, routeCount)
    if index == routeCount then
        return 'pre-attack', true
    end

    if point._corridor then
        return 'corridor', false
    end

    if point._curve then
        return 'curve', false
    end

    if point._ingress then
        return 'ingress', false
    end

    if point._anchor then
        return 'staging', true
    end

    return 'transit', false
end

local function GetPlatoonMainBodyCenter(units)
    if not units then
        return nil, 0
    end

    local positions = {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead and unit.GetPosition then
            local pos = unit:GetPosition()
            if pos then
                table.insert(positions, { pos[1] or 0, pos[2] or 0, pos[3] or 0 })
            end
        end
    end

    local count = table.getn(positions)
    if count == 0 then
        return nil, 0
    end

    local bestCenter = positions[1]
    local bestCount = 0
    local bestScore = math.huge

    for _, candidate in ipairs(positions) do
        local clusterCount = 0
        local clusterScore = 0
        for _, other in ipairs(positions) do
            local distanceSq = DistSq(candidate, other)
            if distanceSq <= CohesionMainBodyRadiusSq then
                clusterCount = clusterCount + 1
                clusterScore = clusterScore + distanceSq
            end
        end

        if clusterCount > bestCount or (clusterCount == bestCount and clusterScore < bestScore) then
            bestCenter = candidate
            bestCount = clusterCount
            bestScore = clusterScore
        end
    end

    local sumX = 0
    local sumY = 0
    local sumZ = 0
    local mainBodyCount = 0
    for _, pos in ipairs(positions) do
        if DistSq(bestCenter, pos) <= CohesionMainBodyRadiusSq then
            sumX = sumX + VecX(pos)
            sumY = sumY + VecY(pos)
            sumZ = sumZ + VecZ(pos)
            mainBodyCount = mainBodyCount + 1
        end
    end

    if mainBodyCount == 0 then
        return CopyVec(bestCenter), bestCount
    end

    return { sumX / mainBodyCount, sumY / mainBodyCount, sumZ / mainBodyCount }, mainBodyCount
end

local function IsPlatoonCohesionBroken(units, route)
    local mainBodyCenter, mainBodyCount = GetPlatoonMainBodyCenter(units)
    if not mainBodyCenter then
        return false, nil
    end

    local totalUnits = 0
    local outliers = 0
    local severeOutliers = 0
    local worstDistanceSq = 0
    for _, unit in ipairs(units or {}) do
        if unit and not unit.Dead then
            totalUnits = totalUnits + 1
            local distanceSq = UnitDistanceSqToPoint(unit, mainBodyCenter)
            if distanceSq > CohesionStragglerDistanceSq then
                outliers = outliers + 1
                if distanceSq > CohesionWorstOutlierDistanceSq then
                    severeOutliers = severeOutliers + 1
                end
                if distanceSq > worstDistanceSq then
                    worstDistanceSq = distanceSq
                end
            end
        end
    end

    local details = {
        center = mainBodyCenter,
        totalUnits = totalUnits,
        mainBodyCount = mainBodyCount,
        outliers = outliers,
        severeOutliers = severeOutliers,
        worstDistanceSq = worstDistanceSq,
    }

    if totalUnits <= 2 then
        return false, details
    end

    local missingForReform = math.max(
        CohesionReformMinMissingUnits,
        math.ceil(totalUnits * CohesionReformOutlierRatio)
    )
    details.missingForReform = missingForReform

    local mainBodyStable = mainBodyCount >= math.max(2, math.ceil(totalUnits * 0.55))
    local enoughOutliers = outliers >= missingForReform
    local severeBreak = severeOutliers >= math.max(1, math.floor(missingForReform * 0.5))
    local broken = mainBodyStable and enoughOutliers and (severeBreak or outliers >= (missingForReform + 1))

    return broken, details
end

local function ShouldReformPlatoon(route, units, currentTime)
    if not route then
        return false, nil
    end

    local broken, details = IsPlatoonCohesionBroken(units, route)
    route.cohesionBroken = broken and true or false
    route.cohesionState = details

    if broken then
        route.cohesionBrokenSamples = (route.cohesionBrokenSamples or 0) + 1
        route.cohesionStableSamples = 0
        route.cohesionBrokenSince = route.cohesionBrokenSince or currentTime
    else
        route.cohesionBrokenSamples = 0
        route.cohesionBrokenSince = nil
        route.cohesionStableSamples = math.min(CohesionRecoverySamples, (route.cohesionStableSamples or 0) + 1)
        route.needsReform = false
        return false, details
    end

    local reformCooldown = route.reformCooldown or CohesionReformCooldown
    local lastReformTime = route.lastReformTime or -math.huge
    if currentTime < (lastReformTime + reformCooldown) then
        return false, details
    end

    local firstIssueTime = route.initialFormIssuedTime or route.createdAt or 0
    if currentTime < (firstIssueTime + CohesionReformGracePeriod) then
        return false, details
    end

    if (route.cohesionBrokenSamples or 0) < CohesionPersistentSamples then
        return false, details
    end

    route.needsReform = true
    return true, details
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
        local waypointType, staging = DetermineWaypointType(point, i, table.getn(route))
        local continuous = not staging

        local arrivalFacing, departureFacing, flowFacing, commandFacing = DetermineWaypointFacing(prevPoint, point, nextPoint, waypointType, continuous)
        local segmentLength = SegmentLength(prevPoint, point)
        local nextSegmentLength = SegmentLength(point, nextPoint)
        local turnAngle = AngleDeltaDegrees(arrivalFacing, departureFacing)
        local reachDistanceSq = continuous and ContinuousReachDistanceSq or SegmentReachDistanceSq

        table.insert(metadata, {
            position = point,
            aggressiveMove = aggressiveMove,
            facing = commandFacing,
            arrivalFacing = arrivalFacing,
            departureFacing = departureFacing,
            flowFacing = flowFacing,
            commandFacing = commandFacing,
            waypointType = waypointType,
            staging = staging,
            continuous = continuous,
            reachDistanceSq = reachDistanceSq,
            queueDistanceSq = continuous and DetermineWaypointQueueDistanceSq(waypointType, segmentLength, nextSegmentLength, turnAngle) or reachDistanceSq,
            segmentStart = CopyVec(prevPoint),
            segmentEnd = CopyVec(point),
            nextSegmentEnd = CopyVec(nextPoint),
            segmentLength = segmentLength,
            nextSegmentLength = nextSegmentLength,
            turnAngle = turnAngle,
        })
    end

    RouteStamp = RouteStamp + 1
    return {
        stamp = RouteStamp,
        createdAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0,
        currentIndex = 1,
        lastQueuedIndex = 0,
        lastIssuedIndex = nil,
        lastIssuedTime = nil,
        initialFormIssued = false,
        initialFormIssuedTime = nil,
        needsReform = false,
        cohesionBroken = false,
        cohesionState = nil,
        cohesionBrokenSamples = 0,
        cohesionStableSamples = 0,
        cohesionBrokenSince = nil,
        lastReformTime = nil,
        reformCooldown = (opts and opts.ReformCooldown) or CohesionReformCooldown,
        queueWindow = (opts and opts.QueueWindow) or PlatoonTraversalQueueWindow,
        destination = CopyVec(destination),
        targetPosition = opts and opts.TargetPosition and CopyVec(opts.TargetPosition) or CopyVec(destination),
        targetZone = opts and opts.TargetZone or nil,
        layer = layer,
        aggressiveMove = aggressiveMove,
        formation = formation,
        routeSource = opts and opts.RouteSource or nil,
        randomizeRoute = opts and opts.RandomizeRoute and true or false,
        routeVariant = opts and opts.RouteVariant or 'default',
        startedOutsidePlayableArea = startedOutside and true or false,
        ingressEdge = ingressEdge,
        waypoints = metadata,
        queuedIndex = nil,
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
    if opts and opts.RandomizeRoute ~= nil then
        route.randomizeRoute = opts.RandomizeRoute and true or false
    end
    if opts and opts.RouteVariant ~= nil then
        route.routeVariant = opts.RouteVariant
    end
    if opts and opts.QueueWindow ~= nil then
        route.queueWindow = math.max(1, opts.QueueWindow)
    end

    for _, waypoint in ipairs(route.waypoints or {}) do
        waypoint.aggressiveMove = route.aggressiveMove
        if waypoint.segmentStart and waypoint.segmentEnd then
            waypoint.arrivalFacing, waypoint.departureFacing, waypoint.flowFacing, waypoint.commandFacing = DetermineWaypointFacing(
                waypoint.segmentStart,
                waypoint.segmentEnd,
                waypoint.nextSegmentEnd,
                waypoint.waypointType,
                waypoint.continuous
            )
            waypoint.facing = waypoint.commandFacing
            waypoint.segmentLength = SegmentLength(waypoint.segmentStart, waypoint.segmentEnd)
        end
        if waypoint.segmentEnd and waypoint.nextSegmentEnd then
            waypoint.nextSegmentLength = SegmentLength(waypoint.segmentEnd, waypoint.nextSegmentEnd)
            if DistSq(waypoint.segmentEnd, waypoint.nextSegmentEnd) <= 1 then
                waypoint.departureFacing = waypoint.arrivalFacing or waypoint.departureFacing
            end
        else
            waypoint.departureFacing = waypoint.arrivalFacing or waypoint.facing
            waypoint.nextSegmentLength = 0
        end
        waypoint.turnAngle = AngleDeltaDegrees(waypoint.arrivalFacing, waypoint.departureFacing)
        waypoint.queueDistanceSq = waypoint.continuous
            and DetermineWaypointQueueDistanceSq(
                waypoint.waypointType,
                waypoint.segmentLength or 0,
                waypoint.nextSegmentLength or 0,
                waypoint.turnAngle or 0
            )
            or (waypoint.reachDistanceSq or SegmentReachDistanceSq)
    end

    route.queuedIndex = route.lastQueuedIndex and route.lastQueuedIndex > 0 and route.lastQueuedIndex or nil
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

    local candidates = CollectRouteCandidates(layer, routingStart, target, opts, area)
    local selected = SelectRouteCandidate(candidates, opts)
    if not (selected and selected.path) then
        return nil
    end

    for i = 2, table.getn(selected.path) do
        table.insert(route, CopyVec(selected.path[i]))
    end

    route = RemoveDuplicateRoutePoints(route, 2)
    route = RemoveRouteDoubleBack(route)
    route = CenterRouteThroughCorridors(route, layer, area)
    route = SmoothRouteCorners(route, layer, area)
    route = CenterRouteThroughCorridors(route, layer, area)
    route = SimplifyRoutePreservingSafety(route, layer)

    local buildOpts = {}
    if type(opts) == 'table' then
        for k, v in pairs(opts) do
            buildOpts[k] = v
        end
    end
    buildOpts.RouteVariant = selected.routeType or 'default'

    local stored = BuildWaypointMetadata(route, target, buildOpts, layer, startedOutside, ingressEdge)
    SyncRouteOptions(stored, buildOpts)
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

    if opts and opts.RandomizeRoute ~= nil and stored.randomizeRoute ~= (opts.RandomizeRoute and true or false) then
        return BuildPlatoonRoute(platoon, destination, opts)
    end

    return SyncRouteOptions(stored, opts)
end

local function HasWaypointBeenPassed(platoonPos, waypoint, nextWaypoint)
    if not (platoonPos and waypoint and waypoint.position) then
        return false
    end

    local reachDistanceSq = waypoint.reachDistanceSq or SegmentReachDistanceSq
    local distSq = DistSq(platoonPos, waypoint.position)
    if distSq <= reachDistanceSq then
        return true
    end

    local progress, segmentLength = ProjectionAlongSegment(platoonPos, waypoint.segmentStart, waypoint.segmentEnd)
    if segmentLength > 0 and progress >= math.max(segmentLength - 2, segmentLength * 0.92) then
        return true
    end

    if nextWaypoint and nextWaypoint.position and segmentLength > 0 and progress >= math.max(segmentLength * 0.70, segmentLength - 5) then
        local nextDistSq = DistSq(platoonPos, nextWaypoint.position)
        if nextDistSq + 16 < distSq then
            return true
        end
    end

    return false
end

local function AdvanceStoredRouteIndex(stored, nextIndex)
    stored.currentIndex = nextIndex
    if stored.lastQueuedIndex and stored.lastQueuedIndex < nextIndex then
        stored.lastQueuedIndex = nextIndex - 1
    end
    stored.queuedIndex = stored.lastQueuedIndex and stored.lastQueuedIndex > 0 and stored.lastQueuedIndex or nil
end

local function ResetQueuedTraversal(route, anchorIndex)
    if not route then
        return
    end

    route.lastQueuedIndex = math.max(0, (anchorIndex or route.currentIndex or 1) - 1)
    route.queuedIndex = route.lastQueuedIndex > 0 and route.lastQueuedIndex or nil
end

local function QueuePlatoonMove(platoon, aggressiveMove, position)
    if not (platoon and position) then
        return false
    end

    if aggressiveMove then
        if not platoon.AggressiveMoveToLocation then
            return false
        end
        local ok = pcall(platoon.AggressiveMoveToLocation, platoon, position)
        return ok
    end

    if not platoon.MoveToLocation then
        return false
    end

    local ok = pcall(platoon.MoveToLocation, platoon, position, false)
    return ok
end

local function QueueTraversalWindow(platoon, route)
    if not (platoon and route and route.waypoints) then
        return false
    end

    local waypointCount = table.getn(route.waypoints)
    if waypointCount == 0 then
        return false
    end

    local currentIndex = math.max(1, math.min(route.currentIndex or 1, waypointCount))
    local queueWindow = math.max(1, route.queueWindow or PlatoonTraversalQueueWindow)
    local queueLimit = math.min(waypointCount, currentIndex + queueWindow - 1)
    local nextIndex = math.max(currentIndex, (route.lastQueuedIndex or 0) + 1)

    for waypointIndex = nextIndex, queueLimit do
        local waypoint = route.waypoints[waypointIndex]
        if not (waypoint and waypoint.position and PointPassable(route.layer, waypoint.position)) then
            return false
        end

        if not QueuePlatoonMove(platoon, waypoint.aggressiveMove, waypoint.position) then
            return false
        end

        route.lastQueuedIndex = waypointIndex
        route.lastIssuedIndex = waypointIndex
        route.lastIssuedTime = GetGameTimeSeconds and GetGameTimeSeconds() or route.lastIssuedTime
    end

    route.queuedIndex = route.lastQueuedIndex and route.lastQueuedIndex > 0 and route.lastQueuedIndex or nil
    return true
end

local function IssueFormationOrder(platoon, units, route, waypoint, waypointIndex, commandMode)
    if not (platoon and units and route and waypoint and waypoint.position) then
        return false
    end

    local gameTime = GetGameTimeSeconds and GetGameTimeSeconds() or 0
    local formation = route.formation
    local useFormation = formation and formation ~= 'NoFormation'
    local facing = waypoint.commandFacing or waypoint.arrivalFacing or waypoint.flowFacing or waypoint.facing or 0

    IssueClearCommands(units)

    if useFormation then
        platoon:SetPlatoonFormationOverride(formation)
        if route.aggressiveMove then
            IssueFormAggressiveMove(units, waypoint.position, formation, facing)
        else
            IssueFormMove(units, waypoint.position, formation, facing)
        end
    else
        platoon:SetPlatoonFormationOverride('NoFormation')
        if not QueuePlatoonMove(platoon, route.aggressiveMove, waypoint.position) then
            return false
        end
    end

    if commandMode == 'initial-form' then
        route.initialFormIssued = true
        route.initialFormIssuedTime = gameTime
    elseif commandMode == 'reform' then
        route.lastReformTime = gameTime
        route.needsReform = false
        route.cohesionBroken = false
        route.cohesionBrokenSamples = 0
        route.cohesionStableSamples = 0
        route.cohesionBrokenSince = nil
    end

    route.lastIssuedIndex = waypointIndex or route.lastIssuedIndex
    route.lastIssuedTime = gameTime
    ResetQueuedTraversal(route, (waypointIndex or route.currentIndex or 1) + 1)
    return true
end

local function IssueInitialFormationOrder(platoon, units, route, waypoint, waypointIndex)
    return IssueFormationOrder(platoon, units, route, waypoint, waypointIndex, 'initial-form')
end

local function IssueCohesionRecoveryReform(platoon, units, route, waypoint, waypointIndex)
    return IssueFormationOrder(platoon, units, route, waypoint, waypointIndex, 'reform')
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

    local waypointCount = table.getn(stored.waypoints)
    stored.currentIndex = math.max(1, math.min(stored.currentIndex or 1, waypointCount))
    stored.lastQueuedIndex = math.max(0, math.min(stored.lastQueuedIndex or 0, waypointCount))
    stored.queuedIndex = stored.lastQueuedIndex > 0 and stored.lastQueuedIndex or nil

    local lastProgressTime = GetGameTimeSeconds and GetGameTimeSeconds() or 0
    local initialPlatoonPos = platoon:GetPlatoonPosition()
    local lastProgressPosition = initialPlatoonPos and CopyVec(initialPlatoonPos) or nil
    local lastProgressIndex = stored.currentIndex
    local lastProgressDistanceSq = math.huge

    while PlatoonAlive(platoon) do
        local platoonPos = platoon:GetPlatoonPosition()
        if not platoonPos then
            return 'fail'
        end

        if DistSq(platoonPos, stored.destination) <= FinalAttackDistanceSq then
            return 'attack'
        end

        while stored.currentIndex <= waypointCount do
            local waypoint = stored.waypoints[stored.currentIndex]
            local nextWaypoint = stored.waypoints[stored.currentIndex + 1]
            if not waypoint then
                return 'repath'
            end
            if not (waypoint.position and PointPassable(stored.layer, waypoint.position)) then
                return 'repath'
            end
            if not HasWaypointBeenPassed(platoonPos, waypoint, nextWaypoint) then
                break
            end
            AdvanceStoredRouteIndex(stored, stored.currentIndex + 1)
        end

        if stored.currentIndex > waypointCount then
            if destination and DistSq(platoonPos, destination) <= FinalAttackDistanceSq then
                return 'attack'
            end
            return 'success'
        end

        local currentWaypoint = stored.waypoints[stored.currentIndex]
        if not currentWaypoint then
            return 'repath'
        end
        if not stored.initialFormIssued then
            if not IssueInitialFormationOrder(platoon, units, stored, currentWaypoint, stored.currentIndex) then
                return 'repath'
            end
            if not QueueTraversalWindow(platoon, stored) then
                return 'repath'
            end
            lastProgressTime = GetGameTimeSeconds and GetGameTimeSeconds() or lastProgressTime
            lastProgressPosition = CopyVec(platoonPos)
            lastProgressIndex = stored.currentIndex
            lastProgressDistanceSq = DistSq(platoonPos, currentWaypoint.position)
        else
            local currentTime = GetGameTimeSeconds and GetGameTimeSeconds() or 0
            local shouldReform = ShouldReformPlatoon(stored, units, currentTime)
            if shouldReform then
                if not IssueCohesionRecoveryReform(platoon, units, stored, currentWaypoint, stored.currentIndex) then
                    return 'repath'
                end
                if not QueueTraversalWindow(platoon, stored) then
                    return 'repath'
                end
                lastProgressTime = currentTime
                lastProgressPosition = CopyVec(platoonPos)
                lastProgressIndex = stored.currentIndex
                lastProgressDistanceSq = DistSq(platoonPos, currentWaypoint.position)
            elseif (stored.lastQueuedIndex or 0) < math.min(waypointCount, stored.currentIndex + math.max(1, stored.queueWindow or PlatoonTraversalQueueWindow) - 1) then
                if not QueueTraversalWindow(platoon, stored) then
                    return 'repath'
                end
            end
        end

        local distanceToWaypointSq = DistSq(platoonPos, currentWaypoint.position)
        local movedSq = lastProgressPosition and DistSq(platoonPos, lastProgressPosition) or math.huge
        local routeAdvanced = stored.currentIndex > lastProgressIndex
        local madeMovementProgress = movedSq > 9
        local madePathProgress = routeAdvanced or (lastProgressDistanceSq - distanceToWaypointSq) > 16

        if routeAdvanced or madeMovementProgress or madePathProgress then
            lastProgressTime = GetGameTimeSeconds and GetGameTimeSeconds() or lastProgressTime
            lastProgressPosition = CopyVec(platoonPos)
            lastProgressIndex = stored.currentIndex
            lastProgressDistanceSq = distanceToWaypointSq
        elseif (GetGameTimeSeconds and GetGameTimeSeconds() or 0) >= (lastProgressTime + RouteStuckTimeout) then
            return 'repath'
        end

        WaitSeconds(1)
    end

    return 'fail'
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