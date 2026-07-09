sim = ac.getSim()
car = ac.getCar(0)

local pendingChats = {}

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

local FL_ANIM_DURATION = 0.45
local FL_DISPLAY_DURATION = 6 -- segundos que queda visible antes de desaparecer
local fastestLap = { driver = nil, timeMs = nil, animTimer = 0, displayTimer = 0 }

local function settleLapCandidates(myName)
    if #lapCandidates == 0 then return end
    table.sort(lapCandidates, function(a, b) return a.time < b.time end)
    local winner = lapCandidates[1]
    lapCandidates = {}

    if bestLapTimeMs == nil or winner.time < bestLapTimeMs then
        bestLapTimeMs = winner.time
        bestLapDriver = winner.name

        fastestLap.driver = winner.name
        fastestLap.timeMs = winner.time
        fastestLap.animTimer = FL_ANIM_DURATION
        fastestLap.displayTimer = FL_DISPLAY_DURATION

        if winner.name == myName then
            table.insert(pendingChats, "⏱️ Nueva vuelta rápida: " .. winner.name .. " - " .. msToTimeString(winner.time))
        end
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

local RESULT_ANIM_DURATION = 0.4
local resultsList = {} -- { {rank=1, name=..., animTimer=...}, ... } -- se muestra TODA la lista, no solo el podio

local function getRankColor(rank)
    if rank == 1 then return rgbm(1.0, 0.78, 0.05, 1) end
    if rank == 2 then return rgbm(0.78, 0.78, 0.81, 1) end
    if rank == 3 then return rgbm(0.82, 0.55, 0.32, 1) end
    return rgbm(0.55, 0.55, 0.58, 1) -- neutro para P4 en adelante
end

local function settleAndAnnouncePodium(myName)
    table.sort(finishRecords, function(a, b) return a.time < b.time end)
    for i = 1, #finishRecords do
        local r = finishRecords[i]
        if not announcedNames[r.name] then
            announcedNames[r.name] = true

            table.insert(resultsList, { rank = i, name = r.name, animTimer = RESULT_ANIM_DURATION })

            if r.name == myName then
                local podium = PODIUM[i]
                if podium then
                    if i == 1 then
                        table.insert(pendingChats, "🏆 " .. r.name .. " HA GANADO LA CARRERA!")
                    else
                        table.insert(pendingChats, podium.icon .. " " .. r.name .. " terminó en P" .. i .. "!")
                    end
                else
                    table.insert(pendingChats, "🏁 " .. r.name .. " terminó en P" .. i .. "!")
                end
            end
            ac.log("[ANNOUNCE] Resultado confirmado: " .. r.name .. " -> P" .. i)
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
local banner = { label = "", value = "", icon = "", alpha = 0, timer = 0, color = rgbm(1.0, 0.82, 0.0, 1) }

lastLapEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Last Lap")
}, function(sender, message)
    if raceLastLapAnnounced then return end
    raceLastLapAnnounced = true
    banner.label = ""
    banner.value = "ÚLTIMA VUELTA"
    banner.icon = "🏁"
    banner.color = rgbm(0.95, 0.95, 0.95, 1)
    banner.timer = 5
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
    fastestLap.driver = nil
    fastestLap.timeMs = nil
    fastestLap.animTimer = 0
    fastestLap.displayTimer = 0
    resultsList = {}
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

local function easeOutCubic(t)
    t = math.max(0, math.min(1, t))
    local inv = 1 - t
    return 1 - inv * inv * inv
end

