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
    Engineer patrol that constructs and upgrades forward firebases in order.
    For each entry in Markers the engineers move to the named marker, build
    every structure defined in the paired group (including upgrades), and only
    advance to the next entry once the site is fully complete. After the last
    entry the loop restarts from the first.

Data options
    Markers         (required)
                    List of {markerName, groupName} pairs. Each pair specifies
                    the location to move to and the editor unit-group that
                    defines the structures to build/upgrade there.

Example
    Firebase(platoon, {
        Markers = {
            { 'Firebase_North', 'FirebaseLayout_T1' },
            { 'Firebase_East',  'FirebaseWalls'     },
        },
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

-- Issue one clear, then queue all waypoints so the engine handles transitions
-- without stopping to reform between each point.
local function MoveAlongRoute(platoon, waypoints, options)
    local n = table.getn(waypoints)
    if n < 1 then return end
    local units = PlatoonUnits(platoon)
    if table.getn(units) < 1 then return end
    local aggressive = options and options.AggressiveMove and true or false
    local formation  = (options and options.Formation) or 'NoFormation'
    IssueClearCommands(units)
    for i = 1, n do
        if formation ~= 'NoFormation' and formation ~= '' then
            IssueFormMove(units, waypoints[i], formation, 0)
        elseif aggressive then
            IssueAggressiveMove(units, waypoints[i])
        else
            IssueMove(units, waypoints[i])
        end
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
    -- Check every unit individually rather than using the platoon centroid.
    -- GetPlatoonPosition() returns nil once units stop moving, which would
    -- make a centroid-based check permanently fail at the final waypoint.
    local units = PlatoonUnits(platoon)
    for _, u in ipairs(units) do
        if IsAlive(u) then
            local p = u:GetPosition()
            if p then
                local dx = p[1] - pos[1]
                local dz = p[3] - pos[3]
                if (dx * dx + dz * dz) <= radiusSq then
                    return true
                end
            end
        end
    end
    return false
end

-- Poll until the platoon center is within ArriveRadius of pos, or timeout.
-- When AggressiveMove is set, actively scans for enemies near the platoon
-- during transit: stops to kill any enemy found within scanR, then re-issues
-- movement to the original destination before continuing the wait loop.
-- Fight time is not counted against the travel timeout.
local function WaitForArrival(platoon, pos, options)
    local radius     = (options and options.ArriveRadius) or 15
    local timeout    = (options and options.ArriveTimeout) or 120
    local interval   = 1
    local elapsed    = 0
    local radiusSq   = radius * radius
    local aggressive = options and options.AggressiveMove
    local scanR      = 35

    local dbg = options and options.Debug
    while PlatoonAlive(platoon) and elapsed < timeout do
        -- Yield first so this loop never busy-spins, even when HasArrived is
        -- true on the very first check (e.g. platoon already at target position).
        WaitSeconds(interval)
        elapsed = elapsed + interval

        if HasArrived(platoon, pos, radiusSq) then
            return true
        end

        if aggressive then
            local center = GetPlatoonCenter(platoon)
            if center then
                local brain  = platoon:GetBrain()
                local domain = GetDomain(platoon)
                local nearby = brain:GetUnitsAroundPoint(
                    categories.MOBILE + categories.STRUCTURE,
                    center, scanR, 'Enemy') or {}
                local target
                for _, u in ipairs(nearby) do
                    if IsAlive(u) and CanUnitDomainAttackTarget(domain, u, false) then
                        target = u
                        break
                    end
                end
                if target then
                    local units = PlatoonUnits(platoon)
                    IssueClearCommands(units)
                    IssueAttack(units, target)
                    local fightSecs = 0
                    while PlatoonAlive(platoon) and IsAlive(target) and fightSecs < 60 do
                        WaitSeconds(1)
                        fightSecs = fightSecs + 1
                    end
                    if PlatoonAlive(platoon) then
                        MovePlatoonTo(platoon, pos, options)
                    end
                end
            end
        end
    end

    -- Log why we exited: timeout vs platoon dead
    if not PlatoonAlive(platoon) then
        DLog(dbg, 'WaitForArrival', 'exited - platoon dead after ' .. tostring(elapsed) .. 's')
    else
        DLog(dbg, 'WaitForArrival', 'timeout after ' .. tostring(elapsed) .. 's radius=' .. tostring(radius))
    end
    return false
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

-- Returns a flat list of { pdPos, rangeSq } pairs for every living enemy point
-- defense structure (STRUCTURE * DEFENSE * DIRECTFIRE).  MaxRadius is read
-- directly from each unit's weapon blueprint so T1/T2/T3 PD have different
-- ranges rather than a single fixed value.
local function GetEnemyPDCoverage(brain)
    local pdCat = categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE
    local all   = brain:GetUnitsAroundPoint(pdCat, { 0, 0, 0 }, 100000, 'Enemy') or {}
    local out   = {}
    for _, pd in ipairs(all) do
        if IsAlive(pd) then
            local pdPos = pd:GetPosition()
            local bp    = pd:GetBlueprint()
            local range = 0
            if bp and bp.Weapon then
                for _, wpn in ipairs(bp.Weapon) do
                    if (wpn.MaxRadius or 0) > range then
                        range = wpn.MaxRadius
                    end
                end
            end
            if range > 0 and pdPos then
                table.insert(out, { pdPos, range * range })
            end
        end
    end
    return out
end

-- Returns true when targetPos falls within the weapon range of any PD in the
-- coverage list produced by GetEnemyPDCoverage.
local function IsCoveredByPD(targetPos, coverage)
    for _, entry in ipairs(coverage) do
        local pdPos  = entry[1]
        local rangeSq = entry[2]
        local dx = targetPos[1] - pdPos[1]
        local dz = targetPos[3] - pdPos[3]
        if (dx * dx + dz * dz) <= rangeSq then
            return true
        end
    end
    return false
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

    -- Build PD coverage once per call so every candidate is checked against
    -- real weapon ranges (T1 PD shorter, T2 PD longer, etc.) rather than a
    -- fixed threat-map radius.
    local pdCoverage = {}
    if avoidDef and brain then
        pdCoverage = GetEnemyPDCoverage(brain)
    end

    for _, u in ipairs(units or {}) do
        if IsAlive(u) then
            local p = u:GetPosition()
            local dx = pos[1] - p[1]
            local dz = pos[3] - p[3]
            local d2 = (dx * dx) + (dz * dz)

            if avoidDef and IsCoveredByPD(p, pdCoverage) then
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
            -- Build a safe route to the cluster center so the platoon is guided
            -- around terrain/water corners rather than scraping straight through.
            -- All waypoints and attacks are queued in one command stream.
            local domain = GetDomain(platoon)
            local start  = platoon:GetPlatoonPosition()
            local route
            if start then
                route = BuildSafeRoute({ start, choose.Center }, domain)
            else
                route = { choose.Center }
            end
            MoveAlongRoute(platoon, route, data)
            local wunits = PlatoonUnits(platoon)
            for _, u in ipairs(choose.Units) do
                if IsAlive(u) then
                    IssueAttack(wunits, u)
                end
            end
            ClearLocalArea(platoon, data, choose.Center)
            WaitForArrival(platoon, choose.Center, data)
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
            local targetPos = target:GetPosition()
            AttackMoveToTarget(platoon, target, data)
            WaitForArrival(platoon, targetPos, data)
        else
            DLog(data.Debug, 'RaidAttack', 'no target found')
            WaitSeconds(3)
        end
    end
end

local function ResolveHuntMask(list)
    -- Categories are userdata in FAF, not numbers. Accumulate with nil so the
    -- first assignment is always a category + category operation, never number + category.
    local mask = nil
    for _, item in ipairs(list or {}) do
        if type(item) == 'string' then
            -- Blueprint ID string: widen mask to ALLUNITS so the unit passes the
            -- initial GetUnitsAroundPoint filter; MatchesHuntList does the exact check.
            mask = mask and (mask + categories.ALLUNITS) or categories.ALLUNITS
        elseif type(item) == 'userdata' then
            mask = mask and (mask + item) or item
        end
    end
    return mask or categories.ALLUNITS
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
            local targetPos = target:GetPosition()
            AttackMoveToTarget(platoon, target, data)
            ClearLocalArea(platoon, data, targetPos)
            WaitForArrival(platoon, targetPos, data)
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
    local chain = Scenario.Chains and Scenario.Chains[chainName]
    if not chain or not chain.Markers then
        return positions
    end
    for _, markerName in ipairs(chain.Markers) do
        local p = ScenarioUtils.MarkerToPosition(markerName)
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
    data.Investigate = data.Investigate and true or false
    if data.ArriveRadius == nil then data.ArriveRadius = 10 end
    local pingPong = (data.Loop == false)

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

    path = BuildSafeRoute(path, GetDomain(platoon))
    if table.getn(path) < 2 then
        DLog(data.Debug, 'DefensePatrol', 'no passable segments after terrain filter')
        return
    end

    -- Use NoFormation for waypoint moves so every unit stops exactly at the
    -- marker position. Formation moves (GrowthFormation etc.) settle units in
    -- a ring around the destination; if the ring radius > ArriveRadius, no unit
    -- ever enters the arrival check and the engine kills the idle platoon.
    data.Formation = 'NoFormation'

    DLog(data.Debug, 'DefensePatrol', 'start pingPong=' .. tostring(pingPong) .. ' pathLen=' .. tostring(table.getn(path)))

    while PlatoonAlive(platoon) do
        for i = 1, table.getn(path) do
            if not PlatoonAlive(platoon) then break end
            MovePlatoonTo(platoon, path[i], data)
            local arrived = WaitForArrival(platoon, path[i], data)
            DLog(data.Debug, 'DefensePatrol', 'forward i=' .. tostring(i) .. '/' .. tostring(table.getn(path)) .. ' arrived=' .. tostring(arrived))
            InvestigateNearby(platoon, data, path[i])
        end

        DLog(data.Debug, 'DefensePatrol', 'forward complete pingPong=' .. tostring(pingPong))
        if pingPong then
            DLog(data.Debug, 'DefensePatrol', 'backtrack start')
            for i = table.getn(path) - 1, 1, -1 do
                if not PlatoonAlive(platoon) then break end
                MovePlatoonTo(platoon, path[i], data)
                local arrived = WaitForArrival(platoon, path[i], data)
                DLog(data.Debug, 'DefensePatrol', 'backtrack i=' .. tostring(i) .. '/' .. tostring(table.getn(path)) .. ' arrived=' .. tostring(arrived))
                InvestigateNearby(platoon, data, path[i])
            end
        end
    end
    DLog(data.Debug, 'DefensePatrol', 'patrol ended - platoon no longer alive')
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

local function CollectGroupEntries(node, out)
    if not (node and node.Units) then
        return
    end
    for _, child in pairs(node.Units) do
        if type(child) == 'table' then
            if child.type and child.Position then
                table.insert(out, { bp = child.type, pos = child.Position })
            elseif child.Units then
                CollectGroupEntries(child, out)
            end
        end
    end
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
    CollectGroupEntries(group, out)
    return out
end

local function StructureExistsAt(brain, pos, bpId, radius)
    radius = radius or 2
    local target = string.lower(bpId)
    local nearby = brain:GetUnitsAroundPoint(
        categories.STRUCTURE + categories.WALL, pos, radius, 'Ally') or {}
    for _, unit in ipairs(nearby) do
        if IsAlive(unit) then
            local bp = unit:GetBlueprint()
            if bp and string.lower(bp.BlueprintId or '') == target then
                return true
            end
        end
    end
    return false
end

-- Returns true if any allied structure/wall exists at pos (any blueprint).
-- Used to detect positions occupied by a lower-tier structure.
local function AnyStructureAt(brain, pos, radius)
    local nearby = brain:GetUnitsAroundPoint(
        categories.STRUCTURE + categories.WALL, pos, radius or 2, 'Ally') or {}
    for _, s in ipairs(nearby) do
        if IsAlive(s) then return true end
    end
    return false
end

-- Mod is absent in this FAF Lua build; use floor-based integer modulo.
local function Mod(a, b) return a - math.floor(a / b) * b end

-- Returns the tech tier (1/2/3) of an engineer unit.
-- T3 and SCU/ACU all fall under categories.TECH3 in FAF.
local function EngineerTier(u)
    if EntityCategoryContains(categories.TECH3, u) then return 3 end
    if EntityCategoryContains(categories.TECH2, u) then return 2 end
    return 1
end

-- Infers the required build tier from a structure blueprint ID.
-- Standard FAF IDs embed the tier as the 3rd character: ue1xxx=T1, ur2xxx=T2, xa3xxx=T3.
local function StructureTier(bp)
    local c = string.sub(bp, 3, 3)
    if c == '3' then return 3 end
    if c == '2' then return 2 end
    return 1
end

local function EngineerUnits(units)
    local out = {}
    for _, u in ipairs(units or {}) do
        if IsAlive(u) and EntityCategoryContains(categories.ENGINEER, u) then
            table.insert(out, u)
        end
    end
    return out
end

local function BuildMissingStructures(brain, engineers, groupEntries, debugOn)
    -- Only collect entries where the position is completely empty.
    -- Positions that already have any structure (even a lower-tier one) are
    -- left to the upgrade phase; trying to build on top of them fails silently.
    local missing = {}
    for _, entry in ipairs(groupEntries) do
        if not StructureExistsAt(brain, entry.pos, entry.bp, 2) then
            if not AnyStructureAt(brain, entry.pos, 2) then
                DLog(debugOn, 'Firebase', 'build missing ' .. tostring(entry.bp))
                table.insert(missing, entry)
            end
        end
    end

    if table.getn(missing) == 0 then return 0 end

    local numEng     = table.getn(engineers)
    local numMissing = table.getn(missing)
    if numEng < 1 then return 0 end

    -- Cache each engineer's tier once
    local engTier = {}
    for i = 1, numEng do
        engTier[i] = EngineerTier(engineers[i])
    end

    -- Primary pass: spread structures across capable engineers (round-robin per tier).
    local cursor  = { [1]=1, [2]=1, [3]=1 }
    local hasOrder = {}

    for _, entry in ipairs(missing) do
        local need  = StructureTier(entry.bp)
        local start = cursor[need]
        local picked = nil
        for step = 0, numEng - 1 do
            local idx = Mod(start - 1 + step, numEng) + 1
            if engTier[idx] >= need then
                picked = idx
                cursor[need] = Mod(idx, numEng) + 1
                break
            end
        end
        if picked then
            IssueBuildMobile({engineers[picked]}, entry.pos, entry.bp, {})
            hasOrder[picked] = true
        else
            DLog(debugOn, 'Firebase', 'skipping ' .. tostring(entry.bp) .. ' (no T' .. need .. '+ engineer)')
        end
    end

    -- Secondary pass: every engineer without a primary order gets a build command
    -- for the first compatible structure in the list (so they arrive and assist
    -- naturally).  Only fall back to IssueGuard if no compatible structure exists.
    local anchor = nil
    for i = 1, numEng do
        if hasOrder[i] then anchor = engineers[i]; break end
    end

    for i = 1, numEng do
        if not hasOrder[i] then
            local assigned = false
            for j = 1, numMissing do
                local entry = missing[Mod(i - 1 + j - 1, numMissing) + 1]
                if engTier[i] >= StructureTier(entry.bp) then
                    IssueBuildMobile({engineers[i]}, entry.pos, entry.bp, {})
                    assigned = true
                    break
                end
            end
            if not assigned and anchor then
                IssueGuard({engineers[i]}, anchor)
            end
        end
    end

    return numMissing
end

local function WaitForEngineers(platoon, timeoutSecs)
    local elapsed  = 0
    local interval = 2
    timeoutSecs    = timeoutSecs or 120
    while PlatoonAlive(platoon) and elapsed < timeoutSecs do
        local busy = false
        for _, unit in ipairs(EngineerUnits(PlatoonUnits(platoon))) do
            local cmds = unit:GetCommandQueue()
            if cmds and table.getn(cmds) > 0 then
                busy = true
                break
            end
        end
        if not busy then return end
        WaitSeconds(interval)
        elapsed = elapsed + interval
    end
end

-- Given the current blueprint ID of a structure and the desired target blueprint
-- ID, returns the immediate next upgrade step toward the target, or nil if the
-- current structure is not below the target in the same upgrade chain.
-- Uses __blueprints (FAF global blueprint registry).
local function UpgradeStepToward(cur, target)
    if not (cur and target) then return nil end
    cur    = string.lower(cur)
    target = string.lower(target)
    if cur == target then return nil end

    local data = __blueprints and __blueprints[cur]
    local up   = data and data.General and data.General.UpgradesTo
    if not (type(up) == 'string' and up ~= '' and up ~= 'none') then return nil end
    local nxt = string.lower(up)

    -- Walk forward from nxt; if we reach target then nxt is the right first step
    if nxt == target then return nxt end
    local walk = nxt
    local seen = { [cur] = true }
    while walk and not seen[walk] do
        if walk == target then return nxt end
        seen[walk] = true
        local d  = __blueprints and __blueprints[walk]
        local u2 = d and d.General and d.General.UpgradesTo
        if not (type(u2) == 'string' and u2 ~= '' and u2 ~= 'none') then break end
        walk = string.lower(u2)
    end
    return nil
end

-- Issue upgrade orders on any fully-built structures that are below their target
-- tier, and have all engineers assist the upgrading structures (round-robin).
-- Returns the number of structures that received upgrade orders (or are already
-- upgrading toward the target). 0 means everything is at target tier.
local function IssueUpgradesAndAssist(brain, engineers, groupEntries, debugOn)
    local targets = {}  -- structures that are upgrading or just issued an upgrade

    for _, entry in ipairs(groupEntries) do
        if not StructureExistsAt(brain, entry.pos, entry.bp, 2) then
            local nearby = brain:GetUnitsAroundPoint(
                categories.STRUCTURE + categories.WALL, entry.pos, 2, 'Ally') or {}
            for _, s in ipairs(nearby) do
                if IsAlive(s) then
                    -- Only upgrade complete structures, not ones still being built
                    local frac = s.GetFractionComplete and s:GetFractionComplete() or 1
                    if frac >= 1 then
                        local sbp   = s:GetBlueprint()
                        local curId = sbp and string.lower(sbp.BlueprintId or '')
                        if curId and curId ~= '' then
                            local nxt = UpgradeStepToward(curId, entry.bp)
                            if nxt then
                                local ok, already = pcall(function()
                                    return s:IsUnitState('Upgrading')
                                end)
                                if not (ok and already) then
                                    DLog(debugOn, 'Firebase', 'upgrade ' .. curId .. ' -> ' .. nxt)
                                    IssueUpgrade({s}, nxt)
                                end
                                table.insert(targets, s)
                            end
                        end
                    end
                end
            end
        end
    end

    if table.getn(targets) == 0 then return 0 end

    -- Assign engineers round-robin across upgrading structures to assist
    local numEng = table.getn(engineers)
    local numTgt = table.getn(targets)
    if numEng < 1 then return numTgt end
    for i = 1, numEng do
        local tgt = targets[Mod(i - 1, numTgt) + 1]
        IssueGuard({engineers[i]}, tgt)
    end

    return numTgt
end

-- Waits until no structure near any group-entry position is in the Upgrading state.
local function WaitForStructureUpgrades(brain, platoon, groupEntries, timeoutSecs)
    local elapsed  = 0
    local interval = 3
    timeoutSecs    = timeoutSecs or 180
    while PlatoonAlive(platoon) and elapsed < timeoutSecs do
        local busy = false
        for _, entry in ipairs(groupEntries) do
            local nearby = brain:GetUnitsAroundPoint(
                categories.STRUCTURE + categories.WALL, entry.pos, 2, 'Ally') or {}
            for _, s in ipairs(nearby) do
                if IsAlive(s) then
                    local ok, st = pcall(function()
                        return s:IsUnitState('Upgrading')
                    end)
                    if ok and st then busy = true; break end
                end
            end
            if busy then break end
        end
        if not busy then return end
        WaitSeconds(interval)
        elapsed = elapsed + interval
    end
end

-- Returns true when every group entry has its exact target structure fully present
-- at its position (complete, not still being built, not mid-upgrade).
local function AllStructuresComplete(brain, groupEntries)
    for _, entry in ipairs(groupEntries) do
        local target = string.lower(entry.bp)
        local nearby = brain:GetUnitsAroundPoint(
            categories.STRUCTURE + categories.WALL, entry.pos, 2.5, 'Ally') or {}
        local found = false
        for _, s in ipairs(nearby) do
            if IsAlive(s) then
                local sbp = s:GetBlueprint()
                if sbp and string.lower(sbp.BlueprintId or '') == target then
                    local frac          = s.GetFractionComplete and s:GetFractionComplete() or 1
                    local ok1, upgr     = pcall(function() return s:IsUnitState('Upgrading')  end)
                    local ok2, built    = pcall(function() return s:IsUnitState('BeingBuilt') end)
                    if frac >= 1 and not (ok1 and upgr) and not (ok2 and built) then
                        found = true
                        break
                    end
                end
            end
        end
        if not found then return false end
    end
    return true
end

function Firebase(platoon, data)
    data = NormalizeData(data)
    data.Markers = data.Markers or {}
    DLog(data.Debug, 'Firebase', 'start')

    if table.getn(data.Markers) < 1 then
        DLog(data.Debug, 'Firebase', 'no Markers provided; exiting')
        return
    end

    local brain    = platoon:GetBrain()
    local armyName = GetArmyName(brain)

    while PlatoonAlive(platoon) do
        for _, entry in ipairs(data.Markers) do
            if not PlatoonAlive(platoon) then break end

            local markerName   = entry[1]
            local groupName    = entry[2]
            local groupEntries = GetGroupUnits(armyName, groupName)

            DLog(data.Debug, 'Firebase',
                'moving to ' .. tostring(markerName) ..
                ' (group ' .. tostring(groupName) .. ', ' ..
                table.getn(groupEntries) .. ' entries)')

            MovePlatoonTo(platoon, markerName, data)
            WaitSeconds(2)

            if not PlatoonAlive(platoon) then break end

            -- Keep working until every target structure is fully built and upgraded.
            -- Only advance to the next marker once AllStructuresComplete is true.
            while PlatoonAlive(platoon) and not AllStructuresComplete(brain, groupEntries) do

                -- Phase 1: build any empty positions that need a structure
                local engineers = EngineerUnits(PlatoonUnits(platoon))
                local issued = BuildMissingStructures(brain, engineers, groupEntries, data.Debug)
                if issued > 0 then
                    DLog(data.Debug, 'Firebase', 'issued ' .. issued .. ' build orders; waiting')
                    WaitForEngineers(platoon, 120)
                end

                if not PlatoonAlive(platoon) then break end

                -- Phase 2: upgrade any structures below their target tier
                engineers = EngineerUnits(PlatoonUnits(platoon))
                local upgrades = IssueUpgradesAndAssist(brain, engineers, groupEntries, data.Debug)
                if upgrades > 0 then
                    DLog(data.Debug, 'Firebase', 'issued ' .. upgrades .. ' upgrade orders; waiting')
                    WaitForStructureUpgrades(brain, platoon, groupEntries, 180)
                end

                if not PlatoonAlive(platoon) then break end
                WaitSeconds(2)
            end

            if PlatoonAlive(platoon) then
                DLog(data.Debug, 'Firebase', 'site complete; advancing from ' .. tostring(markerName))
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
