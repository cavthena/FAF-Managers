-- Mission-scoped navigation graph for platoon routing.
local NavUtils = import('/lua/sim/NavUtils.lua')

local function ImportFirstAvailable(paths)
    for _, path in ipairs(paths or {}) do
        if type(path) == 'string' and path ~= '' then
            local okImport, mod = pcall(import, path)
            if okImport and mod then
                return mod
            end
        end
    end
    return nil
end

local function AppendCaseVariants(paths, path)
    if type(path) ~= 'string' or path == '' then
        return
    end

    table.insert(paths, path)

    local lower = string.lower(path)
    if lower ~= path then
        table.insert(paths, lower)
    end
end

local function ResolveSiblingModule(fileName, fallbackPath)
    local candidates = {}

    local ok, info = pcall(debug.getinfo, 1, 'S')
    if ok and info and info.source then
        local src = info.source
        if type(src) == 'string' and string.sub(src, 1, 1) == '@' then
            local dir = string.match(src, '^@(.*/)[^/]*$')
            if dir then
                AppendCaseVariants(candidates, dir .. fileName)
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
                AppendCaseVariants(candidates, dir .. '/' .. fileName)
            end
        end
    end

    AppendCaseVariants(candidates, fallbackPath)

    local mod = ImportFirstAvailable(candidates)
    if mod then
        return mod
    end

    return import(fallbackPath)
end

local Utils = ResolveSiblingModule('platoon_RoutingUtils.lua', '/maps/faf_coop_U01.v0001/platoon_RoutingUtils.lua')
local HugeNumber = math.huge or 1e9

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

local function VecZ(v)
    return ReadVecComponent(v, 3, 'z') or 0
end

local function CopyVec(v)
    if not v then
        return nil
    end
    return { VecX(v), ReadVecComponent(v, 2, 'y') or 0, VecZ(v) }
end

local function DistSq(a, b)
    if not (a and b) then
        return HugeNumber
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

local BaseConfig = {
    resolution = 32,
    obstacleProbeDistance = 7,
    obstacleProbeStep = 2,
    inflationHardBlock = 2.5,
    inflationSoftPenalty = 8,
    diagonalCost = math.sqrt(2),
}

local Domains = {
    LAND = 'Land',
    SEA = 'Water',
    AIR = 'Air',
}

local Directions = {
    { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
    { 1, 1, BaseConfig.diagonalCost }, { -1, 1, BaseConfig.diagonalCost },
    { 1, -1, BaseConfig.diagonalCost }, { -1, -1, BaseConfig.diagonalCost },
}

local RandomizedRouteLengthSlack = 1.55
local GraphCache = false

local function ResolveConfig(opts)
    local cfg = {}
    for k, v in pairs(BaseConfig) do
        cfg[k] = v
    end
    for k, v in pairs(opts or {}) do
        cfg[k] = v
    end
    return cfg
end

local function ConfigMatches(existing, requested)
    if not (existing and requested) then
        return false
    end

    return existing.resolution == requested.resolution
        and existing.obstacleProbeDistance == requested.obstacleProbeDistance
        and existing.obstacleProbeStep == requested.obstacleProbeStep
        and existing.inflationHardBlock == requested.inflationHardBlock
        and existing.inflationSoftPenalty == requested.inflationSoftPenalty
        and existing.diagonalCost == requested.diagonalCost
end

local function ResolveMapKey(area)
    local mapName = ScenarioInfo and (ScenarioInfo.name or ScenarioInfo.map or ScenarioInfo.MapName) or 'unknown-map'
    if area then
        return string.format('%s:%s:%s:%s:%s', mapName, area[1] or 0, area[2] or 0, area[3] or 0, area[4] or 0)
    end
    return tostring(mapName)
end

local function GetPlayableArea(area)
    if area then
        return area
    end

    if ScenarioInfo and ScenarioInfo.PlayableArea then
        return ScenarioInfo.PlayableArea
    end

    local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize)
    if size then
        return { 0, 0, size[1], size[2] }
    end

    return { 0, 0, 512, 512 }
end

