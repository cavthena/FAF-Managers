-- Mission-scoped graph router for platoon navigation.
-- Rebuilt to provide deterministic, domain-aware, scalable routing on both
-- open and tight maps.

local NavUtils = import('/lua/sim/NavUtils.lua')

local HugeNumber = math.huge or 1e9
local Sqrt2 = math.sqrt(2)

local BaseConfig = {
    resolution = 24,
    obstacleProbeDistance = 8,
    obstacleProbeStep = 2,
    inflationHardBlock = 2.5,
    inflationSoftPenalty = 8,
    diagonalCost = Sqrt2,
}

local Directions = {
    { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
    { 1, 1, Sqrt2 }, { -1, 1, Sqrt2 }, { 1, -1, Sqrt2 }, { -1, -1, Sqrt2 },
}

local Domains = {
    Land = 'Land',
    Water = 'Water',
    Air = 'Air',
}

local GraphCache = false

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

local function DistSq(a, b)
    if not (a and b) then
        return HugeNumber
    end

    local dx = VecX(a) - VecX(b)
    local dz = VecZ(a) - VecZ(b)
    return dx * dx + dz * dz
end

local function Dist(a, b)
    return math.sqrt(DistSq(a, b))
end

local function CopyVec(v)
    if not v then
        return nil
    end

    return { VecX(v), VecY(v), VecZ(v) }
end

local function SurfaceHeightForLayer(layer, x, z)
    if layer == 'Water' or layer == 'Naval' then
        return GetSurfaceHeight(x, z)
    end

    return math.max(GetTerrainHeight(x, z), GetSurfaceHeight(x, z))
end

local function IsWaterAt(x, z)
    return (GetSurfaceHeight(x, z) - GetTerrainHeight(x, z)) > 0.05
end

local function SegmentPassable(layer, a, b)
    local ok, passable = pcall(NavUtils.CanPathTo, layer, a, b)
    return ok and passable
end

local function ResolveDomainForLayer(layer)
    if layer == 'Air' then
        return Domains.Air
    end

    if layer == 'Water' or layer == 'Naval' then
        return Domains.Water
    end

    return Domains.Land
end

local function ResolveConfig(opts)
    local config = {}
    for key, value in pairs(BaseConfig) do
        config[key] = value
    end

    for key, value in pairs(opts or {}) do
        config[key] = value
    end

    return config
end

local function ConfigMatches(a, b)
    if not (a and b) then
        return false
    end

    return a.resolution == b.resolution
        and a.obstacleProbeDistance == b.obstacleProbeDistance
        and a.obstacleProbeStep == b.obstacleProbeStep
        and a.inflationHardBlock == b.inflationHardBlock
        and a.inflationSoftPenalty == b.inflationSoftPenalty
        and a.diagonalCost == b.diagonalCost
end

local function ResolveMapKey(area)
    local mapName = ScenarioInfo and (ScenarioInfo.name or ScenarioInfo.map or ScenarioInfo.MapName) or 'unknown-map'
    if area then
        return string.format('%s:%s:%s:%s:%s', mapName, area[1] or 0, area[2] or 0, area[3] or 0, area[4] or 0)
    end
    return tostring(mapName)
end

local function GridDimensions(area, resolution)
    local width = math.max(1, math.floor(((area[3] - area[1]) / resolution) + 0.5))
    local height = math.max(1, math.floor(((area[4] - area[2]) / resolution) + 0.5))
    return width, height
end

local function CellCenter(area, resolution, gx, gz)
    return {
        area[1] + ((gx + 0.5) * resolution),
        0,
        area[2] + ((gz + 0.5) * resolution),
    }
end

local function GridIndex(width, gx, gz)
    return (gz * width) + gx + 1
end

local function DecodeGridIndex(width, index)
    local i = index - 1
    local gx = math.mod(i, width)
    local gz = math.floor(i / width)
    return gx, gz
end

local function Clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function CellFromPosition(graph, position)
    local cfg = graph.config
    local area = graph.area
    local gx = Clamp(math.floor((VecX(position) - area[1]) / cfg.resolution), 0, graph.width - 1)
    local gz = Clamp(math.floor((VecZ(position) - area[2]) / cfg.resolution), 0, graph.height - 1)
    return gx, gz, GridIndex(graph.width, gx, gz)
end

local function IsHardBlocked(domainState)
    return domainState.hardBlocked and true or false
end

local function DomainCellPassable(graph, cell, domain)
    if domain == Domains.Air then
        return true
    end

    local state = cell[domain]
    if not state then
        return false
    end

    return not IsHardBlocked(state)
end

local function CollectNeighbors(graph, index, domain)
    local neighbors = {}
    local gx, gz = DecodeGridIndex(graph.width, index)
    local current = graph.cells[index]

    for _, dir in ipairs(Directions) do
        local nx = gx + dir[1]
        local nz = gz + dir[2]
        if nx >= 0 and nx < graph.width and nz >= 0 and nz < graph.height then
            local nidx = GridIndex(graph.width, nx, nz)
            local nextCell = graph.cells[nidx]
            if DomainCellPassable(graph, nextCell, domain) then
                if math.abs(dir[1]) + math.abs(dir[2]) == 2 and domain ~= Domains.Air then
                    local idxA = GridIndex(graph.width, gx + dir[1], gz)
                    local idxB = GridIndex(graph.width, gx, gz + dir[2])
                    if not (DomainCellPassable(graph, graph.cells[idxA], domain) and DomainCellPassable(graph, graph.cells[idxB], domain)) then
                        -- Prevent diagonal corner-cutting in tight choke points.
                    else
                        table.insert(neighbors, { id = nidx, cost = dir[3] })
                    end
                else
                    table.insert(neighbors, { id = nidx, cost = dir[3] })
                end
            end
        end
    end

    current.neighbors = current.neighbors or {}
    current.neighbors[domain] = neighbors
    return neighbors
end

local function GetNeighbors(graph, index, domain)
    local cell = graph.cells[index]
    local bucket = cell.neighbors and cell.neighbors[domain]
    if bucket then
        return bucket
    end
    return CollectNeighbors(graph, index, domain)
end

local function ComputeInflationCost(graph, domain, gx, gz)
    if domain == Domains.Air then
        return 1
    end

    local cfg = graph.config
    local center = CellCenter(graph.area, cfg.resolution, gx, gz)
    local x = center[1]
    local z = center[3]

    local passSample = { x, SurfaceHeightForLayer(domain == Domains.Water and 'Water' or 'Land', x, z), z }
    if not SegmentPassable(domain == Domains.Water and 'Water' or 'Land', passSample, passSample) then
        return false, true
    end

    local isWater = IsWaterAt(x, z)
    if (domain == Domains.Land and isWater) or (domain == Domains.Water and not isWater) then
        return false, true
    end

    local minObstacle = HugeNumber
    local maxRadius = cfg.obstacleProbeDistance
    local step = math.max(1, cfg.obstacleProbeStep)

    local probeLayer = domain == Domains.Water and 'Water' or 'Land'

    local radius = step
    while radius <= maxRadius do
        local blockedDirections = 0
        for _, dir in ipairs(Directions) do
            local px = x + (dir[1] * radius)
            local pz = z + (dir[2] * radius)
            local probe = { px, SurfaceHeightForLayer(probeLayer, px, pz), pz }
            if not SegmentPassable(probeLayer, passSample, probe) then
                blockedDirections = blockedDirections + 1
            end
        end

        if blockedDirections > 0 then
            minObstacle = radius
            break
        end

        radius = radius + step
    end

    if minObstacle <= cfg.inflationHardBlock then
        return false, true
    end

    local penalty = 1
    if minObstacle < HugeNumber and minObstacle <= cfg.inflationSoftPenalty then
        local softness = (cfg.inflationSoftPenalty - minObstacle) / math.max(0.01, cfg.inflationSoftPenalty - cfg.inflationHardBlock)
        penalty = penalty + (softness * 2.2)
    end

    return penalty, false
end

local function BuildComponents(graph, domain)
    local components = {}
    local compIndex = {}
    local compCount = 0

    for idx, cell in ipairs(graph.cells) do
        if DomainCellPassable(graph, cell, domain) and not compIndex[idx] then
            compCount = compCount + 1
            local queue = { idx }
            local qh = 1
            compIndex[idx] = compCount
            local size = 0

            while qh <= table.getn(queue) do
                local current = queue[qh]
                qh = qh + 1
                size = size + 1

                local neighbors = GetNeighbors(graph, current, domain)
                for _, n in ipairs(neighbors) do
                    if not compIndex[n.id] then
                        compIndex[n.id] = compCount
                        queue[table.getn(queue) + 1] = n.id
                    end
                end
            end

            components[compCount] = size
        end
    end

    graph.components[domain] = {
        index = compIndex,
        sizes = components,
        count = compCount,
    }
end

local function BuildCellState(graph)
    local cfg = graph.config
    local validLand = 0
    local validWater = 0

    for gz = 0, graph.height - 1 do
        for gx = 0, graph.width - 1 do
            local idx = GridIndex(graph.width, gx, gz)
            local cell = {
                id = idx,
                gx = gx,
                gz = gz,
                center = CellCenter(graph.area, cfg.resolution, gx, gz),
                neighbors = {},
                Land = {},
                Water = {},
                Air = { hardBlocked = false, moveCost = 1 },
            }

            local landCost, landBlocked = ComputeInflationCost(graph, Domains.Land, gx, gz)
            cell.Land.hardBlocked = landBlocked and true or false
            cell.Land.moveCost = landCost or HugeNumber
            if not cell.Land.hardBlocked then
                validLand = validLand + 1
            end

            local waterCost, waterBlocked = ComputeInflationCost(graph, Domains.Water, gx, gz)
            cell.Water.hardBlocked = waterBlocked and true or false
            cell.Water.moveCost = waterCost or HugeNumber
            if not cell.Water.hardBlocked then
                validWater = validWater + 1
            end

            graph.cells[idx] = cell
        end
    end

    graph.validCells = {
        Land = validLand,
        Water = validWater,
        Air = table.getn(graph.cells),
    }

    BuildComponents(graph, Domains.Land)
    BuildComponents(graph, Domains.Water)
    BuildComponents(graph, Domains.Air)
end

local function BuildGraph(area, config)
    local started = GetGameTimeSeconds()
    local width, height = GridDimensions(area, config.resolution)

    local graph = {
        area = { area[1], area[2], area[3], area[4] },
        config = config,
        width = width,
        height = height,
        cells = {},
        components = {},
        mapKey = ResolveMapKey(area),
        metrics = {
            buildSeconds = 0,
            pathToCalls = 0,
            pathToFallbacks = 0,
            requests = 0,
            solved = 0,
            failed = 0,
        },
    }

    BuildCellState(graph)

    local finished = GetGameTimeSeconds()
    graph.metrics.buildSeconds = math.max(0, finished - started)
    graph.metrics.totalNodes = table.getn(graph.cells)
    graph.metrics.validLand = graph.validCells.Land
    graph.metrics.validSea = graph.validCells.Water
    graph.metrics.validAir = graph.validCells.Air
    graph.metrics.componentsLand = graph.components.Land and graph.components.Land.count or 0
    graph.metrics.componentsSea = graph.components.Water and graph.components.Water.count or 0

    return graph
end

local function Heuristic(graph, a, b)
    local cellA = graph.cells[a]
    local cellB = graph.cells[b]
    return Dist(cellA.center, cellB.center) / math.max(1, graph.config.resolution)
end

local function ResolveVariantBias(opts)
    if opts and opts.variantSpec and opts.variantSpec.sideSign then
        return opts.variantSpec.sideSign, (opts.variantSpec.bias or 0.28)
    end

    return 0, 0
end

local function SideBiasCost(graph, fromId, toId, startPos, targetPos, sideSign, bias)
    if sideSign == 0 or bias <= 0 then
        return 0
    end

    local from = graph.cells[fromId].center
    local to = graph.cells[toId].center

    local ax = VecX(targetPos) - VecX(startPos)
    local az = VecZ(targetPos) - VecZ(startPos)
    local bx = VecX(to) - VecX(from)
    local bz = VecZ(to) - VecZ(from)

    local cross = (ax * bz) - (az * bx)
    local signed = cross * sideSign
    if signed >= 0 then
        return 0
    end

    return math.abs(signed) * bias * 0.0025
end

local function DomainConnected(graph, domain, a, b)
    if domain == Domains.Air then
        return true
    end

    local comps = graph.components[domain]
    if not comps then
        return false
    end

    local ia = comps.index[a]
    local ib = comps.index[b]
    return ia and ib and ia == ib
end

local function FindNearestPassableCell(graph, domain, position, maxRing)
    local gx, gz, centerIndex = CellFromPosition(graph, position)
    local centerCell = graph.cells[centerIndex]
    if centerCell and DomainCellPassable(graph, centerCell, domain) then
        return centerIndex
    end

    local limit = maxRing or 5
    for ring = 1, limit do
        local minX = math.max(0, gx - ring)
        local maxX = math.min(graph.width - 1, gx + ring)
        local minZ = math.max(0, gz - ring)
        local maxZ = math.min(graph.height - 1, gz + ring)

        for z = minZ, maxZ do
            for x = minX, maxX do
                if x == minX or x == maxX or z == minZ or z == maxZ then
                    local idx = GridIndex(graph.width, x, z)
                    if DomainCellPassable(graph, graph.cells[idx], domain) then
                        return idx
                    end
                end
            end
        end
    end

    return nil
end

local function AStarRoute(graph, domain, startId, targetId, startPos, targetPos, opts)
    local open = { startId }
    local openSet = { [startId] = true }
    local gScore = { [startId] = 0 }
    local fScore = { [startId] = Heuristic(graph, startId, targetId) }
    local cameFrom = {}

    local sideSign, sideBias = ResolveVariantBias(opts)

    while table.getn(open) > 0 do
        local bestIndex = 1
        local current = open[1]
        local currentF = fScore[current] or HugeNumber

        for i = 2, table.getn(open) do
            local id = open[i]
            local score = fScore[id] or HugeNumber
            if score < currentF then
                currentF = score
                current = id
                bestIndex = i
            end
        end

        table.remove(open, bestIndex)
        openSet[current] = nil

        if current == targetId then
            local nodes = { current }
            while cameFrom[current] do
                current = cameFrom[current]
                table.insert(nodes, 1, current)
            end
            return nodes
        end

        local neighbors = GetNeighbors(graph, current, domain)
        for _, n in ipairs(neighbors) do
            local nCell = graph.cells[n.id]
            local moveCost = n.cost
            if domain ~= Domains.Air then
                local domainState = nCell[domain]
                moveCost = moveCost * (domainState.moveCost or 1)
            end

            moveCost = moveCost + SideBiasCost(graph, current, n.id, startPos, targetPos, sideSign, sideBias)

            local tentative = (gScore[current] or HugeNumber) + moveCost
            if tentative < (gScore[n.id] or HugeNumber) then
                cameFrom[n.id] = current
                gScore[n.id] = tentative
                fScore[n.id] = tentative + Heuristic(graph, n.id, targetId)
                if not openSet[n.id] then
                    openSet[n.id] = true
                    table.insert(open, n.id)
                end
            end
        end
    end

    return nil
end

local function DirectClear(routeLayer, fromPos, toPos, opts)
    if opts and type(opts.DirectCheck) == 'function' then
        local ok, clear = pcall(opts.DirectCheck, routeLayer, fromPos, toPos)
        return ok and clear
    end
    return SegmentPassable(routeLayer, fromPos, toPos)
end

local function PathNodesToPoints(graph, domain, nodes, layer)
    local points = {}
    for _, id in ipairs(nodes or {}) do
        local c = graph.cells[id]
        local p = CopyVec(c.center)
        p[2] = SurfaceHeightForLayer(layer, p[1], p[3])
        table.insert(points, p)
    end
    return points
end

local function SmoothPath(points, layer, opts)
    if not (points and table.getn(points) > 2) then
        return points
    end

    local smoothed = { CopyVec(points[1]) }
    local anchor = 1
    local probe = 3

    while probe <= table.getn(points) do
        if DirectClear(layer, points[anchor], points[probe], opts) then
            probe = probe + 1
        else
            table.insert(smoothed, CopyVec(points[probe - 1]))
            anchor = probe - 1
        end
    end

    local finalPoint = points[table.getn(points)]
    if DistSq(smoothed[table.getn(smoothed)], finalPoint) > 1 then
        table.insert(smoothed, CopyVec(finalPoint))
    end

    return smoothed
end

local function RouteLength(path)
    if not (path and table.getn(path) > 1) then
        return 0
    end

    local total = 0
    for i = 2, table.getn(path) do
        total = total + Dist(path[i - 1], path[i])
    end
    return total
end

function InitializeMissionGraph(area, opts)
    local requested = ResolveConfig(opts or {})
    local mapKey = ResolveMapKey(area)

    if GraphCache
        and GraphCache.mapKey == mapKey
        and ConfigMatches(GraphCache.config, requested)
    then
        return GraphCache
    end

    GraphCache = BuildGraph(area, requested)
    return GraphCache
end

function GetScenarioGraph()
    return GraphCache
end

local function ResolveGraph(area, opts)
    local cfg = (opts and opts.GraphConfig) or nil
    if not GraphCache then
        return InitializeMissionGraph(area, cfg)
    end

    local requested = ResolveConfig(cfg or GraphCache.config)
    local key = ResolveMapKey(area)
    if GraphCache.mapKey ~= key or not ConfigMatches(GraphCache.config, requested) then
        return InitializeMissionGraph(area, requested)
    end

    return GraphCache
end

function FindGraphRoute(area, layer, startPos, targetPos, opts)
    if not (startPos and targetPos) then
        return nil
    end

    local graph = ResolveGraph(area, opts)
    graph.metrics.requests = (graph.metrics.requests or 0) + 1

    local domain = ResolveDomainForLayer(layer)

    if domain == Domains.Air then
        local airRoute = { CopyVec(startPos), CopyVec(targetPos) }
        graph.metrics.solved = (graph.metrics.solved or 0) + 1
        return {
            path = airRoute,
            routeType = 'graph-air-direct',
            graphUsed = true,
            domain = domain,
            length = RouteLength(airRoute),
        }
    end

    local startId = FindNearestPassableCell(graph, domain, startPos, 7)
    local targetId = FindNearestPassableCell(graph, domain, targetPos, 7)

    if not (startId and targetId) then
        graph.metrics.failed = (graph.metrics.failed or 0) + 1
        return nil
    end

    if not DomainConnected(graph, domain, startId, targetId) then
        graph.metrics.failed = (graph.metrics.failed or 0) + 1
        return nil
    end

    local nodePath = AStarRoute(graph, domain, startId, targetId, startPos, targetPos, opts)
    if not nodePath or table.getn(nodePath) == 0 then
        graph.metrics.failed = (graph.metrics.failed or 0) + 1
        return nil
    end

    local path = PathNodesToPoints(graph, domain, nodePath, layer)
    path[1] = CopyVec(startPos)
    path[table.getn(path)] = CopyVec(targetPos)
    path = SmoothPath(path, layer, opts)

    graph.metrics.solved = (graph.metrics.solved or 0) + 1

    local routeType = 'graph'
    if opts and opts.variantSpec and opts.variantSpec.routeType then
        routeType = opts.variantSpec.routeType
    end

    return {
        path = path,
        routeType = routeType,
        graphUsed = true,
        domain = domain,
        nodes = table.getn(nodePath),
        length = RouteLength(path),
    }
end

function RecordPathToCall()
    if GraphCache and GraphCache.metrics then
        GraphCache.metrics.pathToCalls = (GraphCache.metrics.pathToCalls or 0) + 1
    end
end

function ReportPathToFallback()
    if GraphCache and GraphCache.metrics then
        GraphCache.metrics.pathToFallbacks = (GraphCache.metrics.pathToFallbacks or 0) + 1
    end
end

function GetMetrics()
    if not (GraphCache and GraphCache.metrics) then
        return {}
    end

    local m = {}
    for key, value in pairs(GraphCache.metrics) do
        m[key] = value
    end

    m.totalNodes = GraphCache.metrics.totalNodes
    m.validLand = GraphCache.metrics.validLand
    m.validSea = GraphCache.metrics.validSea
    m.validAir = GraphCache.metrics.validAir
    m.componentsLand = GraphCache.metrics.componentsLand
    m.componentsSea = GraphCache.metrics.componentsSea
    m.resolution = GraphCache.config and GraphCache.config.resolution
    return m
end

function GetVariantSpecs(area, opts)
    local specs = {
        { routeType = 'graph-left', sideSign = -1, bias = 0.30 },
        { routeType = 'graph-right', sideSign = 1, bias = 0.30 },
    }

    if opts and opts.FlankPreference == 'left' then
        return { specs[1], specs[2] }
    elseif opts and opts.FlankPreference == 'right' then
        return { specs[2], specs[1] }
    end

    return specs
end

function MeasureTerminalFlank(route, target)
    if not (route and target and table.getn(route) >= 2) then
        return 0
    end

    local finalPoint = route[table.getn(route)]
    local prevPoint = route[table.getn(route) - 1] or finalPoint
    local approachX = VecX(finalPoint) - VecX(prevPoint)
    local approachZ = VecZ(finalPoint) - VecZ(prevPoint)

    local directX = VecX(target) - VecX(route[1])
    local directZ = VecZ(target) - VecZ(route[1])

    local approachLen = math.sqrt((approachX * approachX) + (approachZ * approachZ))
    local directLen = math.sqrt((directX * directX) + (directZ * directZ))
    if approachLen < 0.01 or directLen < 0.01 then
        return 0
    end

    local dot = ((approachX * directX) + (approachZ * directZ)) / (approachLen * directLen)
    dot = math.max(-1, math.min(1, dot))
    return math.deg(math.acos(dot))
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
                local dsq = DistSq(point, other)
                if dsq < nearestSq then
                    nearestSq = dsq
                end
            end
            total = total + math.sqrt(nearestSq)
            samples = samples + 1
        end
    end

    return samples > 0 and (total / samples) or 0
end

function ScoreCandidates(candidates)
    if not (candidates and table.getn(candidates) > 0) then
        return candidates
    end

    local reference = candidates[1] and candidates[1].path or nil
    for _, c in ipairs(candidates) do
        c.separation = reference and RoutePathSeparation(c.path, reference) or 0
        c.flankAngle = c.flankAngle or MeasureTerminalFlank(c.path, c.target)

        local clearance = c.clearance or { minimum = 0, average = 0, centeredness = 0 }
        local clearanceScore = (clearance.minimum * 8.5) + (clearance.average * 2.5) + (clearance.centeredness * 12)
        local lengthPenalty = (c.length or HugeNumber) * 0.75
        local turnPenalty = c.turnPenalty or 0
        local edgePenalty = c.edgePenalty or 0

        c.selectionScore = clearanceScore - lengthPenalty - turnPenalty - edgePenalty
        if c.routeType ~= 'default' and c.routeType ~= 'graph-default' then
            c.selectionScore = c.selectionScore + (c.separation * 1.2) + (c.flankAngle * 0.11)
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

    for _, candidate in ipairs(candidates) do
        local length = candidate.length or HugeNumber
        if length <= (bestLength * 1.55) then
            table.insert(viable, candidate)
        end
    end

    if table.getn(viable) == 0 then
        return best, {
            selected = best.routeType or 'default',
            randomized = false,
            candidates = table.getn(candidates),
            viable = 0,
        }
    end

    local choiceIndex = Random and Random(1, table.getn(viable)) or math.random(1, table.getn(viable))
    local selected = viable[choiceIndex] or best
    return selected, {
        selected = selected.routeType or 'default',
        randomized = true,
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

    local splitThreshold = math.max(8, footprintWidth * 0.78)
    local rejoinThreshold = math.max(12, footprintWidth * 1.08)

    local inSplit = false
    for index, waypoint in ipairs(route.waypoints) do
        local width = waypoint and waypoint.corridorWidth or nil
        if width and width > 0 and width < splitThreshold then
            plan.requiresSplit = true
            table.insert(plan.chokepoints, { index = index, width = width })
            if not inSplit then
                inSplit = true
                table.insert(plan.splitIndices, index)
            end
        elseif inSplit and width and width >= rejoinThreshold then
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