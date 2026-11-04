MZTransport.PopulationProvider = MZTransport.PopulationProvider or {}
local Provider = MZTransport.PopulationProvider
local RideService = MZTransport.RideService
local Repository = MZTransport.Repository
local Utils = MZTransport.Utils
local States = MZTransport.States

function Provider.CreateDriver(ride)
    if not ride or ride.status ~= States.SEARCHING_DRIVER or ride.npcPending then return false end
    if Config.NPCDriver.Enabled ~= true then
        RideService.Transition(ride, States.FAILED, { reason = 'no_driver_available' })
        RideService.PushSnapshot(ride)
        RideService.Release(ride)
        return false
    end
    ride.npcPending = true
    ride.npcNonce = ('%s_%s_%s'):format(ride.id, os.time(), math.random(100000, 999999))
    ride.npcPedModel = Config.NPCDriver.Models[math.random(1, #Config.NPCDriver.Models)]
    ride.npcVehicleModel = Config.NPCDriver.Vehicles[math.random(1, #Config.NPCDriver.Vehicles)]
    TriggerClientEvent('mz_transport:client:npcCreate', ride.passengerSource, {
        rideId = ride.id,
        nonce = ride.npcNonce,
        origin = ride.origin,
        destination = ride.destination,
        pedModel = ride.npcPedModel,
        vehicleModel = ride.npcVehicleModel,
        minSpawnDistance = Config.NPCDriver.MinSpawnDistance,
        maxSpawnDistance = Config.NPCDriver.MaxSpawnDistance,
        drivingSpeed = Config.NPCDriver.DrivingSpeed,
        drivingStyle = Config.NPCDriver.DrivingStyle
    })
    local nonce = ride.npcNonce
    SetTimeout((tonumber(Config.NPCDriver.SpawnTimeoutSeconds) or 20) * 1000, function()
        if ride.status == States.SEARCHING_DRIVER and ride.npcPending
            and ride.npcNonce == nonce and not ride.npcVehicleNetId then
            ride.npcPending = false
            RideService.Transition(ride, States.FAILED, { reason = 'npc_spawn_timeout' })
            RideService.PushSnapshot(ride)
            RideService.Release(ride)
            TriggerClientEvent('mz_transport:client:npcCleanup', ride.passengerSource, ride.id)
        end
    end)
    return true
end

function Provider.Ready(source, payload)
    local ride = RideService.Get(payload and payload.rideId)
    if not ride or ride.passengerSource ~= source or ride.status ~= States.SEARCHING_DRIVER then
        return false, 'ride_not_searching'
    end
    if not ride.npcPending or tostring(payload.nonce or '') ~= tostring(ride.npcNonce) then
        return false, 'npc_request_invalid'
    end
    local pedNetId, vehicleNetId = tonumber(payload.pedNetId), tonumber(payload.vehicleNetId)
    if not pedNetId or pedNetId <= 0 or not vehicleNetId or vehicleNetId <= 0 then
        return false, 'npc_entities_invalid'
    end
    local ped, vehicle = NetworkGetEntityFromNetworkId(pedNetId), NetworkGetEntityFromNetworkId(vehicleNetId)
    if not ped or ped <= 0 or not vehicle or vehicle <= 0
        or not DoesEntityExist(ped) or not DoesEntityExist(vehicle) then
        return false, 'npc_entities_missing'
    end
    if GetPedInVehicleSeat(vehicle, -1) ~= ped then return false, 'npc_driver_seat_invalid' end

    ride.npcPedNetId, ride.npcVehicleNetId = pedNetId, vehicleNetId
    ride.npcPending = false
    ride.driverType = 'npc'
    ride.driverName = 'MZ Move'
    ride.vehicleModel = ride.npcVehicleModel
    ride.vehiclePlate = Utils.Trim(GetVehicleNumberPlateText(vehicle), 16)
    ride.npcProfile = {
        name = ride.driverName,
        rating = 5.0,
        rides = 0,
        vehicle = ride.vehicleModel,
        plate = ride.vehiclePlate
    }
    local affected = Repository.AssignDriver(ride)
    if tonumber(affected) ~= 1 then
        ride.npcPending = false
        ride.npcPedNetId, ride.npcVehicleNetId = nil, nil
        TriggerClientEvent('mz_transport:client:npcCleanup', source, ride.id)
        return false, 'ride_already_assigned'
    end
    RideService.Transition(ride, States.DRIVER_ASSIGNED)
    RideService.Transition(ride, States.DRIVER_ENROUTE)
    RideService.NotifyPhone(source, 'Motorista encontrado', 'Um motorista MZ Move esta a caminho.', 'success')
    RideService.PushSnapshot(ride)
    print(('[MZ_TRANSPORT] npc_created ride=%s ped=%s vehicle=%s'):format(ride.id, pedNetId, vehicleNetId))
    return true
end

local function npcVehicle(ride)
    if not ride or not ride.npcVehicleNetId then return nil end
    local vehicle = NetworkGetEntityFromNetworkId(ride.npcVehicleNetId)
    return vehicle and vehicle > 0 and DoesEntityExist(vehicle) and vehicle or nil
end

function Provider.Status(source, payload)
    local ride = RideService.Get(payload and payload.rideId)
    if not ride or ride.passengerSource ~= source then
        return false, 'npc_ride_invalid'
    end
    local status = tostring(payload.status or '')
    if status == 'spawn_failed' and ride.npcPending and ride.status == States.SEARCHING_DRIVER then
        ride.npcPending = false
        RideService.Transition(ride, States.FAILED, { reason = 'npc_spawn_failed' })
        RideService.PushSnapshot(ride)
        RideService.Release(ride)
        return true
    end
    if status == 'entity_lost' and ride.driverType == 'npc'
        and not MZTransport.TerminalStates[ride.status] then
        ride.failureReason = 'npc_entity_lost'
        RideService.Transition(ride, States.FAILED, { reason = ride.failureReason })
        RideService.PushSnapshot(ride)
        RideService.Release(ride)
        Provider.Cleanup(ride)
        return true
    end
    if ride.driverType ~= 'npc' then return false, 'npc_ride_invalid' end
    local vehicle = npcVehicle(ride)
    if not vehicle then return false, 'npc_vehicle_missing' end
    ride.npcCoords = Utils.NormalizeCoords(GetEntityCoords(vehicle))

    if status == 'tracking' and not MZTransport.TerminalStates[ride.status] then
        RideService.PushSnapshot(ride)
        return true
    elseif status == 'arrived' and ride.status == States.DRIVER_ENROUTE then
        if Utils.Distance(ride.npcCoords, ride.origin) > Config.Ride.DriverArrivalDistance + 12.0 then
            return false, 'npc_too_far_from_passenger'
        end
        RideService.Transition(ride, States.DRIVER_ARRIVED)
        RideService.Transition(ride, States.PASSENGER_BOARDING)
        RideService.NotifyPhone(source, 'Seu motorista chegou', 'Entre no veiculo para iniciar.', 'success')
    elseif status == 'boarded' and ride.status == States.PASSENGER_BOARDING then
        local passengerPed = GetPlayerPed(source)
        if GetVehiclePedIsIn(passengerPed, false) ~= vehicle then return false, 'passenger_not_in_vehicle' end
        RideService.Transition(ride, States.IN_TRIP)
        print(('[MZ_TRANSPORT] trip_started ride=%s type=npc'):format(ride.id))
    elseif status == 'destination' and ride.status == States.IN_TRIP then
        if Utils.Distance(ride.npcCoords, ride.destination) > Config.Ride.DestinationArrivalDistance + 12.0 then
            return false, 'npc_too_far_from_destination'
        end
        RideService.Transition(ride, States.ARRIVED_DESTINATION)
        RideService.Complete(ride)
        TriggerClientEvent('mz_transport:client:npcCleanup', source, ride.id, 5000)
        return true
    else
        return false, 'npc_status_invalid'
    end
    RideService.PushSnapshot(ride)
    return true
end

function Provider.Cleanup(ride)
    if not ride then return end
    if ride.passengerSource then TriggerClientEvent('mz_transport:client:npcCleanup', ride.passengerSource, ride.id) end
    for _, netId in ipairs({ ride.npcPedNetId, ride.npcVehicleNetId }) do
        if netId then
            local entity = NetworkGetEntityFromNetworkId(netId)
            if entity and entity > 0 and DoesEntityExist(entity) then pcall(DeleteEntity, entity) end
        end
    end
    ride.npcPedNetId, ride.npcVehicleNetId = nil, nil
    print(('[MZ_TRANSPORT] npc_removed ride=%s'):format(tostring(ride.id)))
end

-- Contract for a future population_mz.lua provider:
-- CreateDriver(ride), Ready(source, payload), Status(source, payload), Cleanup(ride).
-- The provider owns entity lifecycle only; pricing, matching, payment and state
-- transitions remain in mz_transport services.
