-- Same-workspace files are the fastest sync path and need no background process.
-- The HTTP relay remains a fallback when executor instances isolate their files.
local PartySync = {}

local function relayKind(url)
    if url:match("^https://[^/]+$") then return "remote" end
    local host, port = url:match("^http://([^/:]+):(%d+)$")
    if not host or tonumber(port) < 1 or tonumber(port) > 65535 then return nil end
    if host == "localhost" or host == "127.0.0.1" or host == "10.0.2.2" then return "local" end
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    if a == 10 or a == 192 and b == 168 or a == 172 and b >= 16 and b <= 31 then return "local" end
end

local function wallTime()
    if DateTime and type(DateTime.now) == "function" then return DateTime.now().UnixTimestampMillis / 1000 end
    return os.time()
end

function PartySync.new(config, mode, isAlive)
    local Http = game:GetService("HttpService")
    local player = game:GetService("Players").LocalPlayer
    local sync = { status = "Sync off" }
    local context, response, receivedAt, pending, acknowledged, lastAttempt = nil, nil, nil, nil, false, -math.huge
    local generation = 0
    local files = {
        available = type(writefile) == "function" and type(readfile) == "function"
            and type(isfile) == "function" and type(makefolder) == "function",
        room = nil, shared = false, lastWrite = -math.huge,
    }

    local function signature()
        return table.concat({ tostring(config.SyncEnabled), config.SyncURL, config.SyncKey,
            config.Role, config.Host, config.Carry, config.Alts }, "|")
    end
    local lastSignature = signature()
    local function reset()
        local value = signature()
        if value ~= lastSignature then
            lastSignature = value; generation = generation + 1
            context, response, receivedAt, pending, acknowledged = nil, nil, nil, nil, false
            lastAttempt = -math.huge
            files.room, files.shared, files.lastWrite = nil, false, -math.huge
        end
    end
    local function ensureFolder(path)
        if type(isfolder) == "function" and isfolder(path) then return true end
        return pcall(makefolder, path)
    end
    local function readJSON(path)
        if not files.available or not path or not isfile(path) then return nil end
        local ok, value = pcall(function() return Http:JSONDecode(readfile(path)) end)
        return ok and type(value) == "table" and value or nil
    end
    local function writeJSON(path, value)
        if not files.available or not path then return false end
        return pcall(function() writefile(path, Http:JSONEncode(value)) end)
    end
    local function setupRoom(ids, hostId, carryId)
        if not files.available then return end
        local sorted = table.clone(ids)
        table.sort(sorted)
        local root = "DungeonQuestRewrite-sync"
        local room = root .. "/" .. hostId .. "_" .. carryId .. "_" .. table.concat(sorted, "-")
        if not ensureFolder(root) or not ensureFolder(room) then files.available = false; return end
        files.room = room
    end
    local function heartbeatPath(id) return files.room and (files.room .. "/" .. id .. ".json") end
    local function commandPath() return files.room and (files.room .. "/command.json") end
    local function fresh(entry, limit)
        if type(entry) ~= "table" or type(entry.at) ~= "number" then return false end
        local age = wallTime() - entry.at
        return age >= -5 and age <= limit
    end
    local function writeHeartbeat(now)
        if not files.room or not context or now - files.lastWrite < 0.25 then return end
        files.lastWrite = now
        writeJSON(heartbeatPath(player.UserId), {
            version = 1, userId = player.UserId, jobId = game.JobId, placeId = game.PlaceId, mode = mode,
            enabled = config.Enabled, ready = config.Enabled and context.ready and now - context.at < 2,
            healCount = context.healCount,
            at = wallTime(),
        })
    end
    local function fileReadiness(roster)
        if not files.room then return false, nil end
        local missing, visible = {}, 0
        for _, account in ipairs(roster) do
            local member = readJSON(heartbeatPath(account.id))
            local seen = fresh(member, 3) and member.userId == account.id
            if seen then visible = visible + 1 end
            if not seen or member.mode ~= mode or member.jobId ~= game.JobId or member.placeId ~= game.PlaceId
                or member.enabled ~= true or member.ready ~= true then table.insert(missing, account.name) end
        end
        if visible == #roster then files.shared = true end
        return #missing == 0, missing
    end
    local function relayReadiness(roster)
        local now = os.clock()
        local localRelay = relayKind(config.SyncURL:gsub("/+$", "")) == "local"
        local responseLimit, memberLimit = localRelay and 3 or 20, localRelay and 5 or 35
        if not response or not receivedAt or now - receivedAt > responseLimit then return false, nil end
        local observed = {}
        for _, member in ipairs(response.members) do observed[member.userId] = member end
        local missing = {}
        for _, account in ipairs(roster) do
            local member = observed[account.id]
            if not member or member.mode ~= mode or member.jobId ~= game.JobId or member.placeId ~= game.PlaceId
                or member.enabled ~= true or member.ready ~= true or type(member.age) ~= "number"
                or member.age + now - receivedAt > memberLimit then table.insert(missing, account.name) end
        end
        return #missing == 0, missing
    end

    local function validMember(member, id, limit)
        return fresh(member, limit) and member.userId == id and member.mode == mode
            and member.jobId == game.JobId and member.placeId == game.PlaceId
    end

    function sync.Update(roster, host, carry, ready, healCount)
        reset()
        local ids = {}
        for _, account in ipairs(roster) do table.insert(ids, account.id) end
        context = { roster = ids, hostId = host.id, carryId = carry.id, ready = ready,
            healCount = tonumber(healCount), at = os.clock() }
        if not files.room then setupRoom(ids, host.id, carry.id) end
    end
    function sync.Pause()
        if context then context.ready = false end
        files.lastWrite = -math.huge
    end
    function sync.Regroup(reason)
        reset()
        if not config.SyncEnabled or config.Role ~= "Host" then return true end
        if files.shared and writeJSON(commandPath(), {
            version = 1, jobId = game.JobId, reason = reason, at = wallTime(),
        }) then return true end
        if not pending then pending = reason; acknowledged = false; lastAttempt = -math.huge end
        return acknowledged
    end
    function sync.Command()
        reset()
        if not config.SyncEnabled then return nil end
        local command = readJSON(commandPath())
        if fresh(command, 30) and command.jobId == game.JobId and type(command.reason) == "string" then
            return command.reason
        end
        local responseLimit = relayKind(config.SyncURL:gsub("/+$", "")) == "local" and 3 or 20
        if response and receivedAt and os.clock() - receivedAt <= responseLimit then
            command = response.command
            if type(command) == "table" and command.jobId == game.JobId and type(command.reason) == "string" then
                return command.reason
            end
        end
    end
    function sync.HealCounts(roster)
        reset()
        local counts = {}
        if files.room then
            for _, account in ipairs(roster) do
                local member = readJSON(heartbeatPath(account.id))
                if validMember(member, account.id, 3) and type(member.healCount) == "number" then
                    counts[account.id] = member.healCount
                end
            end
        end
        if response and receivedAt and os.clock() - receivedAt <= 20 then
            for _, member in ipairs(response.members) do
                if member.mode == mode and member.jobId == game.JobId and member.placeId == game.PlaceId
                    and type(member.healCount) == "number" and counts[member.userId] == nil then
                    counts[member.userId] = member.healCount
                end
            end
        end
        return counts
    end
    function sync.Ready(roster)
        reset()
        if not config.SyncEnabled then sync.status = "Sync off"; return true end
        local ready, missing = fileReadiness(roster)
        if ready then sync.status = "File sync: all scripts ready"; return true end
        if files.shared then
            sync.status = "File sync waiting: " .. table.concat(missing, ", ")
            return false
        end
        local relayReady, relayMissing = relayReadiness(roster)
        if relayReady then sync.status = "Relay sync: all scripts ready"; return true end
        local waiting = missing or relayMissing
        if files.available then
            sync.status = waiting and ("Looking for shared files: " .. table.concat(waiting, ", ")) or "Looking for shared executor workspace"
        elseif relayMissing then
            sync.status = "Relay waiting: " .. table.concat(relayMissing, ", ")
        else
            sync.status = "Sync unavailable: executor files are isolated and relay is offline"
        end
        return false
    end

    task.spawn(function()
        while isAlive() do
            reset()
            local now = os.clock()
            if not config.SyncEnabled then sync.status = "Sync off"
            elseif context then
                writeHeartbeat(now)
                local url = config.SyncURL:gsub("/+$", "")
                local kind = relayKind(url)
                local interval = kind == "local" and 0.5 or 10
                if kind and #config.SyncKey >= 32 and now - lastAttempt >= interval then
                    lastAttempt = now
                    local request = request or http_request or (syn and syn.request)
                    if type(request) == "function" then
                        local sentGeneration = generation
                        local sentSignature = lastSignature
                        local sentAt = os.clock()
                        local payload = {
                            roster = context.roster, hostId = context.hostId, carryId = context.carryId,
                            userId = player.UserId, jobId = game.JobId, placeId = game.PlaceId, mode = mode,
                            enabled = config.Enabled, ready = config.Enabled and context.ready and not pending and now - context.at < 5,
                            healCount = context.healCount,
                            regroup = pending,
                        }
                        local ok, result = pcall(function()
                            local timeout = kind == "local" and 2 or 8
                            local reply = request({ Url = url .. "/sync", Method = "POST", Timeout = timeout,
                                Headers = { ["Content-Type"] = "application/json", Authorization = "Bearer " .. config.SyncKey },
                                Body = Http:JSONEncode(payload) })
                            assert(reply and reply.StatusCode == 200, "Relay HTTP " .. tostring(reply and reply.StatusCode))
                            local decoded = Http:JSONDecode(reply.Body)
                            assert(decoded.protocol == 1 and type(decoded.members) == "table", "Invalid relay response")
                            return decoded
                        end)
                        if not isAlive() then return end
                        reset()
                        if generation == sentGeneration and signature() == sentSignature then
                            if ok and os.clock() - sentAt <= (kind == "local" and 2 or 8) then
                                response, receivedAt = result, sentAt
                                if pending and type(result.command) == "table" and result.command.jobId == game.JobId then acknowledged = true end
                            else response, receivedAt = nil, nil end
                        end
                    end
                end
            else sync.status = "Sync: waiting for valid party setup" end
            task.wait(0.25)
        end
    end)
    return sync
end
return PartySync
