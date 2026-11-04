local Utils = MZTransport.Utils
local States = MZTransport.States
local Repository = MZTransport.Repository
local DriverService = MZTransport.DriverService
local RideService = MZTransport.RideService
local MatchingService = MZTransport.MatchingService
local RatingService = MZTransport.RatingService
local Provider = MZTransport.PopulationProvider

MZTransport.Ready = false

local RateWindows = {}
local SecurityErrors = {
    rate_limited = true, unknown_action = true, role_conflict = true,
    ride_not_owned = true, ride_not_owned_by_driver = true,
    offer_not_owned = true, ride_accept_in_progress = true,
    npc_request_invalid = true, npc_ride_invalid = true,
    npc_status_invalid = true, passenger_not_in_vehicle = true,
    ride_vehicle_mismatch = true
}

local function rateAllowed(source, action)
    local policy = Config.RateLimits[action]
    if not policy then return false end
    local now = os.time()
    local key = ('%s:%s'):format(source, action)
    local bucket = RateWindows[key]
    if not bucket or now - bucket.startedAt >= policy.window then
        bucket = { startedAt = now, count = 0 }
        RateWindows[key] = bucket
    end
    bucket.count = bucket.count + 1
    return bucket.count <= policy.max
end

local function response(source, action, ok, errorCode, data, requestId)
    if ok ~= true and SecurityErrors[errorCode] then
        print(('[MZ_TRANSPORT] security_rejection source=%s action=%s reason=%s')
            :format(tostring(source), tostring(action), tostring(errorCode)))
    end
    requestId = type(requestId) == 'string' and requestId ~= '' and requestId or nil
    TriggerClientEvent('mz_transport:client:phonePayload', source, {
        type = 'response', action = action, ok = ok == true,
        error = errorCode, data = data, requestId = requestId
    })
end

local function driverState(source)
    local driver = DriverService.Runtime[source]
    local identity = DriverService.GetIdentity(source)
    local profile = identity and Repository.GetDriver(identity.characterId) or nil
    local today = identity and Repository.GetDriverTodayStats(identity.characterId) or nil
    local ratingCount = tonumber(profile and profile.rating_count) or tonumber(driver and driver.ratingCount) or 0
    local ratingSum = tonumber(profile and profile.rating_sum) or tonumber(driver and driver.ratingSum) or 0
    return {
        online = driver and driver.online == true or false,
        ride = RideService.SanitizeForDriver(RideService.GetDriverRide(source)),
        offer = RideService.GetPendingOffer(source),
        offerVersion = RideService.GetDriverOfferVersion(source),
        serverNow = os.time(),
        stats = {
            rating = ratingCount > 0 and ratingSum / ratingCount or 5.0,
            rides = tonumber(today and today.rides_today) or 0,
            totalEarned = tonumber(today and today.earnings_today) or 0
        }
    }
end

local function history(source, payload)
    local identity, err = DriverService.GetIdentity(source)
    if not identity then return nil, err end
    local page = Utils.ClampInteger(payload.page, 1, 100000, 1)
    local limit = Utils.ClampInteger(payload.limit, 1, Config.History.MaximumPageSize, Config.History.DefaultPageSize)
    local offset = (page - 1) * limit
    local role = payload.role == 'driver' and 'driver' or 'passenger'
    local rows = role == 'driver'
        and Repository.DriverHistory(identity.characterId, limit + 1, offset)
        or Repository.PassengerHistory(identity.characterId, limit + 1, offset)
    local hasNext = #rows > limit
    if hasNext then table.remove(rows) end
    return { role = role, page = page, limit = limit, hasNext = hasNext, items = rows }
end

