--[[
===============================================================================
Platoon Routing -- dynamic, engine-driven campaign routing
===============================================================================

This module intentionally stays lightweight:
- no persistent map graph
- route decisions are driven by engine path requests
- small caches for frequently repeated campaign queries
- compact route objects and concise metrics for mission debugging
]]

local okNav, NavUtils = pcall(import, '/lua/sim/NavUtils.lua')
if not okNav then
    NavUtils = false
end

local Routing = {}

-- -----------------------------------------------------------------------------
-- Tunables
-- -----------------------------------------------------------------------------
local ROUTE_CACHE_LIMIT = 200
local REGION_CACHE_LIMIT = 300
local CLEARANCE_CACHE_LIMIT = 800

local MIN_WAYPOINT_SPACING = 8
local ARRIVAL_RADIUS_SQ = 20 * 20
local STUCK_TIMEOUT_SECONDS = 12
local STUCK_PROGRESS_SQ = 16
local OSCILLATION_WINDOW = 10
local OSCILLATION_REPEAT_THRESHOLD = 4
local MAX_LOCAL_REPATHS = 2

-- -----------------------------------------------------------------------------
-- Metrics / logging
-- -----------------------------------------------------------------------------
local Metrics = {
    routeQueries = 0,
    routeCacheHits = 0,
    routeCacheMisses = 0,
    regionQueries = 0,
    regionCacheHits = 0,
    regionCacheMisses = 0,
    directPathSuccesses = 0,
    midpointAssistedBuilds = 0,
    repaths = 0,
    stuckDetections = 0,
    fallbackPathTo = 0,
    unreachableFastFails = 0,
    transportFallbacks = 0,
    invalidSegmentRejects = 0,
}

local DebugEnabled = false

local function RLog(a, b, c, d, e, f)
    if DebugEnabled and LOG then
        LOG('[Routing]', a, b, c, d, e, f)
    end
end

-- -----------------------------------------------------------------------------
-- Small helpers
-- -----------------------------------------------------------------------------
local function CopyVector(v)
    if not v then return nil end
    return { v[1], v[2], v[3] }
end

local function IsVec(v)
    return type(v) == 'table' and type(v[1]) == 'number' and type(v[3]) == 'number'
end

