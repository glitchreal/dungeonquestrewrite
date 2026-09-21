-- Shared Obsidian UI, bundled with the place-specific entry point by build.lua.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
local env = getgenv()
local resume = env.DQObsidianResume
env.DQObsidianResume = nil
if env.DungeonQuestObsidian then
    local previous = env.DungeonQuestObsidian
    if not resume then
        resume = { Config = previous.Config, Totals = previous.Totals, Elapsed = previous.Elapsed and previous.Elapsed() or 0 }
    end
    previous.Unload()
end

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/3df0deae2c50a06cf29cf3b6a047db62466d40b9/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
-- A normal PlayerGui parent also permits updates from game event callbacks.
Library.ScreenGui.Parent = player:WaitForChild("PlayerGui")
Library.ScreenGui.ResetOnSpawn = false
Library.Scheme.AccentColor = Color3.fromRGB(63, 205, 134)
Library.ForceCheckbox = false
local controller = createController()
local C = {
    WalkSpeedEnabled = false, WalkSpeed = 16, JumpPowerEnabled = false, JumpPower = 50,
    SpoofNames = false, SpoofName = "Player", ScrollingName = false, SpoofLevel = false, DisplayLevel = 1,
    UpgradeStat = "Spell Power", AutoUpgrade = false,
    FarmPosition = "Nearest", Distance = 20, FarmSpeed = 16, FarmSpeedEnabled = false,
    StartDelay = 0, AutoDungeon = false, AutoAbilities = true, SpamAbilities = false, AutoReplay = false,
    SmartFarm = true, GroupRadius = 6, CloseAoeRange = 8,
    SpellRange = 26,
    DynamicDistance = false, AdaptiveSpacing = true, MeleeDistance = 8, Hover = false, HoverHeight = 5,
    AutoDodge = true, SoloHitless = true, ReactionTime = 0.05, Standoff = 20, SafetyDistance = 3,
    KickOnJoin = false, AllowFriends = true, AllowedPlayers = "",
    Dungeon = "Desert Temple", Difficulty = "Easy", AutoCreate = false, AutoStart = false,
    Hardcore = false, PrivateLobby = true, WaveDefence = false,
    TargetLine = false, Waypoints = true, FPSCap = 60, Disable3D = false,
    DisableEffects = false, LowPerformance = false, ExtremeOptimization = false,
    AutoRaid = false, AdvanceTier = false, AutoReplayRaid = false, RaidTier = "1",
    Webhook = false, WebhookURL = "", ItemImages = false, LargeItemImages = false,
    WebhookDetails = { Dungeon = true, Difficulty = true, Result = true, Duration = true, Coins = true,
        Gems = true, Levels = true, Kills = true, Deaths = true, Items = true },
}
local configDefaults = table.clone(C)
local alive, busy, hooks = true, {}, {}
local placeStartedAt = os.clock()
local startedAt = placeStartedAt
local totals = { Completed = 0, Failed = 0, Coins = 0, Gems = 0, Levels = 0, Deaths = 0, Freezes = 0, Duration = 0, Runs = 0 }
if type(resume) == "table" then
    startedAt = startedAt - math.max(0, tonumber(resume.Elapsed) or 0)
    for key, value in pairs(resume.Totals or {}) do if totals[key] ~= nil and type(value) == "number" then totals[key] = value end end
end
local balances = Adapter.balances()
local balancesReady = Adapter.level() ~= nil
local runStartedAt, runEnded, wasStarted, runCounted = nil, false, false, false
local lastRun, inventory = nil, nil
local raidAction, lobbyAction = "Waiting", "Waiting"
local lastQueue, lastUpgrade, lastInv, lastWebhook = 0, 0, 0, -math.huge
local labels = {}
local patchSets = {}
local movementOriginal = setmetatable({}, { __mode = "k" })
local line, hoverForce, hoverAttachment, beamStart, beamEnd
local previousFPS = type(getfpscap) == "function" and getfpscap() or nil
local fpsChanged = false
local controls = {}
local errors, lastErrors = {}, {}
local configPath = "DungeonQuestObsidian-config.json"
local saveReady, saveDirty, saveVersion = false, false, 0
local menuKey = "RightShift"

local function uiIdentity()
    if type(setthreadidentity) == "function" then setthreadidentity(8) end
end

local function connect(signal, callback)
    local connection = signal:Connect(function(...)
        uiIdentity()
        callback(...)
    end)
    table.insert(hooks, connection)
    return connection
end

local function notify(message)
    if alive then
        uiIdentity()
        pcall(function() Library:Notify({ Title = "Dungeon Quest", Description = tostring(message), Time = 5 }) end)
    end
end

local function saveConfig()
    if not saveReady or not saveDirty then return end
    if type(writefile) ~= "function" then
        errors.config = "Executor file saving is unavailable"
        return
    end
    local ok = pcall(function()
        writefile(configPath, HttpService:JSONEncode({ Version = 1, Config = C, MenuKey = menuKey }))
    end)
    if ok then saveDirty = false; errors.config = nil
    else errors.config = "Could not save settings" end
end

local function scheduleSave()
    if not saveReady then return end
    saveDirty = true
    saveVersion = saveVersion + 1
    local version = saveVersion
    task.delay(0.5, function()
        if alive and version == saveVersion then saveConfig() end
    end)
end

local function job(key, callback)
    if not alive or busy[key] then return end
    busy[key] = true
    task.spawn(function()
        uiIdentity()
        local ok, err = xpcall(callback, debug.traceback)
        busy[key] = nil
        if not ok then
            errors[key] = key == "webhook" and "Webhook request failed" or tostring(err)
            if os.clock() - (lastErrors[key] or -math.huge) < 10 then return end
            lastErrors[key] = os.clock()
            -- Never print request errors: an HTTP error can include the secret webhook URL.
            if key == "webhook" then notify("Webhook request failed") else notify(err) end
        else
            errors[key] = nil
        end
    end)
