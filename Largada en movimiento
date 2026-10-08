local health = { t = 0, lastDraw = 0, welcome = false } -- autodiagnóstico, ver el final del archivo
sim = ac.getSim()
car = ac.getCar(0)

local adminFlag = ui.OnlineExtraFlags.Admin

-- ===== Modo de edición compartido: mismo evento que el resto de los scripts. Este cartel es
-- el ID 9 -- solo se muestra cuando el menú lo tiene seleccionado. =====
local editingPanelId = 0
local MY_PREVIEW_ID = 9
panelPreviewEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Preview Mode"),
    selectedId = ac.StructItem.float()
}, function(sender, message)
    if sender:driverName() ~= car:driverName() then return end
    editingPanelId = message.selectedId
end,
ac.SharedNamespace.ServerScript)

-- ===== Ocultar todos los carteles de todos los scripts menos el que se está arrastrando =====
-- ID global de este cartel: 9 (ver la lista completa de IDs en announcements.lua)
local MY_PANEL_ID = 9
local globalDragging = false
local globalDragPanelId = 0

panelDragStateEvent5 = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Drag State"),
    dragging = ac.StructItem.boolean(),
    panelId = ac.StructItem.float()
}, function(sender, message)
    if sender:driverName() ~= car:driverName() then return end
    globalDragging = message.dragging
    globalDragPanelId = message.panelId
end,
ac.SharedNamespace.ServerScript)

local function shouldHideForDrag()
    return globalDragging and globalDragPanelId ~= MY_PANEL_ID
end

-- Fases: "off" | "yellow" (safety car, vel. libre) | "sequence" (roja -> verde, con límite)
local phase = "off"
local state = { alpha = 0 }

-- Config (se sobreescribe desde Extra Options, sección [ROLLINGSTART])
local maxSpeed = 80
local speedMargin = 3
local restrictorDuration = 3
local restrictorValue = 1.0
local greenHoldTime = 1.5      -- segundos que dura el flash verde antes de apagarse
local seqDuration = 17000      -- ms desde el click hasta que la última luz roja está encendida
local seqStartTime = 12000     -- ms desde el click hasta que se enciende la 1ra luz roja
local lightsOutMin, lightsOutMax = 3000, 5000 -- rango de espera aleatoria tras completar las rojas, antes del verde

-- Estado interno de la secuencia (sincronizado por evento)
local startTime = 0
local delayTime = 0
local greenForced = false -- true apenas CUALQUIER cliente detecta o recibe aviso de que llegó el verde
local greenForcedAt = 0   -- sim.currentSessionTime local en el momento en que se tomó el verde (evita drift de reloj entre clientes)

-- Cola de reenvíos del disparo de la secuencia (mismo mecanismo que en startLights.lua): se
-- manda varias veces, distribuidas en varios segundos, para que a alguien con un corte de
-- conexión puntual igual le llegue alguna copia. Como el mensaje lleva un horario ABSOLUTO,
-- reenviarlo más tarde no desincroniza a nadie.
local resendQueue = {}
local function scheduleResend(payload, delaySeconds)
    table.insert(resendQueue, { timer = delaySeconds, payload = payload })
end

-- Estado interno del restrictor
local restrictorActive = false
local restrictorTimer = 0
local overSpeedFlag = false
local greenCheckDone = false -- asegura que el chequeo de velocidad al dar el verde se haga una sola vez por secuencia

-- ===== Ranking de tiempo de reacción al apagar el pit limiter tras el verde =====
-- Mide cuánto tarda CADA piloto en desactivar el limitador de pits después de que se da la
-- largada, y arma una tabla con todos los que reportaron. Se guarda localmente (ac.storage)
-- para poder revisarla después de la carrera aunque ya no esté el semáforo en pantalla, o
-- incluso después de reconectar.
local pitLimiterArmed = false       -- true mientras se espera que ESTE piloto apague el limitador
local pitLimiterReported = false    -- evita contar dos veces la misma secuencia
local pitLimiterWasOn = false       -- confirma que el limitador estuvo encendido antes de apagarse
local pitLimiterStartTime = 0
local prevGreenForcedForPitLimiter = false

local pitLimiterResults = {}        -- array ordenado: { {name=.., ms=..}, ... }
local pitLimiterIndexByName = {}    -- nombre de piloto -> posición en pitLimiterResults

-- Prefijo propio para que esta tabla no comparta claves con posCfg (la posición del cartel
-- principal), que se guarda con otra llamada a ac.storage más abajo en este archivo.
local pitLimiterStorage = ac.storage({ resultsJSON = "" }, "pitLimiterResults")

local function savePitLimiterResults()
    pcall(function()
        pitLimiterStorage.resultsJSON = stringify(pitLimiterResults, true)
    end)
end

local function loadPitLimiterResults()
    pcall(function()
        if pitLimiterStorage.resultsJSON ~= "" then
            local loaded = stringify.tryParse(pitLimiterStorage.resultsJSON, nil, nil)
            if type(loaded) == "table" then
                pitLimiterResults = loaded
                pitLimiterIndexByName = {}
                for i, entry in ipairs(pitLimiterResults) do
                    if entry and entry.name then
                        pitLimiterIndexByName[entry.name] = i
                    end
                end
            end
        end
    end)
