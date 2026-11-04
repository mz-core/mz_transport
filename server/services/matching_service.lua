MZTransport.MatchingService = MZTransport.MatchingService or {}
local MatchingService = MZTransport.MatchingService
local RideService = MZTransport.RideService
local DriverService = MZTransport.DriverService
local Repository = MZTransport.Repository
local Provider = MZTransport.PopulationProvider
local States = MZTransport.States

local function offerPayload(ride, candidate)
    return {
        id = ride.id,
        status = ride.status,
        passengerName = ride.passengerName,
        pickupDistanceMeters = tonumber(ride.offerPickupDistanceMeters) or candidate.distance,
        distanceMeters = ride.distanceMeters,
        fare = ride.fare,
        driverAmount = ride.driverAmount,
        platformFee = ride.platformFee,
        origin = ride.origin,
        destination = ride.destination,
        expiresAt = tonumber(ride.offerExpiresAt) or (os.time() + Config.Match.AcceptTimeout),
        token = tonumber(ride.offerToken) or 0,
        offerVersion = tonumber(ride.offerVersion) or 0,
        serverNow = os.time()
    }
end

local function scheduleRetry(ride)
    if not ride then return end
    ride.offerRetryToken = (tonumber(ride.offerRetryToken) or 0) + 1
    local token = ride.offerRetryToken
    SetTimeout(Config.Match.RetryDelay * 1000, function()
        if ride.offerRetryToken ~= token then return end
        if RideService.Rides[ride.id] == ride
            and ride.status == States.SEARCHING_DRIVER
            and not ride.offeredDriverSource then
            MatchingService.OfferNext(ride)
        end
    end)
end

