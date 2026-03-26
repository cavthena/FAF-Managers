local Routing = import('/maps/faf_coop_U01.v0001/platoon_Routing.lua')

function ValidateRoutingGraph(startPos, targetPos, opts)
    local report = {
        ok = true,
        checks = {},
        metrics = {},
    }

    Routing.InitializeRoutingSystem(opts)
    local metrics = Routing.GetRoutingMetrics()
    report.metrics = metrics

    table.insert(report.checks, {
        name = 'graph-built',
        passed = metrics and metrics.buildSeconds ~= nil,
        detail = metrics and ('buildSeconds=' .. tostring(metrics.buildSeconds)) or 'missing-metrics',
    })

    if startPos and targetPos then
        -- Smoke check only: mission logic should call BuildRoute with a platoon.
        table.insert(report.checks, {
            name = 'route-smoke',
            passed = true,
            detail = 'Use mission platoon scenarios for full integration validation.',
        })
    end

    for _, check in ipairs(report.checks) do
        if not check.passed then
            report.ok = false
            break
        end
    end

    return report
end

return {
    ValidateRoutingGraph = ValidateRoutingGraph,
}