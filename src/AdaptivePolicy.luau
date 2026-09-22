-- Small on-device contextual bandit for decisions that benefit from experience.
-- This is intentionally bounded and explainable: it learns from local combat
-- outcomes, never sends telemetry, and falls back to the hand-tuned action until
-- enough evidence exists to justify changing behavior.
local AdaptivePolicy = {}

local VERSION = 1
local MAX_CONTEXTS = 48
local MAX_ACTIONS = 6
local MAX_COUNT = 1000000
local ALPHA = 0.18
local EXPLORATION = 0.08

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function validKey(value)
    return type(value) == "string" and #value > 0 and #value <= 80
end

local function actionList(actions)
    local result, seen = {}, {}
    if type(actions) ~= "table" then return result end
    for _, action in ipairs(actions) do
        if type(action) == "string" and #action > 0 and #action <= 32 and not seen[action] then
            seen[action] = true
            table.insert(result, action)
            if #result >= MAX_ACTIONS then break end
        end
    end
    return result
end

local function freshBucket()
    return { total = 0, actions = {} }
end

function AdaptivePolicy.new()
    local self = { version = VERSION, total = 0, contexts = {} }

    local function bucketFor(context, create)
        if not validKey(context) then return nil end
        local bucket = self.contexts[context]
        if not bucket and create then
            bucket = freshBucket()
            self.contexts[context] = bucket
        end
        return bucket
    end

    local function prune()
        local count = 0
        for _ in pairs(self.contexts) do count = count + 1 end
        if count <= MAX_CONTEXTS then return end
        local oldestKey, oldestAt = nil, math.huge
        for key, bucket in pairs(self.contexts) do
            local at = tonumber(bucket.lastAt) or 0
            if at < oldestAt then oldestKey, oldestAt = key, at end
        end
        if oldestKey then self.contexts[oldestKey] = nil end
    end

    function self:choose(context, actions, fallback)
        local choices = actionList(actions)
        if #choices == 0 then return fallback end
        local allowed = {}
        for _, action in ipairs(choices) do allowed[action] = true end
        if not allowed[fallback] then fallback = choices[1] end
        local bucket = bucketFor(context, true)
        bucket.lastAt = os.clock()

        -- Do not experiment in a fresh context. The controller's baseline has
        -- been hand-tuned and should win until the model has useful evidence.
        if (tonumber(bucket.total) or 0) < 3 then return fallback end
        if math.random() < EXPLORATION then
            return choices[math.random(1, #choices)]
        end

        local best, bestScore = fallback, -math.huge
        for _, action in ipairs(choices) do
            local sample = bucket.actions[action]
            local count = sample and tonumber(sample.count) or 0
            local value = sample and tonumber(sample.value) or 0
            -- Mild uncertainty bonus lets a new action catch up without
            -- overpowering a strong, repeatedly observed action.
            local score = value + 0.24 / math.sqrt(math.max(1, count))
            if action == fallback then score = score + 0.03 end
            if score > bestScore then best, bestScore = action, score end
        end
        return best
    end

    function self:observe(context, action, reward)
        if not validKey(context) or type(action) ~= "string" or #action == 0 then return end
        local bucket = bucketFor(context, true)
        local sample = bucket.actions[action]
        if not sample then sample = { count = 0, value = 0 }; bucket.actions[action] = sample end
        sample.count = math.min(MAX_COUNT, (tonumber(sample.count) or 0) + 1)
        sample.value = clamp((tonumber(sample.value) or 0) + ALPHA * (clamp(tonumber(reward) or 0, 0, 1) - (tonumber(sample.value) or 0)), 0, 1)
        bucket.total = math.min(MAX_COUNT, (tonumber(bucket.total) or 0) + 1)
        bucket.lastAt = os.clock()
        self.total = math.min(MAX_COUNT, (tonumber(self.total) or 0) + 1)
        prune()
    end

    function self:load(data)
        if type(data) ~= "table" or tonumber(data.Version) ~= VERSION or type(data.Contexts) ~= "table" then return end
        self.contexts, self.total = {}, math.max(0, tonumber(data.Total) or 0)
        local contextCount = 0
        for context, source in pairs(data.Contexts) do
            if validKey(context) and type(source) == "table" and type(source.Actions) == "table" then
                local bucket = freshBucket()
                bucket.total, bucket.lastAt = math.max(0, tonumber(source.Total) or 0), tonumber(source.LastAt) or 0
                local actionCount = 0
                for action, value in pairs(source.Actions) do
                    if type(action) == "string" and #action <= 32 and type(value) == "table" and actionCount < MAX_ACTIONS then
                        bucket.actions[action] = {
                            count = math.min(MAX_COUNT, math.max(0, tonumber(value.Count) or 0)),
                            value = clamp(tonumber(value.Value) or 0, 0, 1),
                        }
                        actionCount = actionCount + 1
                    end
                end
                self.contexts[context] = bucket
                contextCount = contextCount + 1
                if contextCount >= MAX_CONTEXTS then break end
            end
        end
    end

    function self:export()
        local result = { Version = VERSION, Total = self.total, Contexts = {} }
        for context, bucket in pairs(self.contexts) do
            local output = { Total = bucket.total or 0, LastAt = bucket.lastAt or 0, Actions = {} }
            for action, sample in pairs(bucket.actions or {}) do
                output.Actions[action] = { Count = sample.count or 0, Value = sample.value or 0 }
            end
            result.Contexts[context] = output
        end
        return result
    end

    function self:summary()
        local contexts = 0
        for _ in pairs(self.contexts) do contexts = contexts + 1 end
        return { observations = self.total, contexts = contexts }
    end

    return self
end

return AdaptivePolicy
