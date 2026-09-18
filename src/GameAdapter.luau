-- Game interfaces inspected in both lobby and dungeon clients, September 2026.
local Adapter = {}
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local PM = require(RS:WaitForChild("Utility"):WaitForChild("PlaceManager"))
local remotes = RS:WaitForChild("remotes")
Adapter.Remotes, Adapter.PlaceManager = remotes, PM

function Adapter.value(root, name, fallback)
    local child = root and root:FindFirstChild(name)
    if child and child:IsA("ValueBase") then return child.Value end
    return fallback
end

function Adapter.level(who)
    who = who or player
    if Adapter.value(who, "dataLoaded", true) == false then return nil end
    return tonumber(Adapter.value(who:FindFirstChild("leaderstats"), "Level", nil))
end

function Adapter.call(name, ...)
    local remote = remotes:FindFirstChild(name)
    assert(remote, "Game interface unavailable: " .. name)
    if remote:IsA("RemoteFunction") then return remote:InvokeServer(...) end
    remote:FireServer(...)
    return true
end

function Adapter.inventory(who)
    local inventory
    if who and who ~= player then inventory = Adapter.call("getOtherPlayersInvy", who)
    else inventory = Adapter.call("reloadInvy") end
    assert(type(inventory) == "table" and type(inventory.abilities) == "table", "Inventory is not loaded")
    return inventory
end

function Adapter.catalog()
    local gui = player.PlayerGui:FindFirstChild("queueGui")
    local choose = gui and gui:FindFirstChild("chooseDungeon")
    local left = choose and choose:FindFirstChild("backgroundFillLeft")
    local list = left and left:FindFirstChild("ScrollingFrame")
    assert(list, "Dungeon catalog unavailable; load once in the lobby")
    local catalog = {}
    for _, row in ipairs(list:GetChildren()) do
        if row:IsA("ImageLabel") and row:FindFirstChild("TextButton") and row.Name ~= "Tutorial Dungeon" then
            local stats = Adapter.call("getDungeonStats", row.Name)
            if type(stats) == "table" then
                catalog[row.Name] = {}
                for _, difficulty in ipairs(Logic.Difficulties) do
                    local data = stats[difficulty]
                    if type(data) == "table" and tonumber(data.levelReq) then
                        catalog[row.Name][difficulty] = { levelReq = tonumber(data.levelReq),
                            isEventPlace = data.isEventPlace, isBossKey = data.isBossKey }
                    end
                end
            end
        end
    end
    assert(next(catalog), "Waiting for dungeon catalog")
    return Logic.catalog(catalog)
end

local identities = {}
function Adapter.identity(token)
    token = token:match("^%s*(.-)%s*$")
    assert(token ~= "", "Enter the host, carry, and selected alt usernames")
    local key = token:lower()
    if identities[key] then return identities[key] end
    local id = tonumber(token) or Players:GetUserIdFromNameAsync(token)
    assert(id and id > 0 and id % 1 == 0, "Invalid account: " .. token)
    local result = { id = id, name = Players:GetNameFromUserIdAsync(id) }
    identities[key] = result
    return result
end

function Adapter.roster(config)
    local host, carry = Adapter.identity(config.Host), Adapter.identity(config.Carry)
    assert(host.id ~= carry.id, "Host and carry must be different accounts")
    local roster, seen = { host, carry }, { [host.id] = true, [carry.id] = true }
    for _, token in ipairs(Logic.tokens(config.Alts)) do
        local account = Adapter.identity(token)
        if not seen[account.id] then table.insert(roster, account); seen[account.id] = true end
    end
    assert(seen[player.UserId], "This account must be in the party list")
    assert(config.Role ~= "Host" or host.id == player.UserId, "Host role must match the host username")
    assert(config.Role ~= "Carry" or carry.id == player.UserId, "Carry role must match the carry username")
    assert(config.Role ~= "Alt" or player.UserId ~= host.id and player.UserId ~= carry.id, "Alt role must be a selected alt")
    return roster, host, carry
