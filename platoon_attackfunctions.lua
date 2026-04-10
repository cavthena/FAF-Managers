--[[
================================================================================
 Platoon Attack Functions -- FAF / Lua 5.0 compatible
================================================================================

Overview
    AttackFunctions provides reusable platoon attack behavior and target
    selection logic for managers such as manager_UnitSpawner.lua and
    manager_UnitBuilder.lua.

    Routing helpers (movement, pathing, domain checks) are inlined directly
    into this file to avoid cross-file import issues in the FAF environment.

Global Options (used by all attacks)
    TargetArmy      (default: omitted)
        List of enemy army indexes to attack. If omitted, all enemies are
        valid targets.

    AggressiveMove  (default: false)
        If true, movement orders use aggressive move.

    Formation       (default: 'NoFormation')
        Formation used by movement orders.

    IntelOnly       (default: false)
        If true, targeting only uses units currently detected on intel.

    RandomizeRoute  (default: false)
        If true, movement can use random flank route before final approach.

    Transport       (default: false)
        If true, target reachability checks allow transport use.

    Bombard         (default: false)
        If true, cross-domain bombard targets are allowed (example: naval unit
        bombarding shoreline structures).

    Debug           (default: false)
        If true, verbose debug logs are emitted.

================================================================================
 Attack: WaveAttack(platoon, data)
================================================================================
Description
    Constant pressure assault against structure clusters.
    Platoon selects a target cluster, moves, clears nearby area, then repeats.

Data options
    Type            'Closest' | 'Value' (default: 'Closest')
                    Closest: nearest valid cluster to platoon position.
                    Value: highest-value cluster by structure mass+energy value.
                    Both modes avoid tiny clusters (<= 5 structures) unless no
                    larger valid cluster exists.

Example
    WaveAttack(platoon, {
        Type = 'Value',
        AggressiveMove = true,
        Formation = 'AttackFormation',
        TargetArmy = { ScenarioInfo.Player1 },
        Transport = false,
    })

================================================================================
 Attack: RaidAttack(platoon, data)
================================================================================
Description
    Precision raid against structure categories.
    Chooses nearest valid target using category priority:
        Specified > ECO > INT > BLD > DEF

Data options
    Type            'ECO' | 'BLD' | 'INT' | 'DEF'
                    If provided, that category is tried first.

    AvoidDef        false/true (default: false)
                    If true, avoid targets covered by enemy defenses unless no
                    uncovered alternatives remain.

Category mapping
    ECO : Mass extractors, power generators, mass fabricators.
    BLD : Factories, engineering support.
    INT : Radar and sonar intel structures.
    DEF : Point defense, AA, artillery, tactical/nuclear missile systems.

Example
    RaidAttack(platoon, {
        Type = 'ECO',
        AvoidDef = true,
        IntelOnly = true,
        RandomizeRoute = true,
    })

================================================================================
 Attack: HuntAttack(platoon, data)
================================================================================
Description
    Hunts explicit unit blueprints or categories. Selects nearest valid target,
    clears area, and repeats. When no target exists, platoon waits at marker.

Data options
    List            (required)
                    List entries may be blueprint id strings or category masks.

    AvoidDef        false/true (default: false)
                    Avoid targets inside defense threat range when possible.

    WaitMarker      Marker name or position table.
                    Fallback wait location when no target is found.

Air waiting behavior
    If platoon domain is AIR and it is waiting at WaitMarker, units circle the
    marker instead of stopping.

Example
    HuntAttack(platoon, {
        List = { 'ueb1103', categories.ENGINEER + categories.COMMAND },
        AvoidDef = true,
        WaitMarker = 'Air_Hold_1',
    })

================================================================================
 Attack: ScoutAttack(platoon, data)
================================================================================
Description
    Continuous random scouting across playable area.
    Each cycle has a 25% chance to move toward the current coolest intel point
    if intel manager support is available; otherwise chooses random map points.

Example
    ScoutAttack(platoon, {
        Formation = 'NoFormation',
        AggressiveMove = false,
    })

================================================================================
 Attack: DefensePatrol(platoon, data)
================================================================================
Description
    Marker-chain defense patrol.

Data options
    Chain           (required)
                    Marker chain name.

    Loop            false/true (default: true)
                    true : loop 1->N then back to 1 and repeat.
                    false: ping-pong 1->N then N->1 and repeat.

    Investigate     false/true (default: false)
                    If true, platoon can briefly intercept close enemies around
                    patrol path before resuming chain.

Example
    DefensePatrol(platoon, {
        Chain = 'Base_Defense_Chain',
        Loop = false,
        Investigate = true,
        AggressiveMove = true,
    })

================================================================================
 Attack: Firebase(platoon, data)
================================================================================
Description
    Engineer patrol that maintains forward firebases. For each marker in the
    list the engineers move to the marker, check which structures from the
    provided editor groups are missing, construct any that are absent, then
    advance to the next marker. After the last marker the loop restarts from
    the first.

Data options
    Markers         (required)
                    List of marker name strings indicating firebase locations.

    Groups          (required)
                    List of editor unit-group name strings that define which
                    structures must exist at each firebase.

Example
    Firebase(platoon, {
        Markers = { 'Firebase_North', 'Firebase_East' },
        Groups  = { 'FirebaseLayout_T1', 'FirebaseWalls' },
    })

================================================================================
 Attack: BaseBuild(platoon, data)
================================================================================
Description
    Sends a platoon of engineers to a base marker and assigns them to the base
    managed by manager_BaseEngineer. Engineers are only dispatched if the base
    currently has no factories and no engineers of its own -- once the base is
    self-sustaining, the platoon is not reassigned.

Data options
    BaseMarker      (required)
                    Marker name for the base location.

    BaseTag         (required)
                    The tag string used when the base was started via
                    manager_BaseEngineer.Start.

Example
    BaseBuild(platoon, {
        BaseMarker = 'CybranForwardBase',
        BaseTag    = 'CB_Forward',
    })
]]

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local okNav, NavUtils = pcall(import, '/lua/sim/NavUtils.lua')
if not okNav then
    NavUtils = false
