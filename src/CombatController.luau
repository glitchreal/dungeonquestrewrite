-- Obsidian dungeon combat controller; creates no separate UI.
-- The controller has one movement owner: dodge goals preempt combat goals,
-- and path recovery invalidates the active path instead of issuing random jumps.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local player = Players.LocalPlayer

local CFG = {
    ATTACK_RANGE = 26,
    COMBAT_DISTANCE = 20,
    COMBAT_MIN_DISTANCE = 16,
    COMBAT_MAX_DISTANCE = 24,
    SKILL_COOLDOWN = 0.2,
    CONTROL_INTERVAL = 1 / 30,
    UI_INTERVAL = 0.15,
    THREAT_SCAN_INTERVAL = 0.2,
    DETECTION_RADIUS = 1000,

    PATH_UPDATE_INTERVAL = 0.8,
    WAYPOINT_REACH_THRESHOLD = 3,
    DIRECT_PATH_DISTANCE = 40,
    MOVETO_REFRESH_INTERVAL = 0.45,
    AGENT_RADIUS = 2.0,
    AGENT_HEIGHT = 5.5,
    AGENT_CAN_JUMP = true,
    AGENT_JUMP_HEIGHT = 12,
    AGENT_MAX_SLOPE = 70,
    WAYPOINT_SPACING = 4,

    STUCK_CHECK_INTERVAL = 0.35,
    STUCK_MOVE_THRESHOLD = 0.45,
    STUCK_TIMEOUT = 0.75,
    FAILED_PATH_COOLDOWN = 2.5,
    TARGET_SCAN_INTERVAL = 0.25,
    DODGE_COOLDOWN = 0.5,
    DODGE_LATERAL_DISTANCE = 8,
    DODGE_WINDOW = 3,
    DODGE_MAX_PER_WINDOW = 3,
    DODGE_DISTANCE_BUDGET = 18,
    DODGE_SAME_THREAT_COOLDOWN = 3,
    THREAT_RADIUS = 90,
    PROJECTILE_LOOKAHEAD = 1.35,
    PRECAST_MARGIN = 3,
    HAZARD_MARGIN = 6,
    THREAT_MAX_AGE = 2,
    AUTO_ABILITIES = true,
    AUTO_DODGE = true,
    HITLESS_SOLO = true,
    TELEPORT_DODGE = true,
    REACTION_TIME = 0.05,
    MELEE_DANGER_DISTANCE = 11,
    RETREAT_RELEASE_MARGIN = 5,
    FARM_POSITION = "Nearest",
    SMART_FARM = true,
    GROUP_RADIUS = 6,
    CLOSE_AOE_RANGE = 8,
    SPELL_RANGE_OVERRIDE = 0,

    SHOW_WAYPOINTS = true,
    WAYPOINT_NODE_SIZE = 0.5,
    WAYPOINT_LINE_THICKNESS = 0.15,
    WAYPOINT_COLOR = Color3.fromRGB(0, 255, 255),
    CURRENT_WAYPOINT_COLOR = Color3.fromRGB(255, 255, 0),
}

local state = {
    running = false,
    closed = false,
    updateBusy = false,
    skillToggle = false,
    lastSkillTime = 0,
    targetName = "Scanning...",
    targetDist = 0,
    skillQ_count = 0,
    skillE_count = 0,
    status = "Idle",
    kills = 0,
    prevHealth = setmetatable({}, { __mode = "k" }),
    currentTarget = nil,
    lockedTarget = nil,
    cachedTargets = {},
    lastTargetScan = 0,

    motionMode = "idle",
    motionGoal = nil,
    motionGoalMode = nil,
    lastMoveToCall = 0,
    lastMoveToPosition = Vector3.zero,
    waypoints = {},
    currentWaypointIndex = 1,
    pathObject = nil,
    pathBlocked = false,
    pathBlockedConn = nil,
    pathGoal = nil,
    pathMode = nil,
    pathUpdateTime = 0,
    failedPaths = {},
    fallbackGoal = nil,
    fallbackUntil = 0,

    lastPosition = Vector3.zero,
    lastStuckCheck = 0,
    lastProgressDistance = math.huge,
    lastProgressAt = 0,
    stuckRetries = 0,
    stuckCount = 0,
    stuckStartTime = 0,

    dodgeGoal = nil,
    lastDodgeTime = 0,
    lastThreatPart = nil,
    lastDodgeThreat = nil,
    lastDodgeThreatAt = 0,
    dodgeSide = 1,
    dodgeCount = 0,
    damageEvents = 0,
    lastPlayerHealth = nil,

    waypointFolder = nil,
    visualNodes = {},
    pathGeneration = 0,
    pathPending = false,
    lastThreatScan = 0,
    dodgeHistory = {},
    dodgedThreats = setmetatable({}, { __mode = "k" }),
    observedThreats = setmetatable({}, { __mode = "k" }),
    activeZones = {},
    nearbyEnemies = {},
    safetyUntil = 0,
    lastSafetyScan = -math.huge,
    lastEscapePlan = -math.huge,
    enemyMotion = setmetatable({}, { __mode = "k" }),
    retreating = false,
    pathComputations = 0,
    threatLog = {},
    routeDungeon = nil,
    routeAnchors = {},
    routeAnchorIndex = 1,
    routeScannedAt = -math.huge,
}

-- Ring-buffer recorder: zone sightings, escapes, teleports, hits.
-- Lets a later hit be explained from the previous ~60s of decisions.
local function logThreat(kind, info)
    local entry = { at = os.clock(), kind = kind }
    if type(info) == "table" then
        for key, value in pairs(info) do entry[key] = value end
    else
        entry.detail = info
    end
    table.insert(state.threatLog, entry)
    while #state.threatLog > 160 do table.remove(state.threatLog, 1) end
end

local abilities = AbilityController.new(player, function(slot)
    if state.closed then return end
    local key = slot == "q" and "skillQ_count" or "skillE_count"
    state[key] = state[key] + 1
end)

local connections = {}
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

local humanoidModels = {}
-- PrecastHitbox and similar effects are transient BaseParts. Tracking additions
-- lets the dodge check remain cheap and catches indicators created under Workspace.
local threatParts = {}
local announcedZones = {}
local safeSpots = {}
local beamParts = {}
local loggedThreats = setmetatable({}, { __mode = "k" })
local aquaticLineTemplates = {}
local function soloHitless()
    return CFG.HITLESS_SOLO and #Players:GetPlayers() == 1
end
local function dangerousName(instance)
    local name = instance:GetFullName():lower()
    return name:find("damage", 1, true) or name:find("hitbox", 1, true)
        or name:find("hazard", 1, true) or name:find("telegraph", 1, true)
        or name:find("precast", 1, true) or name:find("warning", 1, true)
        or name:find("danger", 1, true) or name:find("attack", 1, true)
        or name:find("projectile", 1, true) or name:find("missile", 1, true)
        or name:find("shot", 1, true) or name:find("bomb", 1, true)
        or name:find("spike", 1, true) or name:find("orb", 1, true)
        or name:find("blast", 1, true) or name:find("slam", 1, true)
        or name:find("flame", 1, true) or name:find("beam", 1, true)
        or name:find("laser", 1, true)
end
do
    local templates = game:GetService("ReplicatedStorage"):FindFirstChild("enemyProjectiles")
    for _, name in ipairs({ "firstBossRightHandShot", "secondBossRandomLine" }) do
        local model = templates and templates:FindFirstChild(name)
        local warning = model and model:FindFirstChild("precast")
        local hitbox = model and model:FindFirstChild("hitBox")
        if warning and warning:IsA("BasePart") and hitbox and hitbox:IsA("BasePart") then
            table.insert(aquaticLineTemplates, { name = name, warningSize = warning.Size, hitboxSize = hitbox.Size })
        end
    end
end
local function trackInstance(instance)
    if instance:IsA("Humanoid") and instance.Parent and instance.Parent:IsA("Model") then
        humanoidModels[instance] = instance.Parent
    end
    if instance:IsA("Beam") then
        beamParts[instance] = true
    end
    if instance:IsA("BasePart") then
        local now = os.clock()
        if not instance.CanCollide and (not state.waypointFolder or not instance:IsDescendantOf(state.waypointFolder)) then
            threatParts[instance] = { createdAt = now, lastPosition = instance.Position, lastAt = now }
        end
        local safeName = instance:GetFullName():lower()
        if safeName:find("safespot", 1, true) or safeName:find("safezone", 1, true) then
            safeSpots[instance] = true
        end
    end
end
connect(Workspace.DescendantAdded, trackInstance)
connect(Workspace.DescendantRemoving, function(instance)
    local sample = threatParts[instance]
    if sample and sample.zone then sample.removedAt = os.clock() else threatParts[instance] = nil end
    safeSpots[instance] = nil
    beamParts[instance] = nil
    humanoidModels[instance] = nil
end)
for _, instance in ipairs(Workspace:GetDescendants()) do trackInstance(instance) end

-- The game announces boss telegraphs before their Parts become visible.
pcall(function()
    local storage = game:GetService("ReplicatedStorage")
    local utility = storage:FindFirstChild("Utility")
    local module = utility and utility:FindFirstChild("BridgeNet2")
    if not module then return end
    local bridge = require(module)
    local action = bridge.ReferenceIdentifier("action")
    local connection = bridge.ReferenceBridge("precastHitbox"):Connect(function(data)
        if state.closed or type(data) ~= "table" then return end
        local kind = data[action]
        if kind ~= "Circle" and kind ~= "Cube" then return end
        local now = os.clock()
        local remaining = (tonumber(data.delayUntilAttack) or 0) - (Workspace:GetServerTimeNow() - (tonumber(data.startTime) or Workspace:GetServerTimeNow()))
        local frame, size, shape
        if kind == "Circle" and typeof(data.position) == "Vector3" and type(data.radius) == "number" then
            frame = CFrame.new(data.position) * CFrame.Angles(0, 0, math.pi / 2)
            size, shape = Vector3.new(0.5, data.radius * 2, data.radius * 2), "Cylinder"
        elseif kind == "Cube" and typeof(data.cframe) == "CFrame" and typeof(data.size) == "Vector3" then
            frame, size, shape = data.cframe, data.size, "Block"
        end
        if frame and remaining > -0.35 then
            table.insert(announcedZones, { frame = frame, size = size, shape = shape, expires = now + math.max(0, remaining) + 0.4, id = {} })
        end
    end)
    table.insert(connections, connection)
end)

pcall(function()
    local storage = game:GetService("ReplicatedStorage")
    local remotes = storage:FindFirstChild("remotes")
    local remote = remotes and remotes:FindFirstChild("aquaticBossSpecficEvents")
    local templates = storage:FindFirstChild("enemyProjectiles")
    local template = templates and templates:FindFirstChild("firstBossLaserPrecast")
    local marker = template and template:FindFirstChild("precast")
    local syncModule = storage:FindFirstChild("timeSync")
    if not remote or not marker or not template.PrimaryPart or not syncModule then return end
    local timeSync = require(syncModule)
    local offset = template.PrimaryPart.CFrame:ToObjectSpace(marker.CFrame)
    local size = marker.Size
    connect(remote.OnClientEvent, function(action, data)
        if not state.closed and action == "second boss show damage parts" then
            state.lastSafetyScan = -math.huge
            state.escapeGoal = nil
            state.lastEscapePlan = -math.huge
            return
        end
        if not state.closed and type(data) == "table"
            and (action == "first boss moving orb" or action == "last boss moving orb") then
            local orb = templates:FindFirstChild(action == "first boss moving orb" and "firstBossMoveOrb" or "finalBossOrbShot")
            if not orb or not orb:IsA("BasePart") or typeof(data[1]) ~= "CFrame"
                or type(data[2]) ~= "number" or type(data[3]) ~= "number"
                or type(data[4]) ~= "number" or type(data[5]) ~= "number" or data[5] <= 0 then return end
            local serverNow, now = timeSync:GetTime(), os.clock()
            local remaining = data[3] - serverNow
            if remaining < 0 or remaining > 30 then return end
            table.insert(announcedZones, { frame = data[1], origin = data[1], size = orb.Size,
                shape = "Projectile", velocity = data[1].LookVector * (data[4] / data[5]),
                starts = now + data[2] - serverNow, duration = data[5],
                travel = data[1].LookVector * data[4], lookahead = CFG.PROJECTILE_LOOKAHEAD,
                expires = now + remaining + 0.2, id = {}, name = action })
            state.lastSafetyScan = -math.huge
            return
        end
        if state.closed or action ~= "first boss laser shot" or type(data) ~= "table"
            or type(data[2]) ~= "number" or typeof(data[3]) ~= "CFrame" then return end
        local remaining = data[2] - timeSync:GetTime()
        if remaining < 0 or remaining > 30 then return end
        table.insert(announcedZones, { frame = data[3] * offset, size = size, shape = "Block",
            expires = os.clock() + remaining + 0.2, id = {} })
        state.lastSafetyScan = -math.huge
    end)
end)

local function getChar()
    local character = player.Character
    if not character then return nil, nil, nil end
    return character, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function createWaypointFolder()
    if state.waypointFolder then state.waypointFolder:Destroy() end
    local folder = Instance.new("Folder")
    folder.Name = "PathWaypoints_" .. player.Name
    folder.Parent = Workspace
    state.waypointFolder = folder
    return folder
end

local function clearWaypointVisuals()
    if #state.visualNodes > 0 and state.waypointFolder then state.waypointFolder:ClearAllChildren() end
    state.visualNodes = {}
end

local function visualizeWaypoints(waypoints, currentIndex)
    clearWaypointVisuals()
    if not CFG.SHOW_WAYPOINTS or not waypoints or #waypoints == 0 then return end
    if not state.waypointFolder then createWaypointFolder() end
    for index, waypoint in ipairs(waypoints) do
        local node = Instance.new("Part")
        node.Name = "WaypointNode"
        node.Shape = Enum.PartType.Ball
        node.Size = Vector3.new(CFG.WAYPOINT_NODE_SIZE, CFG.WAYPOINT_NODE_SIZE, CFG.WAYPOINT_NODE_SIZE)
        node.Position = waypoint.Position
        node.Anchored = true
        node.CanCollide = false
        node.CanTouch = false
        node.CanQuery = false
        node.Material = Enum.Material.Neon
        node.Transparency = 0.3
        node.Color = index == currentIndex and CFG.CURRENT_WAYPOINT_COLOR or CFG.WAYPOINT_COLOR
        node.Parent = state.waypointFolder
        table.insert(state.visualNodes, node)
        if index < #waypoints then
            local nextPosition = waypoints[index + 1].Position
            local distance = (nextPosition - waypoint.Position).Magnitude
            local line = Instance.new("Part")
            line.Name = "WaypointLine"
            line.Size = Vector3.new(CFG.WAYPOINT_LINE_THICKNESS, CFG.WAYPOINT_LINE_THICKNESS, distance)
            line.CFrame = CFrame.new((waypoint.Position + nextPosition) / 2, nextPosition)
            line.Anchored = true
            line.CanCollide = false
            line.CanTouch = false
            line.CanQuery = false
            line.Material = Enum.Material.Neon
            line.Transparency = 0.5
            line.Color = CFG.WAYPOINT_COLOR
            line.Parent = state.waypointFolder
            table.insert(state.visualNodes, line)
        end
    end
end

local function updateWaypointHighlight(index)
    local visualIndex = 1
    for waypointIndex = 1, #state.waypoints do
        local node = state.visualNodes[visualIndex]
        if node then
            node.Color = waypointIndex == index and CFG.CURRENT_WAYPOINT_COLOR or CFG.WAYPOINT_COLOR
        end
        visualIndex = visualIndex + 2
    end
