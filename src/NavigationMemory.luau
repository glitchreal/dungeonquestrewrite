-- Small, reversible navigation/boss memory adapted from the older controller.
-- Live geometry always wins; this only changes tie breaking and bounded retries.
local Memory = {}
local VERSION, MAX_CONTEXTS, MAX_ACTIONS, MAX_SAMPLES = 1, 96, 12, 40
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function validKey(value) return type(value) == "string" and #value > 0 and #value <= 96 end
function Memory.new()
    local self = { version = VERSION, contexts = {}, total = 0 }
    local function bucket(context)
        if not validKey(context) then return nil end
        local value = self.contexts[context]
        if not value then
            local count = 0; for _ in pairs(self.contexts) do count = count + 1 end
            if count >= MAX_CONTEXTS then
                local oldest, oldestAt
                for key, entry in pairs(self.contexts) do
                    if not oldestAt or (entry.lastAt or 0) < oldestAt then oldest, oldest, oldestAt = key, key, entry.lastAt or 0 end
                end
                if oldest then self.contexts[oldest] = nil end
            end
            value = { total = 0, lastAt = 0, actions = {} }
            self.contexts[context] = value
        end
        return value
    end
    local function fade(entry, now)
        local age = math.max(0, now - (entry.lastAt or now))
        if age > 900 then entry.total = math.floor(entry.total * 0.5); entry.lastAt = now end
        for action, sample in pairs(entry.actions) do
            if now - (sample.at or now) > 1800 then entry.actions[action] = nil end
        end
    end
    function self:score(context, action, now)
        local entry = self.contexts[context]; if not entry then return 0.5 end
        fade(entry, now or os.clock())
        local sample = entry.actions[action]; if not sample then return 0.5 end
        return clamp(sample.value or 0.5, 0.05, 0.95)
    end
    function self:choose(context, actions, now)
        local best, bestScore
        for _, action in ipairs(actions) do
            local score = self:score(context, action, now)
            if not bestScore or score > bestScore then best, bestScore = action, score end
        end
        return best or actions[1]
    end
    function self:observe(context, action, reward, now)
        if not validKey(context) or type(action) ~= "string" or #action > 48 then return end
        local entry = bucket(context); if not entry then return end
        now, reward = now or os.clock(), clamp(tonumber(reward) or 0, -1, 1)
        fade(entry, now)
        local sample = entry.actions[action] or { count = 0, value = 0.5, at = now }
        sample.count = math.min(MAX_SAMPLES, sample.count + 1)
        local rate = 1 / math.max(4, sample.count)
        sample.value = clamp(sample.value + rate * ((reward + 1) * 0.5 - sample.value), 0.05, 0.95)
        sample.at = now; entry.actions[action] = sample
        entry.total = math.min(MAX_SAMPLES * MAX_ACTIONS, entry.total + 1); entry.lastAt = now
        self.total = math.min(MAX_CONTEXTS * MAX_SAMPLES, self.total + 1)
        local count = 0; for _ in pairs(entry.actions) do count = count + 1 end
        if count > MAX_ACTIONS then
            local oldest, oldestAt
            for key, value in pairs(entry.actions) do if not oldestAt or value.at < oldestAt then oldest, oldestAt = key, value.at end end
            if oldest then entry.actions[oldest] = nil end
        end
    end
    function self:load(data)
        if type(data) ~= "table" or data.Version ~= VERSION or type(data.Contexts) ~= "table" then return end
        self.contexts, self.total = {}, clamp(tonumber(data.Total) or 0, 0, MAX_CONTEXTS * MAX_SAMPLES)
        for context, source in pairs(data.Contexts) do
            if validKey(context) and type(source) == "table" and type(source.Actions) == "table" then
                local entry = { total = clamp(tonumber(source.Total) or 0, 0, MAX_SAMPLES * MAX_ACTIONS), lastAt = tonumber(source.LastAt) or 0, actions = {} }
                local count = 0
                for action, value in pairs(source.Actions) do
                    if type(action) == "string" and type(value) == "table" and count < MAX_ACTIONS then
                        entry.actions[action] = { count = clamp(tonumber(value.Count) or 0, 0, MAX_SAMPLES), value = clamp(tonumber(value.Value) or 0.5, 0.05, 0.95), at = tonumber(value.At) or entry.lastAt }
                        count = count + 1
                    end
                end
                self.contexts[context] = entry
            end
        end
    end
    function self:export()
        local result = { Version = VERSION, Total = self.total, Contexts = {} }
        for context, entry in pairs(self.contexts) do
            result.Contexts[context] = { Total = entry.total, LastAt = entry.lastAt, Actions = {} }
            for action, sample in pairs(entry.actions) do result.Contexts[context].Actions[action] = { Count = sample.count, Value = sample.value, At = sample.at } end
        end
        return result
    end
    function self:summary()
        local contexts = 0; for _ in pairs(self.contexts) do contexts = contexts + 1 end
        return { observations = self.total, contexts = contexts }
    end
    return self
end
return Memory