end

local ok, BaseManager = pcall(import, '/maps/Platoon_Testing.v0001/manager_BaseEngineer.lua')
if not ok then BaseManager = nil end

local CAT = {
    ECO = categories.MASSEXTRACTION + categories.ENERGYPRODUCTION + categories.MASSFABRICATION,
    BLD = categories.FACTORY + categories.ENGINEERSTATION,
    INT = categories.RADAR + categories.SONAR,
    DEF = categories.DEFENSE + categories.DIRECTFIRE + categories.ANTIAIR + categories.ARTILLERY + categories.TACTICALMISSILEPLATFORM + categories.NUKE,
}

local function DLog(debugOn, tag, msg)
    if debugOn then
        LOG(string.format('[Attack:%s] %s', tostring(tag or '?'), tostring(msg)))
    end
end

local function IsAlive(unit)
    return unit and (not unit.Dead)
end

local function PlatoonUnits(platoon)
    if not platoon or platoon.Dead then
        return {}
    end
    return platoon:GetPlatoonUnits() or {}
end

local function PlatoonAlive(platoon)
    if not platoon or platoon.Dead then
        return false
    end
    local brain = platoon:GetBrain()
    if not brain or not brain.PlatoonExists then
        return false
    end
    return brain:PlatoonExists(platoon)
end

-- ---------------------------------------------------------------------------
-- Routing
-- ---------------------------------------------------------------------------

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
        -- Use rawget to bypass strict __index metamethods on FAF Vector objects
        -- (FAF Vectors only accept 'x', 'y', 'z' via __index; other keys throw an error)
        local pos = rawget(markerOrPos, 'position') or rawget(markerOrPos, 'Position')
        if pos then return pos end
        -- Numeric-indexed position table {x, y, z}
        if rawget(markerOrPos, 1) ~= nil then return markerOrPos end
        -- FAF Vector with x/y/z keys (e.g. result of unit:GetPosition())
        if rawget(markerOrPos, 'x') ~= nil then return markerOrPos end
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

local function IssueMovement(units, destination, aggressive, formation)
    if formation and formation ~= 'NoFormation' and formation ~= '' then
        IssueFormMove(units, destination, formation, 0)
    elseif aggressive then
        IssueAggressiveMove(units, destination)
    else
        IssueMove(units, destination)
    end
end

