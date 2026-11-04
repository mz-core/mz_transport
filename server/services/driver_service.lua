MZTransport.DriverService = MZTransport.DriverService or {}
local DriverService = MZTransport.DriverService
local Utils = MZTransport.Utils
local Repository = MZTransport.Repository

DriverService.Runtime = DriverService.Runtime or {}

local function coreExport(name, ...)
    local args = table.pack(...)
    local ok, result = pcall(function()
        if name == 'ResolvePlayerIdentity' then
            return exports['mz_core']:ResolvePlayerIdentity(args[1])
        elseif name == 'GetPlayerSnapshot' then
            return exports['mz_core']:GetPlayerSnapshot(args[1])
        end
        error(('unsupported mz_core export: %s'):format(tostring(name)))
    end)
    return ok and result or nil
end

local function playerOrganizations(source)
    local ok, organizations = pcall(function()
        return exports['mz_org']:GetPlayerOrgs(source)
    end)
    return ok and type(organizations) == 'table' and organizations or {}
end

function DriverService.GetIdentity(source)
    source = tonumber(source)
    if not source or source <= 0 or GetPlayerName(source) == nil then return nil, 'player_not_found' end
    local identity = coreExport('ResolvePlayerIdentity', source)
    if type(identity) ~= 'table' or identity.ok ~= true or not tonumber(identity.characterId) then
        return nil, identity and identity.error or 'identity_unavailable'
    end
    return identity
end

function DriverService.GetPlayerSnapshot(source)
    return coreExport('GetPlayerSnapshot', source)
end

function DriverService.DisplayName(source)
    local player = DriverService.GetPlayerSnapshot(source) or {}
    local charinfo = type(player.charinfo) == 'table' and player.charinfo or {}
    local name = Utils.Trim(('%s %s'):format(charinfo.firstname or '', charinfo.lastname or ''), 120)
    return name ~= '' and name or Utils.Trim(GetPlayerName(source), 120)
end

local function configuredModelAllowed(model)
    local allowed, blocked = Config.DriverVehicle.AllowedModels, Config.DriverVehicle.BlockedModels
    if blocked[model] or blocked[tostring(model)] then return false end
    if next(allowed) ~= nil and not allowed[model] and not allowed[tostring(model)] then return false end
    return true
end

local function configuredClassAllowed(class)
    if Config.DriverVehicle.BlockedClasses[class] then return false end
    if next(Config.DriverVehicle.AllowedClasses) ~= nil and not Config.DriverVehicle.AllowedClasses[class] then
        return false
    end
    if class == 8 and not Config.DriverVehicle.AllowMotorcycles then return false end
    if class == 13 and not Config.DriverVehicle.AllowBicycles then return false end
    if class == 14 and not Config.DriverVehicle.AllowBoats then return false end
    if (class == 15 or class == 16) and not Config.DriverVehicle.AllowAircraft then return false end
    return true
end

local function configuredTypeAllowed(vehicleType)
    vehicleType = tostring(vehicleType or ''):lower()
    if vehicleType == 'boat' or vehicleType == 'submarine' then
        return Config.DriverVehicle.AllowBoats == true
    end
    if vehicleType == 'heli' or vehicleType == 'plane' then
        return Config.DriverVehicle.AllowAircraft == true
    end
    if vehicleType == 'bike' or vehicleType == 'bicycle' or vehicleType == 'motorcycle' then
        return Config.DriverVehicle.AllowMotorcycles == true or Config.DriverVehicle.AllowBicycles == true
    end
    return true
end

local function resolveVehicleClass(vehicle, model, payload)
    local classOk, class = pcall(GetVehicleClass, vehicle)
    if classOk and tonumber(class) then return tonumber(class), false end

    classOk, class = pcall(GetVehicleClassFromName, model)
    if classOk and tonumber(class) then return tonumber(class), false end

    class = tonumber(payload and payload.vehicleClass)
    if not class or class < 0 or class > 22 or class ~= math.floor(class) then
        return nil
    end
    return class, true
end

function DriverService.ValidateVehicle(source, payload)
    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 or not DoesEntityExist(ped) then return nil, 'ped_not_found' end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then return nil, 'driver_not_in_vehicle' end
    if GetPedInVehicleSeat(vehicle, -1) ~= ped then return nil, 'driver_not_in_driver_seat' end

    local healthOk, bodyHealth = pcall(GetVehicleBodyHealth, vehicle)
    if healthOk and tonumber(bodyHealth) and tonumber(bodyHealth) <= 0.0 then
        return nil, 'vehicle_destroyed'
    end
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if not tonumber(netId) or tonumber(netId) <= 0 then return nil, 'vehicle_not_networked' end
    local claimedNetId = tonumber(payload and payload.vehicleNetId)
    if claimedNetId and claimedNetId ~= tonumber(netId) then return nil, 'vehicle_claim_mismatch' end

    local model = GetEntityModel(vehicle)
    local claimedModel = tonumber(payload and payload.modelHash)
    if claimedModel and claimedModel ~= tonumber(model) then return nil, 'vehicle_claim_mismatch' end

    local typeOk, vehicleType = pcall(GetVehicleType, vehicle)
    if typeOk and vehicleType and not configuredTypeAllowed(vehicleType) then
        return nil, 'vehicle_class_blocked'
    end

    local class, usedClientFallback = resolveVehicleClass(vehicle, model, payload)
    if class == nil then return nil, 'vehicle_class_unavailable' end
    if usedClientFallback and (not claimedNetId or not claimedModel) then
        return nil, 'vehicle_class_unavailable'
    end
    if not configuredClassAllowed(class) then return nil, 'vehicle_class_blocked' end
    if not configuredModelAllowed(model) then return nil, 'vehicle_model_blocked' end

    return {
        entity = vehicle,
        netId = netId,
        class = class,
        model = model,
        plate = Utils.Trim(GetVehicleNumberPlateText(vehicle), 16)
    }
