-- Shared routing math / heuristic helpers used by the coarse platoon router.
local HugeNumber = math.huge or 1e9

function ReadVecComponent(v, numericIndex, axisName)
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

function VecX(v)
    return ReadVecComponent(v, 1, 'x') or 0
end

function VecY(v)
    return ReadVecComponent(v, 2, 'y') or 0
end

function VecZ(v)
    return ReadVecComponent(v, 3, 'z') or 0
end

function CopyMetadata(fromPos, toPos)
    if type(fromPos) ~= 'table' or type(toPos) ~= 'table' then
        return
    end

    toPos._curve = rawget(fromPos, '_curve')
    toPos._centered = rawget(fromPos, '_centered')
    toPos._corridor = rawget(fromPos, '_corridor')
    toPos._ingress = rawget(fromPos, '_ingress')
    toPos._ingressEdge = rawget(fromPos, '_ingressEdge')
    toPos._anchor = rawget(fromPos, '_anchor')
    toPos._transitAnchor = rawget(fromPos, '_transitAnchor')
    toPos._forceStaging = rawget(fromPos, '_forceStaging')
    toPos._preAttack = rawget(fromPos, '_preAttack')
end

function CopyVec(v)
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

function BuildPoint(x, y, z)
    return { x, y or 0, z }
end

function DistSq(a, b)
    if not (a and b) then
        return HugeNumber
    end

    local dx = VecX(a) - VecX(b)
    local dz = VecZ(a) - VecZ(b)
    return dx * dx + dz * dz
end

function Lerp(a, b, t)
    return a + (b - a) * t
end

function Length2D(x, z)
    return math.sqrt((x * x) + (z * z))
end

function Normalize2D(x, z)
    local length = Length2D(x, z)
    if length < 0.001 then
        return 0, 0, 0
    end

    return x / length, z / length, length
end

function DirectionBetween(a, b)
    if not (a and b) then
        return 0, 0, 0
    end

    return Normalize2D(VecX(b) - VecX(a), VecZ(b) - VecZ(a))
end

function SegmentLength(a, b)
    local _, _, length = DirectionBetween(a, b)
    return length
end

function HeadingDegrees(a, b)
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

function NormalizeAngleDegrees(angle)
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

function AngleDeltaDegrees(a, b)
    return math.abs(NormalizeAngleDegrees((b or 0) - (a or 0)))
end

function ProjectionAlongSegment(point, segmentStart, segmentEnd)
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

function CopyOptions(opts)
    local copy = {}
    if type(opts) ~= 'table' then
        return copy
    end

    for key, value in pairs(opts) do
        copy[key] = value
    end
    return copy
end

function EstimatePlatoonFootprint(platoon, formation, opts)
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    local count = table.getn(units or {})
    local unitScale = math.max(1, math.sqrt(math.max(1, count)))
    local formationFactor = 1

    if formation == 'AttackFormation' then
        formationFactor = 0.9
    elseif formation == 'GrowthFormation' then
        formationFactor = 1.15
    elseif formation == 'NoFormation' then
        formationFactor = 0.75
    end

    if opts and opts.FormationFootprintScale then
        formationFactor = formationFactor * math.max(0.5, opts.FormationFootprintScale)
    end

    return math.max(8, unitScale * 4.5 * formationFactor)
end

function ResolveAssaultTransitionRadius(route, opts)
    local assaultRadius = route and route.assaultRadius or (opts and opts.AssaultRadius) or 40
    local stagingRadius = route and route.stagingRadius or (opts and opts.StagingRadius) or 72
    local leadDistance = route and route.assaultLeadDistance or (opts and opts.AssaultLeadDistance) or 24
    local formationFootprint = route and route.formationFootprint or (opts and opts.FormationFootprint) or 0

    local footprintLead = math.max(0, formationFootprint * 0.6)
    return math.max(assaultRadius, stagingRadius + leadDistance + footprintLead)
end

function DetermineSegmentAggression(route, waypoint, waypointIndex, waypointCount, opts)
    if not (opts and opts.AggressiveMove) then
        return false, 'move'
    end

    local waypointType = waypoint and waypoint.waypointType or 'transit'
    if waypointType == 'ingress' or waypointType == 'corridor' or waypointType == 'curve' then
        return false, 'move'
    end

    local distanceToTargetSq = route and route.targetPosition and waypoint and waypoint.position and DistSq(waypoint.position, route.targetPosition) or HugeNumber
    local stagingRadius = route and route.stagingRadius or (opts and opts.StagingRadius) or 72
    local assaultRadius = route and route.assaultRadius or (opts and opts.AssaultRadius) or 40
    local assaultTransitionRadius = ResolveAssaultTransitionRadius(route, opts)

    if distanceToTargetSq <= (assaultTransitionRadius * assaultTransitionRadius) then
        return true, 'aggressive'
    end

    if waypointIndex >= math.max(1, waypointCount - 1)
        and distanceToTargetSq <= ((assaultTransitionRadius + 12) * (assaultTransitionRadius + 12))
    then
        return true, 'aggressive'
    end

    if waypointType == 'pre-attack' and distanceToTargetSq <= ((math.max(assaultTransitionRadius, assaultRadius + 35)) * (math.max(assaultTransitionRadius, assaultRadius + 35))) then
        return true, 'aggressive'
    end

    return false, 'move'
end

return {
    HugeNumber = HugeNumber,
    ReadVecComponent = ReadVecComponent,
    VecX = VecX,
    VecY = VecY,
    VecZ = VecZ,
    CopyMetadata = CopyMetadata,
    CopyVec = CopyVec,
    BuildPoint = BuildPoint,
    DistSq = DistSq,
    Lerp = Lerp,
    Length2D = Length2D,
    Normalize2D = Normalize2D,
    DirectionBetween = DirectionBetween,
    SegmentLength = SegmentLength,
    HeadingDegrees = HeadingDegrees,
    NormalizeAngleDegrees = NormalizeAngleDegrees,
    AngleDeltaDegrees = AngleDeltaDegrees,
    ProjectionAlongSegment = ProjectionAlongSegment,
    CopyOptions = CopyOptions,
    EstimatePlatoonFootprint = EstimatePlatoonFootprint,
    ResolveAssaultTransitionRadius = ResolveAssaultTransitionRadius,
    DetermineSegmentAggression = DetermineSegmentAggression,
}