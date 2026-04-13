--[[
================================================================================
 Platoon Routing -- FAF / Lua 5.0 compatible
================================================================================

Purpose
    Shared routing helpers used by platoon_AttackFunctions.lua.
    Handles:
      * Reachability / pathability checks by platoon domain using NavUtils.
      * Domain and water-crossing validation before movement is issued.
      * Ordered movement (aggressive or normal) using configurable formation.
      * Waiting behavior at markers, including air loitering.

Notes
    * This file avoids Lua 5.1+ only features and is authored for Lua 5.0 style.
    * NavUtils is used for all pathability checks; movement itself relies on
      the game's built-in unit pathfinder.
]]

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local okNav, NavUtils = pcall(import, '/lua/sim/NavUtils.lua')
if not okNav then
    NavUtils = false
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function IsAlive(unit)
    return unit and (not unit.Dead)
end

local function PlatoonUnits(platoon)
    if not platoon or platoon.Dead then
        return {}
    end
    return platoon:GetPlatoonUnits() or {}
end

local function GetDomain(platoon)
    if not platoon or platoon.Dead then
        return 'LAND'
    end

    if type(platoon.MovementLayer) == 'string' and platoon.MovementLayer ~= '' then
        local l = string.upper(platoon.MovementLayer)
        if l == 'AIR' or l == 'LAND' or l == 'NAVAL' or l == 'AMPHIBIOUS' then
            return l
        end
    end

    local units = PlatoonUnits(platoon)
    local first = units[1]
    if not first then
        return 'LAND'
    end

    if EntityCategoryContains(categories.AIR, first) then
        return 'AIR'
    elseif EntityCategoryContains(categories.NAVAL, first) then
        return 'NAVAL'
    end

    return 'LAND'
end

local function GetPosition(markerOrPos)
    if not markerOrPos then
        return nil
    end

    if type(markerOrPos) == 'string' then
        return ScenarioUtils.MarkerToPosition(markerOrPos)
    end

    if type(markerOrPos) == 'table' then
        if markerOrPos.position then return markerOrPos.position end
        if markerOrPos.Position then return markerOrPos.Position end
        if markerOrPos[1] and markerOrPos[2] and markerOrPos[3] then
            return markerOrPos
        end
    end

    return nil
end

local function GetPlatoonCenter(platoon)
    if platoon and platoon.GetPlatoonPosition then
        local p = platoon:GetPlatoonPosition()
        if p then return p end
    end

    local units = PlatoonUnits(platoon)
    local u = units[1]
    if u and u.GetPosition then
        return u:GetPosition()
    end

    return nil
end

local function GetNavLayer(domain)
    domain = string.upper(domain or 'LAND')
    if domain == 'AIR'        then return 'Air'        end
    if domain == 'NAVAL'      then return 'Water'      end
    if domain == 'AMPHIBIOUS' then return 'Amphibious' end
    return 'Land'
end

-- Sample (steps+1) evenly-spaced points along the segment fromPos→toPos.
-- Returns false as soon as an impassable point is found.
--   AIR / AMPHIBIOUS : always returns true.
-- Primary check  : NavUtils.GetLabel on the domain navmesh layer.
--   A label of -1 means the point is off the navmesh (blocked terrain OR
--   water), so this catches cliffs and steep slopes as well as water.
-- Fallback check : height-based water detection when NavUtils is unavailable.
--   LAND  — fails on water (surfaceH > terrainH + 0.5).
--   NAVAL — fails on non-water.
local function SegmentIsPassable(fromPos, toPos, domain, steps)
    domain = string.upper(domain or 'LAND')

    if domain == 'AIR' or domain == 'AMPHIBIOUS' then
        return true
    end

    steps = steps or 8
    local navLayer     = GetNavLayer(domain)
    local useNavLabel  = NavUtils and NavUtils.GetLabel

    local x1 = fromPos[1]
    local z1 = fromPos[3]
    local x2 = toPos[1]
    local z2 = toPos[3]

    for i = 0, steps do
        local t  = i / steps
        local sx = x1 + (x2 - x1) * t
        local sz = z1 + (z2 - z1) * t
        local sy = GetSurfaceHeight(sx, sz)

        if useNavLabel then
            -- NavMesh check: label == -1 means off-navmesh (blocked terrain or water).
            local ok, label = pcall(NavUtils.GetLabel, navLayer, { sx, sy, sz })
            if ok and label == -1 then
                return false
            end
        else
            -- Fallback: height-based water detection only.
            local terrainH = GetTerrainHeight(sx, sz)
            local overWater = sy > terrainH + 0.5

            if domain == 'LAND' and overWater then
                return false
            elseif domain == 'NAVAL' and not overWater then
                return false
            end
        end
    end

    return true
end

