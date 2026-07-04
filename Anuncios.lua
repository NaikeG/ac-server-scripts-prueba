sim = ac.getSim()
car = ac.getCar(0)

-- ===== Diagnóstico: encontrar el campo de "cantidad total de vueltas de la carrera" =====
local totalLapsField = nil
local totalLapsFieldSource = nil -- "sim", "car" o "config"
local configLapsValue = nil
local function findTotalLapsField(config)
    -- Opción manual (la más confiable): el admin indica la cantidad de vueltas en Extra Options
    local ok, manualVal = pcall(function() return config:get("ANNOUNCE", "TOTAL_LAPS", 0) end)
    if ok and type(manualVal) == "number" and manualVal > 0 then
        ac.log("[ANNOUNCE] Vueltas totales configuradas manualmente: " .. tostring(manualVal))
        totalLapsFieldSource = "config"
        configLapsValue = manualVal
        return
    end

    local simCandidates = { "raceLaps", "sessionLapsCount", "numberOfLaps", "lapsCount", "totalLaps", "sessionLaps", "raceLapsCount", "lapsTotal", "totalLapsCount" }
    for _, name in ipairs(simCandidates) do
        local ok, val = pcall(function() return sim[name] end)
        if ok and type(val) == "number" then
            ac.log("[ANNOUNCE] Campo de vueltas totales encontrado: sim." .. name .. " = " .. tostring(val))
            totalLapsField = name
            totalLapsFieldSource = "sim"
            return
        end
    end
    local carCandidates = { "lapsTotal", "totalLaps", "racelapsCount", "lapsToDo" }
    for _, name in ipairs(carCandidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "number" then
            ac.log("[ANNOUNCE] Campo de vueltas totales encontrado: car." .. name .. " = " .. tostring(val))
            totalLapsField = name
            totalLapsFieldSource = "car"
            return
        end
    end
    ac.log("[ANNOUNCE] No se encontró campo de vueltas totales (ni automático ni TOTAL_LAPS manual) -> el anuncio de ganador queda desactivado (el de vuelta rápida sigue funcionando igual)")

    local okPairs, errPairs = pcall(function()
        local names = {}
        for k, v in pairs(sim) do
            if tostring(k):lower():find("lap") then
                table.insert(names, tostring(k) .. "=" .. tostring(v))
            end
        end
        ac.log("[ANNOUNCE] Campos de sim con 'lap' en el nombre: " .. table.concat(names, ", "))
    end)
    if not okPairs then
        ac.log("[ANNOUNCE] No se pudo enumerar sim: " .. tostring(errPairs))
    end
end

local function getTotalLaps()
    if totalLapsFieldSource == "config" then return configLapsValue end
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
        if ok and type(val) == "number" then
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
    findTotalLapsField(config)
    findLapTimeField()
end)

ac.onSessionStart(function()
    -- No reseteamos acá directamente: car.lapCount puede no haber bajado a 0 todavía
    -- en el instante exacto de este evento (causaba el doble anuncio). El reset real
    -- ocurre en script.update cuando se detecta que lapCount volvió a 0.
    sessionJustStarted = true
end)

-- ===== Carteles visuales en pantalla =====
local sim2 = ac.getSim()
local screen = { w = sim2.windowWidth, h = sim2.windowHeight }
ac.onResolutionChange(function()
    screen.w = ac.getSim().windowWidth
    screen.h = ac.getSim().windowHeight
end)

local banner = { text = "", alpha = 0, timer = 0, color = rgbm(1.0, 0.82, 0.0, 1) }

local function showBanner(text, color, duration)
    banner.text = text
    banner.color = color
    banner.timer = duration or 5
end

function script.drawUI()
    if banner.timer > 0 then
        banner.alpha = math.min(banner.alpha + 0.08, 1)
    else
        banner.alpha = math.max(banner.alpha - 0.08, 0)
    end

    if banner.alpha <= 0 then
        return
    end

    local panelWidth = 620
    local panelHeight = 90
    local x = (screen.w - panelWidth) * 0.5
    local y = 60

    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0, 0, 0, 0.85 * banner.alpha), 10)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight),
        rgbm(banner.color.r, banner.color.g, banner.color.b, banner.alpha), 10, 0, 3)

    ui.pushFont(ui.Font.Title)
    local textSize = ui.measureText(banner.text)
    ui.setCursor(vec2(x + (panelWidth - textSize.x) * 0.5, y + (panelHeight - textSize.y) * 0.5))
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(banner.color.r, banner.color.g, banner.color.b, banner.alpha))
    ui.text(banner.text)
    ui.popStyleColor()
    ui.popFont()
end

function script.update(dt)
    if banner.timer > 0 then
        banner.timer = banner.timer - dt
    end

    if prevLapCount == nil then
        prevLapCount = car.lapCount
        return
    end

    -- Reset real de estado: recién cuando el contador de vueltas vuelve a 0 de verdad
    -- (evita el doble anuncio que pasaba al resetear ciegamente en onSessionStart)
    if car.lapCount == 0 and prevLapCount > 0 then
        bestLapTimeMs = nil
        bestLapDriver = nil
        winnerAnnounced = false
        ac.log("[ANNOUNCE] Nueva carrera detectada (lapCount volvió a 0), estado reseteado")
    end

    -- Chequeo de fin de carrera: se evalúa cada frame, no solo al completar una vuelta,
    -- por si el teletransporte a pits al terminar la sesión corta la ejecución justo
    -- en el frame donde se incrementa el contador de vueltas.
    local totalLaps = getTotalLaps()
    if totalLaps ~= nil and car.lapCount >= totalLaps and not winnerAnnounced then
        winnerAnnounced = true
        local msg = "🏆 " .. car:driverName() .. " HA GANADO LA CARRERA!"
        ac.sendChatMessage(msg)
        showBanner(msg, rgbm(1.0, 0.82, 0.0, 1), 6)
        ac.log("[ANNOUNCE] GANADOR detectado: " .. car:driverName() .. " (lapCount=" .. car.lapCount .. ", totalLaps=" .. totalLaps .. ")")
        raceFinishedEvent({})
    end

    if car.lapCount > prevLapCount then
        local completedLap = prevLapCount + 1
        prevLapCount = car.lapCount

        ac.log("[ANNOUNCE] Vuelta completada: " .. completedLap .. " | car.lapCount=" .. car.lapCount ..
            " | totalLaps=" .. tostring(totalLaps) .. " | winnerAnnounced=" .. tostring(winnerAnnounced))

        -- La vuelta 1 incluye la salida (no es representativa como "vuelta rápida")
        if completedLap >= 2 then
            local lapTimeMs = getLastLapTime()

            if lapTimeMs ~= nil then
                if bestLapTimeMs == nil or lapTimeMs < bestLapTimeMs then
                    bestLapTimeMs = lapTimeMs
                    bestLapDriver = car:driverName()
                    local msg = "⏱️ NUEVA VUELTA RÁPIDA: " .. car:driverName() .. " - " .. msToTimeString(lapTimeMs)
                    ac.sendChatMessage(msg)
                    showBanner(msg, rgbm(0.2, 0.8, 1.0, 1), 5)
                    lapCompletedEvent({ lapTimeMs = lapTimeMs, lapNumber = completedLap })
                end
            end
        end
    end
end
