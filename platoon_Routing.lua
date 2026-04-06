--[[
================================================================================
 platoon_Routing.lua -- Created by Cavthena
================================================================================

 Handles route finding and movement order dispatch for platoons.
 Called by platoon_AttackFunctions.lua; should not contain target-selection
 or assault logic.

 Responsibilities:
   • Detect the platoon's movement layer (LAND / AIR / SEA / AMPHIBIOUS).
   • Build an ingress waypoint when the platoon starts outside the playable area.
   • Compute a path via NavUtils (LAND / SEA / AMPHIBIOUS) or a direct segment
     (AIR, or when Transport = true).
   • Optionally insert a flanking waypoint when RandomizeRoute = true.
   • Dispatch IssueMove / IssueAggressiveMove / IssueFormMove orders.

================================================================================
 PUBLIC API
================================================================================

 RoutePlatoonToTarget(platoon, attackData)  →  result
   Issue movement orders to bring the platoon to attackData.TargetPosition.
   Returns:
     {
       Assault      = bool,    -- true when already within ASSAULT_DISTANCE
       Distance     = number,  -- 2D distance to target at time of call
       Route        = table,   -- waypoint list that was issued  { {x,y,z}, ... }
       MovementLayer = string, -- resolved layer string
     }

 BuildIngressRoute(routingData)  →  result, debugBlock, debugLines
   Build a waypoint list from routingData.CurrentPosition to
   routingData.TargetPosition, optionally prepending an ingress point when the
   platoon starts outside the playable area.
   Returns a result table containing:
     StartPosition, CurrentPosition, TargetPosition, PlayableArea,
     MovementLayer, StartedOutsidePlayableArea, IngressPosition,
     Route = { {x,y,z}, ... }, Debug = {}, DebugBlock = string.

 ReceiveAttackData(attackData)  →  response, debugBlock, debugLines, data
   Entry point called by AttackFunctions for debug introspection.
   Builds and returns the full routing record without issuing move orders.

================================================================================
 ROUTING DATA FIELDS
================================================================================
 Platoon            object   Platoon being routed.
 CurrentPosition    vec3     Platoon's position at time of call.
 StartPosition      vec3     Spawn/starting position (may differ from current).
 TargetPosition     vec3     Desired destination.
 MovementLayer      string   Optional override: 'LAND'|'AIR'|'SEA'|'AMPHIBIOUS'.
 AggressiveMove     bool     Use aggressive move orders.
 Formation          string   Formation name, or 'NoFormation'.
 RandomizeRoute     bool     Allow flanking approach.
 Transport          bool     Platoon may use transports; skip ground pathfinding.
 Debug              bool     Emit verbose log output.
 SpawnerTag         string   Tag from manager_UnitSpawner (used in log prefixes).
 BuilderTag         string   Tag from manager_UnitBuilder (used in log prefixes).
================================================================================
]]

local NavUtils = import('/lua/sim/NavUtils.lua')

-- ============================================================
--  Constants
-- ============================================================
local ASSAULT_DISTANCE  = 80
local DEFAULT_FORMATION = 'NoFormation'

-- ============================================================
--  Utility helpers
-- ============================================================
local function CopyVector(vec)
    if type(vec) ~= 'table' then return nil end
    local x, y, z = vec[1], vec[2], vec[3]
    if type(x) ~= 'number' or type(z) ~= 'number' then return nil end
    if type(y) ~= 'number' then y = 0 end
    return { x, y, z }
end

local function Distance2D(a, b)
    if not (a and b) then return math.huge end
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt(dx * dx + dz * dz)
end

local function BuildDebugBlock(lines)
    if type(lines) ~= 'table' or table.getn(lines) == 0 then return nil end
    return table.concat(lines, '\n')
end

local function FormatPosition(vec)
    if not vec then return 'nil' end
    return ('(%.1f, %.1f, %.1f)'):format(vec[1] or 0, vec[2] or 0, vec[3] or 0)
end