end

-- Enemy discovery is based on Humanoid-bearing ancestor Models. Child parts,
-- attachments, and decorative geometry are therefore never separate targets.
local function getRootPart(model)
    local root = model:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then return root end
    local head = model:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head end
    return model.PrimaryPart
end

local function dungeonName()
    local value = Workspace:FindFirstChild("dungeonName")
    return value and value:IsA("ValueBase") and tostring(value.Value) or nil
end

-- Dungeon maps expose their intended room order through checkPoint parts. Use
-- that authored route whenever replicated enemies are visible through a wall;
-- direct nearest-enemy steering otherwise cuts across folded rooms and doors.
local function refreshRouteAnchors(now)
    local name = dungeonName()
    if state.routeDungeon == name and #state.routeAnchors > 0 then return end
    if state.routeDungeon == name and now - state.routeScannedAt < 2 then return end
    state.routeDungeon, state.routeAnchors, state.routeAnchorIndex = name, {}, 1
    state.routeScannedAt = now
    local dungeon = Workspace:FindFirstChild("dungeon")
    if not dungeon then return end
    for _, instance in ipairs(dungeon:GetDescendants()) do
        if instance:IsA("BasePart") and instance.Name:lower() == "checkpoint" then
            local room = instance.Parent and instance.Parent.Name or ""
            local number = tonumber(room:lower():match("room(%d+)"))
            local order = number or (room:lower():find("boss", 1, true) and 1000 or 900)
            table.insert(state.routeAnchors, { part = instance, order = order, name = room })
        end
    end
    table.sort(state.routeAnchors, function(a, b)
        return a.order < b.order or a.order == b.order and a.name < b.name
    end)
end

local function mapRouteGoal(rootPart, now)
    refreshRouteAnchors(now)
    while true do
        local anchor = state.routeAnchors[state.routeAnchorIndex]
        if not anchor then return nil end
        if not anchor.part.Parent then
            state.routeDungeon, state.routeScannedAt = nil, -math.huge
            refreshRouteAnchors(now)
            anchor = state.routeAnchors[state.routeAnchorIndex]
            if not anchor then return nil end
        end
        local delta = rootPart.Position - anchor.part.Position
        local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
        if flat <= 28 and math.abs(delta.Y) <= 60 then
            state.routeAnchorIndex = state.routeAnchorIndex + 1
        else
            return anchor.part.Position + Vector3.new(0, 2.5, 0), anchor
        end
    end
end

local function isValidTarget(model)
    if not model or not model.Parent or not model:IsA("Model") then return false end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local root = getRootPart(model)
    return humanoid ~= nil and humanoid.Health > 0 and root ~= nil and root:IsA("BasePart")
end

local function isPlayerOrLobbyCharacter(model)
    if Players:GetPlayerFromCharacter(model) then return true end
    local fullName = model:GetFullName():lower()
    if fullName:find(".lobby") or fullName:find(".aesthetic") then return true end
    if model.Name == player.Name or model.Name == "Seller" or model.Name == "Blacksmith" then return true end
    return false
end

local function refreshTargets(rootPart, now)
    if now - state.lastTargetScan < CFG.TARGET_SCAN_INTERVAL then return end
    state.lastTargetScan = now
    local targets = {}
    for humanoid, model in pairs(humanoidModels) do
        if humanoid.Parent ~= model then
            humanoidModels[humanoid] = humanoid.Parent and humanoid.Parent:IsA("Model") and humanoid.Parent or nil
        elseif model:IsDescendantOf(Workspace) and not isPlayerOrLobbyCharacter(model) and isValidTarget(model) then
            local root = getRootPart(model)
            if (root.Position - rootPart.Position).Magnitude <= CFG.DETECTION_RADIUS then
                table.insert(targets, model)
            end
        end
    end
    state.cachedTargets = targets
end

local hasBlockingRay

local function getClosestEnemy(rootPart, now)
    refreshTargets(rootPart, now)
    if now - (state.lastTargetChoice or 0) < 0.15 and isValidTarget(state.lockedTarget) then
        local root = getRootPart(state.lockedTarget)
        local distance = (rootPart.Position - root.Position).Magnitude
        if distance <= CFG.DETECTION_RADIUS and state.lockedTarget:IsDescendantOf(Workspace) then
            return state.lockedTarget, distance
        end
    end
    state.lastTargetChoice = now
    local candidates = {}
    for _, model in ipairs(state.cachedTargets) do
        if isValidTarget(model) and model:IsDescendantOf(Workspace) then
            local root = getRootPart(model)
            local distance = (rootPart.Position - root.Position).Magnitude
            if distance <= CFG.DETECTION_RADIUS then
                table.insert(candidates, { model = model, root = root, distance = distance })
            end
        end
    end
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    local closest = candidates[1]
    local closestIsVisible = false
    if closest then
        -- Prefer nearby enemies we can engage over a closer one behind a wall.
        local searchDistance = math.max(CFG.THREAT_RADIUS, closest.distance + 24)
        for _, candidate in ipairs(candidates) do
            if candidate.distance > searchDistance then break end
            if not hasBlockingRay(rootPart.Position, candidate.root.Position, rootPart.Parent, candidate.model) then
                closest = candidate
                closestIsVisible = true
                break
            end
        end
    end
    local previousLock = state.lockedTarget
    state.lockedTarget = closest and closest.model
    local pickDist = closest and closest.distance or CFG.DETECTION_RADIUS
    -- Hysteresis: two far targets in opposite directions flip-flop the lock
    -- every step and the bot paces between them forever. Only switch when the
    -- challenger is clearly closer or the lock is invalid/gone.
    if previousLock and previousLock ~= state.lockedTarget and isValidTarget(previousLock)
        and previousLock:IsDescendantOf(Workspace) then
        local lockedRoot = getRootPart(previousLock)
        if lockedRoot then
            local lockedDist = (rootPart.Position - lockedRoot.Position).Magnitude
            local lockedVisible = not hasBlockingRay(rootPart.Position, lockedRoot.Position, rootPart.Parent, previousLock)
            if (not closestIsVisible or lockedVisible) and lockedDist <= pickDist + 20 and lockedDist <= CFG.DETECTION_RADIUS then
                state.lockedTarget = previousLock
                return previousLock, lockedDist
            end
        end
    end
    return state.lockedTarget, pickDist
end

local function buildRaycastParams(character, target)
    local ignored = { character }
    if target then table.insert(ignored, target) end
    if state.waypointFolder then table.insert(ignored, state.waypointFolder) end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignored
    params.IgnoreWater = true
    return params
end

hasBlockingRay = function(origin, destination, character, target)
    local direction = destination - origin
    local params = buildRaycastParams(character, target)
    params.RespectCanCollide = true
    for _ = 1, 6 do
        local hit = Workspace:Raycast(origin, direction, params)
        if not hit then return false end
        local instance = hit.Instance
        local ancestorModel = instance:FindFirstAncestorOfClass("Model")
        local isHumanoidPart = ancestorModel and ancestorModel:FindFirstChildOfClass("Humanoid") ~= nil
        -- Humanoid bodies, invisible hitboxes, and attached effects are dynamic
        -- gameplay geometry, not walls. Static collidable map parts remain blockers.
        if (instance:IsA("BasePart") and not instance.CanCollide) or isHumanoidPart then
            local ignored = params.FilterDescendantsInstances
            table.insert(ignored, isHumanoidPart and ancestorModel or instance)
            params.FilterDescendantsInstances = ignored
        else
            return true
        end
    end
    return true
end

local function groundPosition(position, character, target)
    local hit = Workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), buildRaycastParams(character, target))
    if hit then return Vector3.new(position.X, hit.Position.Y + 2.5, position.Z) end
    return position
end

local function walkingSegmentClear(rootPart, destination, target, params, startFloor)
    params = params or buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    startFloor = startFloor or Workspace:Raycast(rootPart.Position, Vector3.new(0, -12, 0), params)
    if not startFloor then return false end
    local startPosition = rootPart.Position
    local flat = Vector3.new(destination.X - startPosition.X, 0, destination.Z - startPosition.Z)
    if flat.Magnitude < 0.1 then return true end
    local previousY = startFloor.Position.Y
    local steps = math.max(1, math.ceil(flat.Magnitude / 3))
    for i = 1, steps do
        local sample = startPosition + flat * (i / steps)
        sample = Vector3.new(sample.X, previousY + 6, sample.Z)
        local ground = Workspace:Raycast(sample, Vector3.new(0, -12, 0), params)
        if not ground or ground.Normal.Y < 0.55 then return false end
        -- Asymmetric steps: climbing more than ~2.5 needs stairs or a jump,
        -- but stepping DOWN is just falling. Allow drops up to 6 so slab
        -- edges and tiers stay walkable; anything deeper risks a pit trap.
        local dy = ground.Position.Y - previousY
        if dy > 2.5 or dy < -6 then return false end
        if ground.Instance.Name:lower():find("lava", 1, true) and not startFloor.Instance.Name:lower():find("lava", 1, true) then return false end
        previousY = ground.Position.Y
    end
    local endPosition = startPosition + flat + Vector3.new(0, previousY - startFloor.Position.Y, 0)
    local right = Vector3.new(-flat.Z, 0, flat.X).Unit * math.min(CFG.AGENT_RADIUS, 1.5)
    for _, offset in ipairs({ Vector3.zero, right, -right }) do
        if hasBlockingRay(startPosition + offset, endPosition + offset, rootPart.Parent, target) then return false end
    end
    return true
end

local function pathKey(startPosition, endPosition, mode)
    local function quantize(value) return math.floor(value / 4 + 0.5) end
    return string.format("%s:%d,%d,%d>%d,%d,%d", mode or "combat", quantize(startPosition.X), quantize(startPosition.Y), quantize(startPosition.Z), quantize(endPosition.X), quantize(endPosition.Y), quantize(endPosition.Z))
end

local function clearPath()
    state.terrainRecovery = nil
    state.directTravel = false
    state.pathGeneration = state.pathGeneration + 1
    if state.pathBlockedConn then state.pathBlockedConn:Disconnect() end
    state.pathBlockedConn = nil
    if state.pathObject then state.pathObject:Destroy() end
    state.pathObject = nil
    state.pathBlocked = false
    state.waypoints = {}
    state.currentWaypointIndex = 1
    state.pathGoal = nil
    state.pathMode = nil
    clearWaypointVisuals()
end

local function createPath(startPosition, endPosition, mode, now)
    for cachedKey, failedTime in pairs(state.failedPaths) do
        if now - failedTime >= CFG.FAILED_PATH_COOLDOWN then state.failedPaths[cachedKey] = nil end
    end
    local key = pathKey(startPosition, endPosition, mode)
    local failedAt = state.failedPaths[key]
    if failedAt and now - failedAt < CFG.FAILED_PATH_COOLDOWN then return nil end

    local configurations = {
        { AgentRadius = CFG.AGENT_RADIUS, AgentHeight = CFG.AGENT_HEIGHT, AgentCanJump = CFG.AGENT_CAN_JUMP, AgentJumpHeight = CFG.AGENT_JUMP_HEIGHT, AgentMaxSlope = CFG.AGENT_MAX_SLOPE, WaypointSpacing = CFG.WAYPOINT_SPACING },
        { AgentRadius = math.max(1.5, CFG.AGENT_RADIUS - 0.5), AgentHeight = CFG.AGENT_HEIGHT, AgentCanJump = true, AgentJumpHeight = CFG.AGENT_JUMP_HEIGHT + 2, AgentMaxSlope = CFG.AGENT_MAX_SLOPE, WaypointSpacing = 3 },
    }
    for _, configuration in ipairs(configurations) do
        local path = PathfindingService:CreatePath(configuration)
        state.pathComputations = state.pathComputations + 1
        local ok = pcall(function() path:ComputeAsync(startPosition, endPosition) end)
        if ok and path.Status == Enum.PathStatus.Success then
            local waypoints = path:GetWaypoints()
            if #waypoints >= 2 then
                state.failedPaths[key] = nil
                return path, waypoints
            end
        end
        path:Destroy()
    end
    state.failedPaths[key] = now
    return nil
end

local function clearanceFromEnemy(enemy, position)
    local current = enemy.root.Position
    return ThreatGeometry.segmentDistance(position, current, current + enemy.velocity * 0.5) - enemy.radius
end

local function enemyClearance(position)
    local nearest = math.huge
    for _, enemy in ipairs(state.nearbyEnemies) do
        if enemy.root.Parent then
            nearest = math.min(nearest, clearanceFromEnemy(enemy, position))
        end
    end
    return nearest
end

local function safeEnemyStep(startPosition, endPosition)
    for _, enemy in ipairs(state.nearbyEnemies) do
        if enemy.root.Parent then
            local original = clearanceFromEnemy(enemy, startPosition)
            for i = 1, 4 do
                local clearance = clearanceFromEnemy(enemy, startPosition:Lerp(endPosition, i / 4))
                if clearance < math.min(0, original) - 0.1 then return false end
                original = clearance
            end
        end
    end
    return true
end

-- Steering uses Humanoid:MoveTo. (Humanoid:Move is input-path and gets
-- swallowed from an executor context, which once froze the bot solid.)
local function issueMove(humanoid, position, mode, now, bypass)
    if not bypass and CFG.AUTO_DODGE and #state.activeZones > 0 then
        local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
        if root then
            local delta = position - root.Position
            local nextPosition = delta.Magnitude > 12 and root.Position + delta.Unit * 12 or position
            if not ThreatGeometry.segmentSafe(state.activeZones, root.Position, nextPosition, CFG.HAZARD_MARGIN) then
                humanoid:MoveTo(root.Position)
                state.motionMode = "safety-hold"
                state.movementBlocked = true
                state.blockedByHazard = true
                state.lastMoveToCall = 0
                return
            end
        end
    end
    if not bypass and CFG.AUTO_DODGE and #state.nearbyEnemies > 0 then
        local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
        if root then
            local delta = position - root.Position
            local reach = math.max(3, humanoid.WalkSpeed * 0.3)
            local step = delta.Magnitude > reach and root.Position + delta.Unit * reach or position
            if not safeEnemyStep(root.Position, step) then
                humanoid:MoveTo(root.Position)
                state.motionMode, state.movementBlocked = "safety-hold", true
                state.lastEscapePlan = -math.huge
                state.lastMoveToCall = 0
                return
            end
        end
    end
    local changed = state.motionMode ~= mode or (position - state.lastMoveToPosition).Magnitude > 0.75
    if changed or now - state.lastMoveToCall >= CFG.MOVETO_REFRESH_INTERVAL then
        humanoid:MoveTo(position)
        state.lastMoveToCall = now
        state.lastMoveToPosition = position
    end
    state.motionMode = mode
end

local function chooseFallbackStep(rootPart, goal, target)
    local delta = goal - rootPart.Position
    local forward = Vector3.new(delta.X, 0, delta.Z)
    if forward.Magnitude < 0.1 then forward = Vector3.new(1, 0, 0) end
    forward = forward.Unit
    local directions = {
        forward, Vector3.new(-forward.Z, 0, forward.X), Vector3.new(forward.Z, 0, -forward.X),
        -forward, (forward + Vector3.new(-forward.Z, 0, forward.X)).Unit,
        (forward + Vector3.new(forward.Z, 0, -forward.X)).Unit,
    }
    local best, bestScore
    state.fallbackVisits = state.fallbackVisits or {}
    local now = os.clock()
    for key, at in pairs(state.fallbackVisits) do if now - at > 15 then state.fallbackVisits[key] = nil end end
    for _, direction in ipairs(directions) do
        local candidate = groundPosition(rootPart.Position + direction * 8, rootPart.Parent, target)
        if walkingSegmentClear(rootPart, candidate, target) then
            local key = math.floor(candidate.X / 6) .. ":" .. math.floor(candidate.Z / 6)
            local score = (candidate - goal).Magnitude + (state.fallbackVisits[key] and 40 or 0)
            if not bestScore or score < bestScore then best, bestScore = candidate, score end
        end
    end
    if best then state.fallbackVisits[math.floor(best.X / 6) .. ":" .. math.floor(best.Z / 6)] = now end
    return best