end

local function patch(group, instance, property, value)
    patchSets[group] = patchSets[group] or setmetatable({}, { __mode = "k" })
    local set = patchSets[group]
    set[instance] = set[instance] or {}
    if set[instance][property] == nil then set[instance][property] = { instance[property] } end
    instance[property] = value
end

local function restore(group)
    for instance, properties in pairs(patchSets[group] or {}) do
        for property, original in pairs(properties) do
            pcall(function() instance[property] = original[1] end)
        end
    end
    patchSets[group] = nil
end

local function updateEffects(instance)
    if instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
        or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles")
        or instance:IsA("PostEffect") then
        if instance == line then return end
        if C.DisableEffects or C.ExtremeOptimization then patch("effects", instance, "Enabled", false) end
    end
    if C.ExtremeOptimization and instance:IsA("BasePart") then patch("shadows", instance, "CastShadow", false) end
end

local function applyPerformance()
    restore("effects"); restore("shadows"); restore("lighting")
    if C.DisableEffects or C.ExtremeOptimization then
        for _, instance in ipairs(workspace:QueryDescendants("ParticleEmitter, Trail, Beam, Smoke, Fire, Sparkles")) do updateEffects(instance) end
        for _, instance in ipairs(Lighting:QueryDescendants("PostEffect")) do updateEffects(instance) end
    end
    if C.LowPerformance or C.ExtremeOptimization then patch("lighting", Lighting, "GlobalShadows", false) end
    if C.ExtremeOptimization then
        for _, instance in ipairs(workspace:QueryDescendants("BasePart")) do updateEffects(instance) end
    end
    controller.Config.UI_INTERVAL = C.LowPerformance and 0.5 or 0.15
    controller.Config.TARGET_SCAN_INTERVAL = C.LowPerformance and 0.5 or 0.25
    controller.SetWaypoints(C.Waypoints and not C.ExtremeOptimization)
end

local function clearHover()
    if hoverForce then hoverForce:Destroy(); hoverForce = nil end
    if hoverAttachment then hoverAttachment:Destroy(); hoverAttachment = nil end
end

local function clearLine()
    if line then line:Destroy(); line = nil end
    if beamStart then beamStart:Destroy(); beamStart = nil end
    if beamEnd then beamEnd:Destroy(); beamEnd = nil end
end

local function restoreMovement()
    for humanoid, original in pairs(movementOriginal) do
        for property, value in pairs(original) do pcall(function() humanoid[property] = value end) end
    end
    table.clear(movementOriginal)
end

local function movementProperty(humanoid, property, value)
    local original = movementOriginal[humanoid]
    if value == nil then
        if original and original[property] ~= nil then
            humanoid[property] = original[property]
            original[property] = nil
        end
        return
    end
    if not original then original = {}; movementOriginal[humanoid] = original end
    if original[property] == nil then original[property] = humanoid[property] end
    if humanoid[property] ~= value then humanoid[property] = value end
end

local function updateAppearance()
    restore("appearance")
    if not C.SpoofNames and not C.SpoofLevel then return end
    local name = C.SpoofName ~= "" and C.SpoofName or "Player"
    if C.ScrollingName and #name > 1 then
        local at = math.floor(os.clock() * 3) % #name
        name = name:sub(at + 1) .. " " .. name:sub(1, at)
    end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and C.SpoofNames then patch("appearance", humanoid, "DisplayName", name) end
    local roots = { player.PlayerGui }
    if character then table.insert(roots, character) end
    local actualLevel = Adapter.level()
    for _, root in ipairs(roots) do
        for _, label in ipairs(root:QueryDescendants("TextLabel")) do
            if C.SpoofNames and (label.Text == player.Name or label.Text == player.DisplayName) then
                patch("appearance", label, "Text", name)
            elseif C.SpoofLevel and actualLevel and label.Name:lower() == "level" and label.Text == tostring(actualLevel) then
                patch("appearance", label, "Text", tostring(C.DisplayLevel))
            elseif C.SpoofLevel and actualLevel and label.Text:match("^Level:?%s*" .. actualLevel .. "$") then
                patch("appearance", label, "Text", "Level " .. C.DisplayLevel)
            elseif C.SpoofLevel and actualLevel and label.Text:match("^Lv%.?%s*" .. actualLevel .. "$") then
                patch("appearance", label, "Text", "Lv. " .. C.DisplayLevel)
            end
        end
    end
end

local function equip(class)
    job("gear", function()
        local level = assert(Adapter.level(), "Player level not loaded")
        inventory = Adapter.inventory()
        local chosen = Logic.bestGear(inventory, level, class)
        local equipped = 0
        for _, entry in ipairs(chosen) do
            if not alive then return end
            if entry.item.equipped ~= true and Adapter.call("equipItem", entry.kind, tonumber(entry.id)) then equipped = equipped + 1 end
            task.wait(0.3)
        end
        notify(equipped > 0 and ("Equipped " .. equipped .. " " .. class:lower() .. " items") or "Best eligible gear already equipped, or no eligible gear")
    end)
end

local Window = Library:CreateWindow({
    Title = "Dungeon Quest Reborn", Footer = "Obsidian | " .. MODE,
    Center = true, AutoShow = true, Resizable = true, ShowCustomCursor = false,
    Size = UDim2.fromOffset(860, 650), NotifySide = "Right",
})
local tabs = {
    Player = Window:AddTab("Player", "user"), Farm = Window:AddTab("Dungeon", "swords"),
    Lobby = Window:AddTab("Lobby", "door-open"), Visuals = Window:AddTab("Farm Visuals", "eye"),
    Raid = Window:AddTab("Auto Raid", "crown"), Webhook = Window:AddTab("Webhook Logging", "send"),
    Settings = Window:AddTab("Settings", "settings"),
}
local function toggle(group, key, text, callback, tooltip)
    local control = group:AddToggle(key, { Text = text, Default = C[key], Tooltip = tooltip })
    control:OnChanged(function(value) C[key] = value; scheduleSave(); if callback then callback(value) end end)
    controls[key] = control
    return control
