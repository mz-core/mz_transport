MZTransport.RideService = MZTransport.RideService or {}
local RideService = MZTransport.RideService
local Utils = MZTransport.Utils
local States = MZTransport.States
local Repository = MZTransport.Repository
local PricingService = MZTransport.PricingService
local PaymentService = MZTransport.PaymentService
local DriverService = MZTransport.DriverService

RideService.Rides = RideService.Rides or {}
RideService.PassengerRides = RideService.PassengerRides or {}
RideService.AcceptLocks = RideService.AcceptLocks or {}
RideService.LastPassengerRequest = RideService.LastPassengerRequest or {}

local function log(action, ride, extra)
    local suffix = extra and (' ' .. tostring(extra)) or ''
    print(('[MZ_TRANSPORT] %s ride=%s%s'):format(action, tostring(ride and ride.id or 'none'), suffix))
end

function RideService.CanTransition(currentState, newState)
    return MZTransport.AllowedTransitions[currentState]
        and MZTransport.AllowedTransitions[currentState][newState] == true
end

function RideService.Transition(ride, newState, context)
    if not ride or not RideService.CanTransition(ride.status, newState) then
        log('invalid_transition', ride, ('from=%s to=%s'):format(tostring(ride and ride.status), tostring(newState)))
        return false, 'invalid_transition'
    end
    ride.status = newState
    ride.updatedAt = os.time()
    Repository.UpdateRideState(ride, context)
    return true
end

function RideService.GetPlayerCoords(source)
    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 or not DoesEntityExist(ped) then return nil, 'ped_not_found' end
    local coords = Utils.NormalizeCoords(GetEntityCoords(ped))
    return coords, coords and nil or 'invalid_coords'
end

function RideService.Estimate(source, destination)
    local origin, originErr = RideService.GetPlayerCoords(source)
    if not origin then return nil, originErr end
    local rawZ = type(destination) == 'table' and (destination.z or destination[3]) or nil
    destination = Utils.NormalizeCoords(destination)
    if not destination then return nil, 'invalid_destination' end
    -- z ausente nao vira 0: usa a altura da origem como fallback explicito.
    -- limitacao: pontes/tuneis/interiores ainda podem divergir.
    if rawZ == nil then destination.z = origin.z end
    local pricing, pricingErr = PricingService.Calculate(origin, destination)
    if not pricing then return nil, pricingErr end
    pricing.origin, pricing.destination = origin, destination
    return pricing
end

function RideService.Create(source, destination)
    if RideService.PassengerRides[source] then return nil, 'passenger_has_active_ride' end
    local driverRuntime = DriverService.Runtime[source]
    if driverRuntime and (driverRuntime.online or driverRuntime.activeRideId) then
        return nil, 'role_conflict'
    end
    local lastRequest = tonumber(RideService.LastPassengerRequest[source]) or 0
    if os.time() - lastRequest < Config.Cancellation.RequestCooldownSeconds then
        return nil, 'request_cooldown'
    end
    local identity, identityErr = DriverService.GetIdentity(source)
    if not identity then return nil, identityErr end
    local pricing, pricingErr = RideService.Estimate(source, destination)
    if not pricing then return nil, pricingErr end
    local affordable, balanceErr = PaymentService.CanAfford(source, pricing.fare)
    if not affordable then return nil, balanceErr end

    local ride = {
        passengerSource = source,
        passengerCharacterId = tonumber(identity.characterId),
        passengerCitizenId = tostring(identity.citizenid or ''),
        passengerName = DriverService.DisplayName(source),
        driverType = 'player',
        category = pricing.category,
        origin = pricing.origin,
        destination = pricing.destination,
        distanceMeters = pricing.distanceMeters,
        fare = pricing.fare,
        platformFee = pricing.platformFee,
        driverAmount = pricing.driverAmount,
        paymentStatus = 'pending',
        status = States.REQUESTED,
        requestedAt = os.time(),
        offeredDrivers = {}
    }
    ride.id = Repository.CreateRide(ride)
    if not ride.id then return nil, 'database_error' end
    RideService.Rides[ride.id] = ride
    RideService.PassengerRides[source] = ride.id
    RideService.LastPassengerRequest[source] = os.time()
    RideService.Transition(ride, States.SEARCHING_DRIVER)
    log('ride_created', ride)
    return ride
end

function RideService.Get(id)
    return RideService.Rides[tonumber(id)]
end

function RideService.GetPassengerRide(source)
    return RideService.Get(RideService.PassengerRides[source])
end

function RideService.GetDriverRide(source)
    local driver = DriverService.Runtime[source]
    return driver and RideService.Get(driver.activeRideId) or nil
end