-- ============================================================
--  Playable area helpers
-- ============================================================
local function GetPlayableArea()
    if ScenarioInfo and ScenarioInfo.PlayableArea then
        return ScenarioInfo.PlayableArea
    end
    local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize)
    if size then return { 0, 0, size[1], size[2] } end
    return nil
end

local function PositionInPlayableArea(position, area)
    if not (position and area) then return nil end
    return position[1] >= area[1]
       and position[1] <= area[3]
       and position[3] >= area[2]
       and position[3] <= area[4]
end

local function ClampToPlayableArea(position, area)
    if not (position and area) then return nil end
    local x = math.max(area[1], math.min(area[3], position[1] or 0))
    local z = math.max(area[2], math.min(area[4], position[3] or 0))
    local y = position[2]
    if type(y) ~= 'number' then y = 0 end
    return { x, y, z }
end

local function Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- ============================================================
--  Layer resolution
-- ============================================================
local MOTION_TO_LAYER = {
    RULEUMT_Air               = 'AIR',
    RULEUMT_AirFighter        = 'AIR',
    RULEUMT_Water             = 'SEA',
    RULEUMT_SurfacingSub      = 'SEA',
    RULEUMT_Sub               = 'SEA',
    RULEUMT_Amphibious        = 'AMPHIBIOUS',
    RULEUMT_AmphibiousFloating = 'AMPHIBIOUS',
}

local function ResolveLayer(platoon, routingData)
    -- 1. Explicit override in routing data
    local hint = routingData and (routingData.MovementLayer or routingData.Layer)
    if type(hint) == 'string' then
        local upper = string.upper(hint)
        if upper == 'LAND' or upper == 'AIR' or upper == 'SEA' or upper == 'AMPHIBIOUS' then
            return upper
        end
    end

    -- 2. Platoon property
    if platoon and platoon.MovementLayer then
        local upper = string.upper(platoon.MovementLayer)
        if upper ~= '' then return upper end
    end

    -- 3. Lead unit blueprint
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    local lead  = units[1]
    if lead and lead.GetBlueprint then
        local bp    = lead:GetBlueprint()
        local mt    = bp and bp.Physics and bp.Physics.MotionType
        if mt then
            local layer = MOTION_TO_LAYER[mt]
            if layer then return layer end
        end
    end

    return 'LAND'
end

local function ResolveNavLayer(layer)
    if layer == 'AIR'        then return 'Air'        end
    if layer == 'SEA'        then return 'Water'      end
    if layer == 'AMPHIBIOUS' then return 'Amphibious' end
    return 'Land'
end

-- ============================================================
--  NavUtils wrappers
-- ============================================================
local function TryCanPath(navLayer, startPos, endPos)
    if not (NavUtils and NavUtils.CanPathTo and startPos and endPos) then return true end
    -- Try vector form first (standard FAF NavUtils signature).
    local ok, result = pcall(NavUtils.CanPathTo, navLayer, startPos, endPos)
    if ok and type(result) == 'boolean' then return result end
    -- Fallback: scalar x/z form used by some NavUtils versions.
    ok, result = pcall(NavUtils.CanPathTo, navLayer, startPos[1], startPos[3], endPos[1], endPos[3])
    if ok and type(result) == 'boolean' then return result end
    return true
end

local function TryPathTo(navLayer, startPos, endPos)
    if not (NavUtils and NavUtils.PathTo and startPos and endPos) then return nil end
    -- Try vector form first (standard FAF NavUtils signature).
    local ok, path = pcall(NavUtils.PathTo, navLayer, startPos, endPos)
    if ok and type(path) == 'table' and table.getn(path) > 0 then return path end
    -- Fallback: scalar x/z form used by some NavUtils versions.
    ok, path = pcall(NavUtils.PathTo, navLayer, startPos[1], startPos[3], endPos[1], endPos[3])
    if ok and type(path) == 'table' and table.getn(path) > 0 then return path end
    return nil
end