end
loadPitLimiterResults()

-- No hay cartel en pantalla para esto a propósito -- el pedido fue que quede un REGISTRO
-- guardado (acá, en el log de CSP y en ac.storage), no una ventana visible. Para revisarlo
-- después de la carrera: Documents/Assetto Corsa/logs/custom_shaders_patch.log, buscando
-- "[ROLLINGSTART] Ranking".
local function dumpPitLimiterRanking()
    pcall(function()
        ac.log("[ROLLINGSTART] ===== Ranking tiempo de reacción al pit limiter =====")
        if #pitLimiterResults == 0 then
            ac.log("[ROLLINGSTART]   (todavía sin datos)")
        end
        for i, entry in ipairs(pitLimiterResults) do
            ac.log(string.format("[ROLLINGSTART]   %d. %s - %.2f s", i, tostring(entry.name), entry.ms / 1000))
        end
    end)
end

local function registerPitLimiterResult(name, ms)
    if name == nil then return end
    ms = math.max(0, math.floor((tonumber(ms) or 0) + 0.5))
    local idx = pitLimiterIndexByName[name]
    if idx then
        pitLimiterResults[idx].ms = ms
    else
        table.insert(pitLimiterResults, { name = name, ms = ms })
    end
    table.sort(pitLimiterResults, function(a, b) return a.ms < b.ms end)
    pitLimiterIndexByName = {}
    for i, entry in ipairs(pitLimiterResults) do
        pitLimiterIndexByName[entry.name] = i
    end
    savePitLimiterResults()
    ac.log(string.format("[ROLLINGSTART] %s reaccionó al pit limiter en %.2f s", tostring(name), ms / 1000))
    dumpPitLimiterRanking()
end

-- Sonido
local beepURL = ""
local beepSound = nil
local soundVolumeMultiplier = 2.5
local speedSignURL = ""

-- Sonido dedicado para el momento del verde -- así, aunque el cartel/semáforo no llegue a
-- verse por el bug conocido de CSP/apps, el piloto se entera igual por el audio.
local greenSoundURL = ""
local greenSound = nil

-- Sonido dedicado para cuando se enciende la TERCERA luz roja -- distinto del beep de cada
-- luz, se dispara una sola vez por secuencia (mismo mecanismo de flanco que ya usa el beep).
local thirdRedSoundURL = ""
local thirdRedSound = nil

-- Declaración adelantada: las funciones que realmente reproducen cada sonido se definen más
-- abajo en el archivo, pero "greenNowEvent" (al que le sigue, unas líneas más abajo) necesita
-- poder llamarlas. Sin esto, Lua no las ve como upvalue y la llamada busca una variable
-- GLOBAL con ese nombre -- que no existe -- y revienta en silencio apenas llega el evento.
-- (Así se había colado el bug de "playSound(greenSound, ...)": esa función nunca existió.)
local playBeep, playGreenSound, playThirdRedSound

local title = "LARGADA EN MOVIMIENTO"

local lightCount = 6
local neonRed = rgbm(1.6, 0.05, 0.05, 1)
local neonGreen = rgbm(0.05, 1.8, 0.1, 1)
local neonYellow = rgbm(1.6, 1.1, 0.05, 1)

-- Estado de las luces, calculado una vez por frame en script.update y usado por drawGantry
local litMode = "red" -- "yellow" | "red" | "green"
local lightsOn = {}
local prevLightsOn = {}
for i = 1, lightCount, 1 do
    lightsOn[i] = false
    prevLightsOn[i] = false
end

local screen = {
    w = sim.windowWidth,
    h = sim.windowHeight
}

-- Diagnóstico: lista los ac.PenaltyType disponibles al conectar
local penaltyTypesLogged = false
local function logAvailablePenaltyTypes()
    if penaltyTypesLogged then return end
    penaltyTypesLogged = true
    pcall(function()
        local names = {}
        for k, v in pairs(ac.PenaltyType) do
            table.insert(names, tostring(k) .. "=" .. tostring(v))
        end
        ac.log("[ROLLINGSTART] ac.PenaltyType disponibles: " .. table.concat(names, ", "))
    end)
end

local function resetLightEdges()
    for i = 1, lightCount, 1 do
        prevLightsOn[i] = false
    end
end

greenNowEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Rolling Start Green Now")
}, function(sender, message)
    if not greenForced then
        greenForced = true
        greenForcedAt = sim.currentSessionTime
        -- Nota: acá había un llamado a una función "playSound(greenSound, ...)" que no existe
        -- en este archivo (la real es "playGreenSound()", sin argumentos) -- nunca sonaba el
        -- verde cuando llegaba avisado por otro cliente. Corregido de paso.
        playGreenSound()
    end
end,
ac.SharedNamespace.ServerScript)

rollingStartEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Rolling Start"),
    phase = ac.StructItem.float(),     -- 0 = off, 1 = yellow, 2 = sequence
    startTime = ac.StructItem.float(),
    delayTime = ac.StructItem.float()
}, function(sender, message)
    -- Si startTime/delayTime son IDÉNTICOS a los que ya tenía guardados para esta fase, es
    -- un reenvío duplicado del mismo comando (no uno nuevo) -- no hay que reiniciar el
    -- estado, si no un reenvío tardío que llega DESPUÉS de que ya se pasó a verde podría
    -- resetear todo por error y volver a fase "sequence".
    local isDuplicate = (message.phase == 2 and phase == "sequence" and
        startTime == message.startTime and delayTime == message.delayTime)

    if message.phase == 1 then
        phase = "yellow"
        resetLightEdges()
    elseif message.phase == 2 then
        if not isDuplicate then
            phase = "sequence"
            startTime = message.startTime
            delayTime = message.delayTime
            overSpeedFlag = false
            greenCheckDone = false
            greenForced = false
            resetLightEdges()

            -- Nueva largada -> se limpia el ranking de la anterior, así la tabla que se ve
            -- "después de la carrera" es siempre la de la carrera que se acaba de correr.
            pitLimiterArmed = false
            pitLimiterReported = false
            pitLimiterWasOn = false
            pitLimiterResults = {}
            pitLimiterIndexByName = {}
            savePitLimiterResults()
        end
    else
        phase = "off"
        restrictorActive = false
        restrictorTimer = 0
    end
    ac.log("[ROLLINGSTART] " .. sender:driverName() .. " -> fase: " .. phase .. (isDuplicate and " (duplicado, ignorado)" or ""))
end,
ac.SharedNamespace.ServerScript)

-- Cada cliente, al detectar que APAGÓ su propio limitador, transmite su tiempo de reacción.
-- Todos (incluido el que lo manda, por el eco del propio evento) lo guardan en su tabla local,
-- así cualquiera puede abrir el cartel de ranking y ver a todos los que reportaron.
pitLimiterReactionEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Pit Limiter Reaction"),
    ms = ac.StructItem.float()
}, function(sender, message)
    local okName, name = pcall(function() return sender:driverName() end)
    if okName then
        registerPitLimiterResult(name, message.ms)
    end
end,
ac.SharedNamespace.ServerScript)

ac.onResolutionChange(function()
    screen.w = ac.getSim().windowWidth
    screen.h = ac.getSim().windowHeight
end)

ac.onOnlineWelcome(function(message, config)
    if config:get("ROLLINGSTART", "ADMIN_ONLY", 1) == 0 then
        adminFlag = ui.OnlineExtraFlags.None
    else
        adminFlag = ui.OnlineExtraFlags.Admin
    end

    maxSpeed = config:get("ROLLINGSTART", "MAX_SPEED_KMH", 80)
    speedMargin = config:get("ROLLINGSTART", "SPEED_MARGIN_KMH", 3)
    restrictorDuration = config:get("ROLLINGSTART", "RESTRICTOR_DURATION", 3)
    restrictorValue = config:get("ROLLINGSTART", "RESTRICTOR_VALUE", 1.0)
    greenHoldTime = config:get("ROLLINGSTART", "GREEN_HOLD_TIME", 1.5)
    seqDuration = config:get("ROLLINGSTART", "SEQUENCE_LENGTH", 17) * 1000
    seqStartTime = config:get("ROLLINGSTART", "SEQUENCE_START", 12) * 1000
    lightsOutMin = config:get("ROLLINGSTART", "RANDOM_DELAY_RANGE", 3, 1) * 1000
    lightsOutMax = config:get("ROLLINGSTART", "RANDOM_DELAY_RANGE", 5, 2) * 1000

    speedSignURL = config:get("ROLLINGSTART", "SPEED_SIGN_URL", "")
    beepURL = config:get("ROLLINGSTART", "SOUND_BEEP_URL", "")
    soundVolumeMultiplier = config:get("ROLLINGSTART", "SOUND_VOLUME_MULTIPLIER", 2.5)
    if beepURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(beepURL) end)
        if ok then
            beepSound = result
            ac.log("[ROLLINGSTART] Beep sound cargado OK: " .. beepURL)
        else
            ac.log("[ROLLINGSTART] ERROR cargando beep sound (" .. beepURL .. "): " .. tostring(result))
        end
    end

    -- Sonido al darse el verde -- faltaba cargarlo (las variables y la reproducción ya
    -- estaban armadas, pero nunca se leía la URL ni se inicializaba el reproductor, así que
    -- nunca sonaba). Así, aunque el cartel no llegue a verse por el bug conocido de
    -- CSP/apps, el piloto se entera igual por el audio.
    greenSoundURL = config:get("ROLLINGSTART", "GREEN_SOUND_URL", "")
    if greenSoundURL ~= "" then
        local okGreen, resultGreen = pcall(function() return ui.MediaPlayer(greenSoundURL) end)
        if okGreen then
            greenSound = resultGreen
            ac.log("[ROLLINGSTART] Green sound cargado OK: " .. greenSoundURL)
        else
            ac.log("[ROLLINGSTART] ERROR cargando green sound (" .. greenSoundURL .. "): " .. tostring(resultGreen))
        end
    end

    -- Sonido dedicado para cuando se enciende la 3ra luz roja (aviso de "ya casi" antes del
    -- verde). Se agrega aparte del beep normal de cada luz, no lo reemplaza.
    thirdRedSoundURL = config:get("ROLLINGSTART", "THIRD_RED_SOUND_URL", "")
    if thirdRedSoundURL ~= "" then
        local okThirdRed, resultThirdRed = pcall(function() return ui.MediaPlayer(thirdRedSoundURL) end)
        if okThirdRed then
            thirdRedSound = resultThirdRed
            ac.log("[ROLLINGSTART] Third red sound cargado OK: " .. thirdRedSoundURL)
        else
            ac.log("[ROLLINGSTART] ERROR cargando third red sound (" .. thirdRedSoundURL .. "): " .. tostring(resultThirdRed))
        end
    end