function RideService.SanitizeForPassenger(ride)
    if not ride then return nil end
    local driver = ride.driverSource and DriverService.Runtime[ride.driverSource] or nil
    local driverCoords = driver and Utils.Copy(driver.coords) or Utils.Copy(ride.npcCoords)
    local pickupDistance = driverCoords and Utils.Distance(driverCoords, ride.origin) or nil
    if pickupDistance == math.huge then pickupDistance = nil end
    return {
        id = ride.id, status = ride.status, category = ride.category,
        origin = Utils.Copy(ride.origin), destination = Utils.Copy(ride.destination),
        distanceMeters = ride.distanceMeters, fare = ride.fare,
        platformFee = ride.platformFee, driverAmount = ride.driverAmount,
        driverType = ride.driverType,
        driver = driver and DriverService.PublicProfile(driver) or ride.npcProfile,
        driverCoords = driverCoords,
        pickupDistanceMeters = pickupDistance,
        paymentStatus = ride.paymentStatus,
        failureReason = ride.failureReason
    }
end

function RideService.SanitizeForDriver(ride)
    if not ride then return nil end
    local driver = ride.driverSource and DriverService.Runtime[ride.driverSource] or nil
    local driverCoords = driver and Utils.Copy(driver.coords) or nil
    local pickupDistance = driverCoords and Utils.Distance(driverCoords, ride.origin) or nil
    if pickupDistance == math.huge then pickupDistance = nil end
    return {
        id = ride.id, status = ride.status, passengerName = ride.passengerName,
        origin = Utils.Copy(ride.origin), destination = Utils.Copy(ride.destination),
        distanceMeters = ride.distanceMeters, fare = ride.fare,
        platformFee = ride.platformFee, driverAmount = ride.driverAmount,
        pickupDistanceMeters = pickupDistance,
        paymentStatus = ride.paymentStatus, failureReason = ride.failureReason
    }
end

function RideService.GetDriverOfferVersion(source)
    local driver = DriverService.Runtime[tonumber(source)]
    return tonumber(driver and driver.offerVersion) or 0
end

function RideService.NextDriverOfferVersion(source)
    local driver = DriverService.Runtime[tonumber(source)]
    if not driver then return 0 end
    driver.offerVersion = RideService.GetDriverOfferVersion(source) + 1
    return driver.offerVersion
end

function RideService.ClearPendingOffer(ride)
    if not ride then return end
    local offeredSource = tonumber(ride.offeredDriverSource)
    local offerToken = tonumber(ride.offerToken) or 0
    ride.offeredDriverSource = nil
    ride.offerExpiresAt = nil
    ride.offerPickupDistanceMeters = nil
    ride.offerDriverCharacterId = nil
    ride.offerToken = offerToken + 1
    if offeredSource then
        ride.offerVersion = RideService.NextDriverOfferVersion(offeredSource)
    end
    return offeredSource, offerToken, tonumber(ride.offerVersion) or 0
end

function RideService.SanitizePendingOffer(ride, source)
    if not ride or ride.status ~= States.SEARCHING_DRIVER then return nil end

    source = tonumber(source)
    if not source or tonumber(ride.offeredDriverSource) ~= source then return nil end

    local driver = DriverService.Runtime[source]
    if not driver or driver.online ~= true or driver.activeRideId then return nil end
    if ride.offerDriverCharacterId
        and tonumber(ride.offerDriverCharacterId) ~= tonumber(driver.characterId) then
        return nil
    end

    local now = os.time()
    local expiresAt = tonumber(ride.offerExpiresAt)
    if not expiresAt or expiresAt <= now then return nil end

    return {
        id = ride.id,
        status = ride.status,
        passengerName = ride.passengerName,
        pickupDistanceMeters = tonumber(ride.offerPickupDistanceMeters) or 0,
        distanceMeters = ride.distanceMeters,
        fare = ride.fare,
        platformFee = ride.platformFee,
        driverAmount = ride.driverAmount,
        origin = Utils.Copy(ride.origin),
        destination = Utils.Copy(ride.destination),
        expiresAt = expiresAt,
        token = tonumber(ride.offerToken) or 0,
        offerVersion = tonumber(ride.offerVersion) or RideService.GetDriverOfferVersion(source),
        serverNow = now
    }
end

function RideService.GetPendingOffer(source)
    source = tonumber(source)
    if not source then return nil end

    for _, ride in pairs(RideService.Rides) do
        local offer = RideService.SanitizePendingOffer(ride, source)
        if offer then return offer end
    end

    return nil
end

function RideService.NotifyPhone(source, title, message, notificationType)
    if not source or GetPlayerName(source) == nil then return end
    TriggerClientEvent('mz_phone:client:notify', source, {
        app = 'move', title = title, message = message, subtitle = message,
        type = notificationType or 'info'
    })
end

function RideService.PushSnapshot(ride)
    if not ride then return end
    if ride.passengerSource and GetPlayerName(ride.passengerSource) ~= nil then
        TriggerClientEvent('mz_transport:client:phonePayload', ride.passengerSource, {
            type = 'snapshot', role = 'passenger', ride = RideService.SanitizeForPassenger(ride)
        })
    end
    if ride.driverSource and GetPlayerName(ride.driverSource) ~= nil then
        TriggerClientEvent('mz_transport:client:phonePayload', ride.driverSource, {
            type = 'snapshot', role = 'driver', ride = RideService.SanitizeForDriver(ride)
        })
    end