local function DistSq(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return (dx * dx) + (dz * dz)
end

local function Dist(a, b)
    return math.sqrt(DistSq(a, b))
end

local function HeightForLayer(layer, x, z)
    if layer == 'Water' then
        return GetSurfaceHeight(x, z)
    end
    return GetTerrainHeight(x, z)
end

local function NormalizeY(layer, path)
    for _, p in ipairs(path or {}) do
        if p then
            p[2] = HeightForLayer(layer, p[1], p[3])
        end
    end
end

local function GetLayer(platoon, overrideLayer, amphibious)
    if overrideLayer then
        return overrideLayer
    end

    if not platoon then
        return amphibious and 'Amphibious' or 'Land'
    end

    local movement = platoon.MovementLayer
    if movement == 'Air' then
        return 'Air'
    elseif movement == 'Water' or movement == 'Sub' then
        return 'Water'
    end

    if amphibious then
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

local function ClampToPlayable(pos, buffer)
    local area = GetPlayableArea()
    if not (area and IsVec(pos)) then
        return CopyVector(pos)
    end

    local b = buffer or 0
    return {
        math.max(area[1] + b, math.min(area[3] - b, pos[1])),
        pos[2],
        math.max(area[2] + b, math.min(area[4] - b, pos[3])),
    }
end

local function QuantizePos(v, q)
    if not IsVec(v) then return 'nil' end
    local step = q or 4
    return ('%d:%d'):format(math.floor(v[1] / step), math.floor(v[3] / step))
end

local function BuildCacheKey(layer, a, b, opts)
    return table.concat({
        tostring(layer),
        QuantizePos(a, 4),
        QuantizePos(b, 4),
        tostring(opts and opts.AvoidDef and true or false),
        tostring(opts and opts.RandomizeRoute and true or false),
        tostring(opts and opts.RouteCacheTag or ''),
    }, '|')
end

local function LruSet(cache, order, key, value, limit)
    if cache[key] == nil then
        table.insert(order, key)
        if table.getn(order) > limit then
            local stale = table.remove(order, 1)
            cache[stale] = nil
        end
    end
    cache[key] = value
end

-- -----------------------------------------------------------------------------
-- Caches
-- -----------------------------------------------------------------------------
local RouteCache = {}
local RouteCacheOrder = {}

local RegionCache = {}
local RegionCacheOrder = {}

local ClearanceCache = {}
local ClearanceCacheOrder = {}

-- -----------------------------------------------------------------------------
-- Engine path wrappers
-- -----------------------------------------------------------------------------
local function TryNavCanPath(layer, a, b)
    if not (NavUtils and NavUtils.CanPathTo and IsVec(a) and IsVec(b)) then
        return nil
    end

    local ok, can = pcall(NavUtils.CanPathTo, layer, a[1], a[3], b[1], b[3])
    if ok then
        return can and true or false
    end

    return nil
end

local function TryGenerateEnginePath(platoon, layer, startPos, endPos)
    if not (platoon and platoon.PlatoonGenerateSafePathTo and IsVec(startPos) and IsVec(endPos)) then
        return nil
    end

    local brain = platoon:GetBrain()
    if not brain then
        return nil
    end

    -- Try weighted variant first; fallback to minimal call.
    local ok, path = pcall(platoon.PlatoonGenerateSafePathTo, platoon, brain, layer, startPos, endPos, 200, 2)
    if (not ok) or type(path) ~= 'table' or table.getn(path) == 0 then
        ok, path = pcall(platoon.PlatoonGenerateSafePathTo, platoon, brain, layer, startPos, endPos)
    end

    if ok and type(path) == 'table' and table.getn(path) > 0 then
        return path
    end

    return nil
end

local function CanTraverseSegment(platoon, layer, a, b)
    if not (IsVec(a) and IsVec(b)) then
        return false
    end

    if layer == 'Air' then
        return true
    end

    local nav = TryNavCanPath(layer, a, b)
    if nav ~= nil then
        return nav
    end

    local path = TryGenerateEnginePath(platoon, layer, a, b)
    return path ~= nil
end

local function SimplifyPath(path)
    local out = {}
    for _, p in ipairs(path or {}) do
        if IsVec(p) then
            if table.getn(out) == 0 then
                table.insert(out, CopyVector(p))
            else
                local last = out[table.getn(out)]
                if DistSq(last, p) >= (MIN_WAYPOINT_SPACING * MIN_WAYPOINT_SPACING) then
                    table.insert(out, CopyVector(p))
                else
                    out[table.getn(out)] = CopyVector(p)
                end
            end
        end
    end
    return out
end

local function ValidatePathSegments(platoon, layer, path)
    if type(path) ~= 'table' or table.getn(path) == 0 then
        return false
    end

    if layer == 'Air' then
        return true
    end

    for i = 1, table.getn(path) - 1 do
        if not CanTraverseSegment(platoon, layer, path[i], path[i + 1]) then
            return false
        end
    end

    return true
end

local function BuildPathSegmentForPlatoon(platoon, layer, startPos, endPos)
    if layer == 'Air' then
        return { CopyVector(startPos), CopyVector(endPos) }
    end

    local path = TryGenerateEnginePath(platoon, layer, startPos, endPos)
    if not path then
        return nil
    end

    path = SimplifyPath(path)
    if table.getn(path) == 0 then
        return nil
    end

    if not ValidatePathSegments(platoon, layer, path) then
        return nil
    end

    return path
end

-- -----------------------------------------------------------------------------
-- Clearance / midpoint scoring
-- -----------------------------------------------------------------------------
function ScoreWaypointClearance(position, movementLayer, options)
    if not (IsVec(position) and movementLayer) then
        return -999
    end

    if movementLayer == 'Air' then
        return 100
    end

    local key = table.concat({ movementLayer, QuantizePos(position, 2) }, '|')
    if ClearanceCache[key] ~= nil then
        return ClearanceCache[key]
    end

    -- Local passability sampling around the candidate point.
    local ring = {
        { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 },
        { 3, 3 }, { -3, 3 }, { 3, -3 }, { -3, -3 },
        { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 },
    }

    local valid = 0
    for _, d in ipairs(ring) do
        local probe = { position[1] + d[1], position[2], position[3] + d[2] }
        local can = TryNavCanPath(movementLayer, position, probe)
        if can == nil then
            -- Unknown is neutral; do not over-penalize maps where NavUtils signatures vary.
            valid = valid + 0.5
        elseif can then
            valid = valid + 1
        end
    end

    local score = valid

    -- Optional defensive avoidance bias.
    local opts = options or {}
    if opts.AvoidDef and opts.Brain and opts.Brain.GetThreatAtPosition then
        local threatType = 'AntiSurface'
        if movementLayer == 'Water' then
            threatType = 'AntiNavy'
        elseif movementLayer == 'Air' then
            threatType = 'AntiAir'
        end
        local ok, threat = pcall(opts.Brain.GetThreatAtPosition, opts.Brain, position, 1, true, threatType)
        if ok and type(threat) == 'number' then
            score = score - (threat * 0.75)
        end
    end

    LruSet(ClearanceCache, ClearanceCacheOrder, key, score, CLEARANCE_CACHE_LIMIT)
    return score
end

local function BuildMidpointCandidates(fromPos, toPos)
    local candidates = {}
    local dx = toPos[1] - fromPos[1]
    local dz = toPos[3] - fromPos[3]
    local len = math.sqrt((dx * dx) + (dz * dz))
    if len < 1 then
        return candidates
    end

    local nx, nz = -dz / len, dx / len
    local fractions = { 0.35, 0.5, 0.65 }
    local offsets = { 0, 20, -20, 36, -36 }

    for _, f in ipairs(fractions) do
        local bx = fromPos[1] + (dx * f)
        local bz = fromPos[3] + (dz * f)
        for _, off in ipairs(offsets) do
            table.insert(candidates, { bx + (nx * off), fromPos[2], bz + (nz * off) })
        end
    end

    return candidates
end

function SelectIntermediateWaypoint(platoon, fromPos, toPos, options)
    if not (platoon and IsVec(fromPos) and IsVec(toPos)) then
        return nil
    end

    local opts = options or {}
    local layer = GetLayer(platoon, opts.RouteLayer, opts.Amphibious)
    if layer == 'Air' then
        return nil
    end

    local brain = platoon:GetBrain()
    local baseDist = Dist(fromPos, toPos)
    local best = nil

    for _, candidate in ipairs(BuildMidpointCandidates(fromPos, toPos)) do
        candidate = ClampToPlayable(candidate, 1)
        local segA = BuildPathSegmentForPlatoon(platoon, layer, fromPos, candidate)
        if segA then
            local segB = BuildPathSegmentForPlatoon(platoon, layer, candidate, toPos)
            if segB then
                local pathCost = Dist(fromPos, candidate) + Dist(candidate, toPos)
                local progressPenalty = math.max(0, pathCost - baseDist)
                local clearance = ScoreWaypointClearance(candidate, layer, {
                    AvoidDef = opts.AvoidDef,
                    Brain = brain,
                })
                local score = progressPenalty - (clearance * 1.2)

                local entry = {
                    point = CopyVector(candidate),
                    score = score,
                    segA = segA,
                    segB = segB,
                }

                if not best or score < best.score then
                    best = entry
                end
            end
        end
    end

    return best
end

-- -----------------------------------------------------------------------------
-- Region relation
-- -----------------------------------------------------------------------------
function GetRegionRelation(platoon, startPos, endPos, movementLayer, options)
    Metrics.regionQueries = Metrics.regionQueries + 1

    if not (platoon and IsVec(startPos) and IsVec(endPos)) then
        return 'unreachable'
    end

    local opts = options or {}
    local layer = GetLayer(platoon, movementLayer, opts.Amphibious)

    if layer == 'Air' then
        return 'same_area'
    end

    local key = BuildCacheKey(layer, startPos, endPos, { RouteCacheTag = 'region' })
    local cached = RegionCache[key]
    if cached then
        Metrics.regionCacheHits = Metrics.regionCacheHits + 1
        return cached
    end
    Metrics.regionCacheMisses = Metrics.regionCacheMisses + 1

    local relation = 'unreachable'
    if CanTraverseSegment(platoon, layer, startPos, endPos) then
        relation = 'same_area'
    else
        local path = TryGenerateEnginePath(platoon, layer, startPos, endPos)
        if path and table.getn(path) > 0 then
            relation = 'different_area'
        elseif opts.Transport then
            relation = 'unreachable_special_handling'
        else
            relation = 'unreachable'
        end
    end

    LruSet(RegionCache, RegionCacheOrder, key, relation, REGION_CACHE_LIMIT)
    return relation
end

-- -----------------------------------------------------------------------------
-- Public compatibility helpers
-- -----------------------------------------------------------------------------
function CanPathBetween(layer, a, b)
    if layer == 'Air' then
        return IsVec(a) and IsVec(b)
    end

    local nav = TryNavCanPath(layer, a, b)
    if nav ~= nil then
        return nav == true
    end

    -- Compatibility fallback for logic that probes short links without platoon
    -- context. Route building itself still uses engine-generated paths.
    return IsVec(a) and IsVec(b) and DistSq(a, b) <= (160 * 160)
end

function CanPathTo(platoon, layer, destination)
    if not (platoon and IsVec(destination)) then
        return false
    end

    local start = platoon.GetPlatoonPosition and platoon:GetPlatoonPosition() or nil
    if not IsVec(start) then
        return false
    end

    local useLayer = GetLayer(platoon, layer)
    if useLayer == 'Air' then
        return true
    end

    if CanTraverseSegment(platoon, useLayer, start, destination) then
        return true
    end

    return TryGenerateEnginePath(platoon, useLayer, start, destination) ~= nil
end

function BuildPathSegment(layer, startPos, destination)
    if not (IsVec(startPos) and IsVec(destination)) then
        return nil
    end

    if layer == 'Air' then
        return { CopyVector(startPos), CopyVector(destination) }
    end

    local nav = TryNavCanPath(layer, startPos, destination)
    if nav then
        return { CopyVector(startPos), CopyVector(destination) }
    end

    return nil
end

-- -----------------------------------------------------------------------------
-- Route build / path extraction
-- -----------------------------------------------------------------------------
local function PathToWaypointObjects(path)
    local out = {}
    for _, p in ipairs(path or {}) do
        table.insert(out, { position = CopyVector(p) })
    end
    return out
end

local function ExtractPath(route)
    local path = {}
    for _, w in ipairs(route and route.waypoints or {}) do
        if w and w.position then
            table.insert(path, CopyVector(w.position))
        end
    end
    return path
end

function BuildRoute(platoon, startPos, endPos, options)
    Metrics.routeQueries = Metrics.routeQueries + 1

    local opts = options or {}
    DebugEnabled = opts.Debug and true or DebugEnabled

    if not (platoon and IsVec(startPos) and IsVec(endPos)) then
        Metrics.unreachableFastFails = Metrics.unreachableFastFails + 1
        return nil
    end

    local layer = GetLayer(platoon, opts.RouteLayer, opts.Amphibious)
    local start = ClampToPlayable(startPos, 0)
    local destination = ClampToPlayable(endPos, 0)

    local key = BuildCacheKey(layer, start, destination, opts)
    if not opts.ForceRepath and RouteCache[key] then
        Metrics.routeCacheHits = Metrics.routeCacheHits + 1
        local cached = RouteCache[key]
        platoon._storedRoute = cached
        return cached
    end
    Metrics.routeCacheMisses = Metrics.routeCacheMisses + 1

    local relation = GetRegionRelation(platoon, start, destination, layer, opts)
    if relation == 'unreachable' then
        Metrics.unreachableFastFails = Metrics.unreachableFastFails + 1
        RLog('fast-fail unreachable', tostring(layer), tostring(opts.RouteSource or 'unknown'))
        return nil
    elseif relation == 'unreachable_special_handling' and not opts.Transport then
        Metrics.unreachableFastFails = Metrics.unreachableFastFails + 1
        return nil
    end

    -- 1) Prefer direct engine path whenever valid.
    local directPath = BuildPathSegmentForPlatoon(platoon, layer, start, destination)
    local finalPath = nil
    local routeType = nil

    if directPath then
        finalPath = directPath
        routeType = 'direct-engine-path'
        Metrics.directPathSuccesses = Metrics.directPathSuccesses + 1
    else
        -- 2) Midpoint-assisted route if direct path is not available/reliable.
        local mid = SelectIntermediateWaypoint(platoon, start, destination, opts)
        if mid and mid.segA and mid.segB then
            finalPath = {}
            for _, p in ipairs(mid.segA) do
                table.insert(finalPath, CopyVector(p))
            end
            for i = 2, table.getn(mid.segB) do
                table.insert(finalPath, CopyVector(mid.segB[i]))
            end
            routeType = 'midpoint-assisted'
            Metrics.midpointAssistedBuilds = Metrics.midpointAssistedBuilds + 1
        end
    end

    if not finalPath then
        if opts.Transport then
            Metrics.transportFallbacks = Metrics.transportFallbacks + 1
        else
            Metrics.unreachableFastFails = Metrics.unreachableFastFails + 1
        end
        return nil
    end

    finalPath = SimplifyPath(finalPath)
    NormalizeY(layer, finalPath)

    if not ValidatePathSegments(platoon, layer, finalPath) then
        Metrics.invalidSegmentRejects = Metrics.invalidSegmentRejects + 1
        return nil
    end

    local route = {
        routeType = routeType,
        routeChainUsed = false,
        graphUsed = false,
        regionRelation = relation,
        layer = layer,
        destination = CopyVector(destination),
        waypoints = PathToWaypointObjects(finalPath),
        createdAt = GetGameTimeSeconds and GetGameTimeSeconds() or 0,
        repathCount = 0,
    }

    platoon._storedRoute = route
    LruSet(RouteCache, RouteCacheOrder, key, route, ROUTE_CACHE_LIMIT)
    return route