end

function Adapter.members(roster)
    local members = {}
    for _, account in ipairs(roster) do
        local who = Players:GetPlayerByUserId(account.id)
        table.insert(members, { id = account.id, name = account.name, present = who ~= nil,
            level = who and Adapter.level(who), player = who })
    end
    return members
end

function Adapter.findLobby()
    local games = workspace:FindFirstChild("games")
    local list = games and games:FindFirstChild("inLobby")
    if list then return list:FindFirstChild(player.Name) end
end

function Adapter.lobbyMatches(lobby, selection, config)
    local map = lobby and lobby:FindFirstChild("mapName")
    return Adapter.value(lobby, "mapName") == selection.Dungeon
        and Adapter.value(map, "difficulty") == selection.Difficulty
        and Adapter.value(map, "hardcore") == config.Hardcore
        and Adapter.value(map, "private") == config.Whitelist
        and Adapter.value(map, "waveDefence", false) == false
end

function Adapter.createLobby(selection, config)
    local level = assert(Adapter.level(), "Player level is not loaded")
    assert(selection and level >= selection.levelReq, "Dungeon is locked at your level")
    return Adapter.call("createLobby", selection.Dungeon, selection.Difficulty, selection.levelReq,
        config.Hardcore, config.Whitelist, false)
end

function Adapter.currentDungeon()
    local teleport = PM.GetPlaceTeleportData()
    local data = teleport and teleport.dungeonStats or {}
    return { Dungeon = Adapter.value(workspace, "dungeonName", data.dungeonName), Difficulty = data.difficulty,
        levelReq = tonumber(data.levelReq) }
end

function Adapter.ownerId()
    -- Join-request arrivals may omit the original owner in teleport data.
    -- The server's active owner is authoritative, including ownership changes.
    local active = tonumber(RS:GetAttribute("ActiveDungeonOwnerId"))
    if active and active > 0 then return active end
    if type(PM.GetDungeonOwnerId) == "function" then
        local id = tonumber(PM.GetDungeonOwnerId())
        if id and id > 0 then return id end
    end
    local teleport = PM.GetPlaceTeleportData()
    local id = teleport and (tonumber(teleport.ownerId)
        or type(teleport.dungeonStats) == "table" and tonumber(teleport.dungeonStats.ownerId))
    return id and id > 0 and id or nil
end

function Adapter.pendingRequests()
    local pending = {}
    for _, gui in ipairs(player.PlayerGui:GetChildren()) do
        local id = gui.Name:match("^joinRequestConfirm_(.+)$")
        if id and gui:IsA("ScreenGui") and gui.Enabled then
            local frame = gui:FindFirstChild("Frame")
            local body = frame and frame:FindFirstChild("Frame")
            local status = body and body:FindFirstChild("status")
            local name = status and Logic.requestUsername(status.Text)
            if name then table.insert(pending, { id = tonumber(id) or id, name = name, prompt = gui }) end
        end
    end
    return pending
end

function Adapter.failed()
    return player.PlayerGui:FindFirstChild("failedGui") ~= nil
end

function Adapter.finished()
    if Adapter.value(workspace, "dungeonProgress", "") == "bossKilled" then return true end
    local dungeon = workspace:FindFirstChild("dungeon")
    return Adapter.value(dungeon and dungeon:FindFirstChild("bossRoom"), "dungeonFinished", false) == true
end

function Adapter.replay()
    assert(PM.IsDungeonOwner(player), "Only the host can replay")
    local teleport = PM.GetPlaceTeleportData()
    local data = table.clone(teleport and teleport.dungeonStats or {})
    assert(type(data.dungeonName) == "string", "Run data unavailable")
    for _, name in ipairs({ "dungeonName", "dungeonProgress", "dungeonStarted", "hardcore" }) do
        local value = Adapter.value(workspace, name, nil)
        if value ~= nil then data[name] = value end
    end
    return Adapter.call("replayDungeon", data)
end

return Adapter