local function CanReachPosition(platoon, destination, options)
    options = options or {}
    destination = GetPosition(destination)
    if not destination then
        return false
    end

    if options.Transport then
        return true
    end

    local domain = options.Domain or GetDomain(platoon)
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
        return not EntityCategoryContains(categories.NAVAL, targetUnit)
    elseif domain == 'NAVAL' then
        return EntityCategoryContains(categories.NAVAL, targetUnit)
    end

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

local function NormalizeData(data)
    data = data or {}
    if not data.Formation then
        data.Formation = 'NoFormation'
    end
    data.AggressiveMove = data.AggressiveMove and true or false
    data.IntelOnly = data.IntelOnly and true or false
    data.RandomizeRoute = data.RandomizeRoute and true or false
    data.Transport = data.Transport and true or false
    data.Bombard = data.Bombard and true or false
    data.Debug = data.Debug and true or false
    return data
end

local function ValidTargetArmies(brain, targetArmyList)
    if type(targetArmyList) == 'table' and table.getn(targetArmyList) > 0 then
        return targetArmyList
    end

    local out = {}
    local armies = ListArmies()
    local myIndex = brain:GetArmyIndex()
    for i = 1, table.getn(armies) do
        if IsEnemy(i, myIndex) and not IsAlly(i, myIndex) then
            table.insert(out, i)
        end
    end
    return out
end

local function GetThreatAt(brain, position, rings)
    if brain and brain.GetThreatAtPosition then
        local ok, threat = pcall(brain.GetThreatAtPosition, brain, position, rings or 1, true, 'AntiSurface')
        if ok and threat then
            return threat
        end
    end
    return 0
end

local function HasIntelOn(brain, unit)
    if not IsAlive(unit) then
        return false
    end

    if unit.IsIntelVisible then
        local ok, vis = pcall(unit.IsIntelVisible, unit)
        if ok then
            return vis and true or false
        end
    end

    if brain and brain.GetIntelManager and unit.GetPosition then
        local im = brain:GetIntelManager()
        if im and im.GetIntelCoverage and unit.GetPosition then
            local pos = unit:GetPosition()
            local ok, covered = pcall(im.GetIntelCoverage, im, pos)
            if ok then
                return covered and true or false
            end
        end
    end

    return true
end

local function UnitValue(unit)
    if not IsAlive(unit) then
        return 0
    end
    local bp = unit:GetBlueprint()
    if not bp or not bp.Economy then
        return 1
    end
    local m = bp.Economy.BuildCostMass or 0
    local e = bp.Economy.BuildCostEnergy or 0
    return m + (e * 0.01)
end

local function BuildEnemyTargetPool(brain, platoon, data, categoriesMask, includeMobile)
    local out = {}
    local armies = ValidTargetArmies(brain, data.TargetArmy)
    local domain = GetDomain(platoon)

    for _, army in ipairs(armies) do
        local all = brain:GetUnitsAroundPoint(categoriesMask, {0, 0, 0}, 100000, 'Enemy') or {}
        for _, unit in ipairs(all) do
            if unit:GetAIBrain():GetArmyIndex() == army then
                if (includeMobile or EntityCategoryContains(categories.STRUCTURE, unit))
                    and CanUnitDomainAttackTarget(domain, unit, data.Bombard)
                    and (not data.IntelOnly or HasIntelOn(brain, unit))
                then
                    local pos = unit:GetPosition()
                    if pos and CanReachPosition(platoon, pos, data) then
                        table.insert(out, unit)
                    end
                end
            end
        end
    end

    return out
end

local function ClosestUnitToPos(pos, units, avoidDef, brain)
    local best, bestDistSq
    local fallback, fallbackDistSq

    for _, u in ipairs(units or {}) do
        if IsAlive(u) then
            local p = u:GetPosition()
            local dx = pos[1] - p[1]
            local dz = pos[3] - p[3]
            local d2 = (dx * dx) + (dz * dz)

            if avoidDef and GetThreatAt(brain, p, 1) > 0 then
                if not fallback or d2 < fallbackDistSq then
                    fallback = u
                    fallbackDistSq = d2
                end
            else
                if not best or d2 < bestDistSq then
                    best = u
                    bestDistSq = d2
                end
            end
        end
    end

    if best then
        return best
    end

    return fallback
end

