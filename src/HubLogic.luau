-- Pure decisions shared by the role coordinator and focused policy checks.
local Logic = {}
Logic.Difficulties = { "Easy", "Medium", "Hard", "Insane", "Nightmare" }
-- These seasonal entries currently lack reliable event flags in getDungeonStats.
local seasonal = { ["Egg Island"] = true, Krampus = true, ["Tutorial Dungeon"] = true }

function Logic.tokens(text)
    local result, seen = {}, {}
    -- Roblox usernames and numeric IDs contain no whitespace. Accept pasted rows,
    -- tabs, spaces, commas, and semicolons while keeping first-seen spelling.
    for token in (text or ""):gmatch("[^,%s;]+") do
        if token ~= "" and not seen[token:lower()] then
            seen[token:lower()] = true
            table.insert(result, token)
        end
    end
    return result
end

function Logic.requestUsername(text)
    if type(text) ~= "string" then return nil end
    return text:match("^([%w_]+) %(LVL %d+%) wants to join your raid%.$")
        or text:match("^([%w_]+) wants to join your raid%.$")
end

function Logic.accountRole(party, username, userId)
    local function matches(value)
        for _, token in ipairs(Logic.tokens(value)) do
            if token:lower() == username:lower() or tonumber(token) == userId then return true end
        end
        return false
    end
    if matches(party.Host) then return "Host" end
    if matches(party.Carry) then return "Carry" end
    if matches(party.Alts) then return "Alt" end
end

function Logic.bestDungeon(catalog, level, pirateOnly)
    local best
    for name, stats in pairs(catalog) do
        if not seasonal[name] and (not pirateOnly or name == "Pirate Island") then
            for rank, difficulty in ipairs(Logic.Difficulties) do
                local data = stats[difficulty]
                local required = type(data) == "table" and tonumber(data.levelReq)
                if required and level and required <= level and not data.isEventPlace and not data.isBossKey
                    and (not best or required > best.levelReq or required == best.levelReq and rank > best.rank
                        or required == best.levelReq and rank == best.rank and name < best.Dungeon) then
                    best = { Dungeon = name, Difficulty = difficulty, levelReq = required, rank = rank }
                end
            end
        end
    end
    return best
end

function Logic.sameDungeon(a, b)
    return a and b and a.Dungeon == b.Dungeon and a.Difficulty == b.Difficulty
end

-- Protect every equipped ability slot, including the game's q2/e2 slots.
function Logic.isEquipped(item)
    if type(item.equipped) == "table" then
        for _, value in pairs(item.equipped) do if value ~= false then return true end end
        return false
    end
    return item.equipped ~= false
end

function Logic.heals(inventory)
    local result = {}
    for id, item in pairs(inventory.abilities or {}) do
        if item.name == "Universal Heal" and tostring(id):match("^ability_%d+$") then
            table.insert(result, { id = tonumber(id:match("%d+$")), item = item })
        end
    end
    table.sort(result, function(a, b)
        local function equipped(item)
            return Logic.isEquipped(item) and 1 or 0
        end
        local x, y = equipped(a.item), equipped(b.item)
        return x > y or x == y and a.id < b.id
    end)
    return result
end

function Logic.tankArmor(inventory, level)
    local result = {}
    for _, kind in ipairs({ "helmet", "chest" }) do
        local best
        for id, item in pairs(inventory[kind .. "s"] or {}) do
            local required, health = tonumber(item.levelReq), tonumber(item.health) or 0
            local name = tostring(item.name or ""):lower()
            local class = tostring(item.itemClass or item.class or ""):lower()
            local tank = class == "tank" or name:find("guardian", 1, true) or name:find("tank", 1, true)
                or health > 0 and (tonumber(item.spellPower) or 0) == 0 and (tonumber(item.physicalPower) or 0) == 0
            local number = tonumber(tostring(id):match("^" .. kind .. "_(%d+)$"))
            if tank and number and required and required <= level then
                if not best or required > best.required or required == best.required and health > best.health
                    or required == best.required and health == best.health and number < best.id then
                    best = { kind = kind, id = number, item = item, required = required, health = health }
                end
            end
        end
        if best then table.insert(result, best) end
    end
    return result
end

function Logic.normalizeItemName(name)
    return tostring(name or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
end

function Logic.keepNames(text)
    local keep = {}
    -- Spaces belong to item names; only rows, commas, or semicolons separate items.
    for name in (text or ""):gmatch("[^,;\r\n]+") do
        name = Logic.normalizeItemName(name)
        if name ~= "" then keep[name] = true end
    end
    return keep
end

function Logic.sellPlan(inventory, protected, keepItems, keepLegendary)
    local plan, count = { weapon = {}, helmet = {}, chest = {}, ability = {} }, 0
    local keep = {}
    local names = Logic.keepNames(keepItems)
    for index, heal in ipairs(Logic.heals(inventory)) do if index <= 2 then keep[heal.id] = true end end
    for kind, ids in pairs(plan) do
        for id, item in pairs(inventory[kind == "ability" and "abilities" or kind .. "s"] or {}) do
            local number = tonumber(tostring(id):match("^" .. kind .. "_(%d+)$"))
            local equipped = Logic.isEquipped(item)
            local legendary = keepLegendary and Logic.normalizeItemName(item.rarity) == "legendary"
            if not legendary and number and not names[Logic.normalizeItemName(item.name)] and not equipped and not item.locked and not item.favorite and not item.favourited
                and not (kind == "ability" and keep[number]) and not (protected and protected[id]) then
                table.insert(ids, number)
                count = count + 1
            end
        end
        table.sort(ids)
    end
    return plan, count
end

function Logic.partyReady(members, hostId, carryId)
    local hostLevel, missing, equal = nil, {}, true
    for _, member in ipairs(members) do
        if member.id == hostId and member.present then hostLevel = member.level end
        if not member.present or not member.level then table.insert(missing, member.name) end
    end
    if not hostLevel or #missing > 0 then return false, false, missing end
    for _, member in ipairs(members) do
        if member.id ~= carryId and member.level ~= hostLevel then equal = false end
    end
    return true, equal, missing
end

return Logic
