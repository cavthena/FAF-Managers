--[[
================================================================================
Platoon Attack Behaviours (FAF safe, Lua 5.0)
================================================================================

Import this module from your manager script (for example
manager_UnitBuilder.lua or manager_UnitSpawner.lua) and fork the desired
behaviour on the platoon once it has been handed off:

    local Attacks = import('/maps/<map-name>/platoon_AttackFunctions.lua')
    local options = {
        Domain = 'LAND',
        TargetArmy = {'Player1', 'Player2'},
        Formation = 'AttackFormation',
    }
    platoon:ForkAIThread(Attacks.WaveAttack, options)

Each public entry point accepts the platoon and an optional configuration table.
All functions share the following global options:

    TargetArmy (table<string|number>)
        A whitelist of army nicknames/indices that may be targeted.  When nil the
        platoon looks for any hostile army.

    IntelOnly (boolean, default = false)
        When true the platoon only considers units/areas that are currently known
        through intelligence (vision, radar or sonar).  When false it may select
        any hostile unit regardless of intel coverage.

    Formation (string, default = 'GrowthFormation')
        Formation used for non-aggressive movement: 'AttackFormation',
        'GrowthFormation' or 'NoFormation'.

    Domain (string, required)
        Movement layer and primary target domain.  Accepted values: 'LAND',
        'AMPHIBIOUS', 'AIR', 'SEA'.  Amphibious units route over both land and
        water but evaluate land targets.  Air platoons may engage both land and
        sea units/structures.

    Underwater (boolean, default = false)
        When true the platoon will consider underwater targets (if its weapons
        allow).  When false submerged units are ignored.

    UseTransports (boolean, default = false)
        Allows the platoon to request transports for long distance moves or
        unreachable areas.  A transport will be requested for trips over 200
        units or if the navmesh reports no valid path.  Units unload safely
        before continuing on their domain routing.

    AvoidDef (boolean, default = false)
        Attempts to avoid static defenses that threaten the platoon.  Paths are
        evaluated against domain-appropriate threat fields; when no safe path is
        found the direct path is used instead.

Attack specific options
-----------------------

WaveAttack
    TargetType = 'concentration' | 'closest'
        Focuses on either the densest cluster of structures or the closest
        hostile structure respectively.

RaidAttack
    TargetType = 'ECO' | 'FAB' | 'ENG' | 'DEF' | 'SMT'
        Selects priority categories for hit-and-run raids.  When no targets are
        available in the chosen category the search falls back in this order:
        selected > ECO > FAB > ENG > DEF.  'SMT' chooses the least defended
        target overall.

Scout
    No extra parameters.  Half the platoon scouts near known contacts while the
    remainder explores random points on the map.

Bombard
    TargetType = 'concentration' | 'closest'
        Long range bombardment prioritising shields/intel, then artillery/TML,
        then point defences, finally remaining structures.

Siege
    TargetType = 'concentration' | 'closest'
        Focused destruction of static defences.  Platoon advances aggressively as
        threats are removed.

Cull
    No extra parameters.  Patrols near known enemy activity and hunts enemy
    platoons, only engaging when they stray from defensive cover.

Hunt
    TargetList (table of unit blueprints) -- required
    Wait (boolean, default = false)
        If Wait is true the platoon ignores targets protected by defences.  When
        false it engages immediately upon detection.  The platoon returns to the
        initial marker location whenever no targets are detected.

Firebase
    Location (array)
    Template (array)
        Matching arrays of marker names/positions and structure templates.  The
        platoon must consist entirely of engineers.  Engineers travel to each
        marker in order, construct the template, and loop indefinitely,
        rebuilding missing structures as required.

All behaviours run as independent threads (ForkAIThread) and remain active
until the platoon is destroyed, idling when no valid targets are present.
================================================================================
]]

local ScenarioUtils      = import('/lua/sim/ScenarioUtilities.lua')
local ScenarioFramework  = import('/lua/ScenarioFramework.lua')
local NavUtils           = import('/lua/sim/NavUtils.lua')

--------------------------------------------------------------------------------
-- small helpers ----------------------------------------------------------------
--------------------------------------------------------------------------------

local TableGetn          = table.getn
local TableInsert        = table.insert
local TableSort          = table.sort
local Random             = math.random
local Floor              = math.floor
local Min                = math.min
local Max                = math.max
local Abs                = math.abs
local PI                 = math.pi

local RecheckDelay       = 10
local TransportDistance  = 200
local ClusterRadius      = 32
local ThreatSampleRadius = 24
local FirebaseTimeout    = 120

local DomainLayer = {
    LAND        = 'Land',
    AMPHIBIOUS  = 'Amphibious',
    AIR         = 'Air',
    SEA         = 'Water',
}

local DomainThreatType = {
    LAND        = 'AntiSurface',
    AMPHIBIOUS  = 'AntiSurface',
    SEA         = 'AntiSurface',
    AIR         = 'AntiAir',
}

local DomainTargetCategory = {
    LAND        = categories.LAND - categories.AIR - categories.NAVAL,
    AMPHIBIOUS  = categories.LAND - categories.AIR,
    SEA         = categories.NAVAL,
    AIR         = categories.AIR,
}

