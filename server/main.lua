local QBCore = exports['qb-core']:GetCoreObject()

local ControlledZones = {}
local PlayerZones = {} --tracks which zones players are in on server side
local Cooldowns = {}
local Wars = {}

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    TriggerEvent('sayer-gangs:InitialiseZones')
end)

AddEventHandler('onResourceStop', function(t) if t ~= GetCurrentResourceName() then return end
    
end)

RegisterNetEvent('sayer-gangs:ZoneUpdate', function(zone, action)
    local src = source
    if not Config.Zones[zone] then 
        DebugCode("No Zone") 
        return 
    end
    
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then 
        DebugCode("No Player") 
        return 
    end
    
    local citizenid = Player.PlayerData.citizenid

    if action == "enter" then
        PlayerZones[citizenid] = PlayerZones[citizenid] or {}
        PlayerZones[citizenid].zone = zone
        PlayerZones[citizenid].timer = 0
        DebugCode("Zone [" .. zone .. "] Stored For: " .. citizenid)
    elseif action == "exit" then
        PlayerZones[citizenid] = PlayerZones[citizenid] or {}
        if PlayerZones[citizenid].zone ~= nil then
            if PlayerZones[citizenid].zone == zone then
                PlayerZones[citizenid] = nil
                DebugCode("Zone [" .. zone .. "] Removed For: " .. citizenid)
            end
        end
    else
        DebugCode("Invalid Action: " .. action)
    end
end)

RegisterNetEvent('sayer-gangs:InitialiseZones', function()
    MySQL.query('SELECT id FROM sayer_zones', {}, function(existingZones)
        -- Convert the existing zones into a lookup table for faster checks
        local existingZoneIds = {}
        for _, zone in ipairs(existingZones) do
            existingZoneIds[zone.id] = true
        end

        -- Loop through Config.Zones and add missing zones
        for zoneName, _ in pairs(Config.Zones) do
            if not existingZoneIds[zoneName] then
                MySQL.insert('INSERT INTO sayer_zones (id, owner, rep) VALUES (?, ?, ?)', {
                    zoneName,
                    'none',
                    0,
                })
            end
        end
    end)
end)

QBCore.Functions.CreateCallback('sayer-gangs:GetAllZonesInfo', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    MySQL.query('SELECT * FROM sayer_zones', {}, function(Zones)
        local FormattedZonesInfo = {}
        for _, zone in ipairs(Zones) do
            FormattedZonesInfo[zone.id] = {
                rep = zone.rep,
                owner = zone.owner,
            }
        end
        cb(FormattedZonesInfo)
    end)
end)

RegisterNetEvent('sayer-gangs:testAddRep',function()
    local activity = 'drugselling'
    local src = source
    AddZoneRep(src, activity,false)
end)

RegisterNetEvent('sayer-gangs:AddZoneRep',function(src,activity, isInternal)
    AddZoneRep(src,activity,isInternal)
end)

