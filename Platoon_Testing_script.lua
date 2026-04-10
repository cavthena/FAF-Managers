--General Imports
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
local Utilities = import('/lua/utilities.lua')
local ScenarioFramework = import('/lua/ScenarioFramework.lua')

local BuildMgr = import('/maps/Platoon_testing.v0001/manager_UnitBuilder.lua')
local SpawnMgr = import('/maps/Platoon_testing.v0001/manager_UnitSpawner.lua')
local EngiMgr = import('/maps/Platoon_testing.v0001/manager_BaseEngineer.lua')
local plaAtk = import('/maps/Platoon_testing.v0001/platoon_AttackFunctions.lua')
--local Routing = import('/maps/Platoon_testing.v0001/platoon_Routing.lua')

--Locals
local Difficulty = ScenarioInfo.Options.Difficulty
local Debug = true

function OnPopulate()
    --Set colors, setup armies and set coop.
    ScenarioUtils.InitializeScenarioArmies()
    local tblArmy = ListArmies()
    for i, name in ipairs(tblArmy) do
        ScenarioInfo[name] = i
        if Debug then
            LOG(string.format('Assigned ScenarioInfo.%s = %d', name, i))
        end
    end

    local colors = {
        ['Player1'] = {41, 41, 225},
        ['Cybran'] = {128, 39, 37},
    }
    for name, color in pairs(colors) do
        if tblArmy[ScenarioInfo[name]] then
            ScenarioFramework.SetArmyColor(ScenarioInfo[name], unpack(color))
        end
    end

    -- Hide all scores
    for i = 1, table.getn(ArmyBrains) do
        SetArmyShowScore(i, false)
    end

    --AI Unit Cap
    SetArmyUnitCap(ScenarioInfo.Cybran, 1000)
    if Debug then
        LOG('Cybran army cap set to 1000.')
    end

    Utilities.UserConRequest('SallyShears')

    ScenarioFramework.SetPlayableArea('AREA_2' , false)
end

function OnStart(scenario)
    --Create UEF Base
    ScenarioUtils.CreateArmyGroup('Player1', 'BaseTarget')

    --Start Cybran Base
    CybranBase_AI()

    ScenarioFramework.CreateTimerTrigger(function()
        CybranSpawn_NW()
    end, 10)

    ScenarioFramework.CreateTimerTrigger(function()
        CybranBuild_Main()
    end, 15)
end

function CybranBase_AI()
    ScenarioInfo.CBEngi = EngiMgr.Start({
        brain = ArmyBrains[ScenarioInfo.Cybran],
        baseMarker = 'CybranBase',
        baseTag = 'CBBase',
        radius = 26,
        structGroups = {'CybranBase'},
        engineers = {
            T1 = 4,
            T2 = 2,
            T3 = 0,
            SCU = 0,
        },
        engineerFactoryPriority = 200,
        engineerFactoryCount = 1,
        tasks = {
            weights = {BUILD = 1.5, ASIST = 1, EXP = 0},
        },
    })
end

function CybranSpawn_NW()
    ScenarioInfo.CybranNWAttack = SpawnMgr.Start{
        brain = ArmyBrains[ScenarioInfo.Cybran],
        spawnMarker = 'Spawn_TopWest',
        composition = {
            {'url0106', 3},
        },
        attackFn = plaAtk.WaveAttack,
        attackData = {
            Type = 'Closest',
            Formation = 'NoFormation',
            Debug = true,
        },
        waveCooldown = 5,
        mode = 2,
        mode2LossThreshold = 1,
        spawnerTag = 'CybranNWAttack',
        spawnSpread = 2,
        debug = true,
    }
end

function CybranBuild_Main()
    ScenarioInfo.CybranBuildAtk = BuildMgr.Start({
        brain = ArmyBrains[ScenarioInfo.Cybran],
        baseMarker = 'CybranBase',
        domain = 'LAND',
        composition = {
            {'url0107', 4},
        },
        baseHandle = ScenarioInfo.CBEngi,
        wantFactories = 2,
        priority = 100,
        radius = 26,
        rallyMarker = 'CybranBase_Rally2',
        waveCooldown = 5,
        attackFn = plaAtk.WaveAttack,
        attackData = {
            Type = 'Value',
            Formation = 'AttackFormation',
            AggressiveMove = true,
            Debug = true,
        },
        builderTag = 'CybranBuildAtk',
        mode = 2,
        mode2LossThreshold = 1,
        debug = true,
    })
end