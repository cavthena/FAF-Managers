--[[
================================================================================
 platoon_AttackFunctions.lua -- Created by Cavthena
================================================================================

 Handles attack behavior and target selection for platoons.
 Movement and route orders are delegated to platoon_Routing.lua.
 Compatible with manager_UnitSpawner.lua and manager_UnitBuilder.lua.

 Attack functions receive a platoon and an optional data table.
 Values in the data table override matching keys in platoon.PlatoonData.

================================================================================
 GLOBAL OPTIONS  (available to all attack functions)
================================================================================

 TargetArmy        table | nil
   List of army indices (numbers) or brain Nicknames (strings) to target.
   Omit or leave nil to target all enemies.

 AggressiveMove    bool  (default false)
   Units move with aggressive orders, attacking anything in range en route.

 Formation         string  (default 'NoFormation')
   Formation name used when issuing movement commands.
   e.g. 'AttackFormation', 'GrowthFormation', 'NoFormation'.

 IntelOnly         bool  (default false)
   When true only target units that are visible on the intel map
   (blip detected or previously seen).

 RandomizeRoute    bool  (default false)
   When true platoons may approach the target from a flank instead of
   taking the direct route.

 Transport         bool  (default false)
   When true the platoon is permitted to use transports to reach a target.
   When false only targets reachable by the platoon's own movement layer
   are selected.

 Bombard           bool  (default false)
   When true the platoon may target units outside its normal domain if the
   target falls within maximum weapon range.
   Example: navy platoon bombarding structures on the shoreline.

 Debug             bool  (default false)
   Emit verbose routing and targeting log messages.

================================================================================
 ATTACK FUNCTIONS
================================================================================

 WaveAttack(platoon, data)
 ─────────────────────────
 Applies sustained pressure.  The platoon moves to a target, clears the area,
 then selects the next target and repeats until destroyed.

 Required data fields:
   Type    'Closest' | 'Value'
     'Closest'  Target the closest enemy structure cluster to the platoon's
                current position.
     'Value'    Target the enemy structure cluster with the highest combined
                mass build cost.  Clusters of 5 or fewer structures are
                skipped unless no larger cluster exists.

 Example:
   local AF = import('/maps/Platoon_Testing.v0001/platoon_AttackFunctions.lua')
   AF.WaveAttack(platoon, {
       Type           = 'Value',
       Formation      = 'AttackFormation',
       AggressiveMove = true,
       RandomizeRoute = true,
       IntelOnly      = false,
       Debug          = false,
   })

 ─────────────────────────────────────────────────────────────────────────────

 RaidAttack(platoon, data)
 ─────────────────────────
 Targets specific structure categories.  When the specified category has no
 valid targets the attack falls back through the default priority order:
   Specified → ECO → INT → BLD → DEF.

 Required data fields:
   Type    'ECO' | 'BLD' | 'INT' | 'DEF'
     'ECO'  Mass extractors, power generators, mass fabricators.
     'BLD'  Factories, engineering stations.
     'INT'  Radars, sonars, omni sensors.
     'DEF'  Point defenses, AA, artillery, missile and nuke structures.

 Optional data fields:
   AvoidDef  bool  (default false)
     Skip targets that are inside enemy defensive weapon coverage.
     Falls back to defended targets only when no undefended target exists.

 Example:
   AF.RaidAttack(platoon, {
       Type     = 'ECO',
       AvoidDef = true,
       IntelOnly = true,
       Formation = 'NoFormation',
   })

 ─────────────────────────────────────────────────────────────────────────────

 HuntAttack(platoon, data)
 ─────────────────────────
 Tracks and destroys specific units or unit categories.  When no valid target
 exists the platoon holds at WaitMarker.  Air platoons circle the marker.

 Required data fields:
   List        table
     Mixed list of unit blueprint IDs (strings) and/or category expressions.
     Example:  { 'uel0001', categories.EXPERIMENTAL, 'xrl0403' }

   WaitMarker  string
     Name of the map marker the platoon waits at when no targets are found.

 Optional data fields:
   AvoidDef  bool  (default false)
     Skip targets within enemy defensive weapon range.

 Example:
   AF.HuntAttack(platoon, {
       List       = { 'uel0001', categories.EXPERIMENTAL },
       WaitMarker = 'NORTH_HOLD',
       AvoidDef   = true,
       AggressiveMove = true,
   })

 ─────────────────────────────────────────────────────────────────────────────

 ScoutAttack(platoon, data)
 ──────────────────────────
 Units patrol the playable area gathering intelligence.  Each movement cycle
 has a 25 % chance to move toward the least-explored point on the intel map;
 otherwise a random point within the playable area is chosen.

 No required data fields.

 Example:
   AF.ScoutAttack(platoon, { Debug = true })

 ─────────────────────────────────────────────────────────────────────────────

 DefensePatrol(platoon, data)
 ─────────────────────────────
 Platoon follows a named marker chain repeatedly.

 Required data fields:
   Chain   string
     Name of the marker chain defined in the scenario.

 Optional data fields:
   Loop    bool  (default true)
     true   Follow the chain in a circle: after the last marker loop back to
            the first.
     false  Ping-pong: travel to the last marker then reverse back to the
            first before repeating.

   Investigate  bool  (default false)
     When true the platoon breaks off to engage enemy mobile units that come
     within InvestigateRadius of the current patrol waypoint, then resumes.

   InvestigateRadius  number  (default 60)
     Radius around each waypoint at which threats trigger investigation.

 Example:
   AF.DefensePatrol(platoon, {
       Chain             = 'SOUTH_PATROL',
       Loop              = false,
       Investigate       = true,
       InvestigateRadius = 80,
   })

================================================================================
]]

