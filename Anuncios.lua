sim = ac.getSim()
car = ac.getCar(0)

local pendingChats = {}

-- ===== Modo de edición: muestra todos los carteles con contenido de ejemplo para poder
-- acomodarlos con tranquilidad antes de que arranque la actividad real. Se comparte el mismo
-- evento con penalties.lua, así un solo botón prende/apaga el modo de edición en todos los
-- carteles de ambos scripts a la vez. =====
local previewMode = false
local adminFlag = ui.OnlineExtraFlags.Admin

panelPreviewEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Preview Mode"),
    enabled = ac.StructItem.boolean()
}, function(sender, message)
    previewMode = message.enabled
end,
ac.SharedNamespace.ServerScript)

local function msToTimeString(ms)
    local totalSeconds = ms / 1000
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds - minutes * 60
    return string.format("%d:%06.3f", minutes, seconds)
end

-- ===== Diagnóstico: encontrar el campo de "está en boxes" =====
-- Para filtrar falsos positivos: si a alguien lo teletransportan a boxes por una sanción,
-- el juego puede contar eso como si hubiera cruzado la meta. Si detectamos que está en
-- boxes justo en ese momento, no lo contamos como llegada real.
local inPitField = nil
local function findInPitField()
    local candidates = { "isInPit", "isInPitlane", "inPitlane", "inPit", "isInPitLane", "isInPitBox" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "boolean" then
            ac.log("[ANNOUNCE] Campo de pits encontrado: car." .. name .. " = " .. tostring(val))
            inPitField = name
            return
        end
    end
    ac.log("[ANNOUNCE] No se encontró campo de pits -> no se puede filtrar falsos positivos por teletransporte a boxes")
end

local function isCarInPit()
    if inPitField == nil then return false end
    local ok, val = pcall(function() return car[inPitField] end)
    if ok and val == true then return true end
    return false
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

-- ===== Sincronización del mejor tiempo al conectarse =====
-- Sin esto, un piloto que se conecta a mitad de sesión no sabe cuál es el mejor tiempo
-- ya existente, y su primera vuelta le parece un "récord" aunque sea más lenta que el real.
requestBestLapSyncEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Request Best Lap Sync")
}, function(sender, message)
    if bestLapTimeMs ~= nil then
        bestLapSyncResponseEvent({ timeMs = bestLapTimeMs })
    end
end,
ac.SharedNamespace.ServerScript)

bestLapSyncResponseEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Best Lap Sync Response"),
    timeMs = ac.StructItem.float()
}, function(sender, message)
    if bestLapTimeMs == nil or message.timeMs < bestLapTimeMs then
        bestLapTimeMs = message.timeMs
        ac.log("[ANNOUNCE] Mejor tiempo existente sincronizado al conectar: " .. tostring(message.timeMs))
    end
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
local RESULTS_MAX_SLOTS = 15 -- a partir del 16° resultado, se reutiliza el lugar visual del 1°, el 17° el del 2°, etc.
local resultsSlots = {} -- indexado 1..15; cada slot tiene el ÚLTIMO resultado que le tocó, aunque su rank real sea otro

local function getRankColor(rank)
    if rank == 1 then return rgbm(1.0, 0.78, 0.05, 1) end
    if rank == 2 then return rgbm(0.78, 0.78, 0.81, 1) end
    if rank == 3 then return rgbm(0.82, 0.55, 0.32, 1) end
    return rgbm(0.55, 0.55, 0.58, 1) -- neutro para P4 en adelante
end

-- Cartel grande centrado del podio (P1/P2/P3), en cola para que no se pisen entre sí
local podiumBanner = { label = "", value = "", icon = "", color = rgbm(1, 1, 1, 1), timer = 0, alpha = 0 }
local podiumBannerQueue = {}

local function showPodiumBanner(label, value, icon, color, duration)
    table.insert(podiumBannerQueue, { label = label, value = value, icon = icon, color = color, duration = duration or 6 })
end

