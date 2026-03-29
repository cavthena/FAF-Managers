--[[
================================================================================
Platoon Routing -- Created by Cavthena
================================================================================

Section 1
    Receives routing handoff data from platoon_AttackFunctions.lua and returns
    the captured payload.

    If `attackData.Debug == true`, debug lines are included in the return value.
================================================================================
]]

local function CopyVector(vec)
    if type(vec) ~= 'table' then
        return nil
    end

    local x = vec[1]
    local y = vec[2]
    local z = vec[3]

    if type(x) ~= 'number' or type(z) ~= 'number' then
        return nil
    end

    if type(y) ~= 'number' then
        y = 0
    end

    return { x, y, z }
end

local function FormatPosition(vec)
    if not vec then
        return 'nil'
    end

    return ('(%.2f, %.2f, %.2f)'):format(vec[1], vec[2], vec[3])
end

local function BoolOrFalse(value)
    return value and true or false
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
    if not (position and area) then
        return nil
    end

    return position[1] >= area[1]
        and position[1] <= area[3]
        and position[3] >= area[2]
        and position[3] <= area[4]
end

local function ResolveInsidePlayableArea(attackData, currentPosition, startPosition)
    if attackData.InsidePlayableArea ~= nil then
        return attackData.InsidePlayableArea and true or false
    end

    if attackData.StartedOutsidePlayableArea ~= nil then
        return not (attackData.StartedOutsidePlayableArea and true or false)
    end

    local area = GetPlayableArea()
    local currentInside = PositionInPlayableArea(currentPosition, area)
    if currentInside ~= nil then
        return currentInside and true or false
    end

    local startInside = PositionInPlayableArea(startPosition, area)
    if startInside ~= nil then
        return startInside and true or false
    end

    return true
end

local function ResolveDebugTag(attackData, routingData)
    local tag = attackData.SpawnerTag
        or attackData.BuilderTag
        or routingData.SpawnerTag
        or routingData.BuilderTag
        or routingData.PlatoonTag

    if tag == nil or tag == '' then
        return 'unknown-tag'
    end

    return tostring(tag)
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
        AggressiveMove = BoolOrFalse(attackData.AggresiveMove or attackData.AggressiveMove),
    }

    local response = {
        Data = routingData,
    }

    if attackData.Debug then
        local debugTag = ResolveDebugTag(attackData, routingData)
        local prefix = ('[%s] '):format(debugTag)
        response.Debug = {
            ('%sRouting section 1 handoff received from AttackFunctions:'):format(prefix),
            ('%s  --- Identity ---'):format(prefix),
            ('%s  Platoon = %s'):format(prefix, tostring(routingData.Platoon)),
            ('%s  PlatoonTag = %s'):format(prefix, tostring(routingData.PlatoonTag)),
            ('%s  SpawnerTag = %s'):format(prefix, tostring(routingData.SpawnerTag)),
            ('%s  BuilderTag = %s'):format(prefix, tostring(routingData.BuilderTag)),
            ('%s  --- Attack ---'):format(prefix),
            ('%s  AttackType = %s'):format(prefix, tostring(routingData.AttackType)),
            ('%s  AttackFunction = %s'):format(prefix, tostring(routingData.AttackFunction)),
            ('%s  --- Positions ---'):format(prefix),
            ('%s  StartSource = %s'):format(prefix, tostring(routingData.StartSource)),
            ('%s  StartPosition = %s'):format(prefix, FormatPosition(routingData.StartPosition)),
            ('%s  CurrentPosition = %s'):format(prefix, FormatPosition(routingData.CurrentPosition)),
            ('%s  TargetPosition = %s'):format(prefix, FormatPosition(routingData.TargetPosition)),
            ('%s  --- Flags ---'):format(prefix),
            ('%s  InsidePlayableArea = %s'):format(prefix, tostring(routingData.InsidePlayableArea)),
            ('%s  AggressiveMove = %s'):format(prefix, tostring(routingData.AggressiveMove)),
        }
    end

    return response
end