local function ClusterUnits(units, radius)
    local clusters = {}
    radius = radius or 38
    local radiusSq = radius * radius

    for _, u in ipairs(units or {}) do
        if IsAlive(u) then
            local up = u:GetPosition()
            local chosen = nil
            for _, cl in ipairs(clusters) do
                local cp = cl.Center
                local dx = up[1] - cp[1]
                local dz = up[3] - cp[3]
                if ((dx * dx) + (dz * dz)) <= radiusSq then
                    chosen = cl
                    break
                end
            end

            if not chosen then
                chosen = { Units = {}, Center = { up[1], up[2], up[3] }, Value = 0 }
                table.insert(clusters, chosen)
            end

            table.insert(chosen.Units, u)
            chosen.Value = chosen.Value + UnitValue(u)

            local n = table.getn(chosen.Units)
            chosen.Center[1] = chosen.Center[1] + ((up[1] - chosen.Center[1]) / n)
            chosen.Center[2] = chosen.Center[2] + ((up[2] - chosen.Center[2]) / n)
            chosen.Center[3] = chosen.Center[3] + ((up[3] - chosen.Center[3]) / n)
        end
    end

    return clusters
end

local function ChooseWaveCluster(platoon, clusters, mode)
    if table.getn(clusters or {}) < 1 then
        return nil
    end

    local pos = platoon:GetPlatoonPosition()
    local best = nil
    local backup = nil
    local bestScore = nil
    local bestBackupScore = nil

    for _, cl in ipairs(clusters) do
        local count = table.getn(cl.Units)
        local small = (count <= 5)

        if mode == 'VALUE' then
            local score = cl.Value
            if small then
                if (not backup) or score > bestBackupScore then
                    backup = cl
                    bestBackupScore = score
                end
            else
                if (not best) or score > bestScore then
                    best = cl
                    bestScore = score
                end
            end
        else
            local dx = pos[1] - cl.Center[1]
            local dz = pos[3] - cl.Center[3]
            local d2 = (dx * dx) + (dz * dz)
            if small then
                if (not backup) or d2 < bestBackupScore then
                    backup = cl
                    bestBackupScore = d2
                end
            else
                if (not best) or d2 < bestScore then
                    best = cl
                    bestScore = d2
                end
            end
        end
    end

    return best or backup
end

local function ClearLocalArea(platoon, data, center)
    local units = PlatoonUnits(platoon)
    if table.getn(units) < 1 then
        return
    end

    local brain = platoon:GetBrain()
    local enemy = brain:GetUnitsAroundPoint(categories.MOBILE + categories.STRUCTURE, center, 30, 'Enemy') or {}
    for _, u in ipairs(enemy) do
        if IsAlive(u) and CanUnitDomainAttackTarget(GetDomain(platoon), u, data.Bombard) then
            IssueAttack(units, u)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function WaveAttack(platoon, data)
    data = NormalizeData(data)
    DLog(data.Debug, 'WaveAttack', 'start')

    while PlatoonAlive(platoon) do
        local brain = platoon:GetBrain()
        local pool = BuildEnemyTargetPool(brain, platoon, data, categories.STRUCTURE, false)
        local clusters = ClusterUnits(pool, 40)
        local choose = ChooseWaveCluster(platoon, clusters, string.upper(data.Type or 'CLOSEST'))

        if choose then
            DLog(data.Debug, 'WaveAttack', 'cluster size=' .. table.getn(choose.Units))
            MovePlatoonTo(platoon, choose.Center, data)
            for _, u in ipairs(choose.Units) do
                if IsAlive(u) then
                    AttackMoveToTarget(platoon, u, data)
                end
            end
            ClearLocalArea(platoon, data, choose.Center)
            WaitSeconds(2)
        else
            DLog(data.Debug, 'WaveAttack', 'no target found; waiting')
            WaitSeconds(3)
        end
    end
end

local function RaidOrder(data)
    local order = { 'ECO', 'INT', 'BLD', 'DEF' }
    if data.Type and CAT[string.upper(data.Type)] then
        local t = string.upper(data.Type)
        local out = { t }
        for _, v in ipairs(order) do
            if v ~= t then
                table.insert(out, v)
            end
        end
        return out
    end
    return order
end

