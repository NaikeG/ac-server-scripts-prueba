sim = ac.getSim()
car = ac.getCar(0)

local pendingAnnouncements = {}

local function msToTimeString(ms)
    local totalSeconds = ms / 1000
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds - minutes * 60
    return string.format("%d:%06.3f", minutes, seconds)
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

bestLapTimeMs = nil
bestLapDriver = nil
myFinishAnnounced = false

-- Igual que con el podio: en vez de anunciar apenas ALGUIEN cree tener un nuevo récord
-- (que puede ser falso si todavía no le llegó el aviso de un tiempo mejor de otro piloto),
-- se junta en un buffer y se confirma el más rápido tras un breve período sin novedades.
local lapCandidates = {}
local lapSettleTimer = 0
local LAP_SETTLE_DELAY = 2.0

local function addLapCandidate(name, timeMs)
    if bestLapTimeMs ~= nil and timeMs >= bestLapTimeMs then return end -- no supera el ya confirmado, ni se molesta
    table.insert(lapCandidates, { name = name, time = timeMs })
    lapSettleTimer = LAP_SETTLE_DELAY
end

local function settleLapCandidates(myName)
    if #lapCandidates == 0 then return end
    table.sort(lapCandidates, function(a, b) return a.time < b.time end)
    local winner = lapCandidates[1]
    lapCandidates = {}

    if bestLapTimeMs == nil or winner.time < bestLapTimeMs then
        bestLapTimeMs = winner.time
        bestLapDriver = winner.name
        local chatMsg = nil
        if winner.name == myName then
            chatMsg = "⏱️ Nueva vuelta rápida: " .. winner.name .. " - " .. msToTimeString(winner.time)
        end
        table.insert(pendingAnnouncements, {
            chatMsg = chatMsg,
            label = "VUELTA MÁS RÁPIDA",
            value = winner.name .. "  " .. msToTimeString(winner.time),
            icon = "⏱️",
            color = rgbm(0.2, 0.8, 1.0, 1),
            duration = 6
        })
        ac.log("[ANNOUNCE] Vuelta rápida confirmada: " .. winner.name .. " - " .. tostring(winner.time))
    end
end

-- ===== Evento: vuelta completada (para vuelta rápida) =====
lapCompletedEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Lap Completed"),
    lapTimeMs = ac.StructItem.float(),
    lapNumber = ac.StructItem.float()
}, function(sender, message)
    addLapCandidate(sender:driverName(), message.lapTimeMs)
end,
ac.SharedNamespace.ServerScript)

-- Datos visuales de cada puesto del podio
local PODIUM = {
    [1] = { label = "GANADOR DE LA CARRERA", icon = "🏆", color = rgbm(1.0, 0.78, 0.05, 1) },
    [2] = { label = "SEGUNDO PUESTO", icon = "🥈", color = rgbm(0.78, 0.78, 0.81, 1) },
    [3] = { label = "TERCER PUESTO", icon = "🥉", color = rgbm(0.82, 0.55, 0.32, 1) },
}

-- El podio se arma ordenando por la HORA REAL de cruce (sim.currentSessionTime), no por el
-- orden en que a cada cliente le llegan los avisos por red (eso podía dar resultados
-- distintos según a quién le llegaba primero cada mensaje).
local finishRecords = {} -- { {name=..., time=...}, ... }
local announcedNames = {}
local pendingSettleTimer = 0
local SETTLE_DELAY = 1.5 -- segundos de espera tras el último aviso recibido, para que lleguen los que venían atrasados

local function addFinishRecord(name, time)
    for _, r in ipairs(finishRecords) do
        if r.name == name then return end -- ya registrado
    end
    table.insert(finishRecords, { name = name, time = time })
    pendingSettleTimer = SETTLE_DELAY -- reinicia el buffer cada vez que llega uno nuevo
end

local function settleAndAnnouncePodium(myName)
    table.sort(finishRecords, function(a, b) return a.time < b.time end)
    for i = 1, math.min(3, #finishRecords) do
        local r = finishRecords[i]
        if not announcedNames[r.name] then
            announcedNames[r.name] = true
            local podium = PODIUM[i]
            local chatMsg = nil
            if r.name == myName then
                if i == 1 then
                    chatMsg = "🏆 " .. r.name .. " HA GANADO LA CARRERA!"
                else
                    chatMsg = podium.icon .. " " .. r.name .. " terminó en P" .. i .. "!"
                end
            end
            table.insert(pendingAnnouncements, {
                chatMsg = chatMsg,
                label = podium.label,
                value = r.name,
                icon = podium.icon,
                color = podium.color,
                duration = 6
            })
            ac.log("[ANNOUNCE] Podio confirmado: " .. r.name .. " -> P" .. i)
        end
    end
end

-- ===== Evento: carrera terminada (para anuncio de podio) =====
raceFinishedEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Race Finished"),
    finishTime = ac.StructItem.float()
}, function(sender, message)
    addFinishRecord(sender:driverName(), message.finishTime)
end,
ac.SharedNamespace.ServerScript)

local prevLapCount = nil
local raceLapsSeenZero = false -- evita falsos positivos si lapCount arranca con un valor viejo de otra sesión

