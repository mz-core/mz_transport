MZTransport.PaymentService = MZTransport.PaymentService or {}
local PaymentService = MZTransport.PaymentService

local function economyCall(exportName, ...)
    if GetResourceState('mz_economy') ~= 'started' then return nil, 'economy_unavailable' end
    local args = table.pack(...)
    local ok, result, detail = pcall(function()
        if exportName == 'GetMoney' then
            return exports['mz_economy']:GetMoney(args[1])
        elseif exportName == 'TransferBankBetweenPlayers' then
            return exports['mz_economy']:TransferBankBetweenPlayers(args[1], args[2], args[3], args[4])
        elseif exportName == 'RemoveMoney' then
            return exports['mz_economy']:RemoveMoney(args[1], args[2], args[3], args[4])
        end
        error(('unsupported mz_economy export: %s'):format(tostring(exportName)))
    end)
    if not ok then return nil, 'core_export_failed' end
    return result, detail
end

function PaymentService.CanAfford(source, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, 'invalid_amount' end
    local money, err = economyCall('GetMoney', source)
    if type(money) ~= 'table' then return false, err or 'balance_unavailable' end
    if math.floor(tonumber(money.bank) or 0) < amount then return false, 'insufficient_funds' end
    return true
end

function PaymentService.Settle(ride)
    if ride.paymentStatus == 'paid' then
        return true, ride.paymentReference
    end

    local idempotencyKey = ('mz_transport_ride_%s_settle'):format(tostring(ride.id))
    local metadata = {
        idempotency_key = idempotencyKey,
        external_ref = ('mz-transport-ride-%s'):format(tostring(ride.id)),
        category = 'transport',
        reason = 'mz_transport_ride',
        recipient_reason = 'mz_transport_driver_income',
        fee = ride.driverType == 'player' and ride.platformFee or 0,
        counts_as_expense = true,
        data = {
            ride_id = ride.id,
            driver_type = ride.driverType,
            gross = ride.fare,
            platform_fee = ride.platformFee,
            net = ride.driverAmount
        }
    }

    if ride.driverType == 'player' then
        if not ride.driverSource or GetPlayerName(ride.driverSource) == nil then
            return false, 'driver_offline'
        end
        local result, err = economyCall(
            'TransferBankBetweenPlayers',
            ride.passengerSource,
            ride.driverSource,
            ride.driverAmount,
            metadata
        )
        if type(result) ~= 'table' or result.ok ~= true then
            return false, type(result) == 'table' and result.error or err or 'payment_failed'
        end
        return true, result.correlationId or result.transactionRef or metadata.external_ref
    end

    metadata.fee = nil
    metadata.reason = 'mz_transport_npc_ride'
    metadata.idempotency_key = idempotencyKey
    local paid, detail = economyCall('RemoveMoney', ride.passengerSource, 'bank', ride.fare, metadata)
    if paid ~= true then return false, detail or 'payment_failed' end
    return true, metadata.external_ref
end

function PaymentService.ChargeCancellation(ride, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end

    local metadata = {
        idempotency_key = ('mz_transport_ride_%s_cancel'):format(tostring(ride.id)),
        external_ref = ('mz-transport-ride-%s-cancel'):format(tostring(ride.id)),
        category = 'transport',
        reason = 'mz_transport_cancellation_fee',
        recipient_reason = 'mz_transport_driver_cancellation',
        fee = 0,
        counts_as_expense = true,
        data = { ride_id = ride.id, cancellation_fee = amount }
    }

    if ride.driverType == 'player' and ride.driverSource
        and GetPlayerName(ride.driverSource) ~= nil then
        local result, err = economyCall(
            'TransferBankBetweenPlayers',
            ride.passengerSource,
            ride.driverSource,
            amount,
            metadata
        )
        if type(result) ~= 'table' or result.ok ~= true then
            return false, type(result) == 'table' and result.error or err or 'cancellation_payment_failed'
        end
        return true, result.correlationId or result.transactionRef or metadata.external_ref
    end

    metadata.fee = nil
    local paid, detail = economyCall('RemoveMoney', ride.passengerSource, 'bank', amount, metadata)
    if paid ~= true then return false, detail or 'cancellation_payment_failed' end
    return true, metadata.external_ref
end