end

-- Uphill survey: cast a transect from the player toward a higher goal and
-- return the base of the nearest up-step (stairs/ramp), so long climbs chain
-- stair-base -> local climb instead of walking the flat route underneath.
local function surveyUphill(rootPart, targetPos)
    local flat = Vector3.new(targetPos.X - rootPart.Position.X, 0, targetPos.Z - rootPart.Position.Z)
    local dist = flat.Magnitude
    if dist < 12 then return nil end
    local dir = flat.Unit
    local params = buildRaycastParams(rootPart.Parent, nil)
    params.RespectCanCollide = true
    local prev = rootPart.Position + Vector3.new(0, 2, 0)
    local prevGround = Workspace:Raycast(prev, Vector3.new(0, -14, 0), params)
    local prevY = (prevGround and prevGround.Position.Y) or rootPart.Position.Y
    local step, i = 10, 1
    while i * step < math.min(dist, 150) do
        local sample = rootPart.Position + dir * (i * step)
        local hit = Workspace:Raycast(sample + Vector3.new(0, 30, 0), Vector3.new(0, -70, 0), params)
        if hit and hit.Normal.Y > 0.6 and not hit.Instance.Name:lower():find("lava", 1, true) then
            if hit.Position.Y - prevY > 4 then
                -- Walk to just before the step; close-range climb takes over.
                local base = rootPart.Position + dir * ((i - 1) * step)
                local baseHit = Workspace:Raycast(base + Vector3.new(0, 30, 0), Vector3.new(0, -70, 0), params)
                if baseHit and baseHit.Normal.Y > 0.55 then
                    return baseHit.Position + Vector3.new(0, 2.5, 0)
                end
                return nil
            end
            prevY = hit.Position.Y
        end
        i = i + 1
    end
    return nil
end

local function findRecoveryPath(rootPart, goal, target, minRise)    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    local start = rootPart.Position
    minRise = minRise or 4
    local candidates = {}
    for _, radius in ipairs({ 24, 48, 64 }) do
        for index = 0, 11 do
            local angle = index * math.pi / 6
            local sample = start + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            local hit = Workspace:Raycast(sample + Vector3.new(0, 60, 0), Vector3.new(0, -100, 0), params)
            if hit and hit.Normal.Y > 0.65 and hit.Position.Y > start.Y + minRise
                and not hit.Instance.Name:lower():find("lava", 1, true) then
                table.insert(candidates, hit.Position + Vector3.new(0, 2.5, 0))
            end
        end
    end
    table.sort(candidates, function(a, b)
        return (a - goal).Magnitude < (b - goal).Magnitude
    end)
    for index = 1, math.min(6, #candidates) do
        if state.closed or not state.running or player.Character ~= rootPart.Parent then return nil end
        local path, waypoints = createPath(start, candidates[index], "terrain-recovery", os.clock())
        if path then return path, waypoints, candidates[index] end
    end
end

local function followGoal(humanoid, rootPart, goal, mode, now, target)
    if not goal then return end
    -- Flying targets bob up and down; a climb goal set during an upward bob
    -- goes stale when the target comes back down. Drop it instead of pacing
    -- between tiers.
    if state.terrainRecovery and target and target.Parent then
        local targetRoot = getRootPart(target)
        if targetRoot and targetRoot.Position.Y - rootPart.Position.Y < 4 then
            state.terrainRecovery = nil
            clearPath()
        end
    end
    -- Gap jumps: dungeon bridges break into jumpable platforms. When grounded
    -- with no floor just ahead but a landing in jump reach, hop the gap while
    -- running at it. Ignores water so wading stays on foot.
    if humanoid.FloorMaterial ~= Enum.Material.Air then
        local toGoal = goal - rootPart.Position
        local flat = Vector3.new(toGoal.X, 0, toGoal.Z)
        if flat.Magnitude >= 3 then
            local dir = flat.Unit
            local params = buildRaycastParams(rootPart.Parent, target)
            params.IgnoreWater = true
            local edge = Workspace:Raycast(rootPart.Position + dir * 3 + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), params)
            if not edge then
                local land = Workspace:Raycast(rootPart.Position + dir * 10 + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), params)
                if land and math.abs(land.Position.Y - rootPart.Position.Y) < 6
                    and not land.Instance.Name:lower():find("lava", 1, true) then
                    humanoid.Jump = true
                end
            end
        end
    end
    if state.terrainRecovery and #state.waypoints > 0 then
        goal, mode = state.terrainRecovery, "terrain-recovery"
    end
    local newGoal = not state.motionGoal or (state.motionGoal - goal).Magnitude > 2 or state.motionGoalMode ~= mode
    if newGoal then
        state.motionGoal, state.motionGoalMode = goal, mode
        state.fallbackGoal, state.fallbackUntil = nil, 0
        if state.pathMode and state.pathMode ~= mode then clearPath() end
        state.lastProgressDistance = math.huge
        state.lastProgressAt = now
    end

    -- Keep a short collision-checked escape step active between path attempts.
    -- MoveTo has an internal timeout, so refreshing it here prevents a wall
    -- corner from leaving the Humanoid idle while the long path is retried.
    if state.fallbackGoal and now < state.fallbackUntil then
        if (rootPart.Position - state.fallbackGoal).Magnitude > CFG.WAYPOINT_REACH_THRESHOLD then
            issueMove(humanoid, state.fallbackGoal, mode, now)
            return
        end
        state.fallbackGoal, state.fallbackUntil = nil, 0
    end

    if (goal - rootPart.Position).Magnitude <= CFG.DIRECT_PATH_DISTANCE then
        local probe = state.directProbe
        if not probe or now - probe.at > 0.2 or probe.target ~= target or probe.character ~= rootPart.Parent
            or (probe.origin - rootPart.Position).Magnitude > 5 or (probe.goal - goal).Magnitude > 4 then
            probe = { at = now, target = target, character = rootPart.Parent, origin = rootPart.Position, goal = goal,
                clear = walkingSegmentClear(rootPart, goal, target) }
            state.directProbe = probe
        end
        if probe.clear then
            if not state.directTravel then clearPath() end
            state.directTravel, state.pathMode = true, mode
            state.pathStatus = "Pathfinding: direct walk"
            issueMove(humanoid, goal, mode, now)
            return
        end
    end
    state.directTravel = false

    local shouldRepath = state.pathBlocked or #state.waypoints == 0 or not state.pathGoal or (goal - state.pathGoal).Magnitude > 12
    if shouldRepath and not state.pathPending and now - state.pathUpdateTime >= CFG.PATH_UPDATE_INTERVAL and (goal - rootPart.Position).Magnitude > CFG.WAYPOINT_REACH_THRESHOLD then
        state.pathUpdateTime = now
        state.pathPending = true
        local generation = state.pathGeneration
        local startPosition = rootPart.Position
        task.spawn(function()
        local recoveryGoal
        local ok, path, waypoints = pcall(function()
            local result, points = createPath(startPosition, goal, mode, now)
            if not result and goal.Y > rootPart.Position.Y + 6 and now - (state.lastTerrainProbe or -math.huge) > 6 then
                state.lastTerrainProbe = now
                result, points, recoveryGoal = findRecoveryPath(rootPart, goal, target)
            end
            return result, points
        end)
        state.pathPending = false
        if not ok then
            warn("[EnemyWalker] path error: " .. tostring(path))
            return
        end
        if state.closed or not state.running or humanoid.Health <= 0 or generation ~= state.pathGeneration
            or player.Character ~= rootPart.Parent or not target.Parent
            or not state.motionGoal or (state.motionGoal - goal).Magnitude > 8 then
            if path then path:Destroy() end
            return
        end
        if path and waypoints then
            clearPath()
            state.terrainRecovery = recoveryGoal
            state.pathObject = path
            state.pathBlocked = false
            state.pathGoal, state.pathMode = recoveryGoal or goal, recoveryGoal and "terrain-recovery" or mode
            if recoveryGoal then state.motionGoal, state.motionGoalMode = recoveryGoal, "terrain-recovery" end
            state.waypoints = waypoints
            state.currentWaypointIndex = 1
            -- Computation can finish after we have walked beyond its start.
            local nearestDistance = math.huge
            for index, waypoint in ipairs(waypoints) do
                local distance = (rootPart.Position - waypoint.Position).Magnitude
                if distance < nearestDistance then
                    nearestDistance = distance
                    state.currentWaypointIndex = index
                end
            end
            state.pathBlockedConn = path.Blocked:Connect(function(blockedIndex)
                if blockedIndex >= state.currentWaypointIndex then state.pathBlocked = true end
            end)
            visualizeWaypoints(waypoints, state.currentWaypointIndex)
            state.pathStatus = (recoveryGoal and "Recovering to higher ground: " or "Pathfinding: ") .. #waypoints .. " waypoints"
        else
            if #state.waypoints > 0 and not state.pathBlocked then return end
            clearPath()
            local fallback = nil
            if (goal - rootPart.Position).Magnitude <= CFG.DIRECT_PATH_DISTANCE and walkingSegmentClear(rootPart, goal, target) then
                fallback = goal
            else
                -- A failed long path still gets a short, collision-checked step.
                -- This keeps the agent moving around a wall while the failed-path
                -- cache prevents repeated identical ComputeAsync calls.
                fallback = chooseFallbackStep(rootPart, goal, target)
            end
            if fallback then
                state.fallbackGoal, state.fallbackUntil = fallback, os.clock() + 1.6
                state.pathStatus = "No full path: local recovery step"
            else
                state.pathStatus = "Pathfinding: blocked, probing alternate step"
            end
            clearWaypointVisuals()
            return
        end
        end)
    end

    local waypoint = state.waypoints[state.currentWaypointIndex]
    -- Watchdog: a waypoint we fail to close on for 4s is skipped, not rammed
    -- forever. Deterministic repaths regenerate the same stuck point, so
    -- skipping is what breaks the loop. Progress refreshes the window.
    if waypoint then
        local flatDist = (Vector3.new(rootPart.Position.X - waypoint.Position.X, 0, rootPart.Position.Z - waypoint.Position.Z)).Magnitude
        if state.watchWp ~= waypoint then
            state.watchWp, state.watchSince, state.watchDist, state.watchSkips = waypoint, now, flatDist, 0
        elseif now - state.watchSince >= 4 and flatDist > state.watchDist - 1 and (state.watchSkips or 0) < 4 then
            state.watchSkips = (state.watchSkips or 0) + 1
            state.currentWaypointIndex = state.currentWaypointIndex + 1
            state.watchWp, state.watchSince = nil, 0
            waypoint = state.waypoints[state.currentWaypointIndex]
        elseif flatDist < state.watchDist - 1 then
            state.watchSince, state.watchDist = now, flatDist
        end
    end
    -- Path waypoints are grounded positions while HumanoidRootPart is elevated
    -- by the hip height. Compare XZ distance so a small height delta cannot pin
    -- the controller on the first waypoint of a bridge or stair transition.
    -- But require rough height agreement too: on staircases stacked waypoints
    -- share one XZ, and skipping them all strands the bot walking in place.
    while waypoint
        and (Vector3.new(rootPart.Position.X - waypoint.Position.X, 0, rootPart.Position.Z - waypoint.Position.Z)).Magnitude <= CFG.WAYPOINT_REACH_THRESHOLD
        and math.abs(rootPart.Position.Y - waypoint.Position.Y) <= 6 do
        state.currentWaypointIndex = state.currentWaypointIndex + 1
        waypoint = state.waypoints[state.currentWaypointIndex]
        updateWaypointHighlight(state.currentWaypointIndex)
    end
    if not waypoint then
        state.terrainRecovery = nil
        if #state.waypoints > 0 then clearPath() end
        if (goal - rootPart.Position).Magnitude <= CFG.DIRECT_PATH_DISTANCE
            and walkingSegmentClear(rootPart, goal, target) then
            issueMove(humanoid, goal, mode, now)
        else
            if now - (state.lastPendingStep or -math.huge) >= 0.2 then
                state.lastPendingStep = now
                local fallback = chooseFallbackStep(rootPart, goal, target)
                if fallback then
                    if (goal - rootPart.Position).Magnitude > 50 then
                        state.routeFails = (state.routeFails or 0) + 1
                    end
                    state.fallbackGoal, state.fallbackUntil = fallback, now + 0.6
                    issueMove(humanoid, fallback, mode, now)
                else
                    humanoid:MoveTo(rootPart.Position)
                end
            end
        end
        return
    end
    if hasBlockingRay(rootPart.Position + Vector3.new(0, 2, 0), waypoint.Position + Vector3.new(0, 2, 0), rootPart.Parent, target) then
        -- A path can become stale or can thread a child part that the navmesh
        -- did not include. Reject that segment before MoveTo pins the player
        -- against the wall, then let the short-step fallback route around it.
        state.pathBlocked = true
        clearPath()
        local fallback = chooseFallbackStep(rootPart, goal, target)
        if fallback then
            state.fallbackGoal, state.fallbackUntil = fallback, now + 1.6
            issueMove(humanoid, fallback, mode, now)
        end
        return
    end
    if waypoint.Action == Enum.PathWaypointAction.Jump and humanoid.FloorMaterial ~= Enum.Material.Air then humanoid.Jump = true end
    issueMove(humanoid, waypoint.Position, mode, now)
end

local function chooseRecoveryGoal(rootPart, goal, target)
    local delta = goal - rootPart.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)
    if flat.Magnitude < 0.1 then flat = Vector3.new(1, 0, 0) end
    flat = flat.Unit
    local candidates = {}
    for index = 0, 7 do
        local angle = index * math.pi / 4
        local direction = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), angle):VectorToWorldSpace(flat)
        table.insert(candidates, rootPart.Position + direction * 8)
    end
    for _, candidate in ipairs(candidates) do
        candidate = groundPosition(candidate, rootPart.Parent, target)
        if walkingSegmentClear(rootPart, candidate, target) then return candidate end
    end
    return nil
end

local function updateProgress(humanoid, rootPart, goal, target, now)
    if now - state.lastStuckCheck < CFG.STUCK_CHECK_INTERVAL then return false end
    state.lastStuckCheck = now
    local distance = (goal - rootPart.Position).Magnitude
    local moved = (rootPart.Position - state.lastPosition).Magnitude
    state.lastPosition = rootPart.Position
    if moved >= CFG.STUCK_MOVE_THRESHOLD or distance < state.lastProgressDistance - 0.25 then
        state.stuckCount = 0
        state.stuckStartTime = 0
        state.lastProgressDistance = distance
        state.lastProgressAt = now
        state.routeFails = 0
        return false
    end
    state.stuckCount = state.stuckCount + 1
    if state.stuckStartTime == 0 then state.stuckStartTime = now end
    if now - state.stuckStartTime < CFG.STUCK_TIMEOUT then return false end
    -- Rate-limit recoveries: chained lateral hops every 0.75s read as
    -- oscillation. One committed recovery per 2s, then keep walking it.
    if now - (state.lastRecoveryAt or -math.huge) < 2 then return true end
    state.lastRecoveryAt = now

    state.stuckRetries = state.stuckRetries + 1
    state.stuckStartTime = now
    state.stuckCount = 0
    state.routeFails = (state.routeFails or 0) + 1
    -- NOTE: no clearPath() here. Clearing bumps the path generation, which
    -- discards the in-flight repath result, which stalls again, which clears
    -- again: a permanent loop where no path ever survives to be walked.
    -- Keep the current path; the Blocked event repaths if truly blocked.
    local recovery = chooseRecoveryGoal(rootPart, goal, target)
    if recovery then
        state.fallbackGoal, state.fallbackUntil = recovery, now + 1.6
        issueMove(humanoid, recovery, "recovery", now)
        state.pathStatus = "Pathfinding: lateral recovery"
    end
    return true