function script.drawUI()
    -- Los mensajes de chat se disparan acá y no en script.update, porque drawUI solo se
    -- ejecuta donde hay pantalla (el cliente), nunca en la copia headless que corre en el
    -- servidor. Así se evita que el mismo aviso se mande dos veces.
    for _, msg in ipairs(pendingChats) do
        ac.sendChatMessage(msg)
    end
    pendingChats = {}

    ------------------------------------------------
    -- Cartel de "ÚLTIMA VUELTA" (centrado, transitorio, como antes)
    ------------------------------------------------
    if banner.timer > 0 then
        banner.alpha = math.min(banner.alpha + 0.10, 1)
    else
        banner.alpha = math.max(banner.alpha - 0.10, 0)
    end

    if banner.alpha > 0 then
        local a = banner.alpha
        local c = banner.color
        local panelWidth = 620
        local panelHeight = 96
        local x = (screen.w - panelWidth) * 0.5
        local y = 60

        ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0, 0, 0, 0.85 * a), 10)
        ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(c.r, c.g, c.b, a), 10, 0, 3)

        ui.pushFont(ui.Font.Small)
        local labelText = (banner.icon ~= "" and (banner.icon .. "  ") or "") .. string.upper(banner.label)
        local labelSize = ui.measureText(labelText)
        ui.setCursor(vec2(x + (panelWidth - labelSize.x) * 0.5, y + 16))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(c.r, c.g, c.b, a))
        ui.text(labelText)
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(ui.Font.Title)
        local valueText = string.upper(banner.value)
        local valueSize = ui.measureText(valueText)
        ui.setCursor(vec2(x + (panelWidth - valueSize.x) * 0.5, y + 46))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, a))
        ui.text(valueText)
        ui.popStyleColor()
        ui.popFont()
    end

    ------------------------------------------------
    -- Panel de "FASTEST LAP" (persistente, arriba a la derecha, estilo nativo de AC)
    ------------------------------------------------
    if fastestLap.driver ~= nil and fastestLap.displayTimer > 0 then
        local t = 1 - (fastestLap.animTimer / FL_ANIM_DURATION)
        local eased = easeOutCubic(t)
        local slide = (1 - eased) * 70 -- entra deslizándose desde la derecha

        local panelWidth = 260
        local panelHeight = 70
        local x = screen.w - panelWidth - 20 + slide
        local y = 40

        ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0.04, 0.04, 0.05, 0.92), 6)
        ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0.2, 0.8, 1.0, 1), 6, 0, 2)

        ui.pushFont(ui.Font.Small)
        ui.setCursor(vec2(x + 12, y + 8))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.2, 0.8, 1.0, 1))
        ui.text("VUELTA RAPIDA")
        ui.popStyleColor()
        ui.popFont()

        -- Insignia con el número "1"
        local badgeSize = 26
        local badgeX = x + 12
        local badgeY = y + 32
        ui.drawRectFilled(vec2(badgeX, badgeY), vec2(badgeX + badgeSize, badgeY + badgeSize), rgbm(0.2, 0.8, 1.0, 1), 4)
        ui.pushFont(ui.Font.Main)
        local badgeText = "1"
        local badgeTextSize = ui.measureText(badgeText)
        ui.setCursor(vec2(badgeX + (badgeSize - badgeTextSize.x) * 0.5, badgeY + (badgeSize - badgeTextSize.y) * 0.5))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.05, 0.05, 0.05, 1))
        ui.text(badgeText)
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(ui.Font.Main)
        ui.setCursor(vec2(badgeX + badgeSize + 10, y + 30))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, 1))
        ui.text(string.upper(fastestLap.driver))
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(ui.Font.Small)
        ui.setCursor(vec2(badgeX + badgeSize + 10, y + 48))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.75, 0.75, 0.78, 1))
        ui.text(msToTimeString(fastestLap.timeMs))
        ui.popStyleColor()
        ui.popFont()
    end

    ------------------------------------------------
    -- Lista de resultados (persistente, crece con cada piloto que llega)
    ------------------------------------------------
    local resultsY = 40 + ((fastestLap.driver ~= nil and fastestLap.displayTimer > 0) and 84 or 0)
    local rowHeight = 34
    local panelWidth = 260

    for i, entry in ipairs(resultsList) do
        local t = 1 - (entry.animTimer / RESULT_ANIM_DURATION)
        local eased = easeOutCubic(t)
        local slide = (1 - eased) * 70

        local rowY = resultsY + (i - 1) * rowHeight
        local x = screen.w - panelWidth - 20 + slide
        local color = getRankColor(entry.rank)

        ui.drawRectFilled(vec2(x, rowY), vec2(x + panelWidth, rowY + rowHeight - 4), rgbm(0.04, 0.04, 0.05, 0.90), 4)

        local badgeSize = 22
        local badgeX = x + 6
        local badgeY = rowY + (rowHeight - 4 - badgeSize) * 0.5
        ui.drawRectFilled(vec2(badgeX, badgeY), vec2(badgeX + badgeSize, badgeY + badgeSize), color, 3)
        ui.pushFont(ui.Font.Small)
        local rankText = tostring(entry.rank)
        local rankTextSize = ui.measureText(rankText)
        ui.setCursor(vec2(badgeX + (badgeSize - rankTextSize.x) * 0.5, badgeY + (badgeSize - rankTextSize.y) * 0.5))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.05, 0.05, 0.05, 1))
        ui.text(rankText)
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(ui.Font.Small)
        ui.setCursor(vec2(badgeX + badgeSize + 10, rowY + (rowHeight - 4) * 0.5 - 8))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, 1))
        ui.text(string.upper(entry.name))
        ui.popStyleColor()
        ui.popFont()
    end
end

function script.update(dt)
    if banner.timer > 0 then
        banner.timer = banner.timer - dt
    end

    if fastestLap.animTimer > 0 then
        fastestLap.animTimer = math.max(fastestLap.animTimer - dt, 0)
    end
    if fastestLap.displayTimer > 0 then
        fastestLap.displayTimer = math.max(fastestLap.displayTimer - dt, 0)
    end

    for _, entry in ipairs(resultsList) do
        if entry.animTimer > 0 then
            entry.animTimer = math.max(entry.animTimer - dt, 0)
        end
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
        fastestLap.driver = nil
        fastestLap.timeMs = nil
        fastestLap.animTimer = 0
        fastestLap.displayTimer = 0
        resultsList = {}
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
        table.insert(pendingChats, "🏁 ÚLTIMA VUELTA!")
        banner.label = ""
        banner.value = "ÚLTIMA VUELTA"
        banner.icon = "🏁"
        banner.color = rgbm(0.95, 0.95, 0.95, 1)
        banner.timer = 5
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
