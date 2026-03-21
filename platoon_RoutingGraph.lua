-- Lazy scenario-scoped routing graph/cache helpers for platoon route selection.
local function ResolveSiblingModule(fileName, fallbackPath)
    local ok, info = pcall(debug.getinfo, 1, 'S')
    if ok and info and info.source then
        local src = info.source
        if type(src) == 'string' and string.sub(src, 1, 1) == '@' then
            local dir = string.match(src, '^@(.*/)[^/]*$')
            if dir then
                local okImport, mod = pcall(import, dir .. fileName)
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
                local okImport, mod = pcall(import, dir .. '/' .. fileName)
                if okImport and mod then
                    return mod
                end
            end
        end
    end

    return import(fallbackPath)
end

local Utils = ResolveSiblingModule('platoon_RoutingUtils.lua', '/maps/faf_coop_U01.v0001/platoon_RoutingUtils.lua')

local DistSq = Utils.DistSq
local HeadingDegrees = Utils.HeadingDegrees
local AngleDeltaDegrees = Utils.AngleDeltaDegrees

local HugeNumber = math.huge or 1e9
local RandomizedRouteMaxCandidates = 4
local RandomizedRouteLengthSlack = 1.55

local GraphCache = false

local function DeepCopyVariantSpecs(specs)
    local copy = {}
    for _, spec in ipairs(specs or {}) do
        local specCopy = {}
        for key, value in pairs(spec) do
            if type(value) == 'table' then
                local valueCopy = {}
                for index, item in ipairs(value) do
                    if type(item) == 'table' then
                        local itemCopy = {}
                        for itemKey, itemValue in pairs(item) do
                            itemCopy[itemKey] = itemValue
                        end
                        valueCopy[index] = itemCopy
                    else
                        valueCopy[index] = item
                    end
                end
                specCopy[key] = valueCopy
            else
                specCopy[key] = value
            end
        end
        table.insert(copy, specCopy)
    end
    return copy
end

local function ResolveMapKey(area)
    local mapName = ScenarioInfo and (ScenarioInfo.name or ScenarioInfo.map or ScenarioInfo.MapName) or 'unknown-map'
    if area then
        return string.format('%s:%s:%s:%s:%s', mapName, area[1] or 0, area[2] or 0, area[3] or 0, area[4] or 0)
    end
    return tostring(mapName)
end

local function BuildGraphCache(area)
    return {
        key = ResolveMapKey(area),
        area = area,
        cardinalIngress = {
            left = { axis = 'x', sign = 1 },
            right = { axis = 'x', sign = -1 },
            bottom = { axis = 'z', sign = 1 },
            top = { axis = 'z', sign = -1 },
        },
        variantSpecs = {
            { routeType = 'left-wide', sideSign = -1, lateralScale = 0.30, fractions = { { 0.22, 0.65 }, { 0.48, 1.0 }, { 0.74, 0.85 } }, approachOffset = 0.95, approachBackoff = 0.20, maxOffset = 96, bias = 'wide-flank' },
            { routeType = 'left-deep', sideSign = -1, lateralScale = 0.38, fractions = { { 0.18, 0.75 }, { 0.42, 1.10 }, { 0.68, 1.0 } }, approachOffset = 1.15, approachBackoff = 0.24, maxOffset = 112, bias = 'deep-flank' },
            { routeType = 'right-wide', sideSign = 1, lateralScale = 0.30, fractions = { { 0.22, 0.65 }, { 0.48, 1.0 }, { 0.74, 0.85 } }, approachOffset = 0.95, approachBackoff = 0.20, maxOffset = 96, bias = 'wide-flank' },
            { routeType = 'right-deep', sideSign = 1, lateralScale = 0.38, fractions = { { 0.18, 0.75 }, { 0.42, 1.10 }, { 0.68, 1.0 } }, approachOffset = 1.15, approachBackoff = 0.24, maxOffset = 112, bias = 'deep-flank' },
            { routeType = 'left-late', sideSign = -1, lateralScale = 0.25, fractions = { { 0.34, 0.45 }, { 0.60, 0.90 } }, approachOffset = 1.20, approachBackoff = 0.28, maxOffset = 84, bias = 'late-flank' },
            { routeType = 'right-late', sideSign = 1, lateralScale = 0.25, fractions = { { 0.34, 0.45 }, { 0.60, 0.90 } }, approachOffset = 1.20, approachBackoff = 0.28, maxOffset = 84, bias = 'late-flank' },
        },
    }
end

local function GetScenarioGraph(area)
    local key = ResolveMapKey(area)
    if not GraphCache or GraphCache.key ~= key then
        GraphCache = BuildGraphCache(area)
    end
    return GraphCache
end

local function GetVariantSpecs(area, opts)
    local cache = GetScenarioGraph(area)
    local specs = DeepCopyVariantSpecs(cache.variantSpecs)
    if opts and opts.FlankPreference == 'left' then
        table.sort(specs, function(a, b)
            return (a.sideSign or 0) < (b.sideSign or 0)
        end)
    elseif opts and opts.FlankPreference == 'right' then
        table.sort(specs, function(a, b)
            return (a.sideSign or 0) > (b.sideSign or 0)
        end)
    end
    return specs
end

local function RoutePathSeparation(route, reference)
    if not (route and reference and table.getn(route) > 0 and table.getn(reference) > 0) then
        return 0
    end

    local total = 0
    local samples = 0
    for i = 2, math.max(2, table.getn(route) - 1) do
        local point = route[i]
        if point then
            local nearestSq = HugeNumber
            for _, other in ipairs(reference) do
                local distanceSq = DistSq(point, other)
                if distanceSq < nearestSq then
                    nearestSq = distanceSq
                end
            end
            total = total + math.sqrt(nearestSq)
            samples = samples + 1
        end
    end

    return samples > 0 and (total / samples) or 0