local function heartbeat(source, payload)
    local ride = RideService.GetDriverRide(source)
    if not ride or tonumber(payload.rideId) ~= tonumber(ride.id) then return false, 'ride_not_owned' end
    local driver, vehicle = DriverService.RefreshVehicle(source)
    if not driver then return false, vehicle end
    if ride.vehicleNetId ~= driver.vehicleNetId then return false, 'ride_vehicle_mismatch' end

    if ride.status == States.DRIVER_ENROUTE
        and Utils.Distance(driver.coords, ride.origin) <= Config.Ride.DriverArrivalDistance then
        RideService.Transition(ride, States.DRIVER_ARRIVED)
        RideService.Transition(ride, States.PASSENGER_BOARDING)
        RideService.NotifyPhone(ride.passengerSource, 'Seu motorista chegou', 'Entre no veiculo para iniciar.', 'success')
        print(('[MZ_TRANSPORT] driver_arrived ride=%s'):format(ride.id))
    end

    if ride.status == States.PASSENGER_BOARDING then
        local passengerPed = GetPlayerPed(ride.passengerSource)
        local driverPed = GetPlayerPed(source)
        local actualVehicle = GetVehiclePedIsIn(driverPed, false)
        if actualVehicle > 0 and GetVehiclePedIsIn(passengerPed, false) == actualVehicle
            and Utils.Distance(GetEntityCoords(passengerPed), driver.coords) <= Config.Ride.BoardingDistance then
            RideService.Transition(ride, States.IN_TRIP)
            print(('[MZ_TRANSPORT] trip_started ride=%s type=player'):format(ride.id))
        end
    end

    if ride.status == States.IN_TRIP
        and Utils.Distance(driver.coords, ride.destination) <= Config.Ride.DestinationArrivalDistance then
        RideService.Transition(ride, States.ARRIVED_DESTINATION)
        RideService.Complete(ride)
        return true
    end
    RideService.PushSnapshot(ride)
    return true
end

RegisterNetEvent('mz_transport:server:request', function(action, payload, requestId)
    local source = source
    action = Utils.Trim(action, 40)
    payload = type(payload) == 'table' and payload or {}
    requestId = type(requestId) == 'string' and requestId:gsub('[^%w_%-:]', ''):sub(1, 80) or nil
    if requestId == '' then requestId = nil end

    local function respond(ok, errorCode, data)
        response(source, action, ok, errorCode, data, requestId)
    end

    if MZTransport.Ready ~= true then
        respond( false, 'service_not_ready')
        return
    end
    if not rateAllowed(source, action) then
        respond( false, 'rate_limited')
        return
    end

    if action == 'bootstrap' then
        local role = payload.role == 'driver' and 'driver' or 'passenger'
        local data = role == 'driver'
            and driverState(source)
            or { ride = RideService.SanitizeForPassenger(RideService.GetPassengerRide(source)) }
        respond( true, nil, { role = role, state = data })
    elseif action == 'estimate' then
        local estimate, err = RideService.Estimate(source, payload.destination)
        respond( estimate ~= nil, err, estimate)
    elseif action == 'requestRide' then
        local ride, err = RideService.Create(source, payload.destination)
        if ride then
            RideService.PushSnapshot(ride)
            MatchingService.Start(ride)
        end
        respond( ride ~= nil, err, RideService.SanitizeForPassenger(ride))
    elseif action == 'cancelRide' then
        local ride = RideService.GetPassengerRide(source)
        if not ride or tonumber(payload.rideId) ~= tonumber(ride.id) then
            respond( false, 'ride_not_owned')
        else
            local ok, err = RideService.Cancel(ride, 'passenger', 'passenger_cancelled')
            respond( ok, err)
        end
    elseif action == 'setDriverOnline' then
        if RideService.GetPassengerRide(source) then
            respond( false, 'role_conflict')
        else
            local driver, err = DriverService.SetOnline(source, payload)
            respond( driver ~= nil, err, driver and driverState(source) or nil)
        end
    elseif action == 'setDriverOffline' then
        local ok, err = DriverService.SetOffline(source, false)
        if ok then MatchingService.ClearOffersForDriver(source, 'driver_offline') end
        respond( ok, err, ok and driverState(source) or nil)
    elseif action == 'acceptOffer' then
        local ok, err = MatchingService.Accept(source, payload.rideId)
        respond( ok, err, ok and driverState(source) or nil)
    elseif action == 'rejectOffer' then
        local ok, err = MatchingService.Reject(source, payload.rideId)
        respond( ok, err, ok and driverState(source) or nil)
    elseif action == 'heartbeat' then
        local ok, err = heartbeat(source, payload)
        if not ok and SecurityErrors[err] then
            print(('[MZ_TRANSPORT] security_rejection source=%s action=%s reason=%s')
                :format(tostring(source), action, tostring(err)))
        end
        if not ok and Config.Debug then respond( false, err) end
    elseif action == 'history' then
        local data, err = history(source, payload)
        respond( data ~= nil, err, data)
    elseif action == 'rate' then
        local ok, err = RatingService.Submit(source, payload.rideId, payload.rating)
        respond( ok, err)
    elseif action == 'npcReady' then
        local ok, err = Provider.Ready(source, payload)
        respond( ok, err)
    elseif action == 'npcStatus' then
        local ok, err = Provider.Status(source, payload)
        if not ok and SecurityErrors[err] then
            print(('[MZ_TRANSPORT] security_rejection source=%s action=%s reason=%s')
                :format(tostring(source), action, tostring(err)))
        end
        if not ok and Config.Debug then respond( false, err) end
    else
        respond( false, 'unknown_action')
    end
end)

