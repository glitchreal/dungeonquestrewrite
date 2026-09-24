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
    local numericId = tonumber(token)
    for _, current in ipairs(Players:GetPlayers()) do
        if numericId == current.UserId or not numericId and current.Name:lower() == key then
            local result = { id = current.UserId, name = current.Name }
            identities[key] = result
            return result
        end
    end
    local id = numericId or Players:GetUserIdFromNameAsync(token)
    assert(id and id > 0 and id % 1 == 0, "Invalid account: " .. token)
    local result = { id = id, name = numericId and Players:GetNameFromUserIdAsync(id) or token }
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

function Adapter.findLobby(name)
    local games = workspace:FindFirstChild("games")
    local list = games and games:FindFirstChild("inLobby")
    if list then return list:FindFirstChild(name or player.Name) end
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

-- Lobby membership and global listings are the same evidence used by queue UI.
function Adapter.lobbyMembers(lobby)
    local members = {}
    if not lobby then return members end
    local encoded = lobby:GetAttribute("Roster")
    if type(encoded) == "string" then
        local ok, rows = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), encoded)
        if ok and type(rows) == "table" then
            for _, row in pairs(rows) do
                if type(row.n) == "string" then members[row.n:lower()] = tonumber(row.l) or true end
            end
        end
    end
    for _, child in ipairs(lobby:GetChildren()) do
        if child:IsA("StringValue") and child.Name ~= "mapName" then
            local who = Players:FindFirstChild(child.Name)
            members[child.Name:lower()] = who and Adapter.level(who) or members[child.Name:lower()] or true
        end
    end
    return members
end

local lobbySearchIndex = {}
function Adapter.joinLobby(hostName, dungeon, catalog)
    local lobby = Adapter.findLobby(hostName)
    if lobby then
        if Adapter.lobbyMembers(lobby)[player.Name:lower()] then return true, "Joined Host lobby; waiting for departure" end
        local map = lobby:FindFirstChild("mapName")
        local required = Adapter.value(map, "minLevelReq")
        if not required or not Adapter.level() or Adapter.level() < required then return false, "Host lobby level requirement unavailable or unmet" end
        local private = map and map:FindFirstChild("private")
        if private and private.Value and not private:FindFirstChild(player.Name) then return false, "Waiting for Host whitelist" end
        Adapter.call("joinDungeon", hostName)
        return true, "Joining Host lobby"
    end
    if dungeon and remotes:FindFirstChild("listGlobalParties") then
        local maps = {}
        for name in pairs(catalog or {}) do table.insert(maps, name) end
        table.sort(maps)
        local index = (lobbySearchIndex[hostName] or 0) % math.max(1, #maps) + 1
        lobbySearchIndex[hostName] = index
        local queries = { dungeon }
        if maps[index] and maps[index] ~= dungeon then table.insert(queries, maps[index]) end
        for _, mapName in ipairs(queries) do
        local listings = Adapter.call("listGlobalParties", mapName)
        for _, entry in ipairs(type(listings) == "table" and listings or {}) do
            if entry.ownerName == hostName and tonumber(entry.minLevelReq)
                and Adapter.level() and Adapter.level() >= tonumber(entry.minLevelReq) then
                local ok = Adapter.call("joinGlobalParty", entry.jobId, entry.ownerName)
                return ok ~= false, ok ~= false and "Joining Host global lobby" or "Host global lobby declined join; waiting"
            end
        end
        end
    end
    return false, "Lobby reforming: waiting for a joinable Host lobby"
end

function Adapter.currentDungeon()
    local teleport = PM.GetPlaceTeleportData()
    local data = teleport and teleport.dungeonStats or {}
    return { Dungeon = Adapter.value(workspace, "dungeonName", data.dungeonName),
        Difficulty = Adapter.value(workspace, "difficulty", data.difficulty),
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
    if player.PlayerGui:FindFirstChild("completeGui") then return true end
    if Adapter.value(workspace, "dungeonProgress", "") == "bossKilled" then return true end
    local dungeon = workspace:FindFirstChild("dungeon")
    return Adapter.value(dungeon and dungeon:FindFirstChild("bossRoom"), "dungeonFinished", false) == true
end

-- PlaceManager has no IsDungeonOwner in the inspected client. The game's replay
-- UI checks teleport.ownerId; prefer replicated active ownership when available.
function Adapter.started()
    if Adapter.value(workspace, "dungeonStarted", nil) == nil then return nil end
    return PM.HasDungeonStarted()
end

function Adapter.replay()
    local owner = Adapter.ownerId()
    if owner and owner ~= player.UserId then return false, "Active dungeon owner is another account" end
    if not Adapter.finished() then return false, "Dungeon completion has not replicated" end
    local teleport = PM.GetPlaceTeleportData()
    local data = table.clone(teleport and teleport.dungeonStats or {})
    for _, name in ipairs({ "dungeonName", "dungeonProgress", "dungeonStarted", "hardcore" }) do
        local value = Adapter.value(workspace, name, nil)
        if value ~= nil then data[name] = value end
    end
    data.isHardcore = data.hardcore
    local dungeon = workspace:FindFirstChild("dungeon")
    for _, container in pairs({ dungeon, dungeon and dungeon:FindFirstChild("bossRoom") }) do
        for _, value in ipairs(container:GetChildren()) do
            if value:IsA("ValueBase") then data[value.Name] = value.Value end
        end
    end
    if type(data.dungeonName) ~= "string" then return false, "Run data unavailable" end
    -- Same payload/remote as ReplayDungeonButton; server validates ownership.
    return Adapter.call("replayDungeon", data)
end

Adapter.PermanentBoosts = {
    { name = "x2 Gold", key = "goldGamepass" },
    { name = "+1 Drop", key = "extraItemGamepass" },
    { name = "VIP", key = "vip" },
}
Adapter.XPBoosts = {
    { name = "XP 1h", id = 1013086750 }, { name = "XP 2h", id = 1013086878 }, { name = "XP 4h", id = 1013087251 },
}
function Adapter.boostOffer(entry)
    return Adapter.call(entry.key and "getGoldGamepassPrice" or "getGoldXPBoostPrice", entry.key or entry.id)
end
function Adapter.buyBoost(entry, offer)
    if type(offer) ~= "table" or offer.ready == false then return false end
    -- Inspected gamepass interface charges Gold. Unknown/premium responses fail closed.
    if entry.key and offer.currency ~= nil and offer.currency ~= "gold" then return false end
    if not entry.key and offer.currency ~= "gold" then return false end
    if entry.key then return Adapter.call("requestGoldGamepassPurchase", entry.key) end
    return Adapter.call("requestGoldXPBoostPurchase", entry.id, "gold")
end
function Adapter.gold() return tonumber(Adapter.value(player:FindFirstChild("leaderstats"), "Gold")) end

return Adapter