end

local function MeasureTerminalFlank(route, target)
    if not (route and target and table.getn(route) >= 2) then
        return 0
    end

    local finalPoint = route[table.getn(route)]
    local prevPoint = route[table.getn(route) - 1] or finalPoint
    local approachHeading = HeadingDegrees(prevPoint, finalPoint)
    local directHeading = HeadingDegrees(route[1], target)
    return AngleDeltaDegrees(directHeading, approachHeading)
end

local function ScoreCandidates(candidates)
    if not (candidates and table.getn(candidates) > 0) then
        return candidates
    end

    local reference = candidates[1] and candidates[1].path or nil
    for _, candidate in ipairs(candidates) do
        candidate.separation = reference and RoutePathSeparation(candidate.path, reference) or 0
        candidate.flankAngle = candidate.flankAngle or MeasureTerminalFlank(candidate.path, candidate.target)
        local clearance = candidate.clearance or { minimum = 0, average = 0, centeredness = 0 }
        local clearanceScore = (clearance.minimum * 10) + (clearance.average * 3) + (clearance.centeredness * 14)
        local lengthPenalty = (candidate.length or HugeNumber) * 0.75
        local edgePenalty = candidate.edgePenalty or 0
        local turnPenalty = candidate.turnPenalty or 0
        candidate.selectionScore = clearanceScore - lengthPenalty - edgePenalty - turnPenalty
        if candidate.routeType ~= 'default' then
            candidate.selectionScore = candidate.selectionScore + (candidate.separation * 1.5) + (candidate.flankAngle * 0.14)
        end
    end

    table.sort(candidates, function(a, b)
        if math.abs((a.selectionScore or 0) - (b.selectionScore or 0)) > 0.05 then
            return (a.selectionScore or 0) > (b.selectionScore or 0)
        end
        return (a.length or HugeNumber) < (b.length or HugeNumber)
    end)

    return candidates
end

local function SelectCandidate(candidates, opts)
    if not (candidates and table.getn(candidates) > 0) then
        return nil, nil
    end

    local best = candidates[1]
    if not (opts and opts.RandomizeRoute) then
        return best, {
            selected = best.routeType or 'default',
            randomized = false,
            candidates = table.getn(candidates),
        }
    end

    local viable = {}
    local bestLength = best.length or HugeNumber
    local bestMinimumClearance = best.clearance and best.clearance.minimum or 0

    for _, candidate in ipairs(candidates) do
        local length = candidate.length or HugeNumber
        local minClearance = candidate.clearance and candidate.clearance.minimum or 0
        local sufficientlyDistinct = candidate.routeType == 'default'
            or candidate.separation >= 10
            or candidate.flankAngle >= 22

        if length <= (bestLength * RandomizedRouteLengthSlack)
            and minClearance >= math.max(4, bestMinimumClearance - 2)
            and sufficientlyDistinct
        then
            table.insert(viable, candidate)
        end
        if table.getn(viable) >= RandomizedRouteMaxCandidates then
            break
        end
    end

    if table.getn(viable) == 0 then
        return best, {
            selected = best.routeType or 'default',
            randomized = false,
            candidates = table.getn(candidates),
        }
    end

    local weighted = {}
    local totalWeight = 0
    for _, candidate in ipairs(viable) do
        local weight = 1
        if candidate.routeType ~= 'default' then
            weight = weight + math.max(1, math.floor(candidate.separation / 6)) + math.max(0, math.floor(candidate.flankAngle / 20))
        else
            local weakestViable = viable[table.getn(viable)]
            weight = math.max(1, weight + math.floor((candidate.selectionScore - ((weakestViable and weakestViable.selectionScore) or 0)) / 8))
        end
        totalWeight = totalWeight + weight
        table.insert(weighted, { candidate = candidate, weight = weight })
    end

    local roll = Random and Random(1, totalWeight) or math.random(1, totalWeight)
    local running = 0
    for _, entry in ipairs(weighted) do
        running = running + entry.weight
        if roll <= running then
            return entry.candidate, {
                selected = entry.candidate.routeType or 'default',
                randomized = true,
                candidates = table.getn(candidates),
                viable = table.getn(viable),
            }
        end
    end

    local fallback = viable[table.getn(viable)] or best
    return fallback, {
        selected = fallback.routeType or 'default',
        randomized = true,
        candidates = table.getn(candidates),
        viable = table.getn(viable),
    }
end

local function BuildSquadPlan(route, footprintWidth)
    local plan = {
        requiresSplit = false,
        splitIndices = {},
        rejoinIndices = {},
        chokepoints = {},
    }

    if not (route and route.waypoints and footprintWidth) then
        return plan
    end

    local inSplit = false
    for index, waypoint in ipairs(route.waypoints) do
        local width = waypoint and waypoint.corridorWidth or nil
        if width and width > 0 and width < math.max(8, footprintWidth * 0.80) then
            plan.requiresSplit = true
            table.insert(plan.chokepoints, { index = index, width = width })
            if not inSplit then
                inSplit = true
                table.insert(plan.splitIndices, index)
            end
        elseif inSplit and width and width >= math.max(12, footprintWidth * 1.10) then
            inSplit = false
            table.insert(plan.rejoinIndices, index)
        end
    end

    return plan
end

return {
    GetScenarioGraph = GetScenarioGraph,
    GetVariantSpecs = GetVariantSpecs,
    MeasureTerminalFlank = MeasureTerminalFlank,
    RoutePathSeparation = RoutePathSeparation,
    ScoreCandidates = ScoreCandidates,
    SelectCandidate = SelectCandidate,
    BuildSquadPlan = BuildSquadPlan,
}