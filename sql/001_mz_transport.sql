CREATE TABLE IF NOT EXISTS mz_transport_schema_migrations (
    version INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(96) NOT NULL,
    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
    origin_x DOUBLE NOT NULL,
    origin_y DOUBLE NOT NULL,
    origin_z DOUBLE NOT NULL,
    destination_x DOUBLE NOT NULL,
    destination_y DOUBLE NOT NULL,
    destination_z DOUBLE NOT NULL,
    distance_meters DOUBLE NOT NULL,
    fare BIGINT UNSIGNED NOT NULL,
    platform_fee BIGINT UNSIGNED NOT NULL,
    driver_amount BIGINT UNSIGNED NOT NULL,
    status VARCHAR(32) NOT NULL,
    payment_status VARCHAR(24) NOT NULL DEFAULT 'pending',
    payment_reference VARCHAR(96) NULL,
    failure_reason VARCHAR(64) NULL,
    requested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    accepted_at TIMESTAMP NULL,
    started_at TIMESTAMP NULL,
    completed_at TIMESTAMP NULL,
    cancelled_at TIMESTAMP NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_mz_transport_rides_passenger (passenger_character_id, requested_at),
    INDEX idx_mz_transport_rides_driver (driver_character_id, requested_at),
    INDEX idx_mz_transport_rides_status (status, requested_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO mz_transport_schema_migrations (version, name)
VALUES (1, 'initial_transport_schema');
