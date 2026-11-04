--[[
    mz_transport - ponte GPS client-side.

    O GTA V possui UM unico waypoint nativo (blip 8). Para nao destruir a
    navegacao pessoal do jogador, a rota de corrida e tratada como "managed":

      1. antes do primeiro waypoint de corrida, o waypoint pessoal e capturado;
      2. cada fase da corrida (coleta -> destino) usa a MESMA chave da corrida;
      3. no cleanup, so removemos o waypoint se ele ainda for o da corrida
         (comparacao por proximidade). Se o jogador trocou ou removeu, nao
         tocamos nele;
      4. se o waypoint atual ainda for o da corrida, limpamos e restauramos o
         waypoint pessoal capturado.

    Limitacao real: como o native so aceita um waypoint, uma fase nova da
    corrida sobrescreve um waypoint pessoal definido durante a corrida. Esse
    comportamento e explicitamente documentado; nunca removemos um waypoint
    que nao seja comprovadamente nosso.
]]

MZTransportClient = MZTransportClient or {}
MZTransportClient.GPS = MZTransportClient.GPS or {}
local GPS = MZTransportClient.GPS

local MANAGED_EPSILON = 3.0

local Managed = {
    key = nil,
    coords = nil,
    personal = nil,
    generation = 0
}

local function readWaypoint()
    if type(GetFirstBlipInfoId) ~= 'function'
        or type(DoesBlipExist) ~= 'function'
        or type(GetBlipInfoIdCoord) ~= 'function' then
        return nil
    end
    local ok, blip = pcall(GetFirstBlipInfoId, 8)
    if not ok or not blip or blip == 0 then return nil end
    local existsOk, exists = pcall(DoesBlipExist, blip)
    if not existsOk or not exists then return nil end
    local coordsOk, coords = pcall(GetBlipInfoIdCoord, blip)
    if not coordsOk or type(coords) ~= 'table' then return nil end
    local x, y = tonumber(coords.x), tonumber(coords.y)
    if not x or not y or x ~= x or y ~= y then return nil end
    return { x = x + 0.0, y = y + 0.0 }
end

local function samePoint(a, b)
    if not a or not b then return false end
    local dx, dy = a.x - b.x, a.y - b.y
    return (dx * dx + dy * dy) <= (MANAGED_EPSILON * MANAGED_EPSILON)
end

local function validCoords(coords)
    if type(coords) ~= 'table' then return nil end
    local x, y = tonumber(coords.x), tonumber(coords.y)
    if not x or not y or x ~= x or y ~= y
        or math.abs(x) > 20000.0 or math.abs(y) > 20000.0 then
        return nil
    end
    return { x = x + 0.0, y = y + 0.0 }
end

function GPS.GetWaypoint()
    local blip = GetFirstBlipInfoId(8)
    if not blip or blip == 0 or not DoesBlipExist(blip) then return nil, 'waypoint_not_set' end
    local coords = GetBlipInfoIdCoord(blip)
    local z = coords.z
    local found, ground = GetGroundZFor_3dCoord(coords.x, coords.y, 1000.0, false)
    if found then z = ground end
    return { x = coords.x + 0.0, y = coords.y + 0.0, z = z + 0.0 }
end

function GPS.Set(coords)
    local point = validCoords(coords)
    if not point then return false end
    SetNewWaypoint(point.x + 0.0, point.y + 0.0)
    return true
end

function GPS.Clear()
    if type(SetWaypointOff) ~= 'function' then return false, 'waypoint_clear_unavailable' end
    local ok = pcall(SetWaypointOff)
    return ok == true
end

--[[
    Define um waypoint controlado pela corrida.
    key = 'ride:<id>'. A captura do waypoint pessoal ocorre apenas na primeira
    chamada de uma sequencia managed.
]]
function GPS.SetManaged(key, coords)
    if type(key) ~= 'string' or key == '' then return false, 'managed_key_required' end
    local point = validCoords(coords)
    if not point then return false, 'invalid_coords' end

    if Managed.key == nil then
        Managed.personal = readWaypoint()
    end

    if not GPS.Set(point) then return false, 'waypoint_failed' end
    Managed.key = key
    Managed.coords = point
    Managed.generation = (Managed.generation or 0) + 1
    return true
end

--[[
    Remove o waypoint managed APENAS se ele ainda for o da corrida.
    Retorna:
      true  -> limpou/restaurou ou nada a fazer
      true, 'waypoint_changed_by_player' -> waypoint atual nao e nosso; preservado
      false, err -> chave diferente ou falha
]]
function GPS.ClearManaged(key)
    if not Managed.key then return true end
    if key and key ~= Managed.key then return false, 'managed_key_mismatch' end

    local current = readWaypoint()
    local isOurs = current ~= nil and samePoint(current, Managed.coords)
    local personal = Managed.personal

    Managed.key, Managed.coords, Managed.personal = nil, nil, nil

    if not isOurs then
        -- waypoint do jogador (ou removido por ele): nunca tocar
        return true, 'waypoint_changed_by_player'
    end

    GPS.Clear()
    if personal then
        GPS.Set(personal)
    end
    return true
end

function GPS.GetManaged()
    if not Managed.key then return nil end
    return {
        key = Managed.key,
        coords = Managed.coords and { x = Managed.coords.x, y = Managed.coords.y } or nil,
        generation = Managed.generation
    }
end

--[[
    Politica de rota por estado da corrida (somente motorista):
      driver_assigned / driver_enroute -> coleta
      in_trip                          -> destino
      arrived_destination / terminais  -> cleanup
      outros                           -> sem rota automatica
]]
function GPS.RouteForRide(ride)
    if type(ride) ~= 'table' or not ride.id then return nil end
    local key = ('ride:%s'):format(ride.id)
    if ride.status == 'driver_assigned' or ride.status == 'driver_enroute' then
        return { key = key, phase = 'pickup', coords = ride.origin }
    end
    if ride.status == 'in_trip' then
        return { key = key, phase = 'trip', coords = ride.destination }
    end
    if ride.status == 'arrived_destination' then
        return { key = key, phase = 'arrived', clear = true }
    end
    local terminal = MZTransport and MZTransport.TerminalStates
    if terminal and terminal[ride.status] then
        return { key = key, phase = 'terminal', clear = true }
    end
    return nil
end