end

local function refreshSafety(rootPart, now)
    if now - state.lastSafetyScan < 0.1 then return end
    state.lastSafetyScan = now
    local zones, enemies = {}, {}
    -- These sections are created with the map and activated much later. They
    -- must remain discoverable after the transient effect index has aged out.
    local protectorFloor = Workspace:FindFirstChild("secondBossDamageParts")
    if protectorFloor then
        for _, part in ipairs(protectorFloor:GetChildren()) do
            if part:IsA("BasePart") and not threatParts[part] then trackInstance(part) end
        end
    end
    for _, model in ipairs(state.cachedTargets) do
        if isValidTarget(model) then
            local root = getRootPart(model)
            local distance = (root.Position - rootPart.Position).Magnitude
            if distance < 48 and not hasBlockingRay(rootPart.Position, root.Position, rootPart.Parent, model) then
                local sample = state.enemyMotion[model]
                local velocity = root.AssemblyLinearVelocity
                if sample and now > sample.at then
                    local observed = (root.Position - sample.position) / (now - sample.at)
                    if observed.Magnitude > velocity.Magnitude then velocity = observed end
                end
                velocity = Vector3.new(velocity.X, 0, velocity.Z)
                if velocity.Magnitude > 40 then velocity = velocity.Unit * 40 end
                state.enemyMotion[model] = { at = now, position = root.Position }
                -- Honest body radius: half the footprint plus a small buffer.
                -- The old floor (combat distance) flagged every enemy within
                -- 16+ studs as a crowd threat, so the bot backed away from
                -- anything that approached and never held DPS range on bosses.
                -- Real contact is still covered by the melee-threat response.
                local footprint = math.max(root.Size.X, root.Size.Z) * 0.5
                local radius = math.min(22, math.max(6, footprint + 5))
                table.insert(enemies, { model = model, root = root, distance = distance, velocity = velocity, radius = radius })
            end
        end
    end
    state.nearbyEnemies = enemies
    state.safeSpots = {}
    for part in pairs(safeSpots) do
        if part.Parent and part:IsDescendantOf(Workspace) then
            if (part.Position - rootPart.Position).Magnitude <= 120 then
                table.insert(state.safeSpots, part.Position + Vector3.new(0, 2.5, 0))
            end
        else
            safeSpots[part] = nil
        end
    end
    for i = #announcedZones, 1, -1 do
        local zone = announcedZones[i]
        if zone.origin then
            zone.frame = zone.origin + zone.travel * math.clamp((now - zone.starts) / zone.duration, 0, 1)
            zone.lookahead = math.min(CFG.PROJECTILE_LOOKAHEAD, math.max(0, zone.starts + zone.duration - now))
        end
        if zone.expires < now then table.remove(announcedZones, i)
        elseif (zone.frame.Position - rootPart.Position).Magnitude <= CFG.THREAT_RADIUS + zone.size.Magnitude then
            table.insert(zones, zone)
        end
    end
    for beam in pairs(beamParts) do
        if not beam.Parent then
            beamParts[beam] = nil
        elseif beam.Enabled and (soloHitless() or beam.Name ~= "Beam" and dangerousName(beam)
            or beam.Parent and dangerousName(beam.Parent)) then
            local first, second = beam.Attachment0, beam.Attachment1
            if first and second and first.Parent and second.Parent
                and not first:IsDescendantOf(rootPart.Parent) and not second:IsDescendantOf(rootPart.Parent) then
                local startPosition, endPosition = first.WorldPosition, second.WorldPosition
                local delta = endPosition - startPosition
                local width = math.max(1, beam.Width0, beam.Width1)
                if delta.Magnitude > 0.1
                    and ThreatGeometry.segmentDistance(rootPart.Position, startPosition, endPosition) <= CFG.THREAT_RADIUS then
                    table.insert(zones, { frame = CFrame.lookAt((startPosition + endPosition) * 0.5, endPosition),
                        size = Vector3.new(width, math.max(6, width), delta.Magnitude), shape = "Block",
                        velocity = Vector3.zero, moving = false, live = true, lookahead = 0, id = beam })
                end
            end
        end
    end
    for part, sample in pairs(threatParts) do
        if sample.removedAt then
            if now - sample.removedAt > 0.35 then threatParts[part] = nil
            elseif sample.zone then table.insert(zones, sample.zone) end
        elseif not part.Parent then
            threatParts[part] = nil
        elseif not part:IsDescendantOf(rootPart.Parent)
            and (not state.waypointFolder or not part:IsDescendantOf(state.waypointFolder)) then
            local distance = (part.Position - rootPart.Position).Magnitude
            local model = part:FindFirstAncestorOfClass("Model")
            local playerBody = model and Players:GetPlayerFromCharacter(model)
            if not playerBody and distance < CFG.THREAT_RADIUS + part.Size.Magnitude then
                local name = part:GetFullName():lower()
                local smashBox = part.Name == "precast" and part.Size.Y == 1 and part.Size.Z == 10
                    and part.Size.X >= 10 and part.Size.X <= 150 and part.Parent:FindFirstChild("hitBox")
                local protectorSmash = smashBox and smashBox:IsA("BasePart") and smashBox.Size.Y == 150
                    and smashBox.Size.X == part.Size.X and smashBox.Size.Z == 10
                local lineBox, lineName
                local dungeonName = Workspace:FindFirstChild("dungeonName")
                if part.Name == "precast" and dungeonName and dungeonName.Value == "Aquatic Temple" then
                    local hitbox = part.Parent:FindFirstChild("hitBox")
                    if hitbox and hitbox:IsA("BasePart") then
                        for _, template in ipairs(aquaticLineTemplates) do
                            if (part.Size - template.warningSize).Magnitude < 0.05
                                and (hitbox.Size - template.hitboxSize).Magnitude < 0.05 then
                                sample.lineVisible = sample.lineVisible or part.Transparency < 0.95
                                if sample.lineVisible then lineBox, lineName = hitbox, template.name end
                                break
                            end
                        end
                    end
                end
                local damageContainer = part.Transparency < 0.95 and (name:find("damageparts", 1, true)
                    or name:find("hitboxes", 1, true) or name:find("hazards", 1, true) or name:find("telegraphs", 1, true))
                local elapsed = math.max(0.001, now - sample.lastAt)
                local velocity = part.AssemblyLinearVelocity
                if velocity.Magnitude < 1 then velocity = (part.Position - sample.lastPosition) / elapsed end
                local projectile = (name:find("projectile") or name:find("missile") or name:find("shot")) and velocity.Magnitude > 1
                local potential = dangerousName(part)
                local named = part.Transparency < 0.95 and potential
                local attributed = part:GetAttribute("Attack") == true or part:GetAttribute("Hitbox") == true or part:GetAttribute("Damage") ~= nil
                local floorMarker = part:IsA("Part") and ((part.Shape == Enum.PartType.Block and part.Size.Y <= 4)
                    or (part.Shape == Enum.PartType.Cylinder and part.Size.X <= 4))
                local precast = floorMarker and part.Parent == Workspace and part.Anchored and not part.CanCollide
                    and not part.CanQuery and not part.CanTouch and part.Material == Enum.Material.Neon and part.Size.Magnitude > 3
                if not (name:find("safespot") or name:find("safezone")) and (projectile or named or attributed or precast or damageContainer or protectorSmash or lineBox) then
                    local shape = projectile and "Projectile" or (part:IsA("Part") and part.Shape == Enum.PartType.Cylinder and "Cylinder" or "Block")
                    local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
                    local moving = sample.zone ~= nil and horizontal.Magnitude > 2 and horizontal.Magnitude < 160
                    sample.zone = { frame = part.CFrame, size = part.Size, shape = shape,
                        velocity = velocity, moving = not projectile and moving, live = true,
                        lookahead = projectile and CFG.PROJECTILE_LOOKAHEAD or 0.5, id = part }
                    if protectorSmash then
                        local travel = 150 - part.Size.X
                        local humanoid = rootPart.Parent:FindFirstChildOfClass("Humanoid")
                        sample.zone = { frame = smashBox.CFrame, size = Vector3.new(150, 150, travel * 2 + 10),
                            shape = "ProtectorSmash", startWidth = part.Size.X, travelDistance = travel, id = part,
                            forecastAge = now - sample.createdAt, born = now, walkSpeed = humanoid and humanoid.WalkSpeed or 16 }
                    elseif lineBox then
                        sample.zone = { frame = lineBox.CFrame, size = lineBox.Size, shape = "Block",
                            id = part, kind = "AquaticDelayedLine", name = lineName }
                    end
                    sample.lastActive = now
                    table.insert(zones, sample.zone)
                elseif sample.zone and now - (sample.lastActive or 0) < 0.35 then
                    table.insert(zones, sample.zone)
                elseif now - sample.createdAt > CFG.THREAT_MAX_AGE and not potential then
                    threatParts[part] = nil
                end
                -- Homing/expanding rectangles: re-snapshot frame, size, and a
                -- speed-scaled lookahead every scan. Frozen snapshots go stale
                -- within a frame against parts that chase and grow.
                if sample.zone and sample.zone.live then
                    sample.zone.frame = part.CFrame
                    sample.zone.size = part.Size
                    sample.zone.velocity = velocity
                    local hSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
                    sample.zone.moving = hSpeed > 2 and hSpeed < 160
                    sample.zone.lookahead = math.clamp(hSpeed / 40, 0.5, 1.5)
                end
                sample.lastPosition, sample.lastAt = part.Position, now
            elseif now - sample.createdAt > CFG.THREAT_MAX_AGE and not sample.zone and not dangerousName(part) then
                threatParts[part] = nil
            end
        end
    end
    state.activeZones = zones
    for _, zone in ipairs(zones) do
        if not loggedThreats[zone.id] then
            loggedThreats[zone.id] = true
            local fp = zone.frame.Position
            logThreat("zone", {
                name = typeof(zone.id) == "Instance" and zone.id:GetFullName() or ("announced:" .. tostring(zone.name or zone.shape)),
                shape = zone.shape,
                zat = string.format("%d,%d,%d", math.floor(fp.X), math.floor(fp.Y), math.floor(fp.Z)),
                size = tostring(zone.size),
            })
        end
    end
end

local function crowdDistance(position)
    return math.min(28, enemyClearance(position) + math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22))
end

