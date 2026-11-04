MZTransportClient = MZTransportClient or {}
local GPS = MZTransportClient.GPS
local DriverRide
local LastDriverState
local LastRouteRideId
local LastRouteSignature

local function localError(action, errorCode, requestId)
    TriggerEvent('mz_phone:client:transportPayload', {
        type = 'response',
        action = action,
        requestId = requestId,
        ok = false,
        error = errorCode
    })
end

local function managedWaypointEnabled()
    return not (Config and Config.Ride and Config.Ride.ManagedWaypoint == false)
end

local function clearRideRoute(rideId)
    local target = rideId or LastRouteRideId
    if target and managedWaypointEnabled() then
        GPS.ClearManaged(('ride:%s'):format(target))
    end
    LastRouteRideId = nil
    LastRouteSignature = nil
end

--[[
    Aplica a politica de rota da corrida somente no motorista.
    Reaplica apenas quando a fase muda; heartbeats nao sobrescrevem o waypoint
    do jogador a cada segundo.
]]
local function applyRideRoute(ride)
    if not ride or not ride.id then
        clearRideRoute(LastRouteRideId)
        return
    end

    local route = GPS.RouteForRide(ride)
    if not route then return end

    if LastRouteRideId and tonumber(LastRouteRideId) ~= tonumber(ride.id) then
        clearRideRoute(LastRouteRideId)
    end
    LastRouteRideId = ride.id

    if route.clear then
        if managedWaypointEnabled() then
            GPS.ClearManaged(route.key)
        end
        LastRouteSignature = nil
        return
    end

    local signature = ('%s:%s'):format(route.key, route.phase)
    if signature == LastRouteSignature then return end
    if managedWaypointEnabled() then
        GPS.SetManaged(route.key, route.coords)
    else
        GPS.Set(route.coords)
    end
    LastRouteSignature = signature
end

local function requestTransportBootstrap()
    TriggerServerEvent('mz_transport:server:request', 'bootstrap', { role = 'driver' })
    SetTimeout(250, function()
        TriggerServerEvent('mz_transport:server:request', 'bootstrap', { role = 'passenger' })
    end)
end

RegisterNetEvent('mz_transport:client:phoneRequest', function(action, payload, requestId)
    action = tostring(action or '')
    payload = type(payload) == 'table' and payload or {}
    requestId = type(requestId) == 'string' and requestId or ''

    if action == 'estimate' or action == 'requestRide' then
        if type(payload.destination) ~= 'table' then
            local destination, err = GPS.GetWaypoint()
            if not destination then localError(action, err, requestId) return end
            payload.destination = destination
        end
    elseif action == 'setDriverOnline' then
        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle <= 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then
            localError(action, 'driver_not_in_driver_seat', requestId)
            return
        end
        local model = GetEntityModel(vehicle)
        local display = GetDisplayNameFromVehicleModel(model)
        local label = GetLabelText(display)
        payload.modelName = label ~= 'NULL' and label or display
        payload.modelHash = model
        payload.vehicleClass = GetVehicleClass(vehicle)
        payload.vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    elseif action == 'openGps' then
        local rideId = tonumber(payload.rideId)
        local ok, err
        if managedWaypointEnabled() and rideId and DriverRide and tonumber(DriverRide.id) == rideId then
            ok, err = GPS.SetManaged(('ride:%s'):format(rideId), payload.coords)
            if ok then
                LastRouteRideId = rideId
                LastRouteSignature = nil
            end
        else
            ok = GPS.Set(payload.coords)
            if not ok then err = 'invalid_coords' end
        end
        if not ok then
            localError(action, err or 'invalid_coords', requestId)
        else
            TriggerEvent('mz_phone:client:transportPayload', {
                type = 'response',
                action = action,
                requestId = requestId,
                ok = true
            })
        end
        return
    end

    TriggerServerEvent('mz_transport:server:request', action, payload, requestId)
end)

RegisterNetEvent('mz_transport:client:phonePayload', function(payload)
    payload = type(payload) == 'table' and payload or {}
    if payload.type == 'snapshot' and payload.role == 'driver' then
        DriverRide = payload.ride
        if DriverRide then
            applyRideRoute(DriverRide)
        else
            clearRideRoute(LastRouteRideId)
        end
    elseif payload.type == 'response' and payload.action == 'bootstrap'
        and payload.ok == true and payload.data and payload.data.role == 'driver' then
        LastDriverState = payload.data.state
        DriverRide = LastDriverState and LastDriverState.ride or nil
        if DriverRide then
            applyRideRoute(DriverRide)
        else
            clearRideRoute(LastRouteRideId)
        end
    elseif payload.type == 'response' and payload.action == 'setDriverOffline' and payload.ok == true then
        clearRideRoute(DriverRide and DriverRide.id or LastRouteRideId)
        DriverRide = nil
    end
    TriggerEvent('mz_phone:client:transportPayload', payload)
end)

-- Recupera o estado canonico apos restart/reconnect sem inventar corrida.
RegisterNetEvent('mz_core:client:playerLoaded', function()
    SetTimeout(750, requestTransportBootstrap)
end)

CreateThread(function()
    Wait(3000)
    if DriverRide == nil then
        requestTransportBootstrap()
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    clearRideRoute(LastRouteRideId)
end)

CreateThread(function()
    while true do
        if DriverRide and DriverRide.id
            and DriverRide.status ~= 'completed'
            and DriverRide.status ~= 'cancelled'
            and DriverRide.status ~= 'failed' then
            TriggerServerEvent('mz_transport:server:request', 'heartbeat', { rideId = DriverRide.id })
            Wait(Config.Ride.TrackingIntervalMs)
        else
            Wait(1000)
        end
    end
end)
