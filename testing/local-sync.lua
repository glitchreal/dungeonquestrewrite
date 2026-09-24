-- Shared executor files must coordinate accounts without enabling an HTTP relay.
table.clone = table.clone or function(value)
    local copy = {}
    for key, item in pairs(value) do copy[key] = item end
    return copy
end

local Logic = dofile("src/HubLogic.luau")
local files, folders = {}, {}
local roster = { { id = 1, name = "Host" }, { id = 2, name = "Carry" }, { id = 3, name = "Alt" } }
local function client(id, role)
    local config = { Enabled = true, Role = role, Host = "Host", Carry = "Carry", Alts = "Alt",
        SyncEnabled = false, RequireScriptsReady = true, SyncURL = "", SyncKey = "" }
    local http = {
        JSONEncode = function(_, value) return value end,
        JSONDecode = function(_, value) return value end,
        GenerateGUID = function() return "test-command" end,
    }
    local globals = setmetatable({
        Logic = Logic,
        game = { JobId = "job", PlaceId = 10, GetService = function(_, name)
            if name == "HttpService" then return http end
            return { LocalPlayer = { UserId = id } }
        end },
        task = { spawn = function() end },
        isfile = function(path) return files[path] ~= nil end,
        readfile = function(path) return files[path] end,
        writefile = function(path, value) files[path] = value end,
        isfolder = function(path) return folders[path] == true end,
        makefolder = function(path) folders[path] = true end,
    }, { __index = _G })
    local sync = assert(loadfile("src/PartySync.luau", "t", globals))().new(config, "Dungeon", function() return true end)
    sync.Update(roster, roster[1], roster[2], true, 2, "PRE_START", { Dungeon = "Northern Lands" })
    sync.SetPhase("PRE_START")
    return sync
end

local host = client(1, "Host")
assert(not host.Ready(roster), "Required scripts must wait for missing local heartbeats")
local carry = client(2, "Carry")
local alt = client(3, "Alt")
assert(host.Ready(roster) and carry.Ready(roster) and alt.Ready(roster),
    "Shared workspace should satisfy readiness without enabling relay sync")
assert(carry.Member(1).phase == "PRE_START", "Followers should read Host phase from shared files")
local command = host.NewCommand("REPLAYING", "Replay current dungeon")
assert(host.Announce(command) and carry.Command(false).id == command.id,
    "Shared file commands should reach followers without an HTTP relay")
print("Shared-workspace sync checks passed")