local function findEscapeGoal(rootPart, targetRoot)
    local params = buildRaycastParams(rootPart.Parent, targetRoot.Parent)
    params.RespectCanCollide = true
    local floor = Workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), params)
    if not floor then return nil end
    local candidates = {}
    local originalRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, CFG.HAZARD_MARGIN)
    local targetOffset = rootPart.Position - targetRoot.Position
    local targetRadial = Vector3.new(targetOffset.X, 0, targetOffset.Z)
    if targetRadial.Magnitude < 0.1 then targetRadial = Vector3.new(1, 0, 0) end
    targetRadial = targetRadial.Unit
    local orbitDirection = Vector3.new(-targetRadial.Z, 0, targetRadial.X) * state.dodgeSide
    local originalTargetDistance = Vector3.new(targetOffset.X, 0, targetOffset.Z).Magnitude
    local function combatShapeScore(candidate)
        local candidateOffset = candidate - targetRoot.Position
        local targetDistance = Vector3.new(candidateOffset.X, 0, candidateOffset.Z).Magnitude
        local movement = candidate - rootPart.Position
        movement = Vector3.new(movement.X, 0, movement.Z)
        local orbitAlignment = movement.Magnitude > 0.1 and movement.Unit:Dot(orbitDirection) or 0
        local outward = math.max(0, targetDistance - originalTargetDistance)
        local desiredError = math.abs(targetDistance - CFG.COMBAT_DISTANCE)
        return orbitAlignment * 18 - outward * 24 - desiredError * 2, targetDistance
    end
    if targetRoot.Parent.Name == "Ancient Temple Protector" then
        local toward = targetRoot.Position - rootPart.Position
        toward = Vector3.new(toward.X, 0, toward.Z)
        local originalDistance = toward.Magnitude
        if originalDistance > 0.1 then
            toward = toward.Unit
            local lateral = Vector3.new(-toward.Z, 0, toward.X)
            local best, bestScore, bestSide
            local now = os.clock()
            state.protectorEscapeVisits = state.protectorEscapeVisits or {}
            for key, at in pairs(state.protectorEscapeVisits) do
                if now - at >= 12 then state.protectorEscapeVisits[key] = nil end
            end
            for _, radius in ipairs({ 5, 10, 18 }) do
                for _, angle in ipairs({ math.pi / 6, math.pi / 3, math.pi / 2, math.pi * 2 / 3, math.pi }) do
                    for _, side in ipairs({ state.protectorOrbitSide or 1, -(state.protectorOrbitSide or 1) }) do
                        local candidate = rootPart.Position + (toward * math.cos(angle) + lateral * math.sin(angle) * side) * radius
                        local offset = candidate - targetRoot.Position
                        local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
                        local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                        local progress = originalDistance - distance
                        local key = math.floor(candidate.X / 6) .. ":" .. math.floor(candidate.Z / 6)
                        local score = -risk * 1000 + progress * 10 - radius
                            + (side == state.protectorOrbitSide and 1 or 0)
                            - (state.protectorEscapeVisits[key] and 150 or 0)
                        if distance >= CFG.COMBAT_MIN_DISTANCE
                            and (originalRisk == 0 and risk == 0 or risk < originalRisk - 0.1)
                            and (not bestScore or score + 80 > bestScore)
                            and safeEnemyStep(rootPart.Position, candidate)
                            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
                            and walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor) then
                            local exits = 0
                            for _, direction in ipairs({ toward, -toward, lateral, -lateral }) do
                                local exit = candidate + direction * 6
                                local support = Workspace:Raycast(exit + Vector3.new(0, 3, 0), Vector3.new(0, -9, 0), params)
                                if support and support.Normal.Y >= 0.55
                                    and not Workspace:Raycast(candidate, direction * 6, params)
                                    and ThreatGeometry.segmentSafe(state.activeZones, candidate, exit, CFG.HAZARD_MARGIN) then
                                    exits = exits + 1
                                end
                            end
                            score = score + exits * 20
                            if not bestScore or score > bestScore then
                                best, bestScore, bestSide = candidate, score, side
                            end
                        end
                    end
                end
            end
            if best then
                state.protectorOrbitSide = bestSide
                state.protectorEscapeVisits[math.floor(best.X / 6) .. ":" .. math.floor(best.Z / 6)] = now
                return best
            end
        end
    end
    local originalCrowd = crowdDistance(rootPart.Position)
    local originalDist = (rootPart.Position - targetRoot.Position).Magnitude
    local isProt = targetRoot.Parent and targetRoot.Parent.Name == "Ancient Temple Protector"
    -- Young smash corridors: exit strictly sideways. Generic gradient steps
    -- waste the ~1s windup on diagonals that never leave the corridor.
    do
        local need, lateral
        for _, activeZone in ipairs(state.activeZones) do
            local exitNeed, exitDir = ThreatGeometry.smashExit(activeZone, rootPart.Position, CFG.HAZARD_MARGIN)
            if exitNeed and (not need or exitNeed < need) then need, lateral = exitNeed, exitDir end
        end
        if need and lateral then
            for _, extra in ipairs({ 2, 6, 10 }) do
                for _, dir in ipairs({ lateral, -lateral }) do
                    local candidate = groundPosition(rootPart.Position + dir * (need + extra), rootPart.Parent, targetRoot.Parent)
                    if safeEnemyStep(rootPart.Position, candidate)
                        and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
                        and walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor) then
                        return candidate
                    end
                end
            end
        end
    end
    -- Long rectangular attacks (Northern Mage shots, spearman strikes, boss
    -- beams, and equivalent attacks on other maps) must be crossed sideways.
    -- Test both edges because overlapping lanes can make the nearest edge the
    -- worse one.  A small survival margin permits leaving an overlap without
    -- accepting a path that enters a new attack.
    do
        local exits = {}
        for _, activeZone in ipairs(state.activeZones) do
            local near, nearDirection, far, farDirection = ThreatGeometry.lineExits(
                activeZone, rootPart.Position, CFG.HAZARD_MARGIN
            )
            if near then
                table.insert(exits, { distance = near + 4, direction = nearDirection })
                table.insert(exits, { distance = far + 4, direction = farDirection })
            end
        end
        local best, bestScore, fallback, fallbackScore
        local initialSurvivalRisk = ThreatGeometry.risk(state.activeZones, rootPart.Position, 2)
        for _, exit in ipairs(exits) do
            for _, extra in ipairs({ 0, 6, 12 }) do
                local distance = math.min(40, exit.distance + extra)
                local candidate = groundPosition(rootPart.Position + exit.direction * distance,
                    rootPart.Parent, targetRoot.Parent)
                if walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor)
                    and safeEnemyStep(rootPart.Position, candidate) then
                    local survivalRisk = ThreatGeometry.risk(state.activeZones, candidate, 2)
                    local comfortRisk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                    local shapeScore, targetDistance = combatShapeScore(candidate)
                    local score = survivalRisk * 10000 + comfortRisk * 100 + distance - shapeScore
                        + math.max(0, targetDistance - math.max(CFG.ATTACK_RANGE, originalTargetDistance + 4)) * 500
                    if ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, 2)
                        and (not bestScore or score < bestScore) then
                        best, bestScore = candidate, score
                    end
                    -- Crossing grids can make every perpendicular route brush
                    -- another already active strip.  Still choose a committed
                    -- exit instead of falling back to a five-stud radial move.
                    -- Penalize exposure sampled along the route so this is
                    -- used only when no fully clear lateral crossing exists.
                    local peakRisk, accumulatedRisk = initialSurvivalRisk, 0
                    for sample = 1, 8 do
                        local sampleRisk = ThreatGeometry.risk(state.activeZones,
                            rootPart.Position:Lerp(candidate, sample / 8), 2)
                        peakRisk = math.max(peakRisk, sampleRisk)
                        accumulatedRisk = accumulatedRisk + sampleRisk
                    end
                    local fallbackCandidateScore = survivalRisk * 10000 + peakRisk * 1000
                        + accumulatedRisk * 100 + comfortRisk * 10 + distance - shapeScore
                        + math.max(0, targetDistance - math.max(CFG.ATTACK_RANGE, originalTargetDistance + 7)) * 500
                    if not fallbackScore or fallbackCandidateScore < fallbackScore then
                        fallback, fallbackScore = candidate, fallbackCandidateScore
                    end
                end
            end
        end
        if best then return best, 2, "Crossing out of line attack" end
        if fallback then return fallback, 2, "Crossing overlapping line attacks" end
    end
    if originalRisk > 0 and state.safeSpots and #state.safeSpots > 0 then
        local bestSpot, bestSpotDist
        for _, spot in ipairs(state.safeSpots) do
            local dist = (spot - rootPart.Position).Magnitude
            local spotTargetDistance = (spot - targetRoot.Position).Magnitude
            if dist <= 80 and (not bestSpotDist or dist < bestSpotDist)
                and spotTargetDistance <= math.max(CFG.ATTACK_RANGE, originalTargetDistance + 4)
                and ThreatGeometry.risk(state.activeZones, spot, CFG.HAZARD_MARGIN) == 0
                and safeEnemyStep(rootPart.Position, spot)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, spot, CFG.HAZARD_MARGIN)
                and walkingSegmentClear(rootPart, spot, targetRoot.Parent, params, floor) then
                bestSpot, bestSpotDist = spot, dist
            end
        end
        if bestSpot then return bestSpot end
    end
    local crowdLimit = math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22)
    local radii = originalRisk > 0 and { 5, 10, 18, 28, 40 } or { 3, 8, 14 }
    local angleSteps = 16
    for _, radius in ipairs(radii) do
        for i = 0, angleSteps - 1 do
            local angle = i * math.pi * 2 / angleSteps
            local candidate = rootPart.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            do
                -- Keep every combat escape on a tight target-centered leash.
                -- A few studs of outward travel are allowed to clear a body,
                -- but repeated hazards cannot walk the character to a wall.
                local targetDistance = (candidate - targetRoot.Position).Magnitude
                local backLimit = math.max(CFG.COMBAT_DISTANCE + 6,
                    originalDist + (originalDist > CFG.ATTACK_RANGE and 1 or 4))
                local backOk = targetDistance <= backLimit
                local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                local crowd = crowdDistance(candidate)
                local hazardClearance = 12
                for _, activeZone in ipairs(state.activeZones) do
                    hazardClearance = math.min(hazardClearance, ThreatGeometry.clearance(activeZone, candidate, CFG.HAZARD_MARGIN))
                end
                local crowdOk = originalRisk > 0 and crowd >= originalCrowd - 0.5
                    or (originalCrowd >= crowdLimit and not state.retreating)
                    or crowd > originalCrowd + 0.25
                if backOk and (originalRisk == 0 or risk < originalRisk - 0.1) and crowdOk then
                    local desiredDistance = CFG.COMBAT_DISTANCE + (state.retreating and CFG.RETREAT_RELEASE_MARGIN or 0)
                    local shapeScore = combatShapeScore(candidate)
                    local score = -risk * 1000 + math.min(hazardClearance, 12) + math.min(crowd, 28)
                        - radius * 2 - math.abs(targetDistance - desiredDistance)
                        - math.max(0, targetDistance - CFG.ATTACK_RANGE) * 4
                        + shapeScore
                    if isProt then
                        -- Dodge FORWARD, never back: reward closing on the
                        -- boss, punish backing off. Retreating from the
                        -- Protector just sets up the next volley at range.
                        score = score + math.max(0, originalDist - targetDistance) * 8
                            - math.max(0, targetDistance - originalDist) * 12
                    end
                    table.insert(candidates, { position = candidate, score = score, risk = risk, radius = radius })
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local checked = {}
    local function valid(entry)
        checked[entry] = true
        local candidate = entry.position
        if safeEnemyStep(rootPart.Position, candidate)
            and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
            and walkingSegmentClear(rootPart, candidate, targetRoot.Parent, params, floor) then
            return candidate
        end
    end
    for i = 1, math.min(16, #candidates) do
        local candidate = valid(candidates[i])
        if candidate then return candidate end
    end
    -- Clear endpoints can all be unreachable inside overlapping attacks.
    -- Reserve bounded checks for short steps that reduce current exposure.
    if originalRisk > 0 then
        table.sort(candidates, function(a, b)
            if a.radius ~= b.radius then return a.radius < b.radius end
            return a.risk < b.risk
        end)
        local attempts = 0
        for _, entry in ipairs(candidates) do
            if not checked[entry] then
                attempts = attempts + 1
                local candidate = valid(entry)
                if candidate then return candidate end
                if attempts >= 16 then break end
            end
        end
    end
    return nil
end

local function findLeastBadStep(rootPart, target)
    -- No fully safe route exists. Standing still inside an active hitbox is
    -- the worst option, so walk the reachable step with the lowest exposure.
    -- Scores with a body-radius survival margin (2) instead of the comfort
    -- margin: corridor blankets can still hold tight safe cells that the
    -- planning margin would erase. Teleports keep their strict checks; only
    -- the walk relaxes.
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    -- Anchor escapes to the boss: without a distance term the gradient walks
    -- away from everything, backing out of DPS range forever. Penalize steps
    -- that leave a 34-stud leash on the target.
    local bossPosition
    if target and target.Parent then
        local bossRoot = getRootPart(target)
        if bossRoot then bossPosition = bossRoot.Position end
    end
    local originalLbDist = (bossPosition and (rootPart.Position - bossPosition).Magnitude) or nil
    local radial, tangent
    if bossPosition and originalLbDist and originalLbDist > 0.1 then
        radial = Vector3.new(rootPart.Position.X - bossPosition.X, 0, rootPart.Position.Z - bossPosition.Z).Unit
        tangent = Vector3.new(-radial.Z, 0, radial.X) * state.dodgeSide
    end
    local best, bestScore
    for _, radius in ipairs({ 3, 6, 10 }) do
        for index = 0, 15 do
            local angle = index * math.pi / 8
            local candidate = rootPart.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            if walkingSegmentClear(rootPart, candidate, target, params)
                and safeEnemyStep(rootPart.Position, candidate) then
                local risk = ThreatGeometry.risk(state.activeZones, candidate, 2)
                local score = risk * 1000 + radius
                if bossPosition and originalLbDist then
                    local candDist = (candidate - bossPosition).Magnitude
                    local movement = candidate - rootPart.Position
                    movement = Vector3.new(movement.X, 0, movement.Z)
                    local alignment = tangent and movement.Magnitude > 0.1 and movement.Unit:Dot(tangent) or 0
                    score = score + math.max(0, candDist - originalLbDist) * 50
                        + math.abs(candDist - CFG.COMBAT_DISTANCE) * 3 - alignment * 12
                end
                if not bestScore or score < bestScore then best, bestScore = candidate, score end
            end
        end
    end
    return best
end

local function findEmergencySideStep(rootPart, target)
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    for _, radius in ipairs({ 3, 5, 8, 12 }) do
        for index = 0, 15 do
            local angle = index * math.pi / 8
            local candidate = rootPart.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
            if ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN) == 0
                and safeEnemyStep(rootPart.Position, candidate)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN)
                and walkingSegmentClear(rootPart, candidate, target, params) then
                return candidate
            end
        end
    end
    return nil
end

local function threatIsSmash(threat)
    if typeof(threat) == "string" then
        return threat:find("smash", 1, true) ~= nil or threat:find("windup", 1, true)
    end
    for _, zone in ipairs(state.activeZones) do
        if zone.id == threat and zone.shape == "ProtectorSmash" then return true end
    end
    return false
end

local function canTeleportDodge(now, distance, threat)
    local history = state.dodgeHistory
    while history[1] and now - history[1].at >= CFG.DODGE_WINDOW do table.remove(history, 1) end
    if not distance or distance < 0.1 or distance > CFG.DODGE_LATERAL_DISTANCE + 0.001 then return false end
    if #history >= CFG.DODGE_MAX_PER_WINDOW then return false end
    if history[#history] and now - history[#history].at < CFG.DODGE_COOLDOWN then return false end
    local previous = state.dodgedThreats[threat]
    if previous and now - previous < CFG.DODGE_SAME_THREAT_COOLDOWN then return false end
    local spent = 0
    for _, entry in ipairs(history) do spent = spent + entry.distance end
    -- Reserve a full blink for smash windups: anything else may only spend
    -- what leaves 8 studs of budget. Gridshot clips are survivable; the slam
    -- is not, and a dry budget at windup time is death.
    if not threatIsSmash(threat) and spent + distance > CFG.DODGE_DISTANCE_BUDGET - 8 then
        return false
    end
    return spent + distance <= CFG.DODGE_DISTANCE_BUDGET + 0.001
end

local function effectiveSpellRange(profile)
    -- Positive game metadata is authoritative; the UI value fills only unknown ranges.
    return profile.range or (CFG.SPELL_RANGE_OVERRIDE > 0 and CFG.SPELL_RANGE_OVERRIDE) or CFG.ATTACK_RANGE
end

local function performDodgeTeleport(humanoid, rootPart, destination, target, threat, now)
    if not destination or humanoid.FloorMaterial == Enum.Material.Air then return false end
    local delta = destination - rootPart.Position
    if not canTeleportDodge(now, delta.Magnitude, threat) then return false end
    if not safeEnemyStep(rootPart.Position, destination) then return false end
    if not walkingSegmentClear(rootPart, destination, target) then return false end
    if not ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, destination, CFG.HAZARD_MARGIN) then return false end
    -- Check several body-width rays before applying the bounded horizontal step.
    for _, offset in ipairs({ Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }) do
        if hasBlockingRay(rootPart.Position + offset, destination + offset, rootPart.Parent, target) then return false end
    end
    rootPart.CFrame = rootPart.CFrame + delta
    table.insert(state.dodgeHistory, { at = now, distance = delta.Magnitude })
    logThreat("tp", { distance = math.floor(delta.Magnitude * 10) / 10 })
    state.lastDodgeTime = now
    state.safetyUntil = now + 0.75
    state.dodgeCount = state.dodgeCount + 1
    clearPath()
    state.motionGoal = nil
    state.fallbackGoal, state.fallbackUntil = nil, 0
    humanoid:MoveTo(destination)
    state.motionMode = "dodge"
    state.lastPosition, state.stuckStartTime = destination, 0
    return true
end

local facingHumanoid, previousAutoRotate, facingRoot, facingAttachment, facingAlignment

local function restoreFacing()
    if facingAlignment then facingAlignment:Destroy(); facingAlignment = nil end
    if facingAttachment then facingAttachment:Destroy(); facingAttachment = nil end
    facingRoot = nil
    if facingHumanoid then
        facingHumanoid.AutoRotate = previousAutoRotate
        facingHumanoid = nil
        previousAutoRotate = nil
    end
end

local function faceEnemy(humanoid, rootPart, targetRoot)
    if CFG.SMART_FARM and state.castAimTarget and os.clock() < (state.castAimUntil or 0) and isValidTarget(state.castAimTarget) then
        targetRoot = getRootPart(state.castAimTarget)
    end
    if facingHumanoid ~= humanoid or facingRoot ~= rootPart then
        restoreFacing()
        facingHumanoid, previousAutoRotate = humanoid, humanoid.AutoRotate
        facingRoot = rootPart
        facingAttachment = Instance.new("Attachment")
        facingAttachment.Name = "ObsidianFacingAttachment"
        facingAttachment.Parent = rootPart
        facingAlignment = Instance.new("AlignOrientation")
        facingAlignment.Name = "ObsidianFacing"
        facingAlignment.Mode = Enum.OrientationAlignmentMode.OneAttachment
        facingAlignment.Attachment0 = facingAttachment
        facingAlignment.MaxTorque = 1000000
        facingAlignment.MaxAngularVelocity = 30
        facingAlignment.Responsiveness = 100
        facingAlignment.Parent = rootPart
    end
    humanoid.AutoRotate = false
    local position = rootPart.Position
    local lookAt = Vector3.new(targetRoot.Position.X, position.Y, targetRoot.Position.Z)
    if (lookAt - position).Magnitude > 0.01 then
        -- Writing the root CFrame cancels Humanoid.MoveTo. Rotate through physics
        -- so facing the target never interrupts the current walking command.
        facingAlignment.CFrame = CFrame.new(Vector3.zero, lookAt - position)
    end
