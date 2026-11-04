MZTransport.RatingService = MZTransport.RatingService or {}
local RatingService = MZTransport.RatingService
local Repository = MZTransport.Repository
local DriverService = MZTransport.DriverService

function RatingService.Submit(source, rideId, value)
    local identity, identityErr = DriverService.GetIdentity(source)
    if not identity then return false, identityErr end
    value = tonumber(value)
    if not value or value % 1 ~= 0 or value < 1 or value > 5 then return false, 'invalid_rating' end
    local ride = Repository.FindCompletedRide(tonumber(rideId), tonumber(identity.characterId))
    if not ride then return false, 'ride_not_found' end
    if tostring(ride.driver_type) ~= 'player' or not tonumber(ride.driver_character_id) then
        return false, 'npc_cannot_be_rated'
    end
    local normalized = {
        id = tonumber(ride.id),
        passengerCharacterId = tonumber(ride.passenger_character_id),
        driverCharacterId = tonumber(ride.driver_character_id)
    }
    local ok, err = Repository.AddRating(normalized, value)
    if ok then
        for _, driver in pairs(DriverService.Runtime) do
            if tonumber(driver.characterId) == normalized.driverCharacterId then
                driver.ratingSum = (tonumber(driver.ratingSum) or 0) + value
                driver.ratingCount = (tonumber(driver.ratingCount) or 0) + 1
            end
        end
    end
    return ok, err
end
