--[[
================================================================================
Platoon Attack Functions (FAF safe, Lua 5.0)
================================================================================

This module contains lightweight attack behaviours designed for the FAF Manager
suite.  The functions are written to be safe for the vanilla FA Lua 5.0 runtime
and can be used directly from manager_UnitBuilder.lua and
manager_UnitSpawner.lua.

Usage overview
--------------
    local Attacks = import('/maps/<map>/platoon_AttackFunctions.lua')

    -- Wave attack example ----------------------------------------------------
    local platoonData = {
        TargetType = 'concentration',
        TargetArmy = {'Player1', 'Player2'},
        Formation = 'AttackFormation',
        UseTransports = true,
        AvoidDef = true,
    }
    platoon:ForkAIThread(Attacks.WaveAttack, platoonData)

    -- Raid attack example ----------------------------------------------------
    local raidData = {
        TargetType = 'ECO',
        TargetArmy = {'Player2'},
        Underwater = false,
    }
    platoon:ForkAIThread(Attacks.RaidAttack, raidData)

Global options
--------------
Every function accepts a configuration table (`platoon.PlatoonData`) that may
contain the following keys.  All options are optional unless stated otherwise.

    TargetArmy (table)
        List of army names/indices that may be targeted.  When omitted every
        enemy army is considered a valid target.

    Formation (string, default = 'GrowthFormation')
        Movement formation used for regular move orders.  Allowed values are
        'AttackFormation', 'GrowthFormation', and 'NoFormation'.

    Underwater (boolean, default = false)
        When true the platoon will consider underwater targets.  When false,
        underwater structures and units are ignored.

    UseTransports (boolean, default = false)
        When true the platoon will request transports for moves longer than
        200 units or when no direct path is available.

    AvoidDef (boolean, default = false)
        When true the platoon will attempt to steer around static defences that
        are dangerous to its movement layer.  When no safer path exists the
        direct path is used.

Attack behaviours
-----------------
WaveAttack
    Standard wave style push.  Routes the platoon to structure targets and
    clears the surrounding area before moving to the next target.  Set
    `TargetType` to either 'concentration' (largest cluster of structures) or
    'closest' (nearest structure).

RaidAttack
    Hit-and-run style behaviour.  Targets lightly defended structures in the
    requested category.  Supported `TargetType` values: 'ECO', 'FAB', 'ENG',
    'DEF', and 'SMT'.  'SMT' selects the least defended valid target regardless
    of category.  When no target is available in the requested category the
    search falls back in priority order: requested > ECO > FAB > ENG > DEF.

All behaviours are intended to be forked as platoon AI threads and will exit
when the platoon is destroyed.  Targets are re-evaluated every 10 seconds and
orders are refreshed whenever the target changes.
================================================================================
]]

local ScenarioFramework = import('/lua/ScenarioFramework.lua')
local NavUtils           = import('/lua/sim/NavUtils.lua')

local table_getn = table.getn
local table_insert = table.insert
local table_remove = table.remove
local math_huge = math.huge

local RecheckDelay = 10
local TransportDistance = 200
local ClusterRadius = 40
local ClearRadius = 30
local ThreatSampleRadius = 30

local StructureCategory = categories.STRUCTURE - categories.WALL
local UnderwaterCategory = categories.SUBMERSIBLE + (categories.NAVAL * categories.STRUCTURE)

local RaidCategories = {
    ECO = categories.MASSEXTRACTION + categories.MASSPRODUCTION + categories.ENERGYPRODUCTION +
          categories.MASSSTORAGE + categories.ENERGYSTORAGE,
    FAB = categories.FACTORY + (categories.ANTIMISSILE * categories.STRUCTURE),
    ENG = categories.ENGINEER + (categories.STRUCTURE * categories.ENGINEERSTATION),
    DEF = categories.DEFENSE + categories.SHIELD + categories.RADAR + categories.SONAR,
}

