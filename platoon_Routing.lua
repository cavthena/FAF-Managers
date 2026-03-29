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

function ReceiveAttackData(attackData)
    attackData = attackData or {}

    local routingData = {
        Platoon = attackData.Platoon,
        PlatoonTag = attackData.PlatoonTag or attackData.Tag,
        AttackType = attackData.AttackType or attackData.Type,
        StartPosition = CopyVector(attackData.StartPosition),
        CurrentPosition = CopyVector(attackData.CurrentPosition),
        TargetPosition = CopyVector(attackData.TargetPosition),
        InsidePlayableArea = BoolOrFalse(attackData.InsidePlayableArea),
        AggressiveMove = BoolOrFalse(attackData.AggresiveMove or attackData.AggressiveMove),
    }

    local response = {
        Data = routingData,
    }

    if attackData.Debug then
        response.Debug = {
            'Routing section 1 handoff received from AttackFunctions:',
            ('  Platoon = %s'):format(tostring(routingData.Platoon)),
            ('  PlatoonTag = %s'):format(tostring(routingData.PlatoonTag)),
            ('  AttackType = %s'):format(tostring(routingData.AttackType)),
            ('  StartPosition = %s'):format(FormatPosition(routingData.StartPosition)),
            ('  CurrentPosition = %s'):format(FormatPosition(routingData.CurrentPosition)),
            ('  TargetPosition = %s'):format(FormatPosition(routingData.TargetPosition)),
            ('  InsidePlayableArea = %s'):format(tostring(routingData.InsidePlayableArea)),
            ('  AggressiveMove = %s'):format(tostring(routingData.AggressiveMove)),
        }
    end

    return response
end