local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
local NavUtils      = import('/lua/sim/NavUtils.lua')
local Routing       = import('/maps/Platoon_testing.v0001/platoon_Routing.lua')

-- ============================================================
--  Constants
-- ============================================================
local DEFAULT_FORMATION  = 'NoFormation'
local SEARCH_RADIUS      = 10000    -- map-wide search radius
local DEF_CHECK_RADIUS   = 300      -- radius to look for defending structures
local CLUSTER_RADIUS     = 150      -- max distance between structures in a value cluster
local MIN_CLUSTER_SIZE   = 5        -- clusters of this size or fewer are fallback only
local ARRIVE_RADIUS      = 20       -- platoon is considered arrived within this distance
local SCOUT_GRID_CELLS   = 8        -- grid resolution for coolest-intel-point search
local INV_RADIUS_DEFAULT = 60       -- default investigation radius for DefensePatrol
local PATROL_STEP_LIMIT  = 90       -- seconds before giving up reaching a patrol waypoint

-- ============================================================
--  Structure category shortcuts
-- ============================================================
local CAT_ECO = categories.STRUCTURE * (categories.ENERGYPRODUCTION + categories.MASSEXTRACTION + categories.MASSFABRICATION)
local CAT_BLD = categories.STRUCTURE * (categories.FACTORY + categories.ENGINEERSTATION)
local CAT_INT = categories.STRUCTURE * (categories.RADAR + categories.SONAR + categories.OMNI)
local CAT_DEF = categories.STRUCTURE * categories.DEFENSE
local CAT_STR = categories.STRUCTURE - categories.WALL

local RAID_CATS  = { ECO = CAT_ECO, BLD = CAT_BLD, INT = CAT_INT, DEF = CAT_DEF }
local RAID_ORDER = { 'ECO', 'INT', 'BLD', 'DEF' }

-- ============================================================
--  Basic helpers
-- ============================================================
local function SafeWait(n)
    WaitSeconds(math.max(0.05, n or 0.5))
end

local function PlatoonAlive(platoon)
    if not platoon then return false end
    local brain = platoon:GetBrain()
    return brain and brain.PlatoonExists and brain:PlatoonExists(platoon)
end

local function MergeData(platoon, callData)
    local out = {}
    for k, v in pairs(platoon and platoon.PlatoonData or {}) do out[k] = v end
    for k, v in pairs(callData or {}) do out[k] = v end
    return out
end