local function PointPassable(layer, pos)
    local ok, passable = pcall(NavUtils.CanPathTo, layer, pos, pos)
    return ok and passable
end

local function SegmentPassable(layer, a, b)
    local ok, passable = pcall(NavUtils.CanPathTo, layer, a, b)
    return ok and passable
end

local function ProbeClearance(layer, node, cfg)
    local maxDist = cfg.obstacleProbeDistance
    local step = cfg.obstacleProbeStep
    local x = node.position[1]
    local z = node.position[3]
    local clear = maxDist

    local distance = step
    while distance <= maxDist do
        local points = {
            { x + distance, 0, z },
            { x - distance, 0, z },
            { x, 0, z + distance },
            { x, 0, z - distance },
        }
        local blocked = false
        for _, point in ipairs(points) do
            if not PointPassable(layer, point) then
                blocked = true
                break
            end
        end
        if blocked then
            clear = distance - step
            break
        end
        distance = distance + step
    end

    return math.max(0, clear)
end

local function DomainKeyFromLayer(layer)
    if layer == 'Air' then
        return 'AIR'
    elseif layer == 'Water' or layer == 'Naval' then
        return 'SEA'
    end
    return 'LAND'
end

local function BuildNodes(area, cfg)
    local minX, minZ, maxX, maxZ = area[1], area[2], area[3], area[4]
    local step = cfg.resolution
    local width = math.max(1, math.floor((maxX - minX) / step) + 1)
    local height = math.max(1, math.floor((maxZ - minZ) / step) + 1)

    local nodes = {}
    local indexByGrid = {}
    local id = 1

    for gz = 0, height - 1 do
        for gx = 0, width - 1 do
            local x = minX + (gx * step)
            local z = minZ + (gz * step)
            local node = {
                id = id,
                gx = gx,
                gz = gz,
                position = { x, 0, z },
                reachability = { LAND = false, SEA = false, AIR = true },
                clearance = { LAND = 0, SEA = 0, AIR = cfg.obstacleProbeDistance },
                penalty = { LAND = 0, SEA = 0, AIR = 0 },
                component = { LAND = 0, SEA = 0, AIR = 1 },
                neighbors = {},
            }
            nodes[id] = node
            indexByGrid[gz * width + gx] = id
            id = id + 1
        end
    end

    return nodes, indexByGrid, width, height
end

local function ResolveNode(indexByGrid, width, gx, gz)
    return indexByGrid[gz * width + gx]
end

local function BuildConnectivity(nodes, indexByGrid, width, height, cfg)
    for _, node in ipairs(nodes) do
        for _, direction in ipairs(Directions) do
            local ngx = node.gx + direction[1]
            local ngz = node.gz + direction[2]
            if ngx >= 0 and ngz >= 0 and ngx < width and ngz < height then
                local nId = ResolveNode(indexByGrid, width, ngx, ngz)
                if nId then
                    table.insert(node.neighbors, {
                        id = nId,
                        baseCost = direction[3],
                        diagonal = (direction[1] ~= 0 and direction[2] ~= 0) and true or false,
                    })
                end
            end
        end
    end
end

local function LabelComponents(graph, domain)
    local component = 0
    local visited = {}

    for _, node in ipairs(graph.nodes) do
        if node.reachability[domain] and not visited[node.id] then
            component = component + 1
            local queue = { node.id }
            local head = 1
            visited[node.id] = true
            node.component[domain] = component

            while head <= table.getn(queue) do
                local current = graph.nodes[queue[head]]
                head = head + 1

                for _, edge in ipairs(current.neighbors) do
                    local neighbor = graph.nodes[edge.id]
                    if neighbor and neighbor.reachability[domain] and not visited[neighbor.id] then
                        visited[neighbor.id] = true
                        neighbor.component[domain] = component
                        table.insert(queue, neighbor.id)
                    end
                end
            end
        end
    end

    graph.metrics.componentCounts[domain] = component
end

