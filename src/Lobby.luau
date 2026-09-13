local MODE = "Lobby"
local function createController()
    local state = { running = false, status = "In lobby", kills = 0, cachedTargets = {} }
    return { Config = {}, State = state, SetRunning = function() state.running = false end,
        SetWaypoints = function() end, Shutdown = function() end }
end