end

function FindSafePath(platoon, layer, destination, startOverride, options)
    local startPos = startOverride
    if not IsVec(startPos) then
        startPos = platoon and platoon.GetPlatoonPosition and platoon:GetPlatoonPosition() or nil
    end

    if not (platoon and IsVec(startPos) and IsVec(destination)) then
        return nil
    end

    local route = BuildRoute(platoon, startPos, destination, {
        RouteLayer = layer,
        Amphibious = options and options.Amphibious,
        AvoidDef = options and options.AvoidDef,
        RandomizeRoute = options and options.RandomizeRoute,
        Transport = options and options.Transport,
        Debug = options and options.Debug,
        RouteSource = options and options.RouteSource,
        RouteCacheTag = options and options.RouteCacheTag,
    })

    if not route then
        return nil
    end

    return ExtractPath(route)
end

function RecomputePathWithFallback(platoon, layer, destination, options)
    Metrics.repaths = Metrics.repaths + 1
    local opts = options or {}
    opts.ForceRepath = true

    local path = FindSafePath(platoon, layer, destination, nil, opts)
    if path then
        return path
    end

    Metrics.fallbackPathTo = Metrics.fallbackPathTo + 1
    if opts.Transport then
        Metrics.transportFallbacks = Metrics.transportFallbacks + 1
    end

    return nil
