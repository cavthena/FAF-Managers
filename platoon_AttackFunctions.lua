local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
local Routing = import('/maps/Platoon_testing.v0001/platoon_Routing.lua')

local DEFAULT_FORMATION = 'GrowthFormation'
local RAID_RADIUS = 220
local WAVE_RADIUS = 300
local HUNT_RADIUS = 450

local RAID_CATEGORY_MAP = {
    ECO = categories.STRUCTURE * (categories.ENERGYPRODUCTION + categories.MASSEXTRACTION + categories.MASSFABRICATION),
    BLD = categories.STRUCTURE * (categories.FACTORY + categories.ENGINEERSTATION),
    INT = categories.STRUCTURE * (categories.RADAR + categories.OMNI),
    DEF = categories.STRUCTURE * (categories.DEFENSE),
    SMT = categories.STRUCTURE * (categories.TECH3 + categories.EXPERIMENTAL),
}

local function SafeWait(seconds)
    WaitSeconds(math.max(0.05, seconds or 0.5))
end

local function PlatoonAlive(platoon)
    if not platoon then return false end
    local brain = platoon:GetBrain()
    return brain and brain.PlatoonExists and brain:PlatoonExists(platoon)
end

local function CopyData(source)
    local out = {}
    for k, v in pairs(source or {}) do
        out[k] = v
    end
    return out
end

local function MergeAttackData(platoon, callData)
    local merged = CopyData(platoon and platoon.PlatoonData or {})
    for k, v in pairs(callData or {}) do
        merged[k] = v
    end
    return merged
end

local function EmitRoutingDebug(platoon, opts, targetPosition)
    local debugEnabled = opts and (opts.Debug or opts.debug)
    if not (debugEnabled and Routing and Routing.ReceiveAttackData) then
        return
    end
    if opts._routingDebugEmitted then
        return
    end
    opts._routingDebugEmitted = true

    local payload = CopyData(opts)
    if type(payload.AttackFunction) == 'function' then
        for key, value in pairs(_G or {}) do
            if value == payload.AttackFunction then
                payload.AttackFunction = tostring(key)
                break
            end
        end
    end
    payload.Platoon = platoon
    payload.CurrentPosition = payload.CurrentPosition or (platoon and platoon.GetPlatoonPosition and platoon:GetPlatoonPosition())
    payload.TargetPosition = payload.TargetPosition or targetPosition

    local response = Routing.ReceiveAttackData(payload)
    if type(response) == 'table' and type(response.Debug) == 'table' then
        for _, line in ipairs(response.Debug) do
            LOG(tostring(line))
        end
    end
end

local function GetPlayableArea()
    if ScenarioInfo and ScenarioInfo.PlayableArea then
        return ScenarioInfo.PlayableArea
    end
    local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize)
    if size then
        return {0, 0, size[1], size[2]}
    end
    return nil
end

local function RandomPointInPlayableArea()
    local area = GetPlayableArea()
    if not area then return {0, 0, 0} end
    local x = area[1] + (Random() * (area[3] - area[1]))
    local z = area[2] + (Random() * (area[4] - area[2]))
    return {x, GetTerrainHeight(x, z), z}
end

local function DistanceSq(a, b)
    if not (a and b) then return math.huge end
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return (dx * dx) + (dz * dz)
end

local function ResolveEnemyBrains(brain, targetArmy)
    local enemies = {}
    local allow = {}

    if type(targetArmy) == 'table' and table.getn(targetArmy) > 0 then
        for _, v in ipairs(targetArmy) do
            if type(v) == 'number' then
                allow[v] = true
            elseif type(v) == 'string' then
                for i, b in ipairs(ArmyBrains) do
                    if b and b.Nickname == v then
                        allow[i] = true
                    end
                end
            end
        end
    end

    for i, enemy in ipairs(ArmyBrains) do
        if enemy and enemy ~= brain and IsEnemy(brain:GetArmyIndex(), i) then
            if next(allow) == nil or allow[i] then
                table.insert(enemies, enemy)
            end
        end
    end

    return enemies
end

local function CanSeeUnit(brain, unit, intelOnly)
    if not intelOnly then
        return true
    end
    if unit.IsSeenEver and unit:IsSeenEver(brain:GetArmyIndex()) then
        return true
    end
    if unit.GetBlip and unit:GetBlip(brain:GetArmyIndex()) then
        return true
    end
    return false
end