function MatchingService.ScheduleNPC(ride)
    ride.matchToken = (ride.matchToken or 0) + 1
    local token = ride.matchToken
    SetTimeout(math.max(0, Config.NPCDriver.DelayBeforeOffer) * 1000, function()
        if not RideService.Rides[ride.id] or ride.status ~= States.SEARCHING_DRIVER
            or token ~= ride.matchToken or ride.offeredDriverSource then return end
        local freshCandidates = DriverService.ListCandidates(ride.origin, ride.passengerSource)
        local newCandidates = {}
        for _, candidate in ipairs(freshCandidates) do
            if not ride.offeredDrivers[candidate.source] then
                newCandidates[#newCandidates + 1] = candidate
            end
        end
        if #newCandidates > 0 then
            ride.matchCandidates = newCandidates
            ride.matchIndex = 0
            MatchingService.OfferNext(ride)
            return
        end
        Provider.CreateDriver(ride)
    end)
end

function MatchingService.OfferNext(ride)
    if not ride or ride.status ~= States.SEARCHING_DRIVER then return false end
    ride.offerRetryToken = (tonumber(ride.offerRetryToken) or 0) + 1
    ride.matchIndex = (ride.matchIndex or 0) + 1
    local candidate = ride.matchCandidates and ride.matchCandidates[ride.matchIndex] or nil
    local driver
    while candidate do
        driver = DriverService.Runtime[candidate.source]
        local valid = driver and driver.online and not driver.activeRideId and DriverService.RefreshVehicle(candidate.source)
        if valid and not ride.offeredDrivers[candidate.source] then break end
        ride.matchIndex = ride.matchIndex + 1
        candidate = ride.matchCandidates[ride.matchIndex]
    end

    if not candidate then
        RideService.ClearPendingOffer(ride)
        MatchingService.ScheduleNPC(ride)
        return false
    end

    ride.offeredDrivers[candidate.source] = true
    ride.offeredDriverSource = candidate.source
    ride.offerToken = (ride.offerToken or 0) + 1
    ride.offerExpiresAt = os.time() + Config.Match.AcceptTimeout
    ride.offerPickupDistanceMeters = candidate.distance
    ride.offerDriverCharacterId = driver and tonumber(driver.characterId) or nil
    ride.offerVersion = RideService.NextDriverOfferVersion(candidate.source)
    local token = ride.offerToken
    TriggerClientEvent('mz_transport:client:phonePayload', candidate.source, {
        type = 'offer', role = 'driver', offer = offerPayload(ride, candidate)
    })
    RideService.NotifyPhone(candidate.source, 'Nova corrida', 'Uma nova corrida esta disponivel.', 'info')
    print(('[MZ_TRANSPORT] ride_offered ride=%s driver=%s'):format(ride.id, candidate.source))

    SetTimeout(Config.Match.AcceptTimeout * 1000, function()
        if ride.status ~= States.SEARCHING_DRIVER or ride.offerToken ~= token
            or ride.offeredDriverSource ~= candidate.source then return end
        local _, _, offerVersion = RideService.ClearPendingOffer(ride)
        TriggerClientEvent('mz_transport:client:phonePayload', candidate.source, {
            type = 'offer_expired', role = 'driver', rideId = ride.id,
            offerToken = token, offerVersion = offerVersion, reason = 'expired'
        })
        scheduleRetry(ride)
    end)
    return true
end

function MatchingService.Start(ride)
    ride.matchCandidates = DriverService.ListCandidates(ride.origin, ride.passengerSource)
    ride.matchIndex = 0
    ride.matchToken = (ride.matchToken or 0) + 1
    return MatchingService.OfferNext(ride)
end

function MatchingService.Reject(source, rideId)
    local ride = RideService.Get(rideId)
    if not ride or ride.status ~= States.SEARCHING_DRIVER then return false, 'ride_not_searching' end
    if ride.offeredDriverSource ~= source then return false, 'offer_not_owned' end
    if ride.offerExpiresAt and tonumber(ride.offerExpiresAt) <= os.time() then
        RideService.ClearPendingOffer(ride)
        scheduleRetry(ride)
        return false, 'offer_not_owned'
    end
    RideService.ClearPendingOffer(ride)
    scheduleRetry(ride)
    return true
end

function MatchingService.Accept(source, rideId)
    local ride = RideService.Get(rideId)
    if not ride then return false, 'ride_not_found' end
    if RideService.AcceptLocks[ride.id] then return false, 'ride_accept_in_progress' end
    RideService.AcceptLocks[ride.id] = true

    local ok, result, err = xpcall(function()
        if ride.status ~= States.SEARCHING_DRIVER or ride.offeredDriverSource ~= source then
            return false, ride.driverSource and 'ride_already_assigned' or 'offer_not_owned'
        end
        if ride.offerExpiresAt and tonumber(ride.offerExpiresAt) <= os.time() then
            RideService.ClearPendingOffer(ride)
            scheduleRetry(ride)
            return false, 'offer_not_owned'
        end
        local driver, vehicleErr = DriverService.RefreshVehicle(source)
        if not driver then return false, vehicleErr end
        if ride.offerDriverCharacterId
            and tonumber(ride.offerDriverCharacterId) ~= tonumber(driver.characterId) then
            return false, 'offer_not_owned'
        end
        if driver.activeRideId then return false, 'driver_has_active_ride' end

        ride.driverSource = source
        ride.driverCharacterId = driver.characterId
        ride.driverCitizenId = driver.citizenid
        ride.driverName = driver.name
        ride.driverType = 'player'
        ride.vehicleModel = driver.vehicleModel
        ride.vehiclePlate = driver.vehiclePlate
        ride.vehicleNetId = driver.vehicleNetId
        local affected = Repository.AssignDriver(ride)
        if tonumber(affected) ~= 1 then return false, 'ride_already_assigned' end
        driver.activeRideId = ride.id
        RideService.ClearPendingOffer(ride)
        RideService.Transition(ride, States.DRIVER_ASSIGNED)
        RideService.Transition(ride, States.DRIVER_ENROUTE)
        RideService.NotifyPhone(ride.passengerSource, 'Motorista encontrado',
            ('%s esta a caminho.'):format(driver.name), 'success')
        RideService.PushSnapshot(ride)
        print(('[MZ_TRANSPORT] ride_accepted ride=%s driver=%s'):format(ride.id, source))
        return true
    end, debug.traceback)

    RideService.AcceptLocks[ride.id] = nil
    if not ok then
        print(('[MZ_TRANSPORT] accept_error ride=%s error=%s'):format(ride.id, tostring(result)))
        return false, 'internal_error'
    end
    return result, err
end

function MatchingService.ClearOffersForDriver(source, reason)
    source = tonumber(source)
    if not source then return end

    for _, ride in pairs(RideService.Rides) do
        if tonumber(ride.offeredDriverSource) == source then
            RideService.ClearPendingOffer(ride)
            scheduleRetry(ride)
            print(('[MZ_TRANSPORT] offer_cleared ride=%s driver=%s reason=%s')
                :format(tostring(ride.id), tostring(source), tostring(reason or 'driver_unavailable')))
        end
    end
end

function MatchingService.ReopenAfterDriverLoss(ride, reason)
    if not ride or MZTransport.TerminalStates[ride.status] then return false end
    if ride.status == States.IN_TRIP or ride.status == States.ARRIVED_DESTINATION then
        ride.failureReason = reason or 'driver_disconnected'
        RideService.Transition(ride, States.FAILED, { reason = ride.failureReason })
        RideService.NotifyPhone(ride.passengerSource, 'Corrida interrompida',
            'O motorista ficou indisponivel durante a viagem.', 'error')
        RideService.PushSnapshot(ride)
        RideService.Release(ride)
        return false
    end

    ride.driverSource, ride.driverCharacterId, ride.driverCitizenId = nil, nil, nil
    ride.driverName, ride.vehicleModel, ride.vehiclePlate, ride.vehicleNetId = nil, nil, nil, nil
    Repository.ClearDriver(ride.id)
    RideService.Transition(ride, States.SEARCHING_DRIVER, { reason = reason })
    RideService.NotifyPhone(ride.passengerSource, 'Buscando outro motorista', 'O motorista anterior ficou indisponivel.', 'error')
    RideService.PushSnapshot(ride)
    MatchingService.Start(ride)
    return true
end