function RaidAttack(platoon, data)
    data = NormalizeData(data)
    data.AvoidDef = data.AvoidDef and true or false
    DLog(data.Debug, 'RaidAttack', 'start')

    while PlatoonAlive(platoon) do
        local brain = platoon:GetBrain()
        local pos = platoon:GetPlatoonPosition() or { 0, 0, 0 }
        local order = RaidOrder(data)
        local target

        for _, key in ipairs(order) do
            local pool = BuildEnemyTargetPool(brain, platoon, data, CAT[key] * categories.STRUCTURE, false)
            target = ClosestUnitToPos(pos, pool, data.AvoidDef, brain)
            if target then
                DLog(data.Debug, 'RaidAttack', 'picked ' .. key)
                break
            end
        end

        if target then
            AttackMoveToTarget(platoon, target, data)
            WaitSeconds(2)
        else
            DLog(data.Debug, 'RaidAttack', 'no target found')
            WaitSeconds(3)
        end
    end
end

local function ResolveHuntMask(list)
    local mask = 0
    for _, item in ipairs(list or {}) do
        if type(item) == 'string' then
            mask = mask + categories.ALLUNITS
        elseif type(item) == 'userdata' or type(item) == 'number' then
            mask = mask + item
        end
    end
    if mask == 0 then
        mask = categories.ALLUNITS
    end
    return mask
end

local function MatchesHuntList(unit, list)
    if not IsAlive(unit) then
        return false
    end

    local bp = unit:GetBlueprint()
    local id = bp and bp.BlueprintId

    for _, item in ipairs(list or {}) do
        if type(item) == 'string' then
            if id == item then
                return true
            end
        else
            if EntityCategoryContains(item, unit) then
                return true
            end
        end
    end

    return false
end

function HuntAttack(platoon, data)
    data = NormalizeData(data)
    data.AvoidDef = data.AvoidDef and true or false
    data.List = data.List or {}
    local huntMask = ResolveHuntMask(data.List)
    DLog(data.Debug, 'HuntAttack', 'start')

    while PlatoonAlive(platoon) do
        local brain = platoon:GetBrain()
        local all = BuildEnemyTargetPool(brain, platoon, data, huntMask, true)
        local filtered = {}
        for _, u in ipairs(all) do
            if MatchesHuntList(u, data.List) then
                table.insert(filtered, u)
            end
        end

        local pos = platoon:GetPlatoonPosition() or { 0, 0, 0 }
        local target = ClosestUnitToPos(pos, filtered, data.AvoidDef, brain)

        if target then
            AttackMoveToTarget(platoon, target, data)
            ClearLocalArea(platoon, data, target:GetPosition())
            WaitSeconds(2)
        else
            if data.WaitMarker then
                WaitAtMarker(platoon, data.WaitMarker, data)
            end
            WaitSeconds(3)
        end
    end
end

local function PlayableArea()
    if ScenarioInfo and ScenarioInfo.PlayableArea then
        return ScenarioInfo.PlayableArea
    end
    if ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize) then
        local size = ScenarioInfo.size or ScenarioInfo.MapSize
        return { 0, 0, size[1], size[2] }
    end
    return { 0, 0, 512, 512 }
end

local function RandomPointInArea(area)
    return {
        Random(area[1], area[3]),
        0,
        Random(area[2], area[4]),
    }
end

local function IntelCoolestPoint(brain, area)
    if brain and brain.GetIntelManager then
        local intel = brain:GetIntelManager()
        if intel and intel.GetHottestPoint then
            local ok, p = pcall(intel.GetHottestPoint, intel, false)
            if ok and p then
                return p
            end
        end
    end
    return RandomPointInArea(area)
end

function ScoutAttack(platoon, data)
    data = NormalizeData(data)
    DLog(data.Debug, 'ScoutAttack', 'start')
    local area = PlayableArea()

    while PlatoonAlive(platoon) do
        local brain = platoon:GetBrain()
        local destination

        if Random(1, 100) <= 25 then
            destination = IntelCoolestPoint(brain, area)
        else
            destination = RandomPointInArea(area)
        end

        MovePlatoonTo(platoon, destination, data)
        WaitSeconds(Random(4, 9))
    end
end