local function CollectEnemyUnits(brain, center, radius, category, opts)
    local enemies = ResolveEnemyBrains(brain, opts.TargetArmy)
    local gathered = {}

    for _, enemy in ipairs(enemies) do
        local units = enemy:GetUnitsAroundPoint(category, center, radius or 256, 'Enemy') or {}
        for _, u in ipairs(units) do
            if u and not u.Dead and CanSeeUnit(brain, u, opts.IntelOnly) then
                table.insert(gathered, u)
            end
        end
    end

    return gathered
end

local function FindClosestUnit(platoon, units)
    local p = platoon:GetPlatoonPosition()
    if not p then return nil end
    local best, bestDist = nil, math.huge
    for _, u in ipairs(units or {}) do
        local pos = u:GetPosition()
        local d = DistanceSq(p, pos)
        if d < bestDist then
            best, bestDist = u, d
        end
    end
    return best
end

local function RoutePlatoon(platoon, opts, destination)
    if not (Routing and Routing.RoutePlatoonToTarget) then
        return { Assault = true, Distance = 0 }
    end
    local payload = CopyData(opts)
    payload.Platoon = platoon
    payload.TargetPosition = { destination[1], destination[2], destination[3] }
    payload.CurrentPosition = platoon:GetPlatoonPosition()
    return Routing.RoutePlatoonToTarget(platoon, payload)
end

local function IssueAttackUnit(platoon, target)
    if not target or target.Dead then return end
    local units = platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then return end
    IssueAttack(units, target)
end

local function AttackTargetLoop(platoon, opts, selector)
    while PlatoonAlive(platoon) do
        local target = selector()
        if target and not target.Dead then
            local pos = target:GetPosition()
            if pos then
                opts.CurrentPosition = platoon:GetPlatoonPosition()
                opts.TargetPosition = { pos[1], pos[2], pos[3] }
                EmitRoutingDebug(platoon, opts, pos)
                local moveResult = RoutePlatoon(platoon, opts, pos)
                if moveResult and moveResult.Assault then
                    IssueAttackUnit(platoon, target)
                end
            end
            SafeWait(2)
        else
            SafeWait(3)
        end
    end
end

local function ResolveRaidCategory(data)
    local key = (data and data.Category and string.upper(data.Category)) or 'ECO'
    local requested = RAID_CATEGORY_MAP[key] or RAID_CATEGORY_MAP.ECO
    return {
        requested,
        RAID_CATEGORY_MAP.ECO,
        RAID_CATEGORY_MAP.BLD,
        RAID_CATEGORY_MAP.INT,
        RAID_CATEGORY_MAP.DEF,
    }
end

local function FindRaidTarget(brain, platoon, opts)
    local pos = platoon:GetPlatoonPosition()
    if not pos then return nil end

    for _, cat in ipairs(ResolveRaidCategory(opts)) do
        local units = CollectEnemyUnits(brain, pos, RAID_RADIUS, cat, opts)
        local target = FindClosestUnit(platoon, units)
        if target then
            return target
        end
    end
    return nil
end

local function FindWaveTarget(brain, platoon, opts)
    local pos = platoon:GetPlatoonPosition()
    if not pos then return nil end
    local units = CollectEnemyUnits(brain, pos, WAVE_RADIUS, categories.STRUCTURE, opts)
    return FindClosestUnit(platoon, units)
end

local function NormalizeBlueprintSet(data)
    local out = {}
    local list = data.Blueprints or data.Blueprint or data.TargetBlueprints or data.TargetBP
    if type(list) == 'string' then list = { list } end
    for _, id in ipairs(list or {}) do
        if type(id) == 'string' and id ~= '' then
            out[string.lower(id)] = true
        end
    end
    return out
end

local function UnitBlueprintId(unit)
    if not unit then return nil end
    if unit.GetBlueprint and unit:GetBlueprint() and unit:GetBlueprint().BlueprintId then
        return string.lower(unit:GetBlueprint().BlueprintId)
    end
    if unit.BlueprintID then
        return string.lower(unit.BlueprintID)
    end
    return nil
end

local function NormalizeCategoryFilter(data)
    local cats = data.TargetCategories or data.TargetCategory or data.Categories or data.Category
    if cats == nil then return nil end
    if type(cats) ~= 'table' then
        return { cats }
    end
    return cats
end

local function MatchesAnyCategory(unit, categoryList)
    if not categoryList or table.getn(categoryList) == 0 then
        return true
    end
    for _, cat in ipairs(categoryList) do
        if EntityCategoryContains(cat, unit) then
            return true
        end
    end
    return false
end