end

local function spellUsable(snapshot, rootPart)
    local profile = FarmPlanner.profile(snapshot)
    local humanoid = rootPart.Parent:FindFirstChildOfClass("Humanoid")
    if profile.mode == "heal" then return humanoid and humanoid.Health < humanoid.MaxHealth * 0.85 end
    if profile.mode == "shield" then return state.retreating or #state.activeZones > 0 end
    if profile.mode == "buff" then
        return #state.nearbyEnemies > 0 or state.retreating or state.motionMode == "evade"
            or state.motionMode == "safety-hold" or state.lastThreatPart ~= nil
    end
    if profile.mode == "self" then
        for _, enemy in ipairs(state.nearbyEnemies) do
            if isValidTarget(enemy.model) and (enemy.root.Position - rootPart.Position).Magnitude <= (profile.radius or profile.range or CFG.CLOSE_AOE_RANGE) then
                return true
            end
        end
        return false
    end
    if state.targetDist > effectiveSpellRange(profile) then return false end
    return true
end

local function prepareSpell(_, snapshot)
    if not CFG.SMART_FARM then return true end
    local character, humanoid, rootPart = getChar()
    if not character or not humanoid or not rootPart then return false end
    if not spellUsable(snapshot, rootPart) then return false end
    local profile = FarmPlanner.profile(snapshot)
    if profile.mode == "target" and state.targetDist > effectiveSpellRange(profile) then return false end
    if profile.mode ~= "splash" then return true end
    local range, radius = effectiveSpellRange(profile), profile.radius or CFG.GROUP_RADIUS
    local now = os.clock()
    local plan = state.farmPlan
    if not plan or plan.spell ~= snapshot.name or plan.range ~= range or plan.radius ~= radius
        or now - plan.at >= 0.2 or not isValidTarget(plan.target) then
        local candidates = {}
        for _, model in ipairs(state.cachedTargets) do
            if isValidTarget(model) then
                local root = getRootPart(model)
                local distance = (root.Position - rootPart.Position).Magnitude
                if distance <= range then
                    table.insert(candidates, { model = model, position = root.Position, distance = distance })
                end
            end
        end
        table.sort(candidates, function(a, b) return a.distance < b.distance end)
        local visible = {}
        for _, candidate in ipairs(candidates) do
            if #visible >= 16 then break end
            if not hasBlockingRay(rootPart.Position, candidate.position, character, candidate.model) then table.insert(visible, candidate) end
        end
        local visibilityCache = {}
        local best, count = FarmPlanner.select(visible, radius, function(a, b)
            local cached = visibilityCache[a.model]
            if cached and cached[b.model] ~= nil then return cached[b.model] end
            local clear = not hasBlockingRay(a.position, b.position, character, a.model)
            visibilityCache[a.model], visibilityCache[b.model] = visibilityCache[a.model] or {}, visibilityCache[b.model] or {}
            visibilityCache[a.model][b.model], visibilityCache[b.model][a.model] = clear, clear
            return clear
        end)
        plan = { at = now, target = best and best.model, count = count, spell = snapshot.name, range = range, radius = radius }
        state.farmPlan = plan
    end
    local target = plan.target
    if not isValidTarget(target) then return false end
    local targetRoot = getRootPart(target)
    if (targetRoot.Position - rootPart.Position).Magnitude > range
        or hasBlockingRay(rootPart.Position, targetRoot.Position, character, target) then return false end
    state.castAimTarget, state.castAimUntil, state.groupCount = target, now + 0.35, plan.count
    faceEnemy(humanoid, rootPart, targetRoot)
    local delta = targetRoot.Position - rootPart.Position
    delta = Vector3.new(delta.X, 0, delta.Z)
    return delta.Magnitude < 0.1 or rootPart.CFrame.LookVector:Dot(delta.Unit) >= 0.9985
end

local function castSkill()
    if not CFG.AUTO_ABILITIES then return end
    local now = os.clock()
    if abilities.TryCast(now, CFG.SKILL_COOLDOWN, prepareSpell) then state.lastSkillTime = now end
end

local function stopMovement(humanoid, rootPart)
    if state.motionMode == "hold" and not state.motionGoal then return end
    humanoid:MoveTo(rootPart.Position)
    state.motionMode = "hold"
    state.motionGoal = nil
    state.fallbackGoal, state.fallbackUntil = nil, 0
    clearPath()
end

-- Protector windup tell: hands rest at body level; a fast raise starts the
-- smash volley. A freshly started animation track on the boss counts too.
-- So does the boss snapping to face the player (the slam aims at whoever it
-- faces). Returns true on the tick the tell is detected.
local function protectorWindup(target, targetRoot, rootPart, now)
    if not target or target.Name ~= "Ancient Temple Protector" then
        state.windHands, state.windTracks, state.faceHist = nil, nil, nil
        return false
    end
    local humanoid = target:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if animator then
        local seen, fresh, nowSeen = state.windTracks, false, {}
        local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
        if ok and tracks then
            for _, track in ipairs(tracks) do
                local id = (track.Animation and track.Animation.AnimationId) or track.Name
                nowSeen[id] = true
                if not (seen and seen[id]) then fresh = true end
            end
        end
        state.windTracks = nowSeen
        if fresh and seen then return true end
    end
    -- Facing snap: the slam aims at whoever it faces. Was looking away
    -- (>40deg sometime in the last 1.2s), now dead-on (<15deg).
    if targetRoot and rootPart then
        local facing = targetRoot.CFrame.LookVector
        facing = Vector3.new(facing.X, 0, facing.Z)
        local toPlayer = rootPart.Position - targetRoot.Position
        toPlayer = Vector3.new(toPlayer.X, 0, toPlayer.Z)
        if facing.Magnitude > 0.01 and toPlayer.Magnitude > 0.01 then
            local ang = math.acos(math.clamp(facing.Unit:Dot(toPlayer.Unit), -1, 1))
            local hist = state.faceHist or {}
            table.insert(hist, { at = now, ang = ang })
            while hist[1] and now - hist[1].at > 1.2 do table.remove(hist, 1) end
            state.faceHist = hist
            local was = math.huge
            for _, h in ipairs(hist) do was = math.min(was, h.ang) end
            if ang < 0.26 and was > 0.7 then return true end
        end
    end
    local left = target:FindFirstChild("leftHandModel")
    local right = target:FindFirstChild("rightHandModel")
    if not (left and right) then return false end
    local ly, ry
    pcall(function()
        ly = left:GetPivot().Position.Y
        ry = right:GetPivot().Position.Y
    end)
    if not (ly and ry) then return false end
    local sample = state.windHands
    state.windHands = { at = now, ly = ly, ry = ry }
    if not sample then return false end
    local dt = now - sample.at
    if dt < 0.12 or dt > 2.0 then return false end
    return math.max(ly - sample.ly, ry - sample.ry) > 4
end

local function meleeThreat(rootPart)    local threat, closest = nil, math.huge
    for _, enemy in ipairs(state.nearbyEnemies) do
        if enemy.root.Parent then
            local distance = (enemy.root.Position - rootPart.Position).Magnitude
            local offset = rootPart.Position - enemy.root.Position
            local closing = offset.Magnitude > 0.01 and enemy.velocity:Dot(offset.Unit) or 0
            local limit = math.max(CFG.MELEE_DANGER_DISTANCE, math.min(18, math.max(enemy.root.Size.X, enemy.root.Size.Z) * 0.5 + 6))
            if distance < closest and (distance <= limit or distance - math.max(0, closing) * 0.25 <= limit) then
                threat, closest = enemy.model, distance
            end
        end
    end
    return threat
end

local function dodgeAlongEscape(humanoid, rootPart, goal, target, threat, now, forceBlink)
    if not threat then return end
    local delta = goal - rootPart.Position
    if delta.Magnitude < 0.5 then return end
    local step = rootPart.Position + delta.Unit * math.min(CFG.DODGE_LATERAL_DISTANCE, delta.Magnitude)
    if enemyClearance(step) <= enemyClearance(rootPart.Position) and typeof(threat) == "Instance" and threat:IsA("Model") then return end
    -- Teleport budget is reserved for telegraphed attacks (zone parts and
    -- announcements). Melee separation walks: spending the 3-per-3s budget
    -- dodging bodies leaves nothing for the one-shot windup that follows.
    local telegraphed = not (typeof(threat) == "Instance" and threat:IsA("Model"))
    -- Walk small dodges, blink far ones: anything inside half a second of
    -- walking is smoother on foot; the blink is for real distance.
    -- Emergencies (least-bad) and intentional bursts (windup) always blink.
    if telegraphed and CFG.TELEPORT_DODGE and (forceBlink or delta.Magnitude > 12) then
        performDodgeTeleport(humanoid, rootPart, step, target, threat, now)
    end
end

-- Protector separation goes sideways, never backward. Radial escapes back
-- the bot into the arena pit/edge and strand every fight at range, which is
-- exactly where the slam one-shots it.
local function protectorLateralSeparation(rootPart, targetRoot, target)
    local away = Vector3.new(rootPart.Position.X - targetRoot.Position.X, 0, rootPart.Position.Z - targetRoot.Position.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) else away = away.Unit end
    local tangent = Vector3.new(-away.Z, 0, away.X)
    local params = buildRaycastParams(rootPart.Parent, target)
    params.RespectCanCollide = true
    local ground = Workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), params)
    if not ground then return nil end
    local best, bestScore
    for _, side in ipairs({ 1, -1 }) do
        for _, distance in ipairs({ 6, 10 }) do
            local candidate = groundPosition(rootPart.Position + tangent * side * distance, rootPart.Parent, target)
            if walkingSegmentClear(rootPart, candidate, target, params, ground)
                and safeEnemyStep(rootPart.Position, candidate)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN) then
                local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                local score = risk * 1000 + distance
                if not bestScore or score < bestScore then best, bestScore = candidate, score end
            end
        end
    end
    return best
end

local function forceSeparationGoal(rootPart, targetRoot, target)
    local away = Vector3.new(rootPart.Position.X - targetRoot.Position.X, 0, rootPart.Position.Z - targetRoot.Position.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) else away = away.Unit end
    local tangent = Vector3.new(-away.Z, 0, away.X)
    local params = buildRaycastParams(rootPart.Parent, target)
    local originalDistance = (rootPart.Position - targetRoot.Position).Magnitude
    local best, bestScore, bestSide
    for _, side in ipairs({ state.dodgeSide, -state.dodgeSide }) do
        -- Mostly tangent with only enough outward motion to break body contact.
        -- This keeps the fight centered instead of retreating toward a wall.
        local direction = (tangent * side + away * 0.22).Unit
        for _, distance in ipairs({ 5, 8, 12, 16 }) do
            local candidate = groundPosition(rootPart.Position + direction * distance, rootPart.Parent, target)
            if walkingSegmentClear(rootPart, candidate, target, params)
                and safeEnemyStep(rootPart.Position, candidate)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, candidate, CFG.HAZARD_MARGIN) then
                local candidateDistance = (candidate - targetRoot.Position).Magnitude
                local risk = ThreatGeometry.risk(state.activeZones, candidate, CFG.HAZARD_MARGIN)
                local score = risk * 1000 + math.max(0, candidateDistance - originalDistance) * 30
                    + math.abs(candidateDistance - CFG.COMBAT_DISTANCE) * 2 + distance
                    + (side == state.dodgeSide and 0 or 18)
                if not bestScore or score < bestScore then
                    best, bestScore, bestSide = candidate, score, side
                end
            end
        end
    end
    if bestSide then state.dodgeSide = bestSide end
    return best
end