local function GatherChainPositions(chainName)
    local positions = {}
    local markers = ScenarioUtils.GetMarkers() or {}
    local ids = {}

    for name, marker in pairs(markers) do
        if marker and marker.type == 'Marker' then
            if string.find(name, chainName, 1, true) then
                table.insert(ids, name)
            end
        end
    end

    table.sort(ids)
    for _, id in ipairs(ids) do
        local p = ScenarioUtils.MarkerToPosition(id)
        if p then
            table.insert(positions, p)
        end
    end

    return positions
end

local function InvestigateNearby(platoon, data, anchor)
    if not data.Investigate then
        return
    end

    local brain = platoon:GetBrain()
    local nearby = brain:GetUnitsAroundPoint(categories.MOBILE, anchor, 40, 'Enemy') or {}
    local best = nearby[1]
    if best and IsAlive(best) then
        AttackMoveToTarget(platoon, best, data)
        WaitSeconds(1)
    end
end

function DefensePatrol(platoon, data)
    data = NormalizeData(data)
    data.Loop = (data.Loop ~= nil) and (data.Loop and true or false) or true
    data.Investigate = data.Investigate and true or false

    local chain = data.Chain or data.MarkerChain
    if not chain then
        DLog(data.Debug, 'DefensePatrol', 'missing Chain')
        return
    end

    local path = GatherChainPositions(chain)
    if table.getn(path) < 2 then
        DLog(data.Debug, 'DefensePatrol', 'chain has less than 2 markers')
        return
    end

    DLog(data.Debug, 'DefensePatrol', 'start')

    while PlatoonAlive(platoon) do
        for i = 1, table.getn(path) do
            MovePlatoonTo(platoon, path[i], data)
            InvestigateNearby(platoon, data, path[i])
            WaitSeconds(1)
        end

        if not data.Loop then
            for i = table.getn(path) - 1, 2, -1 do
                MovePlatoonTo(platoon, path[i], data)
                InvestigateNearby(platoon, data, path[i])
                WaitSeconds(1)
            end
        end
    end
end

local function GetArmyName(brain)
    local idx = brain:GetArmyIndex()
    local armies = ListArmies()
    return armies[idx]
end

local function FindGroupNode(node, targetName)
    if not node or not node.Units then
        return nil
    end
    for name, child in pairs(node.Units) do
        if name == targetName then
            return child
        end
        if type(child) == 'table' and child.Units and not child.type then
            local found = FindGroupNode(child, targetName)
            if found then
                return found
            end
        end
    end
    return nil
end

local function GetGroupUnits(armyName, groupName)
    if not Scenario or not Scenario.Armies then
        return {}
    end
    local armyData = Scenario.Armies[armyName]
    if not armyData then
        return {}
    end
    local root = armyData['Units']
    if not root then
        return {}
    end
    local group = FindGroupNode(root, groupName)
    if not group or not group.Units then
        return {}
    end
    local out = {}
    for _, unitData in pairs(group.Units) do
        if unitData.type and unitData.Position then
            table.insert(out, { bp = unitData.type, pos = unitData.Position })
        end
    end
    return out
end

local function StructureExistsAt(brain, pos, bpId, radius)
    radius = radius or 2
    local nearby = brain:GetUnitsAroundPoint(categories.STRUCTURE, pos, radius, 'Ally') or {}
    for _, unit in ipairs(nearby) do
        if IsAlive(unit) then
            local bp = unit:GetBlueprint()
            if bp and bp.BlueprintId == bpId then
                return true
            end
        end
    end
    return false
end

local function BuildMissingStructures(brain, engineers, groupEntries, debugOn)
    local issued = 0
    for _, entry in ipairs(groupEntries) do
        if not StructureExistsAt(brain, entry.pos, entry.bp, 2) then
            DLog(debugOn, 'Firebase', 'build missing ' .. tostring(entry.bp))
            IssueBuildMobile(engineers, entry.pos, entry.bp, {})
            issued = issued + 1
        end
    end
    return issued
end

local function WaitForEngineers(platoon, timeoutSecs)
    local elapsed = 0
    local interval = 2
    timeoutSecs = timeoutSecs or 120
    while PlatoonAlive(platoon) and elapsed < timeoutSecs do
        local busy = false
        for _, unit in ipairs(PlatoonUnits(platoon)) do
            if IsAlive(unit) then
                local cmds = unit:GetCommandQueue()
                if cmds and table.getn(cmds) > 0 then
                    busy = true
                    break
                end
            end
        end
        if not busy then
            return
        end
        WaitSeconds(interval)
        elapsed = elapsed + interval
    end