local function FindHuntTarget(brain, platoon, opts)
    local pos = platoon:GetPlatoonPosition()
    if not pos then return nil end

    local candidates = CollectEnemyUnits(brain, pos, HUNT_RADIUS, categories.ALLUNITS - categories.WALL, opts)
    local blueprints = NormalizeBlueprintSet(opts)
    local categoriesFilter = NormalizeCategoryFilter(opts)

    local filtered = {}
    for _, unit in ipairs(candidates) do
        local ok = true
        if next(blueprints) ~= nil then
            ok = blueprints[UnitBlueprintId(unit)] == true
        end
        if ok and categoriesFilter then
            ok = MatchesAnyCategory(unit, categoriesFilter)
        end
        if ok then
            table.insert(filtered, unit)
        end
    end

    return FindClosestUnit(platoon, filtered)
end

local function ResolveMarkerPosition(marker)
    if type(marker) == 'string' then
        return ScenarioUtils.MarkerToPosition(marker)
    elseif type(marker) == 'table' then
        if marker.position then return marker.position end
        if marker.Position then return marker.Position end
        if marker[1] and marker[2] and marker[3] then return marker end
    end
    return nil
end

function WaveAttack(platoon, data)
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts = MergeAttackData(platoon, data)
    AttackTargetLoop(platoon, opts, function()
        return FindWaveTarget(brain, platoon, opts)
    end)
end

function RaidAttack(platoon, data)
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts = MergeAttackData(platoon, data)
    AttackTargetLoop(platoon, opts, function()
        return FindRaidTarget(brain, platoon, opts)
    end)
end

function HuntAttack(platoon, data)
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts = MergeAttackData(platoon, data)

    local idlePos = ResolveMarkerPosition(opts.Marker or opts.IdleMarker)
    AttackTargetLoop(platoon, opts, function()
        local target = FindHuntTarget(brain, platoon, opts)
        if not target and idlePos then
            RoutePlatoon(platoon, opts, idlePos)
        end
        return target
    end)
end

function ScoutAttack(platoon, data)
    local opts = MergeAttackData(platoon, data)
    while PlatoonAlive(platoon) do
        local destination = RandomPointInPlayableArea()
        opts.CurrentPosition = platoon:GetPlatoonPosition()
        opts.TargetPosition = { destination[1], destination[2], destination[3] }
        EmitRoutingDebug(platoon, opts, destination)
        RoutePlatoon(platoon, opts, destination)
        SafeWait(6)
    end
end

function AreaPatrol(platoon, data)
    local opts = MergeAttackData(platoon, data)
    local chain = opts.Chain or opts.ChainName
    if not chain then return end

    local markers = ScenarioUtils.ChainToPositions(chain) or {}
    if table.getn(markers) == 0 then return end

    for _, p in ipairs(markers) do
        opts.CurrentPosition = platoon:GetPlatoonPosition()
        opts.TargetPosition = { p[1], p[2], p[3] }
        EmitRoutingDebug(platoon, opts, p)
        RoutePlatoon(platoon, opts, p)
    end

    while PlatoonAlive(platoon) do
        SafeWait(5)
    end
end

function DefensePatrol(platoon, data)
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts = MergeAttackData(platoon, data)

    local basePos = ResolveMarkerPosition(opts.BaseMarker or opts.BasePosition) or platoon:GetPlatoonPosition()
    if not basePos then return end

    local radius = opts.InterceptDistance or opts.InterceptRadius or 110
    while PlatoonAlive(platoon) do
        local threats = CollectEnemyUnits(brain, basePos, radius, categories.MOBILE + categories.STRUCTURE, opts)
        local target = FindClosestUnit(platoon, threats)
        if target then
            local pos = target:GetPosition()
            if pos then
                opts.CurrentPosition = platoon:GetPlatoonPosition()
                opts.TargetPosition = { pos[1], pos[2], pos[3] }
                EmitRoutingDebug(platoon, opts, pos)
                local moveResult = RoutePlatoon(platoon, opts, pos)
                if moveResult and moveResult.Assault then
                    IssueAttackUnit(platoon, target)
                end
            end
        else
            RoutePlatoon(platoon, opts, basePos)
        end
        SafeWait(3)
    end
end

return {
    WaveAttack = WaveAttack,
    RaidAttack = RaidAttack,
    ScoutAttack = ScoutAttack,
    AreaPatrol = AreaPatrol,
    HuntAttack = HuntAttack,
    DefensePatrol = DefensePatrol,
}