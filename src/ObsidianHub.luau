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
    AutoHealer = false, AutoSell = false, AutoSkillPoints = false, UpgradeStat = "Stamina",
    OCD = false, RecoveryGrace = 45, JoinInterval = 10, StartDelay = 3,
    HideUI = false, CPUSaver = false, Waypoints = false,
    Distance = 20, SpellRange = 26, AutoDodge = true,
}
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
local coordinator
local previousFPS = type(getfpscap) == "function" and getfpscap() or nil
local performanceApplied = false
local patches = setmetatable({}, { __mode = "k" })
local function identity() if type(setthreadidentity) == "function" then setthreadidentity(8) end end
local function connect(signal, callback)
    local connection = signal:Connect(function(...) identity(); callback(...) end)
    table.insert(hooks, connection)
end
local function snapshot()
    return { Version = 2, Config = C, Runtime = runtime, MenuKey = menuKey }
end
local function save()
    if type(writefile) ~= "function" then errors.Save = "Executor file saving unavailable"; return end
    local ok = pcall(function() writefile(configPath, HttpService:JSONEncode(snapshot())) end)
    errors.Save = not ok and "Could not save settings" or nil
end
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
    if callback then callback(value) end
end
local function toggle(group, key, text, callback, tooltip)
    local control = group:AddToggle(key, { Text = text, Default = C[key], Tooltip = tooltip })
    control:OnChanged(function(value) change(key, value, callback) end)
    controls[key] = control
end
local function input(group, key, text, normalize, tooltip)
    local control = group:AddInput(key, { Text = text, Default = C[key], Finished = true, ClearTextOnFocus = false, Tooltip = tooltip })
    control:OnChanged(function(value)
        local formatted = normalize and normalize(value) or value
        if formatted ~= value then control:SetValue(formatted); return end
        change(key, formatted)
    end)
    controls[key] = control
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
local setup = partyTab:AddLeftGroupbox("Account and party")
dropdown(setup, "Role", "This account", { "Carry", "Host", "Alt" })
input(setup, "Host", "Host username or user ID")
input(setup, "Carry", "Carry username or user ID")
input(setup, "Alts", "Selected alts (paste list, then Enter)", function(value)
    return table.concat(Logic.tokens(value), ", ")
end, "Paste usernames or user IDs separated by newlines, spaces, tabs, commas, or semicolons. Press Enter to format the list and remove duplicates.")
setup:AddLabel("Use the same party list on every account. Host and alts level together; carry is excluded from level matching.", true)
toggle(setup, "Enabled", "Enable role automation")
local options = partyTab:AddRightGroupbox("Run options")
toggle(options, "Hardcore", "Hardcore (host)")
toggle(options, "Whitelist", "Private / whitelist lobby (host)")
toggle(options, "ProvisionHeals", "Farm Pirate Island for Universal Heal", nil, "Enable on every account. Uses eligible dungeons below level 60; leaves Pirate once every selected account owns a heal and levels match.")
toggle(options, "OCD", "OCD: regroup after disconnects", nil, "Pauses carry farming when anyone is missing. After the grace period, return to lobby and reassemble.")
slider(options, "RecoveryGrace", "Recovery grace (seconds)", 15, 180)
slider(options, "StartDelay", "Party-ready delay (seconds)", 0, 30)
local status = partyTab:AddRightGroupbox("Live status")
local statusLabel = status:AddLabel("Disabled", true)
local partyLabel = status:AddLabel("Configure the selected accounts", true)
local levelLabel = status:AddLabel("Level: loading", true)
local errorLabel = status:AddLabel("", true)
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
toggle(host, "AutoBest", "Create and join best eligible dungeon")
toggle(host, "AutoAccept", "Accept selected accounts only")
host:AddLabel("Creates the dungeon, accepts the party, and replays until the host and selected alts match levels. Keep Level Kaitun enabled to start once everyone arrives.", true)
local alt = roleTab:AddRightGroupbox("3 · Alt")
toggle(alt, "AutoHealer", "Tank armor + Universal Heal only", nil, "Equips the highest eligible tank helmet/chest and up to two Universal Heals. Alternates ready heals at least 4 seconds apart when a selected party member needs healing.")
toggle(alt, "AutoSkillPoints", "Auto allocate skill points")
dropdown(alt, "UpgradeStat", "Allocate to", { "Stamina", "Spell Power", "Physical Power" })
local inventory = settingsTab:AddLeftGroupbox("All account types")
toggle(inventory, "AutoSell", "Auto sell all rarities", nil, "Keeps two Universal Heals, equipped/locked/favorite items, and armor selected for the healer loadout.")
local display = settingsTab:AddRightGroupbox("Display and performance")
toggle(display, "HideUI", "Hide UI on execute")
toggle(display, "CPUSaver", "CPU saver", performance, "Disables 3D rendering, reduces effects, and caps FPS at 30. Restored when disabled or unloaded.")
toggle(display, "Waypoints", "Show pathfinding waypoints", performance)
local menu = settingsTab:AddLeftGroupbox("Menu")
local queueTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
menu:AddLabel("Teleport continuation: " .. (type(queueTeleport) == "function" and "available" or "rerun loader after teleport"), true)
menu:AddLabel("Menu key"):AddKeyPicker("MenuKey", { Default = menuKey, NoUI = true, Text = "Menu" })
Library.ToggleKeybind = Library.Options.MenuKey
Library.Options.MenuKey:OnChanged(function() menuKey = Library.Options.MenuKey.Value; save() end)
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
coordinator = Roles.new(C, runtime, MODE, controller, save, function() return alive end)
env.DungeonQuestObsidian = { Config = C, Runtime = runtime, Controller = controller, Coordinator = coordinator,
    Library = Library, Unload = unload, Errors = errors, Mode = MODE }
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
        local ok, err = xpcall(function() coordinator.Tick(os.clock()) end, debug.traceback)
        if not alive then break end
        if not ok then coordinator.Stop(); errors.Automation = tostring(err) else errors.Automation = nil end
        statusLabel:SetText(C.Role .. " · " .. coordinator.status)
        partyLabel:SetText(coordinator.party)
        levelLabel:SetText("Level: " .. tostring(Adapter.level() or "loading") .. " | " .. controller.State.status)
        errorLabel:SetText(errors.Automation or errors.Save or "")
        if os.clock() - lastSave >= 15 then lastSave = os.clock(); save() end
        task.wait(0.5)
    end
end)
notify("Three-role controls loaded. " .. menuKey .. " opens the menu.")
