local MODE = "Dungeon"

local function queueAction(config, now, arrivedAt)
    local pm = Adapter.PlaceManager
    if (config.AutoStart or config.AutoRaid and pm.IsBossKey())
        and pm.IsDungeonOwner(game:GetService("Players").LocalPlayer)
        and now - arrivedAt >= config.StartDelay then
        Adapter.call("changeStartValue")
        return "Starting dungeon"
    end
    return "Waiting for dungeon start"
end
