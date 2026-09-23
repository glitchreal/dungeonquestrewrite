-- Purchases use the inspected gold shop only; no MarketplaceService prompt path.
local BoostManager = {}
function BoostManager.new(config, runtime, isAlive)
    runtime.Boosts = runtime.Boosts or {}
    local state = { status = "Boosts: auto buy off", nextCheck = 0 }
    function state.Tick(now)
        if not config.AutoBuyBoosts then state.status = "Boosts: auto buy off"; return end
        if now < state.nextCheck then return end
        state.nextCheck = now + 15
        local statuses = {}
        local function inspect(entry)
            local offer = Adapter.boostOffer(entry)
            if type(offer) ~= "table" or offer.ready == false then
                table.insert(statuses, entry.name .. ": waiting for shop data"); return "wait"
            end
            -- Saved observations are diagnostic only. Re-query server on every execute.
            runtime.Boosts[entry.key or tostring(entry.id)] = offer
            if entry.key and (offer.owned == true or Adapter.value(game:GetService("Players").LocalPlayer, entry.key, false)) then
                table.insert(statuses, entry.name .. ": owned"); return "done"
            end
            if not entry.key and (tonumber(offer.remaining) == 0 or (tonumber(offer.nextAvailableIn) or 0) > 0) then
                table.insert(statuses, entry.name .. ": unavailable this cycle"); return "done"
            end
            if not entry.key and offer.valid ~= true then
                table.insert(statuses, entry.name .. ": offer unavailable"); return "wait"
            end
            local currency = offer.currency or (entry.key and "gold")
            if currency ~= "gold" then
                table.insert(statuses, entry.name .. ": " .. tostring(currency or "unknown currency") .. "; use game shop manually")
                return entry.key and "manual" or "wait"
            end
            local cost, gold = tonumber(offer.cost), Adapter.gold()
            if not cost or cost < 0 or not gold then
                table.insert(statuses, entry.name .. ": waiting for price/balance"); return "wait"
            end
            if gold < cost then
                table.insert(statuses, entry.name .. ": waiting for " .. string.format("%.0f", cost) .. " gold"); return "wait"
            end
            if not isAlive() or not config.AutoBuyBoosts then return "wait" end
            Adapter.buyBoost(entry, offer)
            table.insert(statuses, entry.name .. ": purchase requested; verifying server state")
            return "requested"
        end
        local ok, reason = pcall(function()
            for _, entry in ipairs(Adapter.PermanentBoosts) do
                local result = inspect(entry)
                if result ~= "done" and result ~= "manual" then return end
            end
            for _, entry in ipairs(Adapter.XPBoosts) do
                if inspect(entry) ~= "done" then return end
            end
        end)
        state.status = ok and table.concat(statuses, " | ") or ("Boosts: shop unavailable; retrying in 15s (" .. tostring(reason) .. ")")
    end
    return state
end
return BoostManager