local function handleSafety(humanoid, rootPart, target, targetRoot, now)
    if not CFG.AUTO_DODGE then
        state.escapeGoal, state.lastThreatPart, state.movementBlocked, state.retreating = nil, nil, false, false
        return false
    end
    local risk, zone = ThreatGeometry.risk(state.activeZones, rootPart.Position, CFG.HAZARD_MARGIN)
    state.lastThreatPart = zone and zone.id
    -- Jump-over: thin homing rectangles are cleared by leaving the ground as
    -- they pass under. Only when the zone top is within jump apex (~6 studs)
    -- so tall smash volumes never trigger it.
    if now - (state.lastJumpAt or -math.huge) >= 0.4 and humanoid.FloorMaterial ~= Enum.Material.Air then
        for _, activeZone in ipairs(state.activeZones) do
            if activeZone.live then
                local top = activeZone.frame.Position.Y + activeZone.size.Y * 0.5
                if top - rootPart.Position.Y < 2 then
                    local shouldJump = activeZone.shape == "Block" and activeZone.size.Y <= 4
                        and ThreatGeometry.clearance(activeZone, rootPart.Position, CFG.HAZARD_MARGIN) < 0
                    local velocity = activeZone.velocity or Vector3.zero
                    local toPlayer = rootPart.Position - activeZone.frame.Position
                    if not shouldJump and velocity.Magnitude > 0.01 and toPlayer.Magnitude > 0.01 then
                        local closing = velocity:Dot(toPlayer.Unit)
                        local clearanceNow = ThreatGeometry.clearance(activeZone, rootPart.Position, 0)
                        shouldJump = closing > 4 and clearanceNow / closing < 0.4
                    end
                    if shouldJump then
                        humanoid.Jump = true
                        state.lastJumpAt = now
                        logThreat("jump", activeZone.shape or "?")
                        break
                    end
                end
            end
        end
    end
    local crowd = crowdDistance(rootPart.Position)
    local crowdLimit = math.clamp(CFG.COMBAT_MIN_DISTANCE, 6, 22)
    local clearance = enemyClearance(rootPart.Position)
    local isProt = target.Name == "Ancient Temple Protector"
    -- No crowd-retreats against the Protector: backing off for spacing is
    -- what walks the fight backward into the pit and strands it at range.
    -- Zones and real contact still dodge; spacing alone never retreats.
    if clearance < 0 and not isProt then state.retreating = true
    elseif clearance >= CFG.RETREAT_RELEASE_MARGIN then state.retreating = false end
    local contactThreat = meleeThreat(rootPart)
    local contactDistance = (targetRoot.Position - rootPart.Position).Magnitude
    if contactThreat and (contactThreat == target or contactDistance <= CFG.MELEE_DANGER_DISTANCE) then
        local separation = nil
        if isProt then
            separation = protectorLateralSeparation(rootPart, targetRoot, target)
        else
            separation = forceSeparationGoal(rootPart, targetRoot, target)
        end
        state.retreating = true
        if separation then
            clearPath()
            state.escapeGoal, state.escapeUntil = separation, now + 1.25
            state.escapeMargin = CFG.HAZARD_MARGIN
            state.escapeStartRisk = risk
            state.escapeClear, state.lastEscapeCheck = true, now
            state.escapeReason = "Breaking melee contact"
            state.status = state.escapeReason
            dodgeAlongEscape(humanoid, rootPart, separation, target, contactThreat, now)
            issueMove(humanoid, separation, "evade", now)
            return true
        end
        -- A blocked backward step still permits a lateral escape search.
    end
    -- Smash response (Protector only): the slam is a full-arena expanding
    -- rectangle wall. Backing away corners you against the arena edge, so
    -- this does the opposite: phase 1 closes distance toward the boss while
    -- the rectangles are small, phase 2 strafes the side with more open
    -- space. Regular attacks keep the normal backward dodge below; only
    -- Smash behaves this way (attack-dependent dodge direction).
    if target.Name == "Ancient Temple Protector" then
        if protectorWindup(target, targetRoot, rootPart, now) then
            state.smashStrafeUntil = now + 2.2
            logThreat("windup", "smash")
        end
        if state.smashStrafeUntil and now < state.smashStrafeUntil then
            local away = Vector3.new(rootPart.Position.X - targetRoot.Position.X, 0, rootPart.Position.Z - targetRoot.Position.Z)
            local dist = away.Magnitude
            if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) else away = away.Unit end
            local goal
            if dist > 20 then
                -- Phase 1: close distance fast while rectangles are small.
                local toward = Vector3.new(-away.X, 0, -away.Z)
                goal = rootPart.Position + toward * math.min(14, dist - 14)
            else
                -- Phase 2: strafe whichever side has more open space.
                local tangent = Vector3.new(-away.Z, 0, away.X)
                local bestSide, bestScore
                for _, side in ipairs({ 1, -1 }) do
                    local probe = rootPart.Position + tangent * side * 12
                    local probeRisk = ThreatGeometry.risk(state.activeZones, probe, 2)
                    local wallParams = buildRaycastParams(rootPart.Parent, target)
                    wallParams.RespectCanCollide = true
                    local wall = Workspace:Raycast(rootPart.Position, tangent * side * 20, wallParams)
                    local score = probeRisk * 100 + (wall and (20 - (wall.Position - rootPart.Position).Magnitude) * 10 or 0)
                    if not bestScore or score < bestScore then
                        bestScore, bestSide = score, side
                    end
                end
                bestSide = bestSide or 1
                goal = rootPart.Position + tangent * bestSide * 14
            end
            goal = groundPosition(goal, rootPart.Parent, target)
            if walkingSegmentClear(rootPart, goal, target)
                and safeEnemyStep(rootPart.Position, goal) then
                clearPath()
                state.escapeGoal, state.escapeUntil = goal, now + 0.5
                state.escapeMargin = CFG.HAZARD_MARGIN
                state.escapeStartRisk = risk
                state.escapeReason = dist > 20 and "Closing on smash windup" or "Strafing smash by open space"
                state.status = state.escapeReason
                dodgeAlongEscape(humanoid, rootPart, goal, target, "smash" .. math.floor(now * 10), now, true)
                issueMove(humanoid, goal, "evade", now)
                return true
            end
            -- No valid smash goal: fall through to the regular escape logic.
        end
    end
    if state.blockedByHazard then
        state.escapeGoal = nil
        state.lastEscapePlan = -math.huge
    end
    if risk == 0 and not state.retreating and not contactThreat and crowd >= crowdLimit
        and not state.movementBlocked and not state.blockedByHazard then
        state.escapeGoal, state.threatReactionAt = nil, nil
        return false
    end
    if state.escapeGoal and now < (state.escapeUntil or 0) then
        if now - (state.lastEscapeCheck or 0) >= 0.2 then
            state.escapeClear = walkingSegmentClear(rootPart, state.escapeGoal, target)
            state.lastEscapeCheck = now
        end
        -- Commit to the escape walk: the plan was validated at selection and
        -- replans correct course within a fraction of a second. Re-validating
        -- strict per-tick checks is what used to freeze the character
        -- (safety-hold) inside resolving hitboxes. Only abort into something
        -- much worse than when the plan was made.
        if now >= (state.escapeCommitUntil or 0) and risk > (state.escapeStartRisk or 0) + 2.5 then
            state.escapeGoal = nil
        elseif (state.escapeGoal - rootPart.Position).Magnitude > math.max(3, humanoid.WalkSpeed * 0.25)
            and state.escapeClear then
            local contMargin = state.escapeMargin or CFG.HAZARD_MARGIN
            -- Survival-margin escapes already accepted crossing exposure at
            -- selection time; re-validating the strict segment would jitter
            -- between cells instead of committing to the least-bad one.
            -- They also bypass issueMove's guards, which would otherwise
            -- freeze the walk mid-escape (safety-hold inside a hitbox).
            if now >= (state.escapeCommitUntil or 0) and contMargin >= CFG.HAZARD_MARGIN
                and not ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, state.escapeGoal, contMargin) then
                state.escapeGoal = nil
            else
            state.status = state.escapeReason or "Avoiding nearby enemies"
            dodgeAlongEscape(humanoid, rootPart, state.escapeGoal, target, zone and zone.id or contactThreat, now)
            issueMove(humanoid, state.escapeGoal, "evade", now, contMargin < CFG.HAZARD_MARGIN)
            return true
            end
        end
    end
    state.escapeGoal = nil
    if zone then
        state.threatReactionAt = state.threatReactionAt or now
        if now - state.threatReactionAt < CFG.REACTION_TIME then
            state.status = "Reacting to attack"
            return true
        end
    end
    if now - state.lastEscapePlan < 0.12 then return true end
    state.lastEscapePlan = now
    local goal, escapeMargin, escapeReason = findEscapeGoal(rootPart, targetRoot)
    if not goal and (risk > 0 or state.blockedByHazard) then
        goal = findEmergencySideStep(rootPart, target)
    end
    state.movementBlocked, state.blockedByHazard = false, false
    if not goal then
        state.blockedByHazard = false
        if risk > 0 then
            local backup = findLeastBadStep(rootPart, target)
            if backup then
                clearPath()
                state.escapeGoal, state.escapeUntil = backup, now + 0.8
                state.escapeCommitUntil = now + 0.35
                state.escapeMargin = 2
                state.escapeStartRisk = risk
                state.escapeClear, state.lastEscapeCheck = true, now
                state.escapeReason = "Cutting through weakest exposure"
                state.status = state.escapeReason
                logThreat("escape", state.escapeReason)
                dodgeAlongEscape(humanoid, rootPart, backup, target, zone and zone.id or contactThreat, now, true)
                issueMove(humanoid, backup, "evade", now, true)
                return true
            end
        end
        state.status = "Waiting for safe escape route"
        stopMovement(humanoid, rootPart)
        return true
    end
    clearPath()
    state.motionGoal, state.fallbackGoal = nil, nil
    state.escapeGoal, state.escapeUntil = goal, now + 1.5
    state.escapeMargin = escapeMargin or CFG.HAZARD_MARGIN
    state.escapeCommitUntil = escapeMargin and now + 0.9 or now + 0.45
    state.escapeStartRisk = risk
    state.escapeClear, state.lastEscapeCheck = true, now
    state.safetyUntil = now + 0.75
    dodgeAlongEscape(humanoid, rootPart, goal, target, zone and zone.id or contactThreat, now,
        escapeMargin ~= nil)
    state.escapeReason = escapeReason or (zone and "Escaping attack area" or "Avoiding nearby enemies")
    state.status = state.escapeReason
    logThreat("escape", state.escapeReason)
    issueMove(humanoid, goal, "evade", now)
    return true
end

local function controllerTick()
    if not state.running or state.closed then return end
    local character, humanoid, rootPart = getChar()
    if not character or not humanoid or not rootPart then state.status = "No character"; return end
    if humanoid.Health <= 0 then
        state.status = "Dead"
        if state.motionMode ~= "dead" then clearPath(); state.motionMode = "dead" end
        return
    end

    local now = os.clock()
    CFG.ATTACK_RANGE = CFG.SPELL_RANGE_OVERRIDE > 0 and CFG.SPELL_RANGE_OVERRIDE or 26
    if CFG.SMART_FARM then
        local snapshots = abilities.Snapshot(now)
        for _, snapshot in pairs(snapshots) do
            local profile = FarmPlanner.profile(snapshot)
            if profile.range and (profile.mode == "target" or profile.mode == "splash") then
                CFG.ATTACK_RANGE = math.max(CFG.ATTACK_RANGE, profile.range)
            end
        end
        for _, snapshot in pairs(snapshots) do
            local profile = FarmPlanner.profile(snapshot)
            if profile.mode == "heal" or profile.mode == "shield" or profile.mode == "buff" then
                abilities.TryCast(now, CFG.SKILL_COOLDOWN, function(slot, candidate)
                    local candidateProfile = FarmPlanner.profile(candidate)
                    return (candidateProfile.mode == "heal" or candidateProfile.mode == "shield" or candidateProfile.mode == "buff")
                        and prepareSpell(slot, candidate)
                end)
                break
            end
        end
    end
    for model, health in pairs(state.prevHealth) do
        local trackedHumanoid = model:FindFirstChildOfClass("Humanoid")
        if trackedHumanoid and health > 0 and trackedHumanoid.Health <= 0 then
            state.kills = state.kills + 1
        end
        if not trackedHumanoid or trackedHumanoid.Health <= 0 or not model:IsDescendantOf(Workspace) then
            state.prevHealth[model] = nil
        else
            state.prevHealth[model] = trackedHumanoid.Health
        end
    end
    local target, distance = getClosestEnemy(rootPart, now)
    if not target then
        state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
        state.retreating = false
        state.escapeGoal, state.lastThreatPart = nil, nil
        state.status, state.targetName, state.targetDist = "Waiting for wave", "None", 0
        state.currentTarget, state.lockedTarget = nil, nil
        stopMovement(humanoid, rootPart)
        state.pathStatus = "Pathfinding: waiting for next wave"
        return
    end

    -- Burn phase: while the Protector lives, it is the only target. Chasing
    -- adds walks the bot across resolving volleys for no damage gain.
    if target.Name ~= "Ancient Temple Protector" then
        for _, model in ipairs(state.cachedTargets) do
            if model.Name == "Ancient Temple Protector" and isValidTarget(model) and model:IsDescendantOf(Workspace) then
                target = model
                state.lockedTarget = model
                local bossRoot = getRootPart(model)
                if bossRoot then distance = (bossRoot.Position - rootPart.Position).Magnitude end
                break
            end
        end
    end

    local targetHumanoid, targetRoot = target:FindFirstChildOfClass("Humanoid"), getRootPart(target)
    if not targetHumanoid or targetHumanoid.Health <= 0 or not targetRoot then
        state.lockedTarget = nil
        return
    end
    if state.currentTarget ~= target then
        local previousRoot = state.currentTarget and getRootPart(state.currentTarget)
        if not previousRoot or (previousRoot.Position - targetRoot.Position).Magnitude > 4 then
            clearPath()
            state.motionGoal, state.fallbackGoal = nil, nil
            state.pathUpdateTime = 0
        end
        state.lastProgressDistance, state.stuckStartTime = math.huge, 0
        state.routeFails, state.wanderGoal, state.wallSide = 0, nil, nil
        state.wallVisits, state.wallFlips = {}, 0
    end
    state.currentTarget, state.targetName, state.targetDist = target, target.Name, distance
    -- Doomed round: same target for 3 minutes with zero kills and zero damage
    -- dealt (e.g. mob under the map behind a wall that never opens). Solo
    -- only, so nobody else's run is ever touched. Leaves via teleToLobby.
    do
        local dw = state.doomWatch
        local hp = targetHumanoid and targetHumanoid.Health or 0
        if not dw or dw.target ~= target then
            state.doomWatch = { target = target, since = now, kills = state.kills, hp = hp }
        elseif now - dw.since >= 180 and state.kills == dw.kills and hp >= dw.hp and not state.doomFired then
            if #Players:GetPlayers() <= 1 then
                state.doomFired = true
                logThreat("doomed", target.Name)
                warn("[EnemyWalker] doomed round, leaving: " .. target.Name)
                pcall(function()
                    game:GetService("ReplicatedStorage"):WaitForChild("remotes"):WaitForChild("teleToLobby", 5):FireServer()
                end)
            end
        end
    end
    local protectorRear = target.Name == "Ancient Temple Protector"
    local protectorApproach
    if protectorRear then
        local offset = rootPart.Position - targetRoot.Position
        if Vector3.new(offset.X, 0, offset.Z).Magnitude > 40 then
            local side = offset:Dot(targetRoot.CFrame.RightVector) >= 0 and 1 or -1
            protectorApproach = groundPosition(targetRoot.Position + targetRoot.CFrame.RightVector * side * 24
                - targetRoot.CFrame.LookVector * 16, character, target)
        end
    end
    state.prevHealth[target] = targetHumanoid.Health
    refreshSafety(rootPart, now)
    if handleSafety(humanoid, rootPart, target, targetRoot, now) then
        state.navigationPhase = "evade"
        if CFG.AUTO_ABILITIES and CFG.SMART_FARM then
            abilities.TryCast(now, CFG.SKILL_COOLDOWN, function(slot, snapshot)
                return FarmPlanner.profile(snapshot).mode == "buff" and prepareSpell(slot, snapshot)
            end)
        end
        faceEnemy(humanoid, rootPart, targetRoot)
        if distance <= CFG.ATTACK_RANGE and not hasBlockingRay(rootPart.Position, targetRoot.Position, character, target) then castSkill() end
        return
    end

    -- A combat-distance point on this side of a wall is not an attack position.
    -- Route to the enemy's reachable area before holding distance or casting.
    if hasBlockingRay(rootPart.Position, targetRoot.Position, character, target) then
        state.navigationPhase = "approach"
        state.lastThreatPart, state.dodgeGoal = nil, nil
        restoreFacing()
        local routeGoal, routeAnchor = mapRouteGoal(rootPart, now)
        if routeGoal and distance > 35 then
            state.status = "Following map route: " .. routeAnchor.name
            followGoal(humanoid, rootPart, routeGoal, "map-route", now, target)
            updateProgress(humanoid, rootPart, routeGoal, target, now)
            return
        end
        -- Target on a higher level: the flat navmesh route walks underneath
        -- and never climbs. Chain upward recovery steps toward the target
        -- until the height gap closes. Gated on SUSTAINED elevation so flying
        -- trash bobbing up and down doesn't yo-yo the bot up every slope, and
        -- on horizontal closeness so far targets route normally instead of
        -- climbing random hills hundreds of studs away.
        local climbDy = targetRoot.Position.Y - rootPart.Position.Y
        local climbFlat = Vector3.new(targetRoot.Position.X - rootPart.Position.X, 0, targetRoot.Position.Z - rootPart.Position.Z).Magnitude
        if climbDy > 8 and climbFlat < 80 then
            state.climbDySince = state.climbDySince or now
        else
            state.climbDySince = nil
        end
        if state.climbDySince and now - state.climbDySince >= 3 and now - (state.lastClimbTry or -math.huge) >= 2.5 then
            state.lastClimbTry = now
            local climbPath, climbPoints, higher = findRecoveryPath(rootPart, targetRoot.Position, target, 2.5)
            if higher and climbPath and climbPoints then
                clearPath()
                state.terrainRecovery = higher
                state.pathObject = climbPath
                state.pathBlocked = false
                state.pathGoal, state.pathMode = higher, "terrain-recovery"
                state.motionGoal, state.motionGoalMode = higher, "terrain-recovery"
                state.waypoints = climbPoints
                state.currentWaypointIndex = 1
                state.pathStatus = "Climbing to " .. target.Name
                state.status = state.pathStatus
                updateProgress(humanoid, rootPart, higher, target, now)
                return
            end
        end
        -- Unreachable target (locked door, unspawned wave, or geometry we
        -- cannot close on): holding and wandering beats ramming forever.
        -- Far targets hold after ~20 failures; close ones only after ~40, so
        -- ordinary approaches never park within sight of the enemy.
        local holdFails = state.routeFails or 0
        local shouldHold = holdFails > 20 and (distance > 50 or holdFails > 40)
        if shouldHold then
            -- Re-probe periodically: an opened door makes the far target
            -- reachable again, which resumes the advance below.
            if now - (state.lastHoldProbe or -math.huge) >= 2 then
                state.lastHoldProbe = now
                if walkingSegmentClear(rootPart, targetRoot.Position, target) then
                    state.routeFails = 0
                    state.wanderGoal = nil
                    shouldHold = (state.routeFails or 0) > 20 and (distance > 50 or (state.routeFails or 0) > 40)
                end
            end
        end
        if shouldHold then
            if not state.wanderGoal or now > (state.wanderUntil or 0)
                or (state.wanderGoal - rootPart.Position).Magnitude <= CFG.WAYPOINT_REACH_THRESHOLD then
                -- Wall-follow: the target sits behind a wall and pacing into
                -- it loops forever. Walk ALONG the wall on a fixed side;
                -- doors, stairs and ramps are found by traversal, and the 2s
                -- re-probe resumes the advance when the ray clears. Fixed
                -- side plus visited-ground memory is what breaks circles:
                -- flipping sides or re-walking fresh ground is penalized.
                local bearing = math.atan2(targetRoot.Position.Z - rootPart.Position.Z, targetRoot.Position.X - rootPart.Position.X)
                state.wallSide = state.wallSide or (math.random() < 0.5 and 1 or -1)
                state.wallVisits = state.wallVisits or {}
                for key, at in pairs(state.wallVisits) do
                    if now - at > 45 then state.wallVisits[key] = nil end
                end
                local function visitPenalty(pos)
                    local penalty = 0
                    for key in pairs(state.wallVisits) do
                        local cx, cz = key:match("([^:]+):([^:]+)")
                        cx, cz = tonumber(cx), tonumber(cz)
                        if cx and cz then
                            local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(cx, 0, cz)).Magnitude
                            if d < 14 then penalty = penalty + (14 - d) * 6 end
                        end
                    end
                    return penalty
                end
                local bestGoal, bestScore, bestSide
                for _, side in ipairs({ state.wallSide, -state.wallSide }) do
                    local tangent = Vector3.new(-math.sin(bearing), 0, math.cos(bearing)) * side
                    local forward = Vector3.new(math.cos(bearing), 0, math.sin(bearing))
                    local goal = rootPart.Position + (tangent * 0.92 + forward * 0.39).Unit * 26
                    local candidate = groundPosition(goal, character, target)
                    if walkingSegmentClear(rootPart, candidate, target) then
                        local score = (side == state.wallSide and 0 or 60) + visitPenalty(candidate)
                        if not bestScore or score < bestScore then
                            bestScore, bestSide, bestGoal = score, side, candidate
                        end
                    end
                end
                if bestGoal then
                    -- Only adopt a flipped side after repeated forced flips;
                    -- a single blocked pick must not reverse the whole traverse.
                    if bestSide ~= state.wallSide then
                        state.wallFlips = (state.wallFlips or 0) + 1
                        if state.wallFlips >= 3 then
                            state.wallSide, state.wallFlips = bestSide, 0
                        end
                    else
                        state.wallFlips = 0
                    end
                    state.wallVisits[math.floor(bestGoal.X / 7) .. ":" .. math.floor(bestGoal.Z / 7)] = now
                    state.wanderGoal = bestGoal
                else
                    local goal = rootPart.Position + Vector3.new(math.cos(bearing), 0, math.sin(bearing)) * 20
                    state.wanderGoal = chooseFallbackStep(rootPart, goal, target)
                end
                state.wanderUntil = now + 6
            end
            state.status = "Holding for wave/door: " .. target.Name
            if state.wanderGoal then issueMove(humanoid, state.wanderGoal, "hold", now) end
            if distance <= CFG.ATTACK_RANGE then castSkill() end
            return
        elseif distance <= 50 and (state.routeFails or 0) < 40 then
            state.routeFails = 0
            state.wanderGoal = nil
        end
        state.status = "Routing around obstacle to " .. target.Name
        local approachGoal = protectorApproach or (protectorRear
            and groundPosition(targetRoot.Position - targetRoot.CFrame.LookVector * 16, character, target)) or targetRoot.Position
        followGoal(humanoid, rootPart, approachGoal, "approach", now, target)
        updateProgress(humanoid, rootPart, approachGoal, target, now)
        return
    end
    state.navigationPhase = "combat"
    faceEnemy(humanoid, rootPart, targetRoot)

    if protectorApproach then
        state.status = "Approaching Protector flank"
        followGoal(humanoid, rootPart, protectorApproach, "approach", now, target)
        updateProgress(humanoid, rootPart, protectorApproach, target, now)
        if distance <= CFG.ATTACK_RANGE then castSkill() end
        return
    end
    if not protectorRear and CFG.FARM_POSITION == "Nearest" and distance >= CFG.COMBAT_MIN_DISTANCE and distance <= CFG.COMBAT_MAX_DISTANCE then
        state.status = "Attacking " .. target.Name
        -- Keep a small combat orbit while casting so a target in range does not
        -- turn the character into a stationary hitbox.
        local offset = rootPart.Position - targetRoot.Position
        local flat = Vector3.new(offset.X, 0, offset.Z)
        if flat.Magnitude < 0.1 then flat = Vector3.new(1, 0, 0) end
        local tangent = Vector3.new(-flat.Z, 0, flat.X).Unit * state.dodgeSide * 4
        local desiredPosition = groundPosition(targetRoot.Position + flat.Unit * CFG.COMBAT_DISTANCE + tangent, character, target)
        if (desiredPosition - rootPart.Position).Magnitude > 1 then
            followGoal(humanoid, rootPart, desiredPosition, "combat", now, target)
        end
        castSkill()
        return
    end

    local offset = rootPart.Position - targetRoot.Position
    local flat = Vector3.new(offset.X, 0, offset.Z)
    if protectorRear or CFG.FARM_POSITION == "Behind" then flat = -targetRoot.CFrame.LookVector
    elseif CFG.FARM_POSITION == "Front" then flat = targetRoot.CFrame.LookVector
    elseif CFG.FARM_POSITION == "Left" then flat = -targetRoot.CFrame.RightVector
    elseif CFG.FARM_POSITION == "Right" then flat = targetRoot.CFrame.RightVector end
    flat = Vector3.new(flat.X, 0, flat.Z)
    if flat.Magnitude < 0.1 then flat = Vector3.new(1, 0, 0) end
    if protectorRear then
        local radial = Vector3.new(offset.X, 0, offset.Z)
        if radial.Magnitude > 0.1 then
            radial = radial.Unit
            state.protectorOrbitSide = state.protectorOrbitSide or 1
            flat = CFrame.fromAxisAngle(Vector3.yAxis, state.protectorOrbitSide * math.pi / 6):VectorToWorldSpace(radial)
        end
    end
    local desiredPosition = groundPosition(targetRoot.Position + flat.Unit * CFG.COMBAT_DISTANCE, character, target)
    -- Idle creep (Protector): with no active threats, blink small steps
    -- toward the hold instead of only walking. Closes distance between
    -- volleys so the fight happens at sidestep range, not cross-arena.
    -- Budget + same-threat cooldown bound it; dodges always win ties.
    if protectorRear and #state.activeZones == 0 then
        local creepDelta = desiredPosition - rootPart.Position
        if creepDelta.Magnitude > 15 then
            local step = rootPart.Position + creepDelta.Unit * math.min(CFG.DODGE_LATERAL_DISTANCE, creepDelta.Magnitude)
            if safeEnemyStep(rootPart.Position, step)
                and ThreatGeometry.segmentSafe(state.activeZones, rootPart.Position, step, CFG.HAZARD_MARGIN)
                and walkingSegmentClear(rootPart, step, target) then
                performDodgeTeleport(humanoid, rootPart, step, target, "creep", now)
            end
        end
    end
    if (Vector3.new(desiredPosition.X - rootPart.Position.X, 0, desiredPosition.Z - rootPart.Position.Z)).Magnitude < 2 then
        stopMovement(humanoid, rootPart)
        if distance <= CFG.ATTACK_RANGE then castSkill() end
        return
    end
    state.status = protectorRear and "Circling Protector in spell range"
        or (distance > CFG.COMBAT_MAX_DISTANCE and "Moving to " .. target.Name or "Creating space from " .. target.Name)
    followGoal(humanoid, rootPart, desiredPosition, "combat", now, target)
    updateProgress(humanoid, rootPart, desiredPosition, target, now)
    if distance <= CFG.ATTACK_RANGE then castSkill() end
