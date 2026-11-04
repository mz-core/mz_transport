fx_version 'cerulean'
game 'gta5'

lua54 'yes'

name 'mz_transport'
author 'Mazus'
description 'Backend compartilhado do MZ Move e MZ Move Parceiros'
version '1.0.0'

shared_scripts {
    'config.lua',
    'shared/states.lua',
    'shared/utils.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/repositories/repository.lua',
    'server/services/pricing_service.lua',
    'server/services/payment_service.lua',
    'server/services/driver_service.lua',
    'server/services/ride_service.lua',
    'server/services/rating_service.lua',
    'server/providers/population_standalone.lua',
    'server/services/matching_service.lua',
    'server/main.lua'
}

client_scripts {
    'client/services/gps.lua',
    'client/providers/population_standalone.lua',
    'client/main.lua'
}

files {
    'sql/001_mz_transport.sql'
}

dependencies {
    'oxmysql',
    'mz_core',
    'mz_economy',
    'mz_phone'
}