local function DistSq(a, b)
    if not (a and b) then return math.huge end
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return dx * dx + dz * dz
end

local function Dist2D(a, b)
    return math.sqrt(DistSq(a, b))
end

-- ============================================================
--  Playable area
-- ============================================================
local function GetPlayableArea()
    if ScenarioInfo and ScenarioInfo.PlayableArea then
        return ScenarioInfo.PlayableArea
    end
    local size = ScenarioInfo and (ScenarioInfo.size or ScenarioInfo.MapSize)
    if size then return { 0, 0, size[1], size[2] } end
    return nil
end

local function RandomPointInPlayableArea()
    local area = GetPlayableArea()
    if not area then return { 0, 0, 0 } end
    local x = area[1] + Random() * (area[3] - area[1])
    local z = area[2] + Random() * (area[4] - area[2])
    return { x, GetTerrainHeight(x, z), z }
end

local function GetPlayableAreaCenter()
    local area = GetPlayableArea()
    if not area then return nil end
    local cx = (area[1] + area[3]) / 2
    local cz = (area[2] + area[4]) / 2
    return { cx, GetTerrainHeight(cx, cz), cz }
end

-- ============================================================
--  Enemy army helpers
-- ============================================================
local function ResolveEnemyBrains(brain, targetArmy)
    local allow = {}
    if type(targetArmy) == 'table' and table.getn(targetArmy) > 0 then
        for _, v in ipairs(targetArmy) do
            if type(v) == 'number' then
                allow[v] = true
            elseif type(v) == 'string' then
                for i, b in ipairs(ArmyBrains) do
                    if b and b.Nickname == v then allow[i] = true end
                end
            end
        end
    end
    local enemies = {}
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
    if not intelOnly then return true end
    if unit.IsSeenEver and unit:IsSeenEver(brain:GetArmyIndex()) then return true end
    if unit.GetBlip and unit:GetBlip(brain:GetArmyIndex()) then return true end
    return false
end

-- ============================================================
--  Platoon layer / domain helpers
-- ============================================================
local MOTION_TO_LAYER = {
    RULEUMT_Air              = 'AIR',
    RULEUMT_AirFighter       = 'AIR',
    RULEUMT_Water            = 'SEA',
    RULEUMT_SurfacingSub     = 'SEA',
    RULEUMT_Sub              = 'SEA',
    RULEUMT_Amphibious       = 'AMPHIBIOUS',
    RULEUMT_AmphibiousFloating = 'AMPHIBIOUS',
}

local function GetPlatoonLayer(platoon)
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    local lead = units[1]
    if lead and not lead.Dead then
        local bp = lead.GetBlueprint and lead:GetBlueprint()
        local mt = bp and bp.Physics and bp.Physics.MotionType
        if mt then
            local layer = MOTION_TO_LAYER[mt]
            if layer then return layer end
        end
    end
    return 'LAND'
end

local function GetNavLayerStr(layer)
    if layer == 'AIR'        then return 'Air'        end
    if layer == 'SEA'        then return 'Water'      end
    if layer == 'AMPHIBIOUS' then return 'Amphibious' end
    return 'Land'
end

local function IsPositionInWater(x, z)
    return GetSurfaceHeight(x, z) > GetTerrainHeight(x, z) + 0.5
end

-- ============================================================
--  Pathability
-- ============================================================
local function TryCanPath(navLayer, startPos, endPos)
    if not (NavUtils and NavUtils.CanPathTo and startPos and endPos) then return true end
    local ok, result = pcall(NavUtils.CanPathTo, navLayer, startPos[1], startPos[3], endPos[1], endPos[3])
    if ok and type(result) == 'boolean' then return result end
    ok, result = pcall(NavUtils.CanPathTo, navLayer, startPos, endPos)
    if ok and type(result) == 'boolean' then return result end
    return true
end

local function IsReachable(platoon, targetPos, opts, layer)
    if opts.Transport then return true end
    layer = layer or GetPlatoonLayer(platoon)
    if layer == 'AIR' then return true end
    local navLayer = GetNavLayerStr(layer)
    local pos = platoon:GetPlatoonPosition()
    if not pos then return true end
    return TryCanPath(navLayer, pos, targetPos)
