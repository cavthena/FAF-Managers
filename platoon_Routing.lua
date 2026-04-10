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

    IssueClearCommands(units)
    IssueMovement(
        units,
        targetPos,
        options.AggressiveMove and true or false,
        options.Formation or 'NoFormation'
    )
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
    CanReachPosition          = CanReachPosition,
    CanUnitDomainAttackTarget = CanUnitDomainAttackTarget,
    MovePlatoonTo             = MovePlatoonTo,
    AttackMoveToTarget        = AttackMoveToTarget,
    WaitAtMarker              = WaitAtMarker,
}
