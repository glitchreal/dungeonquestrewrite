-- Interfaces verified against Dungeon Quest Reborn's client queue/inventory scripts.
local Adapter = {}
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local PM = require(RS:WaitForChild("Utility"):WaitForChild("PlaceManager"))
local remotes = RS:WaitForChild("remotes")
Adapter.Remotes = remotes
Adapter.PlaceManager = PM

function Adapter.value(root, name, fallback)
    local child = root and root:FindFirstChild(name)
    if child and child:IsA("ValueBase") then return child.Value end
    return fallback
end

function Adapter.level()
    if Adapter.value(player, "dataLoaded", true) == false then return nil end
    return Adapter.value(player:FindFirstChild("leaderstats"), "Level", nil)
end

function Adapter.balances()
    local stats = player:FindFirstChild("leaderstats")
    return { Coins = Adapter.value(stats, "Gold", 0), Gems = Adapter.value(stats, "Gems", 0), Levels = Adapter.level() or 0 }
end

function Adapter.call(name, ...)
    local remote = remotes:FindFirstChild(name)
    if not remote then error("Game interface unavailable: " .. name) end
    if remote:IsA("RemoteFunction") then return remote:InvokeServer(...) end
    remote:FireServer(...)
    return true
end

function Adapter.inventory()
    local inventory = Adapter.call("reloadInvy")
    assert(type(inventory) == "table", "Inventory is not loaded")
    return inventory
end

function Adapter.dungeons()
    local names = {}
    local gui = player.PlayerGui:FindFirstChild("queueGui")
    local choose = gui and gui:FindFirstChild("chooseDungeon")
    local left = choose and choose:FindFirstChild("backgroundFillLeft")
    local list = left and left:FindFirstChild("ScrollingFrame")
    if list then
        for _, row in ipairs(list:GetChildren()) do
            if row:IsA("ImageLabel") and row:FindFirstChild("TextButton") and row.Name ~= "Tutorial Dungeon" then
                table.insert(names, row.Name)
            end
        end
    end
    table.sort(names)
    return names
end

local dungeonStats = {}
function Adapter.dungeonStats(name)
    if dungeonStats[name] then return dungeonStats[name] end
    local result = Adapter.call("getDungeonStats", name)
    assert(type(result) == "table", "Dungeon requirements unavailable")
    dungeonStats[name] = result
    return result
end

function Adapter.findLobby(raid)
    local games = workspace:FindFirstChild(raid and "bossLobbies" or "games")
    if not games then return nil end
    local list = raid and games or games:FindFirstChild("inLobby")
    if not list then return nil end
    for _, lobby in ipairs(list:GetChildren()) do
        local members = raid and lobby:FindFirstChild("players") or lobby
        if lobby.Name == player.Name or (members and members:FindFirstChild(player.Name)) then return lobby end
    end
    return nil
end

function Adapter.createLobby(config)
    local level = Adapter.level()
    assert(level, "Player level is not loaded")
    local stats = Adapter.dungeonStats(config.Dungeon)
    local selected = stats[config.Difficulty]
    assert(type(selected) == "table" and tonumber(selected.levelReq), "Select an available difficulty")
    assert(level >= tonumber(selected.levelReq), "This difficulty requires level " .. tostring(selected.levelReq))
    return Adapter.call("createLobby", config.Dungeon, config.Difficulty, tonumber(selected.levelReq), config.Hardcore and not config.WaveDefence, config.PrivateLobby, config.WaveDefence)
end

function Adapter.replayData()
    local data = {}
    local teleport = PM.GetPlaceTeleportData()
    for k, v in pairs(teleport and teleport.dungeonStats or {}) do data[k] = v end
    for _, name in ipairs({ "dungeonName", "dungeonProgress", "dungeonStarted", "hardcore" }) do
        local value = Adapter.value(workspace, name, nil)
        if value ~= nil then data[name] = value end
    end
    local dungeon = workspace:FindFirstChild("dungeon")
    if dungeon then
        for _, container in ipairs({ dungeon, dungeon:FindFirstChild("bossRoom") }) do
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("ValueBase") then data[child.Name] = child.Value end
            end
        end
    end
    assert(type(data.dungeonName) == "string", "Run data is not available")
    return data
end

function Adapter.finished()
    if Adapter.value(workspace, "dungeonProgress", "") == "bossKilled" then return true end
    local dungeon = workspace:FindFirstChild("dungeon")
    local boss = dungeon and dungeon:FindFirstChild("bossRoom")
    return Adapter.value(boss, "dungeonFinished", false) == true
end

function Adapter.replay(advance)
    assert(PM.IsDungeonOwner(player), "Only the dungeon owner can replay")
    local data = Adapter.replayData()
    if advance and PM.IsBossKey() then
        local nextTier = Adapter.call("checkNextTierKey")
        data.advanceTier = type(nextTier) == "table" and nextTier.eligible == true
    end
    return Adapter.call("replayDungeon", data)
end

return Adapter