end

-- ============================================================
--  Weapon range
-- ============================================================
local function GetPlatoonMaxWeaponRange(platoon)
    local maxRange = 0
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    for _, unit in ipairs(units) do
        if unit and not unit.Dead then
            local bp = unit.GetBlueprint and unit:GetBlueprint()
            local weapons = bp and bp.Weapon
            if weapons then
                for _, w in ipairs(weapons) do
                    local r = w.MaxRadius or 0
                    if r > maxRange then maxRange = r end
                end
            end
        end
    end
    return maxRange
end

-- ============================================================
--  Domain validation
-- ============================================================
local function IsNavalTarget(unit)
    if not unit then return false end
    return EntityCategoryContains(categories.NAVAL, unit)
end

local function IsValidDomain(platoon, unit, targetPos, opts, layer)
    layer = layer or GetPlatoonLayer(platoon)
    local inWater = IsPositionInWater(targetPos[1], targetPos[3])
    local isNaval = IsNavalTarget(unit)

    -- Bombard: cross-domain allowed when target is within weapon range
    if opts.Bombard then
        local platPos = platoon:GetPlatoonPosition()
        if platPos then
            local range = GetPlatoonMaxWeaponRange(platoon)
            if range > 0 and Dist2D(platPos, targetPos) <= range then
                return true
            end
        end
    end

    if layer == 'AIR'        then return true       end
    if layer == 'AMPHIBIOUS' then return true       end
    if layer == 'LAND'       then return (not inWater) and (not isNaval) end
    if layer == 'SEA'        then return inWater    end
    return true
end

-- ============================================================
--  Defense range check
-- ============================================================
local function IsInDefRange(brain, targetPos, opts)
    local enemies = ResolveEnemyBrains(brain, opts.TargetArmy)
    for _, enemy in ipairs(enemies) do
        local defs = enemy:GetUnitsAroundPoint(CAT_DEF, targetPos, DEF_CHECK_RADIUS, 'Enemy') or {}
        for _, def in ipairs(defs) do
            if def and not def.Dead then
                local bp = def.GetBlueprint and def:GetBlueprint()
                local weapons = bp and bp.Weapon
                if weapons then
                    for _, w in ipairs(weapons) do
                        local range = w.MaxRadius or 0
                        if range > 0 then
                            local defPos = def:GetPosition()
                            if defPos and Dist2D(defPos, targetPos) <= range then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- ============================================================
--  Enemy unit collection and filtering
-- ============================================================
local function CollectEnemyUnits(brain, center, radius, category, opts)
    local enemies = ResolveEnemyBrains(brain, opts.TargetArmy)
    local gathered = {}
    for _, enemy in ipairs(enemies) do
        local units = enemy:GetUnitsAroundPoint(category, center, radius, 'Enemy') or {}
        for _, u in ipairs(units) do
            if u and not u.Dead and CanSeeUnit(brain, u, opts.IntelOnly) then
                table.insert(gathered, u)
            end
        end
    end
    return gathered
end

local function FilterValidTargets(brain, platoon, units, opts, layer)
    layer = layer or GetPlatoonLayer(platoon)
    local out = {}
    for _, u in ipairs(units) do
        if u and not u.Dead then
            local pos = u:GetPosition()
            if pos and IsValidDomain(platoon, u, pos, opts, layer) and IsReachable(platoon, pos, opts, layer) then
                table.insert(out, u)
            end
        end
    end
    return out
end

-- Returns only safe targets.  Falls back to defended ones when none are safe.
local function FilterByAvoidDef(brain, units, opts)
    if not opts.AvoidDef then return units end
    local safe, defended = {}, {}
    for _, u in ipairs(units) do
        local pos = u:GetPosition()
        if pos then
            if IsInDefRange(brain, pos, opts) then
                table.insert(defended, u)
            else
                table.insert(safe, u)
            end
        end
    end
    if table.getn(safe) > 0 then return safe end
    return defended