end

function RideService.Release(ride)
    if not ride then return end
    RideService.PassengerRides[ride.passengerSource] = nil
    if ride.driverSource then
        local driver = DriverService.Runtime[ride.driverSource]
        if driver and driver.activeRideId == ride.id then driver.activeRideId = nil end
    end
    if MZTransport.TerminalStates[ride.status] then
        local rideId = ride.id
        SetTimeout((tonumber(Config.Runtime.TerminalRetentionSeconds) or 300) * 1000, function()
            if RideService.Rides[rideId] == ride and MZTransport.TerminalStates[ride.status] then
                RideService.Rides[rideId] = nil
                RideService.AcceptLocks[rideId] = nil
            end
        end)
    end
end

function RideService.Cancel(ride, actor, reason)
    if not ride or MZTransport.TerminalStates[ride.status] then return false, 'ride_not_active' end
    if (ride.status == States.IN_TRIP or ride.status == States.ARRIVED_DESTINATION)
        and actor ~= 'system' and Config.Cancellation.AllowDuringTrip ~= true then
        return false, 'cannot_cancel_in_trip'
    end
    local accepted = ride.driverSource ~= nil or ride.driverType == 'npc'
    local cancellationFee = accepted
        and Config.Cancellation.AfterAcceptFee
        or Config.Cancellation.BeforeAcceptFee
    if actor == 'passenger' and tonumber(cancellationFee) and tonumber(cancellationFee) > 0 then
        local paid, paymentReference = PaymentService.ChargeCancellation(ride, cancellationFee)
        if not paid then return false, paymentReference end
        ride.cancellationFee = math.floor(tonumber(cancellationFee))
        ride.paymentReference = paymentReference
        Repository.SetPayment(ride.id, 'cancellation_fee', paymentReference)
    end
    local ok, err = RideService.Transition(ride, States.CANCELLED, { reason = reason or actor })
    if not ok then return false, err end
    ride.failureReason = reason or actor
    local offeredSource, offerToken, offerVersion = RideService.ClearPendingOffer(ride)
    if offeredSource and GetPlayerName(offeredSource) ~= nil then
        TriggerClientEvent('mz_transport:client:phonePayload', offeredSource, {
            type = 'offer_expired', role = 'driver', rideId = ride.id,
            offerToken = offerToken, offerVersion = offerVersion,
            reason = reason or actor
        })
    end
    if ride.driverSource then
        RideService.NotifyPhone(ride.driverSource, 'Corrida cancelada', 'A corrida foi cancelada.', 'error')
    end
    if ride.npcPending or ride.npcVehicleNetId then
        TriggerClientEvent('mz_transport:client:npcCleanup', ride.passengerSource, ride.id)
    end
    RideService.PushSnapshot(ride)
    RideService.Release(ride)
    log('ride_cancelled', ride, ('actor=%s reason=%s'):format(tostring(actor), tostring(reason)))
    return true
end

function RideService.Complete(ride)
    if not ride or ride.status ~= States.ARRIVED_DESTINATION then return false, 'invalid_transition' end
    local paid, referenceOrErr = PaymentService.Settle(ride)
    if not paid then
        ride.paymentStatus = 'failed'
        ride.failureReason = referenceOrErr
        Repository.SetPayment(ride.id, 'failed', nil, referenceOrErr)
        RideService.Transition(ride, States.FAILED, { reason = referenceOrErr })
        RideService.NotifyPhone(ride.passengerSource, 'Falha no pagamento', 'Nao foi possivel concluir o pagamento.', 'error')
        if ride.driverSource then RideService.NotifyPhone(ride.driverSource, 'Falha no pagamento', 'A corrida nao foi paga.', 'error') end
        RideService.PushSnapshot(ride)
        RideService.Release(ride)
        log('payment_failed', ride, referenceOrErr)
        return false, referenceOrErr
    end

    ride.paymentStatus = 'paid'
    ride.paymentReference = referenceOrErr
    Repository.SetPayment(ride.id, 'paid', referenceOrErr)
    RideService.Transition(ride, States.COMPLETED)
    if ride.driverType == 'player' and ride.driverCharacterId then
        Repository.CompleteDriverRide(ride.driverCharacterId, ride.driverAmount)
    end
    RideService.NotifyPhone(ride.passengerSource, 'Viagem concluida', ('Pagamento de R$ %d confirmado.'):format(ride.fare), 'success')
    if ride.driverSource then
        RideService.NotifyPhone(ride.driverSource, 'Corrida concluida', ('Voce recebeu R$ %d.'):format(ride.driverAmount), 'success')
    end
    RideService.PushSnapshot(ride)
    RideService.Release(ride)
    log('payment_success', ride, referenceOrErr)
    log('trip_completed', ride)
    return true
end
