local Logic = {}
Logic.Difficulties = { "Easy", "Medium", "Hard", "Insane", "Nightmare" }

function Logic.eligibleDifficulties(stats, level)
    local values = {}
    for _, name in ipairs(Logic.Difficulties) do
        local entry = stats and stats[name]
        local required = type(entry) == "table" and tonumber(entry.levelReq)
        if required and level and level >= required then table.insert(values, name) end
    end
    return values
end

function Logic.bestGear(inventory, level, class)
    local result = {}
    for _, kind in ipairs({ "weapon", "helmet", "chest" }) do
        local best, bestScore, bestHealth = nil, -math.huge, -math.huge
        for id, item in pairs(inventory[kind .. "s"] or {}) do
            local required = tonumber(item.levelReq)
            local number = id:match("^" .. kind .. "_(%d+)$")
            if number and required and required <= level then
                local score = tonumber(item[class == "Mage" and "spellPower" or (kind == "weapon" and "physicalDamage" or "physicalPower")]) or 0
                local health = tonumber(item.health) or 0
                if score > bestScore or (score == bestScore and health > bestHealth)
                    or (score == bestScore and health == bestHealth and item.equipped == true) then
                    bestScore, bestHealth = score, health
                    best = { kind = kind, id = number, item = item }
                end
            end
        end
        if best then table.insert(result, best) end
    end
    return result
end

function Logic.raidTiers(inventory)
    local tiers = {}
    for key, owned in pairs(inventory.keys or {}) do
        local tier = tonumber(key)
        if owned == true and tier and tier >= 1 then table.insert(tiers, tier) end
    end
    table.sort(tiers)
    return tiers
end

function Logic.duration(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

function Logic.validWebhook(url)
    return type(url) == "string" and url:match("^https://discord%.com/api/webhooks/%d+/[%w_-]+$") ~= nil
end

function Logic.allowedPlayer(name, userId, csv)
    for token in (csv or ""):gmatch("[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        if token:lower() == name:lower() or tonumber(token) == userId then return true end
    end
    return false
end

return Logic