local function startSequence()
    local st = sim.currentSessionTime + seqDuration
    local dt = math.random(lightsOutMin, lightsOutMax)
    phase = "sequence"
    startTime = st
    delayTime = dt
    overSpeedFlag = false
    greenCheckDone = false
    greenForced = false
    resetLightEdges()
    local payload = { phase = 2, startTime = st, delayTime = dt }
    rollingStartEvent(payload)
    -- Reenvíos distribuidos en varios segundos, mismo mecanismo que startLights.lua
    scheduleResend(payload, 0.2)
    scheduleResend(payload, 0.5)
    scheduleResend(payload, 1)
    scheduleResend(payload, 2)
    scheduleResend(payload, 4)
    scheduleResend(payload, 7)
    ac.log("[ROLLINGSTART] Secuencia iniciada -> fase: sequence")
end

local lineCrossingHooked = false
local function hookLineCrossing()
    if lineCrossingHooked then return end
    lineCrossingHooked = true
    local ok, err = pcall(function()
        ac.onTrackPointCrossed(0, 0, function()
            if phase == "yellow" then
                ac.log("[ROLLINGSTART] Línea de meta cruzada, iniciando secuencia automáticamente")
                startSequence()
            end
        end)
    end)
    if ok then
        ac.log("[ROLLINGSTART] Detección de cruce de línea activada (ac.onTrackPointCrossed)")
    else
        ac.log("[ROLLINGSTART] ERROR activando detección de cruce de línea: " .. tostring(err))
    end
end

ui.registerOnlineExtra(
        ui.Icons.Warning,
        "🚦 Largada en Movimiento",
        function() return true end,
        nil,
        function()
            if phase == "off" then
                phase = "yellow"
                resetLightEdges()
                rollingStartEvent({ phase = 1, startTime = 0, delayTime = 0 })
            elseif phase == "yellow" then
                startSequence()
            else
                -- Ya en secuencia: cancelar y volver a apagado
                phase = "off"
                restrictorActive = false
                restrictorTimer = 0
                rollingStartEvent({ phase = 0, startTime = 0, delayTime = 0 })
            end
            ac.log("[ROLLINGSTART] Click admin -> fase: " .. phase)
        end,
        adminFlag
    )

    logAvailablePenaltyTypes()
    hookLineCrossing()
end)

local function applyRestrictor(value)
    local attempts = {}
    if ac.PenaltyType.Restrictor ~= nil then
        table.insert(attempts, function() physics.setCarPenalty(ac.PenaltyType.Restrictor, value) end)
    end
    if ac.PenaltyType.EngineRestrictor ~= nil then
        table.insert(attempts, function() physics.setCarPenalty(ac.PenaltyType.EngineRestrictor, value) end)
    end
    table.insert(attempts, function() ac.setCarRestrictor(0, value) end)
    table.insert(attempts, function() physics.setExtraRestrictor(value) end)

    for _, fn in ipairs(attempts) do
        local ok = pcall(fn)
        if ok then return true end
    end

    -- Respaldo: bloquea la caja de cambios (te deja sin poder meter marcha)
    pcall(function() physics.lockUserGearboxFor(restrictorDuration, true) end)
    return false
end

function playBeep()
    if not beepSound then return end
    local ok, err = pcall(function()
        beepSound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
        beepSound:play()
    end)
    if not ok then
        ac.log("[ROLLINGSTART] ERROR reproduciendo beep: " .. tostring(err))
    end
end

function playGreenSound()
    if not greenSound then return end
    local ok, err = pcall(function()
        greenSound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
        greenSound:play()
    end)
    if not ok then
        ac.log("[ROLLINGSTART] ERROR reproduciendo sonido de verde: " .. tostring(err))
    end
end

function playThirdRedSound()
    if not thirdRedSound then return end
    local ok, err = pcall(function()
        thirdRedSound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
        thirdRedSound:play()
    end)
    if not ok then
        ac.log("[ROLLINGSTART] ERROR reproduciendo sonido de 3ra luz roja: " .. tostring(err))
    end
