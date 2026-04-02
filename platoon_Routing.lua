--[[
================================================================================
Platoon Routing -- Created by Cavthena
================================================================================

Routing and movement ownership lives in this file.
Attack functions should provide targets and assault behavior only.
================================================================================
]]

local NavUtils = import('/lua/sim/NavUtils.lua')

local ASSAULT_DISTANCE = 80
local DEFAULT_FORMATION = 'GrowthFormation'

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
    return math.sqrt((dx * dx) + (dz * dz))
end

local function BuildDebugBlock(debugLines)
    if type(debugLines) ~= 'table' or table.getn(debugLines) == 0 then return nil end
    return table.concat(debugLines, '\n')
end

local function FormatPosition(vec)
    if not vec then return 'nil' end
    return ('(%.2f, %.2f, %.2f)'):format(vec[1], vec[2], vec[3])
end

local function GetPlayableArea()
    if ScenarioInfo and ScenarioInfo.PlayableArea then
        return ScenarioInfo.PlayableArea
    end

    local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize)
    if size then
        return { 0, 0, size[1], size[2] }
    end

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

local function ResolveLayer(platoon, routingData)
    local hint = routingData and (routingData.MovementLayer or routingData.Layer)
    if type(hint) == 'string' then
        local upper = string.upper(hint)
        if upper == 'LAND' or upper == 'AIR' or upper == 'SEA' or upper == 'AMPHIBIOUS' then
            return upper
        end
    end

    if platoon and platoon.MovementLayer then
        local upper = string.upper(platoon.MovementLayer)
        if upper ~= '' then return upper end
    end

    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    local lead = units[1]
    if lead and lead.GetBlueprint then
        local bp = lead:GetBlueprint()
        local layer = bp and bp.Physics and bp.Physics.MotionType
        if layer == 'RULEUMT_Air' then return 'AIR' end
        if layer == 'RULEUMT_Water' then return 'SEA' end
        if layer == 'RULEUMT_Amphibious' then return 'AMPHIBIOUS' end
    end

    return 'LAND'
end

local function ResolveNavLayer(layer)
    if layer == 'AIR' then return 'Air' end
    if layer == 'SEA' then return 'Water' end
    if layer == 'AMPHIBIOUS' then return 'Amphibious' end
    return 'Land'
end

local function TryCanPath(navLayer, startPos, endPos)
    if not (NavUtils and NavUtils.CanPathTo and startPos and endPos) then
        return true
    end

    local ok, result = pcall(NavUtils.CanPathTo, navLayer, startPos[1], startPos[3], endPos[1], endPos[3])
    if ok and type(result) == 'boolean' then return result end

    ok, result = pcall(NavUtils.CanPathTo, navLayer, startPos, endPos)
    if ok and type(result) == 'boolean' then return result end

    return true
end

local function TryPathTo(navLayer, startPos, endPos)
    if not (NavUtils and NavUtils.PathTo and startPos and endPos) then
        return nil
    end

    local ok, path = pcall(NavUtils.PathTo, navLayer, startPos[1], startPos[3], endPos[1], endPos[3])
    if ok and type(path) == 'table' and table.getn(path) > 0 then
        return path
    end

    ok, path = pcall(NavUtils.PathTo, navLayer, startPos, endPos)
    if ok and type(path) == 'table' and table.getn(path) > 0 then
        return path
    end

    return nil
end

local function NormalizeNavPath(path)
    local out = {}
    for _, p in ipairs(path or {}) do
        local point = p.Position or p.position or p
        if type(point) == 'table' and type(point[1]) == 'number' and type(point[3]) == 'number' then
            table.insert(out, { point[1], point[2] or 0, point[3] })
        end
    end
    return out
end

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

local function BuildDirectSegment(navLayer, fromPos, toPos)
    if TryCanPath(navLayer, fromPos, toPos) then
        return { CopyVector(toPos) }
    end

    local path = NormalizeNavPath(TryPathTo(navLayer, fromPos, toPos))
    if table.getn(path) == 0 then
        return { CopyVector(toPos) }
    end

    if Distance2D(path[table.getn(path)], toPos) > 2 then
        table.insert(path, CopyVector(toPos))
    end

    return path
end