end

-- -----------------------------------------------------------------------------
-- Movement / follow
-- -----------------------------------------------------------------------------
function MoveAlongPath(platoon, path, formation, aggressiveFinal, layer, aggressiveRoute)
    if not (platoon and type(path) == 'table' and table.getn(path) > 0) then
        return false
    end

    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then
        return false
    end

    local form = formation or 'GrowthFormation'
    IssueClearCommands(units)

    for i, waypoint in ipairs(path) do
        if IsVec(waypoint) then
            local useAggressive = aggressiveRoute and true or false
            if i == table.getn(path) and aggressiveFinal ~= nil then
                useAggressive = aggressiveFinal and true or false
            end

            if useAggressive then
                if form ~= 'NoFormation' then
                    IssueFormAggressiveMove(units, waypoint, form, 0)
                else
                    IssueAggressiveMove(units, waypoint)
                end
            else
                if form ~= 'NoFormation' then
                    IssueFormMove(units, waypoint, form, 0)
                else
                    IssueMove(units, waypoint)
                end
            end
        end
    end

    return true
end

local function ShouldRepathInternal(progressState)
    if not progressState then
        return false, nil
    end

    if progressState.stallTime >= STUCK_TIMEOUT_SECONDS then
        return true, 'stalled'
    end

    if progressState.oscillationHits >= OSCILLATION_REPEAT_THRESHOLD then
        return true, 'oscillating'
    end

    return false, nil