end

function script.update(dt)
    health.t = health.t + dt
    if health.tick then health.tick(dt) end
    -- Se actualiza el ancho/alto de pantalla TODOS los cuadros -- ver nota igual en el resto
    -- de los scripts del proyecto sobre por qué (posible causa de carteles invisibles tras
    -- cambiar de cámara a otro auto).
    screen.w = sim.windowWidth
    screen.h = sim.windowHeight

    for i = #resendQueue, 1, -1 do
        local item = resendQueue[i]
        item.timer = item.timer - dt
        if item.timer <= 0 then
            rollingStartEvent(item.payload)
            table.remove(resendQueue, i)
        end
    end

    -- Fade del conjunto (semáforo + panel)
    local fadeSpeed = 3.5
    if phase ~= "off" or editingPanelId == MY_PREVIEW_ID then
        state.alpha = math.min(state.alpha + dt * fadeSpeed, 1)
    else
        state.alpha = math.max(state.alpha - dt * fadeSpeed, 0)
    end

    -- Calcula el estado de las luces (una vez por frame, usado también para el sonido)
    if phase == "yellow" then
        litMode = "yellow"
        local blinkOn = math.floor(sim.currentSessionTime / 400) % 2 == 0
        for i = 1, lightCount, 1 do
            lightsOn[i] = blinkOn
        end
    elseif phase == "sequence" then
        -- Detecta el momento del verde una sola vez y lo comparte con todos los demás clientes,
        -- para que el corte rojo/verde no dependa del reloj individual de cada uno.
        if not greenForced and sim.currentSessionTime >= startTime + delayTime then
            greenForced = true
            greenForcedAt = sim.currentSessionTime
            playGreenSound()
            greenNowEvent({})
        end

        if not greenForced then
            litMode = "red"
            for i = 1, lightCount, 1 do
                local isOn = sim.currentSessionTime > startTime - seqDuration + seqStartTime + ((seqDuration - seqStartTime) / lightCount) * i
                if isOn and not prevLightsOn[i] then
                    playBeep()
                    if i == lightCount then
                        -- Sonido aparte, una sola vez, justo cuando se enciende la ÚLTIMA roja
                        -- (lightCount, no un número fijo, para que siga siendo "la última" si
                        -- en algún momento se cambia la cantidad de luces del semáforo)
                        playThirdRedSound()
                    end
                end
                lightsOn[i] = isOn
            end
        else
            litMode = "green"
            local blinkOn = math.floor(sim.currentSessionTime / 180) % 2 == 0
            for i = 1, lightCount, 1 do
                lightsOn[i] = blinkOn
            end
        end
    else
        for i = 1, lightCount, 1 do
            lightsOn[i] = false
        end
    end
    for i = 1, lightCount, 1 do
        prevLightsOn[i] = lightsOn[i]
    end

    if phase == "sequence" then
        if not greenForced then
            -- Fase roja: sin control todavía
        else
            -- Se dio el verde: chequeo único de si se mantuvo el ritmo de 80 km/h
            if not greenCheckDone then
                greenCheckDone = true
                if car.speedKmh > maxSpeed + speedMargin then
                    ac.sendChatMessage(
                        car:driverName() ..
                        " superó los " .. maxSpeed .. " km/h al darse la largada. Restrictor aplicado."
                    )
                    applyRestrictor(restrictorValue)
                    restrictorActive = true
                    restrictorTimer = restrictorDuration
                end
            end

            if restrictorTimer > 0 then
                restrictorTimer = restrictorTimer - dt
                if restrictorTimer <= 0 then
                    restrictorTimer = 0
                    restrictorActive = false
                    applyRestrictor(0)
                end
            end

            -- Tras el tiempo de flash verde, todo vuelve a apagarse solo
            if sim.currentSessionTime > greenForcedAt + greenHoldTime * 1000 then
                phase = "off"
                if restrictorActive or restrictorTimer > 0 then
                    restrictorActive = false
                    restrictorTimer = 0
                    applyRestrictor(0)
                end
            end
        end
    end

    -- ===== Ranking de reacción al pit limiter: se calcula aparte de "phase", porque "phase"
    -- vuelve a "off" a los pocos segundos del verde (greenHoldTime) y acá hace falta seguir
    -- esperando a que el piloto apague el limitador más allá de ese momento. =====
    if greenForced and not prevGreenForcedForPitLimiter then
        pitLimiterArmed = true
        pitLimiterReported = false
        pitLimiterStartTime = greenForcedAt
        local okInitial, initialOn = pcall(function() return car.manualPitsSpeedLimiterEnabled end)
        pitLimiterWasOn = okInitial and initialOn or false
    end
    prevGreenForcedForPitLimiter = greenForced

    if pitLimiterArmed and not pitLimiterReported then
        local okLimiter, limiterOn = pcall(function() return car.manualPitsSpeedLimiterEnabled end)
        if okLimiter then
            if limiterOn then
                pitLimiterWasOn = true
            elseif pitLimiterWasOn then
                pitLimiterReported = true
                local reactionMs = math.max(0, sim.currentSessionTime - pitLimiterStartTime)
                pitLimiterReactionEvent({ ms = reactionMs })
            end
        end
    end
