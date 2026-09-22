local Geometry = {}
local BASE_MARGIN = 4

function Geometry.segmentDistance(position, startPosition, endPosition)
    local delta = endPosition - startPosition
    local lengthSquared = delta:Dot(delta)
    local fraction = lengthSquared > 0.001 and math.clamp((position - startPosition):Dot(delta) / lengthSquared, 0, 1) or 0
    return (position - (startPosition + delta * fraction)).Magnitude
end

function Geometry.clearance(zone, position, margin, arrivalTime)
    local point = zone.frame:PointToObjectSpace(position)
    local half = zone.size * 0.5
    if zone.shape == "ProtectorSmash" then
        -- Smash corridors earn extra margin: they expand after being modeled
        -- and every recent death landed a few studs inside the modeled edge.
        margin = (margin or 0) + 4
        local height = math.abs(point.Y) - half.Y - BASE_MARGIN
        if height > 0 then return height end
        local forward = -point.Z
        local travel = zone.travelDistance
        local age = zone.born and (os.clock() - zone.born) or zone.forecastAge or 0
        if zone.born or zone.forecastAge then
            travel = math.min(travel, math.max(0, age + 0.25 + (arrivalTime or 0)) * 50)
        end
        local width = zone.startWidth * 0.5 + math.clamp(forward + 5, 0, travel) * 0.5
        return math.max(math.abs(point.X) - width - margin,
            -forward - 5 - margin, forward - travel - 5 - margin)
    end
    if zone.moving and zone.shape == "Block" then
        -- Enclose the observed translation, including generic moving precasts
        -- whose instance names do not identify them as projectiles.
        local travel = zone.frame:VectorToObjectSpace(zone.velocity) * zone.lookahead
        point = point - travel * 0.5
        half = half + Vector3.new(math.abs(travel.X), math.abs(travel.Y), math.abs(travel.Z)) * 0.5
    end
    if zone.shape == "Cylinder" then
        local height = math.abs(point.X) - half.X - BASE_MARGIN
        if height > 0 then return height end
        return Vector2.new(point.Y, point.Z).Magnitude - math.max(half.Y, half.Z) - margin
    end
    if zone.shape == "Projectile" then
        return Geometry.segmentDistance(position, zone.frame.Position, zone.frame.Position + zone.velocity * zone.lookahead)
            - math.max(half.X, half.Y, half.Z) - margin
    end
    local height = math.abs(point.Y) - half.Y - BASE_MARGIN
    if height > 0 then return height end
    return math.max(math.abs(point.X) - half.X - margin, math.abs(point.Z) - half.Z - margin)
end

-- Lateral exit from a traveling smash corridor: how far sideways out of the
-- corridor, and in which world direction the nearer edge lies. Returns nil
-- when already clear or too deep to matter.
function Geometry.smashExit(zone, position, margin)
    if zone.shape ~= "ProtectorSmash" then return nil end
    local point = zone.frame:PointToObjectSpace(position)
    local half = zone.size * 0.5
    if math.abs(point.Y) - half.Y - BASE_MARGIN > 0 then return nil end
    local forward = -point.Z
    local travel = zone.travelDistance
    local age = zone.born and (os.clock() - zone.born) or zone.forecastAge or 0
    if zone.born or zone.forecastAge then
        travel = math.min(travel, math.max(0, age + 0.25) * 50)
    end
    local width = zone.startWidth * 0.5 + math.clamp(forward + 5, 0, travel) * 0.5
    local need = width + (margin or 0) - math.abs(point.X)
    if need <= 0 or need > 45 then return nil end
    local lateral = zone.frame.RightVector
    if math.abs(lateral.Y) > 0.5 then return nil end
    lateral = Vector3.new(lateral.X, 0, lateral.Z)
    if lateral.Magnitude < 0.01 then return nil end
    if point.X < 0 then lateral = -lateral end
    return need, lateral.Unit
end

function Geometry.risk(zones, position, margin)
    local risk, nearest = 0, nil
    for _, zone in ipairs(zones) do
        local clearance = Geometry.clearance(zone, position, margin)
        if clearance < 0 then
            risk = risk + 1 + clearance * clearance
            if not nearest or clearance < nearest.clearance then nearest = { zone = zone, clearance = clearance } end
        end
    end
    return risk, nearest and nearest.zone
end

function Geometry.segmentSafe(zones, startPosition, endPosition, margin)
    local relevant = {}
    local padding = math.sqrt(2 * margin * margin + 16)
    for _, zone in ipairs(zones) do
        local travel = (zone.moving or zone.shape == "Projectile")
            and zone.velocity.Magnitude * zone.lookahead or 0
        local radius = zone.size.Magnitude * 0.5 + padding + travel
        if Geometry.segmentDistance(zone.frame.Position, startPosition, endPosition) <= radius then
            table.insert(relevant, zone)
        end
    end
    if #relevant == 0 then return true end
    local length = (endPosition - startPosition).Magnitude
    local steps = math.max(1, math.ceil(length * 2))
    local initial = {}
    local previousRisk = 0
    for index, zone in ipairs(relevant) do
        local clearance = Geometry.clearance(zone, startPosition, margin)
        initial[index] = clearance
        if clearance < 0 then previousRisk = previousRisk + 1 + clearance * clearance end
    end
    -- Overlapping telegraphs can require moving toward one edge while escaping
    -- the others. Reject new hazards, but judge existing overlaps together.
    for i = 1, steps do
        local position = startPosition:Lerp(endPosition, i / steps)
        local risk = 0
        for index, zone in ipairs(relevant) do
            local clearance = Geometry.clearance(zone, position, margin, length * i / steps / math.max(1, zone.walkSpeed or 16))
            if initial[index] >= 0 and clearance < -0.02 then return false end
            if clearance < 0 then risk = risk + 1 + clearance * clearance end
        end
        if risk > previousRisk + 0.02 then return false end
        previousRisk = risk
    end
    return true
end

-- Adaptive safety spacing: adds margin based on recent hit and health.
-- 3 studs briefly after a hit, up to 8 studs at low health.
-- The larger buffer applies, rather than stacking both.
-- Enable by passing true as the third parameter, or disable with false.
function Geometry.adaptiveSafetyMargin(timeSinceHit, healthPercentage, adaptive)
    if adaptive == false then return 0 end
    local recentHit = timeSinceHit and timeSinceHit < 1.0
    local lowHealth = healthPercentage and healthPercentage < 0.3
    local bonus = 0
    if recentHit then bonus = 3 end
    if lowHealth then bonus = math.max(bonus, 8 * (1 - healthPercentage / 0.3)) end
    return bonus
end

return Geometry
