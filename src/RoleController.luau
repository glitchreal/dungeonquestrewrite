-- One coordinator owns queueing, progression, recovery, and inventory mutations.
local Roles = {}
function Roles.new(config, runtime, mode, controller, save, isAlive, sync)
    local player = game:GetService("Players").LocalPlayer
    local Players = game:GetService("Players")
    local state = { phase = mode == "Lobby" and "LOBBY_REFORMING" or "ASSEMBLING", phaseAt = os.clock(), sellStatus = "Auto sell: off", sold = 0, status = "Disabled", party = "Configure host, carry, and alts", farming = false,
        finished = false, finishedAt = nil, missingAt = nil, readyAt = nil, returning = false, requests = {}, responded = {} }
    local times, healCache, roster, host, carry = {}, {}, nil, nil, nil
    local rosterKey, catalogReady = nil, false
    local healer = mode == "Dungeon" and AbilityController.new(player, function() end) or nil
    runtime.Catalog = Logic.catalog(runtime.Catalog)
    runtime.Heals = runtime.Heals or {}
    -- Previous releases stored booleans for the old one-heal target. Reinspect
    -- those accounts instead of treating an old true as two owned heals.
    for id, count in pairs(runtime.Heals) do
        if type(count) ~= "number" then runtime.Heals[id] = nil end
    end
    runtime.Levels = runtime.Levels or {}
    local revision, tickRevision = 0, 0
    local function wallTime()
        return DateTime and DateTime.now().UnixTimestampMillis / 1000 or os.time()
    end
    local function current() return isAlive() and revision == tickRevision end
    local function active() return current() and config.Enabled end
    local function healerRole() return config.Role == "Host" or config.Role == "Alt" end
    local function due(key, seconds, now)
        if now - (times[key] or -math.huge) < seconds then return false end
        times[key] = now
        return true
    end
    local function stop()
        state.farming = false
        controller.SetRunning(false)
    end
    local function phase(value, now)
        if state.phase ~= value then
            state.phase, state.phaseAt = value, now
            state.missingAt, state.readyAt, state.stableAt, state.partySeen = nil, nil, nil, false
        end
        if sync then sync.SetPhase(value, Adapter.currentDungeon()) end
    end
    local function beginTransition(value, reason, now, command)
        stop()
        phase(value, now)
        state.status, state.transitionAt = reason, now
        local authority = config.Role == "Host" or config.Role == "Carry" and host
            and not Players:GetPlayerByUserId(host.id) and value == "RECOVERING"
        state.transition = command or (authority and sync and sync.NewCommand(value, reason))
        state.transitionLocal = command == nil and authority
        state.returning = value ~= "REPLAYING"
        state.returnReason = reason
        if state.transition then
            runtime.Transition = state.transition
            runtime.ConsumedTransition = state.transition.id
        end
    end
    local function announced(now)
        if not state.transitionLocal or not sync or not state.transition then return true end
        if sync.Announce(state.transition) then return true end
        -- A dead transport must not strand a completed host. Followers can use
        -- the host's departure as presence-only evidence after this bounded window.
        local wait = config.SyncURL ~= "" and 10 or 1
        return now - state.transitionAt >= wait
    end
    local function returnLobby(reason, now, value, command)
        if not state.returning then beginTransition(value or "RECOVERING", reason, now, command) end
        stop()
        state.status = state.returnReason
        if not announced(now) then state.status = "Announcing party return"; return end
        local attempts = state.returnAttempts or 0
        local interval = math.min(30, 3 * 2 ^ math.min(attempts, 4))
        if due("return", interval, now) and active() then
            state.returnAttempts = attempts + 1
            runtime.PendingAction = { jobId = game.JobId, phase = state.phase, attempts = state.returnAttempts, at = wallTime() }
            save()
            local ok, result = pcall(Adapter.call, "teleToLobby")
            state.status = ok and result ~= false and "Return requested; waiting for teleport"
                or ("Return failed; retrying in " .. interval .. "s")
        end
    end
    local function configure()
        local key = table.concat({ config.Role, config.Host, config.Carry, config.Alts }, "|")
        if key ~= rosterKey then
            local newRoster, newHost, newCarry = Adapter.roster(config)
            if not active() then return false end
            if rosterKey then
                state.transition, state.transitionAt, state.returnAttempts, state.replayAttempts = nil, nil, nil, nil
                table.clear(times)
            end
            roster, host, carry, rosterKey = newRoster, newHost, newCarry, key
            state.missingAt, state.readyAt, state.returning, state.partySeen = nil, nil, false, false
            state.stableAt = nil
            healCache = {}
            state.party = "Host: " .. host.name .. " | Carry: " .. carry.name .. " | " .. (#roster - 2) .. " selected alts"
        end
        return true
    end
    local function checkHeals(members, now)
        local allHealed, missing = true, {}
        local synced = sync and sync.HealCounts and sync.HealCounts(roster) or {}
        for _, member in ipairs(members) do
            if member.id ~= carry.id then
                local key = tostring(member.id)
                local cached = healCache[key]
                local reported = member.id ~= player.UserId and synced[member.id]
                if type(reported) == "number" then
                    cached = { at = now, known = true, count = reported }
                    healCache[key], runtime.Heals[key] = cached, reported
                elseif member.present and (not cached or now - cached.at >= 5) then
                    local ok, inv = pcall(Adapter.inventory, member.player)
                    if not active() then return false, {} end
                    cached = { at = now, known = ok, count = ok and #Logic.heals(inv) or 0 }
                    healCache[key] = cached
                    runtime.Heals[key] = ok and cached.count or nil
                end
                if not member.present or not cached or not cached.known or cached.count < 2 then
                    allHealed = false
                    table.insert(missing, member.name .. " " .. (cached and cached.known and cached.count or "?") .. "/2")
                end
            end
        end
        return allHealed, missing
    end
    local function needsHeals()
        if not config.ProvisionHeals then return false end
        for _, member in ipairs(roster) do
            if member.id ~= carry.id and (runtime.Heals[tostring(member.id)] or 0) < 2 then return true end
        end
        return false
    end
    local function selection(level, allHealed)
        local pirate = allHealed ~= true and needsHeals() and Logic.bestDungeon(runtime.Catalog, level, true)
        return pirate or Logic.bestDungeon(runtime.Catalog, level, false)
    end

    local function partyLevel(members)
        local level
        for _, member in ipairs(members or roster) do
            if member.id ~= carry.id then
                local observed = member.level or runtime.Levels[tostring(member.id)]
                if observed then level = math.min(level or observed, observed) end
            end
        end
        return level
    end
    local function inventoryWork(now)
        if not config.AutoSell then state.sellStatus = "Auto sell: off" end
        local equipHealer = active() and healerRole() and config.AutoHealer
        if not (config.AutoSell or equipHealer) or not due("inventory", state.pendingSale and 2 or 8, now) then return end
        if Adapter.value(player, "busyTrading", false) then
            if config.AutoSell then state.sellStatus = "Auto sell: paused while trading" end
            return
        end
        if config.AutoSell then state.sellStatus = "Auto sell: reading inventory" end
        local inv = Adapter.inventory()
        if not current() then return end
        local unconfirmed = 0
        if state.pendingSale then
            local remaining, removed = {}, 0
            for category, items in pairs(inv) do
                if type(items) == "table" then
                    for id, item in pairs(items) do
                        if type(item) == "table" then remaining[category .. ":" .. tostring(item.UniqueItemID or id)] = true end
                    end
                end
            end
            for _, identity in ipairs(state.pendingSale) do
                if remaining[identity] then unconfirmed = unconfirmed + 1 else removed = removed + 1 end
            end
            state.sold = state.sold + removed
            state.pendingSale = nil
        end
        local protected = {}
        -- Preserve planned tank gear even when only standalone selling is enabled.
        if healerRole() and config.AutoHealer then
            for _, entry in ipairs(Logic.tankArmor(inv, assert(Adapter.level()))) do
                protected[entry.kind .. "_" .. entry.id] = true
            end
            local weapon = Logic.mageWeapon(inv, assert(Adapter.level()))
            if weapon then protected["weapon_" .. weapon.id] = true end
        end
        if equipHealer then
            local tank = Logic.tankArmor(inv, assert(Adapter.level()))
            for _, entry in ipairs(tank) do
                protected[entry.kind .. "_" .. entry.id] = true
                if entry.item.equipped ~= true and active() and healerRole() and config.AutoHealer then
                    Adapter.call("equipItem", entry.kind, entry.id)
                end
            end
            local weapon = Logic.mageWeapon(inv, assert(Adapter.level()))
            if weapon then
                protected["weapon_" .. weapon.id] = true
                if weapon.item.equipped ~= true and active() and healerRole() and config.AutoHealer then
                    Adapter.call("equipItem", "weapon", weapon.id)
                end
            end
            local heals = Logic.heals(inv)
            local desired = { q = heals[1], e = heals[2] }
            for _, slot in ipairs({ "q", "e" }) do
                local heal = desired[slot]
                if heal then protected["ability_" .. heal.id] = true end
                if not active() or not healerRole() or not config.AutoHealer then return end
                if heal and not Logic.slotEquipped(heal.item, slot) then
                    Adapter.call("equipItem", "ability", heal.id, slot)
                elseif not heal then
                    for id, item in pairs(inv.abilities) do
                        if Logic.slotEquipped(item, slot) and Logic.normalizeItemName(item.name) ~= "universal heal" then
                            local number = tonumber(tostring(id):match("^ability_(%d+)$"))
                            if number then Adapter.call("unequipItem", "ability", number) end
                        end
                    end
                end
            end
            -- Refresh after equipping; never sell based on pre-equip slot flags.
            inv = Adapter.inventory()
        end
        if controller.SetAbilityInventory then controller.SetAbilityInventory(inv) end
        runtime.Heals[tostring(player.UserId)] = #Logic.heals(inv)
        if current() and config.AutoSell and not Adapter.value(player, "busyTrading", false) then
            local plan, count = Logic.sellPlan(inv, protected, config.KeepItems, config.KeepLegendary)
            if count == 0 then
                state.sellStatus = "No eligible items | Verified sold: " .. state.sold
            elseif due("sell", 8, now) then
                local pending = {}
                for kind, ids in pairs(plan) do
                    local category = kind == "ability" and "abilities" or kind .. "s"
                    for _, id in ipairs(ids) do
                        local key = kind .. "_" .. id
                        table.insert(pending, category .. ":" .. tostring(inv[category][key].UniqueItemID or key))
                    end
                end
                Adapter.call("sellItemEvent", plan)
                state.pendingSale = pending
                state.sellStatus = "Requested " .. count .. " items | Verified sold: " .. state.sold
            else
                state.sellStatus = unconfirmed > 0 and ("Sale not confirmed for " .. unconfirmed .. " items; waiting to retry")
                    or (count .. " eligible items | Verified sold: " .. state.sold)
            end
        end
    end
    local function joinable()
        local owner = Adapter.ownerId()
        return mode == "Dungeon" and state.phase == "PRE_START" and not state.finished
            and not state.returning and not state.runStarted and not state.teleportAt and Adapter.started() == false
            and not Adapter.finished() and not Adapter.failed() and (not owner or owner == player.UserId)
    end
    local function processRequests(now)
        if config.Role ~= "Host" then return end
        if due("requestScan", 1, now) then
            for _, pending in ipairs(Adapter.pendingRequests()) do
                if not state.requests[pending.id] and now - (state.responded[pending.id] or -math.huge) >= 5 then
                    state.requests[pending.id] = { name = pending.name, at = now, prompt = pending.prompt }
                end
            end
        end
        for id, request in pairs(state.requests) do
            if request.prompt and not request.prompt.Parent then state.requests[id] = nil
            elseif now - (state.responded[id] or -math.huge) >= 5 then
                local allowed = false
                if config.AutoAccept and joinable() and now - request.at <= 45 then
                    for _, account in ipairs(roster) do
                        if request.name:lower() == account.name:lower() and account.id ~= host.id then allowed = true; break end
                    end
                end
                if active() then
                    state.responded[id], state.requests[id] = now, nil
                    Adapter.call("respondJoinRequest", id, allowed and joinable())
                end
            end
        end
    end
    function state.OnRequest(id, name, action)
        if action == "close" then
            if id == nil then table.clear(state.requests) else state.requests[id] = nil end
        elseif id ~= nil and type(name) == "string" then
            state.requests[id] = { name = name, at = os.clock() }
        end
    end
    function state.Finish(failed)
        state.failed = state.failed or failed == true
        state.finished, state.finishedAt = true, state.finishedAt or os.clock()
        if not state.transition then phase("REWARDS_SETTLING", state.finishedAt) end
        stop()
    end
    function state.TeleportStarted()
        state.teleportAt = os.clock()
        stop()
        if sync then sync.Pause() end
    end
    function state.TeleportFailed()
        state.teleportAt = nil
        state.status = "Teleport failed; bounded retry pending"
        -- Retain attempt timestamps: failure callbacks must not bypass rate limits.
    end
    function state.Stop() revision = revision + 1; stop(); if sync then sync.Pause() end end
    function state.Tick(now)
        tickRevision = revision
        if not isAlive() then return end
        if state.teleportAt then
            stop()
            if now - state.teleportAt < 30 then state.status = "Party teleport in progress"; return end
            state.teleportAt = nil
        end
        if mode == "Dungeon" then
            if Adapter.failed() then state.Finish(true) elseif Adapter.finished() then state.Finish() end
        end
        if not Adapter.level() then
            stop(); state.status = "Waiting for player data"
            state.sellStatus = config.AutoSell and "Auto sell: waiting for player data" or "Auto sell: off"
            return
        end
        -- Inventory tools must not depend on a valid party or dungeon catalog.
        inventoryWork(now)
        if not active() then
            stop(); state.status = "Off — enable automation at the top of Party"; state.missingAt, state.readyAt, state.returning, state.partySeen = nil, nil, false, false
            return
        end
        state.status = "Checking party setup"
        if not configure() then return end
        if not state.restored then
            state.restored = true
            local saved = runtime.Transition
            if mode == "Dungeon" and Logic.validCommand(saved, host.id, carry.id, game.JobId, game.PlaceId,
                wallTime(), not Players:GetPlayerByUserId(host.id)) then
                beginTransition(saved.phase, saved.reason, now, saved)
                state.transitionLocal = saved.authorId == player.UserId
                state.transitionAt = now - math.max(0, wallTime() - saved.at)
                local action = runtime.PendingAction
                if type(action) == "table" and action.jobId == game.JobId and action.phase == saved.phase
                    and type(action.at) == "number" and type(action.attempts) == "number" then
                    local key = saved.phase == "REPLAYING" and "replay" or "return"
                    times[key] = now - math.max(0, wallTime() - action.at)
                    if key == "replay" then state.replayAttempts = action.attempts else state.returnAttempts = action.attempts end
                end
            end
        end
        if sync then sync.Update(roster, host, carry, true, runtime.Heals[tostring(player.UserId)], state.phase, Adapter.currentDungeon()) end
        if mode == "Lobby" and not catalogReady then
            state.status = "Loading dungeon requirements"
            local catalog = Adapter.catalog()
            if not active() then return end
            runtime.Catalog, catalogReady = catalog, true
            save()
        end
        if not active() then return end
        if healerRole() and config.AutoSkillPoints and due("points", 3, now) then
            local points = Adapter.value(player, "skillPoints", 0)
            local stat = ({ Stamina = "stamina", ["Spell Power"] = "spellPower", ["Physical Power"] = "physicalPower" })[config.UpgradeStat]
            if points > 0 and stat then Adapter.call("spendSkillPoint", stat, points) end
        end
        if mode == "Dungeon" then runtime.LastDungeonJob = game.JobId end
        local members = Adapter.members(roster)
        for _, member in ipairs(members) do
            if member.level then runtime.Levels[tostring(member.id)] = member.level end
        end
        local ready, equal, missing = Logic.partyReady(members, host.id, carry.id)
        local hostPresent = Players:GetPlayerByUserId(host.id) ~= nil
        local hostState = sync and sync.Member(host.id)
        local scriptsReady = not sync or sync.Ready(roster)
        state.party = ready and (equal and "Party present; levels match" or "Party present; progression uses lowest Host/Alt level")
            or ("Waiting: " .. table.concat(missing, ", "))
        if mode == "Lobby" then
            stop()
            phase("LOBBY_REFORMING", now)
            runtime.Transition = nil
            if config.Role ~= "Host" then
                if not config.AutoJoin then state.status = "Auto join disabled"; return end
                -- Positive Host PRE_START presence permits requests to the dungeon.
                -- A completed/returning Host heartbeat explicitly forbids them.
                local hostJoinable = hostState and hostState.enabled and hostState.ready
                    and hostState.mode == "Dungeon" and hostState.phase == "PRE_START"
                    and hostState.jobId ~= runtime.LastDungeonJob
                state.status = hostJoinable and ("Requesting " .. host.name) or "Lobby reforming: waiting for Host"
                if due("join", config.JoinInterval, now) and active() then
                    if hostJoinable then
                        local ok, reason = Adapter.call("sendJoinRequest", host.name, false)
                        if ok == false then state.status = "Join request: " .. tostring(reason or "Host not ready") end
                    elseif not hostState or hostState.mode == "Lobby" and hostState.phase == "LOBBY_REFORMING" then
                        -- Without transport, assemble in an actual lobby queue and
                        -- depart together. Never probe a completed dungeon with requests.
                        local choice = selection(partyLevel(members) or Adapter.level())
                        local dungeon = hostState and hostState.dungeon and hostState.dungeon.Dungeon
                            or choice and choice.Dungeon
                        local _, reason = Adapter.joinLobby(host.name, dungeon, runtime.Catalog)
                        state.status = reason
                    else state.status = "Waiting: Host phase " .. tostring(hostState.phase) end
                end
                return
            end
            if not config.AutoBest then state.status = "Auto best dungeon disabled"; return end
            local lobby = Adapter.findLobby()
            local queued = Adapter.lobbyMembers(lobby)
            for _, member in ipairs(roster) do
                local level = queued[member.name:lower()]
                if type(level) == "number" then runtime.Levels[tostring(member.id)] = level end
            end
            local level = partyLevel(members) or Adapter.level()
            local chosen = assert(selection(level), "No eligible dungeon; refresh the lobby catalog")
            if sync then sync.SetPhase("LOBBY_REFORMING", chosen) end
            state.status = "Host: " .. chosen.Dungeon .. " / " .. chosen.Difficulty
            if due("queue", 5, now) and active() then
                if lobby then
                    if not Adapter.lobbyMatches(lobby, chosen, config) then
                        Adapter.call("leaveGame"); state.status = "Recreating lobby with selected options"; return
                    end
                    if config.Whitelist then
                        for _, account in ipairs(roster) do if account.id ~= host.id then Adapter.call("addPlayerToWhitelist", account.name) end end
                    end
                    -- Presence-only fallback has no remote phase evidence: gather
                    -- everyone in the queue before entering the dungeon.
                    local queuedMissing = {}
                    for _, account in ipairs(roster) do
                        if not queued[account.name:lower()] then table.insert(queuedMissing, account.name) end
                    end
                    if #queuedMissing > 0 then
                        state.status = "Lobby reforming: waiting for " .. table.concat(queuedMissing, ", "); return
                    end
                    save(); Adapter.call("startDungeon")
                    state.status = "Entering " .. chosen.Dungeon .. " / " .. chosen.Difficulty
                else
                    assert(Adapter.createLobby(chosen, config), "Server declined dungeon creation")
                    state.status = "Lobby created; gathering selected accounts"
                end
            end
            return
        end
        local command = sync and sync.Command(not hostPresent)
        if command and command.id ~= runtime.ConsumedTransition
            and (not state.transition or command.at >= state.transition.at) then
            runtime.ConsumedTransition = command.id
            if command.phase == "REPLAYING" then
                beginTransition("REPLAYING", "Host replay requested; waiting for teleport", now, command)
            else
                returnLobby(command.reason, now, command.phase, command); return
            end
        end
        if state.returning then processRequests(now); returnLobby(state.returnReason, now); return end
        if state.finished then
            stop()
            if not state.transition then phase("REWARDS_SETTLING", now) end
            processRequests(now)
            if now - state.finishedAt < 5 then state.status = "Rewards settling"; return end
            if not state.rewardsRefreshed then
                healCache = {}; times.inventory = nil; state.rewardsRefreshed = true
                if config.ProvisionHeals then state.healsSettlingUntil = now + 2 end
            end
            if config.Role ~= "Host" then
                state.status = state.phase == "REPLAYING" and "Replay requested; waiting for teleport" or "Rewards settled; waiting for Host decision"
                -- Host departure is the fallback authority signal. A replay command
                -- suspends this fallback while the game's party teleport completes.
                if not hostPresent and not state.transition then
                    state.hostLeftAt = state.hostLeftAt or now
                    -- Without an explicit decision, departure may be replay.
                    -- Allow the same bounded grace as an in-flight teleport.
                    state.status = "Host departed; waiting for party teleport"
                    local confirmedReturn = hostState and hostState.mode == "Lobby" and hostState.phase == "LOBBY_REFORMING"
                    if confirmedReturn or now - state.hostLeftAt >= 30 then
                        returnLobby("Following Host return", now, "PROGRESSION_RETURN")
                    end
                elseif state.transition and now - state.transitionAt > 90 then
                    returnLobby("Replay teleport timed out; regrouping", now)
                else state.hostLeftAt = nil end
                return
            end
            if state.failed then returnLobby("Run failed: regrouping in lobby", now); return end
            local allHealed = false
            if config.ProvisionHeals then allHealed = checkHeals(members, now) end
            if state.healsSettlingUntil and now < state.healsSettlingUntil then state.status = "Rewards settling: Universal Heals"; return end
            local eligibleLevel = partyLevel(members)
            local chosen = eligibleLevel and selection(eligibleLevel, config.ProvisionHeals and allHealed or nil)
            local dungeon = Adapter.currentDungeon()
            if not state.transition and config.AutoBest and ready
                and Logic.shouldProgress(chosen, dungeon, config.ProvisionHeals and allHealed and dungeon.Dungeon == "Pirate Island") then
                returnLobby("Progression unlocked: returning for " .. chosen.Dungeon .. " / " .. chosen.Difficulty, now, "PROGRESSION_RETURN"); return
            end
            if not ready then
                state.status = "Run complete: " .. state.party
                if now - state.finishedAt >= config.RecoveryGrace then returnLobby("Replay party incomplete; regrouping", now) end
                return
            end
            if not state.transition then beginTransition("REPLAYING", "Replaying current dungeon", now) end
            if not announced(now) then state.status = "Announcing current dungeon replay"; return end
            local attempts = state.replayAttempts or 0
            if attempts >= 3 and now - (times.replay or now) >= 12 then
                state.transitionAt = nil
                returnLobby("Replay failed after 3 attempts; regrouping", now); return
            end
            local interval = math.min(12, 4 * 2 ^ math.max(0, attempts - 1))
            state.status = attempts == 0 and "Replaying current dungeon" or ("Replay requested; waiting for teleport (retry in "
                .. math.max(0, math.ceil(interval - (now - (times.replay or now)))) .. "s)")
            if state.replayError then
                state.status = "Replay failed; retrying in " .. math.max(0, math.ceil(interval - (now - (times.replay or now)))) .. "s: " .. state.replayError
            end
            if attempts < 3 and due("replay", interval, now) and active() then
                state.replayAttempts = attempts + 1
                runtime.PendingAction = { jobId = game.JobId, phase = "REPLAYING", attempts = state.replayAttempts, at = wallTime() }
                save()
                local ok, result, reason = pcall(Adapter.replay)
                state.replayError = not (ok and result ~= false) and tostring(reason or result) or nil
                state.status = state.replayError and ("Replay failed; retrying in " .. interval .. "s: " .. state.replayError)
                    or "Replay requested; waiting for teleport"
            end
            return
        end
        if state.transition then
            stop(); processRequests(now)
            state.status = "Host replay pending; waiting for completion/teleport"
            if now - state.transitionAt > 90 then returnLobby("Replay timed out; regrouping", now) end
            return
        end
        local started = Adapter.started()
        if started == nil then phase("ASSEMBLING", now); stop(); state.status = "Waiting for dungeon state replication"; return end
        if started then state.runStarted = true; state.endingAt = nil
        elseif state.runStarted then
            phase("REWARDS_SETTLING", now); stop(); processRequests(now)
            state.endingAt = state.endingAt or now
            state.status = "Rewards settling: waiting for completion replication"
            if config.Role == "Host" and now - state.endingAt >= 30 then
                returnLobby("Completion state unavailable; regrouping", now)
            end
            return
        end
        phase(started and "RUNNING" or "PRE_START", now)
        processRequests(now)
        local transition = hostState and hostState.jobId == game.JobId and
            (hostState.phase == "REPLAYING" or hostState.phase == "PROGRESSION_RETURN" or hostState.phase == "RECOVERING")
        if transition then
            stop(); state.missingAt, state.partySeen = nil, false
            state.status = "Waiting for Host transition: " .. hostState.phase; return
        end
        -- Only a fully replicated party observed in THIS stable phase arms OCD.
        local loaded = ready
        for _, member in ipairs(members) do if not member.level then loaded = false end end
        if loaded then
            state.stableAt = state.stableAt or now
            if now - state.stableAt >= config.StartDelay then state.partySeen = true end
            state.missingAt = nil
        elseif not ready and state.partySeen then state.missingAt = state.missingAt or now
        else state.missingAt = nil; state.stableAt = nil end
        if not ready then
            stop()
            state.readyAt = nil
            state.status = state.party
            if config.OCD and state.missingAt then
                local elapsed = now - state.missingAt
                state.status = "OCD grace: " .. table.concat(missing, ", ") .. " missing " .. math.floor(elapsed) .. " / " .. config.RecoveryGrace .. "s"
                if elapsed >= config.RecoveryGrace then
                    -- Host is the authority; Carry takes over only when Host is lost.
                    if config.Role == "Host" or not hostPresent and config.Role == "Carry" then
                        returnLobby("OCD recovery: " .. table.concat(missing, ", "), now)
                    elseif not hostPresent and not Players:GetPlayerByUserId(carry.id) then
                        returnLobby("Following party recovery", now)
                    end
                end
            end
            return
        end
        if not started then
            stop()
            if config.RequireScriptsReady and not scriptsReady then state.readyAt = nil; state.status = sync and sync.status or "Sync transport unavailable"; return end
            if config.Role ~= "Host" then
                state.readyAt = nil
                state.status = "Waiting for Host to start"
                return
            end
            state.readyAt = state.readyAt or now
            local elapsed = math.max(0, now - state.readyAt)
            state.status = "Party ready; start delay " .. string.format("%.1f / %.1f", math.min(elapsed, config.StartDelay), config.StartDelay)
            if config.LevelKaitun and elapsed >= config.StartDelay
                and due("start", 5, now) and active() then
                state.status = "Starting dungeon"; Adapter.call("changeStartValue")
            end
            return
        end
        -- Heartbeat readiness gates START only, never local movement during a run.
        local canRun = ready
        state.farming = config.Role == "Carry" and config.LevelKaitun and canRun
        controller.SetRunning(state.farming)
        state.status = state.farming and "Carry farm active" or healerRole() and config.AutoHealer and (config.Role .. ": Universal Heal") or "Waiting for carry"
        if healerRole() and config.AutoHealer and healer and canRun then
            -- The slot scheduler alternates Q/E and still respects each tool cooldown.
            -- Stagger heals even when both slots are ready after joining or idling.
            healer.TryCast(now, 4, function(_, snapshot)
                if snapshot.name ~= "Universal Heal" then return false end
                for _, member in ipairs(members) do
                    local character = member.player and member.player.Character
                    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                    if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth * 0.95 then return true end
                end
                return false
            end)
        end
    end
    return state
end
return Roles