end

local function alphaColor(r, g, b, mult)
    return rgbm(r, g, b, state.alpha * (mult or 1))
end

-- Cartel de límite de velocidad "80", estilo cartel de tránsito real (círculo rojo, centro
-- claro, número negro grueso) -- se muestra desde que terminan las intermitentes amarillas
-- (arranca la secuencia de rojos) hasta que se da el verde, como recordatorio de mantener el
-- ritmo controlado mientras se preparan para largar.
local function drawSpeedLimitSign(centerX, centerY, radius)
    ui.drawCircleFilled(vec2(centerX, centerY), radius, alphaColor(0.85, 0.1, 0.08, 1), 48)
    ui.drawCircleFilled(vec2(centerX, centerY), radius * 0.78, alphaColor(0.96, 0.96, 0.94, 1), 48)

    ui.pushFont(ui.Font.Huge)
    local text = "80"
    local textSize = ui.measureText(text)
    ui.setCursor(vec2(centerX - textSize.x * 0.5, centerY - textSize.y * 0.5))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(0.05, 0.05, 0.05, 1))
    ui.text(text)
    ui.popStyleColor()
    ui.popFont()
end

local function drawGantry(centerX, y)
    local radius = 26
    local spacing = radius * 2.4
    local panelWidth = (lightCount - 1) * spacing + radius * 2 + 44
    local panelHeight = radius * 2 + 44
    local x = centerX - panelWidth * 0.5

    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), alphaColor(0.03, 0.03, 0.03, 0.92), 14)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), alphaColor(0.16, 0.16, 0.16, 1), 14, 0, 2)

    local lightsY = y + panelHeight * 0.5
    local lightsStartX = x + 22 + radius

    local litColor = neonRed
    if litMode == "yellow" then
        litColor = neonYellow
    elseif litMode == "green" then
        litColor = neonGreen
    end

    for i = 1, lightCount, 1 do
        local center = vec2(lightsStartX + (i - 1) * spacing, lightsY)

        ui.drawCircleFilled(center, radius + 6, alphaColor(0.10, 0.10, 0.10, 1), 32)
        ui.drawCircle(center, radius + 6, alphaColor(0.22, 0.22, 0.22, 1), 32, 1.5)

        if lightsOn[i] then
            ui.drawCircleFilled(center, radius * 2.1, rgbm(litColor.r, litColor.g, litColor.b, state.alpha * 0.12), 32)
            ui.drawCircleFilled(center, radius * 1.5, rgbm(litColor.r, litColor.g, litColor.b, state.alpha * 0.28), 32)
            ui.drawCircleFilled(center, radius, rgbm(litColor.r, litColor.g, litColor.b, state.alpha), 32)
            ui.drawCircle(center, radius, alphaColor(1, 1, 1, 0.35), 32, 1)
        else
            ui.drawCircleFilled(center, radius, alphaColor(0.16, 0.02, 0.02, 1), 32)
        end
    end
end

-- Cuadrado intermitente amarillo (mismo estilo que la franja del ícono SC), para poner uno
-- a cada lado del cartel de texto en la fase amarilla, en vez del semáforo completo (que
-- sigue usándose tal cual durante la secuencia real de largada, más abajo).
local function drawBlinkSquare(x, y, size)
    local blinkOn = math.floor(sim.currentSessionTime / 400) % 2 == 0
    if blinkOn then
        ui.drawRectFilled(vec2(x, y), vec2(x + size, y + size), alphaColor(1.0, 0.82, 0.0, 1))
    else
        ui.drawRectFilled(vec2(x, y), vec2(x + size, y + size), alphaColor(0.25, 0.2, 0.0, 1))
    end
    ui.drawRect(vec2(x, y), vec2(x + size, y + size), alphaColor(0.16, 0.16, 0.16, 1), 0, 0, 2)
end