local function BuildMissionGraph(area, opts)
    local cfg = ResolveConfig(opts)

    local playable = GetPlayableArea(area)
    local nodes, indexByGrid, width, height = BuildNodes(playable, cfg)
    local startedAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0

    local graph = {
        key = ResolveMapKey(playable),
        area = playable,
        config = cfg,
        width = width,
        height = height,
        nodes = nodes,
        indexByGrid = indexByGrid,
        metrics = {
            buildSeconds = 0,
            nodeCount = table.getn(nodes or {}),
            routeQueries = 0,
            directShortcuts = 0,
            astarSearches = 0,
            disconnectedFastFails = 0,
            fallbackPathTo = 0,
            pathToCalls = 0,
            routeBuildSecondsTotal = 0,
            routeBuildTimes = {},
            componentCounts = { LAND = 0, SEA = 0, AIR = 1 },
            validNodeCounts = { LAND = 0, SEA = 0, AIR = 0 },
        },
        variantSpecs = {
            { routeType = 'left-wide', sideSign = -1, lateralScale = 0.30, fractions = { { 0.22, 0.65 }, { 0.48, 1.0 }, { 0.74, 0.85 } }, approachOffset = 0.95, approachBackoff = 0.20, maxOffset = 96, bias = 'wide-flank' },
            { routeType = 'left-deep', sideSign = -1, lateralScale = 0.38, fractions = { { 0.18, 0.75 }, { 0.42, 1.10 }, { 0.68, 1.0 } }, approachOffset = 1.15, approachBackoff = 0.24, maxOffset = 112, bias = 'deep-flank' },
            { routeType = 'right-wide', sideSign = 1, lateralScale = 0.30, fractions = { { 0.22, 0.65 }, { 0.48, 1.0 }, { 0.74, 0.85 } }, approachOffset = 0.95, approachBackoff = 0.20, maxOffset = 96, bias = 'wide-flank' },
            { routeType = 'right-deep', sideSign = 1, lateralScale = 0.38, fractions = { { 0.18, 0.75 }, { 0.42, 1.10 }, { 0.68, 1.0 } }, approachOffset = 1.15, approachBackoff = 0.24, maxOffset = 112, bias = 'deep-flank' },
        },
    }

    BuildConnectivity(graph.nodes, graph.indexByGrid, graph.width, graph.height, cfg)

    for _, node in ipairs(graph.nodes) do
        node.reachability.LAND = PointPassable(Domains.LAND, node.position)
        node.reachability.SEA = PointPassable(Domains.SEA, node.position)
        node.reachability.AIR = PointPassable(Domains.AIR, node.position)
        node.clearance.LAND = ProbeClearance(Domains.LAND, node, cfg)
        node.clearance.SEA = ProbeClearance(Domains.SEA, node, cfg)

        if node.reachability.LAND then
            if node.clearance.LAND < cfg.inflationHardBlock then
                node.reachability.LAND = false
            elseif node.clearance.LAND < cfg.inflationSoftPenalty then
                node.penalty.LAND = (cfg.inflationSoftPenalty - node.clearance.LAND) * 3
            end
        end

        if node.reachability.SEA then
            if node.clearance.SEA < cfg.inflationHardBlock then
                node.reachability.SEA = false
            elseif node.clearance.SEA < cfg.inflationSoftPenalty then
                node.penalty.SEA = (cfg.inflationSoftPenalty - node.clearance.SEA) * 3
            end
        end

        if node.reachability.LAND then
            graph.metrics.validNodeCounts.LAND = graph.metrics.validNodeCounts.LAND + 1
        end
        if node.reachability.SEA then
            graph.metrics.validNodeCounts.SEA = graph.metrics.validNodeCounts.SEA + 1
        end
        if node.reachability.AIR then
            graph.metrics.validNodeCounts.AIR = graph.metrics.validNodeCounts.AIR + 1
        end
    end

    LabelComponents(graph, 'LAND')
    LabelComponents(graph, 'SEA')

    local endedAt = GetGameTimeSeconds and GetGameTimeSeconds() or startedAt
    graph.metrics.buildSeconds = math.max(0, endedAt - startedAt)
    return graph
end