local function NormalizeNavPath(path)
    local out = {}
    for _, p in ipairs(path or {}) do
        -- Handle a wrapping .Position / .position field first.
        local point = p.Position or p.position or p
        local x, y, z

        if type(point) == 'table' then
            if type(point[1]) == 'number' and type(point[3]) == 'number' then
                -- Numeric-index form: {x, y, z}
                x, y, z = point[1], point[2], point[3]
            elseif type(point.x) == 'number' and type(point.z) == 'number' then
                -- Named-field form: {x=..., y=..., z=...}
                x, y, z = point.x, point.y, point.z
            end
        end

        if x and z then
            table.insert(out, { x, y or 0, z })
        end
    end
    return out
end

-- ============================================================
--  Terrain helpers (LAND and SEA routing validation)
-- ============================================================
local WATER_CHECK_STEP = 4   -- sample every N units along a segment

local function IsWaterPosition(pos)
    if not pos then return false end
    return GetSurfaceHeight(pos[1], pos[3]) > GetTerrainHeight(pos[1], pos[3]) + 0.5
end

local function IsLandPosition(pos)
    if not pos then return false end
    return GetSurfaceHeight(pos[1], pos[3]) <= GetTerrainHeight(pos[1], pos[3]) + 0.5
end

-- Find a nearby point in the desired terrain domain.
-- Returns nil when no suitable point is found within searchRadius.
local function FindNearestDomainPoint(position, wantLand, area, searchRadius, step)
    if not position then return nil end
    if wantLand and IsLandPosition(position) then
        return CopyVector(position)
    elseif (not wantLand) and IsWaterPosition(position) then
        return CopyVector(position)
    end

    local radiusMax = searchRadius or 56
    local ringStep  = step or 4
    local angleStep = math.rad(15)

    for r = ringStep, radiusMax, ringStep do
        local angle = 0
        while angle < (math.pi * 2) do
            local candidate = {
                position[1] + math.cos(angle) * r,
                position[2],
                position[3] + math.sin(angle) * r,
            }
            if area then
                candidate[1] = Clamp(candidate[1], area[1], area[3])
                candidate[3] = Clamp(candidate[3], area[2], area[4])
            end

            if wantLand then
                if IsLandPosition(candidate) then return candidate end
            else
                if IsWaterPosition(candidate) then return candidate end
            end
            angle = angle + angleStep
        end
    end

    return nil
end

