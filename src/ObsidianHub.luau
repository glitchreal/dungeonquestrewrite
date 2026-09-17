-- Three-role Obsidian front end. Combat remains in the original pathfinding controller.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local player, env = Players.LocalPlayer, getgenv()
local resume = env.DQRewriteResume
env.DQRewriteResume = nil
if env.DungeonQuestObsidian then env.DungeonQuestObsidian.Unload() end
local configPath = "DungeonQuestRewrite-" .. player.UserId .. ".json"
local C = {
    Enabled = false, Role = "Carry", Host = "", Carry = "", Alts = "",
    AutoJoin = true, AutoAccept = true, Hardcore = false, Whitelist = true,
    LevelKaitun = true, AutoBest = true, AutoSwitch = true, ProvisionHeals = true,
    AutoHealer = false, AutoSell = false, KeepItems = "", KeepLegendary = true, AutoSkillPoints = false, UpgradeStat = "Stamina",
    SyncEnabled = false, SyncURL = "", SyncKey = "",
    OCD = false, RecoveryGrace = 45, JoinInterval = 10, StartDelay = 3,
    HideUI = false, CPUSaver = false, Waypoints = false,
    Distance = 20, SpellRange = 26, AutoDodge = true,
}
local defaults = table.clone(C)
local partyPath = "DungeonQuestRewrite-party.json"
local function profilePath(role) return "DungeonQuestRewrite-role-" .. role .. ".json" end
local function readShared(path)
    if type(readfile) ~= "function" then return nil end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
    if ok and type(data) == "table" and data.Version == 1 then return data end
end
local accountOnly = { SyncEnabled = true, SyncURL = true, SyncKey = true }
local function applyValues(values)
    for key, value in pairs(type(values) == "table" and values or {}) do
        if not accountOnly[key] and defaults[key] ~= nil and type(value) == type(defaults[key]) then C[key] = value end
    end
end
local runtime, menuKey = {}, "RightShift"
if env.autoloadconfig ~= false then
    local saved = resume
    if not saved and type(readfile) == "function" then
        local ok, value = pcall(function() return HttpService:JSONDecode(readfile(configPath)) end)
        if ok and type(value) == "table" and value.Version == 2 then saved = value end
    end
    if type(saved) == "table" then
        for key, value in pairs(saved.Config or {}) do
            if C[key] ~= nil and type(C[key]) == type(value) then C[key] = value end
        end
        if type(saved.Runtime) == "table" then runtime = saved.Runtime end
        if type(saved.MenuKey) == "string" then menuKey = saved.MenuKey end
    end
end
-- A teleport snapshot belongs to this account and takes precedence over shared profiles.
if env.autoloadconfig ~= false and type(resume) ~= "table" then
    local shared = readShared(partyPath)
    local party = shared and type(shared.Party) == "table" and shared.Party or table.clone(C)
    local detected = Logic.accountRole(party, player.Name, player.UserId)
    if detected then
        local profile = readShared(profilePath(detected))
        if profile and type(profile.Config) == "table" then
            applyValues(profile.Config)
            if type(profile.MenuKey) == "string" then menuKey = profile.MenuKey end
        elseif C.Role ~= detected then
            applyValues(defaults)
        end
        C.Role = detected
    end
    for _, key in ipairs({ "Host", "Carry", "Alts" }) do
        if type(party[key]) == "string" then C[key] = party[key] end
    end
end
-- A private setup loader can configure the relay without publishing credentials.
local syncSetup = env.DQRewriteSync
if type(syncSetup) == "table" and type(syncSetup.URL) == "string" and type(syncSetup.Key) == "string" then
    C.SyncURL, C.SyncKey, C.SyncEnabled = syncSetup.URL, syncSetup.Key, true
    env.DQRewriteSync = nil