local function drawInfoPanel(centerX, y)
    local panelWidth = 420
    local panelHeight = 110
    local x = centerX - panelWidth * 0.5

    local borderColor
    if restrictorActive then
        borderColor = alphaColor(1.0, 0.15, 0.1)
    elseif phase == "yellow" then
        borderColor = alphaColor(1.0, 0.75, 0.0)
    else
        borderColor = alphaColor(1.0, 0.82, 0.0)
    end

    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), alphaColor(0, 0, 0, 0.88), 10)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), borderColor, 10, 0, 3)

    ui.pushFont(ui.Font.Title)
    local titleSize = ui.measureText(title)
    ui.setCursor(vec2(x + (panelWidth - titleSize.x) * 0.5, y + 18))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1.0, 0.82, 0.0))
    ui.text(title)
    ui.popStyleColor()
    ui.popFont()

    local subtitle
    if phase == "yellow" then
        subtitle = "RESPETAR POSICIONES"
    else
        subtitle = "MÁXIMO " .. maxSpeed .. " KM/H   |   ACTUAL " .. math.round(car.speedKmh, 0) .. " KM/H"
    end
    ui.pushFont(ui.Font.Main)
    local subSize = ui.measureText(subtitle)
    ui.setCursor(vec2(x + (panelWidth - subSize.x) * 0.5, y + 62))
    local speedColor
    if phase == "sequence" and car.speedKmh > maxSpeed + speedMargin then
        speedColor = alphaColor(1.0, 0.2, 0.15)
    else
        speedColor = alphaColor(1, 1, 1)
    end
    ui.pushStyleColor(ui.StyleColor.Text, speedColor)
    ui.text(subtitle)
    ui.popStyleColor()
    ui.popFont()

    if restrictorActive then
        local warnText = "¡RESTRICTOR ACTIVO!"
        ui.pushFont(ui.Font.Small)
        local warnSize = ui.measureText(warnText)
        ui.setCursor(vec2(x + (panelWidth - warnSize.x) * 0.5, y + 90))
        local blink = (math.floor(sim.currentSessionTime / 200) % 2 == 0)
        ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1.0, 0.15, 0.1, blink and 1 or 0.35))
        ui.text(warnText)
        ui.popStyleColor()
        ui.popFont()
    end

    -- Un cuadrado intermitente a cada lado del cartel (esta función solo se usa en la fase
    -- amarilla/decorativa o en modo edición, nunca durante la secuencia real de largada)
    local squareSize = panelHeight
    local gap = 12
    drawBlinkSquare(x - gap - squareSize, y, squareSize)
    drawBlinkSquare(x + panelWidth + gap, y, squareSize)
end

local function drawSpeedSign(x, y, size)
    local center = vec2(x + size * 0.5, y + size * 0.5)
    local radius = size * 0.5

    if speedSignURL ~= "" and ui.isImageReady(speedSignURL) then
        ui.drawImage(speedSignURL, vec2(x, y), vec2(x + size, y + size), alphaColor(1, 1, 1, 1))
        return
    end

    -- Respaldo vectorial mientras la imagen no está lista o no hay URL configurada
    ui.drawCircleFilled(center, radius, alphaColor(1, 1, 1, 1), 48)
    ui.drawCircleFilled(center, radius, alphaColor(0.85, 0.05, 0.05, 1), 48, 0, radius * 0.16)
    ui.pushFont(ui.Font.Title)
    local txt = "80"
    local txtSize = ui.measureText(txt)
    ui.setCursor(vec2(center.x - txtSize.x * 0.5, center.y - txtSize.y * 0.5))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(0.05, 0.05, 0.05, 1))
    ui.text(txt)
    ui.popStyleColor()
    ui.popFont()
end


-- ===== Arrastre manual con click sostenido =====
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

-- Posición guardada por el usuario (persiste entre sesiones, individual por piloto)
local posCfg = ac.storage({
    posX = 0.5,       -- proporción de pantalla (centro horizontal del conjunto)
    posY = 90 / 1080   -- proporción de pantalla (borde superior del conjunto)
})

local dragging = false
local dragOffsetX, dragOffsetY = 0, 0
local blockWidth, blockHeight = 420, 226

function script.drawUI()
    health.lastDraw = health.t
    -- El mouse se lee UNA SOLA VEZ acá arriba y se reutiliza en toda la función -- llamarlo
    -- de nuevo más abajo podía dar un resultado distinto en el mismo cuadro, provocando
    -- arrastres fantasma que se autocorregían al cuadro siguiente sin parar.
    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()

    -- Chequeo de seguridad INCONDICIONAL: si había un cartel en arrastre y el mouse ya no
    -- está apretado, se libera YA, sin importar si el cartel dejó de ser visible a mitad
    -- de camino. Sin esto, el candado compartido puede quedar trabado para siempre.
    if dragging and not mouseIsDown then
        dragging = false
        panelDragStateEvent5({ dragging = false, panelId = 0 })
        ac.log("[LARGADA] Arrastre liberado por seguridad")
    end

    if state.alpha <= 0 or shouldHideForDrag() then
        return
    end

    local panelHeight = 110
    local centerX = posCfg.posX * screen.w
    local panelY = posCfg.posY * screen.h
    local gantryY = panelY + panelHeight + 20

    local blockX = centerX - blockWidth * 0.5
    local blockY = panelY

    if mp ~= nil then
        local overBlock = mp.x >= blockX and mp.x <= blockX + blockWidth and mp.y >= blockY and mp.y <= blockY + blockHeight

        if not dragging and mouseIsDown and overBlock then
            dragging = true
            dragOffsetX = mp.x - blockX
            dragOffsetY = mp.y - blockY
            panelDragStateEvent5({ dragging = true, panelId = MY_PANEL_ID })
        end

        if dragging then
            if mouseIsDown then
                blockX = mp.x - dragOffsetX
                blockY = mp.y - dragOffsetY
                centerX = blockX + blockWidth * 0.5
                panelY = blockY
                gantryY = panelY + panelHeight + 20
                posCfg.posX = centerX / screen.w
                posCfg.posY = panelY / screen.h
            else
                dragging = false
                panelDragStateEvent5({ dragging = false, panelId = 0 })
            end
        end
    end

    if phase == "yellow" or editingPanelId == MY_PREVIEW_ID then
        drawInfoPanel(centerX, panelY)
    else
        -- Durante la secuencia (rojo -> verde): se oculta el cartel, queda solo el semáforo en su misma posición.
        drawGantry(centerX, gantryY)

        -- El cartel de 80 se muestra desde que arranca la secuencia (terminaron las
        -- intermitentes amarillas) hasta que se da el verde -- desaparece apenas
        -- greenForced pasa a true, sea porque lo detectó este cliente o porque le llegó el
        -- aviso de otro.
        if phase == "sequence" and not greenForced then
            local signRadius = 55
            local signX = centerX + blockWidth * 0.5 + signRadius + 24
            local signY = gantryY + (blockHeight * 0.5)
            drawSpeedLimitSign(signX, signY, signRadius)
        end
    end