local function EnsureScenarioGraph(area, opts)
    local key = ResolveMapKey(GetPlayableArea(area))
    local requestedConfig = ResolveConfig(opts)
    if not GraphCache
        or GraphCache.key ~= key
        or not ConfigMatches(GraphCache.config, requestedConfig)
    then
        GraphCache = BuildMissionGraph(area, opts)
    end
    return GraphCache
end

local function NearestNode(graph, domain, position, maxRadius)
    local best = nil
    local bestDistSq = (maxRadius or (graph.config.resolution * 5)) ^ 2

    for _, node in ipairs(graph.nodes) do
        if node.reachability[domain] then
            local distSq = DistSq(node.position, position)
            if distSq < bestDistSq then
                best = node
                bestDistSq = distSq
            end
        end
    end

    return best
end

local function Heuristic(a, b)
    return math.sqrt(DistSq(a.position, b.position))
end

local function ReconstructPath(nodes, cameFrom, currentId)
    local path = {}
    local cursor = currentId
    while cursor do
        table.insert(path, 1, CopyVec(nodes[cursor].position))
        cursor = cameFrom[cursor]
    end
    return path
end

local function FindPathAStar(graph, domain, startNode, goalNode, opts)
    local open = { startNode.id }
    local inOpen = { [startNode.id] = true }
    local cameFrom = {}
    local gScore = { [startNode.id] = 0 }
    local fScore = { [startNode.id] = Heuristic(startNode, goalNode) }

    while table.getn(open) > 0 do
        local currentIndex = 1
        local currentId = open[1]
        local currentScore = fScore[currentId] or HugeNumber

        for i = 2, table.getn(open) do
            local candidateId = open[i]
            local candidateScore = fScore[candidateId] or HugeNumber
            if candidateScore < currentScore then
                currentIndex = i
                currentId = candidateId
                currentScore = candidateScore
            end
        end

        table.remove(open, currentIndex)
        inOpen[currentId] = nil

        if currentId == goalNode.id then
            return ReconstructPath(graph.nodes, cameFrom, currentId)
        end

        local currentNode = graph.nodes[currentId]
        for _, edge in ipairs(currentNode.neighbors) do
            local neighbor = graph.nodes[edge.id]
            if neighbor and neighbor.reachability[domain] then
                if not edge.diagonal or (graph.nodes[ResolveNode(graph.indexByGrid, graph.width, currentNode.gx, neighbor.gz)] and graph.nodes[ResolveNode(graph.indexByGrid, graph.width, neighbor.gx, currentNode.gz)]) then
                    local temporaryPenalty = opts and opts.TemporaryNodePenalty and (opts.TemporaryNodePenalty[neighbor.id] or 0) or 0
                    local tentative = (gScore[currentId] or HugeNumber) + edge.baseCost + (neighbor.penalty[domain] or 0) + temporaryPenalty
                    if tentative < (gScore[neighbor.id] or HugeNumber) then
                        cameFrom[neighbor.id] = currentId
                        gScore[neighbor.id] = tentative
                        fScore[neighbor.id] = tentative + Heuristic(neighbor, goalNode)
                        if not inOpen[neighbor.id] then
                            table.insert(open, neighbor.id)
                            inOpen[neighbor.id] = true
                        end
                    end
                end
            end
        end
    end

    return nil
end

function InitializeMissionGraph(area, opts)
    return EnsureScenarioGraph(area, opts)
end

function GetScenarioGraph(area)
    return EnsureScenarioGraph(area)
end