local LayerThreatTypes = {
    Land = 'AntiSurface',
    Water = 'AntiSurface',
    Amphibious = 'AntiSurface',
    Air = 'AntiAir',
}

local LayerFormationDefault = {
    Land = 'GrowthFormation',
    Water = 'GrowthFormation',
    Amphibious = 'GrowthFormation',
    Air = 'AttackFormation',
}

local function SafeWaitSeconds(seconds)
    if seconds and seconds > 0 then
        WaitSeconds(seconds)
    else
        WaitTicks(1)
    end
end

local function PlatoonAlive(platoon)
    if not platoon then
        return false
    end
    local brain = platoon:GetBrain()
    if not brain then
        return false
    end
    if not brain:PlatoonExists(platoon) then
        return false
    end
    local units = platoon:GetPlatoonUnits()
    return units and table_getn(units) > 0
end

local function CopyVector(vec)
    if not vec then
        return nil
    end
    return { vec[1], vec[2], vec[3] }
end

local function DetermineLayer(platoon)
    if not platoon then
        return 'Land'
    end
    if platoon.MovementLayer then
        return platoon.MovementLayer
    end
    local units = platoon:GetPlatoonUnits() or {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            if EntityCategoryContains(categories.AIR, unit) then
                return 'Air'
            elseif EntityCategoryContains(categories.NAVAL, unit) then
                return 'Water'
            elseif EntityCategoryContains(categories.AMPHIBIOUS, unit) then
                return 'Amphibious'
            end
        end
    end
    return 'Land'
end

local function IsUnitUnderwater(unit)
    if not unit or unit.Dead then
        return false
    end
    if EntityCategoryContains(UnderwaterCategory, unit) then
        return true
    end
    local pos = unit:GetPosition()
    if not pos then
        return false
    end
    local surface = GetSurfaceHeight(pos[1], pos[3])
    return pos[2] < surface - 0.2
end

local function GetArmyBrainByName(name)
    if type(name) == 'number' then
        return ArmyBrains[name]
    end
    if type(name) ~= 'string' then
        return nil
    end
    if ScenarioInfo and ScenarioInfo.ArmySetup then
        local setup = ScenarioInfo.ArmySetup[name]
        if setup and setup.ArmyIndex then
            return ArmyBrains[setup.ArmyIndex]
        end
        for key, info in pairs(ScenarioInfo.ArmySetup) do
            if key == name or info.ArmyName == name or info.HumanPlayerName == name then
                if info.ArmyIndex then
                    return ArmyBrains[info.ArmyIndex]
                end
            end
        end
    end
    for idx, brain in pairs(ArmyBrains or {}) do
        if brain and brain.Nickname == name then
            return brain
        end
        if brain and brain.GetArmyName and brain:GetArmyName() == name then
            return brain
        end
    end
    return nil
end

local function ResolveTargetBrains(brain, opts)
    local targets = {}
    local myIndex = brain:GetArmyIndex()
    if opts.TargetArmy then
        for _, entry in ipairs(opts.TargetArmy) do
            local targetBrain = entry
            if type(targetBrain) ~= 'table' or not targetBrain.GetArmyIndex then
                targetBrain = GetArmyBrainByName(entry)
            end
            if targetBrain and not targetBrain:IsDefeated() then
                local idx = targetBrain:GetArmyIndex()
                if idx and IsEnemy(myIndex, idx) then
                    table_insert(targets, targetBrain)
                end
            end
        end
    else
        for idx, targetBrain in pairs(ArmyBrains or {}) do
            if targetBrain and targetBrain ~= brain and not targetBrain:IsDefeated() then
                local enemyIdx = targetBrain:GetArmyIndex()
                if enemyIdx and IsEnemy(myIndex, enemyIdx) then
                    table_insert(targets, targetBrain)
                end
            end
        end
    end
    return targets
end

local function CollectUnitsFromBrains(brains, category, opts)
    local units = {}
    for _, enemyBrain in ipairs(brains) do
        local list = enemyBrain:GetListOfUnits(category, false, false) or {}
        for _, unit in ipairs(list) do
            if unit and not unit.Dead then
                if opts.Underwater or not IsUnitUnderwater(unit) then
                    table_insert(units, unit)
                end
            end
        end
    end
    return units
end

local function GetPlatoonPosition(platoon)
    local pos = nil
    if platoon and platoon.GetPlatoonPosition then
        local ok, result = pcall(platoon.GetPlatoonPosition, platoon)
        if ok then
            pos = result
        end
    end
    if not pos then
        local units = platoon:GetPlatoonUnits() or {}
        for _, unit in ipairs(units) do
            if unit and not unit.Dead then
                pos = unit:GetPosition()
                break
            end
        end
    end
    return pos
end

local function EnsureNavMesh(layer)
    if not NavUtils or not NavUtils.IsGenerated then
        return
    end
    local ok, generated = pcall(NavUtils.IsGenerated)
    if ok and not generated and NavUtils.Generate then
        pcall(NavUtils.Generate)
    end
end

local function BuildPath(layer, start, goal, opts)
    if not goal then
        return nil
    end
    if not start then
        return { CopyVector(goal) }
    end
    EnsureNavMesh(layer)
    local path = nil
    if opts.AvoidDef and NavUtils and NavUtils.PathToWithThreatThreshold then
        local threatType = LayerThreatTypes[layer] or 'Overall'
        local threatFunc = NavUtils.ThreatFunctions and NavUtils.ThreatFunctions[threatType]
        if threatFunc then
            local ok, safePath = pcall(NavUtils.PathToWithThreatThreshold, layer, start, goal, opts.Brain, threatFunc, opts.ThreatThreshold or 16, ThreatSampleRadius)
            if ok and safePath and table_getn(safePath) > 0 then
                path = safePath
            end
        end
    end
    if not path and NavUtils and NavUtils.PathTo then
        local ok, straight = pcall(NavUtils.PathTo, layer, start, goal)
        if ok and straight then
            path = straight
        end
    end
    if not path then
        path = {}
    end
    if table_getn(path) == 0 then
        table_insert(path, CopyVector(goal))
    else
        local final = path[table_getn(path)]
        if not final or VDist2(final[1], final[3], goal[1], goal[3]) > 2 then
            table_insert(path, CopyVector(goal))
        end
    end
    return path
end

local function IssuePathOrders(platoon, path, formation, aggressiveFinal)
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then
        return false
    end
    IssueClearCommands(units)
    local form = formation or 'GrowthFormation'
    local useForm = (type(form) == 'string') and string.lower(form) ~= 'noformation'
    for i = 1, table_getn(path) - 1 do
        local waypoint = path[i]
        if waypoint then
            if useForm then
                IssueFormMove(units, waypoint, form, 0)
            else
                IssueMove(units, waypoint)
            end
        end
    end
    local final = path[table_getn(path)]
    if aggressiveFinal then
        if useForm then
            platoon:AggressiveMoveToLocation(final)
        else
            IssueAggressiveMove(units, final)
        end
    else
        if useForm then
            IssueFormMove(units, final, form, 0)
        else
            IssueMove(units, final)
        end
    end
    return true
end

local function ShouldUseTransports(platoon, destination, opts)
    if not opts.UseTransports or not destination then
        return false
    end
    local origin = GetPlatoonPosition(platoon)
    if not origin then
        return true
    end
    if VDist3(origin, destination) > TransportDistance then
        return true
    end
    if NavUtils and NavUtils.CanPathTo then
        local layer = opts.Layer or 'Land'
        local ok, can = pcall(NavUtils.CanPathTo, layer, origin, destination)
        if ok and not can then
            return true
        end
    end
    return false
end

local function MoveWithTransports(platoon, destination)
    local success = false
    if ScenarioFramework and ScenarioFramework.PlatoonMoveWithTransports then
        success = pcall(ScenarioFramework.PlatoonMoveWithTransports, platoon, destination, false)
    end
    if not success and ScenarioFramework and ScenarioFramework.PlatoonAttackWithTransports then
        success = pcall(ScenarioFramework.PlatoonAttackWithTransports, platoon, destination, false)
    end
    return success
end

local function RoutePlatoon(platoon, destination, opts, aggressiveFinal)
    if not PlatoonAlive(platoon) then
        return false
    end
    destination = CopyVector(destination)
    if not destination then
        return false
    end
    local start = GetPlatoonPosition(platoon)
    local path = BuildPath(opts.Layer or 'Land', start, destination, opts) or {}
    if table_getn(path) == 0 then
        return false
    end
    IssuePathOrders(platoon, path, opts.Formation, aggressiveFinal)
    return true
end

local function AdvanceToDestination(platoon, destinationProvider, opts, aggressiveFinal)
    local rerouteTimer = 0
    local transported = false
    while PlatoonAlive(platoon) do
        local destination = destinationProvider()
        if not destination then
            return false
        end
        local pos = GetPlatoonPosition(platoon)
        local arriveRadius = aggressiveFinal and 25 or 15
        if pos and VDist3(pos, destination) <= arriveRadius then
            return true
        end
        if rerouteTimer <= 0 then
            local rerouted = false
            if not transported and ShouldUseTransports(platoon, destination, opts) then
                if MoveWithTransports(platoon, destination) then
                    transported = true
                    rerouteTimer = RecheckDelay
                    rerouted = true
                end
            end
            if not rerouted then
                if RoutePlatoon(platoon, destination, opts, aggressiveFinal) then
                    rerouteTimer = RecheckDelay
                else
                    rerouteTimer = 2
                end
            end
        end
        SafeWaitSeconds(1)
        rerouteTimer = rerouteTimer - 1
    end
    return false
end

local function GetThreatAt(brain, position, threatType)
    if not brain or not position then
        return 0
    end
    local ok, threat = pcall(brain.GetThreatAtPosition, brain, position, ThreatSampleRadius, true, threatType or 'Overall')
    if ok and threat then
        return threat
    end
    return 0
end

local function DefenseScore(brain, position, opts)
    local threatType = LayerThreatTypes[opts.Layer or 'Land'] or 'Overall'
    local threat = GetThreatAt(brain, position, threatType)
    if not opts.Underwater then
        local surfaceThreat = GetThreatAt(brain, position, 'IndirectFire')
        threat = threat + surfaceThreat * 0.5
    end
    return threat
end

local function ClusterPosition(units)
    local count = table_getn(units)
    if count == 0 then
        return nil
    end
    local sx, sy, sz = 0, 0, 0
    for _, unit in ipairs(units) do
        local pos = unit:GetPosition()
        sx = sx + pos[1]
        sy = sy + pos[2]
        sz = sz + pos[3]
    end
    return { sx / count, sy / count, sz / count }
end

local function FindStructureCluster(reference, structures)
    if table_getn(structures) == 0 then
        return nil, nil
    end
    local bestUnits = {}
    local bestScore = -1
    for _, anchor in ipairs(structures) do
        local apos = anchor:GetPosition()
        local cluster = {}
        local score = 0
        for _, candidate in ipairs(structures) do
            local cpos = candidate:GetPosition()
            if VDist2(apos[1], apos[3], cpos[1], cpos[3]) <= ClusterRadius then
                table_insert(cluster, candidate)
                score = score + 1
            end
        end
        if score > bestScore then
            bestScore = score
            bestUnits = cluster
        end
    end
    if bestScore <= 0 then
        local single = structures[1]
        return single, single:GetPosition()
    end
    return bestUnits[1], ClusterPosition(bestUnits)
end

local function FindClosestStructure(reference, structures)
    if table_getn(structures) == 0 then
        return nil, nil
    end
    local best = nil
    local bestDist = math_huge
    for _, structure in ipairs(structures) do
        local pos = structure:GetPosition()
        local dist = VDist2(reference[1], reference[3], pos[1], pos[3])
        if dist < bestDist then
            best = structure
            bestDist = dist
        end
    end
    if not best then
        return nil, nil
    end
    return best, best:GetPosition()
end

local function FilterAlive(units)
    local index = 1
    while index <= table_getn(units) do
        local unit = units[index]
        if not unit or unit.Dead then
            table_remove(units, index)
        else
            index = index + 1
        end
    end
    return units
end

local function PruneBrains(brainList)
    local index = 1
    while index <= table_getn(brainList) do
        local enemyBrain = brainList[index]
        if not enemyBrain or enemyBrain:IsDefeated() then
            table_remove(brainList, index)
        else
            index = index + 1
        end
    end
    return brainList
end

local function WaitForTargetDestruction(target, timeout)
    timeout = timeout or 60
    local elapsed = 0
    while elapsed < timeout do
        if not target or target.Dead then
            return true
        end
        SafeWaitSeconds(1)
        elapsed = elapsed + 1
    end
    return target.Dead
end

local function ClearTargetArea(platoon, position, opts)
    if not PlatoonAlive(platoon) or not position then
        return
    end
    local brain = platoon:GetBrain()
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then
        return
    end
    IssueAggressiveMove(units, position)
    local tries = 0
    while PlatoonAlive(platoon) and tries < 6 do
        SafeWaitSeconds(5)
        tries = tries + 1
        if not brain then
            break
        end
        local hostiles = brain:GetUnitsAroundPoint(StructureCategory, position, ClearRadius, 'Enemy') or {}
        FilterAlive(hostiles)
        if table_getn(hostiles) == 0 then
            break
        end
    end
end

local function NormaliseOptions(platoon, data)
    local opts = {}
    if type(data) == 'table' then
        for k, v in pairs(data) do
            opts[k] = v
        end
    end
    opts.Formation = (type(opts.Formation) == 'string') and opts.Formation or nil
    opts.Underwater = opts.Underwater and true or false
    opts.UseTransports = opts.UseTransports and true or false
    opts.AvoidDef = opts.AvoidDef and true or false
    opts.TargetArmy = (type(opts.TargetArmy) == 'table') and opts.TargetArmy or nil
    opts.Brain = platoon:GetBrain()
    opts.Layer = DetermineLayer(platoon)
    if not opts.Formation then
        opts.Formation = LayerFormationDefault[opts.Layer] or 'GrowthFormation'
    end
    return opts
end

local function SelectRaidTarget(platoon, opts, enemyBrains)
    local brain = platoon:GetBrain()
    local basePriority = { opts.TargetType, 'ECO', 'FAB', 'ENG', 'DEF' }
    local seen = {}
    local priorities = {}
    for _, entry in ipairs(basePriority) do
        if entry and RaidCategories[entry] and not seen[entry] then
            table_insert(priorities, entry)
            seen[entry] = true
        end
    end

    local function chooseFromCategory(categoryName)
        local units = CollectUnitsFromBrains(enemyBrains, RaidCategories[categoryName], opts)
        FilterAlive(units)
        if table_getn(units) == 0 then
            return nil
        end
        local best = nil
        local bestThreat = math_huge
        for _, unit in ipairs(units) do
            local pos = unit:GetPosition()
            local threat = DefenseScore(brain, pos, opts)
            if threat < bestThreat then
                bestThreat = threat
                best = unit
            end
        end
        return best
    end

    if opts.TargetType == 'SMT' then
        local all = {}
        for key, cat in pairs(RaidCategories) do
            local units = CollectUnitsFromBrains(enemyBrains, cat, opts)
            for _, unit in ipairs(units) do
                table_insert(all, unit)
            end
        end
        FilterAlive(all)
        if table_getn(all) > 0 then
            local best = nil
            local bestThreat = math_huge
            for _, unit in ipairs(all) do
                local pos = unit:GetPosition()
                local threat = DefenseScore(brain, pos, opts)
                if threat < bestThreat then
                    bestThreat = threat
                    best = unit
                end
            end
            if best then
                return best, best:GetPosition()
            end
        end
    end

    for _, categoryName in ipairs(priorities) do
        local target = chooseFromCategory(categoryName)
        if target then
            return target, target:GetPosition()
        end
    end

    return nil, nil
end

local function SelectWaveTarget(platoon, opts, enemyBrains)
    local structures = CollectUnitsFromBrains(enemyBrains, StructureCategory, opts)
    FilterAlive(structures)
    if table_getn(structures) == 0 then
        return nil, nil
    end
    local position = GetPlatoonPosition(platoon)
    if not position then
        return nil, nil
    end
    if opts.TargetType == 'concentration' then
        local unit, targetPos = FindStructureCluster(position, structures)
        return unit, targetPos
    else
        local unit, targetPos = FindClosestStructure(position, structures)
        return unit, targetPos
    end
end

local function AttackTarget(platoon, target, position, opts, aggressive)
    if not PlatoonAlive(platoon) or not position then
        return false
    end
    local lastPos = CopyVector(position)
    local function destinationProvider()
        if target and not target.Dead then
            local tpos = target:GetPosition()
            if tpos then
                lastPos = tpos
            end
        end
        return lastPos
    end
    local arrived = AdvanceToDestination(platoon, destinationProvider, opts, aggressive)
    if not arrived then
        return false
    end
    local units = platoon:GetPlatoonUnits() or {}
    if table_getn(units) == 0 then
        return false
    end
    if aggressive then
        IssueAggressiveMove(units, lastPos)
    else
        IssueClearCommands(units)
        if target and not target.Dead then
            IssueAttack(units, target)
        else
            IssueMove(units, lastPos)
        end
    end
    return true
end

local function WaveBehaviour(platoon, opts)
    local brain = platoon:GetBrain()
    if not brain then
        return
    end
    local enemyBrains = ResolveTargetBrains(brain, opts)
    while PlatoonAlive(platoon) do
        PruneBrains(enemyBrains)
        if table_getn(enemyBrains) == 0 then
            enemyBrains = ResolveTargetBrains(brain, opts)
        end
        local target, position = SelectWaveTarget(platoon, opts, enemyBrains)
        if target and position then
            local lastPos = CopyVector(position)
            local function provider()
                if target and not target.Dead then
                    local tpos = target:GetPosition()
                    if tpos then
                        lastPos = tpos
                    end
                end
                return lastPos
            end
            if AdvanceToDestination(platoon, provider, opts, false) then
                ClearTargetArea(platoon, lastPos, opts)
            else
                SafeWaitSeconds(RecheckDelay)
            end
        else
            SafeWaitSeconds(RecheckDelay)
        end
    end
end

local function RaidBehaviour(platoon, opts)
    local brain = platoon:GetBrain()
    if not brain then
        return
    end
    local enemyBrains = ResolveTargetBrains(brain, opts)
    while PlatoonAlive(platoon) do
        PruneBrains(enemyBrains)
        if table_getn(enemyBrains) == 0 then
            enemyBrains = ResolveTargetBrains(brain, opts)
        end
        local target, position = SelectRaidTarget(platoon, opts, enemyBrains)
        if target and position then
            local units = platoon:GetPlatoonUnits()
            if units and table_getn(units) > 0 then
                IssueClearCommands(units)
            end
            if AttackTarget(platoon, target, position, opts, false) then
                WaitForTargetDestruction(target, 45)
            else
                SafeWaitSeconds(RecheckDelay)
            end
        else
            SafeWaitSeconds(RecheckDelay)
        end
    end
end

--=======================Expose==================

function WaveAttack(platoon, data)
    local opts = NormaliseOptions(platoon, data)
    if not opts.Brain then
        return
    end
    WaveBehaviour(platoon, opts)
end

function RaidAttack(platoon, data)
    local opts = NormaliseOptions(platoon, data)
    if not opts.Brain then
        return
    end
    RaidBehaviour(platoon, opts)
end

return {
    WaveAttack = WaveAttack,
    RaidAttack = RaidAttack,
}