end
if not table.find({ "Carry", "Host", "Alt" }, C.Role) then C.Role = "Carry"; C.Enabled = false end
C.Alts = table.concat(Logic.tokens(C.Alts), ", ")
C.RecoveryGrace = math.clamp(C.RecoveryGrace, 15, 180)
C.JoinInterval = math.clamp(C.JoinInterval, 5, 60)
C.StartDelay = math.clamp(C.StartDelay, 0, 30)
C.Distance, C.SpellRange = math.clamp(C.Distance, 5, 55), math.clamp(C.SpellRange, 8, 100)
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/3df0deae2c50a06cf29cf3b6a047db62466d40b9/"
local Library = assert(loadstring(game:HttpGet(repo .. "Library.lua")))()
Library.ScreenGui.Parent = player:WaitForChild("PlayerGui")
Library.ScreenGui.ResetOnSpawn = false
Library.Scheme.AccentColor = Color3.fromRGB(63, 205, 134)
local controller = createController()
local alive, hooks, controls, errors = true, {}, {}, {}
local coordinator, partySync
local editingParty = false
local partyInputs = {}
local previousFPS = type(getfpscap) == "function" and getfpscap() or nil
local performanceApplied = false
local patches = setmetatable({}, { __mode = "k" })
local function identity() if type(setthreadidentity) == "function" then setthreadidentity(8) end end
local function connect(signal, callback)
    local connection = signal:Connect(function(...) identity(); callback(...) end)
    table.insert(hooks, connection)
end
local function snapshot()
    -- A teleport/unload can run before Roblox dispatches the last text-change event.
    for key, box in pairs(partyInputs) do
        if box.Parent then C[key] = box.Text end
    end
    return { Version = 2, Config = C, Runtime = runtime, MenuKey = menuKey }
end
local function save()
    if type(writefile) ~= "function" then errors.Save = "Executor file saving unavailable"; return end
    local ok = pcall(function() writefile(configPath, HttpService:JSONEncode(snapshot())) end)
    errors.Save = not ok and "Could not save settings" or nil
end
local function publishProfile(partyKey)
    if type(writefile) ~= "function" then return end
    local ok = pcall(function()
        -- Separate role files avoid carry/host/alt saves replacing each other's profiles.
        if Logic.accountRole(C, player.Name, player.UserId) == C.Role then
            local profile = table.clone(C)
            for key in pairs(accountOnly) do profile[key] = nil end
            writefile(profilePath(C.Role), HttpService:JSONEncode({ Version = 1, Config = profile, MenuKey = menuKey }))
        end
        local shared = readShared(partyPath)
        local party = shared and type(shared.Party) == "table" and shared.Party or { Host = C.Host, Carry = C.Carry, Alts = C.Alts }
        if partyKey then party[partyKey] = C[partyKey] end
        if partyKey or not shared then
            writefile(partyPath, HttpService:JSONEncode({ Version = 1, Party = party }))
        end
    end)
    errors.Profile = not ok and "Could not save shared role profile" or nil
end
-- Seed profiles from existing account settings without replacing a shared profile.
if env.autoloadconfig ~= false and Logic.accountRole(C, player.Name, player.UserId) == C.Role
    and not readShared(profilePath(C.Role)) then publishProfile() end
local function notify(text) identity(); Library:Notify({ Title = "Dungeon Quest Rewrite", Description = text, Time = 5 }) end
local function patch(instance, property, value)
    patches[instance] = patches[instance] or {}
    if patches[instance][property] == nil then patches[instance][property] = { instance[property] } end
    instance[property] = value
end
local function reduceEffect(instance)
    if not C.CPUSaver then return end
    if instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
        or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") or instance:IsA("PostEffect") then
        patch(instance, "Enabled", false)
    end
end
local function restorePerformance()
    for instance, properties in pairs(patches) do
        for property, old in pairs(properties) do pcall(function() instance[property] = old[1] end) end
    end
    table.clear(patches)
    if performanceApplied then
        RunService:Set3dRenderingEnabled(true)
        if type(setfpscap) == "function" then setfpscap(previousFPS or 60) end
    end
    performanceApplied = false
end
local function performance()
    restorePerformance()
    if C.CPUSaver then
        performanceApplied = true
        RunService:Set3dRenderingEnabled(false)
        if type(setfpscap) == "function" then setfpscap(30) end
        patch(Lighting, "GlobalShadows", false)
        for _, instance in ipairs(workspace:QueryDescendants("ParticleEmitter, Trail, Beam, Smoke, Fire, Sparkles")) do reduceEffect(instance) end
        for _, instance in ipairs(Lighting:QueryDescendants("PostEffect")) do reduceEffect(instance) end
    end
    controller.SetWaypoints(C.Waypoints and not C.CPUSaver)
end
local Window = Library:CreateWindow({ Title = "Dungeon Quest Rewrite", Footer = "Obsidian | " .. MODE,
    Center = true, AutoShow = true, Resizable = true, ShowCustomCursor = false, Size = UDim2.fromOffset(800, 650) })
