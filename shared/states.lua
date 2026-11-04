MZTransport = MZTransport or {}

MZTransport.States = {
    REQUESTED = 'requested',
    SEARCHING_DRIVER = 'searching_driver',
    DRIVER_ASSIGNED = 'driver_assigned',
    DRIVER_ENROUTE = 'driver_enroute',
    DRIVER_ARRIVED = 'driver_arrived',
    PASSENGER_BOARDING = 'passenger_boarding',
    IN_TRIP = 'in_trip',
    ARRIVED_DESTINATION = 'arrived_destination',
    COMPLETED = 'completed',
    CANCELLED = 'cancelled',
    FAILED = 'failed'
}

MZTransport.TerminalStates = {
    completed = true,
    cancelled = true,
    failed = true
}

MZTransport.AllowedTransitions = {
    requested = { searching_driver = true, cancelled = true, failed = true },
    searching_driver = { driver_assigned = true, cancelled = true, failed = true },
    driver_assigned = { driver_enroute = true, searching_driver = true, cancelled = true, failed = true },
    driver_enroute = { driver_arrived = true, searching_driver = true, cancelled = true, failed = true },
    driver_arrived = { passenger_boarding = true, searching_driver = true, cancelled = true, failed = true },
    passenger_boarding = { in_trip = true, searching_driver = true, cancelled = true, failed = true },
    in_trip = { arrived_destination = true, cancelled = true, failed = true },
    arrived_destination = { completed = true, cancelled = true, failed = true },
    completed = {},
    cancelled = {},
    failed = {}
}
