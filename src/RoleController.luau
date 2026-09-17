-- One coordinator owns queueing, progression, recovery, and inventory mutations.
local Roles = {}
function Roles.new(config, runtime, mode, controller, save, isAlive, sync)
    local player = game:GetService("Players").LocalPlayer
    local Players = game:GetService("Players")
    local state = { sellStatus = "Auto sell: off", sold = 0, status = "Disabled", party = "Configure host, carry, and alts", farming = false,
        finished = false, finishedAt = nil, missingAt = nil, readyAt = nil, returning = false, requests = {}, responded = {} }
    local times, healCache, roster, host, carry = {}, {}, nil, nil, nil
    local rosterKey, catalogReady = nil, false
    local healer = mode == "Dungeon" and AbilityController.new(player, function() end) or nil
    runtime.Catalog = runtime.Catalog or {}
    runtime.Heals = runtime.Heals or {}
    -- Previous releases stored booleans for the old one-heal target. Reinspect
    -- those accounts instead of treating an old true as two owned heals.
    for id, count in pairs(runtime.Heals) do
        if type(count) ~= "number" then runtime.Heals[id] = nil end
    end
    runtime.Levels = runtime.Levels or {}
    local revision, tickRevision = 0, 0
    local function current() return isAlive() and revision == tickRevision end
    local function active() return current() and config.Enabled end
    local function due(key, seconds, now)
        if now - (times[key] or -math.huge) < seconds then return false end
        times[key] = now
        return true
    end
    local function stop()
        state.farming = false
        controller.SetRunning(false)
    end
    local function returnLobby(reason, now)
        stop()
        state.returning, state.status = true, reason
        if sync and not sync.Regroup(reason) then
            state.status = "Waiting for relay to announce regroup"
            return
        end
        if due("return", 15, now) and active() then save(); Adapter.call("teleToLobby") end
    end
    local function configure()
        local key = table.concat({ config.Role, config.Host, config.Carry, config.Alts }, "|")
        if key ~= rosterKey then
            local newRoster, newHost, newCarry = Adapter.roster(config)
            if not active() then return false end
            roster, host, carry, rosterKey = newRoster, newHost, newCarry, key
            state.missingAt, state.readyAt, state.returning, state.partySeen = nil, nil, false, false
            healCache = {}
            state.party = "Host: " .. host.name .. " | Carry: " .. carry.name .. " | " .. (#roster - 2) .. " selected alts"
        end
        return true
    end
    local function checkHeals(members, now)
        local allHealed = true
        for _, member in ipairs(members) do
            if member.id ~= carry.id then
                local key = tostring(member.id)
                local cached = healCache[key]
                if member.present and (not cached or now - cached.at >= 20) then
                    local ok, inv = pcall(Adapter.inventory, member.player)
                    if not active() then return false end
                    cached = { at = now, known = ok, count = ok and #Logic.heals(inv) or 0 }
                    healCache[key] = cached
                    runtime.Heals[key] = ok and cached.count or nil
                end
                if not member.present or not cached or not cached.known or cached.count < 2 then allHealed = false end
            end
        end
        return allHealed
    end
    local function needsHeals()
        if not config.ProvisionHeals then return false end
        for _, member in ipairs(roster) do
            if member.id ~= carry.id and (runtime.Heals[tostring(member.id)] or 0) < 2 then return true end
        end
        return false
    end
    local function selection(level)
        local pirate = needsHeals() and Logic.bestDungeon(runtime.Catalog, level, true)
        return pirate or Logic.bestDungeon(runtime.Catalog, level, false)
    end
    local function inventoryWork(now)
        if not config.AutoSell then state.sellStatus = "Auto sell: off" end
        local equipHealer = active() and config.Role == "Alt" and config.AutoHealer
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
        if config.Role == "Alt" and config.AutoHealer then
            for _, entry in ipairs(Logic.tankArmor(inv, assert(Adapter.level()))) do
                protected[entry.kind .. "_" .. entry.id] = true
            end
        end
        if equipHealer then
            local tank = Logic.tankArmor(inv, assert(Adapter.level()))
            for _, entry in ipairs(tank) do
                protected[entry.kind .. "_" .. entry.id] = true
                if entry.item.equipped ~= true and active() and config.Role == "Alt" and config.AutoHealer then
                    Adapter.call("equipItem", entry.kind, entry.id)
                end
            end
            local heals = Logic.heals(inv)
            local desired = { q = heals[1], e = heals[2] }
            for _, slot in ipairs({ "q", "e" }) do
                local heal = desired[slot]
                if heal then protected["ability_" .. heal.id] = true end
                if not active() or config.Role ~= "Alt" or not config.AutoHealer then return end
                if heal and not (type(heal.item.equipped) == "table" and heal.item.equipped[slot]) then
                    Adapter.call("equipItem", "ability", heal.id, slot)
                elseif not heal then
                    for id, item in pairs(inv.abilities) do
                        if type(item.equipped) == "table" and item.equipped[slot] and item.name ~= "Universal Heal" then
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
    local function processRequests(now)
        if config.Role ~= "Host" or not config.AutoAccept or Adapter.PlaceManager.HasDungeonStarted() then return end
        -- Recover prompts whose showJoinRequest event fired before this script loaded.
        if due("requestScan", 1, now) then
            for _, pending in ipairs(Adapter.pendingRequests()) do
                if not state.requests[pending.id] and now - (state.responded[pending.id] or -math.huge) >= 5 then
                    state.requests[pending.id] = { name = pending.name, at = now, prompt = pending.prompt }
                end
            end
        end
        for id, request in pairs(state.requests) do
            if now - request.at > 45 or request.prompt and not request.prompt.Parent then state.requests[id] = nil
            elseif config.Role == "Host" and config.AutoAccept and not Adapter.PlaceManager.HasDungeonStarted() then
                local allowed = false
                for _, account in ipairs(roster) do
                    if request.name:lower() == account.name:lower() and account.id ~= host.id then allowed = true; break end
                end
                if active() then
                    Adapter.call("respondJoinRequest", id, allowed)
                    state.responded[id] = now
                    state.requests[id] = nil
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
        stop()
    end
    function state.TeleportFailed()
        state.status = "Teleport failed; retrying"
        times["return"], times["queue"], times["replay"] = nil, nil, nil
    end
    function state.Stop() revision = revision + 1; stop(); if sync then sync.Pause() end end
    function state.Tick(now)
        tickRevision = revision
        if not isAlive() then return end
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
        if sync then sync.Update(roster, host, carry, true) end
        if mode == "Lobby" and not catalogReady then
            state.status = "Loading dungeon requirements"
            local catalog = Adapter.catalog()
            if not active() then return end
            runtime.Catalog, catalogReady = catalog, true
            save()
        end
        if not active() then return end
        if config.Role == "Alt" and config.AutoSkillPoints and due("points", 3, now) then
            local points = Adapter.value(player, "skillPoints", 0)
            local stat = ({ Stamina = "stamina", ["Spell Power"] = "spellPower", ["Physical Power"] = "physicalPower" })[config.UpgradeStat]
            if points > 0 and stat then Adapter.call("spendSkillPoint", stat, points) end
        end
        local members = Adapter.members(roster)
        for _, member in ipairs(members) do
            if member.level then runtime.Levels[tostring(member.id)] = member.level end
        end
        if mode == "Lobby" then
            stop()
            if config.Role ~= "Host" then
                state.status = config.AutoJoin and ("Requesting " .. host.name) or "Auto join disabled"
                if config.AutoJoin and due("join", config.JoinInterval, now) and active() then
                    local ok, reason = Adapter.call("sendJoinRequest", host.name)
                    if ok == false then state.status = "Join request: " .. tostring(reason or "host not ready") end
                end
                return
            end
            if not config.AutoBest then state.status = "Auto best dungeon disabled"; return end
            -- Recovery may have left an alt behind. Use its last observed level as an eligibility ceiling.
            local level = Adapter.level()
            for _, member in ipairs(roster) do
                local observed = runtime.Levels[tostring(member.id)]
                if member.id ~= carry.id and observed then level = math.min(level, observed) end
            end
            local chosen = assert(selection(level), "No eligible dungeon; refresh the lobby catalog")
            state.status = "Host: " .. chosen.Dungeon .. " / " .. chosen.Difficulty
            if due("queue", 5, now) and active() then
                local lobby = Adapter.findLobby()
                if lobby then
                    if not Adapter.lobbyMatches(lobby, chosen, config) then
                        Adapter.call("leaveGame")
                        state.status = "Recreating lobby with selected options"
                        return
                    end
                    if config.Whitelist then
                        for _, account in ipairs(roster) do if account.id ~= host.id then Adapter.call("addPlayerToWhitelist", account.name) end end
                    end
                    if active() then
                        state.status = "Entering " .. chosen.Dungeon .. " / " .. chosen.Difficulty
                        assert(Adapter.call("startDungeon") ~= false, "Server declined dungeon entry; retrying")
                    end
                else
                    state.status = "Creating " .. chosen.Dungeon .. " / " .. chosen.Difficulty
                    assert(Adapter.createLobby(chosen, config), "Server declined dungeon creation; check your level and lobby state")
                    state.status = "Lobby created; entering shortly"
                end
            end
            return
        end
        -- Owner metadata is not reliable on first entry or after ownership transfers.
        -- Role selection controls requests; the server validates owner-only actions.
        if sync and config.Role ~= "Host" then
            local regroup = sync.Command()
            if regroup then returnLobby("Host regroup: " .. regroup, now); return end
        end
        processRequests(now)
        if not active() then return end
        local ready, equal, missing = Logic.partyReady(members, host.id, carry.id)
        state.party = ready and (equal and "Party present; host and alts at the same level" or "Party present; waiting for levels to match")
            or ("Missing: " .. table.concat(missing, ", "))
        if ready then state.partySeen = true; state.missingAt = nil
        else state.missingAt = state.missingAt or now end
        local scriptsReady = not sync or sync.Ready(roster)
        local canRun = ready and scriptsReady
        if canRun then state.readyAt = state.readyAt or now else state.readyAt = nil end
        if state.returning then returnLobby(state.status, now); return end
        local started = Adapter.PlaceManager.HasDungeonStarted()
        -- Initial assembly has no timeout. Recover only a party that was assembled
        -- or a run already in progress, so slow joins do not eject the host.
        if config.OCD and (state.partySeen or started) and not ready and now - state.missingAt >= config.RecoveryGrace then
            returnLobby("OCD recovery: regrouping in lobby", now); return
        end
        if Adapter.failed() then state.Finish(true)
        elseif Adapter.finished() then state.Finish() end
        if state.finishedAt and now - state.finishedAt >= 5 and not state.rewardsRefreshed then
            healCache = {}; times.inventory = nil; state.rewardsRefreshed = true
        end
        local allHealed = config.ProvisionHeals and checkHeals(members, now)
        if not active() then return end
        -- Presence/levels must be freshly observed, never inferred from a host leaving.
        local hostLevel
        for _, member in ipairs(members) do if member.id == host.id then hostLevel = member.level end end
        local chosen = hostLevel and selection(hostLevel)
        local current = Adapter.currentDungeon()
        local switchEnabled = config.Role == "Host" and config.AutoBest
            or config.Role ~= "Host" and config.AutoSwitch and not config.SyncEnabled
        local switch = switchEnabled and ready and equal and chosen and not Logic.sameDungeon(chosen, current)
        if state.finished then
            stop()
            if state.failed then state.status = "Run failed; waiting for the game to return to lobby"; return end
            -- Let replicated levels and newly awarded drops settle before replay/progression.
            if now - state.finishedAt < 5 then state.status = "Waiting for rewards"; return end
            if switch then returnLobby("Progression: " .. chosen.Dungeon .. " / " .. chosen.Difficulty, now); return end
            state.status = ready and "Run ended; replaying current dungeon" or "Run ended; waiting for party"
            if config.Role == "Host" and canRun and due("replay", 15, now) and active() then Adapter.replay() end
            return
        end
        if not started then
            stop()
            if switch and current.Dungeon == "Pirate Island" and allHealed then
                returnLobby("Universal Heal ready; selecting best dungeon", now); return
            end
            state.status = canRun and "Party ready; waiting to start" or ready and "Waiting for selected scripts through relay" or "Waiting for selected accounts"
            -- Carry owns Level Kaitun policy; the host mirrors its readiness gate for owner-only servers.
            if canRun and now - state.readyAt >= config.StartDelay and config.LevelKaitun
                and (config.Role == "Carry" or config.Role == "Host") and due("start", 5, now) and active() then
                Adapter.call("changeStartValue")
            end
            return
        end
        state.farming = config.Role == "Carry" and config.LevelKaitun and canRun
        controller.SetRunning(state.farming)
        state.status = state.farming and "Carry: pathfinding farm" or config.Role == "Alt" and config.AutoHealer and "Alt: Universal Heal" or "Waiting for carry"
        if config.Role == "Alt" and config.AutoHealer and healer and canRun then
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