-- Returns true when the straight line between fromPos and toPos passes over water.
local function SegmentCrossesWater(fromPos, toPos)
    if not (fromPos and toPos) then return false end
    local dx  = toPos[1] - fromPos[1]
    local dz  = toPos[3] - fromPos[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1 then return IsWaterPosition(toPos) end

    local steps = math.max(2, math.floor(len / WATER_CHECK_STEP))
    for i = 1, steps do
        local t = i / steps
        local x = fromPos[1] + dx * t
        local z = fromPos[3] + dz * t
        if GetSurfaceHeight(x, z) > GetTerrainHeight(x, z) + 0.5 then
            return true
        end
    end
    return false
end

-- Returns true when the straight line between fromPos and toPos passes over land.
local function SegmentCrossesLand(fromPos, toPos)
    if not (fromPos and toPos) then return false end
    local dx  = toPos[1] - fromPos[1]
    local dz  = toPos[3] - fromPos[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1 then return IsLandPosition(toPos) end

    local steps = math.max(2, math.floor(len / WATER_CHECK_STEP))
    for i = 1, steps do
        local t = i / steps
        local x = fromPos[1] + dx * t
        local z = fromPos[3] + dz * t
        if GetSurfaceHeight(x, z) <= GetTerrainHeight(x, z) + 0.5 then
            return true
        end
    end
    return false
end

-- Remove any waypoints that sit in water, then verify no segment in the
-- remaining path crosses water.  Returns the clean path, or nil if the
-- path cannot be made water-free.
local function ValidateLandPath(fromPos, path)
    -- Strip individual water waypoints.
    local clean = {}
    for _, p in ipairs(path or {}) do
        if not IsWaterPosition(p) then
            table.insert(clean, p)
        end
    end
    if table.getn(clean) == 0 then return nil end

    -- Check that no segment between consecutive waypoints crosses water.
    local prev = fromPos or clean[1]
    for _, p in ipairs(clean) do
        if SegmentCrossesWater(prev, p) then
            return nil
        end
        prev = p
    end
    return clean
end

-- Remove any waypoints that sit on land, then verify no segment in the
-- remaining path crosses land.  Returns the clean path, or nil if the
-- path cannot be made land-free.
local function ValidateSeaPath(fromPos, path)
    -- Strip individual land waypoints.
    local clean = {}
    for _, p in ipairs(path or {}) do
        if not IsLandPosition(p) then
            table.insert(clean, p)
        end
    end
    if table.getn(clean) == 0 then return nil end

    -- Check that no segment between consecutive waypoints crosses land.
    local prev = fromPos or clean[1]
    for _, p in ipairs(clean) do
        if SegmentCrossesLand(prev, p) then
            return nil
        end
        prev = p
    end
    return clean
end

-- ============================================================
--  Route building
-- ============================================================

-- Return the NavUtils path from fromPos to toPos as a normalised waypoint list,
-- or nil when no passable path exists.  Land paths are validated to stay on dry
-- ground; Water paths are validated to stay on water.
local function GetNavPath(navLayer, fromPos, toPos)
    local raw  = TryPathTo(navLayer, fromPos, toPos)
    local path = NormalizeNavPath(raw)
    if table.getn(path) == 0 then return nil end

    -- Append the exact target when the nav mesh ends slightly short of it.
    if Distance2D(path[table.getn(path)], toPos) > 2 then
        table.insert(path, CopyVector(toPos))
    end

    -- Validate that the path stays within the correct domain.
    if navLayer == 'Land' then
        path = ValidateLandPath(fromPos, path)
        if not path then return nil end
    elseif navLayer == 'Water' then
        path = ValidateSeaPath(fromPos, path)
        if not path then return nil end
    end

    return path
end

-- Build a single routed segment from fromPos to toPos.
--   skipNavUtils = true  : AIR / Transport layers; return a direct endpoint only.
--   skipNavUtils = false : use PathTo so waypoints follow the nav mesh.
--                          Falls back to a direct hop only when NavUtils is
--                          unavailable AND the straight line stays in the correct
--                          domain.  Returns an empty table when no safe route can
--                          be built, signalling the caller to skip this target.
local function BuildDirectSegment(navLayer, fromPos, toPos, skipNavUtils)
    if skipNavUtils then
        return { CopyVector(toPos) }
    end

    local path = GetNavPath(navLayer, fromPos, toPos)
    if path then return path end

    -- NavUtils returned nothing.  Only allow a direct hop if the straight line
    -- stays within the layer's domain.
    if navLayer == 'Land' then
        if IsWaterPosition(toPos) or SegmentCrossesWater(fromPos, toPos) then
            return {}   -- target or path crosses water; skip
        end
    elseif navLayer == 'Water' then
        if IsLandPosition(toPos) or SegmentCrossesLand(fromPos, toPos) then
            return {}   -- target or path crosses land; skip
        end
    end

    return { CopyVector(toPos) }
end

-- Produce two flank candidates perpendicular to the direct path.
local function BuildFlankCandidates(startPos, targetPos, area)
    local dx   = targetPos[1] - startPos[1]
    local dz   = targetPos[3] - startPos[3]
    local dist = math.max(1, math.sqrt(dx * dx + dz * dz))
    local nx   = dx / dist
    local nz   = dz / dist
    local r    = math.max(60, math.min(140, dist * 0.35))

    local left  = { targetPos[1] - nz * r, targetPos[2], targetPos[3] + nx * r }
    local right = { targetPos[1] + nz * r, targetPos[2], targetPos[3] - nx * r }

    if area then
        left  = ClampToPlayableArea(left,  area)
        right = ClampToPlayableArea(right, area)
    end
    return { left, right }
end

-- Build a route from startPos to targetPos.
-- When randomizeRoute is true there is a 50 % chance of using a flanking approach.
-- AIR and Transport layers bypass all ground pathfinding.
local function BuildLayeredRoute(startPos, targetPos, navLayer, randomizeRoute, area, skipNavUtils)
    local route = {}
    if not (startPos and targetPos) then return route end

    local best = BuildDirectSegment(navLayer, startPos, targetPos, skipNavUtils)
    if table.getn(best) == 0 then return route end

    if randomizeRoute and not skipNavUtils then
        local candidates = {}
        for _, flank in ipairs(BuildFlankCandidates(startPos, targetPos, area)) do
            -- Both legs must have a real nav-mesh path; no direct-line fallback
            -- here because the flank point itself may be on impassable terrain.
            local legA = GetNavPath(navLayer, startPos, flank)
            local legB = GetNavPath(navLayer, flank,    targetPos)
            if legA and legB then
                local candidate = {}
                for _, p in ipairs(legA) do table.insert(candidate, p) end
                for i, p in ipairs(legB) do
                    if i > 1 then table.insert(candidate, p) end
                end
                table.insert(candidates, candidate)
                if table.getn(candidates) >= 2 then break end
            end
        end

        if table.getn(candidates) > 0 and Random(1, 100) <= 50 then
            best = candidates[Random(1, table.getn(candidates))]
        end
    end

    for _, p in ipairs(best or {}) do
        if not area or PositionInPlayableArea(p, area) then
            table.insert(route, p)
        else
            local clamped = ClampToPlayableArea(p, area)
            if clamped then table.insert(route, clamped) end
        end
    end

    return route
end

-- ============================================================
--  Inside-playable-area resolution
-- ============================================================
local function ResolveInsidePlayableArea(routingData, currentPosition, startPosition)
    if routingData.InsidePlayableArea ~= nil then
        return routingData.InsidePlayableArea and true or false
    end
    if routingData.StartedOutsidePlayableArea ~= nil then
        return not (routingData.StartedOutsidePlayableArea and true or false)
    end

    local area = GetPlayableArea()
    local insideCurrent = PositionInPlayableArea(currentPosition, area)
    if insideCurrent ~= nil then return insideCurrent end

    local insideStart = PositionInPlayableArea(startPosition, area)
    if insideStart ~= nil then return insideStart end

    return true
end

-- ============================================================
--  Debug tag helper
-- ============================================================
local function ResolveDebugTag(data)
    local tag = data.SpawnerTag or data.BuilderTag or data.PlatoonTag or data.Tag
    if tag == nil or tag == '' then return 'unknown' end
    return tostring(tag)
end

-- ============================================================
--  Movement order dispatch
-- ============================================================
local function IssuePlatoonMove(platoon, destination, formation, aggressive)
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 or not destination then return end

    if formation and formation ~= 'NoFormation' then
        if aggressive then
            local ok = pcall(IssueFormAggressiveMove, units, destination, formation, 0)
            if not ok then IssueAggressiveMove(units, destination) end
        else
            local ok = pcall(IssueFormMove, units, destination, formation)
            if not ok then IssueMove(units, destination) end
        end
    else
        if aggressive then
            IssueAggressiveMove(units, destination)
        else
            IssueMove(units, destination)
        end
    end
end

-- ============================================================
--  BuildIngressRoute  (public)
-- ============================================================
function BuildIngressRoute(routingData)
    routingData = routingData or {}

    local startPosition   = CopyVector(routingData.StartPosition)   or CopyVector(routingData.CurrentPosition)
    local currentPosition = CopyVector(routingData.CurrentPosition) or CopyVector(routingData.StartPosition)
    local targetPosition  = CopyVector(routingData.TargetPosition)

    local area             = GetPlayableArea()
    local insidePlayable   = ResolveInsidePlayableArea(routingData, currentPosition, startPosition)
    local ingressPosition  = nil
    local ingressStart     = currentPosition
    local layer            = ResolveLayer(routingData.Platoon, routingData)
    local navLayer         = ResolveNavLayer(layer)

    if area and not insidePlayable then
        ingressPosition = ClampToPlayableArea(startPosition or currentPosition, area)
        ingressStart    = ingressPosition or currentPosition
    end

    -- Avoid handing LAND/SEA platoons an ingress point in the wrong domain.
    if ingressPosition and layer == 'LAND' and IsWaterPosition(ingressPosition) then
        ingressPosition = FindNearestDomainPoint(ingressPosition, true, area)
        ingressStart = ingressPosition or currentPosition
    elseif ingressPosition and layer == 'SEA' and IsLandPosition(ingressPosition) then
        ingressPosition = FindNearestDomainPoint(ingressPosition, false, area)
        ingressStart = ingressPosition or currentPosition
    end
    
    -- AIR platoons and Transport-enabled platoons do not need ground pathfinding
    local skipNav  = (layer == 'AIR') or (routingData.Transport and true or false)

    local route = {}
    if ingressPosition then
        table.insert(route, ingressPosition)
    end
    for _, wp in ipairs(BuildLayeredRoute(ingressStart, targetPosition, navLayer, routingData.RandomizeRoute, area, skipNav) or {}) do
        table.insert(route, wp)
    end

    local result = {
        StartPosition             = startPosition,
        CurrentPosition           = currentPosition,
        TargetPosition            = targetPosition,
        PlayableArea              = area,
        MovementLayer             = layer,
        StartedOutsidePlayableArea = not insidePlayable,
        IngressPosition           = ingressPosition,
        Route                     = route,
    }

    if routingData.Debug then
        local prefix = ('[%s] '):format(ResolveDebugTag(routingData))
        result.Debug = {
            ('%sBuilding ingress + layered route:'):format(prefix),
            ('%s  StartPosition             = %s'):format(prefix, FormatPosition(startPosition)),
            ('%s  CurrentPosition           = %s'):format(prefix, FormatPosition(currentPosition)),
            ('%s  TargetPosition            = %s'):format(prefix, FormatPosition(targetPosition)),
            ('%s  MovementLayer             = %s'):format(prefix, tostring(layer)),
            ('%s  StartedOutsidePlayableArea = %s'):format(prefix, tostring(not insidePlayable)),
            ('%s  IngressPosition           = %s'):format(prefix, FormatPosition(ingressPosition)),
            ('%s  RouteWaypoints            = %d'):format(prefix, table.getn(route)),
            ('%s  RandomizeRoute            = %s'):format(prefix, tostring(routingData.RandomizeRoute and true or false)),
            ('%s  Transport                 = %s'):format(prefix, tostring(routingData.Transport and true or false)),
        }
        result.DebugBlock = BuildDebugBlock(result.Debug)
    end

    return result, result.DebugBlock, result.Debug
end

-- ============================================================
--  RoutePlatoonToTarget  (public)
-- ============================================================
function RoutePlatoonToTarget(platoon, attackData)
    if not platoon then
        return { Assault = false, Distance = math.huge, Route = {} }
    end

    local currentPosition = platoon.GetPlatoonPosition and platoon:GetPlatoonPosition() or nil
    local targetPosition  = CopyVector(attackData and attackData.TargetPosition)
    local distance        = Distance2D(currentPosition, targetPosition)

    local assaultDistance = ASSAULT_DISTANCE
    if attackData and type(attackData.AssaultDistance) == 'number' then
        assaultDistance = math.max(1, attackData.AssaultDistance)
    end

    if distance <= assaultDistance then
        return {
            Assault       = true,
            Distance      = distance,
            Route         = {},
            MovementLayer = ResolveLayer(platoon, attackData or {}),
        }
    end

    local payload = {}
    for k, v in pairs(attackData or {}) do payload[k] = v end
    payload.Platoon         = platoon
    payload.CurrentPosition = currentPosition

    local response = ReceiveAttackData(payload)
    local route    = response and response.Data and response.Data.Route or {}
    local layer    = response and response.Data and response.Data.MovementLayer or 'LAND'
    -- Only fall back to a direct target waypoint for AIR / transport layers.
    -- Ground and naval layers must not blindly route through impassable terrain.
    if table.getn(route) == 0 and targetPosition and (layer == 'AIR' or (attackData and attackData.Transport)) then
        route = { CopyVector(targetPosition) }
    end

    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) > 0 then
        IssueClearCommands(units)
        local formation = attackData.Formation or DEFAULT_FORMATION
        local aggressive = attackData.AggressiveMove and true or false
        for _, waypoint in ipairs(route) do
            IssuePlatoonMove(platoon, waypoint, formation, aggressive)
        end
    end

    return {
        Assault       = (distance <= assaultDistance),
        Distance      = distance,
        Route         = route,
        MovementLayer = response and response.Data and response.Data.MovementLayer,
    }
end

-- ============================================================
--  ReceiveAttackData  (public)
-- ============================================================
function ReceiveAttackData(attackData)
    attackData = attackData or {}
    local debugEnabled    = (attackData.Debug or attackData.debug) and true or false
    local startPosition   = CopyVector(attackData.StartPosition)
    local currentPosition = CopyVector(attackData.CurrentPosition)
    local targetPosition  = CopyVector(attackData.TargetPosition)

    local routingData = {
        Platoon          = attackData.Platoon,
        PlatoonTag       = attackData.PlatoonTag or attackData.Tag,
        SpawnerTag       = attackData.SpawnerTag,
        BuilderTag       = attackData.BuilderTag,
        AttackType       = attackData.AttackType or attackData.Type,
        StartSource      = attackData.StartSource or attackData.StartPositionSource,
        StartPosition    = startPosition,
        CurrentPosition  = currentPosition,
        TargetPosition   = targetPosition,
        InsidePlayableArea = ResolveInsidePlayableArea(attackData, currentPosition, startPosition),
        AggressiveMove   = (attackData.AggressiveMove or attackData.AggresiveMove) and true or false,
        RandomizeRoute   = attackData.RandomizeRoute  and true or false,
        Transport        = attackData.Transport       and true or false,
        MovementLayer    = attackData.MovementLayer   or attackData.Layer,
        Debug            = debugEnabled,
    }

    local ingress = BuildIngressRoute(routingData)
    routingData.IngressPosition            = ingress.IngressPosition
    routingData.Route                      = ingress.Route
    routingData.MovementLayer              = ingress.MovementLayer
    routingData.StartedOutsidePlayableArea = ingress.StartedOutsidePlayableArea

    local response = { Data = routingData }

    if debugEnabled then
        local prefix = ('[%s] '):format(ResolveDebugTag(attackData))
        response.Debug = {
            ('%sRouting handoff received from AttackFunctions:'):format(prefix),
            ('%s  AttackType                = %s'):format(prefix, tostring(routingData.AttackType)),
            ('%s  StartPosition             = %s'):format(prefix, FormatPosition(routingData.StartPosition)),
            ('%s  CurrentPosition           = %s'):format(prefix, FormatPosition(routingData.CurrentPosition)),
            ('%s  TargetPosition            = %s'):format(prefix, FormatPosition(routingData.TargetPosition)),
            ('%s  MovementLayer             = %s'):format(prefix, tostring(routingData.MovementLayer)),
            ('%s  StartedOutsidePlayableArea = %s'):format(prefix, tostring(routingData.StartedOutsidePlayableArea)),
            ('%s  RouteWaypoints            = %d'):format(prefix, table.getn(routingData.Route or {})),
            ('%s  Transport                 = %s'):format(prefix, tostring(routingData.Transport)),
        }
        for _, line in ipairs(ingress.Debug or {}) do
            table.insert(response.Debug, line)
        end
        response.DebugBlock = BuildDebugBlock(response.Debug)
    end

    return response, response.DebugBlock, response.Debug, response.Data
end

return {
    ReceiveAttackData    = ReceiveAttackData,
    BuildIngressRoute    = BuildIngressRoute,
    RoutePlatoonToTarget = RoutePlatoonToTarget,
    AssaultDistance      = ASSAULT_DISTANCE,
}
