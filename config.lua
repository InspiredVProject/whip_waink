Config = {
    Enabled = true, PreviewWidth = 40, PreviewFps = 24, ScanRange = 25.0, ScanMs = 1000, AccessRange = 3.0, AccessMs = 4500,
    LockKitSeconds = 18, TrackerMs = 4000, SalePercent = 12, RegistrationPercent = 65, SaleCooldown = 120,
    AlarmChance = 45, TrackerChance = 35, AdvancedChance = 30, ItemConsume = false,
    Buyer = { enabled = true, coords = vector3(737.48,-1093.35,22.17), radius = 12.0, blip = true, name = 'Moses • Vehicle dealer', model = 's_m_y_dealer_01', heading = 82.04, zOffset = 0.0, useInteriorGate = false, speaker = 'Moses' },
    Blips = { Sprite = 225, Colour = 27, Scale = 0.72, ShortRange = true },
    Registrar = { enabled = false, coords = vector3(0,0,0), radius = 12.0, blip = true, name = 'Vehicle registration' },
    Prices = { low = 15000, medium = 35000, high = 95000, elite = 180000 },
    Items = { low = 'waink_slimjim', medium = 'waink_lockkit', high = 'waink_keycloner', elite = 'waink_procloner', tracker = 'waink_signaltool' },
    UnknownPopulation = true, SessionPopulation = true, ScriptedPopulation = false,
    AdditionalStreetModels = 'none', -- comma-separated admin-approved add-on spawn names
    Models = { blista = 'low', asea = 'low', emperor = 'low', primo = 'low', sultan = 'medium', tailgater2 = 'high', adder = 'elite', t20 = 'elite' },
    Protected = { 'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2', 'ambulance', 'firetruk', 'fbi', 'fbi2', 'riot' }
}
