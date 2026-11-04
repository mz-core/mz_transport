Config = Config or {}

Config.Debug = false

Config.Driver = {
    RequireJob = false,
    AllowedJobs = { taxi = true }
}

Config.DriverVehicle = {
    AllowMotorcycles = false,
    AllowBicycles = false,
    AllowBoats = false,
    AllowAircraft = false,
    AllowedClasses = {
        [0] = true, [1] = true, [2] = true, [3] = true, [4] = true,
        [5] = true, [6] = true, [7] = true, [9] = true, [10] = true,
        [11] = true, [12] = true
    },
    BlockedClasses = {},
    AllowedModels = {},
    BlockedModels = {}
}

Config.Match = {
    SearchRadius = 5000.0,
    AcceptTimeout = 12,
    MaxDrivers = 5,
    RetryDelay = 1
}

Config.Pricing = {
    BaseFare = 25,
    PricePerKm = 8,
    PricePerMinute = 0,
    MinimumFare = 35,
    PlatformFeePercent = 10,
    MaximumFare = 100000,
    MaximumDistanceKm = 100.0,
    Category = 'economy'
}

Config.Ride = {
    DriverArrivalDistance = 20.0,
    BoardingDistance = 25.0,
    DestinationArrivalDistance = 25.0,
    TrackingIntervalMs = 1000,
    StaleDriverSeconds = 8,
    -- Rota de corrida com ownership/cleanup. false = comportamento legado
    -- (sobrescreve o waypoint a cada fase e nao restaura o waypoint pessoal).
    ManagedWaypoint = true
}

Config.Cancellation = {
    BeforeAcceptFee = 0,
    AfterAcceptFee = 0,
    AllowDuringTrip = false,
    RequestCooldownSeconds = 8
}

Config.NPCDriver = {
    Enabled = true,
    DelayBeforeOffer = 30,
    SpawnTimeoutSeconds = 20,
    MinSpawnDistance = 80.0,
    MaxSpawnDistance = 180.0,
    DrivingSpeed = 20.0,
    DrivingStyle = 786603,
    Models = {
        'a_m_m_business_01',
        'a_m_m_bevhills_01'
    },
    Vehicles = {
        'taxi',
        'asea',
        'premier'
    }
}

Config.History = {
    DefaultPageSize = 15,
    MaximumPageSize = 50
}

Config.Runtime = {
    TerminalRetentionSeconds = 300
}

Config.RateLimits = {
    bootstrap = { window = 3, max = 6 },
    estimate = { window = 5, max = 6 },
    requestRide = { window = 15, max = 3 },
    cancelRide = { window = 10, max = 4 },
    setDriverOnline = { window = 10, max = 5 },
    setDriverOffline = { window = 10, max = 5 },
    acceptOffer = { window = 10, max = 5 },
    rejectOffer = { window = 10, max = 8 },
    heartbeat = { window = 5, max = 8 },
    history = { window = 10, max = 5 },
    rate = { window = 30, max = 5 },
    npcReady = { window = 30, max = 3 },
    npcStatus = { window = 10, max = 15 }
}
