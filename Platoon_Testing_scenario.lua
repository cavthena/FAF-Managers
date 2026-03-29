version = 3 -- Lua Version. Dont touch this
ScenarioInfo = {
    name = "Platoon_Testing",
    description = "Testing Environment",
    preview = '',
    map_version = 1,
    type = 'campaign_coop',
    starts = true,
    size = {256, 256},
    reclaim = {33027.3, 0},
    map = '/maps/Platoon_Testing.v0001/Platoon_Testing.scmap',
    save = '/maps/Platoon_Testing.v0001/Platoon_Testing_save.lua',
    script = '/maps/Platoon_Testing.v0001/Platoon_Testing_script.lua',
    norushradius = 40,
    Configurations = {
        ['standard'] = {
            teams = {
                {
                    name = 'FFA',
                    armies = {'Player1', 'Cybran'}
                },
            },
            customprops = {
                ['ExtraArmies'] = STRING( 'ARMY_17 NEUTRAL_CIVILIAN' ),
            },
            factions = {
                {'uef'},
            },
        },
    },
}
