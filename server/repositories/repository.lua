MZTransport.Repository = MZTransport.Repository or {}
local Repository = MZTransport.Repository

function Repository.Prepare()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS mz_transport_schema_migrations (
            version INT UNSIGNED NOT NULL PRIMARY KEY,
            name VARCHAR(96) NOT NULL,
            applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS mz_transport_drivers (
            character_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
            citizenid VARCHAR(64) NOT NULL,
            rating_sum INT UNSIGNED NOT NULL DEFAULT 0,
            rating_count INT UNSIGNED NOT NULL DEFAULT 0,
            rides_completed INT UNSIGNED NOT NULL DEFAULT 0,
            total_earned BIGINT UNSIGNED NOT NULL DEFAULT 0,
            created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY uq_mz_transport_drivers_citizenid (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS mz_transport_rides (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            passenger_character_id BIGINT UNSIGNED NOT NULL,
            passenger_citizenid VARCHAR(64) NOT NULL,
            passenger_name VARCHAR(120) NOT NULL,
            driver_character_id BIGINT UNSIGNED NULL,
            driver_citizenid VARCHAR(64) NULL,
            driver_name VARCHAR(120) NULL,
            driver_type VARCHAR(16) NOT NULL DEFAULT 'player',
            vehicle_model VARCHAR(80) NULL,
            vehicle_plate VARCHAR(16) NULL,
            category VARCHAR(24) NOT NULL DEFAULT 'economy',
            origin_x DOUBLE NOT NULL, origin_y DOUBLE NOT NULL, origin_z DOUBLE NOT NULL,
            destination_x DOUBLE NOT NULL, destination_y DOUBLE NOT NULL, destination_z DOUBLE NOT NULL,
            distance_meters DOUBLE NOT NULL,
            fare BIGINT UNSIGNED NOT NULL,
            platform_fee BIGINT UNSIGNED NOT NULL,
            driver_amount BIGINT UNSIGNED NOT NULL,
            status VARCHAR(32) NOT NULL,
            payment_status VARCHAR(24) NOT NULL DEFAULT 'pending',
            payment_reference VARCHAR(96) NULL,
            failure_reason VARCHAR(64) NULL,
            requested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            accepted_at TIMESTAMP NULL, started_at TIMESTAMP NULL,
            completed_at TIMESTAMP NULL, cancelled_at TIMESTAMP NULL,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            INDEX idx_mz_transport_rides_passenger (passenger_character_id, requested_at),
            INDEX idx_mz_transport_rides_driver (driver_character_id, requested_at),
            INDEX idx_mz_transport_rides_status (status, requested_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS mz_transport_ratings (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            ride_id BIGINT UNSIGNED NOT NULL,
            passenger_character_id BIGINT UNSIGNED NOT NULL,
            driver_character_id BIGINT UNSIGNED NOT NULL,
            rating TINYINT UNSIGNED NOT NULL,
            created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY uq_mz_transport_ratings_ride (ride_id),
            INDEX idx_mz_transport_ratings_driver (driver_character_id, created_at),
            CONSTRAINT fk_mz_transport_rating_ride FOREIGN KEY (ride_id)
                REFERENCES mz_transport_rides(id) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[INSERT IGNORE INTO mz_transport_schema_migrations (version, name) VALUES (1, 'initial_transport_schema')]])
end

function Repository.FailOrphanedRides()
    return MySQL.update.await([[
        UPDATE mz_transport_rides
        SET status = 'failed', failure_reason = 'resource_restart'
        WHERE status NOT IN ('completed', 'cancelled', 'failed')
    ]])
end

function Repository.CreateRide(ride)
    return MySQL.insert.await([[
        INSERT INTO mz_transport_rides (
            passenger_character_id, passenger_citizenid, passenger_name, driver_type,
            category, origin_x, origin_y, origin_z, destination_x, destination_y,
            destination_z, distance_meters, fare, platform_fee, driver_amount, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        ride.passengerCharacterId, ride.passengerCitizenId, ride.passengerName,
        ride.driverType, ride.category, ride.origin.x, ride.origin.y, ride.origin.z,
        ride.destination.x, ride.destination.y, ride.destination.z, ride.distanceMeters,
        ride.fare, ride.platformFee, ride.driverAmount, ride.status
    })
end

function Repository.UpdateRideState(ride, context)
    context = type(context) == 'table' and context or {}
    return MySQL.update.await([[
        UPDATE mz_transport_rides
        SET status = ?, failure_reason = COALESCE(?, failure_reason),
            accepted_at = CASE WHEN ? = 'driver_assigned' THEN CURRENT_TIMESTAMP ELSE accepted_at END,
            started_at = CASE WHEN ? = 'in_trip' THEN CURRENT_TIMESTAMP ELSE started_at END,
            completed_at = CASE WHEN ? = 'completed' THEN CURRENT_TIMESTAMP ELSE completed_at END,
            cancelled_at = CASE WHEN ? = 'cancelled' THEN CURRENT_TIMESTAMP ELSE cancelled_at END
        WHERE id = ?
    ]], { ride.status, context.reason, ride.status, ride.status, ride.status, ride.status, ride.id })
end

function Repository.AssignDriver(ride)
    return MySQL.update.await([[
        UPDATE mz_transport_rides
        SET driver_character_id = ?, driver_citizenid = ?, driver_name = ?, driver_type = ?,
            vehicle_model = ?, vehicle_plate = ?
        WHERE id = ? AND status = 'searching_driver'
    ]], {
        ride.driverCharacterId, ride.driverCitizenId, ride.driverName, ride.driverType,
        ride.vehicleModel, ride.vehiclePlate, ride.id
    })
end

function Repository.ClearDriver(rideId)
    return MySQL.update.await([[
        UPDATE mz_transport_rides SET driver_character_id = NULL, driver_citizenid = NULL,
            driver_name = NULL, driver_type = 'player', vehicle_model = NULL, vehicle_plate = NULL
        WHERE id = ?
    ]], { rideId })
end

function Repository.SetPayment(rideId, status, reference, failureReason)
    return MySQL.update.await([[
        UPDATE mz_transport_rides
        SET payment_status = ?, payment_reference = ?, failure_reason = COALESCE(?, failure_reason)
        WHERE id = ?
    ]], { status, reference, failureReason, rideId })
end

function Repository.EnsureDriver(identity)
    MySQL.query.await([[
        INSERT INTO mz_transport_drivers (character_id, citizenid)
        VALUES (?, ?)
        ON DUPLICATE KEY UPDATE citizenid = VALUES(citizenid)
    ]], { identity.characterId, identity.citizenid })
    return Repository.GetDriver(identity.characterId)
end

function Repository.GetDriver(characterId)
    return MySQL.single.await([[
        SELECT character_id, citizenid, rating_sum, rating_count, rides_completed, total_earned
        FROM mz_transport_drivers WHERE character_id = ? LIMIT 1
    ]], { characterId })
end

function Repository.GetDriverTodayStats(characterId)
    return MySQL.single.await([[
        SELECT COUNT(*) AS rides_today, COALESCE(SUM(driver_amount), 0) AS earnings_today
        FROM mz_transport_rides
        WHERE driver_character_id = ? AND status = 'completed'
          AND completed_at >= CURRENT_DATE
          AND completed_at < CURRENT_DATE + INTERVAL 1 DAY
    ]], { characterId }) or { rides_today = 0, earnings_today = 0 }
end

function Repository.CompleteDriverRide(characterId, amount)
    return MySQL.update.await([[
        UPDATE mz_transport_drivers
        SET rides_completed = rides_completed + 1, total_earned = total_earned + ?
        WHERE character_id = ?
    ]], { amount, characterId })
end

function Repository.AddRating(ride, rating)
    local inserted = MySQL.insert.await([[
        INSERT IGNORE INTO mz_transport_ratings
            (ride_id, passenger_character_id, driver_character_id, rating)
        VALUES (?, ?, ?, ?)
    ]], { ride.id, ride.passengerCharacterId, ride.driverCharacterId, rating })
    if not inserted or tonumber(inserted) == 0 then return false, 'rating_already_submitted' end
    MySQL.update.await([[
        UPDATE mz_transport_drivers
        SET rating_sum = rating_sum + ?, rating_count = rating_count + 1
        WHERE character_id = ?
    ]], { rating, ride.driverCharacterId })
    return true
end

function Repository.FindCompletedRide(rideId, passengerCharacterId)
    return MySQL.single.await([[
        SELECT id, passenger_character_id, driver_character_id, driver_type, status
        FROM mz_transport_rides
        WHERE id = ? AND passenger_character_id = ? AND status = 'completed'
        LIMIT 1
    ]], { rideId, passengerCharacterId })
end

function Repository.PassengerHistory(characterId, limit, offset)
    return MySQL.query.await([[
        SELECT r.id, r.status, r.driver_name, r.driver_type, r.vehicle_model, r.vehicle_plate,
            r.origin_x, r.origin_y, r.destination_x, r.destination_y, r.distance_meters,
            r.fare, r.requested_at, r.completed_at, rt.rating
        FROM mz_transport_rides r
        LEFT JOIN mz_transport_ratings rt ON rt.ride_id = r.id
        WHERE r.passenger_character_id = ?
        ORDER BY r.id DESC LIMIT ? OFFSET ?
    ]], { characterId, limit, offset }) or {}
end

function Repository.DriverHistory(characterId, limit, offset)
    return MySQL.query.await([[
        SELECT id, status, passenger_name, distance_meters, fare, platform_fee,
            driver_amount, requested_at, completed_at
        FROM mz_transport_rides
        WHERE driver_character_id = ?
        ORDER BY id DESC LIMIT ? OFFSET ?
    ]], { characterId, limit, offset }) or {}
end