end
local function slider(group, key, text, min, max, rounding, callback)
    local control = group:AddSlider(key, { Text = text, Default = C[key], Min = min, Max = max, Rounding = rounding or 0 })
    control:OnChanged(function(value) C[key] = value; scheduleSave(); if callback then callback(value) end end)
    controls[key] = control
    return control
end
local function input(group, key, text, numeric, callback)
    local control = group:AddInput(key, { Text = text, Default = tostring(C[key]), Numeric = numeric or false, Finished = true, ClearTextOnFocus = false })
    control:OnChanged(function(value) C[key] = value; scheduleSave(); if callback then callback(value) end end)
    controls[key] = control
    return control
end
local function dropdown(group, key, text, values, callback, multi)
    local control = group:AddDropdown(key, { Text = text, Values = values, Default = C[key], Multi = multi or false, Searchable = #values > 8 })
    control:OnChanged(function(value) C[key] = value; scheduleSave(); if callback then callback(value) end end)
    controls[key] = control
    return control
end
local function label(group, key, text)
    labels[key] = group:AddLabel(text, true)
end
local function setLabel(key, text)
    if labels[key] then labels[key]:SetText(text) end
end

local movement = tabs.Player:AddLeftGroupbox("Movement", "footprints")
toggle(movement, "WalkSpeedEnabled", "Walk Speed")
slider(movement, "WalkSpeed", "Walk Speed", 0, 100)
toggle(movement, "JumpPowerEnabled", "Jump Power")
slider(movement, "JumpPower", "Jump Power", 0, 100)
local appearance = tabs.Player:AddRightGroupbox("Appearance", "user-round")
toggle(appearance, "SpoofNames", "Spoof Names", updateAppearance, "Local display only")
input(appearance, "SpoofName", "Spoof Name", false, updateAppearance)
toggle(appearance, "ScrollingName", "Scrolling Name", updateAppearance)
toggle(appearance, "SpoofLevel", "Spoof Level", updateAppearance, "Local display only; unlocks use your actual level")
slider(appearance, "DisplayLevel", "Display Level", 1, 300, 0, updateAppearance)
local loadout = tabs.Player:AddLeftGroupbox("Loadout", "backpack")
loadout:AddButton({ Text = "Equip Warrior Gear", Func = function() equip("Warrior") end })
loadout:AddButton({ Text = "Equip Mage Gear", Func = function() equip("Mage") end })
local stats = tabs.Player:AddRightGroupbox("Stats", "chart-no-axes-column")
label(stats, "Level", "Level: loading")
label(stats, "Points", "Unspent points: loading")
dropdown(stats, "UpgradeStat", "Stats To Upgrade", { "Spell Power", "Physical Power", "Stamina" })
toggle(stats, "AutoUpgrade", "Auto Upgrader", nil, "Spends available skill points on the selected stat")

local farm = tabs.Farm:AddLeftGroupbox("Dungeon Farm", "swords")
dropdown(farm, "FarmPosition", "Farm Position", { "Nearest", "Behind", "Front", "Left", "Right" })
slider(farm, "Distance", "Distance From NPC", 5, 55)
toggle(farm, "FarmSpeedEnabled", "Override Farm Speed")
slider(farm, "FarmSpeed", "Farm Speed", 8, 24)
slider(farm, "StartDelay", "Time To Start", 0, 300)
toggle(farm, "AutoDungeon", "Auto Dungeon", function(value) if not value then controller.SetRunning(false); clearHover() end end)
toggle(farm, "AutoAbilities", "Auto Abilities")
toggle(farm, "SpamAbilities", "Spam Abilities", nil, "Checks ready equipped abilities more often; game cooldowns still apply")
toggle(farm, "AutoReplay", "Auto Replay Dungeon")
toggle(farm, "SmartFarm", "Smart Farming", nil, "Aim supported splash spells at compact groups; preserve safety and nearest-enemy movement")
slider(farm, "GroupRadius", "Grouping Radius", 3, 12)
slider(farm, "CloseAoeRange", "Close AoE Distance", 4, 16)
slider(farm, "SpellRange", "Spell Range", 8, 100, 0, nil)
local helper = tabs.Farm:AddRightGroupbox("Helper", "shield")
toggle(helper, "DynamicDistance", "Dynamic Distance")
toggle(helper, "AdaptiveSpacing", "Adaptive Safety Spacing", nil, "Adds distance after taking damage and at low health; keeps your configured distance as the baseline")
slider(helper, "MeleeDistance", "Melee Distance", 5, 12)
toggle(helper, "Hover", "Hover Above Hitboxes", function(value) if not value then clearHover() end end)
slider(helper, "HoverHeight", "Hover Height", 0, 14)
toggle(helper, "AutoDodge", "Auto Dodge")
toggle(helper, "SoloHitless", "Solo Hitless Safety", nil, "When alone, forces dodge protection on, scans farther ahead, and uses larger telegraph margins while preserving bounded 8-stud dodge teleports")
slider(helper, "ReactionTime", "Reaction Time", 0.05, 0.8, 2)
slider(helper, "Standoff", "Standoff Distance", 0, 60)
slider(helper, "SafetyDistance", "Safety Distance", 0.25, 16, 2)
toggle(helper, "KickOnJoin", "Kick On Player Join", nil, "Disconnects your own account if an unapproved player joins")
toggle(helper, "AllowFriends", "Allow Friends")
input(helper, "AllowedPlayers", "Allow Players", false)
local dodge = tabs.Farm:AddRightGroupbox("Teleport Limits", "move-horizontal")
label(dodge, "Limits", "8 studs maximum | 0.5 second cooldown\n3 dodges / 18 studs per 3 seconds")
local combat = tabs.Farm:AddRightGroupbox("Combat Status", "activity")
label(combat, "CombatTarget", "Target: none")
label(combat, "CombatHealth", "Target HP: -")
label(combat, "FarmAim", "Splash group: -")
label(combat, "AbilityQ", "Q: unequipped")
label(combat, "AbilityE", "E: unequipped")
label(combat, "Hazards", "Active attacks: 0")
label(combat, "Navigation", "Navigation: idle")
label(combat, "Spacing", "Combat distance: -")
label(combat, "LastDamage", "Last hit: none")
local farmStats = tabs.Farm:AddLeftGroupbox("Statistics (Script Start)", "chart-line")
for _, entry in ipairs({ { "Status", "Status" }, { "Completed", "Dungeons Completed" }, { "Coins", "Coins Gained" }, { "Gems", "Gems Gained" }, { "Levels", "Levels Earned" }, { "Enemies", "Enemies Left" }, { "Uptime", "Uptime" } }) do label(farmStats, entry[1], entry[2] .. ": 0") end

local lobby = tabs.Lobby:AddLeftGroupbox("Dungeon", "door-open")
local function refreshDifficulties()
    if MODE ~= "Lobby" then
        setLabel("Requirements", "Requirements checked in lobby")
        return
    end
    job("requirements", function()
        local selected = C.Dungeon
        if type(selected) ~= "string" or not Adapter.level() then
            setLabel("Requirements", "Waiting for dungeon selection and player data")
            return
        end
        local data = Adapter.dungeonStats(selected)
        if not alive then return end
        if C.Dungeon ~= selected then task.defer(refreshDifficulties); return end
        local eligible = Logic.eligibleDifficulties(data, Adapter.level())
        local present, locked = {}, {}
        for _, difficulty in ipairs(Logic.Difficulties) do
            if data[difficulty] then
                table.insert(present, difficulty)
                if not table.find(eligible, difficulty) then table.insert(locked, difficulty) end
            end
        end
        controls.Difficulty:SetValues(present)
        controls.Difficulty:SetDisabledValues(locked)
        if not table.find(eligible, C.Difficulty) then controls.Difficulty:SetValue(eligible[1]) end
        setLabel("Requirements", #eligible > 0 and ("Available at your level: " .. table.concat(eligible, ", ")) or "Locked at your current level")
    end)
end
dropdown(lobby, "Dungeon", "Lobby Dungeon", Adapter.dungeons(), refreshDifficulties)
dropdown(lobby, "Difficulty", "Lobby Difficulty", Logic.Difficulties)
label(lobby, "Requirements", "Loading level requirements")
toggle(lobby, "AutoCreate", "Auto Create Lobby")
toggle(lobby, "AutoStart", "Auto Start Dungeon")
label(lobby, "LobbyAction", "Lobby: waiting")
local lobbyOptions = tabs.Lobby:AddRightGroupbox("Options", "list-filter")
toggle(lobbyOptions, "Hardcore", "Lobby Hardcore")
toggle(lobbyOptions, "PrivateLobby", "Private Lobby")
toggle(lobbyOptions, "WaveDefence", "Wave Defence")

local visualizer = tabs.Visuals:AddLeftGroupbox("Farm Visualizer", "scan-eye")
toggle(visualizer, "TargetLine", "Target Line", function(value) if not value then clearLine() end end)
toggle(visualizer, "Waypoints", "Waypoints", applyPerformance)
local performance = tabs.Visuals:AddLeftGroupbox("Performance", "gauge")
input(performance, "FPSCap", "FPS Cap", true, function(value)
    local cap = tonumber(value)
    if not cap or cap < 15 or cap > 360 then notify("FPS cap must be between 15 and 360"); return end
    if type(setfpscap) == "function" then setfpscap(cap); fpsChanged = true end
end)
controls.FPSCap:SetDisabled(type(setfpscap) ~= "function")
toggle(performance, "Disable3D", "Disable 3D Rendering", function(value) RunService:Set3dRenderingEnabled(not value) end)
toggle(performance, "DisableEffects", "Disable Effects", applyPerformance)
toggle(performance, "LowPerformance", "Low Performance Mode", applyPerformance)
toggle(performance, "ExtremeOptimization", "Extreme Optimization", applyPerformance)
local extra = tabs.Visuals:AddRightGroupbox("Extra Stats", "timer")
label(extra, "Average", "Avg Dungeon Time: 00:00:00")
label(extra, "Failed", "Dungeons Failed: 0")

local raid = tabs.Raid:AddLeftGroupbox("Boss Raid", "crown")
toggle(raid, "AutoRaid", "Auto Raid")
toggle(raid, "AdvanceTier", "Advance Tier")
toggle(raid, "AutoReplayRaid", "Auto Replay Raid")
dropdown(raid, "RaidTier", "Raid Tier", { "1" })
local raidStatus = tabs.Raid:AddRightGroupbox("Status", "activity")
label(raidStatus, "Tier", "Current Tier: loading")
label(raidStatus, "CurrentTier", "Current Tier: none")
label(raidStatus, "RaidAction", "Raid Action: waiting")
local function refreshInventory()
    inventory = Adapter.inventory()
    if controller.SetAbilityInventory then controller.SetAbilityInventory(inventory) end
    if not alive then return end
    local tiers = Logic.raidTiers(inventory)
    local values = {}
    for _, tier in ipairs(tiers) do table.insert(values, tostring(tier)) end
    controls.RaidTier:SetValues(values)
    if not table.find(values, C.RaidTier) then controls.RaidTier:SetValue(values[1]) end
    setLabel("Tier", "Owned Tiers: " .. (#values > 0 and table.concat(values, ", ") or "No raid keys"))
end
raid:AddButton({ Text = "Refresh Raid Keys", Func = function() job("inventory", refreshInventory) end })

local function webhookPayload(record)
    local fields = {}
    local values = {
        Dungeon = record.Dungeon or (MODE == "Dungeon" and Adapter.PlaceManager.GetDungeonName()) or C.Dungeon,
        Difficulty = record.Difficulty or C.Difficulty, Result = record.Result or "Session log",
        Duration = Logic.duration(record.Duration or os.clock() - startedAt),
        Coins = record.Coins or totals.Coins, Gems = record.Gems or totals.Gems, Levels = record.Levels or totals.Levels,
        Kills = record.Kills or controller.State.kills, Deaths = record.Deaths or totals.Deaths,
        Items = record.ItemsText or "No recorded drops",
    }
    for _, name in ipairs({ "Dungeon", "Difficulty", "Result", "Duration", "Coins", "Gems", "Levels", "Kills", "Deaths", "Items" }) do
        if C.WebhookDetails[name] then table.insert(fields, { name = name, value = tostring(values[name]):sub(1, 1024), inline = name ~= "Items" }) end
    end
    local embed = { title = "Dungeon Quest Reborn", color = 4173189, fields = fields }
    if C.ItemImages and record.Image then
        embed[C.LargeItemImages and "image" or "thumbnail"] = { url = record.Image }
    end
    return { username = "Dungeon Quest", allowed_mentions = { parse = {} }, embeds = { embed } }
end

local function sendWebhook(record)
    if not Logic.validWebhook(C.WebhookURL) then notify("Enter a valid Discord webhook URL"); return end
    if os.clock() - lastWebhook < 5 then notify("Wait before sending another webhook"); return end
    local requestFn = request or http_request or (syn and syn.request)
    if type(requestFn) ~= "function" then notify("HTTP requests are unavailable"); return end
    lastWebhook = os.clock()
    job("webhook", function()
        if C.ItemImages and record.Asset and not record.Image then
            local ok, thumbnail = pcall(function()
                local url = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. record.Asset .. "&size=420x420&format=Png&isCircular=false"
                local data = HttpService:JSONDecode(game:HttpGet(url))
                return data.data and data.data[1] and data.data[1].imageUrl
            end)
            if ok and type(thumbnail) == "string" and thumbnail:match("^https://") then record.Image = thumbnail end
        end
        local response = requestFn({ Url = C.WebhookURL, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(webhookPayload(record)) })
        local status = tonumber(response and response.StatusCode) or 0
        notify(status >= 200 and status < 300 and "Webhook sent" or ("Webhook failed (HTTP " .. status .. ")"))
    end)
end

local webhook = tabs.Webhook:AddLeftGroupbox("Dungeon Webhook", "send")
toggle(webhook, "Webhook", "Webhook Logging")
input(webhook, "WebhookURL", "Webhook URL", false)
webhook:AddButton({ Text = "Test Send", Func = function() sendWebhook({ Result = "Test" }) end })
local details = tabs.Webhook:AddRightGroupbox("Details To Show", "list")
dropdown(details, "WebhookDetails", "Webhook Details", { "Dungeon", "Difficulty", "Result", "Duration", "Coins", "Gems", "Levels", "Kills", "Deaths", "Items" }, nil, true)
toggle(details, "ItemImages", "Item Images")
toggle(details, "LargeItemImages", "Large Item Images")
local developer = tabs.Webhook:AddLeftGroupbox("Developer", "activity")
for _, entry in ipairs({ { "Collected", "Data Collected" }, { "Freezes", "Freezes Logged" }, { "Deaths", "Deaths Logged" }, { "Runs", "Runs Recorded" } }) do label(developer, entry[1], entry[2] .. ": 0") end
developer:AddButton({ Text = "Send Farm Log", Func = function() sendWebhook(lastRun or {}) end })

local function unload()
    if not alive then return end
    saveConfig()
    alive = false
    controller.Shutdown()
    clearLine(); clearHover(); restoreMovement()
    for group in pairs(patchSets) do restore(group) end
    for _, connection in ipairs(hooks) do connection:Disconnect() end
    RunService:Set3dRenderingEnabled(true)
    if fpsChanged and previousFPS and type(setfpscap) == "function" then setfpscap(previousFPS) end
    if env.DungeonQuestObsidian and env.DungeonQuestObsidian.Config == C then env.DungeonQuestObsidian = nil end
    if not Library.Unloaded then Library:Unload() end
end
Library:OnUnload(unload)
local settings = tabs.Settings:AddLeftGroupbox("Menu", "settings")
local queueTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
settings:AddLabel("Teleport continuation: " .. (type(queueTeleport) == "function" and "Available" or "Unavailable"))
settings:AddLabel("Menu key"):AddKeyPicker("MenuKey", { Default = "RightShift", NoUI = true, Text = "Menu" })
Library.ToggleKeybind = Library.Options.MenuKey
Library.Options.MenuKey:OnChanged(function()
    menuKey = Library.Options.MenuKey.Value
    scheduleSave()
end)
settings:AddButton({ Text = "Unload", Func = unload })

env.DungeonQuestObsidian = { Unload = unload, Config = C, Controller = controller, Library = Library, Totals = totals, Errors = errors, Mode = MODE,
    Elapsed = function() return os.clock() - startedAt end }
local teleportQueued = false
connect(player.OnTeleport, function(teleportState)
    if teleportState == Enum.TeleportState.Failed then teleportQueued = false; return end
    if teleportState ~= Enum.TeleportState.Started then return end
    saveConfig()
    if env.autoexecute == false or teleportQueued or type(queueTeleport) ~= "function" then return end
    local loaderURL = env.DQObsidianLoaderURL or "https://raw.githubusercontent.com/glitchreal/Dungeon-quest/main/main.luau"
    local snapshot = HttpService:JSONEncode({ Config = C, Totals = totals, Elapsed = os.clock() - startedAt })
    local queued = string.format("getgenv().autoexecute=true\ngetgenv().autoloadconfig=%s\ngetgenv().DQObsidianResume=game:GetService('HttpService'):JSONDecode(%q)\nassert(loadstring(game:HttpGet(%q)))()", tostring(env.autoloadconfig ~= false), snapshot, loaderURL)
    queueTeleport(queued)
    teleportQueued = true
end)
connect(workspace.DescendantAdded, updateEffects)
connect(Lighting.DescendantAdded, updateEffects)
connect(player.CharacterAdded, function() clearLine(); clearHover(); restoreMovement() end)
connect(Players.PlayerAdded, function(joined)
    if not C.KickOnJoin or joined == player then return end
    job("join-" .. joined.UserId, function()
        if Logic.allowedPlayer(joined.Name, joined.UserId, C.AllowedPlayers) then return end
        if C.AllowFriends then
            local ok, friend = pcall(player.IsFriendsWith, player, joined.UserId)
            if not ok or friend then return end
        end
        if alive and C.KickOnJoin then
            controller.SetRunning(false)
            player:Kick("Dungeon Quest: unapproved player joined")
        end
    end)
end)

local runBalances, runDeaths, runKills, runInventory
local function finishRun(success)
    if runCounted then return end
    runCounted, runEnded = true, true
    controller.SetRunning(false)
    clearHover()
    local duration = runStartedAt and os.clock() - runStartedAt or 0
    totals.Runs = totals.Runs + 1
    totals[success and "Completed" or "Failed"] = totals[success and "Completed" or "Failed"] + 1
    if success then totals.Duration = totals.Duration + duration end
    local before = runBalances or Adapter.balances()
    local replayAt = os.clock()
    job("finish", function()
        task.wait(1)
        if not alive then return end
        local after = Adapter.balances()
        local data = Adapter.replayData()
        local record = { Dungeon = data.dungeonName, Difficulty = data.difficulty, Result = success and "Completed" or "Failed", Duration = duration,
            Coins = math.max(0, after.Coins - before.Coins), Gems = math.max(0, after.Gems - before.Gems), Levels = math.max(0, after.Levels - before.Levels),
            Deaths = totals.Deaths - (runDeaths or 0), Kills = controller.State.kills - (runKills or 0) }
        local items = {}
        local ok, current = pcall(Adapter.inventory)
        if ok and runInventory then
            for _, category in ipairs({ "weapons", "helmets", "chests", "abilities" }) do
                for id, item in pairs(current[category] or {}) do
                    if not (runInventory[category] or {})[id] then
                        table.insert(items, item.name or id)
                        local asset = tostring(item.imageId or ""):match("rbxassetid://(%d+)")
                        if asset then record.Asset = asset end
                    end
                end
            end
        end
        record.ItemsText = #items > 0 and table.concat(items, "\n") or "No recorded drops"
        lastRun = record
        if C.Webhook then sendWebhook(record) end
        local replay = Adapter.PlaceManager.IsBossKey() and C.AutoReplayRaid or (not Adapter.PlaceManager.IsBossKey() and C.AutoReplay)
        if replay then
            task.wait(math.max(0, 3 - (os.clock() - replayAt)))
            if alive and (Adapter.PlaceManager.IsBossKey() and C.AutoReplayRaid or not Adapter.PlaceManager.IsBossKey() and C.AutoReplay) then Adapter.replay(C.AdvanceTier) end
        end
    end)
end
for name, success in pairs({ loadCompleteGui = true, loadFailedGui = false }) do
    local remote = Adapter.Remotes:FindFirstChild(name)
    if MODE == "Dungeon" and remote then connect(remote.OnClientEvent, function() finishRun(success) end) end
end

local lastHealth, lastHumanoid, lastSlow = nil, nil, 0
local function slowTick(now)
    if not Adapter.level() then
        setLabel("Level", "Level: loading")
        return
    end
    local current = Adapter.balances()
    if not balancesReady then
        balances, balancesReady = current, true
        refreshDifficulties()
    end
    for key, value in pairs(current) do
        totals[key] = totals[key] + math.max(0, value - balances[key])
    end
    if current.Levels ~= balances.Levels then refreshDifficulties() end
    balances = current
    local pm = Adapter.PlaceManager
    local inLevel = MODE == "Dungeon"
    local inRaid = inLevel and pm.IsBossKey()
    local started = inLevel and pm.HasDungeonStarted()
    if started and not wasStarted then
        runStartedAt, runCounted, runEnded = now, false, false
        runBalances, runDeaths, runKills = current, totals.Deaths, 0
        job("runInventory", function() runInventory = Adapter.inventory() end)
    end
    wasStarted = started
    if not runCounted and started and Adapter.finished() then finishRun(true) end
    local farming = (C.AutoDungeon or (C.AutoRaid and inRaid)) and started and not runEnded and now - placeStartedAt >= C.StartDelay
    controller.SetRunning(farming == true)
    if not farming then clearHover() end

    if C.AutoUpgrade and now - lastUpgrade >= 2 then
        local points = Adapter.value(player, "skillPoints", 0)
        if points > 0 then
            lastUpgrade = now
            job("upgrade", function()
                if not C.AutoUpgrade then return end
                local stat = ({ ["Spell Power"] = "spellPower", ["Physical Power"] = "physicalPower", Stamina = "stamina" })[C.UpgradeStat]
                Adapter.call("spendSkillPoint", stat, points)
            end)
        end
    end
    if (C.AutoRaid or C.SmartFarm) and now - lastInv >= 30 then lastInv = now; job("inventory", refreshInventory) end
    if now - lastQueue >= 5 and (C.AutoCreate or C.AutoStart or C.AutoRaid) and not started and not runEnded then
        lastQueue = now
        job("queue", function()
            local nextLobby, nextRaid = queueAction(C, now, placeStartedAt)
            lobbyAction, raidAction = nextLobby or lobbyAction, nextRaid or raidAction
        end)
    end
    updateAppearance()
    setLabel("Level", "Level: " .. tostring(Adapter.level() or "loading"))
    setLabel("Points", "Unspent points: " .. Adapter.value(player, "skillPoints", 0))
    setLabel("Status", "Status: " .. controller.State.status)
    local combatState = controller.State
    setLabel("CombatTarget", "Target: " .. (combatState.targetName or "none") .. " | " .. math.floor(combatState.targetDist or 0) .. " studs")
    local targetHumanoid = combatState.currentTarget and combatState.currentTarget:FindFirstChildOfClass("Humanoid")
    setLabel("CombatHealth", targetHumanoid and ("Target HP: " .. math.ceil(targetHumanoid.Health) .. "/" .. math.ceil(targetHumanoid.MaxHealth)) or "Target HP: -")
    setLabel("FarmAim", C.SmartFarm and ("Last splash aim: " .. (combatState.groupCount or 0) .. " nearby enemies (estimate)") or "Smart farming: off")
    local abilityStatus = controller.AbilityStatus and controller.AbilityStatus() or {}
    for _, slot in ipairs({ "q", "e" }) do
        local ability = abilityStatus[slot]
        local text = ability and (ability.name .. " | " .. (ability.cooldown > 0 and string.format("%.1fs", ability.cooldown) or "Ready")) or "unequipped"
        if ability and controller.AbilityProfile then
            local profile = controller.AbilityProfile(ability)
            text = text .. " | " .. profile.mode .. " | " .. (profile.range and tostring(profile.range) .. " st" or "range estimated")
        end
        local count = slot == "q" and combatState.skillQ_count or combatState.skillE_count
        setLabel(slot == "q" and "AbilityQ" or "AbilityE", slot:upper() .. ": " .. text .. " | " .. (count or 0) .. " casts")
    end
    setLabel("Hazards", "Active attacks: " .. #(combatState.activeZones or {}) .. " | Dodges: " .. (combatState.dodgeCount or 0))
    setLabel("Navigation", (combatState.pathStatus or "Navigation: idle") .. " | Plans: " .. (combatState.pathComputations or 0))
    setLabel("Spacing", string.format("Combat distance: %.0f studs", controller.Config.COMBAT_DISTANCE or 0))
    local damage = combatState.lastDamage
    setLabel("LastDamage", damage and string.format("Last hit: %.0f HP | %.0fs ago", damage.amount, now - damage.at) or "Last hit: none")
    local names = { Completed = "Dungeons Completed", Coins = "Coins Gained", Gems = "Gems Gained", Levels = "Levels Earned", Failed = "Dungeons Failed", Deaths = "Deaths Logged", Freezes = "Freezes Logged", Runs = "Runs Recorded" }
    for key, title in pairs(names) do setLabel(key, title .. ": " .. totals[key]) end
    local enemies = 0
    for _, model in ipairs(controller.State.cachedTargets) do
        local h = model:FindFirstChildOfClass("Humanoid")
        if h and h.Health > 0 then enemies = enemies + 1 end
    end
    setLabel("Enemies", "Enemies Left: " .. enemies)
    setLabel("Uptime", "Uptime: " .. Logic.duration(now - startedAt))
    setLabel("Collected", "Data Collected: " .. math.floor((now - startedAt) / 60) .. "m")
    setLabel("Average", "Avg Dungeon Time: " .. Logic.duration(totals.Completed > 0 and totals.Duration / totals.Completed or 0))
    setLabel("LobbyAction", "Lobby: " .. lobbyAction)
    setLabel("RaidAction", "Raid Action: " .. raidAction)
    local teleport = inLevel and pm.GetPlaceTeleportData()
    local raidData = teleport and teleport.dungeonStats or {}
    setLabel("CurrentTier", "Current Tier: " .. tostring(raidData.tier or (inRaid and C.RaidTier) or "none"))
end

connect(RunService.Heartbeat, function(dt)
    if not alive then return end
    local now = os.clock()
    if dt > 1 then totals.Freezes = totals.Freezes + 1 end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if humanoid then
        if lastHumanoid == humanoid and lastHealth and lastHealth > 0 and humanoid.Health <= 0 then totals.Deaths = totals.Deaths + 1 end
        lastHumanoid, lastHealth = humanoid, humanoid.Health
        movementProperty(humanoid, "WalkSpeed", C.WalkSpeedEnabled and C.WalkSpeed or (C.FarmSpeedEnabled and controller.State.running and C.FarmSpeed or nil))
        movementProperty(humanoid, "JumpPower", C.JumpPowerEnabled and C.JumpPower or nil)
        movementProperty(humanoid, "UseJumpPower", C.JumpPowerEnabled and true or nil)
    end
    local target = controller.State.currentTarget
    local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
    local cfg = controller.Config
    local distance = C.Distance
    if C.DynamicDistance then
        local melee = false
        for _, weapon in ipairs(character and character:GetChildren() or {}) do
            if weapon:IsA("Accessory") and weapon:FindFirstChild("Weapon") then
                melee = Adapter.value(weapon, "physicalDamage", 0) > Adapter.value(weapon, "spellPower", 0)
                break
            end
        end
        distance = melee and C.MeleeDistance or C.Standoff
    end
    if C.AdaptiveSpacing and humanoid and humanoid.Health > 0 and humanoid.MaxHealth > 0 then
        local missing = 1 - humanoid.Health / humanoid.MaxHealth
        local healthBuffer = math.clamp((missing - 0.35) / 0.4, 0, 1) * 8
        local damage = controller.State.lastDamage
        local damageBuffer = damage and now - damage.at < 5 and 3 or 0
        distance = distance + math.max(healthBuffer, damageBuffer)
    end
    local soloHitless = C.SoloHitless and #Players:GetPlayers() == 1
    if soloHitless then distance = math.max(distance, 20) end
    if target and target.Name == "Ancient Temple Protector" then distance = 16 end
    if C.SmartFarm and controller.AbilityStatus then
        if C.AdaptiveSpacing and targetRoot then
            local contactDistance = math.max(cfg.MELEE_DANGER_DISTANCE or 11,
                math.min(18, math.max(targetRoot.Size.X, targetRoot.Size.Z) * 0.5 + 6))
            distance = math.max(distance, contactDistance + 2)
        end
        for _, snapshot in pairs(controller.AbilityStatus()) do
            local profile = controller.AbilityProfile(snapshot)
            if profile.mode == "target" or profile.mode == "splash" then
                distance = math.min(distance, math.max(1, (profile.range or C.SpellRange) - 3))
            end
        end
    end
    cfg.COMBAT_DISTANCE = math.max(1, distance)
    cfg.COMBAT_MIN_DISTANCE, cfg.COMBAT_MAX_DISTANCE = math.max(0, distance - 3), distance + 3
    cfg.FARM_POSITION = C.FarmPosition
    cfg.PRECAST_MARGIN = math.max(C.SafetyDistance, soloHitless and 6 or 0)
    cfg.HAZARD_MARGIN = math.max(6, C.SafetyDistance + 3, soloHitless and 9 or 0)
    cfg.AUTO_ABILITIES, cfg.AUTO_DODGE = C.AutoAbilities, C.AutoDodge or soloHitless
    cfg.HITLESS_SOLO = C.SoloHitless
    cfg.REACTION_TIME = soloHitless and math.min(C.ReactionTime, 0.05) or C.ReactionTime
    cfg.PROJECTILE_LOOKAHEAD = soloHitless and 1.75 or 1.35
    cfg.THREAT_RADIUS = soloHitless and 120 or 90
    cfg.MELEE_DANGER_DISTANCE = soloHitless and math.max(11, C.MeleeDistance) or 11
    cfg.SMART_FARM, cfg.GROUP_RADIUS, cfg.CLOSE_AOE_RANGE = C.SmartFarm, C.GroupRadius, C.CloseAoeRange
    cfg.SPELL_RANGE_OVERRIDE = C.SpellRange
    cfg.SKILL_COOLDOWN = C.SpamAbilities and 0.35 or 0.2
    if C.TargetLine and root and targetRoot and controller.State.running then
        if not line or beamStart.Parent ~= root or beamEnd.Parent ~= targetRoot then
            clearLine()
            beamStart, beamEnd = Instance.new("Attachment"), Instance.new("Attachment")
            beamStart.Parent, beamEnd.Parent = root, targetRoot
            line = Instance.new("Beam")
            line.Attachment0, line.Attachment1 = beamStart, beamEnd
            line.FaceCamera, line.Width0, line.Width1 = true, 0.08, 0.08
            line.Color = ColorSequence.new(Color3.fromRGB(63, 205, 134))
            line.Parent = root
        end
    else clearLine() end
    if C.Hover and C.HoverHeight > 0 and root and targetRoot and humanoid and humanoid.Health > 0
        and controller.State.running and controller.State.lastThreatPart and #(controller.State.activeZones or {}) == 0 then
        if not hoverForce or hoverForce.Parent ~= root then
            clearHover()
            hoverAttachment = Instance.new("Attachment")
            hoverAttachment.Parent = root
            hoverForce = Instance.new("VectorForce")
            hoverForce.Attachment0 = hoverAttachment
            hoverForce.RelativeTo = Enum.ActuatorRelativeTo.World
            hoverForce.ApplyAtCenterOfMass = true
            hoverForce.Parent = root
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { character, target }
        params.RespectCanCollide = true
        local floor = workspace:Raycast(root.Position, Vector3.new(0, -40, 0), params)
        if floor then
            local height = floor.Position.Y + humanoid.HipHeight + root.Size.Y / 2 + C.HoverHeight
            local acceleration = math.clamp((height - root.Position.Y) * 20 - root.AssemblyLinearVelocity.Y * 8, -workspace.Gravity, 100)
            hoverForce.Force = Vector3.new(0, root.AssemblyMass * (workspace.Gravity + acceleration), 0)
        else clearHover() end
    else clearHover() end
    if now - lastSlow >= 0.5 and not busy.slow then
        lastSlow = now
        job("slow", function() slowTick(now) end)
    end
end)

if env.autoloadconfig ~= false then
    local saved
    if type(readfile) == "function" then
        local ok, data = pcall(function() return HttpService:JSONDecode(readfile(configPath)) end)
        if ok and type(data) == "table" and data.Version == 1 then saved = data end
    end
    local values = type(resume) == "table" and resume.Config or saved and saved.Config
    if type(values) == "table" then
        for key, value in pairs(values) do
            if controls[key] and configDefaults[key] ~= nil then
                local expected = type(configDefaults[key])
                if expected == "number" then value = tonumber(value) end
                if type(value) == expected then
                    if key == "Dungeon" and not table.find(controls.Dungeon.Values, value) then
                        local dungeonValues = table.clone(controls.Dungeon.Values)
                        table.insert(dungeonValues, value)
                        controls.Dungeon:SetValues(dungeonValues)
                    end
                    local ok = pcall(function() controls[key]:SetValue(value) end)
                    if not ok then errors.config = "Some saved settings could not be restored" end
                end
            end
        end
    end
    if saved and type(saved.MenuKey) == "string" then
        pcall(function() Library.Options.MenuKey:SetValue({ saved.MenuKey, "Toggle" }) end)
    end
end
saveReady = true
if env.autoloadconfig ~= false and type(resume) == "table" then scheduleSave() end
if type(writefile) ~= "function" then notify("Automatic saving is unavailable in this executor") end
refreshDifficulties()
job("inventory", refreshInventory)
if MODE == "Lobby" then tabs.Lobby:Show() else tabs.Farm:Show() end
notify("Dungeon Quest controls loaded")