end

-- ============================================================
--  Target selection helpers
-- ============================================================
local function FindClosestUnit(platoon, units)
    local platPos = platoon:GetPlatoonPosition()
    if not platPos then return nil end
    local best, bestDist = nil, math.huge
    for _, u in ipairs(units or {}) do
        if u and not u.Dead then
            local pos = u:GetPosition()
            if pos then
                local d = DistSq(platPos, pos)
                if d < bestDist then best, bestDist = u, d end
            end
        end
    end
    return best
end

local function GetUnitMassValue(unit)
    local bp = unit.GetBlueprint and unit:GetBlueprint()
    return (bp and bp.Economy and bp.Economy.BuildCostMass) or 100
end

-- For each unit treated as a potential cluster center, count members within
-- CLUSTER_RADIUS and sum their mass value.  Returns the center unit of:
--   1. The highest-value cluster with more than MIN_CLUSTER_SIZE members.
--   2. Fallback: the highest-value cluster of any size.
local function FindHighestValueCluster(platoon, units)
    if not units or table.getn(units) == 0 then return nil end

    local radSq = CLUSTER_RADIUS * CLUSTER_RADIUS
    local bestLarge, bestLargeScore = nil, -1
    local bestAny,   bestAnyScore   = nil, -1

    for _, center in ipairs(units) do
        if center and not center.Dead then
            local cPos = center:GetPosition()
            if cPos then
                local score, count = 0, 0
                for _, u in ipairs(units) do
                    if u and not u.Dead then
                        local uPos = u:GetPosition()
                        if uPos and DistSq(cPos, uPos) <= radSq then
                            count = count + 1
                            score = score + GetUnitMassValue(u)
                        end
                    end
                end
                if score > bestAnyScore then
                    bestAny, bestAnyScore = center, score
                end
                if count > MIN_CLUSTER_SIZE and score > bestLargeScore then
                    bestLarge, bestLargeScore = center, score
                end
            end
        end
    end

    return bestLarge or bestAny
end

-- ============================================================
--  Marker helpers
-- ============================================================
local function ResolveMarkerPosition(marker)
    if type(marker) == 'string' then
        return ScenarioUtils.MarkerToPosition(marker)
    elseif type(marker) == 'table' then
        if marker.position then return marker.position end
        if marker.Position then return marker.Position end
        if marker[1] and marker[3] then return marker end
    end
    return nil
end

-- ============================================================
--  Movement helpers
-- ============================================================
local function IssuePlatoonMove(platoon, dest, formation, aggressive)
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 or not dest then return end
    if formation and formation ~= 'NoFormation' then
        if aggressive then
            IssueFormAggressiveMove(units, dest, formation, 0)
        else
            IssueFormMove(units, dest, formation)
        end
    else
        if aggressive then
            IssueAggressiveMove(units, dest)
        else
            IssueMove(units, dest)
        end
    end
end

-- Air platoons orbit (patrol) the position; all other layers move to it.
local function HoldAtPosition(platoon, pos, opts)
    if not pos then return end
    local units = platoon and platoon.GetPlatoonUnits and platoon:GetPlatoonUnits() or {}
    if table.getn(units) == 0 then return end
    IssueClearCommands(units)
    if GetPlatoonLayer(platoon) == 'AIR' then
        IssuePatrol(units, pos)
    else
        IssueMove(units, pos)
    end
end

local function RoutePlatoon(platoon, opts, dest)
    if not (Routing and Routing.RoutePlatoonToTarget) then
        IssuePlatoonMove(platoon, dest, opts.Formation or DEFAULT_FORMATION, opts.AggressiveMove)
        return { Assault = false }
    end
    local payload = {}
    for k, v in pairs(opts) do payload[k] = v end
    payload.Platoon        = platoon
    payload.TargetPosition = { dest[1], dest[2], dest[3] }
    payload.CurrentPosition = platoon:GetPlatoonPosition()
    return Routing.RoutePlatoonToTarget(platoon, payload)
end

