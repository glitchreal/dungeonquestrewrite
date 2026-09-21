-- Public entry point: https://github.com/glitchreal/Dungeon-quest
local env = getgenv()
if env.autoexecute == nil then env.autoexecute = true end
if env.autoloadconfig == nil then env.autoloadconfig = true end
local ROOT = "https://raw.githubusercontent.com/glitchreal/Dungeon-quest/main/"
local routes = {
    [77649408247578] = "lobby", -- Main lobby
    [115445507767090] = "lobby", -- Level 100+ lobby
    [85776757589518] = "dungeon", -- Dungeons, wave defense, and boss raids
}

if not game:IsLoaded() then game.Loaded:Wait() end
local route = routes[game.PlaceId]
if not route then
    warn("[DungeonQuest] Unsupported place: " .. tostring(game.PlaceId))
    return
end

if env.DQObsidianLoading and env.DQObsidianLoaderJob == game.JobId then return end
env.DQObsidianLoading = true
env.DQObsidianLoaderJob = game.JobId
env.DQObsidianLoaderURL = ROOT .. "main.luau"
local ok, err = pcall(function()
    local source = game:HttpGet(ROOT .. "dist/" .. route .. ".luau")
    local entry, compileError = loadstring(source, "DungeonQuest/" .. route)
    assert(entry, compileError)
    entry()
end)
env.DQObsidianLoading = nil
env.DQObsidianLoaderJob = nil
if not ok then
    warn("[DungeonQuest] Could not load " .. route .. ": " .. tostring(err))
end