function FindGraphRoute(area, layer, startPos, targetPos, opts)
    local graph = EnsureScenarioGraph(area, opts and opts.GraphConfig)
    graph.metrics.routeQueries = graph.metrics.routeQueries + 1
    local startedAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0

    local domain = DomainKeyFromLayer(layer)

    if opts and opts.DirectCheck and opts.DirectCheck(layer, startPos, targetPos) then
        graph.metrics.directShortcuts = graph.metrics.directShortcuts + 1
        return {
            path = { CopyVec(startPos), CopyVec(targetPos) },
            routeType = 'direct',
            graphUsed = true,
        }
    end

    local startNode = NearestNode(graph, domain, startPos, graph.config.resolution * 7)
    local endNode = NearestNode(graph, domain, targetPos, graph.config.resolution * 7)
    if not (startNode and endNode) then
        return nil
    end

    if (startNode.component[domain] or 0) ~= (endNode.component[domain] or 0) then
        graph.metrics.disconnectedFastFails = graph.metrics.disconnectedFastFails + 1
        return nil
    end

    graph.metrics.astarSearches = graph.metrics.astarSearches + 1
    local nodePath = FindPathAStar(graph, domain, startNode, endNode, opts)
    if not nodePath then
        return nil
    end

    local path = { CopyVec(startPos) }
    for _, point in ipairs(nodePath) do
        table.insert(path, point)
    end
    table.insert(path, CopyVec(targetPos))

    local endedAt = GetGameTimeSeconds and GetGameTimeSeconds() or startedAt
    local elapsed = math.max(0, endedAt - startedAt)
    graph.metrics.routeBuildSecondsTotal = graph.metrics.routeBuildSecondsTotal + elapsed
    table.insert(graph.metrics.routeBuildTimes, elapsed)

    return {
        path = path,
        routeType = 'graph',
        graphUsed = true,
        sourceNodeId = startNode.id,
        targetNodeId = endNode.id,
        sourceComponent = startNode.component[domain],
        targetComponent = endNode.component[domain],
    }
end

function ReportPathToFallback()
    local graph = EnsureScenarioGraph()
    graph.metrics.fallbackPathTo = graph.metrics.fallbackPathTo + 1
    graph.metrics.pathToCalls = graph.metrics.pathToCalls + 1
end

function RecordPathToCall()
    local graph = EnsureScenarioGraph()
    graph.metrics.pathToCalls = graph.metrics.pathToCalls + 1
end

function GetMetrics(area)
    local graph = EnsureScenarioGraph(area)
    return graph and graph.metrics or {}
end

local function DeepCopyVariantSpecs(specs)
    local copy = {}
    for _, spec in ipairs(specs or {}) do
        local specCopy = {}
        for key, value in pairs(spec) do
            specCopy[key] = value
        end
        table.insert(copy, specCopy)
    end
    return copy
end

function GetVariantSpecs(area, opts)
    local cache = EnsureScenarioGraph(area)
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

function RoutePathSeparation(route, reference)
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

function MeasureTerminalFlank(route, target)
    if not (route and target and table.getn(route) >= 2) then
        return 0
    end

    local finalPoint = route[table.getn(route)]
    local prevPoint = route[table.getn(route) - 1] or finalPoint
    local approachHeading = HeadingDegrees(prevPoint, finalPoint)
    local directHeading = HeadingDegrees(route[1], target)
    return AngleDeltaDegrees(directHeading, approachHeading)
end

function ScoreCandidates(candidates)
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

function SelectCandidate(candidates, opts)
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
    end

    if table.getn(viable) == 0 then
        return best, {
            selected = best.routeType or 'default',
            randomized = false,
            uniformRandom = false,
            candidates = table.getn(candidates),
            viable = 0,
        }
    end

    local choiceIndex = Random and Random(1, table.getn(viable)) or math.random(1, table.getn(viable))
    local choice = viable[choiceIndex] or viable[table.getn(viable)] or best
    return choice, {
        selected = choice.routeType or 'default',
        randomized = true,
        uniformRandom = true,
        candidates = table.getn(candidates),
        viable = table.getn(viable),
    }
end

function BuildSquadPlan(route, footprintWidth)
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
    InitializeMissionGraph = InitializeMissionGraph,
    GetScenarioGraph = GetScenarioGraph,
    FindGraphRoute = FindGraphRoute,
    ReportPathToFallback = ReportPathToFallback,
    RecordPathToCall = RecordPathToCall,
    GetMetrics = GetMetrics,
    GetVariantSpecs = GetVariantSpecs,
    MeasureTerminalFlank = MeasureTerminalFlank,
    RoutePathSeparation = RoutePathSeparation,
    ScoreCandidates = ScoreCandidates,
    SelectCandidate = SelectCandidate,
    BuildSquadPlan = BuildSquadPlan,
}