end

function ShouldRepath(platoon, routeOrState, options)
    if options and options.ForceRepath then
        return true, 'forced'
    end

    -- Compatibility: callers may pass route object; internal follow uses state.
    if routeOrState and routeOrState.progress then
        return ShouldRepathInternal(routeOrState.progress)
    end

    if not (platoon and routeOrState and routeOrState.waypoints and table.getn(routeOrState.waypoints) > 0) then
        return true, 'missing-route'
    end

    return false, nil
end

local function QuantizedCell(pos)
    return QuantizePos(pos, 6)
end

function FollowRoute(platoon, route, options)
    local opts = options or {}
    if not (platoon and route and route.waypoints and table.getn(route.waypoints) > 0) then
        return 'repath'
    end

    local path = ExtractPath(route)
    if table.getn(path) == 0 then
        return 'repath'
    end

    if not MoveAlongPath(platoon, path, opts.Formation, false, route.layer, opts.AggressiveMove) then
        return 'repath'
    end

    local state = {
        repaths = 0,
        progress = {
            lastPos = platoon:GetPlatoonPosition(),
            stallTime = 0,
            oscillationHits = 0,
            recentCells = {},
        },
    }

    while platoon and platoon.GetPlatoonPosition do
        local units = platoon:GetPlatoonUnits() or {}
        if table.getn(units) == 0 then
            return 'fail'
        end

        local pos = platoon:GetPlatoonPosition()
        local goal = path[table.getn(path)]
        if IsVec(pos) and IsVec(goal) and DistSq(pos, goal) <= ARRIVAL_RADIUS_SQ then
            return 'attack'
        end

        if IsVec(pos) and IsVec(state.progress.lastPos) and DistSq(pos, state.progress.lastPos) > STUCK_PROGRESS_SQ then
            state.progress.lastPos = CopyVector(pos)
            state.progress.stallTime = 0
        else
            state.progress.stallTime = state.progress.stallTime + 1
        end

        if IsVec(pos) then
            local cell = QuantizedCell(pos)
            table.insert(state.progress.recentCells, cell)
            if table.getn(state.progress.recentCells) > OSCILLATION_WINDOW then
                table.remove(state.progress.recentCells, 1)
            end
            local repeats = 0
            for _, c in ipairs(state.progress.recentCells) do
                if c == cell then
                    repeats = repeats + 1
                end
            end
            state.progress.oscillationHits = repeats
        end

        local repathNeeded, reason = ShouldRepath(platoon, state, opts)
        if repathNeeded then
            Metrics.stuckDetections = Metrics.stuckDetections + 1

            if state.repaths >= MAX_LOCAL_REPATHS then
                RLog('follow-route giving up after local repaths', tostring(reason))
                return 'repath'
            end

            local current = platoon:GetPlatoonPosition()
            local destination = route.destination or goal
            local repath = RecomputePathWithFallback(platoon, route.layer, destination, opts)
            if not repath then
                return 'repath'
            end

            state.repaths = state.repaths + 1
            route.repathCount = (route.repathCount or 0) + 1

            if not MoveAlongPath(platoon, repath, opts.Formation, false, route.layer, opts.AggressiveMove) then
                return 'repath'
            end

            path = repath
            state.progress.lastPos = current
            state.progress.stallTime = 0
            state.progress.oscillationHits = 0
            state.progress.recentCells = {}
        end

        WaitSeconds(1)
    end

    return 'repath'
