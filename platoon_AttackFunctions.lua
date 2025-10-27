--[[
Usage Overview
==============

Import the module from your scenario or manager scripts and hand it a platoon
plus an options table when transferring control to an attack thread:

    local PlatoonAttacks = import('/lua/AI/platoon_AttackFunctions.lua')
    platoon:ForkAIThread(PlatoonAttacks.WaveAttack, {
        Domain = 'LAND',
        TargetArmy = {'Player1', 'Player2'},
        TargetType = 'concentration',
    })

Every entry point shares the same global options:
  * `TargetArmy` (table of army nicknames / indices) limits target scanning.
  * `IntelOnly` (bool, default `false`) respects Fog-of-War if `true`.
  * `Formation` (string, default `'GrowthFormation'`) selects movement
    formation: `'AttackFormation'`, `'GrowthFormation'`, or `'NoFormation'`.
  * `Domain` (string, required) restricts routing & targeting. Accepted values:
    `'LAND'`, `'AMPHIBIOUS'`, `'AIR'`, `'SEA'`. Amphibious units route across
    water but evaluate land targets.
  * `Underwater` (bool, default `false`) allows targeting submerged units when
    `true`.
  * `UseTransports` (bool, default `false`) requests airlift support for long or
    blocked paths. Units unload before switching back to their domain routing.
  * `AvoidDef` (bool, default `false`) attempts to path around dangerous
    defenses when possible.

Function specific options:
  * `WaveAttack` / `Bombard` / `Siege` require `TargetType = 'concentration'` or
    `'closest'` to determine structure selection.
  * `RaidAttack` requires `TargetType` from `'ECO' | 'FAB' | 'ENG' | 'DEF' |
    'SMT'` and automatically falls back through other categories as needed.
  * `Scout` has no additional parameters; units split between known and random
    intel sweeps.
  * `Cull` roams near known enemies to ambush mobile units only.
  * `Hunt` needs `TargetList` (array of unit BPs) and optional `Wait` (bool)
    that delays attacks until targets leave defensive umbrellas.
  * `Firebase` expects `Location` (array of marker names / positions) and
    matching `Template` entries (scenario army groups) describing the base to
    construct at each marker. Engineers loop through the list, rebuilding as
    required.

Each function runs until its platoon is destroyed or no further targets can be
found. Targets are re-evaluated roughly every 10 seconds, and commands are
issued using the standard move or aggressive move route helpers provided by the
engine.
]]

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
local ScenarioFramework = import('/lua/ScenarioFramework.lua')
local NavUtils = import('/lua/sim/NavUtils.lua')
local AIBuildStructures = import('/lua/AI/aibuildstructures.lua')

--------------------------------------------------------------------------------
-- helpers & shared state ------------------------------------------------------
--------------------------------------------------------------------------------

local TableGetn = table.getn
local TableInsert = table.insert
local TableSort = table.sort

local DomainToLayer = {
    LAND = 'Land',
    AMPHIBIOUS = 'Amphibious',
    AIR = 'Air',
    SEA = 'Water',
}

local DomainToThreat = {
    LAND = 'StructureAntiSurface',
    AMPHIBIOUS = 'StructureAntiSurface',
    SEA = 'Naval',
    AIR = 'AntiAir',
}

local DefaultOptions = {
    IntelOnly = false,
    Formation = 'GrowthFormation',
    Underwater = false,
    UseTransports = false,
    AvoidDef = false,
}

local RecheckDelay = 10

local function CopyVector(pos)
    if not pos then return nil end
    return { pos[1], pos[2], pos[3] }
end

local function AddVectors(a, b)
    return { (a[1] or 0) + (b[1] or 0), (a[2] or 0) + (b[2] or 0), (a[3] or 0) + (b[3] or 0) }
end

local function SubVectors(a, b)
    return { (a[1] or 0) - (b[1] or 0), (a[2] or 0) - (b[2] or 0), (a[3] or 0) - (b[3] or 0) }
end

local function ScaleVector(vec, scale)
    return { (vec[1] or 0) * scale, (vec[2] or 0) * scale, (vec[3] or 0) * scale }
end

local function VectorLength2D(vec)
    return math.sqrt((vec[1] or 0) * (vec[1] or 0) + (vec[3] or 0) * (vec[3] or 0))
end

local function Distance2D(a, b)
    return VectorLength2D(SubVectors(a, b))
end