local function BuildFlankCandidates(startPos, targetPos, area)
    local dx = targetPos[1] - startPos[1]
    local dz = targetPos[3] - startPos[3]
    local dist = math.max(1, math.sqrt((dx * dx) + (dz * dz)))
    local nx = dx / dist
    local nz = dz / dist
    local radius = math.max(60, math.min(140, dist * 0.35))

    local left = { targetPos[1] - nz * radius, targetPos[2], targetPos[3] + nx * radius }
    local right = { targetPos[1] + nz * radius, targetPos[2], targetPos[3] - nx * radius }

    if area then
        left = ClampToPlayableArea(left, area)
        right = ClampToPlayableArea(right, area)
    end

    return { left, right }
end

local function BuildLayeredRoute(startPos, targetPos, navLayer, randomizeRoute, area)
    local route = {}
    if not (startPos and targetPos) then return route end

    local best = BuildDirectSegment(navLayer, startPos, targetPos)

    if randomizeRoute then
        local candidates = {}
        for _, flank in ipairs(BuildFlankCandidates(startPos, targetPos, area)) do
            local legA = BuildDirectSegment(navLayer, startPos, flank)
            local legB = BuildDirectSegment(navLayer, flank, targetPos)
            if table.getn(legA) > 0 and table.getn(legB) > 0 then
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

local function ResolveDebugTag(attackData, routingData)
    local tag = attackData.SpawnerTag
        or attackData.BuilderTag
        or routingData.SpawnerTag
        or routingData.BuilderTag
        or routingData.PlatoonTag

    if tag == nil or tag == '' then return 'unknown-tag' end
    return tostring(tag)
end

local function IssuePlatoonMove(platoon, destination, formation, aggressive)
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 or not destination then return end

    if formation and formation ~= 'NoFormation' then
        if aggressive then
            IssueFormAggressiveMove(units, destination, formation, 0)
        else
            IssueFormMove(units, destination, formation)
        end
    else
        if aggressive then
            IssueAggressiveMove(units, destination)
        else
            IssueMove(units, destination)
        end
    end
end

function BuildIngressRoute(routingData)
    routingData = routingData or {}

    local startPosition = CopyVector(routingData.StartPosition) or CopyVector(routingData.CurrentPosition)
    local currentPosition = CopyVector(routingData.CurrentPosition) or CopyVector(routingData.StartPosition)
    local targetPosition = CopyVector(routingData.TargetPosition)

    local area = GetPlayableArea()
    local insidePlayableArea = ResolveInsidePlayableArea(routingData, currentPosition, startPosition)
    local ingressPosition = nil
    local ingressStart = currentPosition

    if area and not insidePlayableArea then
        ingressPosition = ClampToPlayableArea(startPosition or currentPosition, area)
        ingressStart = ingressPosition or currentPosition
    end

    local layer = ResolveLayer(routingData.Platoon, routingData)
    local navLayer = ResolveNavLayer(layer)

    local route = {}
    if ingressPosition then
        table.insert(route, ingressPosition)
    end

    for _, waypoint in ipairs(BuildLayeredRoute(ingressStart, targetPosition, navLayer, routingData.RandomizeRoute, area) or {}) do
        table.insert(route, waypoint)
    end

    local result = {
        StartPosition = startPosition,
        CurrentPosition = currentPosition,
        TargetPosition = targetPosition,
        PlayableArea = area,
        MovementLayer = layer,
        StartedOutsidePlayableArea = not insidePlayableArea,
        IngressPosition = ingressPosition,
        Route = route,
    }

    if routingData.Debug then
        local debugTag = ResolveDebugTag(routingData, routingData)
        local prefix = ('[%s] '):format(debugTag)
        result.Debug = {
            ('%sRouting ingress + layered route:'):format(prefix),
            ('%s  StartPosition = %s'):format(prefix, FormatPosition(startPosition)),
            ('%s  CurrentPosition = %s'):format(prefix, FormatPosition(currentPosition)),
            ('%s  TargetPosition = %s'):format(prefix, FormatPosition(targetPosition)),
            ('%s  MovementLayer = %s'):format(prefix, tostring(layer)),
            ('%s  StartedOutsidePlayableArea = %s'):format(prefix, tostring(result.StartedOutsidePlayableArea)),
            ('%s  IngressPosition = %s'):format(prefix, FormatPosition(ingressPosition)),
            ('%s  RouteWaypoints = %d'):format(prefix, table.getn(route)),
            ('%s  RandomizeRoute = %s'):format(prefix, tostring(routingData.RandomizeRoute and true or false)),
        }
        result.DebugBlock = BuildDebugBlock(result.Debug)
    end

    return result, result.DebugBlock, result.Debug
