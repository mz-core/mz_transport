MZTransport.Utils = MZTransport.Utils or {}
local Utils = MZTransport.Utils

function Utils.IsFiniteNumber(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function Utils.NormalizeCoords(value)
    if value == nil then return nil end
    local ok, rawX, rawY, rawZ = pcall(function()
        return value.x or value[1], value.y or value[2], value.z or value[3]
    end)
    if not ok then return nil end
    local x = tonumber(rawX)
    local y = tonumber(rawY)
    local z = tonumber(rawZ) or 0.0
    if not Utils.IsFiniteNumber(x) or not Utils.IsFiniteNumber(y) or not Utils.IsFiniteNumber(z) then
        return nil
    end
    if math.abs(x) > 20000.0 or math.abs(y) > 20000.0 or z < -2000.0 or z > 3000.0 then
        return nil
    end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

function Utils.Distance(a, b)
    a, b = Utils.NormalizeCoords(a), Utils.NormalizeCoords(b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Utils.ClampInteger(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not Utils.IsFiniteNumber(value) then return fallback end
    value = math.floor(value)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function Utils.Trim(value, maximum)
    value = tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if maximum and #value > maximum then value = value:sub(1, maximum) end
    return value
end

function Utils.Copy(value, depth)
    if type(value) ~= 'table' then return value end
    depth = (depth or 0) + 1
    if depth > 6 then return nil end
    local out = {}
    for key, child in pairs(value) do out[key] = Utils.Copy(child, depth) end
    return out
end