local partyTab = Window:AddTab("Party", "users")
local roleTab = Window:AddTab("Roles", "swords")
local settingsTab = Window:AddTab("Settings", "settings")
local function change(key, value, callback)
    C[key] = value
    if coordinator then coordinator.Stop() end
    save()
    -- Shared profiles publish only on user edits, not periodic/runtime saves.
    publishProfile((key == "Host" or key == "Carry" or key == "Alts") and key or nil)
    if callback then callback(value) end
end
local function toggle(group, key, text, callback, tooltip)
    local control = group:AddToggle(key, { Text = text, Default = C[key], Tooltip = tooltip })
    control:OnChanged(function(value) change(key, value, callback) end)
    controls[key] = control
end
local function input(group, key, text, normalize, tooltip)
    local control = group:AddInput(key, { Text = text, Default = C[key], Finished = false, ClearTextOnFocus = false, Tooltip = tooltip })
    control:OnChanged(function(value)
        -- Save drafts without stripping separators while the user is still typing.
        change(key, value)
    end)
    controls[key] = control
    local box = control.Holder and control.Holder:FindFirstChildOfClass("TextBox")
    if box then
        partyInputs[key] = box
        connect(box.Focused, function()
            editingParty = true
            if coordinator then coordinator.Stop() end
        end)
        connect(box.FocusLost, function()
            control:SetValue(normalize and normalize(box.Text) or box.Text)
            editingParty = false
        end)
    end
end
local function dropdown(group, key, text, values)
    local control = group:AddDropdown(key, { Text = text, Values = values, Default = C[key] })
    control:OnChanged(function(value) change(key, value) end)
    controls[key] = control
end
local function slider(group, key, text, min, max)
    local control = group:AddSlider(key, { Text = text, Default = C[key], Min = min, Max = max, Rounding = 0 })
    control:OnChanged(function(value) change(key, value) end)
    controls[key] = control