local StructureCategory = categories.STRUCTURE - categories.WALL
local MobileCategory    = categories.MOBILE - categories.ENGINEER - categories.SCOUT - categories.WALL

local RaidCategoryPriorities = {
    ECO = categories.MASSEXTRACTION + categories.MASSPRODUCTION + categories.ENERGYPRODUCTION + categories.MASSSTORAGE + categories.ENERGYSTORAGE,
    FAB = categories.FACTORY + categories.ANTIMISSILE * categories.STRUCTURE,
    ENG = categories.ENGINEER + categories.STRUCTURE * categories.ENGINEERSTATION,
    DEF = categories.DEFENSE + categories.SHIELD + categories.RADAR + categories.SONAR,
}

local BombardPriority = {
    categories.STRUCTURE * (categories.SHIELD + categories.RADAR + categories.SONAR),
    categories.STRUCTURE * (categories.ARTILLERY + categories.TACTICALMISSILEPLATFORM),
    categories.STRUCTURE * (categories.DEFENSE - categories.SHIELD),
    StructureCategory,
}

local SiegeCategory = categories.STRUCTURE * (categories.DEFENSE + categories.SHIELD)

local DomainAliases = {
    NAVY        = 'SEA',
    NAVAL       = 'SEA',
    WATER       = 'SEA',
    LANDPATH    = 'LAND',
}

local DefaultOptions = {
    IntelOnly      = false,
    Formation      = 'GrowthFormation',
    Underwater     = false,
    UseTransports  = false,
    AvoidDef       = false,
}

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

local function CopyVector(vec)
    if not vec then return nil end
    return {vec[1], vec[2], vec[3]}
end

local function AddVector(a, b)
    return { (a[1] or 0) + (b[1] or 0), (a[2] or 0) + (b[2] or 0), (a[3] or 0) + (b[3] or 0) }
end

local function SubVector(a, b)
    return { (a[1] or 0) - (b[1] or 0), (a[2] or 0) - (b[2] or 0), (a[3] or 0) - (b[3] or 0) }
end

local function VectorLength2D(v)
    local x = v[1] or 0
    local z = v[3] or 0
    return math.sqrt(x * x + z * z)
end

local function Distance2D(a, b)
    return VectorLength2D(SubVector(a, b))
end

local function SurfaceHeight(x, z)
    local terrain = GetTerrainHeight(x, z)
    local surface = GetSurfaceHeight(x, z)
    if terrain > surface then
        return terrain
    end
    return surface
end

local function AdjustToSurface(position)
    if not position then
        return nil
    end
    local x = position[1]
    local z = position[3]
    local y = position[2] or SurfaceHeight(x, z)
    return { x, y, z }
end

local function AdjustToDomain(domain, position)
    if not position then
        return nil
    end
    local x = position[1]
    local z = position[3]
    if domain == 'SEA' then
        return { x, GetSurfaceHeight(x, z), z }
    end
    if domain == 'AIR' then
        return { x, position[2] or SurfaceHeight(x, z) + 20, z }
    end
    -- land / amphibious
    return { x, GetTerrainHeight(x, z), z }
end

local function MapCenterAndRadius()
    local size = ScenarioInfo and ScenarioInfo.size or {512, 512}
    local width = size[1] or 512
    local height = size[2] or 512
    local center = { width * 0.5, 0, height * 0.5 }
    local radius = math.sqrt((width * 0.5) ^ 2 + (height * 0.5) ^ 2)
    return center, radius
end

local function RandomDomainPoint(domain)
    local center, radius = MapCenterAndRadius()
    local angle = Random() * 2 * PI
    local distance = Random() * radius
    local pos = { center[1] + math.cos(angle) * distance, 0, center[3] + math.sin(angle) * distance }
    return AdjustToDomain(domain, pos)
end

local function NormalizeDomain(domain)
    if not domain then return nil end
    local upper = string.upper(domain)
    return DomainAliases[upper] or upper
end

local function GetArmyIndex(brainOrIndex)
    if type(brainOrIndex) == 'number' then
        return brainOrIndex
    end
    if brainOrIndex and brainOrIndex.GetArmyIndex then
        return brainOrIndex:GetArmyIndex()
    end
    return nil
end

local function ArmiesEqual(a, b)
    if a == b then return true end
    local ai, bi = GetArmyIndex(a), GetArmyIndex(b)
    return ai and bi and ai == bi
end

local function PlatoonAlive(platoon)
    return platoon and not platoon.Dead and platoon:GetBrain() and platoon:GetBrain():PlatoonExists(platoon)
end

