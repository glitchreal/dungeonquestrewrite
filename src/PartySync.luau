-- Optional local/HTTPS relay. Network I/O runs outside the automation loop; stale
-- replies never authorize starting or farming, even if a request hangs.
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
function PartySync.new(config, mode, isAlive)
    local Http = game:GetService("HttpService")
    local player = game:GetService("Players").LocalPlayer
    local sync = { status = "Sync off" }
    local context, response, receivedAt, pending, acknowledged, lastAttempt = nil, nil, nil, nil, false, -math.huge
    local generation = 0
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
        end
    end
    function sync.Update(roster, host, carry, ready)
        reset()
        local ids = {}
        for _, account in ipairs(roster) do table.insert(ids, account.id) end
        context = { roster = ids, hostId = host.id, carryId = carry.id, ready = ready, at = os.clock() }
    end
    function sync.Pause()
        if context then context.ready = false end
    end
    function sync.Regroup(reason)
        reset()
        if not config.SyncEnabled or config.Role ~= "Host" then return true end
        if not pending then
            pending = reason; acknowledged = false
            -- Publish host decisions on the next half-second loop instead of
            -- waiting for an ordinary heartbeat interval.
            lastAttempt = -math.huge
        end
        return acknowledged
    end
    function sync.Command()
        reset()
        if config.SyncEnabled and response and receivedAt and os.clock() - receivedAt <= 20 then
            local command = response.command
            if type(command) == "table" and command.jobId == game.JobId and type(command.reason) == "string" then
                return command.reason
            end
        end
    end
    function sync.Ready(roster)
        reset()
        if not config.SyncEnabled then sync.status = "Sync off"; return true end
        local now = os.clock()
        local localRelay = relayKind(config.SyncURL:gsub("/+$", "")) == "local"
        local responseLimit, memberLimit = localRelay and 3 or 20, localRelay and 5 or 35
        if not response or not receivedAt or now - receivedAt > responseLimit then
            if response then sync.status = "Sync stale; waiting to reconnect" end
            return false
        end
        local observed = {}
        for _, member in ipairs(response.members) do observed[member.userId] = member end
        local missing = {}
        for _, account in ipairs(roster) do
            local member = observed[account.id]
            if not member or member.mode ~= mode or member.jobId ~= game.JobId or member.placeId ~= game.PlaceId
                or member.enabled ~= true or member.ready ~= true or type(member.age) ~= "number"
                or member.age + now - receivedAt > memberLimit then table.insert(missing, account.name) end
        end
        sync.status = #missing == 0 and "Sync: all scripts ready" or ("Sync waiting: " .. table.concat(missing, ", "))
        return #missing == 0
    end
    task.spawn(function()
        while isAlive() do
            reset()
            local now = os.clock()
            if not config.SyncEnabled then sync.status = "Sync off"
            elseif context then
                local url = config.SyncURL:gsub("/+$", "")
                local kind = relayKind(url)
                local interval = kind == "local" and 0.5 or 10
                if now - lastAttempt >= interval then
                    lastAttempt = now
                    local request = request or http_request or (syn and syn.request)
                    if not kind or #config.SyncKey < 32 then
                        response, receivedAt = nil, nil
                        sync.status = "Sync: enter HTTPS or private local relay URL and key"
                    elseif type(request) ~= "function" then
                        response, receivedAt = nil, nil
                        sync.status = "Sync: executor HTTP requests unavailable"
                    else
                        local sentGeneration = generation
                        local sentSignature = lastSignature
                        local sentAt = os.clock()
                        local payload = {
                            roster = context.roster, hostId = context.hostId, carryId = context.carryId,
                            userId = player.UserId, jobId = game.JobId, placeId = game.PlaceId, mode = mode,
                            enabled = config.Enabled, ready = config.Enabled and context.ready and not pending and now - context.at < 5,
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
                                sync.status = "Sync connected"
                            else
                                response, receivedAt = nil, nil
                                sync.status = "Sync unavailable; waiting to reconnect"
                            end
                        end
                    end
                end
            else sync.status = "Sync: waiting for valid party setup" end
            task.wait(0.5)
        end
    end)
    return sync
end
return PartySync