end

-- ===================================================================================
-- Autodiagnóstico y reparación suave (mismo bloque en los 7 scripts, ver announcements.lua
-- para el botón de admin y el reporte). ID de este script: 6 (Largada en Movimiento)
--   1 Anuncios | 2 Penalizaciones | 3 Safety Car | 4 Vuelta Previa | 5 Luces de largada
--   6 Largada en Movimiento | 7 Bandera Verde
-- Qué hace: (1) responde cuando el admin pide un chequeo, informando si este script está
-- corriendo, si recibió la configuración del servidor y si realmente está dibujando
-- (drawUI se ejecutó en los últimos 3 s). (2) Si detecta que corre pero NO dibuja, se
-- repara solo (como mucho una vez cada 30 s). Reparar = reiniciar el estado que ya vimos que
-- deja carteles invisibles: tamaño de pantalla y bloqueos de arrastre. No es una recarga
-- del script (CSP no ofrece eso).
-- ===================================================================================
local HEALTH_SCRIPT_ID = 6
local healthPending = nil
local healthLastRepair = -999
local healthNextCheck = 5

health.ok = function()
    return (health.t - health.lastDraw) < 3 and sim.windowWidth > 0 and sim.windowHeight > 0
end

health.repair = function(reason)
    healthLastRepair = health.t
    local okRepair, errRepair = pcall(function()
        screen.w = sim.windowWidth
        screen.h = sim.windowHeight
        dragging = false
        globalDragging = false
        globalDragPanelId = 0
    end)
    ac.log("[HEALTH] Reparación suave en Largada en Movimiento (" .. tostring(reason) .. ")" ..
        (okRepair and "" or (" ERROR: " .. tostring(errRepair))))
end

health.tick = function(dt)
    if healthPending and health.t >= healthPending.at then
        local p = healthPending
        healthPending = nil
        local okPong, errPong = pcall(function()
            healthPongEvent({ scriptId = HEALTH_SCRIPT_ID, visualOk = health.ok(), welcome = health.welcome, nonce = p.nonce })
        end)
        ac.log("[HEALTH] Largada en Movimiento: respuesta enviada ok=" .. tostring(okPong) .. (okPong and "" or (" err=" .. tostring(errPong))))
    end
    if health.t >= healthNextCheck then
        healthNextCheck = health.t + 5
        if not health.ok() and (health.t - healthLastRepair) > 30 then
            health.repair("autochequeo: el script corre pero drawUI no se ejecuta")
        end
    end
end

ac.onOnlineWelcome(function() health.welcome = true end)

healthPingEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Health Ping"),
    nonce = ac.StructItem.float()
}, function(sender, message)
    -- Las respuestas se escalonan (por ID de script y un poco al azar) para que 7 scripts x
    -- todos los pilotos no revienten el límite de mensajes por segundo.
    ac.log("[HEALTH] Largada en Movimiento: recibió el ping " .. tostring(message.nonce))
    healthPending = { at = health.t + HEALTH_SCRIPT_ID * 0.25 + math.random() * 1.5, nonce = message.nonce }
end,
ac.SharedNamespace.ServerScript)

healthRepairEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Health Repair"),
    target = ac.StructItem.string(32) -- nombre del piloto (primeros 24 caracteres); vacío = todos
}, function(sender, message)
    local okName, myName = pcall(function() return string.sub(car:driverName(), 1, 24) end)
    local target = tostring(message.target or "")
    if target == "" or (okName and target == myName) then
        health.repair("pedido del admin")
    end
end,
ac.SharedNamespace.ServerScript)

healthPongEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Health Pong"),
    scriptId = ac.StructItem.float(),
    visualOk = ac.StructItem.boolean(),
    welcome = ac.StructItem.boolean(),
    nonce = ac.StructItem.float()
}, function(sender, message)
    -- Solo announcements.lua junta las respuestas; acá solo se declara para poder enviar.
end,
ac.SharedNamespace.ServerScript)
