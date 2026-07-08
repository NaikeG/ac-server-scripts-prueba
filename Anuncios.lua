sim = ac.getSim()
car = ac.getCar(0)

local pendingAnnouncements = {}

local function msToTimeString(ms)
    local totalSeconds = ms / 1000
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds - minutes * 60
    return string.format("%d:%05.2f", minutes, seconds)
end

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
    ac.log("[ANNOUNCE] Evento de vuelta recibido de " .. sender:driverName() ..
        " | tiempo=" .. tostring(message.lapTimeMs) .. " | bestLapTimeMs local actual=" .. tostring(bestLapTimeMs))
    -- Actualiza el registro local y le muestra el cartel a TODOS (el que hizo la vuelta
    -- ya ve el suyo propio desde script.update; esto es para el resto de los pilotos).
    if bestLapTimeMs == nil or message.lapTimeMs < bestLapTimeMs then
        bestLapTimeMs = message.lapTimeMs
        bestLapDriver = sender:driverName()
        table.insert(pendingAnnouncements, {
            chatMsg = nil, -- el chat ya lo mandó el que hizo la vuelta
            label = "VUELTA MÁS RÁPIDA",
            value = sender:driverName() .. "  " .. msToTimeString(message.lapTimeMs),
            icon = "⏱️",
            color = rgbm(0.2, 0.8, 1.0, 1),
            duration = 6
        })
    end
end,
ac.SharedNamespace.ServerScript)

-- ===== Evento: carrera terminada (para anuncio de ganador) =====
raceFinishedEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Race Finished")
}, function(sender, message)
    if not winnerAnnounced then
        winnerAnnounced = true
        table.insert(pendingAnnouncements, {
            chatMsg = nil, -- el chat ya lo mandó el ganador
            label = "GANADOR DE LA CARRERA",
            value = sender:driverName(),
            icon = "🏆",
            color = rgbm(1.0, 0.78, 0.05, 1),
            duration = 7
        })
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
    local candidates = {
        "lastLap", "lastLapTimeMs", "lastLapTime", "previousLapTimeMs", "bestLap",
        "currentLapTime", "currentLapTimeMs", "sessionBestLapTimeMs", "bestLapTimeMs",
        "lapTimeMs", "lapTime", "previousLap"
    }
    ac.log("[ANNOUNCE] --- Probando todos los campos de tiempo de vuelta candidatos ---")
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        ac.log("[ANNOUNCE] car." .. name .. " = " .. tostring(ok and val or "no existe"))
    end

    for _, name in ipairs({ "bestLapTimeMs", "previousLapTimeMs", "lastLap", "lastLapTimeMs", "lastLapTime", "bestLap" }) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "number" and lapTimeField == nil then
            lapTimeField = name
        end
    end
    if lapTimeField then
        ac.log("[ANNOUNCE] Usando car." .. lapTimeField .. " para el tiempo de vuelta")
    else
        ac.log("[ANNOUNCE] No se encontró campo de tiempo de vuelta -> el anuncio de vuelta rápida queda desactivado")
    end
end

local function getLastLapTime()
    if lapTimeField == nil then return nil end
    local ok, val = pcall(function() return car[lapTimeField] end)
    if ok and type(val) == "number" and val > 0 then return val end
    return nil
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

local banner = { label = "", value = "", icon = "", alpha = 0, timer = 0, color = rgbm(1.0, 0.82, 0.0, 1) }
local bannerQueue = {}

local function showBanner(label, value, icon, color, duration)
    table.insert(bannerQueue, { label = label, value = value, icon = icon, color = color, duration = duration or 5 })
end

function script.drawUI()
    -- Los anuncios (chat + cartel) se disparan acá y no en script.update, porque
    -- drawUI solo se ejecuta donde hay pantalla (el cliente), nunca en la copia
    -- headless que corre en el servidor. Así se evita que el mismo aviso se
    -- mande dos veces (una desde cada copia del script).
    for _, item in ipairs(pendingAnnouncements) do
        if item.chatMsg then
            ac.sendChatMessage(item.chatMsg)
        end
        showBanner(item.label, item.value, item.icon, item.color, item.duration)
    end
    pendingAnnouncements = {}

    if banner.timer > 0 then
        banner.alpha = math.min(banner.alpha + 0.10, 1)
    else
        banner.alpha = math.max(banner.alpha - 0.10, 0)
    end

    if banner.alpha <= 0 then
        return
    end

    local a = banner.alpha
    local c = banner.color

    local panelWidth = 620
    local panelHeight = 96
    local x = (screen.w - panelWidth) * 0.5
    local y = 60

    -- Fondo oscuro con marco redondeado del color de la categoría
    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0, 0, 0, 0.85 * a), 10)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(c.r, c.g, c.b, a), 10, 0, 3)

    -- Categoría (chica, en mayúsculas, color del marco)
    ui.pushFont(ui.Font.Small)
    local labelText = (banner.icon ~= "" and (banner.icon .. "  ") or "") .. string.upper(banner.label)
    local labelSize = ui.measureText(labelText)
    ui.setCursor(vec2(x + (panelWidth - labelSize.x) * 0.5, y + 16))
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(c.r, c.g, c.b, a))
    ui.text(labelText)
    ui.popStyleColor()
    ui.popFont()

    -- Dato principal (grande, blanco, en mayúsculas)
    ui.pushFont(ui.Font.Title)
    local valueText = string.upper(banner.value)
    local valueSize = ui.measureText(valueText)
    ui.setCursor(vec2(x + (panelWidth - valueSize.x) * 0.5, y + 46))
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, a))
    ui.text(valueText)
    ui.popStyleColor()
    ui.popFont()
end

function script.update(dt)
    if banner.timer > 0 then
        banner.timer = banner.timer - dt
    elseif #bannerQueue > 0 then
        local next_ = table.remove(bannerQueue, 1)
        banner.label = next_.label
        banner.value = next_.value
        banner.icon = next_.icon
        banner.color = next_.color
        banner.timer = next_.duration
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
    local isRaceSession = (sim.raceSessionType == ac.SessionType.Race)
    if isRaceSession and totalLaps ~= nil and car.lapCount >= totalLaps and not winnerAnnounced then
        winnerAnnounced = true
        local chatMsg = "🏆 " .. car:driverName() .. " HA GANADO LA CARRERA!"
        table.insert(pendingAnnouncements, {
            chatMsg = chatMsg,
            label = "GANADOR DE LA CARRERA",
            value = car:driverName(),
            icon = "🏆",
            color = rgbm(1.0, 0.78, 0.05, 1),
            duration = 7
        })
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
                    local chatMsg = "⏱️ Nueva vuelta rápida: " .. car:driverName() .. " - " .. msToTimeString(lapTimeMs)
                    table.insert(pendingAnnouncements, {
                        chatMsg = chatMsg,
                        label = "VUELTA MÁS RÁPIDA",
                        value = car:driverName() .. "  " .. msToTimeString(lapTimeMs),
                        icon = "⏱️",
                        color = rgbm(0.2, 0.8, 1.0, 1), -- celeste
                        duration = 6
                    })
                    lapCompletedEvent({ lapTimeMs = lapTimeMs, lapNumber = completedLap })
                end
            end
        end
    end
end