function AddZoneRep(src, activity, isInternal)
    local Player
    local citizenid
    local playerTable

    -- Check if the call is internal or external
    if isInternal then
        citizenid = src -- `src` will be the citizen ID in this case
        playerTable = PlayerZones[citizenid]
        Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    else
        Player = QBCore.Functions.GetPlayer(src)
        if not Player then return end

        citizenid = Player.PlayerData.citizenid
        playerTable = PlayerZones[citizenid]
    end

    local zone = playerTable and playerTable.zone
    if not zone then
        DebugCode("No Valid Zone")
        return
    end

    Config.Zones[zone].lastRepUpdate = os.time()

    local zoneConfig = Config.Zones[zone]
    local activityConfig = zoneConfig and zoneConfig.activities[activity]

    if not zoneConfig or not activityConfig then return end

    local activityCooldown = GetCooldownState(citizenid, zone, activity)
    if activityCooldown then
        return
    end

    local SourceGang

    SourceGang = Player.PlayerData.gang.name

    if not Config.Gangs[SourceGang] then return end

    local RepToGive = activityConfig.RepAmount
    if Config.RepBooster[activity] and type(Config.RepBooster[activity]) == 'number' then
        RepToGive = RepToGive * Config.RepBooster[activity]
    end

    if Wars[zone] ~= nil then
        AddZoneWarPoints(SourceGang,zone,RepToGive)
    else
        if activityConfig.WarOnly then
            return 
        end

        MySQL.rawExecute('SELECT * FROM sayer_zones WHERE id = ?', { zone }, function(result)
            if result and result[1] then
                local currentRep = result[1].rep
                local ownedGang = result[1].owner

                local newRep, takeover = AdjustZoneRep(currentRep, RepToGive, SourceGang, ownedGang)
                if takeover then
                    if Config.Wars.Enable then
                        if (Wars ~= nil and #Wars < Config.Wars.MaxWars) or Wars == nil then
                            TriggerWar(zone, SourceGang, RepToGive)
                        end
                    else
                        TakeOverZone(zone, SourceGang, RepToGive)
                    end
                else
                    UpdateZoneRepCount(zone, newRep)
                end

                -- Start cooldown after success
                StartCooldown(citizenid, zone, activity)
            else
                DebugCode("Error: Could not fetch zone data for ID: " .. tostring(zone))
            end
        end)
    end
end

exports('AddZoneRep', AddZoneRep)

-- Helper Function for Adjusting Reputation
function AdjustZoneRep(currentRep, repToGive, sourceGang, ownedGang)
    if sourceGang == ownedGang then
        currentRep = math.min(currentRep + repToGive, Config.MaxRepInZones)
    else
        currentRep = currentRep - repToGive
        if currentRep <= 0 then
            currentRep = 0
            return currentRep, true -- Zone will be taken over
        end
    end
    return currentRep, false -- No takeover
end

function UpdateZoneRepCount(zone, amount)
    MySQL.update('UPDATE sayer_zones SET rep = ? WHERE id = ?', { amount, zone }, function(affectedRows)
        if affectedRows > 0 then
            DebugCode(string.format("Zone '%s' reputation updated to %d", zone, amount))
        else
            DebugCode(string.format("Failed to update reputation for zone '%s'", zone))
        end
    end)
end

function TakeOverZone(zone, gang, points)
    DebugCode(string.format("Attempting to take over zone '%s' by gang '%s'", zone, gang))

    if not Config.Gangs[gang] then
        DebugCode(string.format("Gang '%s' is not valid", gang))
        return
    end

    if not Config.Zones[zone] then
        DebugCode(string.format("Zone '%s' is not valid", zone))
        return
    end

    MySQL.update('UPDATE sayer_zones SET owner = ?, rep = ? WHERE id = ?', { gang, points, zone }, function(affectedRows)
        if affectedRows > 0 then
            -- Notify all clients about the zone change
            TriggerClientEvent('sayer-gangs:UpdateZoneBlip', -1, zone, gang, false)
            DebugCode(string.format("Zone '%s' successfully taken over by gang '%s'", zone, gang))
        else
            DebugCode(string.format("Failed to take over zone '%s'", zone))
        end
    end)
end

function TriggerWar(zone, gang, points)
    if not Config.Gangs[gang] then return end
    if not Config.Zones[zone] then return end

    local startTime = os.time()
    local editTime = Config.Wars.WarsLength * 60 -- Convert minutes to seconds
    local endTime = startTime + editTime
    Wars[zone] = {active = true, startTime = startTime, endTime = endTime, gangs = {}}
    Wars[zone].gangs[gang] = points
    TriggerClientEvent('sayer-gangs:UpdateZoneBlip', -1, zone, gang, true)
    TriggerClientEvent('sayer-gangs:NotifyWarStarted', -1, zone)
    DebugCode("zone war started")
end


function AddZoneWarPoints(gang,zone,points)
    DebugCode("reached war points")
    if not Config.Gangs[gang] then return end
    if not Config.Zones[zone] then return end
    if not Wars[zone] then return end
    DebugCode("all things correct, adding")
    if Wars[zone].gangs[gang] then
        local currentPoints = Wars[zone].gangs[gang]
        local newPoints = currentPoints + points
        Wars[zone].gangs[gang] = newPoints
        DebugCode("Points Added for zone war, total: "..newPoints)
    else
        Wars[zone].gangs[gang] = points
        DebugCode("first entry points for zone war")
    end
end

function EndZoneWar(zone, gangs)
    if not Wars[zone] then return end

    local highestPoints = 0
    local controllingGang = nil
    local newGang = 'none'

    for gang, points in pairs(Wars[zone].gangs) do
        if points > highestPoints then
            highestPoints = points
            controllingGang = gang
        end
    end

    -- controllingGang will now hold the gang with the highest points
    if controllingGang then
        DebugCode(("Gang %s controls zone %s with %d points"):format(controllingGang, zone, highestPoints))
        -- Perform additional actions, such as rewarding the gang or updating the zone owner
        newGang = controllingGang
    else
        DebugCode(("No controlling gang for zone %s"):format(zone))
    end

    -- Reset the war for this zone
    Wars[zone] = nil
    TriggerClientEvent('sayer-gangs:UpdateZoneBlip', -1, zone, newGang, false)
    TriggerClientEvent('sayer-gangs:NotifyWarFinished', -1, newGang, zone)
    TakeOverZone(zone, newGang, highestPoints)
end

CreateThread(function()
    while true do
        Wait(1000)
        if Wars ~= nil then
            local currentTime = os.time()
            for k,v in pairs(Wars) do
                if v.endTime ~= nil then
                    if currentTime > v.endTime then
                        EndZoneWar(k)
                    end
                end
            end
        end
    end
end)


function StartCooldown(citizenid, zone, activity)
    local cooldownTime = os.time() -- Save the current time
    Cooldowns[citizenid] = Cooldowns[citizenid] or {}
    Cooldowns[citizenid][zone] = Cooldowns[citizenid][zone] or {}
    Cooldowns[citizenid][zone][activity] = cooldownTime -- Save the cooldown start time
end

function GetCooldownState(citizenid, zone, activity)
    local currentTime = os.time()
    local CooldownTimer = Config.Zones[zone].activities[activity].Cooldown
    if not CooldownTimer or CooldownTimer < 1 then return false end

    local cooldownStart = Cooldowns[citizenid] 
        and Cooldowns[citizenid][zone] 
        and Cooldowns[citizenid][zone][activity]

        DebugCode("Cooldown Start:", cooldownStart, "Current Time:", currentTime, "Timer:", CooldownTimer)

    if cooldownStart and currentTime < cooldownStart + (CooldownTimer*60) then
        local timeLeft = cooldownStart + (CooldownTimer*60) - currentTime
        DebugCode("Cooldown Active, Time Left:", timeLeft)
        return timeLeft
    end

    return false
end

-- hang around system

CreateThread(function()
    while true do
        Wait(1000) -- Check every second
        if PlayerZones ~= nil then
            for citizenid, zoneData in pairs(PlayerZones) do
                local zoneConfig = Config.Zones[zoneData.zone]
                if zoneConfig then
                    local zoneActivity = zoneConfig.activities and zoneConfig.activities['hangaround']
                    if zoneActivity ~= nil then
                        -- Time needed in the zone before adding reputation
                        local timeNeededInZone = Config.HangAroundTimeNeededInZone * 60 * 1000 -- Convert to milliseconds

                        -- Increment the timer for the citizen
                        zoneData.timer = (zoneData.timer or 0) + 1000

                        -- Check if the timer has exceeded the required time
                        if zoneData.timer >= timeNeededInZone then
                            local activityCooldown = GetCooldownState(citizenid, zoneData.zone, 'hangaround')

                            if not activityCooldown then
                                DebugCode("Not In Cooldown and Adding HangAround Rep")
                                -- Add reputation to the zone for the citizen
                                AddZoneRep(citizenid, 'hangaround', true)

                                -- Reset the timer after successfully adding reputation
                                zoneData.timer = 0
                                TriggerClientEvent('sayer-gangs:TirggerUpdateFromServer', -1)
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- zone rep decay 


-- Server-Side Thread for Decay
CreateThread(function()
    while true do
        Wait(1000) -- Check every second

        -- Skip decay logic if disabled
        if not Config.EnableDecay then
            goto continue
        end

        -- Loop through zones to handle decay
        MySQL.query('SELECT id, owner, rep FROM sayer_zones', {}, function(zones)
            for _, zone in ipairs(zones) do
                local zoneId = zone.id
                local zoneOwner = zone.owner
                local zoneRep = zone.rep

                local zoneConfig = Config.Zones[zoneId]

                -- Decay logic only applies to zones with an owner and decay settings
                if zoneOwner ~= "none" and zoneConfig and zoneConfig.decay then
                    local decayTime = zoneConfig.decay.time * 60 -- Convert minutes to seconds
                    local decayAmount = zoneConfig.decay.amount

                    -- Check if the zone should decay
                    if not ControlledZones[zoneId] then
                        ControlledZones[zoneId] = { lastUpdate = os.time() }
                    end

                    local lastUpdate = ControlledZones[zoneId].lastUpdate
                    if os.time() - lastUpdate >= decayTime then
                        local newRep = math.max(zoneRep - decayAmount, 0) -- Prevent rep from going below 0

                        -- Update the database
                        UpdateZoneRepCount(zoneId, newRep)

                        -- Reset owner if rep is 0
                        if newRep == 0 then
                            MySQL.update('UPDATE sayer_zones SET owner = ? WHERE id = ?', { 'none', zoneId }, function()
                                TriggerClientEvent('sayer-gangs:UpdateZoneBlip', -1, zoneId, 'none', false)
                                TriggerClientEvent('sayer-gangs:NotifyLostZone',-1,zoneOwner, zoneId)
                                DebugCode(string.format("Zone '%s' has reset to no owner due to decay.", zoneId))
                            end)
                        end

                        -- Update last decay time
                        ControlledZones[zoneId].lastUpdate = os.time()
                    end
                end
            end
        end)

        ::continue::
    end
end)


-- EXPORTS

function GetZoneDetails(zone)
    local retval = nil
    if not Config.Zones[zone] then return end
    MySQL.rawExecute('SELECT * FROM sayer_zones WHERE id = ?', { zone }, function(result)
        if result and result[1] then
            retval = {
                rep = result[1].rep,
                owner = result[1].owner,
            }
        else
            retval = nil
        end
    end)
    return retval
end

exports('GetZoneDetails',GetZoneDetails)

function GetZoneOwner(zone)
    local retval = nil
    if not Config.Zones[zone] then return end
    MySQL.rawExecute('SELECT * FROM sayer_zones WHERE id = ?', { zone }, function(result)
        if result and result[1] then
            retval = result[1].owner
        else
            retval = nil
        end
    end)
    return retval
end

exports('GetZoneOwner',GetZoneOwner)

function GetZoneRep(zone)
    local retval = nil
    if not Config.Zones[zone] then return end
    MySQL.rawExecute('SELECT * FROM sayer_zones WHERE id = ?', { zone }, function(result)
        if result and result[1] then
            retval = result[1].rep
        else
            retval = nil
        end
    end)
    return retval
end

exports('GetZoneRep',GetZoneRep)

function IsZoneOwned(zone)
    local retval = false
    if not Config.Zones[zone] then return end
    MySQL.rawExecute('SELECT * FROM sayer_zones WHERE id = ?', { zone }, function(result)
        if result and result[1] then
            local owner = result[1].owner
            if owner ~= 'none' then
                retval = true
            else
                retval = false
            end
        else
            retval = nil
        end
    end)
    return retval
end

exports('IsZoneOwned',IsZoneOwned)

function GetPlayerCountForZone(zone)
    if not Config.Zones[zone] then return end
    local PlayersInThisZone = 0
    if PlayerZones ~= nil then
        for k,v in pairs(PlayerZones) do
            if v.zone == zone then
                PlayersInThisZone = PlayersInThisZone + 1
            end
        end
    end
    return PlayersInThisZone
end

exports('GetPlayerCountForZone',GetPlayerCountForZone)

function GetPlayersInZone(zone)
    if not Config.Zones[zone] then return end
    local PlayersTable = {}
    if PlayerZones ~= nil then
        for k,v in pairs(PlayerZones) do
            if v.zone == zone then
                local Player = QBCore.Functions.GetPlayerByCitizenId(k)
                if Player ~= nil then
                    table.insert(PlayersTable, Player)
                end
            end
        end
    end
    return PlayersTable
end

exports('GetPlayersInZone',GetPlayersInZone)

function IsValidZone(zone)
    if Config.Zones[zone] ~= nil then
        return true
    else
        return false
    end
end

exports('IsValidZone',IsValidZone)

function IsValidGang(gang)
    if Config.Gangs[gang] ~= nil then
        return true
    else
        return false
    end
end

exports('IsValidGang',IsValidGang)

-- ONLY FOR DEBUG AND TESTING
QBCore.Commands.Add('swapgangzone', "Swap Zone of gang", { { name = "zone", help = "Name of zone" }, { name = "gang", help = "Name of gang" } }, true, function(source, args)
    TakeOverZone(args[1],args[2],10)
end, 'admin')

QBCore.Commands.Add('getmyplayerzone', "get current stored zone", { }, true, function(source, args)
    local Player = QBCore.Functions.GetPlayer(source)
    local citizenid = Player.PlayerData.citizenid

    if PlayerZones[citizenid] ~= nil then
        if PlayerZones[citizenid].zone ~= nil then
            DebugCode("Current Stored Zone of "..citizenid.." is "..PlayerZones[citizenid].zone)
        else
            DebugCode("No Stored Zone For "..citizenid)
        end
    else
        DebugCode("No Stored Zone For "..citizenid)
    end
end, 'admin')

function DebugCode(msg)
    if Config.DebugCode then
        print(msg)
    end
end

function SendNotify(src, msg, type, time, title)
    if not title then title = "Chop Shop" end
    if not time then time = 5000 end
    if not type then type = 'success' end
    if not msg then DebugCode("SendNotify Server Triggered With No Message") return end
    if Config.NotifyScript == 'qb' then
        TriggerClientEvent('QBCore:Notify', src, msg, type, time)
    elseif Config.NotifyScript == 'okok' then
        TriggerClientEvent('okokNotify:Alert', src, title, msg, time, type, false)
    elseif Config.NotifyScript == 'qs' then
        TriggerClientEvent('qs-notify:Alert', src, msg, time, type)
    elseif Config.NotifyScript == 'other' then
        --add your notify event here
    end
end