end

function Firebase(platoon, data)
    data = NormalizeData(data)
    data.Markers = data.Markers or {}
    data.Groups  = data.Groups  or {}
    DLog(data.Debug, 'Firebase', 'start')

    if table.getn(data.Markers) < 1 then
        DLog(data.Debug, 'Firebase', 'no Markers provided; exiting')
        return
    end

    local brain     = platoon:GetBrain()
    local armyName  = GetArmyName(brain)

    local allGroupEntries = {}
    for _, groupName in ipairs(data.Groups) do
        local entries = GetGroupUnits(armyName, groupName)
        DLog(data.Debug, 'Firebase', 'group ' .. tostring(groupName) .. ' -> ' .. table.getn(entries) .. ' entries')
        for _, e in ipairs(entries) do
            table.insert(allGroupEntries, e)
        end
    end

    while PlatoonAlive(platoon) do
        for _, markerName in ipairs(data.Markers) do
            if not PlatoonAlive(platoon) then
                break
            end

            DLog(data.Debug, 'Firebase', 'moving to ' .. tostring(markerName))
            MovePlatoonTo(platoon, markerName, data)
            WaitSeconds(2)

            if not PlatoonAlive(platoon) then
                break
            end

            local engineers = PlatoonUnits(platoon)
            local issued = BuildMissingStructures(brain, engineers, allGroupEntries, data.Debug)

            if issued > 0 then
                DLog(data.Debug, 'Firebase', 'issued ' .. issued .. ' build orders; waiting')
                WaitForEngineers(platoon, 120)
            else
                DLog(data.Debug, 'Firebase', 'nothing to build at ' .. tostring(markerName))
                WaitSeconds(2)
            end
        end
    end
end

local function BaseIsSelfSustaining(brain, basePos, radius)
    radius = radius or 70
    local factories = brain:GetUnitsAroundPoint(
        categories.FACTORY * categories.STRUCTURE, basePos, radius, 'Ally') or {}
    if table.getn(factories) < 1 then
        return false
    end
    local engineers = brain:GetUnitsAroundPoint(
        categories.ENGINEER, basePos, radius, 'Ally') or {}
    return table.getn(engineers) > 0
end

function BaseBuild(platoon, data)
    data = NormalizeData(data)
    DLog(data.Debug, 'BaseBuild', 'start')

    if not data.BaseMarker then
        DLog(data.Debug, 'BaseBuild', 'missing BaseMarker; exiting')
        return
    end
    if not data.BaseTag then
        DLog(data.Debug, 'BaseBuild', 'missing BaseTag; exiting')
        return
    end

    local brain   = platoon:GetBrain()
    local basePos = GetPosition(data.BaseMarker)

    if not basePos then
        DLog(data.Debug, 'BaseBuild', 'could not resolve BaseMarker position; exiting')
        return
    end

    while PlatoonAlive(platoon) do
        if not BaseIsSelfSustaining(brain, basePos, data.Radius or 70) then
            break
        end
        DLog(data.Debug, 'BaseBuild', 'base already self-sustaining; waiting')
        WaitSeconds(10)
    end

    if not PlatoonAlive(platoon) then
        return
    end

    DLog(data.Debug, 'BaseBuild', 'moving engineers to ' .. tostring(data.BaseMarker))
    MovePlatoonTo(platoon, data.BaseMarker, data)
    WaitSeconds(2)

    if not PlatoonAlive(platoon) then
        return
    end

    if BaseManager then
        local baseHandle = BaseManager.GetBase(data.BaseTag)
        if baseHandle and baseHandle.AssignEngineerUnit then
            local units = PlatoonUnits(platoon)
            for _, unit in ipairs(units) do
                if IsAlive(unit) and EntityCategoryContains(categories.ENGINEER, unit) then
                    DLog(data.Debug, 'BaseBuild', 'assigning engineer to base')
                    baseHandle:AssignEngineerUnit(unit)
                end
            end
        else
            DLog(data.Debug, 'BaseBuild', 'no base handle found for tag ' .. tostring(data.BaseTag))
        end
    else
        DLog(data.Debug, 'BaseBuild', 'BaseManager module not available')
    end
end