local function settleAndAnnouncePodium(myName)
    table.sort(finishRecords, function(a, b) return a.time < b.time end)
    for i = 1, #finishRecords do
        local r = finishRecords[i]
        if not announcedNames[r.name] then
            announcedNames[r.name] = true

            local slot = ((i - 1) % RESULTS_MAX_SLOTS) + 1
            resultsSlots[slot] = { rank = i, name = r.name, animTimer = RESULT_ANIM_DURATION }

            if i == 1 then
                raceWon = true
            end

            local podium = PODIUM[i]
            if podium then
                showPodiumBanner(podium.label, r.name, podium.icon, podium.color, 6)
            end

            if r.name == myName then
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
            ac.log("[ANNOUNCE] Resultado confirmado: " .. r.name .. " -> P" .. i .. " (slot " .. slot .. ")")
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
local raceWon = false -- se pone en true apenas se confirma el P1 (quien gane la carrera)
local banner = { label = "", value = "", icon = "", alpha = 0, color = rgbm(1.0, 0.82, 0.0, 1) }

lastLapEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Announce Last Lap")
}, function(sender, message)
    if raceLastLapAnnounced then return end
    raceLastLapAnnounced = true
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

-- ===== Diagnóstico: campo de "vuelta inválida" (corte de pista, etc.) =====
local lapValidField = nil
local lapValidFieldMeansInvalid = false -- true si el campo se llama tipo "isLapInvalid" (invertido)
local function findLapValidField()
    local validCandidates = {
        "isLapValid", "isValidLap", "lapValid", "lastLapValid", "isCurrentLapValid",
        "currentLapValid", "lapIsValid", "isLapValidated"
    }
    local invalidCandidates = {
        "isLapInvalid", "lapInvalidated", "invalidLap", "lapCut", "isLapCut",
        "currentLapInvalid", "lapInvalid", "isCurrentLapInvalid", "hasCut",
        "cutTrack", "isOffTrackInvalidation", "lapCutInvalidation"
    }

    ac.log("[ANNOUNCE] --- Probando todos los campos de validez de vuelta candidatos ---")
    for _, name in ipairs(validCandidates) do
        local ok, val = pcall(function() return car[name] end)
        ac.log("[ANNOUNCE] car." .. name .. " = " .. tostring(ok and val or "no existe"))
    end
    for _, name in ipairs(invalidCandidates) do
        local ok, val = pcall(function() return car[name] end)
        ac.log("[ANNOUNCE] car." .. name .. " = " .. tostring(ok and val or "no existe"))
    end

    for _, name in ipairs(validCandidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "boolean" then
            lapValidField = name
            lapValidFieldMeansInvalid = false
            ac.log("[ANNOUNCE] Usando car." .. name .. " (válido=true) para la validez de vuelta")
            return
        end
    end
    for _, name in ipairs(invalidCandidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "boolean" then
            lapValidField = name
            lapValidFieldMeansInvalid = true
            ac.log("[ANNOUNCE] Usando car." .. name .. " (inválido=true, se invierte) para la validez de vuelta")
            return
        end
    end
    ac.log("[ANNOUNCE] No se encontró ningún campo de validez de vuelta -> no se puede filtrar vueltas cortadas")
end

local function isLapValid()
    if lapValidField == nil then return true end -- si no hay campo, no filtramos (mejor que romper la función)
    local ok, val = pcall(function() return car[lapValidField] end)
    if not ok then return true end
    if lapValidFieldMeansInvalid then return not val end
    return val
end

-- El campo de validez puede resetearse a "válido" apenas arranca la vuelta nueva, justo antes
-- de que lleguemos a leerlo en el frame donde se completa la vuelta anterior. Por eso lo
-- vigilamos en TODOS los frames de la vuelta, no solo en el instante en que termina.
local currentLapHadInvalidMoment = false

ac.onOnlineWelcome(function(message, config)
    findTotalLapsField(config)
    findLapTimeField()
    findLapValidField()
    findInPitField()
    requestBestLapSyncEvent({})

    if config:get("ANNOUNCE", "PANEL_EDIT_ADMIN_ONLY", 1) == 0 then
        adminFlag = ui.OnlineExtraFlags.None
    end

    ui.registerOnlineExtra(
        ui.Icons.Warning,
        "🔧 Acomodar Carteles",
        function() return true end,
        nil,
        function()
            previewMode = not previewMode
            panelPreviewEvent({ enabled = previewMode })
            ac.log("[ANNOUNCE] Modo de edición de carteles: " .. tostring(previewMode))
        end,
        adminFlag
    )
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
    raceWon = false
    fastestLap.driver = nil
    fastestLap.timeMs = nil
    fastestLap.animTimer = 0
    fastestLap.displayTimer = 0
    resultsSlots = {}
    podiumBanner.timer = 0
    podiumBannerQueue = {}
    prevLapCount = nil
    currentLapHadInvalidMoment = false
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

-- ===== Arrastre manual con click sostenido (panel de Vuelta Rápida) =====
local function isMouseButtonDown()
    local ok, val = pcall(function() return ui.mouseDown(0) end)
    if ok then return val end
    return false
end

local function getMousePos()
    local ok, val = pcall(function() return ui.mousePos() end)
    if ok then return val end
    return nil
end

-- Las 4 posiciones van en UNA sola llamada a ac.storage() (no 4 separadas), para eliminar
-- cualquier posibilidad de que distintas llamadas a ac.storage() con forma parecida terminen
-- compartiendo el mismo espacio de guardado por error.
local panelPositions = ac.storage({
    flX = (screen.w - 280) / screen.w,
    flY = 290 / 1080,
    lastLapX = 0.5, -- centro del cartel
    lastLapY = 34 / 1080,
    podiumX = 0.5, -- centro del cartel
    podiumY = 105 / 1080,
    resultsX = (screen.w - 280) / screen.w,
    resultsY = 130 / 1080,
})

-- ===== Identificadores globales de cartel, compartidos entre TODOS los scripts del proyecto,
-- para poder ocultar "todos menos el que se está arrastrando" incluso entre scripts distintos.
-- 1-4: announcements.lua | 5: penalties.lua | 6: safetyCar.lua | 7: vueltaPrevia.lua
-- 8: startLights.lua | 9: largadaEnMovimiento.lua
local PANEL_GLOBAL_ID = {
    lastLap = 1,
    podium = 2,
    flPanel = 3,
    results = 4,
}

local globalDragging = false
local globalDragPanelId = 0

panelDragStateEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Drag State"),
    dragging = ac.StructItem.boolean(),
    panelId = ac.StructItem.float()
}, function(sender, message)
    -- Solo reacciona a MI PROPIO arrastre, no al de otros jugadores que puedan estar
    -- editando sus carteles al mismo tiempo -- esto es una preferencia visual personal,
    -- no algo que deba afectar la pantalla de nadie más.
    if sender:driverName() ~= car:driverName() then return end
    globalDragging = message.dragging
    globalDragPanelId = message.panelId
end,
ac.SharedNamespace.ServerScript)

-- Un cartel se oculta si HAY un arrastre en curso Y no es el que se está arrastrando
local function shouldHideForDrag(id)
    return globalDragging and globalDragPanelId ~= PANEL_GLOBAL_ID[id]
end

-- ===== Sistema de arrastre centralizado: un único "dueño" del click a la vez =====
-- En vez de que cada cartel decida por su cuenta si el click es suyo (lo que podía fallar
-- si dos hitboxes se superponían), acá se decide en un solo lugar: el PRIMER cartel cuyo
-- rectángulo contiene el click en el momento en que se presiona el mouse se queda con el
-- arrastre completo, y ningún otro cartel puede "sumarse" hasta soltar el botón.
local activeDragTarget = nil -- nil, o "flPanel" / "lastLap" / "podium" / "results"
local dragOffsetX, dragOffsetY = 0, 0

-- Devuelve la posición actual (x,y de la esquina superior izquierda) de un cartel, y si
-- corresponde, actualiza esa posición por el arrastre. "centered" = true si fieldX/fieldY
-- guardan el CENTRO del cartel en vez del borde izquierdo.
local function panelXY(id, fieldX, fieldY, panelWidth, panelHeight, centered, mp, mouseIsDown)
    local baseX = centered and (panelPositions[fieldX] * screen.w - panelWidth * 0.5) or (panelPositions[fieldX] * screen.w)
    local baseY = panelPositions[fieldY] * screen.h

    if mp == nil then return baseX, baseY end

    if activeDragTarget == nil then
        if mouseIsDown then
            local overPanel = mp.x >= baseX and mp.x <= baseX + panelWidth and mp.y >= baseY and mp.y <= baseY + panelHeight
            if overPanel then
                activeDragTarget = id
                dragOffsetX = mp.x - baseX
                dragOffsetY = mp.y - baseY
                panelDragStateEvent({ dragging = true, panelId = PANEL_GLOBAL_ID[id] })
            end
        end
    elseif activeDragTarget == id then
        if mouseIsDown then
            baseX = mp.x - dragOffsetX
            baseY = mp.y - dragOffsetY
            panelPositions[fieldX] = centered and ((baseX + panelWidth * 0.5) / screen.w) or (baseX / screen.w)
            panelPositions[fieldY] = baseY / screen.h
        else
            activeDragTarget = nil
            panelDragStateEvent({ dragging = false, panelId = 0 })
        end
    end

    return baseX, baseY
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
    -- Cartel de "ÚLTIMA VUELTA" (arriba centrado, estilo "LEADER IS ON FINAL LAP" nativo,
    -- persistente hasta que se confirme el ganador, no por tiempo fijo)
    ------------------------------------------------
    local showLastLapBanner = (raceLastLapAnnounced and not raceWon) or previewMode
    if showLastLapBanner then
        banner.alpha = math.min(banner.alpha + 0.10, 1)
    else
        banner.alpha = math.max(banner.alpha - 0.10, 0)
    end

    if banner.alpha > 0 and not shouldHideForDrag("lastLap") then
        local a = banner.alpha
        ui.pushFont(ui.Font.Title)
        local text = "🏁  ÚLTIMA VUELTA"
        local textSize = ui.measureText(text)
        local panelWidth = textSize.x + 80
        local panelHeight = 60

        local mp = getMousePos()
        local mouseIsDown = isMouseButtonDown()
        local x, y = panelXY("lastLap", "lastLapX", "lastLapY", panelWidth, panelHeight, true, mp, mouseIsDown)

        -- Fondo con transparencia normal: ya no busca tapar nada, solo mostrarse debajo
        ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0.05, 0.05, 0.05, 0.9 * a))
        ui.setCursor(vec2(x + (panelWidth - textSize.x) * 0.5, y + (panelHeight - textSize.y) * 0.5))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, a))
        ui.text(text)
        ui.popStyleColor()
        ui.popFont()
    end

    ------------------------------------------------
    -- Cartel grande centrado del podio (P1/P2/P3), aparece uno atrás del otro
    ------------------------------------------------
    if podiumBanner.timer > 0 or previewMode then
        podiumBanner.alpha = math.min(podiumBanner.alpha + 0.10, 1)
    else
        podiumBanner.alpha = math.max(podiumBanner.alpha - 0.10, 0)
    end

    if podiumBanner.alpha > 0 and not shouldHideForDrag("podium") then
        local a = podiumBanner.alpha
        local c = previewMode and rgbm(1.0, 0.78, 0.05, 1) or podiumBanner.color
        local label = previewMode and "GANADOR DE LA CARRERA" or podiumBanner.label
        local value = previewMode and "PILOTO DE EJEMPLO" or podiumBanner.value
        local icon = previewMode and "🏆" or podiumBanner.icon
        local panelWidth = 620
        local panelHeight = 96

        local mp = getMousePos()
        local mouseIsDown = isMouseButtonDown()
        local x, y = panelXY("podium", "podiumX", "podiumY", panelWidth, panelHeight, true, mp, mouseIsDown)

        ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0, 0, 0, 0.85 * a), 10)
        ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(c.r, c.g, c.b, a), 10, 0, 3)

        ui.pushFont(ui.Font.Small)
        local labelText = (icon ~= "" and (icon .. "  ") or "") .. string.upper(label)
        local labelSize = ui.measureText(labelText)
        ui.setCursor(vec2(x + (panelWidth - labelSize.x) * 0.5, y + 16))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(c.r, c.g, c.b, a))
        ui.text(labelText)
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(ui.Font.Title)
        local valueText = string.upper(value)
        local valueSize = ui.measureText(valueText)
        ui.setCursor(vec2(x + (panelWidth - valueSize.x) * 0.5, y + 46))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, a))
        ui.text(valueText)
        ui.popStyleColor()
        ui.popFont()
    end

    ------------------------------------------------
    -- Panel de "VUELTA RAPIDA" (arriba a la derecha por defecto, arrastrable, estilo nativo de AC)
    ------------------------------------------------
    if ((fastestLap.driver ~= nil and fastestLap.displayTimer > 0) or previewMode) and not shouldHideForDrag("flPanel") then
        local displayDriver = previewMode and "PILOTO DE EJEMPLO" or fastestLap.driver
        local displayTime = previewMode and 90123 or fastestLap.timeMs
        local panelWidth = 260
        local panelHeight = 70

        local mp = getMousePos()
        local mouseIsDown = isMouseButtonDown()
        local baseX, baseY = panelXY("flPanel", "flX", "flY", panelWidth, panelHeight, false, mp, mouseIsDown)

        local t = 1 - (fastestLap.animTimer / FL_ANIM_DURATION)
        local eased = easeOutCubic(t)
        local slide = (1 - eased) * 70 -- entra deslizándose desde la derecha

        local x = baseX + slide
        local y = baseY

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
        ui.text(string.upper(displayDriver))
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(ui.Font.Small)
        ui.setCursor(vec2(badgeX + badgeSize + 10, y + 48))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.75, 0.75, 0.78, 1))
        ui.text(msToTimeString(displayTime))
        ui.popStyleColor()
        ui.popFont()
    end

    ------------------------------------------------
    -- Lista de resultados (persistente, crece con cada piloto que llega)
    ------------------------------------------------
    local rowHeight = 34
    local panelWidth = 260
    local listPanelHeightForDrag = rowHeight * (previewMode and 3 or RESULTS_MAX_SLOTS)
    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()
    local resultsX, resultsY = panelXY("results", "resultsX", "resultsY", panelWidth, listPanelHeightForDrag, false, mp, mouseIsDown)

    -- En modo edición, si todavía no hay resultados reales, se arman 3 filas de ejemplo
    local displaySlots = resultsSlots
    if previewMode and #finishRecords == 0 then
        displaySlots = {
            [1] = { rank = 1, name = "PILOTO EJEMPLO 1", animTimer = 0 },
            [2] = { rank = 2, name = "PILOTO EJEMPLO 2", animTimer = 0 },
            [3] = { rank = 3, name = "PILOTO EJEMPLO 3", animTimer = 0 },
        }
    end

    for slot = 1, RESULTS_MAX_SLOTS do
        local entry = displaySlots[slot]
        if entry and not shouldHideForDrag("results") then
            local t = 1 - (entry.animTimer / RESULT_ANIM_DURATION)
            local eased = easeOutCubic(t)
            local slide = (1 - eased) * 70

            local rowY = resultsY + (slot - 1) * rowHeight
            local x = resultsX + slide
            local color = getRankColor(entry.rank)

            ui.drawRectFilled(vec2(x, rowY), vec2(x + panelWidth, rowY + rowHeight - 4), rgbm(0.04, 0.04, 0.05, 0.90), 4)

            local badgeSize = 22
            local badgeX = x + 6
            local badgeY = rowY + (rowHeight - 4 - badgeSize) * 0.5
            ui.drawRectFilled(vec2(badgeX, badgeY), vec2(badgeX + badgeSize, badgeY + badgeSize), color, 3)
            ui.pushFont(ui.Font.Small)
            local rankText = tostring(entry.rank) -- muestra el puesto REAL (ej "16"), aunque esté en el lugar visual del 1
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
end

