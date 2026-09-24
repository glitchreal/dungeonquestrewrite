-- Shared-workspace party sync is automatic; no server, key, or background command required.
getgenv().autoexecute = true
getgenv().autoloadconfig = true
getgenv().DQRewriteSync = { Files = true }
loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/dungeonquestrewrite/main/main.luau"))()
