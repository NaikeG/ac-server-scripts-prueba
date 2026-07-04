sim = ac.getSim()
car = ac.getCar(0)

-- ===== Diagnóstico: encontrar el campo de "cantidad total de vueltas de la carrera" =====
local totalLapsField = nil
local totalLapsFieldSource = nil -- "sim" o "car"
local function findTotalLapsField()
    local simCandidates = { "raceLaps", "sessionLapsCount", "numberOfLaps", "lapsCount", "totalLaps" }
    for _, name in ipairs(simCandidates) do
        local ok, val = pcall(function() return sim[name] end)
        if ok and type(val) == "number" and val > 0 then
            ac.log("[ANNOUNCE] Campo de vueltas totales encontrado: sim." .. name .. " = " .. tostring(val))
            totalLapsField = name
            totalLapsFieldSource = "sim"
            return
        end
    end
    ac.log("[ANNOUNCE] No se encontró campo de vueltas totales -> el anuncio de ganador queda desactivado (el de vuelta rápida sigue funcionando igual)")
end

local function getTotalLaps()
    if totalLapsField == nil then return nil end
    local ok, val = pcall(function()
        if totalLapsFieldSource == "sim" then return sim[totalLapsField] end
        return car[totalLapsField]
    end)
    if ok then return val end
    return nil
end

-- ===== Evento: vuelta completada (para vuelta rápida) =====
lapCompletedEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Lap Completed"),
    lapTimeMs = ac.StructItem.float(),
    lapNumber = ac.StructItem.float()
}, function(sender, message)
    -- Solo actualiza el registro local; el anuncio lo hace quien marcó la vuelta (ver script.update)
    if bestLapTimeMs == nil or message.lapTimeMs < bestLapTimeMs then
        bestLapTimeMs = message.lapTimeMs
        bestLapDriver = sender:driverName()
    end
end,
ac.SharedNamespace.ServerScript)

-- ===== Evento: carrera terminada (para anuncio de ganador) =====
raceFinishedEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Race Finished")
}, function(sender, message)
    if not winnerAnnounced then
        winnerAnnounced = true
        ac.log("[ANNOUNCE] Ganador registrado: " .. sender:driverName())
    end
end,
ac.SharedNamespace.ServerScript)

bestLapTimeMs = nil
bestLapDriver = nil
winnerAnnounced = false

local prevLapCount = nil

-- ===== Diagnóstico: encontrar el campo de "tiempo de la última vuelta" =====
local lapTimeField = nil
local function findLapTimeField()
    local candidates = { "lastLap", "lastLapTimeMs", "lastLapTime", "previousLapTimeMs", "bestLap" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "number" and val > 0 then
            ac.log("[ANNOUNCE] Campo de tiempo de vuelta encontrado: car." .. name .. " = " .. tostring(val))
            lapTimeField = name
            return
        end
    end
    ac.log("[ANNOUNCE] No se encontró campo de tiempo de vuelta -> el anuncio de vuelta rápida queda desactivado")
end

local function getLastLapTime()
    if lapTimeField == nil then return nil end
    local ok, val = pcall(function() return car[lapTimeField] end)
    if ok and type(val) == "number" and val > 0 then return val end
    return nil
end

local function msToTimeString(ms)
    local totalSeconds = ms / 1000
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds - minutes * 60
    return string.format("%d:%05.2f", minutes, seconds)
end

ac.onOnlineWelcome(function(message, config)
    findTotalLapsField()
    findLapTimeField()
end)

ac.onSessionStart(function()
    -- Reset de estado al arrancar una sesión nueva
    bestLapTimeMs = nil
    bestLapDriver = nil
    winnerAnnounced = false
    prevLapCount = nil
end)

function script.update(dt)
    if prevLapCount == nil then
        prevLapCount = car.lapCount
        return
    end

    if car.lapCount > prevLapCount then
        local completedLap = prevLapCount + 1
        prevLapCount = car.lapCount

        -- La vuelta 1 incluye la salida (no es representativa como "vuelta rápida")
        if completedLap >= 2 then
            local lapTimeMs = getLastLapTime()

            if lapTimeMs ~= nil then
                if bestLapTimeMs == nil or lapTimeMs < bestLapTimeMs then
                    bestLapTimeMs = lapTimeMs
                    bestLapDriver = car:driverName()
                    ac.sendChatMessage("⏱️ Nueva vuelta rápida: " .. car:driverName() .. " - " .. msToTimeString(lapTimeMs))
                    lapCompletedEvent({ lapTimeMs = lapTimeMs, lapNumber = completedLap })
                end
            end
        end

        -- Chequeo de fin de carrera
        local totalLaps = getTotalLaps()
        if totalLaps ~= nil and car.lapCount >= totalLaps and not winnerAnnounced then
            winnerAnnounced = true
            ac.sendChatMessage("🏆 " .. car:driverName() .. " ha ganado la carrera!")
            raceFinishedEvent({})
        end
    end
end