function script.update(dt)
    -- Vigila la validez de la vuelta en curso en TODOS los frames (ver nota arriba de
    -- currentLapHadInvalidMoment sobre por qué no alcanza con chequearlo al completar la vuelta)
    if not isLapValid() then
        currentLapHadInvalidMoment = true
    end

    if podiumBanner.timer > 0 then
        podiumBanner.timer = podiumBanner.timer - dt
    elseif #podiumBannerQueue > 0 then
        local nxt = table.remove(podiumBannerQueue, 1)
        podiumBanner.label = nxt.label
        podiumBanner.value = nxt.value
        podiumBanner.icon = nxt.icon
        podiumBanner.color = nxt.color
        podiumBanner.timer = nxt.duration
    end

    if fastestLap.animTimer > 0 then
        fastestLap.animTimer = math.max(fastestLap.animTimer - dt, 0)
    end
    if fastestLap.displayTimer > 0 then
        fastestLap.displayTimer = math.max(fastestLap.displayTimer - dt, 0)
    end

    for slot = 1, RESULTS_MAX_SLOTS do
        local entry = resultsSlots[slot]
        if entry and entry.animTimer > 0 then
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
        raceWon = false
        fastestLap.driver = nil
        fastestLap.timeMs = nil
        fastestLap.animTimer = 0
        fastestLap.displayTimer = 0
        resultsSlots = {}
        podiumBanner.timer = 0
        podiumBannerQueue = {}
        prevLapCount = 0 -- CRÍTICO: sin esto, la condición de arriba se queda pegada en true para siempre
        currentLapHadInvalidMoment = false
        ac.log("[ANNOUNCE] Nueva carrera detectada (lapCount volvió a 0), estado reseteado")
    end

    -- Chequeo de fin de carrera: se evalúa cada frame, no solo al completar una vuelta,
    -- por si el teletransporte a pits al terminar la sesión corta la ejecución justo
    -- en el frame donde se incrementa el contador de vueltas.
    local totalLaps = getTotalLaps()
    local isRaceSession = (sim.raceSessionType == ac.SessionType.Race)
    if raceLapsSeenZero and isRaceSession and totalLaps ~= nil and car.lapCount >= totalLaps and not myFinishAnnounced and not isCarInPit() then
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

    -- Última vuelta: aviso único para toda la carrera, apenas el PRIMERO (el líder) entra a su vuelta final.
    -- Queda visible hasta que se confirme el ganador (raceWon), no por un tiempo fijo.
    if raceLapsSeenZero and isRaceSession and totalLaps ~= nil and totalLaps > 1
        and car.lapCount == totalLaps - 1 and not raceLastLapAnnounced then
        raceLastLapAnnounced = true
        table.insert(pendingChats, "🏁 ÚLTIMA VUELTA!")
        lastLapEvent({})
        ac.log("[ANNOUNCE] Última vuelta de la carrera anunciada (líder detectado por " .. car:driverName() .. ")")
    end

    if car.lapCount > prevLapCount then
        local completedLap = prevLapCount + 1
        prevLapCount = car.lapCount

        ac.log("[ANNOUNCE] Vuelta completada: " .. completedLap .. " | car.lapCount=" .. car.lapCount ..
            " | totalLaps=" .. tostring(totalLaps) .. " | myFinishAnnounced=" .. tostring(myFinishAnnounced))

        -- Chequeo de ganador redundante: se repite acá (además del chequeo aislado de arriba)
        -- porque este bloque confirmadamente se ejecuta con el valor correcto de car.lapCount
        -- justo en el momento en que se completa la vuelta, sin depender de que otro chequeo
        -- llegue a tiempo antes de un posible reset/teletransporte.
        if raceLapsSeenZero and isRaceSession and totalLaps ~= nil and car.lapCount >= totalLaps and not myFinishAnnounced and not isCarInPit() then
            myFinishAnnounced = true
            local myFinishTime = sim.currentSessionTime
            addFinishRecord(car:driverName(), myFinishTime)
            raceFinishedEvent({ finishTime = myFinishTime })
            ac.log("[ANNOUNCE] Mi llegada detectada (redundante, lapCount=" .. car.lapCount .. ", totalLaps=" .. totalLaps .. "), evento enviado")
        end

        local lapTimeMs = getLastLapTime()
        local lapValid = not currentLapHadInvalidMoment
        ac.log("[ANNOUNCE] Validez de la vuelta " .. completedLap .. ": " .. tostring(lapValid))
        currentLapHadInvalidMoment = false -- arranca limpia la vuelta nueva

        if lapTimeMs ~= nil and lapValid then
            addLapCandidate(car:driverName(), lapTimeMs)
            lapCompletedEvent({ lapTimeMs = lapTimeMs, lapNumber = completedLap })
        end
    end
end