end

function RoutePlatoonToTarget(platoon, attackData)
    if not platoon then return { Assault = false, Distance = math.huge, Route = {} } end

    local currentPosition = platoon.GetPlatoonPosition and platoon:GetPlatoonPosition() or nil
    local targetPosition = CopyVector(attackData and attackData.TargetPosition)
    local distance = Distance2D(currentPosition, targetPosition)
    if distance <= ASSAULT_DISTANCE then
        return {
            Assault = true,
            Distance = distance,
            Route = {},
            MovementLayer = ResolveLayer(platoon, attackData or {}),
        }
    end

    local payload = {}
    for k, v in pairs(attackData or {}) do payload[k] = v end
    payload.Platoon = platoon
    payload.CurrentPosition = currentPosition

    local response = ReceiveAttackData(payload)
    local route = response and response.Data and response.Data.Route or {}

    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) > 0 then
        IssueClearCommands(units)
        for _, waypoint in ipairs(route or {}) do
            IssuePlatoonMove(platoon, waypoint, attackData.Formation or DEFAULT_FORMATION, attackData.AggressiveMove)
        end
    end

    return {
        Assault = false,
        Distance = distance,
        Route = route,
        MovementLayer = response and response.Data and response.Data.MovementLayer,
    }
end

function ReceiveAttackData(attackData)
    attackData = attackData or {}
    local startPosition = CopyVector(attackData.StartPosition)
    local currentPosition = CopyVector(attackData.CurrentPosition)
    local targetPosition = CopyVector(attackData.TargetPosition)

    local routingData = {
        Platoon = attackData.Platoon,
        PlatoonTag = attackData.PlatoonTag or attackData.Tag,
        SpawnerTag = attackData.SpawnerTag,
        BuilderTag = attackData.BuilderTag,
        AttackType = attackData.AttackType or attackData.Type,
        AttackFunction = attackData.AttackFunction or attackData.attackFn,
        StartSource = attackData.StartSource or attackData.StartPositionSource,
        StartPosition = startPosition,
        CurrentPosition = currentPosition,
        TargetPosition = targetPosition,
        InsidePlayableArea = ResolveInsidePlayableArea(attackData, currentPosition, startPosition),
        AggressiveMove = (attackData.AggresiveMove or attackData.AggressiveMove) and true or false,
        RandomizeRoute = attackData.RandomizeRoute and true or false,
        MovementLayer = attackData.MovementLayer or attackData.Layer,
    }

    local ingress = BuildIngressRoute(routingData)
    routingData.IngressPosition = ingress.IngressPosition
    routingData.Route = ingress.Route
    routingData.MovementLayer = ingress.MovementLayer
    routingData.StartedOutsidePlayableArea = ingress.StartedOutsidePlayableArea

    local response = { Data = routingData }

    if attackData.Debug then
        local debugTag = ResolveDebugTag(attackData, routingData)
        local prefix = ('[%s] '):format(debugTag)
        response.Debug = {
            ('%sRouting handoff received from AttackFunctions:'):format(prefix),
            ('%s  AttackType = %s'):format(prefix, tostring(routingData.AttackType)),
            ('%s  AttackFunction = %s'):format(prefix, tostring(routingData.AttackFunction)),
            ('%s  StartPosition = %s'):format(prefix, FormatPosition(routingData.StartPosition)),
            ('%s  CurrentPosition = %s'):format(prefix, FormatPosition(routingData.CurrentPosition)),
            ('%s  TargetPosition = %s'):format(prefix, FormatPosition(routingData.TargetPosition)),
            ('%s  MovementLayer = %s'):format(prefix, tostring(routingData.MovementLayer)),
            ('%s  StartedOutsidePlayableArea = %s'):format(prefix, tostring(routingData.StartedOutsidePlayableArea)),
            ('%s  RouteWaypoints = %d'):format(prefix, table.getn(routingData.Route or {})),
        }
        for _, line in ipairs(ingress.Debug or {}) do
            table.insert(response.Debug, line)
        end
        response.DebugBlock = BuildDebugBlock(response.Debug)
    end

    return response, response.DebugBlock, response.Debug, response.Data
end

return {
    ReceiveAttackData = ReceiveAttackData,
    BuildIngressRoute = BuildIngressRoute,
    RoutePlatoonToTarget = RoutePlatoonToTarget,
    AssaultDistance = ASSAULT_DISTANCE,
}