end

function MoveToNearestPlayableIngress(platoon, layer, area, formation, destination)
    if not platoon then
        return false, nil, nil
    end

    local pos = platoon.GetPlatoonPosition and platoon:GetPlatoonPosition() or nil
    if not IsVec(pos) then
        return false, nil, nil
    end

    local playArea = area or GetPlayableArea()
    if not playArea then
        return false, nil, nil
    end

    local safeBuffer = 4
    local dest = IsVec(destination) and ClampToPlayable(destination, 0) or nil
    local ingressCandidates = {}

    local function AddCandidate(candidate)
        if not IsVec(candidate) then
            return
        end

        candidate = ClampToPlayable(candidate, safeBuffer)
        for _, existing in ipairs(ingressCandidates) do
            if DistSq(existing, candidate) <= 4 then
                return
            end
        end

        table.insert(ingressCandidates, candidate)
    end

    local minX, minZ, maxX, maxZ = playArea[1], playArea[2], playArea[3], playArea[4]
    local edgePoint = {
        math.max(minX, math.min(maxX, pos[1])),
        pos[2],
        math.max(minZ, math.min(maxZ, pos[3])),
    }
    AddCandidate(edgePoint)

    local leftDist = math.abs(pos[1] - minX)
    local rightDist = math.abs(pos[1] - maxX)
    local bottomDist = math.abs(pos[3] - minZ)
    local topDist = math.abs(pos[3] - maxZ)

    local edge = 'left'
    local bestEdgeDist = leftDist
    if rightDist < bestEdgeDist then edge = 'right'; bestEdgeDist = rightDist end
    if bottomDist < bestEdgeDist then edge = 'bottom'; bestEdgeDist = bottomDist end
    if topDist < bestEdgeDist then edge = 'top'; bestEdgeDist = topDist end

    local ratios = { 0.2, 0.5, 0.8 }
    if edge == 'left' or edge == 'right' then
        local x = edge == 'left' and (minX + safeBuffer) or (maxX - safeBuffer)
        AddCandidate({ x, pos[2], math.max(minZ, math.min(maxZ, pos[3])) })
        for _, r in ipairs(ratios) do
            AddCandidate({ x, pos[2], minZ + ((maxZ - minZ) * r) })
        end
        if dest then
            AddCandidate({ x, pos[2], dest[3] })
        end
    else
        local z = edge == 'bottom' and (minZ + safeBuffer) or (maxZ - safeBuffer)
        AddCandidate({ math.max(minX, math.min(maxX, pos[1])), pos[2], z })
        for _, r in ipairs(ratios) do
            AddCandidate({ minX + ((maxX - minX) * r), pos[2], z })
        end
        if dest then
            AddCandidate({ dest[1], pos[2], z })
        end
    end

    if dest then
        AddCandidate(dest)
    end

    local bestPath = nil
    local bestIngress = nil
    local bestScore = (math.huge or 1e9)
    local routeLayer = GetLayer(platoon, layer)
    for _, candidate in ipairs(ingressCandidates) do
        local candidatePath = nil
        if routeLayer == 'Air' then
            candidatePath = { CopyVector(candidate) }
        else
            candidatePath = BuildPathSegmentForPlatoon(platoon, routeLayer, pos, candidate)
            if candidatePath and table.getn(candidatePath) > 1 and DistSq(candidatePath[1], pos) <= 4 then
                table.remove(candidatePath, 1)
            end
        end

        if candidatePath and table.getn(candidatePath) > 0 then
            local score = DistSq(pos, candidate)
            if dest then
                score = score + (DistSq(candidate, dest) * 0.35)
            end
            if score < bestScore then
                bestScore = score
                bestIngress = candidate
                bestPath = candidatePath
            end
        end
    end

    if not (bestIngress and bestPath and table.getn(bestPath) > 0) then
        return false, nil, nil
    end

    local moved = MoveAlongPath(platoon, bestPath, formation, false, routeLayer, false)
    return moved and true or false, bestIngress, moved and bestPath or nil
end

function GetRoutingMetrics()
    return {
        routeQueries = Metrics.routeQueries,
        routeCacheHits = Metrics.routeCacheHits,
        routeCacheMisses = Metrics.routeCacheMisses,
        regionQueries = Metrics.regionQueries,
        regionCacheHits = Metrics.regionCacheHits,
        regionCacheMisses = Metrics.regionCacheMisses,
        directPathSuccesses = Metrics.directPathSuccesses,
        midpointAssistedBuilds = Metrics.midpointAssistedBuilds,
        repaths = Metrics.repaths,
        stuckDetections = Metrics.stuckDetections,
        fallbackPathTo = Metrics.fallbackPathTo,
        unreachableFastFails = Metrics.unreachableFastFails,
        disconnectedFastFails = Metrics.unreachableFastFails,
        transportFallbacks = Metrics.transportFallbacks,
        invalidSegmentRejects = Metrics.invalidSegmentRejects,
        astarSearches = 0,
    }
end

return Routing