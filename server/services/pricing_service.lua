MZTransport.PricingService = MZTransport.PricingService or {}
local PricingService = MZTransport.PricingService
local Utils = MZTransport.Utils

function PricingService.Calculate(origin, destination)
    local distanceMeters = Utils.Distance(origin, destination)
    if distanceMeters == math.huge or distanceMeters <= 1.0 then
        return nil, 'invalid_destination'
    end

    local distanceKm = distanceMeters / 1000.0
    if distanceKm > Config.Pricing.MaximumDistanceKm then
        return nil, 'destination_too_far'
    end

    local calculated = Config.Pricing.BaseFare + (distanceKm * Config.Pricing.PricePerKm)
    local fare = math.max(Config.Pricing.MinimumFare, math.floor(calculated + 0.5))
    if fare <= 0 or fare > Config.Pricing.MaximumFare then return nil, 'invalid_fare' end

    local fee = math.floor((fare * Config.Pricing.PlatformFeePercent / 100.0) + 0.5)
    fee = math.max(0, math.min(fare, fee))

    return {
        category = Config.Pricing.Category,
        distanceMeters = distanceMeters,
        distanceKm = distanceKm,
        fare = fare,
        platformFee = fee,
        driverAmount = fare - fee
    }
end