-- Returns the perpendicular unit vector (px, pz) for the direction fromPos→toPos.
-- Used to offset a midpoint sideways when trying to clear a blocked segment.
local function SegmentPerp(fromPos, toPos)
    local dx = toPos[1] - fromPos[1]
    local dz = toPos[3] - fromPos[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then
        return 1, 0
    end
    return -dz / len, dx / len
end

-- Try increasing perpendicular offsets from the midpoint of fromPos→toPos until
-- a candidate M' is found where both fromPos→M' and M'→toPos are passable.
--   clearance   : game-unit step size per attempt.
--   maxAttempts : number of offset multiples to try in each direction.
-- Returns a {x,y,z} position table, or nil if no clear point is found.
local function FindClearMidpoint(fromPos, toPos, domain, clearance, maxAttempts)
    local mx = (fromPos[1] + toPos[1]) * 0.5
    local mz = (fromPos[3] + toPos[3]) * 0.5
    local px, pz = SegmentPerp(fromPos, toPos)

    for attempt = 1, maxAttempts do
        local offset = clearance * attempt
        for _, sign in ipairs({ 1, -1 }) do
            local cx = mx + px * offset * sign
            local cz = mz + pz * offset * sign
            local candidate = { cx, GetSurfaceHeight(cx, cz), cz }
            if SegmentIsPassable(fromPos, candidate, domain)
                and SegmentIsPassable(candidate, toPos, domain)
            then
                return candidate
            end
        end
    end

    return nil
end

-- Recursively resolve the segment fromPos→toPos into passable sub-segments,
-- inserting clearance waypoints as needed.
--   clearance / maxAttempts : passed to FindClearMidpoint.
--   depth / maxDepth        : recursion guard.
-- Results (excluding fromPos) are appended to `out`; toPos is always appended
-- as the terminal point of this call so the original destination is preserved.
local function ClearSegmentInto(fromPos, toPos, domain, clearance, maxAttempts, depth, maxDepth, out)
    -- Segment already passable: nothing to do.
    if SegmentIsPassable(fromPos, toPos, domain) then
        table.insert(out, toPos)
        return
    end

    -- Recursion limit reached: accept the endpoint as-is.
    if depth >= maxDepth then
        table.insert(out, toPos)
        return
    end

    -- Try to resolve the whole blocked segment with a single offset waypoint.
    local mid = FindClearMidpoint(fromPos, toPos, domain, clearance, maxAttempts)
    if mid then
        ClearSegmentInto(fromPos, mid,  domain, clearance, maxAttempts, depth + 1, maxDepth, out)
        ClearSegmentInto(mid,   toPos,  domain, clearance, maxAttempts, depth + 1, maxDepth, out)
        return
    end

    -- Single waypoint not enough; bisect the segment and recurse on both halves.
    local bx = (fromPos[1] + toPos[1]) * 0.5
    local bz = (fromPos[3] + toPos[3]) * 0.5
    local bisect = { bx, GetSurfaceHeight(bx, bz), bz }

    ClearSegmentInto(fromPos, bisect, domain, clearance, maxAttempts, depth + 1, maxDepth, out)
    ClearSegmentInto(bisect,  toPos,  domain, clearance, maxAttempts, depth + 1, maxDepth, out)
end

-- Build a safe route from a list of positions, inserting clearance waypoints
-- to route around blocked terrain or water wherever a direct segment fails.
-- The first position is always kept unchanged.
--   steps       : sample resolution passed to SegmentIsPassable (default 8).
--   clearance   : perpendicular offset step in game units (default 12).
--   maxAttempts : perpendicular attempts per side before bisecting (default 10).
--   maxDepth    : recursion depth limit for ClearSegmentInto (default 4).
local function BuildSafeRoute(positions, domain, steps)
    if not positions or table.getn(positions) < 1 then
        return positions
    end

    local clearance   = 12
    local maxAttempts = 10
    local maxDepth    = 4

    local out  = { positions[1] }
    local prev = positions[1]

    for i = 2, table.getn(positions) do
        local curr = positions[i]
        if SegmentIsPassable(prev, curr, domain, steps) then
            table.insert(out, curr)
        else
            ClearSegmentInto(prev, curr, domain, clearance, maxAttempts, 0, maxDepth, out)
        end
        prev = out[table.getn(out)]
    end

    return out
end

-- Issues a single movement command.  Formation takes priority over plain
-- move/aggressive-move so only one command is queued per waypoint.
local function IssueMovement(units, destination, aggressive, formation)
    if formation and formation ~= 'NoFormation' and formation ~= '' then
        IssueFormMove(units, destination, formation)
    elseif aggressive then
        IssueAggressiveMove(units, destination)
    else
        IssueMove(units, destination)
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function CanReachPosition(platoon, destination, options)
    options = options or {}
    destination = GetPosition(destination)
    if not destination then
        return false
    end

    -- Transport allows reaching any position regardless of terrain.
    if options.Transport then
        return true
    end

    local domain = options.Domain or GetDomain(platoon)
    -- Air units are never blocked by terrain or water.
    if string.upper(domain) == 'AIR' then
        return true
    end

    local start = GetPlatoonCenter(platoon)
    if not start then
        return false
    end

    if NavUtils and NavUtils.CanPathTo then
        local layer = GetNavLayer(domain)
        local ok, canPath = pcall(NavUtils.CanPathTo, layer, start, destination)
        if ok then
            return canPath and true or false
        end
    end

    -- NavUtils unavailable: allow movement and let the game pathfinder decide.
    return true
end

local function CanUnitDomainAttackTarget(domain, targetUnit, bombard)
    if not IsAlive(targetUnit) then
        return false
    end

    domain = string.upper(domain or 'LAND')

    if bombard then
        return true
    end

    if domain == 'LAND' then
        -- Land units cannot attack pure naval targets.
        return not EntityCategoryContains(categories.NAVAL, targetUnit)
    elseif domain == 'NAVAL' then
        -- Naval units can only attack other naval units unless bombarding.
        return EntityCategoryContains(categories.NAVAL, targetUnit)
    end

    -- AIR / AMPHIBIOUS can attack anything.
    return true
end

local function MovePlatoonTo(platoon, destination, options)
    options = options or {}
    destination = GetPosition(destination)
    if not destination then
        return false
    end

    local units = PlatoonUnits(platoon)
    if table.getn(units) < 1 then
        return false
    end

    IssueClearCommands(units)
    IssueMovement(
        units,
        destination,
        options.AggressiveMove and true or false,
        options.Formation or 'NoFormation'
    )
    return true
end

-- Issue a move-along-route command sequence (queued, no stop between waypoints).
local function MoveAlongRoute(platoon, waypoints, options)
    local n = table.getn(waypoints)
    if n < 1 then return end
    local units = PlatoonUnits(platoon)
    if table.getn(units) < 1 then return end
    local aggressive = options and options.AggressiveMove and true or false
    local formation  = (options and options.Formation) or 'NoFormation'
    IssueClearCommands(units)
    for i = 1, n do
        IssueMovement(units, waypoints[i], aggressive, formation)
    end
end

local function AttackMoveToTarget(platoon, targetUnit, options)
    options = options or {}
    if not IsAlive(targetUnit) then
        return false
    end

    local units = PlatoonUnits(platoon)
    if table.getn(units) < 1 then
        return false
    end

    local targetPos = targetUnit:GetPosition()
    if not targetPos then
        return false
    end

    -- Build a routed path so the platoon navigates around terrain/water corners
    -- instead of relying solely on the engine pathfinder for the straight line.
    local domain = options.Domain or GetDomain(platoon)
    local start  = GetPlatoonCenter(platoon)
    local route
    if start then
        route = BuildSafeRoute({ start, targetPos }, domain)
    else
        route = { targetPos }
    end

    MoveAlongRoute(platoon, route, options)
    IssueAttack(units, targetUnit)
    return true
end

local function HasArrived(platoon, pos, radiusSq)
    local center = GetPlatoonCenter(platoon)
    if not center then
        return false
    end
    local dx = center[1] - pos[1]
    local dz = center[3] - pos[3]
    return (dx * dx + dz * dz) <= radiusSq
end

local function AirCircleAt(platoon, markerPos, options)
    options = options or {}
    local units = PlatoonUnits(platoon)
    if table.getn(units) < 1 then
        return
    end

    local formation = options.Formation or 'NoFormation'
    local r = options.CircleRadius or 24

    IssueClearCommands(units)
    IssueFormMove(units, { markerPos[1] + r, markerPos[2], markerPos[3]     }, formation)
    IssueFormMove(units, { markerPos[1],     markerPos[2], markerPos[3] + r }, formation)
    IssueFormMove(units, { markerPos[1] - r, markerPos[2], markerPos[3]     }, formation)
    IssueFormMove(units, { markerPos[1],     markerPos[2], markerPos[3] - r }, formation)
    IssueFormMove(units, { markerPos[1] + r, markerPos[2], markerPos[3]     }, formation)
end

local function WaitAtMarker(platoon, marker, options)
    options = options or {}
    local pos = GetPosition(marker)
    if not pos then
        return false
    end

    local units = PlatoonUnits(platoon)
    if table.getn(units) < 1 then
        return false
    end

    local domain  = string.upper(options.Domain or GetDomain(platoon))
    local radius  = options.ArriveRadius or 12
    local radiusSq = radius * radius

    if domain == 'AIR' then
        if not HasArrived(platoon, pos, radiusSq) then
            MovePlatoonTo(platoon, pos, options)
            WaitSeconds(2)
        end
        AirCircleAt(platoon, pos, options)
    else
        MovePlatoonTo(platoon, pos, options)
    end

    return true
end

return {
    GetDomain                 = GetDomain,
    GetPosition               = GetPosition,
    SegmentIsPassable         = SegmentIsPassable,
    BuildSafeRoute            = BuildSafeRoute,
    CanReachPosition          = CanReachPosition,
    CanUnitDomainAttackTarget = CanUnitDomainAttackTarget,
    MovePlatoonTo             = MovePlatoonTo,
    AttackMoveToTarget        = AttackMoveToTarget,
    WaitAtMarker              = WaitAtMarker,
}