-- ============================================================
--  Coolest intel point (for ScoutAttack)
-- ============================================================
-- Samples a grid over the playable area and returns the point
-- with the fewest known enemy units nearby — the least-explored area.
local function FindCoolestIntelPoint(brain)
    local area = GetPlayableArea()
    if not area then return nil end

    local mapW = area[3] - area[1]
    local mapH = area[4] - area[2]
    local cellW = mapW / SCOUT_GRID_CELLS
    local cellH = mapH / SCOUT_GRID_CELLS

    local best, bestScore = nil, math.huge
    for gx = 0, SCOUT_GRID_CELLS - 1 do
        for gz = 0, SCOUT_GRID_CELLS - 1 do
            local x = area[1] + (gx + 0.5) * cellW
            local z = area[2] + (gz + 0.5) * cellH
            local pos = { x, GetTerrainHeight(x, z), z }
            local known = brain:GetNumUnitsAroundPoint(categories.ALLUNITS, pos, cellW * 0.8, 'Enemy') or 0
            if known < bestScore then
                best, bestScore = pos, known
            end
        end
    end
    return best
end

-- ============================================================
--  RaidAttack priority builder
-- ============================================================
local function BuildRaidPriority(typeName)
    local key = type(typeName) == 'string' and string.upper(typeName) or ''
    local out = {}
    if key ~= '' and RAID_CATS[key] then
        table.insert(out, key)
    end
    for _, k in ipairs(RAID_ORDER) do
        if k ~= key then table.insert(out, k) end
    end
    return out
end

-- ============================================================
--  HuntAttack list resolver
-- ============================================================
-- Returns a filter function(unit) -> bool built from a mixed list of
-- blueprint ID strings and/or category expressions.
local function BuildHuntFilter(list)
    local bpSet = {}
    local cats  = {}
    for _, entry in ipairs(list or {}) do
        if type(entry) == 'string' then
            bpSet[string.lower(entry)] = true
        else
            table.insert(cats, entry)
        end
    end

    local hasBPs  = next(bpSet) ~= nil
    local hasCats = table.getn(cats) > 0

    return function(unit)
        if hasBPs then
            local bp = unit.GetBlueprint and unit:GetBlueprint()
            local id = bp and bp.BlueprintId
            if id and bpSet[string.lower(id)] then return true end
            if unit.BlueprintID and bpSet[string.lower(unit.BlueprintID)] then return true end
        end
        if hasCats then
            for _, cat in ipairs(cats) do
                if EntityCategoryContains(cat, unit) then return true end
            end
        end
        -- Empty list matches everything
        return not hasBPs and not hasCats
    end
end

-- ============================================================
--  WaveAttack
-- ============================================================
function WaveAttack(platoon, data)
--[[
    Constant pressure attack.  Selects an enemy structure cluster, moves to it,
    clears it, then selects the next cluster and repeats.

    Type = 'Closest' : nearest cluster to the platoon.
    Type = 'Value'   : highest mass-value cluster (ignoring clusters ≤ 5
                       unless nothing larger exists).

    All global options apply (TargetArmy, IntelOnly, Formation, etc.).
]]
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts     = MergeData(platoon, data)
    local layer    = GetPlatoonLayer(platoon)
    local useValue = type(opts.Type) == 'string' and string.upper(opts.Type) == 'VALUE'
    local fallback = GetPlayableAreaCenter()

    while PlatoonAlive(platoon) do
        local platPos    = platoon:GetPlatoonPosition() or { 0, 0, 0 }
        local candidates = CollectEnemyUnits(brain, platPos, SEARCH_RADIUS, CAT_STR, opts)
        candidates = FilterValidTargets(brain, platoon, candidates, opts, layer)

        local target
        if useValue then
            target = FindHighestValueCluster(platoon, candidates)
        else
            target = FindClosestUnit(platoon, candidates)
        end

        if target and not target.Dead then
            local pos = target:GetPosition()
            if pos then
                local result = RoutePlatoon(platoon, opts, pos)
                if result and result.Assault then
                    local units = platoon:GetPlatoonUnits() or {}
                    if table.getn(units) > 0 and not target.Dead then
                        IssueClearCommands(units)
                        IssueAttack(units, target)
                    end
                end
            end
            SafeWait(2)
        else
            if fallback then HoldAtPosition(platoon, fallback, opts) end
            SafeWait(4)
        end
    end