local function GetPlatoonUnits(platoon)
    if not platoon or platoon.Dead then return {} end
    local units = platoon:GetPlatoonUnits() or {}
    local alive = {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            TableInsert(alive, unit)
        end
    end
    return alive
end

local function GetPlatoonPosition(platoon)
    if not platoon or platoon.Dead then return nil end
    return platoon:GetPlatoonPosition()
end

local function GetArmyBrainsFromList(list)
    local brains = {}
    for _, entry in ipairs(list or {}) do
        local idx
        if type(entry) == 'number' then
            idx = entry
        elseif type(entry) == 'string' then
            local wanted = string.lower(entry)
            for _, brain in ipairs(ArmyBrains or {}) do
                local name = (brain.Nickname or brain.Name or brain:GetArmyIndex())
                if type(name) == 'string' then
                    if string.lower(name) == wanted then
                        idx = brain:GetArmyIndex()
                        break
                    end
                elseif type(name) == 'number' and tostring(name) == wanted then
                    idx = brain:GetArmyIndex()
                    break
                end
            end
            if not idx and ScenarioInfo and ScenarioInfo.ArmySetup then
                for armyName, info in pairs(ScenarioInfo.ArmySetup) do
                    if string.lower(armyName) == wanted then
                        idx = info.ArmyIndex or info.armyIndex
                        break
                    end
                end
            end
        end
        if idx and ArmyBrains[idx] then
            TableInsert(brains, ArmyBrains[idx])
        end
    end
    return brains
end

local function DetermineTargetBrains(brain, options)
    local brains
    if options.TargetArmy and TableGetn(options.TargetArmy) > 0 then
        brains = GetArmyBrainsFromList(options.TargetArmy)
    end
    if not brains or TableGetn(brains) == 0 then
        brains = {}
        local ourIndex = brain:GetArmyIndex()
        for _, otherBrain in ipairs(ArmyBrains or {}) do
            if otherBrain and not ArmiesEqual(otherBrain, brain) and IsEnemy(ourIndex, otherBrain:GetArmyIndex()) then
                TableInsert(brains, otherBrain)
            end
        end
    end
    return brains
end

local function IntelVisible(brain, unit, options)
    if not unit or unit.Dead then
        return false
    end
    if not options or not options.IntelOnly then
        return true
    end
    if not brain then
        return false
    end
    local armyIndex = brain:GetArmyIndex()
    local ok, visible = pcall(IsUnitVisible, armyIndex, unit)
    if ok and visible then
        return true
    end
    if unit.IsOnRadar and unit:IsOnRadar(armyIndex) then
        return true
    end
    if unit.IsOnSonar and unit:IsOnSonar(armyIndex) then
        return true
    end
    return false
end

local function UnitMatchesDomain(unit, domain, options)
    if not unit or unit.Dead then
        return false
    end
    if domain == 'AIR' then
        return EntityCategoryContains(categories.AIR, unit)
    elseif domain == 'SEA' then
        if EntityCategoryContains(categories.NAVAL, unit) then
            return true
        end
        if options.Underwater and EntityCategoryContains(categories.SUBMERSIBLE, unit) then
            return true
        end
        return false
    else
        -- treat amphibious as land for targets
        if EntityCategoryContains(categories.NAVAL, unit) then
            return false
        end
        if not options.Underwater and EntityCategoryContains(categories.SUBMERSIBLE, unit) then
            return false
        end
        if domain == 'AMPHIBIOUS' then
            return true
        end
        return not EntityCategoryContains(categories.AIR, unit)
    end
end

local function FilterUnitsByIntel(units, brain, options, domainCategory)
    local filtered = {}
    for _, unit in ipairs(units or {}) do
        if unit and not unit.Dead then
            if not domainCategory or EntityCategoryContains(domainCategory, unit) or EntityCategoryContains(StructureCategory, unit) then
                if UnitMatchesDomain(unit, options.Domain, options) then
                    if IntelVisible(brain, unit, options) then
                        TableInsert(filtered, unit)
                    end
                end
            end
        end
    end
    return filtered
end

local function GatherEnemyUnits(brain, category, options)
    local targets = {}
    local domainCategory = DomainTargetCategory[options.Domain] or category
    for _, enemyBrain in ipairs(options.TargetBrains or {}) do
        local ok, units = pcall(enemyBrain.GetListOfUnits, enemyBrain, category or categories.ALLUNITS, false)
        if ok and units then
            for _, unit in ipairs(units) do
                if unit and not unit.Dead then
                    if UnitMatchesDomain(unit, options.Domain, options) or EntityCategoryContains(StructureCategory, unit) then
                        if IntelVisible(brain, unit, options) then
                            TableInsert(targets, unit)
                        end
                    end
                end
            end
        end
    end
    return targets
end

local function SortUnitsByDistance(units, reference)
    if not reference then
        return units
    end
    TableSort(units, function(a, b)
        local ap = a:GetPosition()
        local bp = b:GetPosition()
        return Distance2D(ap, reference) < Distance2D(bp, reference)
    end)
    return units
end

local function EnsureNavMesh(layer)
    if not NavUtils then
        return
    end
    if NavUtils.IsGenerated and not NavUtils.IsGenerated() then
        pcall(function()
            NavUtils.Generate()
        end)
    end
end

local function BuildPath(layer, start, goal, options)
    if not goal then
        return nil
    end
    if not layer then
        layer = DomainLayer[options.Domain or 'LAND'] or 'Land'
    end
    if not start then
        return {goal}
    end
    EnsureNavMesh(layer)
    local path
    if NavUtils and NavUtils.PathTo then
        local ok, result = pcall(NavUtils.PathTo, layer, start, goal)
        if ok then
            path = result
        end
        if options.AvoidDef and NavUtils.PathToWithThreatThreshold then
            local threatName = DomainThreatType[options.Domain]
            local threatFunc = NavUtils.ThreatFunctions and NavUtils.ThreatFunctions[threatName]
            if threatFunc then
                local okAvoid, safe = pcall(NavUtils.PathToWithThreatThreshold, layer, start, goal, options.Brain, threatFunc, options.ThreatThreshold or 15, options.ThreatRadius or 30)
                if okAvoid and safe and TableGetn(safe) > 0 then
                    path = safe
                end
            end
        end
    end
    path = path or {}
    local count = TableGetn(path)
    if count == 0 or Distance2D(path[count], goal) > 3 then
        path[count + 1] = goal
    end
    return path
end

local function IssuePath(platoon, path, formation, aggressiveFinal)
    local units = GetPlatoonUnits(platoon)
    if TableGetn(units) == 0 then
        return false
    end
    IssueClearCommands(units)
    --platoon:SetPlatoonFormation(formation or 'GrowthFormation')
    local size = TableGetn(path or {})
    if size == 0 then
        return false
    end
    for i = 1, size - 1 do
        local waypoint = path[i]
        if waypoint then
            IssueFormMove(units, waypoint, formation or 'GrowthFormation', 0)
        end
    end
    local last = path[size]
    if aggressiveFinal then
        platoon:AggressiveMoveToLocation(last)
    else
        IssueFormMove(units, last, formation or 'GrowthFormation', 0)
    end
    return true
end

local function WaitForPlatoon(platoon, destination, radius, timeout)
    radius = radius or 15
    timeout = timeout or 120
    local elapsed = 0
    while elapsed < timeout do
        if not PlatoonAlive(platoon) then
            return false
        end
        local pos = GetPlatoonPosition(platoon)
        if pos and Distance2D(pos, destination) <= radius then
            return true
        end
        WaitSeconds(1)
        elapsed = elapsed + 1
    end
    return false
end

local function ShouldUseTransport(platoon, options, destination)
    if not options.UseTransports or not destination then
        return false
    end
    local start = GetPlatoonPosition(platoon)
    if not start then
        return true
    end
    if Distance2D(start, destination) > TransportDistance then
        return true
    end
    if NavUtils and NavUtils.CanPathTo then
        local layer = DomainLayer[options.Domain or 'LAND'] or 'Land'
        local ok, canPath = pcall(NavUtils.CanPathTo, layer, start, destination)
        if ok and not canPath then
            return true
        end
    end
    return false
end

local function UseTransports(platoon, destination, options)
    if not ScenarioFramework then
        return false
    end
    local success = false
    if ScenarioFramework.PlatoonMoveWithTransports then
        success = pcall(function()
            ScenarioFramework.PlatoonMoveWithTransports(platoon, destination, false)
        end)
        if not success and options.Brain then
            success = pcall(function()
                ScenarioFramework.PlatoonMoveWithTransports(options.Brain, platoon, destination, false)
            end)
        end
    end
    if not success and ScenarioFramework.PlatoonAttackWithTransports then
        success = pcall(function()
            ScenarioFramework.PlatoonAttackWithTransports(platoon, destination, false)
        end)
        if not success and options.Brain then
            success = pcall(function()
                ScenarioFramework.PlatoonAttackWithTransports(options.Brain, platoon, destination, false)
            end)
        end
    end
    if not success then
        WARN('[platoon_AttackFunctions] Transport move request failed; falling back to ground pathing.')
    end
    return success
end

local function MovePlatoon(platoon, destination, options, aggressiveFinal)
    if not PlatoonAlive(platoon) then
        return false
    end
    destination = CopyVector(destination)
    if not destination then
        return false
    end
    if ShouldUseTransport(platoon, options, destination) then
        if UseTransports(platoon, destination, options) then
            WaitForPlatoon(platoon, destination, 20, 240)
            return true
        end
    end
    local start = GetPlatoonPosition(platoon)
    local path = BuildPath(DomainLayer[options.Domain or 'LAND'] or 'Land', start, destination, options)
    if not path then
        return false
    end
    IssuePath(platoon, path, options.Formation, aggressiveFinal)
    WaitForPlatoon(platoon, destination, aggressiveFinal and 25 or 15, 180)
    return true
end

local function CalculatePlatoonStrength(platoon, threatType)
    local threat = 0
    if platoon and platoon.CalculatePlatoonThreat then
        local ok, value = pcall(platoon.CalculatePlatoonThreat, platoon, threatType or 'Overall', categories.ALLUNITS)
        if ok and value then
            threat = value
        end
    end
    return threat
end

local function ThreatAt(brain, position, threatType)
    if not brain or not position then
        return 0
    end
    local ok, threat = pcall(brain.GetThreatAtPosition, brain, position, ThreatSampleRadius, true, threatType or 'Overall')
    if ok and threat then
        return threat
    end
    return 0
end

local function TargetDefenseWeight(brain, unit, options)
    if not unit or unit.Dead then
        return math.huge
    end
    local position = unit:GetPosition()
    local threatType = DomainThreatType[options.Domain] or 'Overall'
    return ThreatAt(brain, position, threatType)
end

local function SelectClosestStructure(platoon, options, structures)
    if TableGetn(structures) == 0 then
        return nil
    end
    local pos = GetPlatoonPosition(platoon)
    if not pos then
        pos = structures[1]:GetPosition()
    end
    SortUnitsByDistance(structures, pos)
    local unit = structures[1]
    return { Unit = unit, Position = CopyVector(unit:GetPosition()) }
end

local function SelectStructureCluster(platoon, options, structures)
    if TableGetn(structures) == 0 then
        return nil
    end
    local bestScore = -1
    local bestCenter = nil
    for _, structure in ipairs(structures) do
        local pos = structure:GetPosition()
        local count = 0
        local sum = {0, 0, 0}
        for _, other in ipairs(structures) do
            local otherPos = other:GetPosition()
            if Distance2D(pos, otherPos) <= ClusterRadius then
                count = count + 1
                sum[1] = sum[1] + otherPos[1]
                sum[2] = sum[2] + otherPos[2]
                sum[3] = sum[3] + otherPos[3]
            end
        end
        if count > bestScore then
            bestScore = count
            bestCenter = {sum[1] / count, sum[2] / count, sum[3] / count}
        end
    end
    if not bestCenter then
        return nil
    end
    return { Position = bestCenter }
end

local function SortByDefense(units, brain, options)
    TableSort(units, function(a, b)
        return TargetDefenseWeight(brain, a, options) < TargetDefenseWeight(brain, b, options)
    end)
end

local function ResolveOptions(platoon, data)
    local opts = {}
    for key, default in pairs(DefaultOptions) do
        local lower = string.lower(key)
        local value = data and (data[key] ~= nil and data[key] or data[lower])
        if value == nil then
            value = default
        end
        opts[key] = value
    end
    opts.Domain = NormalizeDomain((data and (data.Domain or data.domain)) or opts.Domain)
    if not opts.Domain then
        opts.Domain = 'LAND'
        WARN('[platoon_AttackFunctions] Domain missing; defaulting to LAND.')
    end
    opts.Formation = (data and (data.Formation or data.formation)) or opts.Formation
    opts.TargetArmy = (data and (data.TargetArmy or data.targetArmy)) or opts.TargetArmy
    opts.Brain = platoon and platoon:GetBrain()
    opts.TargetBrains = DetermineTargetBrains(opts.Brain, opts)
    return opts, data or {}
end

--------------------------------------------------------------------------------
-- target selection ------------------------------------------------------------
--------------------------------------------------------------------------------

local function SelectWaveTarget(platoon, options, targetType)
    local structures = GatherEnemyUnits(options.Brain, StructureCategory, options)
    if TableGetn(structures) == 0 then
        return nil
    end
    targetType = string.lower(targetType or 'concentration')
    if targetType == 'closest' then
        return SelectClosestStructure(platoon, options, structures)
    end
    local cluster = SelectStructureCluster(platoon, options, structures)
    if cluster then
        cluster.Units = structures
        return cluster
    end
    return SelectClosestStructure(platoon, options, structures)
end

local function BuildRaidPriorityList(targetType)
    local ordered = {}
    local seen = {}
    local function push(key)
        key = string.upper(key)
        if not seen[key] then
            seen[key] = true
            TableInsert(ordered, key)
        end
    end
    if targetType and string.upper(targetType) ~= 'SMT' then
        push(targetType)
    end
    push('ECO')
    push('FAB')
    push('ENG')
    push('DEF')
    return ordered
end

local function SelectRaidTarget(platoon, options, targetType)
    local desired = string.upper(targetType or 'ECO')
    if desired ~= 'SMT' and not RaidCategoryPriorities[desired] then
        desired = 'ECO'
    end
    local units
    if desired == 'SMT' then
        units = GatherEnemyUnits(options.Brain, StructureCategory, options)
        if TableGetn(units) == 0 then
            return nil
        end
        SortByDefense(units, options.Brain, options)
        local unit = units[1]
        return { Unit = unit, Position = AdjustToSurface(unit:GetPosition()) }
    end
    for _, key in ipairs(BuildRaidPriorityList(desired)) do
        local category = RaidCategoryPriorities[key]
        units = GatherEnemyUnits(options.Brain, category, options)
        if TableGetn(units) > 0 then
            SortByDefense(units, options.Brain, options)
            local target = units[1]
            return { Unit = target, Position = AdjustToSurface(target:GetPosition()) }
        end
    end
    return nil
end

local function SelectBombardTarget(platoon, options, targetType)
    targetType = string.lower(targetType or 'concentration')
    for _, category in ipairs(BombardPriority) do
        local units = GatherEnemyUnits(options.Brain, category, options)
        if TableGetn(units) > 0 then
            if targetType == 'closest' then
                return SelectClosestStructure(platoon, options, units)
            else
                local cluster = SelectStructureCluster(platoon, options, units)
                if cluster then
                    cluster.Units = units
                    return cluster
                end
            end
        end
    end
    return nil
end

local function SelectSiegeTarget(platoon, options, targetType)
    local defenses = GatherEnemyUnits(options.Brain, SiegeCategory, options)
    if TableGetn(defenses) == 0 then
        return nil
    end
    targetType = string.lower(targetType or 'closest')
    if targetType == 'closest' then
        return SelectClosestStructure(platoon, options, defenses)
    end
    local cluster = SelectStructureCluster(platoon, options, defenses)
    if cluster then
        cluster.Units = defenses
        return cluster
    end
    return SelectClosestStructure(platoon, options, defenses)
end

local function SelectMobileTargets(platoon, options)
    local category
    if options.Domain == 'AIR' then
        category = categories.MOBILE * categories.AIR
    elseif options.Domain == 'SEA' then
        category = categories.MOBILE * categories.NAVAL
    else
        category = categories.MOBILE * categories.LAND
    end
    return GatherEnemyUnits(options.Brain, category, options)
end

--------------------------------------------------------------------------------
-- behaviour implementations ---------------------------------------------------
--------------------------------------------------------------------------------

local function ExecuteWave(platoon, options, target)
    if not target or not target.Position then
        return false
    end
    local dest = AdjustToDomain(options.Domain, target.Position)
    if not MovePlatoon(platoon, dest, options, false) then
        return false
    end
    if not PlatoonAlive(platoon) then
        return false
    end
    platoon:AggressiveMoveToLocation(dest)
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteRaid(platoon, options, raid)
    if not raid or not raid.Unit or raid.Unit.Dead then
        return false
    end
    local dest = AdjustToDomain(options.Domain, raid.Position or raid.Unit:GetPosition())
    if not MovePlatoon(platoon, dest, options, false) then
        return false
    end
    if not PlatoonAlive(platoon) then
        return false
    end
    local members = GetPlatoonUnits(platoon)
    for _, unit in ipairs(members) do
        if unit and not unit.Dead then
            IssueClearCommands({ unit })
            IssueAttack({ unit }, raid.Unit)
        end
    end
    WaitSeconds(RecheckDelay)
    return true
end

local function GetPlatoonMaxRange(platoon)
    if not platoon or platoon.Dead then
        return 30
    end
    if platoon.GetPlatoonMaxRange then
        local ok, value = pcall(platoon.GetPlatoonMaxRange, platoon)
        if ok and value and value > 0 then
            return value
        end
    end
    return 30
end

local function ExecuteBombard(platoon, options, bombard)
    if not bombard or not bombard.Position then
        return false
    end
    local dest = AdjustToDomain(options.Domain, bombard.Position)
    if not MovePlatoon(platoon, dest, options, false) then
        return false
    end
    if not PlatoonAlive(platoon) then
        return false
    end
    local range = Max(GetPlatoonMaxRange(platoon) - 5, 25)
    local members = GetPlatoonUnits(platoon)
    for _, attacker in ipairs(members) do
        if attacker and not attacker.Dead then
            IssueClearCommands({ attacker })
        end
    end
    local targets = bombard.Units or {}
    if TableGetn(targets) == 0 and bombard.Unit then
        targets = { bombard.Unit }
    end
    for _, unit in ipairs(targets) do
        if not PlatoonAlive(platoon) then
            return false
        end
        if unit and not unit.Dead then
            local pos = AdjustToSurface(unit:GetPosition())
            for _, attacker in ipairs(members) do
                if attacker and not attacker.Dead then
                    IssueAttack({ attacker }, unit)
                end
            end
            WaitSeconds(2)
            local ourPos = GetPlatoonPosition(platoon)
            if ourPos and Distance2D(ourPos, pos) > range then
                MovePlatoon(platoon, pos, options, false)
            end
        end
    end
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteSiege(platoon, options, siege)
    if not siege or not siege.Position then
        return false
    end
    local dest = AdjustToDomain(options.Domain, siege.Position)
    if not MovePlatoon(platoon, dest, options, true) then
        return false
    end
    if not PlatoonAlive(platoon) then
        return false
    end
    local units = siege.Units or {}
    if TableGetn(units) > 0 then
        local members = GetPlatoonUnits(platoon)
        for _, unit in ipairs(units) do
            if unit and not unit.Dead then
                local pos = AdjustToSurface(unit:GetPosition())
                platoon:AggressiveMoveToLocation(pos)
            end
        end
    end
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteScout(platoon, options)
    local members = GetPlatoonUnits(platoon)
    if TableGetn(members) == 0 then
        return false
    end
    local known = GatherEnemyUnits(options.Brain, categories.ALLUNITS - categories.WALL, options)
    local half = Floor(TableGetn(members) * 0.5)
    for idx, unit in ipairs(members) do
        if unit and not unit.Dead then
            local destination
            if idx <= half and TableGetn(known) > 0 then
                local reference = known[(math.mod((idx - 1), TableGetn(known))) + 1]
                local refPos = reference:GetPosition()
                local angle = Random() * 2 * PI
                destination = { refPos[1] + math.cos(angle) * 25, 0, refPos[3] + math.sin(angle) * 25 }
            else
                destination = RandomDomainPoint(options.Domain)
            end
            destination = AdjustToDomain(options.Domain, destination)
            IssueClearCommands({ unit })
            IssueMove({ unit }, destination)
        end
    end
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteCull(platoon, options)
    local brain = options.Brain
    local mobiles = SelectMobileTargets(platoon, options)
    if TableGetn(mobiles) == 0 then
        MovePlatoon(platoon, RandomDomainPoint(options.Domain), options, false)
        WaitSeconds(RecheckDelay)
        return true
    end
    SortByDefense(mobiles, brain, options)
    local target = mobiles[1]
    if not target or target.Dead then
        WaitSeconds(RecheckDelay)
        return true
    end
    local threat = TargetDefenseWeight(brain, target, options)
    local strength = CalculatePlatoonStrength(platoon, DomainThreatType[options.Domain])
    if threat > strength * 0.75 then
        -- wait nearby for safer opportunity
        local patrol = target:GetPosition()
        local offset = { patrol[1] + Random() * 20 - 10, 0, patrol[3] + Random() * 20 - 10 }
        MovePlatoon(platoon, AdjustToDomain(options.Domain, offset), options, false)
        WaitSeconds(RecheckDelay)
        return true
    end
    MovePlatoon(platoon, AdjustToDomain(options.Domain, target:GetPosition()), options, true)
    WaitSeconds(RecheckDelay)
    return true
end

local function ExecuteHunt(platoon, options, params)
    local targets = params.Targets or {}
    if TableGetn(targets) == 0 then
        return false
    end
    local waitPos = params.WaitPosition
    if waitPos then
        MovePlatoon(platoon, AdjustToDomain(options.Domain, waitPos), options, false)
    end
    local desired = {}
    for _, id in ipairs(targets) do
        desired[string.lower(id)] = true
    end
    local mobiles = SelectMobileTargets(platoon, options)
    local best
    local bestThreat = math.huge
    for _, unit in ipairs(mobiles) do
        local bp = unit:GetBlueprint()
        local id = bp and bp.BlueprintId and string.lower(bp.BlueprintId)
        if id and desired[id] then
            local threat = 0
            if params.WaitForSafeZone then
                threat = TargetDefenseWeight(options.Brain, unit, options)
            end
            if threat < bestThreat then
                bestThreat = threat
                best = unit
            end
        end
    end
    if not best then
        if waitPos then
            MovePlatoon(platoon, AdjustToDomain(options.Domain, waitPos), options, false)
        end
        WaitSeconds(RecheckDelay)
        return true
    end
    MovePlatoon(platoon, AdjustToDomain(options.Domain, best:GetPosition()), options, true)
    WaitSeconds(RecheckDelay)
    return true
end

local function ResolveMarkerPosition(entry)
    if not entry then
        return nil
    end
    if type(entry) == 'string' then
        local pos = ScenarioUtils.MarkerToPosition(entry)
        if pos then
            return pos
        end
        local chain = ScenarioUtils.ChainToPositions(entry)
        if chain and chain[1] then
            return chain[1]
        end
    elseif type(entry) == 'table' then
        if entry.Position then
            return ResolveMarkerPosition(entry.Position)
        end
        if entry[1] and entry[3] then
            return { entry[1], entry[2] or SurfaceHeight(entry[1], entry[3]), entry[3] }
        end
    end
    return nil
end

local function ParseTemplate(template)
    if type(template) ~= 'table' then
        return nil
    end
    if template.TemplateData then
        return template.TemplateData
    end
    if template[1] and type(template[1]) == 'string' and template[2] and type(template[2]) == 'string' then
        local data
        if ScenarioUtils.GetTemplate then
            local ok, result = pcall(ScenarioUtils.GetTemplate, template[2])
            if ok and result then
                data = result
            end
        end
        if not data and ScenarioUtils.GetTemplateNamed then
            local ok, result = pcall(ScenarioUtils.GetTemplateNamed, template[2])
            if ok and result then
                data = result
            end
        end
        if data then
            return data
        end
    end
    return template
end

local function StructureExistsAt(brain, position, blueprintId)
    local around = brain:GetUnitsAroundPoint(categories.STRUCTURE, position, 2, 'Ally') or {}
    for _, unit in ipairs(around) do
        if not unit.Dead then
            local bp = unit:GetBlueprint()
            if bp and bp.BlueprintId == blueprintId then
                return true
            end
        end
    end
    return false
end

local function IssueTemplateBuild(platoon, options, template, origin)
    local engineers = GetPlatoonUnits(platoon)
    if TableGetn(engineers) == 0 then
        return false
    end
    local structures = ParseTemplate(template)
    if not structures then
        return false
    end
    local center = {0, 0, 0}
    local count = 0
    for _, data in ipairs(structures) do
        local pos = data.position or data[2]
        if pos then
            center[1] = center[1] + pos[1]
            center[2] = center[2] + (pos[2] or 0)
            center[3] = center[3] + pos[3]
            count = count + 1
        end
    end
    if count == 0 then
        return false
    end
    center[1] = center[1] / count
    center[2] = center[2] / count
    center[3] = center[3] / count
    local brain = options.Brain
    for _, engineer in ipairs(engineers) do
        if engineer and not engineer.Dead then
            IssueClearCommands({ engineer })
        end
    end
    for _, data in ipairs(structures) do
        local bp = data.id or data[1]
        local pos = data.position or data[2]
        local orient = data.orientation or data[3] or 0
        if bp and pos then
            local offset = SubVector(pos, center)
            local buildPos = { origin[1] + offset[1], 0, origin[3] + offset[3] }
            buildPos = AdjustToSurface(buildPos)
            if not StructureExistsAt(brain, buildPos, bp) then
                IssueBuildMobile(engineers, buildPos, bp, { orient })
            end
        end
    end
    local elapsed = 0
    while elapsed < FirebaseTimeout do
        local complete = true
        for _, data in ipairs(structures) do
            local bp = data.id or data[1]
            local pos = data.position or data[2]
            if bp and pos then
                local offset = SubVector(pos, center)
                local checkPos = AdjustToSurface({ origin[1] + offset[1], 0, origin[3] + offset[3] })
                if not StructureExistsAt(brain, checkPos, bp) then
                    complete = false
                    break
                end
            end
        end
        if complete then
            break
        end
        WaitSeconds(5)
        elapsed = elapsed + 5
        if not PlatoonAlive(platoon) then
            return false
        end
    end
    return true
end

local function ExecuteFirebase(platoon, options, params)
    local locations = params.Locations or {}
    local templates = params.Templates or {}
    if TableGetn(locations) == 0 or TableGetn(locations) ~= TableGetn(templates) then
        WARN('[platoon_AttackFunctions] Firebase requires matching Location/Template tables.')
        return false
    end
    local index = params.NextIndex or 1
    if index > TableGetn(locations) then
        index = 1
    end
    params.NextIndex = index + 1
    local origin = AdjustToSurface(locations[index])
    if not origin then
        return false
    end
    if not MovePlatoon(platoon, AdjustToDomain(options.Domain, origin), options, false) then
        return false
    end
    if not PlatoonAlive(platoon) then
        return false
    end
    IssueTemplateBuild(platoon, options, templates[index], origin)
    WaitSeconds(RecheckDelay)
    return true
end

--------------------------------------------------------------------------------
-- public interface ------------------------------------------------------------
--------------------------------------------------------------------------------

function WaveAttack(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local target = SelectWaveTarget(platoon, opts, config.TargetType or config.targetType)
        if target then
            if not ExecuteWave(platoon, opts, target) then
                WaitSeconds(RecheckDelay)
            end
        else
            WaitSeconds(RecheckDelay)
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

function RaidAttack(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local target = SelectRaidTarget(platoon, opts, config.TargetType or config.targetType)
        if target then
            if not ExecuteRaid(platoon, opts, target) then
                WaitSeconds(RecheckDelay)
            end
        else
            WaitSeconds(RecheckDelay)
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

function Scout(platoon, data)
    local opts = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        if not ExecuteScout(platoon, opts) then
            break
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

function Bombard(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local target = SelectBombardTarget(platoon, opts, config.TargetType or config.targetType)
        if target then
            if not ExecuteBombard(platoon, opts, target) then
                WaitSeconds(RecheckDelay)
            end
        else
            WaitSeconds(RecheckDelay)
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

function Siege(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        local target = SelectSiegeTarget(platoon, opts, config.TargetType or config.targetType)
        if target then
            if not ExecuteSiege(platoon, opts, target) then
                WaitSeconds(RecheckDelay)
            end
        else
            WaitSeconds(RecheckDelay)
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

function Cull(platoon, data)
    local opts = ResolveOptions(platoon, data)
    while PlatoonAlive(platoon) do
        if not ExecuteCull(platoon, opts) then
            break
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

function Hunt(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    local params = {
        Targets = config.TargetList or config.targetList or {},
        WaitForSafeZone = config.Wait or config.wait or false,
        WaitPosition = ResolveMarkerPosition(config.Marker or config.Location or config.WaitLocation or config.waitLocation),
    }
    while PlatoonAlive(platoon) do
        if not ExecuteHunt(platoon, opts, params) then
            break
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

function Firebase(platoon, data)
    local opts, config = ResolveOptions(platoon, data)
    local locations = {}
    for _, entry in ipairs(config.Location or config.Locations or {}) do
        local pos = ResolveMarkerPosition(entry) or entry
        if pos then
            TableInsert(locations, AdjustToSurface(pos))
        end
    end
    local templates = {}
    for _, entry in ipairs(config.Template or config.Templates or {}) do
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
        if not ExecuteFirebase(platoon, opts, params) then
            break
        end
    end
    if PlatoonAlive(platoon) then
        platoon:PlatoonDisband()
    end
end

return {
    WaveAttack = WaveAttack,
    RaidAttack = RaidAttack,
    Scout = Scout,
    Bombard = Bombard,
    Siege = Siege,
    Cull = Cull,
    Hunt = Hunt,
    Firebase = Firebase,
}