end

local function jobAllowed(source)
    if Config.Driver.RequireJob ~= true then return true end
    for _, organization in pairs(playerOrganizations(source)) do
        if type(organization) == 'table' and tostring(organization.type or '') == 'job'
            and organization.active ~= false
            and Config.Driver.AllowedJobs[tostring(organization.code or '')] == true then
            return true
        end
    end
    return false
end

function DriverService.SetOnline(source, payload)
    local identity, identityErr = DriverService.GetIdentity(source)
    if not identity then return nil, identityErr end
    if not jobAllowed(source) then return nil, 'driver_job_not_allowed' end
    local vehicle, vehicleErr = DriverService.ValidateVehicle(source, payload)
    if not vehicle then return nil, vehicleErr end

    local existing = DriverService.Runtime[source]
    if existing and existing.activeRideId then return nil, 'driver_has_active_ride' end
    local profile = Repository.EnsureDriver(identity) or {}
    local coords = Utils.NormalizeCoords(GetEntityCoords(GetPlayerPed(source)))
    local driver = existing or {}
    driver.offerVersion = tonumber(driver.offerVersion) or 0
    driver.source = source
    driver.characterId = tonumber(identity.characterId)
    driver.citizenid = tostring(identity.citizenid or '')
    driver.name = DriverService.DisplayName(source)
    driver.online = true
    driver.activeRideId = nil
    driver.vehicleNetId = vehicle.netId
    driver.vehicleModelHash = vehicle.model
    driver.vehicleModel = Utils.Trim(payload and payload.modelName or tostring(vehicle.model), 80)
    driver.vehiclePlate = vehicle.plate
    driver.vehicleClass = vehicle.class
    driver.coords = coords
    driver.lastUpdate = os.time()
    driver.ratingSum = tonumber(profile.rating_sum) or 0
    driver.ratingCount = tonumber(profile.rating_count) or 0
    driver.ridesCompleted = tonumber(profile.rides_completed) or 0
    driver.totalEarned = tonumber(profile.total_earned) or 0
    DriverService.Runtime[source] = driver
    return driver
end

function DriverService.SetOffline(source, force)
    local driver = DriverService.Runtime[source]
    if not driver then return true end
    if driver.activeRideId and force ~= true then return false, 'driver_has_active_ride' end
    driver.online = false
    driver.lastUpdate = os.time()
    if force then driver.activeRideId = nil end
    return true
end

function DriverService.RefreshVehicle(source)
    local driver = DriverService.Runtime[source]
    if not driver or driver.online ~= true then return nil, 'driver_offline' end
    local vehicle, err = DriverService.ValidateVehicle(source, {
        vehicleNetId = driver.vehicleNetId,
        modelHash = driver.vehicleModelHash,
        vehicleClass = driver.vehicleClass
    })
    if not vehicle then return nil, err end
    if driver.vehicleNetId ~= vehicle.netId then return nil, 'driver_vehicle_changed' end
    driver.coords = Utils.NormalizeCoords(GetEntityCoords(GetPlayerPed(source)))
    driver.lastUpdate = os.time()
    return driver, vehicle
end

function DriverService.ListCandidates(origin, passengerSource)
    local candidates = {}
    for source, driver in pairs(DriverService.Runtime) do
        if source ~= passengerSource and driver.online and not driver.activeRideId and GetPlayerName(source) ~= nil then
            local valid = DriverService.RefreshVehicle(source)
            if valid then
                local distance = Utils.Distance(origin, driver.coords)
                if distance <= Config.Match.SearchRadius then
                    candidates[#candidates + 1] = { source = source, distance = distance }
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    while #candidates > Config.Match.MaxDrivers do table.remove(candidates) end
    return candidates
end

function DriverService.PublicProfile(driver)
    local count = tonumber(driver and driver.ratingCount) or 0
    return {
        name = driver and driver.name or 'Motorista',
        rating = count > 0 and (driver.ratingSum / count) or 5.0,
        rides = tonumber(driver and driver.ridesCompleted) or 0,
        vehicle = driver and driver.vehicleModel or '',
        plate = driver and driver.vehiclePlate or ''
    }
end