end

-- ============================================================
--  RaidAttack
-- ============================================================
function RaidAttack(platoon, data)
--[[
    Category-focused raider.  Targets the closest structure of the specified
    type.  Falls back through: Specified → ECO → INT → BLD → DEF.

    Type     = 'ECO' | 'BLD' | 'INT' | 'DEF'
    AvoidDef = true  avoids targets inside defensive weapon coverage.

    All global options apply.
]]
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts     = MergeData(platoon, data)
    local layer    = GetPlatoonLayer(platoon)
    local priority = BuildRaidPriority(opts.Type)
    local fallback = GetPlayableAreaCenter()

    while PlatoonAlive(platoon) do
        local platPos = platoon:GetPlatoonPosition() or { 0, 0, 0 }
        local target  = nil

        for _, key in ipairs(priority) do
            local cat = RAID_CATS[key]
            if cat then
                local candidates = CollectEnemyUnits(brain, platPos, SEARCH_RADIUS, cat, opts)
                candidates = FilterValidTargets(brain, platoon, candidates, opts, layer)
                candidates = FilterByAvoidDef(brain, candidates, opts)
                target = FindClosestUnit(platoon, candidates)
                if target then break end
            end
        end

        if target and not target.Dead then
            local pos = target:GetPosition()
            if pos then
                local result = RoutePlatoon(platoon, opts, pos)
                if result and result.Assault then
                    local units = platoon:GetPlatoonUnits() or {}
                    if table.getn(units) > 0 and not target.Dead then
                        IssueClearCommands(units)
                        IssueAttack(units, target)
                    end
                end
            end
            SafeWait(2)
        else
            if fallback then HoldAtPosition(platoon, fallback, opts) end
            SafeWait(4)
        end
    end
end

-- ============================================================
--  HuntAttack
-- ============================================================
function HuntAttack(platoon, data)
--[[
    Hunts a specified list of unit blueprints and/or categories.
    When no valid target exists the platoon holds at WaitMarker.
    Air platoons circle the marker.

    List       = { 'bp_id', categories.CAT, ... }  -- mixed list
    WaitMarker = 'MARKER_NAME'
    AvoidDef   = true  skip targets inside defensive coverage.

    All global options apply.
]]
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts    = MergeData(platoon, data)
    local layer   = GetPlatoonLayer(platoon)
    local filter  = BuildHuntFilter(opts.List)
    local waitPos = ResolveMarkerPosition(opts.WaitMarker or opts.Marker)

    while PlatoonAlive(platoon) do
        local platPos    = platoon:GetPlatoonPosition() or { 0, 0, 0 }
        local candidates = CollectEnemyUnits(brain, platPos, SEARCH_RADIUS, categories.ALLUNITS - categories.WALL, opts)
        candidates = FilterValidTargets(brain, platoon, candidates, opts, layer)

        local filtered = {}
        for _, u in ipairs(candidates) do
            if filter(u) then table.insert(filtered, u) end
        end
        filtered = FilterByAvoidDef(brain, filtered, opts)

        local target = FindClosestUnit(platoon, filtered)
        if target and not target.Dead then
            local pos = target:GetPosition()
            if pos then
                local result = RoutePlatoon(platoon, opts, pos)
                if result and result.Assault then
                    local units = platoon:GetPlatoonUnits() or {}
                    if table.getn(units) > 0 and not target.Dead then
                        IssueClearCommands(units)
                        IssueAttack(units, target)
                    end
                end
            end
            SafeWait(2)
        else
            if waitPos then HoldAtPosition(platoon, waitPos, opts) end
            SafeWait(5)
        end
    end
end