end
local automation = partyTab:AddLeftGroupbox("Automation")
toggle(automation, "Enabled", "Enable role automation", nil, "Starts the selected Carry, Host, or Alt role. Choose Host to create dungeons.")
automation:AddLabel("Select your account role and fill in the party below. Host creates dungeons; carry and alts request the host.", true)
local roleAutomation = roleTab:AddLeftGroupbox("Automation")
roleAutomation:AddButton({ Text = "Start selected role", Func = function() controls.Enabled:SetValue(true) end })
roleAutomation:AddButton({ Text = "Stop role automation", Func = function() controls.Enabled:SetValue(false) end })
local roleStatusLabel = roleAutomation:AddLabel("", true)
local setup = partyTab:AddLeftGroupbox("Account and party")
dropdown(setup, "Role", "This account", { "Carry", "Host", "Alt" })
input(setup, "Host", "Host username or user ID")
input(setup, "Carry", "Carry username or user ID")
input(setup, "Alts", "Selected alts (paste list)", function(value)
    return table.concat(Logic.tokens(value), ", ")
end, "Paste usernames or user IDs separated by newlines, spaces, tabs, commas, or semicolons. Press Enter or click away to format the list and remove duplicates.")
setup:AddLabel("Party list and role settings are shared on this executor workspace. Reload each account to detect its role. Host and alts level together.", true)
local syncGroup = partyTab:AddLeftGroupbox("Cross-client sync")
toggle(syncGroup, "SyncEnabled", "Require scripts ready through relay", nil, "Enable on every selected account. Waits for fresh script heartbeats in the same dungeon and follows host regroup messages.")
input(syncGroup, "SyncURL", "Relay HTTPS URL")
input(syncGroup, "SyncKey", "Private relay key")
syncGroup:AddLabel("Use the same relay URL and key on every account. This does not execute scripts on other accounts.", true)
local syncLabel = syncGroup:AddLabel("Sync off", true)
local options = partyTab:AddRightGroupbox("Run options")
toggle(options, "Hardcore", "Hardcore (host)")
toggle(options, "Whitelist", "Private / whitelist lobby (host)")
toggle(options, "ProvisionHeals", "Farm Pirate Island for Universal Heal", nil, "Enable on every account. Uses eligible dungeons below level 60; leaves Pirate once the host and each selected alt own two Universal Heals and their levels match. The carry is excluded from heal requirements.")
toggle(options, "OCD", "OCD: regroup after disconnects", nil, "Pauses carry farming when anyone is missing. Waits indefinitely for initial arrivals; after an assembled party loses someone, returns to lobby after the grace period.")
slider(options, "RecoveryGrace", "Recovery grace (seconds)", 15, 180)
slider(options, "StartDelay", "Party-ready delay (seconds)", 0, 30)
local status = partyTab:AddRightGroupbox("Live status")
local statusLabel = status:AddLabel("Off — enable automation at the top of Party", true)
local partyLabel = status:AddLabel("Configure the selected accounts", true)
local levelLabel = status:AddLabel("Level: loading", true)
local errorLabel = status:AddLabel("", true)
local saveLabel = status:AddLabel("Settings for " .. player.Name, true)
local carry = roleTab:AddLeftGroupbox("1 · Carry")
toggle(carry, "LevelKaitun", "Level Kaitun: wait, start, and farm", nil, "Carry farms only with the entire selected party present. Keep this on for the host too so it can start on owner-only servers.")
slider(carry, "Distance", "Combat distance", 5, 55)
slider(carry, "SpellRange", "Spell range fallback", 8, 100)
toggle(carry, "AutoDodge", "Pathfinding hazard avoidance")
local join = roleTab:AddLeftGroupbox("Carry and alt")
toggle(join, "AutoJoin", "Send join requests to host")
slider(join, "JoinInterval", "Join request interval (seconds)", 5, 60)
toggle(join, "AutoSwitch", "Switch when host unlocks better dungeon", nil, "Waits for the run to finish and host/alt levels to match. A host leaving is not an unlock signal.")
local host = roleTab:AddRightGroupbox("2 · Host")
toggle(host, "AutoBest", "Create and join best eligible dungeon", nil, "Runs when this account is set to Host and role automation is enabled.")
toggle(host, "AutoAccept", "Accept selected accounts only")
host:AddLabel("Creates the dungeon, accepts the party, and replays until the host and selected alts match levels. Keep Level Kaitun enabled to start once everyone arrives.", true)
local alt = roleTab:AddRightGroupbox("3 · Alt")
toggle(alt, "AutoHealer", "Tank armor + Universal Heal only", nil, "Equips the highest eligible tank helmet/chest and up to two Universal Heals. Alternates ready heals at least 4 seconds apart when a selected party member needs healing.")
toggle(alt, "AutoSkillPoints", "Auto allocate skill points")
dropdown(alt, "UpgradeStat", "Allocate to", { "Stamina", "Spell Power", "Physical Power" })
local inventory = settingsTab:AddLeftGroupbox("All account types")
toggle(inventory, "AutoSell", "Auto sell all rarities", nil, "Works without role automation or party setup. Keeps two Universal Heals, equipped/locked/favorite items, and armor selected for the healer loadout.")
toggle(inventory, "KeepLegendary", "Keep legendary items", nil, "Excludes every legendary weapon, helmet, chest, and ability from Auto Sell. Saved per account; enabled by default.")
local keepItems = inventory:AddInput("KeepItems", {
    Text = "Keep items (full names, comma-separated)", Default = C.KeepItems,
    Finished = false, ClearTextOnFocus = false,
    Tooltip = "Enter full item names, separated by commas, semicolons, or pasted lines. Matches ignore capitalization and extra spaces. Every matching copy is kept. Editing stops Auto Sell; re-enable it when finished.",
})
keepItems:OnChanged(function(value)
    -- Do not sell while an item name is only partially typed.
    if C.AutoSell then controls.AutoSell:SetValue(false) end
    change("KeepItems", value)
end)
controls.KeepItems = keepItems
local sellLabel = inventory:AddLabel("Auto sell: off", true)
local display = settingsTab:AddRightGroupbox("Display and performance")
toggle(display, "HideUI", "Hide UI on execute")
toggle(display, "CPUSaver", "CPU saver", performance, "Disables 3D rendering, reduces effects, and caps FPS at 30. Restored when disabled or unloaded.")
toggle(display, "Waypoints", "Show pathfinding waypoints", performance)
local menu = settingsTab:AddLeftGroupbox("Menu")
local queueTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
menu:AddLabel("Teleport continuation: " .. (type(queueTeleport) == "function" and "available" or "rerun loader after teleport"), true)
menu:AddLabel("Menu key"):AddKeyPicker("MenuKey", { Default = menuKey, NoUI = true, Text = "Menu" })
Library.ToggleKeybind = Library.Options.MenuKey
Library.Options.MenuKey:OnChanged(function() menuKey = Library.Options.MenuKey.Value; save(); publishProfile() end)
local function unload()
    if not alive then return end
    save(); alive = false
    if coordinator then coordinator.Stop() end
    controller.Shutdown()
    for _, connection in ipairs(hooks) do connection:Disconnect() end
    restorePerformance()
    if env.DungeonQuestObsidian and env.DungeonQuestObsidian.Config == C then env.DungeonQuestObsidian = nil end
    if not Library.Unloaded then Library:Unload() end