local function cleanupSource(src, reason)
    src = tonumber(src)
    if not src then return end

    local passengerRide = RideService.GetPassengerRide(src)
    if passengerRide then
        Provider.Cleanup(passengerRide)
        RideService.Cancel(passengerRide, 'system', reason or 'passenger_disconnected')
    end

    local driverRide = RideService.GetDriverRide(src)
    DriverService.SetOffline(src, true)
    if driverRide then
        MatchingService.ReopenAfterDriverLoss(driverRide, reason or 'driver_disconnected')
    end

    MatchingService.ClearOffersForDriver(src, reason or 'driver_dropped')
    DriverService.Runtime[src] = nil
    RideService.LastPassengerRequest[src] = nil
    for key in pairs(RateWindows) do
        if key:find(('^%s:'):format(src)) then RateWindows[key] = nil end
    end
end

AddEventHandler('playerDropped', function()
    cleanupSource(source, 'player_disconnected')
end)

-- Troca de personagem / reuso de source: mz_core fecha a sessao e os consumidores
-- com estado por source precisam limpar antes de a source ser reutilizada.
AddEventHandler('mz_core:server:identitySessionClosed', function(source, _sessionId, reason)
    cleanupSource(source, reason == 'source_reused' and 'session_source_reused' or 'identity_session_closed')
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    local ok, err = pcall(function()
        Repository.Prepare()
        Repository.FailOrphanedRides()
    end)
    if not ok then
        print(('[MZ_TRANSPORT] database_prepare_failed error=%s'):format(tostring(err)))
    else
        MZTransport.Ready = true
        print('[MZ_TRANSPORT] ready')
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for _, ride in pairs(RideService.Rides) do Provider.Cleanup(ride) end
    for source in pairs(DriverService.Runtime) do DriverService.SetOffline(source, true) end
    RideService.Rides = {}
    RideService.PassengerRides = {}
    RideService.AcceptLocks = {}
    DriverService.Runtime = {}
end)

CreateThread(function()
    while true do
        Wait(3000)
        if MZTransport.Ready then
            local now = os.time()
            for source, driver in pairs(DriverService.Runtime) do
                if driver.online and driver.activeRideId
                    and now - (tonumber(driver.lastUpdate) or 0) > Config.Ride.StaleDriverSeconds then
                    local ride = RideService.Get(driver.activeRideId)
                    DriverService.SetOffline(source, true)
                    if ride and not MZTransport.TerminalStates[ride.status] then
                        MatchingService.ReopenAfterDriverLoss(ride, 'driver_heartbeat_timeout')
                    end
                end
            end
        end
    end
end)