end

connect(RunService.RenderStepped, function()
    local target = state.currentTarget
    if not state.running or state.closed or state.navigationPhase == "approach"
        or not isValidTarget(target) or not target:IsDescendantOf(Workspace) then
        restoreFacing()
        return
    end
    local _, humanoid, rootPart = getChar()
    if not humanoid or not rootPart or humanoid.Health <= 0 then
        restoreFacing()
        return
    end
    faceEnemy(humanoid, rootPart, getRootPart(target))
end)

local lastControl, lastError = 0, 0
connect(RunService.Heartbeat, function()
    local now = os.clock()
    if now - lastControl < CFG.CONTROL_INTERVAL then return end
    lastControl = now
    if not state.running or state.closed or state.updateBusy then return end
    state.updateBusy = true
    local ok, err = pcall(controllerTick)
    state.updateBusy = false
    if not ok and now - lastError >= 2 then
        lastError = now
        warn("[EnemyWalker] controller error: " .. tostring(err))
    end
end)

local function setRunning(running)
    if state.closed or state.running == running then return end
    state.running = running
    if state.running then
        state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
        state.retreating = false
        state.escapeGoal, state.escapeUntil, state.safetyUntil = nil, 0, 0
        state.movementBlocked, state.lastSafetyScan, state.lastEscapePlan = false, -math.huge, -math.huge
        state.skillQ_count, state.skillE_count, state.kills, state.stuckRetries = 0, 0, 0, 0
        state.skillToggle, state.lastSkillTime = false, 0
        state.lockedTarget, state.currentTarget = nil, nil
        state.cachedTargets, state.prevHealth = {}, setmetatable({}, { __mode = "k" })
        state.lastTargetScan, state.lastTargetChoice = 0, 0
        state.lastDodgeTime, state.dodgeGoal = 0, nil
        state.motionGoal, state.motionGoalMode, state.motionMode = nil, nil, "idle"
        state.fallbackGoal, state.fallbackUntil = nil, 0
        state.stuckStartTime, state.stuckCount, state.pathUpdateTime = 0, 0, 0
        state.routeFails, state.wanderGoal, state.wanderUntil = 0, nil, 0
        state.wallSide, state.wallVisits, state.wallFlips = nil, {}, 0
        state.routeDungeon, state.routeAnchors, state.routeAnchorIndex = nil, {}, 1
        state.routeScannedAt = -math.huge
        state.doomWatch, state.doomFired = nil, nil
        state.lastDodgeThreat, state.lastDodgeThreatAt = nil, 0
        state.dodgeCount, state.damageEvents, state.lastPlayerHealth = 0, 0, nil
        createWaypointFolder()
        state.pathStatus = "Pathfinding: active"
    else
        state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
        restoreFacing()
        local _, humanoid, rootPart = getChar()
        if humanoid and rootPart then stopMovement(humanoid, rootPart) end
        state.status, state.targetName, state.targetDist = "Idle", "Scanning...", 0
        state.lockedTarget, state.currentTarget = nil, nil
        clearPath()
        state.pathStatus = "Pathfinding: stopped"
    end
end

local function shutdown()
    if state.closed then return end
    state.closed, state.running = true, false
    restoreFacing()
    local _, humanoid, rootPart = getChar()
    if humanoid and rootPart then stopMovement(humanoid, rootPart) end
    clearPath()
    if state.waypointFolder then state.waypointFolder:Destroy() end
    for _, connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
    table.clear(threatParts)
    table.clear(safeSpots)
    table.clear(humanoidModels)
    table.clear(announcedZones)
end

local function watchHealth(character)
    if not character then return end
    local humanoid = character:WaitForChild("Humanoid", 5)
    if not humanoid or state.closed or character ~= player.Character then return end
    if state.healthConnection then state.healthConnection:Disconnect() end
    local previous = humanoid.Health
    state.healthConnection = connect(humanoid.HealthChanged, function(health)
        if state.running and not state.closed and character == player.Character and health < previous - 0.01 then
            state.damageEvents = state.damageEvents + 1
            state.lastDamage = { amount = previous - health, at = os.clock(), health = health,
                mode = state.motionMode, status = state.status, hazards = #state.activeZones,
                distance = state.targetDist }
            local root = character:FindFirstChild("HumanoidRootPart")
            if root then
                local nearby = {}
                for _, zone in ipairs(state.activeZones) do
                    local zp = zone.frame.Position
                    table.insert(nearby, {
                        name = typeof(zone.id) == "Instance" and zone.id:GetFullName() or "Announced telegraph",
                        clearance = ThreatGeometry.clearance(zone, root.Position, 0),
                        position = zone.frame.Position, size = zone.size, shape = zone.shape,
                        zoneAt = string.format("%d,%d,%d", math.floor(zp.X), math.floor(zp.Y), math.floor(zp.Z)),
                    })
                end
                table.sort(nearby, function(a, b) return a.clearance < b.clearance end)
                while #nearby > 4 do table.remove(nearby) end
                state.lastDamage.position = root.Position
                state.lastDamage.goal = state.escapeGoal
                do
                    local boss = state.currentTarget
                    local bossRoot = boss and getRootPart(boss)
                    if bossRoot then
                        local bp = bossRoot.Position
                        state.lastDamage.boss = (boss and boss.Name or "?") .. string.format(" @%d,%d,%d", math.floor(bp.X), math.floor(bp.Y), math.floor(bp.Z))
                    end
                end
                state.lastDamage.speed = humanoid.WalkSpeed
                state.lastDamage.nearestHazards = nearby
            end
            warn(string.format("[EnemyWalker] damage event #%d (%.0f -> %.0f)", state.damageEvents, previous, health))
            logThreat("hit", { amount = math.floor(previous - health) })
        end
        previous = health
    end)
end

connect(player.CharacterAdded, function(character)
    state.protectorOrbitSide = nil
    state.protectorEscapeVisits = nil
    state.threatReactionAt = nil
    state.castAimTarget, state.farmPlan, state.groupCount = nil, nil, 0
    state.retreating = false
    state.escapeGoal, state.escapeUntil, state.safetyUntil = nil, 0, 0
    state.movementBlocked, state.lastSafetyScan = false, -math.huge
    restoreFacing()
    state.lockedTarget, state.currentTarget = nil, nil
    state.cachedTargets, state.prevHealth = {}, setmetatable({}, { __mode = "k" })
    state.motionGoal, state.motionGoalMode, state.motionMode = nil, nil, "idle"
    state.fallbackGoal, state.fallbackUntil = nil, 0
    state.lastPlayerHealth, state.lastTargetScan = nil, 0
    state.routeDungeon, state.routeAnchors, state.routeAnchorIndex = nil, {}, 1
    state.routeScannedAt = -math.huge
    state.pathUpdateTime = 0
    state.stuckStartTime, state.stuckCount = 0, 0
    state.dodgeGoal = nil
    state.lastDodgeThreat, state.lastDodgeThreatAt = nil, 0
    clearPath()
    task.spawn(watchHealth, character)
end)
task.spawn(watchHealth, player.Character)

print("[EnemyWalker] loaded: indexed targets, asynchronous paths, bounded teleport dodges")

return {
    Config = CFG,
    State = state,
    SetRunning = setRunning,
    Shutdown = shutdown,
    AbilityStatus = function() return abilities.Snapshot(os.clock()) end,
    SetAbilityInventory = abilities.SetInventory,
    AbilityProfile = FarmPlanner.profile,
    SetWaypoints = function(enabled)
        CFG.SHOW_WAYPOINTS = enabled
        if enabled then visualizeWaypoints(state.waypoints, state.currentWaypointIndex) else clearWaypointVisuals() end
    end,
}