end
Library:OnUnload(unload)
menu:AddButton({ Text = "Return to lobby", Func = function()
    if MODE == "Dungeon" then coordinator.Stop(); save(); Adapter.call("teleToLobby") end
end })
menu:AddButton({ Text = "Unload", Func = unload })
partySync = PartySync.new(C, MODE, function() return alive end)
coordinator = Roles.new(C, runtime, MODE, controller, save, function() return alive end, partySync)
env.DungeonQuestObsidian = { Config = C, Runtime = runtime, Controller = controller, Coordinator = coordinator,
    Library = Library, Sync = partySync, Unload = unload, Errors = errors, Mode = MODE }
local teleportQueued = false
connect(player.OnTeleport, function(state)
    if state == Enum.TeleportState.Failed then teleportQueued = false; coordinator.TeleportFailed(); return end
    if state ~= Enum.TeleportState.Started then return end
    coordinator.Stop(); save()
    if env.autoexecute == false or teleportQueued or type(queueTeleport) ~= "function" then return end
    local url = env.DQObsidianLoaderURL or "https://raw.githubusercontent.com/glitchreal/dungeonquestrewrite/main/main.luau"
    local queued = string.format("getgenv().autoexecute=true\ngetgenv().autoloadconfig=%s\ngetgenv().DQRewriteResume=game:GetService('HttpService'):JSONDecode(%q)\nassert(loadstring(game:HttpGet(%q)))()",
        tostring(env.autoloadconfig ~= false), HttpService:JSONEncode(snapshot()), url)
    queueTeleport(queued); teleportQueued = true
end)
if MODE == "Dungeon" then
    local requests = Adapter.Remotes:FindFirstChild("showJoinRequest")
    if requests then connect(requests.OnClientEvent, coordinator.OnRequest) end
    for _, name in ipairs({ "loadCompleteGui", "loadFailedGui" }) do
        local remote = Adapter.Remotes:FindFirstChild(name)
        if remote then connect(remote.OnClientEvent, function() coordinator.Finish(name == "loadFailedGui") end) end
    end
end
connect(workspace.DescendantAdded, reduceEffect)
connect(Lighting.DescendantAdded, reduceEffect)
connect(Players.PlayerRemoving, function() coordinator.Stop() end)
performance()
partyTab:Show()
if C.HideUI then Library:Toggle(false) end
local lastSave = os.clock()
task.spawn(function()
    while alive do
        identity()
        local cfg = controller.Config
        cfg.COMBAT_DISTANCE, cfg.COMBAT_MIN_DISTANCE, cfg.COMBAT_MAX_DISTANCE = C.Distance, math.max(0, C.Distance - 3), C.Distance + 3
        cfg.SPELL_RANGE_OVERRIDE, cfg.AUTO_DODGE = C.SpellRange, C.AutoDodge
        cfg.AUTO_ABILITIES = C.Role == "Carry"
        local ok, err = xpcall(function()
            if editingParty then
                coordinator.Stop()
                coordinator.status = "Paused while editing party fields"
            else coordinator.Tick(os.clock()) end
        end, debug.traceback)
        if not alive then break end
        if not ok then
            coordinator.Stop()
            errors.Automation = tostring(err)
            local reason = tostring(err):match("^[^\n]+") or "Unknown error"
            coordinator.status = "Blocked: " .. reason:gsub("^.-:%d+: ", "")
        else errors.Automation = nil end
        saveLabel:SetText(errors.Save or errors.Profile or ("Profile: " .. C.Role .. " | Account: " .. player.Name))
        syncLabel:SetText(partySync.status)
        roleStatusLabel:SetText(C.Role .. " · " .. coordinator.status)
        sellLabel:SetText(coordinator.sellStatus)
        statusLabel:SetText(C.Role .. " · " .. coordinator.status)
        partyLabel:SetText(coordinator.party)
        levelLabel:SetText("Level: " .. tostring(Adapter.level() or "loading") .. " | " .. controller.State.status)
        errorLabel:SetText(errors.Automation or errors.Save or "")
        if os.clock() - lastSave >= 15 then lastSave = os.clock(); save() end
        task.wait(0.5)
    end
end)
notify("Three-role controls loaded. " .. menuKey .. " opens the menu.")