local function Distance3D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dy = (a[2] or 0) - (b[2] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function Normalize2D(vec)
    local len = VectorLength2D(vec)
    if len <= 0.001 then
        return {0, 0, 0}
    end
    return { (vec[1] or 0) / len, 0, (vec[3] or 0) / len }
end

local function RandomInRange(minValue, maxValue)
    return minValue + (maxValue - minValue) * math.random()
end

local function MeanPosition(units)
    local count = 0
    local pos = {0, 0, 0}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            local up = unit:GetPosition()
            pos[1] = pos[1] + up[1]
            pos[2] = pos[2] + up[2]
            pos[3] = pos[3] + up[3]
            count = count + 1
        end
    end
    if count == 0 then
        return nil
    end
    pos[1] = pos[1] / count
    pos[2] = pos[2] / count
    pos[3] = pos[3] / count
    return pos
end

local function GetPlatoonUnits(platoon)
    if not platoon or platoon.Dead then return {} end
    local units = platoon:GetPlatoonUnits() or {}
    local result = {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            TableInsert(result, unit)
        end
    end
    return result
end

local function PlatoonAlive(platoon)
    if not platoon or platoon.Dead then return false end
    return TableGetn(GetPlatoonUnits(platoon)) > 0
end

local function GetPlatoonPosition(platoon)
    local units = GetPlatoonUnits(platoon)
    return MeanPosition(units)
end

local function GetMapCenterAndRadius()
    local width, height = GetMapSize()
    local center = { width * 0.5, 0, height * 0.5 }
    local radius = math.sqrt(width * width + height * height) * 0.6
    return center, radius
end

local function ResolveFormation(option)
    if not option or option == '' then
        return DefaultOptions.Formation
    end
    if option == 'AttackFormation' or option == 'GrowthFormation' or option == 'NoFormation' then
        return option
    end
    return DefaultOptions.Formation
end

local function ArmyNameToIndex(name)
    if not name then return nil end
    if type(name) == 'number' then return name end

    if ScenarioInfo and ScenarioInfo.ArmySetup then
        local rec = ScenarioInfo.ArmySetup[name]
        if rec and rec.ArmyIndex then
            return rec.ArmyIndex
        end
    end

    for index, brain in ArmyBrains do
        if brain and (brain.Name == name or brain.Nickname == name) then
            return index
        end
    end
    return nil
end

local function GetEnemyArmyIndexes(brain, requested)
    local myIndex = brain:GetArmyIndex()
    local indexes = {}
    if requested and type(requested) == 'table' then
        for _, token in ipairs(requested) do
            local idx = ArmyNameToIndex(token)
            if idx and idx ~= myIndex and IsEnemy(myIndex, idx) then
                indexes[idx] = true
            end
        end
    end
    if next(indexes) then
        return indexes
    end
    for index, other in ArmyBrains do
        if other and index ~= myIndex and IsEnemy(myIndex, index) then
            indexes[index] = true
        end
    end
    return indexes
end

local function AdjustPositionToSurface(pos)
    if not pos then return nil end
    local y = GetSurfaceHeight(pos[1], pos[3])
    return { pos[1], y, pos[3] }
end

local function AdjustPositionToDomain(domain, pos)
    if not pos then return nil end
    if domain == 'AIR' then
        return { pos[1], pos[2], pos[3] }
    end
    local y = GetTerrainHeight(pos[1], pos[3])
    return { pos[1], y, pos[3] }
end

local function UnitHasCategory(unit, category)
    if not unit or not category then
        return false
    end
    local ok, result = pcall(EntityCategoryContains, category, unit)
    if ok then
        return result
    end
    return false
end

local function UnitIsUnderwater(unit)
    if not unit or unit.Dead then return false end
    if UnitHasCategory(unit, categories.UNDERWATER) then
        return true
    end
    local pos = unit:GetPosition()
    if not pos then return false end
    local surface = GetSurfaceHeight(pos[1], pos[3])
    return pos[2] < surface - 0.2
end

local function UnitMatchesDomain(domain, unit)
    if not unit or unit.Dead then return false end
    if domain == 'AIR' then
        return true
    end
    if domain == 'SEA' then
        return UnitHasCategory(unit, categories.NAVAL) or UnitHasCategory(unit, categories.SUBMERSIBLE)
    end
    -- LAND and AMPHIBIOUS treat as land
    return not UnitHasCategory(unit, categories.NAVAL)
end

local function EnsureNavMesh()
    if not NavUtils or not NavUtils.IsGenerated then
        return
    end
    if not NavUtils:IsGenerated() then
        pcall(NavUtils.Generate)
    end
end

local function BuildNavPath(layer, origin, destination, opts)
    EnsureNavMesh()
    if not NavUtils or not NavUtils.PathTo then
        return { AdjustPositionToSurface(origin), AdjustPositionToSurface(destination) }
    end
    local path
    local ok, result = pcall(NavUtils.PathTo, layer, origin, destination)
    if ok and type(result) == 'table' and TableGetn(result) > 0 then
        path = {}
        for _, point in ipairs(result) do
            TableInsert(path, AdjustPositionToSurface(point))
        end
    end
    if (not path or TableGetn(path) == 0) and opts and opts.AvoidDef and NavUtils.PathToWithThreatThreshold then
        local threatName = DomainToThreat[opts.Domain or 'LAND'] or 'StructureAntiSurface'
        local threatFunc = NavUtils.ThreatFunctions and NavUtils.ThreatFunctions[threatName]
        if threatFunc then
            local brain = opts.Brain
            if brain then
                local okAvoid, avoidPath = pcall(NavUtils.PathToWithThreatThreshold, layer, origin, destination, brain, threatFunc, opts.ThreatThreshold or 15, opts.ThreatRadius or 25)
                if okAvoid and type(avoidPath) == 'table' and TableGetn(avoidPath) > 0 then
                    path = {}
                    for _, point in ipairs(avoidPath) do
                        TableInsert(path, AdjustPositionToSurface(point))
                    end
                end
            end
        end
    end
    if not path or TableGetn(path) == 0 then
        path = { AdjustPositionToSurface(origin), AdjustPositionToSurface(destination) }
    else
        local last = path[TableGetn(path)]
        if Distance2D(last, destination) > 1.5 then
            TableInsert(path, AdjustPositionToSurface(destination))
        end
    end
    return path
end

local function TryUseTransports(platoon, destination, opts)
    if not opts or not opts.UseTransports then
        return false
    end
    if opts.Domain == 'AIR' then
        return false
    end
    local units = GetPlatoonUnits(platoon)
    if TableGetn(units) == 0 then
        return false
    end
    local start = GetPlatoonPosition(platoon)
    if not start then return false end
    local distance = Distance2D(start, destination)
    local needTransports = distance > 200
    if not needTransports and NavUtils and NavUtils.CanPathTo then
        local layer = DomainToLayer[opts.Domain] or 'Land'
        EnsureNavMesh()
        local okPath = pcall(NavUtils.CanPathTo, layer, start, destination)
        if not okPath then
            needTransports = true
        end
    end
    if not needTransports then
        return false
    end
    local brain = platoon:GetBrain()
    local success = false
    local ok, result = pcall(ScenarioFramework.UseTransports, units, brain, destination, true)
    if ok and result then
        success = true
    end
    if success then
        WaitSeconds(1)
    end
    return success
end

local function IssueMoveRoute(platoon, route, formation)
    if not platoon or not route or TableGetn(route) == 0 then return end
    if formation and platoon.SetPlatoonFormationOverride then
        pcall(platoon.SetPlatoonFormationOverride, platoon, formation)
    end
    pcall(platoon.IssueMoveAlongRoute, platoon, route, formation)
end

local function IssueAggressiveRoute(platoon, route, formation)
    if not platoon or not route or TableGetn(route) == 0 then return end
    if formation and platoon.SetPlatoonFormationOverride then
        pcall(platoon.SetPlatoonFormationOverride, platoon, formation)
    end
    pcall(platoon.IssueAggressiveMoveAlongRoute, platoon, route, formation)
end

local function WaitForPlatoon(platoon, destination, radius, timeout)
    local elapsed = 0
    radius = radius or 10
    timeout = timeout or 60
    while PlatoonAlive(platoon) and elapsed < timeout do
        local pos = GetPlatoonPosition(platoon)
        if pos and Distance2D(pos, destination) <= radius then
            return true
        end
        WaitSeconds(1)
        elapsed = elapsed + 1
    end
    return false
end

local function EnsureTemplateCached(aiBrain, entry)
    if not entry then return nil end
    local groupName
    local armyName
    if type(entry) == 'table' then
        groupName = entry.Group or entry.Name or entry[1]
        armyName = entry.Army or entry[2]
    else
        groupName = entry
    end
    if not groupName then
        return nil
    end
    armyName = armyName or aiBrain.Name
    if not aiBrain.BaseTemplates[groupName] then
        pcall(AIBuildStructures.CreateBuildingTemplate, aiBrain, armyName, groupName)
    end
    return aiBrain.BaseTemplates[groupName]
end

local function ResolveTemplateUnits(aiBrain, entry)
    local groupName
    local armyName
    if type(entry) == 'table' then
        groupName = entry.Group or entry.Name or entry[1]
        armyName = entry.Army or entry[2]
    else
        groupName = entry
    end
    if not groupName then
        return {}
    end
    armyName = armyName or aiBrain.Name
    local ok, units = pcall(ScenarioUtils.AssembleArmyGroup, armyName, groupName)
    if not ok or not units then
        return {}
    end
    local result = {}
    for _, data in pairs(units) do
        if data.type and data.Position then
            TableInsert(result, {
                id = data.type,
                position = { data.Position[1], data.Position[2], data.Position[3] },
                orientation = data.Orientation,
            })
        end
    end
    return result
end

local function OrientationToHeading(orientation)
    if not orientation then
        return 0
    end
    if orientation[1] and orientation[2] and orientation[3] then
        -- assume Euler yaw in radians (y component)
        return orientation[2] or 0
    end
    return orientation[1] or 0
end

local function StructureExistsAt(brain, pos, blueprintId)
    local units = brain:GetUnitsAroundPoint(categories.ALLUNITS, pos, 1.5, 'Ally') or {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            local bp = unit:GetBlueprint()
            if bp and bp.BlueprintId == blueprintId then
                return true
            end
        end
    end
    return false
end

local function GetThreatAtPosition(brain, pos, domain, radius)
    radius = radius or 20
    local threatType = DomainToThreat[domain or 'LAND'] or 'StructureAntiSurface'
    local threat = brain:GetThreatAtPosition(pos, radius, true, threatType)
    return threat or 0
end

local function GetPlatoonMaxRange(platoon)
    local units = GetPlatoonUnits(platoon)
    local maxRange = 0
    for _, unit in ipairs(units) do
        local bp = unit:GetBlueprint()
        if bp and bp.Weapon then
            for _, weapon in ipairs(bp.Weapon) do
                if weapon.MaxRadius and weapon.MaxRadius > maxRange then
                    maxRange = weapon.MaxRadius
                end
            end
        end
    end
    return maxRange
end

local function FilterTargetsByCategory(list, category)
    local result = {}
    for _, unit in ipairs(list) do
        if unit and not unit.Dead and UnitHasCategory(unit, category) then
            TableInsert(result, unit)
        end
    end
    return result
end

local function FilterTargetsExcludeCategory(list, category)
    local result = {}
    for _, unit in ipairs(list) do
        if unit and not unit.Dead and not UnitHasCategory(unit, category) then
            TableInsert(result, unit)
        end
    end
    return result
end

local function SortByDistanceTo(units, reference)
    TableSort(units, function(a, b)
        local pa = a:GetPosition()
        local pb = b:GetPosition()
        return Distance2D(pa, reference) < Distance2D(pb, reference)
    end)
end

local function SelectCluster(structures, radius)
    if TableGetn(structures) == 0 then
        return nil
    end
    local best = nil
    local bestCount = 0
    local radiusSq = radius * radius
    for _, unit in ipairs(structures) do
        local pos = unit:GetPosition()
        local clusterUnits = {}
        local cx, cz = 0, 0
        local count = 0
        for _, other in ipairs(structures) do
            local opos = other:GetPosition()
            local dx = pos[1] - opos[1]
            local dz = pos[3] - opos[3]
            if dx * dx + dz * dz <= radiusSq then
                TableInsert(clusterUnits, other)
                cx = cx + opos[1]
                cz = cz + opos[3]
                count = count + 1
            end
        end
        if count > 0 then
            cx = cx / count
            cz = cz / count
            if count > bestCount then
                bestCount = count
                best = {
                    units = clusterUnits,
                    position = { cx, GetSurfaceHeight(cx, cz), cz },
                }
            end
        end
    end
    return best
end

local function UnitIsKnownToBrain(unit, brainIndex)
    if not unit or unit.Dead then return false end
    if unit.GetBlip then
        local blip = unit:GetBlip(brainIndex)
        if blip then
            if blip.IsMaybeDead and blip:IsMaybeDead(brainIndex) then
                return false
            end
            return true
        end
    end
    -- If we cannot check blip, assume visible
    return true
end

local function GatherEnemyUnits(brain, category, opts)
    local result = {}
    opts = opts or {}
    local brainIndex = brain:GetArmyIndex()
    local domain = opts.Domain or 'LAND'
    local allowUnderwater = opts.Underwater or false
    local enemyIndexes = GetEnemyArmyIndexes(brain, opts.TargetArmy)

    if opts.IntelOnly then
        local center, radius = GetMapCenterAndRadius()
        local known = brain:GetUnitsAroundPoint(category, center, radius, 'Enemy') or {}
        for _, unit in ipairs(known) do
            if unit and not unit.Dead and UnitMatchesDomain(domain, unit) then
                if allowUnderwater or not UnitIsUnderwater(unit) then
                    if enemyIndexes[unit:GetArmy()] then
                        TableInsert(result, unit)
                    end
                end
            end
        end
    else
        for enemyIndex, _ in pairs(enemyIndexes) do
            local enemyBrain = ArmyBrains[enemyIndex]
            if enemyBrain then
                local units = enemyBrain:GetListOfUnits(category, false, true) or {}
                for _, unit in ipairs(units) do
                    if unit and not unit.Dead and UnitMatchesDomain(domain, unit) then
                        if allowUnderwater or not UnitIsUnderwater(unit) then
                            if UnitIsKnownToBrain(unit, brainIndex) or not opts.IntelOnly then
                                TableInsert(result, unit)
                            end
                        end
                    end
                end
            end
        end
    end
    return result
end

local function ResolvePlatoonData(platoon, data)
    if type(data) == 'table' then
        platoon.PlatoonData = data
        return data
    end
    if type(platoon.PlatoonData) == 'table' then
        return platoon.PlatoonData
    end
    local fallback = {}
    platoon.PlatoonData = fallback
    return fallback
end

local function ResolveOptions(platoon, data)
    local opts = {}
    data = ResolvePlatoonData(platoon, data)
    for key, value in pairs(DefaultOptions) do
        if data[key] ~= nil then
            opts[key] = data[key]
        else
            opts[key] = value
        end
    end
    opts.Domain = data.Domain or data.domain or nil
    if opts.Domain then
        opts.Domain = string.upper(opts.Domain)
    end
    opts.TargetArmy = data.TargetArmy or data.targetArmy
    opts.Brain = platoon:GetBrain()
    opts.ThreatThreshold = data.ThreatThreshold
    opts.ThreatRadius = data.ThreatRadius
    if not opts.Domain then
        -- domain required; attempt to infer but warn through log
        opts.Domain = 'LAND'
        WARN('[platoon_AttackFunctions] Domain not provided, defaulting to LAND')
    end
    opts.Formation = ResolveFormation(data.Formation or data.formation)
    opts.IntelOnly = (data.IntelOnly ~= nil) and data.IntelOnly or DefaultOptions.IntelOnly
    opts.Underwater = (data.Underwater ~= nil) and data.Underwater or DefaultOptions.Underwater
    opts.UseTransports = (data.UseTransports ~= nil) and data.UseTransports or DefaultOptions.UseTransports
    opts.AvoidDef = (data.AvoidDef ~= nil) and data.AvoidDef or DefaultOptions.AvoidDef
    return opts, data
end

--------------------------------------------------------------------------------
-- target selection -----------------------------------------------------------
--------------------------------------------------------------------------------

local function SelectWaveTarget(platoon, opts, targetType)
    targetType = targetType or 'closest'
    local brain = opts.Brain
    local category = categories.STRUCTURE - categories.WALL
    local structures = GatherEnemyUnits(brain, category, opts)
    if TableGetn(structures) == 0 then
        return nil
    end
    if targetType == 'concentration' then
        local cluster = SelectCluster(structures, 40)
        if not cluster then
            return nil
        end
        return {
            position = cluster.position,
            units = cluster.units,
            label = 'wave_cluster',
        }
    end
    local platoonPos = GetPlatoonPosition(platoon) or {0,0,0}
    local closest = nil
    local bestDistance = math.huge
    for _, unit in ipairs(structures) do
        local pos = unit:GetPosition()
        local dist = Distance2D(platoonPos, pos)
        if dist < bestDistance then
            bestDistance = dist
            closest = unit
        end
    end
    if not closest then return nil end
    return {
        position = AdjustPositionToSurface(closest:GetPosition()),
        units = { closest },
        label = 'wave_closest',
    }
end

local RaidCategories = {
    ECO = categories.STRUCTURE * (categories.MASSEXTRACTION + categories.MASSFABRICATION + categories.ENERGYPRODUCTION + categories.MASSSTORAGE + categories.ENERGYSTORAGE),
    FAB = categories.STRUCTURE * (categories.FACTORY + categories.ANTIMISSILE),
    ENG = (categories.ENGINEER + categories.ENGINEERSTATION),
    DEF = categories.STRUCTURE * (categories.RADAR + categories.ARTILLERY + categories.NUKE + categories.TACTICALMISSILEPLATFORM + categories.SHIELD),
}

local function CollectRaidCandidates(brain, opts, raidType)
    local category = RaidCategories[raidType]
    if not category then
        return {}
    end
    return GatherEnemyUnits(brain, category, opts)
end

local function EvaluateRaidTarget(platoon, opts, unit)
    local brain = opts.Brain
    local pos = unit:GetPosition()
    local threat = GetThreatAtPosition(brain, pos, opts.Domain, 24)
    local platoonPos = GetPlatoonPosition(platoon)
    local distance = platoonPos and Distance2D(platoonPos, pos) or 0
    return threat, distance
end

local RaidPriorityOrder = { 'ECO', 'FAB', 'ENG', 'DEF' }

local function SelectRaidTarget(platoon, opts, raidType)
    raidType = raidType or 'ECO'
    local brain = opts.Brain
    local order = { raidType }
    for _, entry in ipairs(RaidPriorityOrder) do
        if entry ~= raidType then
            TableInsert(order, entry)
        end
    end
    local bestUnit
    local bestThreat = math.huge
    local bestDistance = math.huge

    for _, entry in ipairs(order) do
        local candidates
        if entry == 'SMT' then
            candidates = {}
            for _, name in ipairs(RaidPriorityOrder) do
                local subCandidates = CollectRaidCandidates(brain, opts, name)
                for _, unit in ipairs(subCandidates) do
                    TableInsert(candidates, unit)
                end
            end
        else
            candidates = CollectRaidCandidates(brain, opts, entry)
        end
        for _, unit in ipairs(candidates) do
            local threat, distance = EvaluateRaidTarget(platoon, opts, unit)
            if threat < bestThreat or (math.abs(threat - bestThreat) < 0.1 and distance < bestDistance) then
                bestThreat = threat
                bestDistance = distance
                bestUnit = unit
            end
        end
        if bestUnit then
            break
        end
    end
    if not bestUnit then
        return nil
    end
    return {
        unit = bestUnit,
        position = AdjustPositionToSurface(bestUnit:GetPosition()),
        threat = bestThreat,
    }
end

local BombardPriority = {
    categories.STRUCTURE * (categories.SHIELD + categories.RADAR + categories.OMNI + categories.SONAR),
    categories.STRUCTURE * (categories.ARTILLERY + categories.TACTICALMISSILEPLATFORM),
    categories.STRUCTURE * categories.DEFENSE * (categories.DIRECTFIRE + categories.ANTIAIR + categories.ANTINAVY),
    categories.STRUCTURE - categories.WALL,
}

local function SelectBombardTargets(platoon, opts, targetType)
    local baseTarget = SelectWaveTarget(platoon, opts, targetType)
    if not baseTarget then
        return nil
    end
    local allUnits = baseTarget.units
    if not allUnits or TableGetn(allUnits) == 0 then
        -- fall back to scanning area around position
        local brain = opts.Brain
        local around = brain:GetUnitsAroundPoint(categories.STRUCTURE, baseTarget.position, 45, 'Enemy') or {}
        allUnits = {}
        for _, unit in ipairs(around) do
            if unit and not unit.Dead and UnitMatchesDomain(opts.Domain, unit) then
                TableInsert(allUnits, unit)
            end
        end
    end
    local prioritized = {}
    for _, category in ipairs(BombardPriority) do
        local list = FilterTargetsByCategory(allUnits, category)
        if TableGetn(list) > 0 then
            TableInsert(prioritized, list)
        end
    end
    if TableGetn(prioritized) == 0 then
        TableInsert(prioritized, allUnits)
    end
    return {
        position = baseTarget.position,
        groups = prioritized,
    }
end

local SiegeCategory = categories.STRUCTURE * categories.DEFENSE

local function SelectSiegeTarget(platoon, opts, targetType)
    local brain = opts.Brain
    local structures = GatherEnemyUnits(brain, SiegeCategory, opts)
    if TableGetn(structures) == 0 then
        return nil
    end
    if targetType == 'concentration' then
        local cluster = SelectCluster(structures, 45)
        if not cluster then
            return nil
        end
        return { position = cluster.position, units = cluster.units }
    end
    local platoonPos = GetPlatoonPosition(platoon) or structures[1]:GetPosition()
    SortByDistanceTo(structures, platoonPos)
    local unit = structures[1]
    return {
        position = AdjustPositionToSurface(unit:GetPosition()),
        units = { unit },
    }
end

local function SelectMobileTargets(platoon, opts)
    local category
    if opts.Domain == 'AIR' then
        category = categories.MOBILE * categories.AIR
    elseif opts.Domain == 'SEA' then
        category = categories.MOBILE * categories.NAVAL
    else
        category = categories.MOBILE * categories.LAND
    end
    return GatherEnemyUnits(opts.Brain, category, opts)
end

--------------------------------------------------------------------------------
-- behaviour implementations ---------------------------------------------------
--------------------------------------------------------------------------------

local function ExecuteWave(platoon, opts, target)
    if not target or not target.position then
        return false
    end
    local formation = opts.Formation
    local startPos = GetPlatoonPosition(platoon) or target.position
    local navLayer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
    local route = BuildNavPath(navLayer, startPos, target.position, opts)
    if not TryUseTransports(platoon, target.position, opts) then
        IssueMoveRoute(platoon, route, formation)
        WaitForPlatoon(platoon, target.position, 15, 90)
    end
    if not PlatoonAlive(platoon) then
        return false
    end
    local attackRoute = {}
    if target.units then
        for _, unit in ipairs(target.units or {}) do
            if unit and not unit.Dead then
                TableInsert(attackRoute, AdjustPositionToSurface(unit:GetPosition()))
            end
        end
    end
    if TableGetn(attackRoute) == 0 then
        TableInsert(attackRoute, target.position)
    end
    IssueAggressiveRoute(platoon, attackRoute, formation)
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteRaid(platoon, opts, raid)
    if not raid or not raid.unit or raid.unit.Dead then
        return false
    end
    local unit = raid.unit
    local dest = AdjustPositionToSurface(unit:GetPosition())
    local formation = opts.Formation
    local startPos = GetPlatoonPosition(platoon) or dest
    local navLayer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
    local route = BuildNavPath(navLayer, startPos, dest, opts)
    IssueMoveRoute(platoon, route, formation)
    WaitForPlatoon(platoon, dest, 20, 90)
    if not PlatoonAlive(platoon) then
        return false
    end
    local units = GetPlatoonUnits(platoon)
    for _, member in ipairs(units) do
        if member and not member.Dead then
            IssueClearCommands({ member })
            IssueAttack({ member }, unit)
        end
    end
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteBombard(platoon, opts, bombard)
    if not bombard or not bombard.groups then
        return false
    end
    local formation = opts.Formation
    local maxRange = math.max(GetPlatoonMaxRange(platoon), 30)
    for _, group in ipairs(bombard.groups) do
        for _, targetUnit in ipairs(group) do
            if not PlatoonAlive(platoon) then
                return false
            end
            if targetUnit and not targetUnit.Dead then
                local targetPos = AdjustPositionToSurface(targetUnit:GetPosition())
                local platoonPos = GetPlatoonPosition(platoon) or targetPos
                local distance = Distance2D(platoonPos, targetPos)
                if distance > maxRange * 0.85 then
                    local direction = Normalize2D(SubVectors(platoonPos, targetPos))
                    local approach = AddVectors(targetPos, ScaleVector(direction, maxRange * 0.8))
                    local navLayer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
                    local route = BuildNavPath(navLayer, platoonPos, approach, opts)
                    IssueMoveRoute(platoon, route, formation)
                    WaitForPlatoon(platoon, approach, 10, 60)
                end
                if not PlatoonAlive(platoon) then
                    return false
                end
                local members = GetPlatoonUnits(platoon)
                for _, member in ipairs(members) do
                    if member and not member.Dead then
                        IssueClearCommands({ member })
                        IssueAttack({ member }, targetUnit)
                    end
                end
                WaitSeconds(RecheckDelay)
            end
        end
    end
    return true
end

local function ExecuteSiege(platoon, opts, siege)
    if not siege or not siege.position then
        return false
    end
    local formation = opts.Formation
    local startPos = GetPlatoonPosition(platoon) or siege.position
    local navLayer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
    local route = BuildNavPath(navLayer, startPos, siege.position, opts)
    IssueMoveRoute(platoon, route, formation)
    WaitForPlatoon(platoon, siege.position, 20, 90)
    if not PlatoonAlive(platoon) then
        return false
    end
    local attackRoute = {}
    for _, unit in ipairs(siege.units or {}) do
        if unit and not unit.Dead then
            TableInsert(attackRoute, AdjustPositionToSurface(unit:GetPosition()))
        end
    end
    if TableGetn(attackRoute) == 0 then
        TableInsert(attackRoute, siege.position)
    end
    IssueAggressiveRoute(platoon, attackRoute, formation)
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteCull(platoon, opts)
    local brain = opts.Brain
    local units = SelectMobileTargets(platoon, opts)
    local candidates = {}
    for _, unit in ipairs(units) do
        local threat = GetThreatAtPosition(brain, unit:GetPosition(), opts.Domain, 20)
        if threat < 15 then
            TableInsert(candidates, unit)
        end
    end
    local formation = opts.Formation
    if TableGetn(candidates) > 0 then
        local target = candidates[math.random(1, TableGetn(candidates))]
        local dest = AdjustPositionToSurface(target:GetPosition())
        local startPos = GetPlatoonPosition(platoon) or dest
        local layer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
        local route = BuildNavPath(layer, startPos, dest, opts)
        IssueAggressiveRoute(platoon, route, formation)
    else
        local center, radius = GetMapCenterAndRadius()
        local angle = math.random() * math.pi * 2
        local distance = RandomInRange(radius * 0.3, radius * 0.6)
        local dest = { center[1] + math.cos(angle) * distance, 0, center[3] + math.sin(angle) * distance }
        dest = AdjustPositionToDomain(opts.Domain, dest)
        local startPos = GetPlatoonPosition(platoon) or dest
        local layer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
        local route = BuildNavPath(layer, startPos, dest, opts)
        IssueMoveRoute(platoon, route, formation)
    end
    WaitSeconds(RecheckDelay)
    return true
end

local function ResolveMarkerPosition(entry)
    if not entry then return nil end
    if type(entry) == 'string' then
        return ScenarioUtils.MarkerToPosition(entry)
    end
    if type(entry) == 'table' then
        if entry[1] and entry[3] then
            return { entry[1], entry[2] or GetSurfaceHeight(entry[1], entry[3]), entry[3] }
        end
        if entry.Position then
            return ResolveMarkerPosition(entry.Position)
        end
    end
    return nil
end

local function ExecuteHunt(platoon, opts, params)
    local targets = params.Targets or {}
    if TableGetn(targets) == 0 then
        return false
    end
    local waitPos = params.WaitPosition
    if waitPos then
        local layer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
        local startPos = GetPlatoonPosition(platoon) or waitPos
        local route = BuildNavPath(layer, startPos, waitPos, opts)
        IssueMoveRoute(platoon, route, opts.Formation)
        WaitForPlatoon(platoon, waitPos, 10, 60)
    end
    local brain = opts.Brain
    local targetList = {}
    for _, id in ipairs(targets) do
        targetList[string.lower(id)] = true
    end
    local units = SelectMobileTargets(platoon, opts)
    local best
    local bestThreat = math.huge
    for _, unit in ipairs(units) do
        local bp = unit:GetBlueprint()
        local id = bp and bp.BlueprintId and string.lower(bp.BlueprintId)
        if id and targetList[id] then
            local threat = 0
            if params.WaitForSafeZone then
                threat = GetThreatAtPosition(brain, unit:GetPosition(), opts.Domain, 18)
            end
            if threat <= 10 and threat < bestThreat then
                bestThreat = threat
                best = unit
            end
        end
    end
    if not best then
        if waitPos then
            local layer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
            local route = BuildNavPath(layer, GetPlatoonPosition(platoon) or waitPos, waitPos, opts)
            IssueMoveRoute(platoon, route, opts.Formation)
        end
        WaitSeconds(RecheckDelay)
        return true
    end
    local dest = AdjustPositionToSurface(best:GetPosition())
    local layer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
    local route = BuildNavPath(layer, GetPlatoonPosition(platoon) or dest, dest, opts)
    IssueAggressiveRoute(platoon, route, opts.Formation)
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteScout(platoon, opts)
    local units = GetPlatoonUnits(platoon)
    if TableGetn(units) == 0 then
        return false
    end
    local half = math.floor(TableGetn(units) / 2)
    local knownTargets = GatherEnemyUnits(opts.Brain, categories.ALLUNITS - categories.WALL, opts)
    local formation = opts.Formation
    for index, unit in ipairs(units) do
        if unit and not unit.Dead then
            local pos
            if index <= half and TableGetn(knownTargets) > 0 then
                local ref = knownTargets[math.mod((index - 1), TableGetn(knownTargets)) + 1]
                local refPos = ref:GetPosition()
                local angle = math.random() * math.pi * 2
                pos = {
                    refPos[1] + math.cos(angle) * 25,
                    0,
                    refPos[3] + math.sin(angle) * 25,
                }
            else
                local center, radius = GetMapCenterAndRadius()
                local angle = math.random() * math.pi * 2
                local distance = RandomInRange(radius * 0.2, radius * 0.9)
                pos = {
                    center[1] + math.cos(angle) * distance,
                    0,
                    center[3] + math.sin(angle) * distance,
                }
            end
            pos = AdjustPositionToDomain(opts.Domain, pos)
            IssueClearCommands({ unit })
            IssueMove({ unit }, pos)
        end
    end
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteFirebase(platoon, opts, params)
    local locations = params.Locations
    local templates = params.Templates
    if TableGetn(locations) == 0 or TableGetn(locations) ~= TableGetn(templates) then
        WARN('[platoon_AttackFunctions] Firebase requires matching location/template tables.')
        return false
    end
    local aiBrain = opts.Brain
    local formation = opts.Formation
    local units = GetPlatoonUnits(platoon)
    if TableGetn(units) == 0 then
        return false
    end
    local index = params.NextIndex or 1
    if index > TableGetn(locations) then
        index = 1
    end
    local location = locations[index]
    local templateEntry = templates[index]
    local targetPos = AdjustPositionToSurface(location)
    params.NextIndex = index + 1
    local startPos = GetPlatoonPosition(platoon) or targetPos
    local navLayer = DomainToLayer[opts.Domain or 'LAND'] or 'Land'
    local route = BuildNavPath(navLayer, startPos, targetPos, opts)
    IssueMoveRoute(platoon, route, formation)
    WaitForPlatoon(platoon, targetPos, 15, 120)
    if not PlatoonAlive(platoon) then
        return false
    end
    local cachedTemplate = EnsureTemplateCached(aiBrain, templateEntry)
    local templateUnits = ResolveTemplateUnits(aiBrain, templateEntry)
    if TableGetn(templateUnits) == 0 then
        WaitSeconds(RecheckDelay)
        return true
    end
    local average = {0, 0, 0}
    for _, data in ipairs(templateUnits) do
        average[1] = average[1] + data.position[1]
        average[2] = average[2] + data.position[2]
        average[3] = average[3] + data.position[3]
    end
    average[1] = average[1] / TableGetn(templateUnits)
    average[2] = average[2] / TableGetn(templateUnits)
    average[3] = average[3] / TableGetn(templateUnits)

    local engineers = GetPlatoonUnits(platoon)
    for _, engineer in ipairs(engineers) do
        if engineer and not engineer.Dead then
            IssueClearCommands({ engineer })
        end
    end

    local function ensureStructure(data)
        local offset = SubVectors(data.position, average)
        local buildPos = AddVectors(targetPos, { offset[1], 0, offset[3] })
        buildPos = { buildPos[1], GetTerrainHeight(buildPos[1], buildPos[3]), buildPos[3] }
        if not StructureExistsAt(aiBrain, buildPos, data.id) then
            local heading = OrientationToHeading(data.orientation)
            IssueBuildMobile(engineers, buildPos, data.id, { heading })
        end
    end

    for _, data in ipairs(templateUnits) do
        ensureStructure(data)
    end

    local elapsed = 0
    while elapsed < 120 do
        local allBuilt = true
        for _, data in ipairs(templateUnits) do
            local offset = SubVectors(data.position, average)
            local buildPos = AddVectors(targetPos, { offset[1], 0, offset[3] })
            buildPos = { buildPos[1], GetTerrainHeight(buildPos[1], buildPos[3]), buildPos[3] }
            if not StructureExistsAt(aiBrain, buildPos, data.id) then
                allBuilt = false
                break
            end
        end
        if allBuilt then
            break
        end
        WaitSeconds(5)
        elapsed = elapsed + 5
        if not PlatoonAlive(platoon) then
            return false
        end
    end
    WaitSeconds(RecheckDelay)
    return true
end

--------------------------------------------------------------------------------
-- exposed attack routines -----------------------------------------------------
--------------------------------------------------------------------------------

function WaveAttack(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local target = SelectWaveTarget(platoon, opts, config.TargetType or config.targetType)
        if not target then
            break
        end
        ExecuteWave(platoon, opts, target)
    end
    platoon:PlatoonDisband()
end

function RaidAttack(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local raid = SelectRaidTarget(platoon, opts, config.TargetType or config.targetType)
        if not raid then
            break
        end
        ExecuteRaid(platoon, opts, raid)
    end
    platoon:PlatoonDisband()
end

function Scout(platoon, data)
    local opts = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        ExecuteScout(platoon, opts)
    end
    platoon:PlatoonDisband()
end

function Bombard(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local bombard = SelectBombardTargets(platoon, opts, config.TargetType or config.targetType)
        if not bombard then
            break
        end
        ExecuteBombard(platoon, opts, bombard)
    end
    platoon:PlatoonDisband()
end

function Siege(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local siege = SelectSiegeTarget(platoon, opts, config.TargetType or config.targetType)
        if not siege then
            break
        end
        ExecuteSiege(platoon, opts, siege)
    end
    platoon:PlatoonDisband()
end

function Cull(platoon, data)
    local opts = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        ExecuteCull(platoon, opts)
    end
    platoon:PlatoonDisband()
end

function Hunt(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    local huntParams = {
        Targets = config.TargetList or config.targetList or {},
        WaitForSafeZone = config.Wait or config.wait or false,
        WaitPosition = ResolveMarkerPosition(config.Marker or config.Location or config.WaitLocation or config.waitLocation),
    }
    while PlatoonAlive(platoon) do
        ExecuteHunt(platoon, opts, huntParams)
    end
    platoon:PlatoonDisband()
end

function Firebase(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    local locationEntries = config.Location or config.Locations or {}
    local templateEntries = config.Template or config.Templates or {}
    local locations = {}
    for _, entry in ipairs(locationEntries) do
        local pos = ResolveMarkerPosition(entry)
        if pos then
            TableInsert(locations, pos)
        end
    end
    local templates = {}
    for _, entry in ipairs(templateEntries) do
        TableInsert(templates, entry)
    end
    local params = {
        Locations = locations,
        Templates = templates,
        NextIndex = 1,
    }
    while PlatoonAlive(platoon) do
        if TableGetn(locations) == 0 or TableGetn(templates) == 0 then
            break
        end
        ExecuteFirebase(platoon, opts, params)
    end
    platoon:PlatoonDisband()
end

--------------------------------------------------------------------------------
-- module export ---------------------------------------------------------------
--------------------------------------------------------------------------------

local M = {
    WaveAttack = WaveAttack,
    RaidAttack = RaidAttack,
    Scout = Scout,
    Bombard = Bombard,
    Siege = Siege,
    Cull = Cull,
    Hunt = Hunt,
    Firebase = Firebase,
}

return M