-- ============================================================
--  ScoutAttack
-- ============================================================
function ScoutAttack(platoon, data)
--[[
    Roaming scout patrol.  Each cycle the platoon has a 25 % chance to move
    toward the least-explored point on the intel map; otherwise it moves to a
    random point within the playable area.

    All global options apply.
]]
    local brain = platoon and platoon:GetBrain()
    local opts  = MergeData(platoon, data)

    while PlatoonAlive(platoon) do
        local dest
        if brain and Random(1, 100) <= 25 then
            dest = FindCoolestIntelPoint(brain)
        end
        dest = dest or RandomPointInPlayableArea()

        RoutePlatoon(platoon, opts, dest)
        SafeWait(8)
    end
end

-- ============================================================
--  DefensePatrol
-- ============================================================
function DefensePatrol(platoon, data)
--[[
    Follows a named marker chain repeatedly.

    Chain             = 'CHAIN_NAME'
    Loop              = true   circular (last marker → first)
                      = false  ping-pong (reverse at each end)
    Investigate       = true   engage enemies that approach the chain
    InvestigateRadius = 60     threat detection radius per waypoint

    All global options apply.
]]
    local brain = platoon and platoon:GetBrain()
    if not brain then return end
    local opts = MergeData(platoon, data)

    local chain = opts.Chain or opts.ChainName
    if not chain then
        if opts.Debug then LOG('[DefensePatrol] No Chain specified.') end
        return
    end

    local markers = ScenarioUtils.ChainToPositions(chain) or {}
    local count   = table.getn(markers)
    if count == 0 then
        if opts.Debug then LOG('[DefensePatrol] Chain "' .. tostring(chain) .. '" has no markers.') end
        return
    end

    local loop        = opts.Loop ~= false    -- default true
    local investigate = opts.Investigate and true or false
    local invRadius   = opts.InvestigateRadius or INV_RADIUS_DEFAULT
    local formation   = opts.Formation or DEFAULT_FORMATION

    local idx = 1   -- current waypoint index
    local dir = 1   -- ping-pong direction (+1 or -1)

    while PlatoonAlive(platoon) do
        local wp = markers[idx]
        if wp then
            -- Issue move to this waypoint
            local units = platoon:GetPlatoonUnits() or {}
            if table.getn(units) > 0 then
                IssueClearCommands(units)
                IssuePlatoonMove(platoon, wp, formation, opts.AggressiveMove)
            end

            -- Wait until arrived or timeout, investigating threats if enabled
            local deadline = GetGameTimeSeconds() + PATROL_STEP_LIMIT
            while PlatoonAlive(platoon) and GetGameTimeSeconds() < deadline do
                local pos = platoon:GetPlatoonPosition()
                if pos and Dist2D(pos, wp) <= ARRIVE_RADIUS then break end

                if investigate and pos then
                    local threats = CollectEnemyUnits(brain, pos, invRadius, categories.MOBILE, opts)
                    local threat  = FindClosestUnit(platoon, threats)
                    if threat and not threat.Dead then
                        -- Break off to engage
                        units = platoon:GetPlatoonUnits() or {}
                        if table.getn(units) > 0 then
                            IssueClearCommands(units)
                            IssueAttack(units, threat)
                        end
                        -- Wait for the threat to be cleared
                        while PlatoonAlive(platoon) and threat and not threat.Dead do
                            SafeWait(2)
                        end
                        -- Resume move to waypoint
                        units = platoon:GetPlatoonUnits() or {}
                        if table.getn(units) > 0 then
                            IssueClearCommands(units)
                            IssuePlatoonMove(platoon, wp, formation, false)
                        end
                        deadline = GetGameTimeSeconds() + PATROL_STEP_LIMIT
                    end
                end

                SafeWait(1)
            end
        end

        -- Advance to next waypoint index
        if loop then
            idx = math.fmod(idx, count) + 1
        else
            idx = idx + dir
            if idx > count then
                idx = count - 1
                dir = -1
            elseif idx < 1 then
                idx = 2
                dir = 1
            end
        end
    end
end

return {
    WaveAttack    = WaveAttack,
    RaidAttack    = RaidAttack,
    HuntAttack    = HuntAttack,
    ScoutAttack   = ScoutAttack,
    DefensePatrol = DefensePatrol,
}