-- ===== Última vuelta =====
-- Aviso único para toda la carrera: el primero en llegar a la última vuelta es, por
-- definición, el líder en ese momento. No lleva nombre de piloto, es un aviso general.
local raceLastLapAnnounced = false

lastLapEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Last Lap")
}, function(sender, message)
    if raceLastLapAnnounced then return end
    raceLastLapAnnounced = true
    table.insert(pendingAnnouncements, {
        chatMsg = nil,
        label = "",
        value = "ÚLTIMA VUELTA",
        icon = "🏁",
        color = rgbm(0.95, 0.95, 0.95, 1),
        duration = 5
    })
end,
ac.SharedNamespace.ServerScript)

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
    -- Reset inmediato de todo el estado al cambiar de sesión (Practice -> Qualy -> Race, etc.)
    bestLapTimeMs = nil
    bestLapDriver = nil
    myFinishAnnounced = false
    finishRecords = {}
    announcedNames = {}
    pendingSettleTimer = 0
    lapCandidates = {}
    lapSettleTimer = 0
    raceLastLapAnnounced = false
    prevLapCount = nil
    -- Se "desarma" hasta confirmar que la sesión nueva realmente arrancó en la vuelta 0,
    -- para que un lapCount viejo que todavía no bajó no dispare un falso podio de entrada.
    raceLapsSeenZero = false
    ac.log("[ANNOUNCE] Cambio de sesión detectado, estado reseteado")
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
        if car.lapCount == 0 then
            raceLapsSeenZero = true
        end
        return
    end

    if car.lapCount == 0 then
        raceLapsSeenZero = true
    end

    -- Reset real de estado: recién cuando el contador de vueltas vuelve a 0 de verdad
    -- (evita el doble anuncio que pasaba al resetear ciegamente en onSessionStart)
    if car.lapCount == 0 and prevLapCount > 0 then
        bestLapTimeMs = nil
        bestLapDriver = nil
        myFinishAnnounced = false
        finishRecords = {}
        announcedNames = {}
        pendingSettleTimer = 0
        lapCandidates = {}
        lapSettleTimer = 0
        raceLastLapAnnounced = false
        ac.log("[ANNOUNCE] Nueva carrera detectada (lapCount volvió a 0), estado reseteado")
    end

    -- Chequeo de fin de carrera: se evalúa cada frame, no solo al completar una vuelta,
    -- por si el teletransporte a pits al terminar la sesión corta la ejecución justo
    -- en el frame donde se incrementa el contador de vueltas.
    local totalLaps = getTotalLaps()
    local isRaceSession = (sim.raceSessionType == ac.SessionType.Race)
    if raceLapsSeenZero and isRaceSession and totalLaps ~= nil and car.lapCount >= totalLaps and not myFinishAnnounced then
        myFinishAnnounced = true
        local myFinishTime = sim.currentSessionTime
        addFinishRecord(car:driverName(), myFinishTime)
        raceFinishedEvent({ finishTime = myFinishTime })
        ac.log("[ANNOUNCE] Mi llegada detectada (lapCount=" .. car.lapCount .. ", totalLaps=" .. totalLaps .. "), evento enviado")
    end

    -- Confirma el podio recién cuando pasó el tiempo de estabilización sin avisos nuevos
    if pendingSettleTimer > 0 then
        pendingSettleTimer = pendingSettleTimer - dt
        if pendingSettleTimer <= 0 then
            pendingSettleTimer = 0
            settleAndAnnouncePodium(car:driverName())
        end
    end

    -- Confirma la vuelta rápida recién cuando pasó el tiempo de estabilización sin avisos nuevos
    if lapSettleTimer > 0 then
        lapSettleTimer = lapSettleTimer - dt
        if lapSettleTimer <= 0 then
            lapSettleTimer = 0
            settleLapCandidates(car:driverName())
        end
    end

    -- Última vuelta: aviso único para toda la carrera, apenas el PRIMERO (el líder) entra a su vuelta final
    if raceLapsSeenZero and isRaceSession and totalLaps ~= nil and totalLaps > 1
        and car.lapCount == totalLaps - 1 and not raceLastLapAnnounced then
        raceLastLapAnnounced = true
        table.insert(pendingAnnouncements, {
            chatMsg = "🏁 ÚLTIMA VUELTA!",
            label = "",
            value = "ÚLTIMA VUELTA",
            icon = "🏁",
            color = rgbm(0.95, 0.95, 0.95, 1),
            duration = 5
        })
        lastLapEvent({})
        ac.log("[ANNOUNCE] Última vuelta de la carrera anunciada (líder detectado por " .. car:driverName() .. ")")
    end

    if car.lapCount > prevLapCount then
        local completedLap = prevLapCount + 1
        prevLapCount = car.lapCount

        ac.log("[ANNOUNCE] Vuelta completada: " .. completedLap .. " | car.lapCount=" .. car.lapCount ..
            " | totalLaps=" .. tostring(totalLaps) .. " | myFinishAnnounced=" .. tostring(myFinishAnnounced))

        -- La vuelta 1 incluye la salida (no es representativa como "vuelta rápida")
        if completedLap >= 2 then
            local lapTimeMs = getLastLapTime()

            if lapTimeMs ~= nil then
                addLapCandidate(car:driverName(), lapTimeMs)
                lapCompletedEvent({ lapTimeMs = lapTimeMs, lapNumber = completedLap })
            end
        end
    end
end
