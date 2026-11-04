MZTransportClient = MZTransportClient or {}
MZTransportClient.Population = MZTransportClient.Population or {}
local Population = MZTransportClient.Population

local Active = {}

local function serverRequest(action, payload)
    TriggerServerEvent('mz_transport:server:request', action, payload or {})
end

local function spawnFailed(rideId)
    serverRequest('npcStatus', { rideId = rideId, status = 'spawn_failed' })
end

local function loadModel(model, vehicle)
    local hash = type(model) == 'number' and model or joaat(tostring(model or ''))
    if not IsModelValid(hash) or not IsModelInCdimage(hash) then return nil end
    if vehicle and not IsModelAVehicle(hash) then return nil end
    RequestModel(hash)
    local expires = GetGameTimer() + 10000
    while not HasModelLoaded(hash) and GetGameTimer() < expires do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

local function findSpawn(origin, minimum, maximum)
    local best, bestHeading
    for nth = 8, 40 do
        local ok, node, heading = GetNthClosestVehicleNodeWithHeading(
            origin.x, origin.y, origin.z, nth, 1, 3.0, 0
        )
        if ok and node then
            local distance = #(vector3(origin.x, origin.y, origin.z) - node)
            if distance >= minimum and distance <= maximum then
                best, bestHeading = node, heading
                if not IsSphereVisible(node.x, node.y, node.z, 3.0) then break end
            end
        end
    end
    return best, bestHeading
end

local function removeEntities(entry)
    if not entry then return end
    if entry.ped and DoesEntityExist(entry.ped) then
        SetEntityAsMissionEntity(entry.ped, true, true)
        DeleteEntity(entry.ped)
    end
    if entry.vehicle and DoesEntityExist(entry.vehicle) then
        SetEntityAsMissionEntity(entry.vehicle, true, true)
        DeleteEntity(entry.vehicle)
    end
end

function Population.Cleanup(rideId, delay)
    rideId = tonumber(rideId)
    local entry = rideId and Active[rideId] or nil
    if not entry then return end
    Active[rideId] = nil
    CreateThread(function()
        if tonumber(delay) and tonumber(delay) > 0 then Wait(tonumber(delay)) end
        removeEntities(entry)
    end)
end

RegisterNetEvent('mz_transport:client:npcCreate', function(data)
    data = type(data) == 'table' and data or {}
    local rideId = tonumber(data.rideId)
    if not rideId or Active[rideId] then return end
    local vehicleModel = loadModel(data.vehicleModel, true)
    local pedModel = loadModel(data.pedModel, false)
    if not vehicleModel or not pedModel then
        spawnFailed(rideId)
        return
    end

    local origin = data.origin
    local node, heading = findSpawn(
        origin,
        tonumber(data.minSpawnDistance) or 80.0,
        tonumber(data.maxSpawnDistance) or 180.0
    )
    if not node then
        spawnFailed(rideId)
        return
    end

    local vehicle = CreateVehicle(vehicleModel, node.x, node.y, node.z, heading or 0.0, true, true)
    if not vehicle or vehicle == 0 then spawnFailed(rideId) return end
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleNumberPlateText(vehicle, ('MZ%05d'):format(rideId % 100000))
    local ped = CreatePedInsideVehicle(vehicle, 26, pedModel, -1, true, true)
    if not ped or ped == 0 then
        DeleteEntity(vehicle)
        spawnFailed(rideId)
        return
    end
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, 0.15)
    local vehicleNetId, pedNetId = NetworkGetNetworkIdFromEntity(vehicle), NetworkGetNetworkIdFromEntity(ped)
    SetNetworkIdCanMigrate(vehicleNetId, true)
    SetNetworkIdCanMigrate(pedNetId, true)

    local entry = {
        rideId = rideId, nonce = data.nonce, vehicle = vehicle, ped = ped,
        origin = origin, destination = data.destination, phase = 'enroute',
        speed = tonumber(data.drivingSpeed) or 20.0,
        style = tonumber(data.drivingStyle) or 786603
    }
    Active[rideId] = entry
    TaskVehicleDriveToCoordLongrange(ped, vehicle, origin.x, origin.y, origin.z, entry.speed, entry.style, 8.0)
    serverRequest('npcReady', {
        rideId = rideId, nonce = data.nonce,
        pedNetId = pedNetId, vehicleNetId = vehicleNetId
    })
    SetModelAsNoLongerNeeded(vehicleModel)
    SetModelAsNoLongerNeeded(pedModel)

    CreateThread(function()
        local lastTrackingAt = 0
        while Active[rideId] == entry and DoesEntityExist(vehicle) and DoesEntityExist(ped) do
            local coords = GetEntityCoords(vehicle)
            if GetGameTimer() - lastTrackingAt >= 1000 then
                lastTrackingAt = GetGameTimer()
                serverRequest('npcStatus', { rideId = rideId, status = 'tracking' })
            end
            if entry.phase == 'enroute'
                and #(coords - vector3(origin.x, origin.y, origin.z)) <= 25.0 then
                TaskVehicleTempAction(ped, vehicle, 27, 3000)
                entry.phase = 'boarding'
                serverRequest('npcStatus', { rideId = rideId, status = 'arrived' })
            elseif entry.phase == 'boarding' and IsPedInVehicle(PlayerPedId(), vehicle, false) then
                entry.phase = 'trip'
                serverRequest('npcStatus', { rideId = rideId, status = 'boarded' })
                TaskVehicleDriveToCoordLongrange(
                    ped, vehicle, entry.destination.x, entry.destination.y, entry.destination.z,
                    entry.speed, entry.style, 8.0
                )
            elseif entry.phase == 'trip'
                and #(coords - vector3(entry.destination.x, entry.destination.y, entry.destination.z)) <= 25.0 then
                entry.phase = 'done'
                TaskVehicleTempAction(ped, vehicle, 27, 5000)
                serverRequest('npcStatus', { rideId = rideId, status = 'destination' })
            end
            Wait(500)
        end
        if Active[rideId] == entry and entry.phase ~= 'done' then
            Active[rideId] = nil
            serverRequest('npcStatus', { rideId = rideId, status = 'entity_lost' })
            removeEntities(entry)
        end
    end)
end)

RegisterNetEvent('mz_transport:client:npcCleanup', function(rideId, delay)
    Population.Cleanup(rideId, delay)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for rideId, entry in pairs(Active) do
        Active[rideId] = nil
        removeEntities(entry)
    end
end)
