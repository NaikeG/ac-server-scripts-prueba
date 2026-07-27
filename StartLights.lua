sim = ac.getSim()
car = ac.getCar(0)
local texFilePath = (ac.getFolder(ac.FolderID.Root) .. "\\content\\texture\\")

-- ===== Modo de edición compartido: mismo evento que el resto de los scripts. Este cartel es
-- el ID 8 -- solo se muestra cuando el menú lo tiene seleccionado. =====
local editingPanelId = 0
local MY_PREVIEW_ID = 8
panelPreviewEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Preview Mode"),
    selectedId = ac.StructItem.float()
}, function(sender, message)
    if sender:driverName() ~= car:driverName() then return end
    editingPanelId = message.selectedId
end,
ac.SharedNamespace.ServerScript)

-- ===== Ocultar todos los carteles de todos los scripts menos el que se está arrastrando =====
-- ID global de este cartel: 8 (ver la lista completa de IDs en announcements.lua)
local MY_PANEL_ID = 8
local globalDragging = false
local globalDragPanelId = 0

panelDragStateEvent4 = ac.OnlineEvent({
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

local penaltyType = 0 -- -2 for gearbox locked until start, -1 for no Penalty, 0 for gearbox lock reactivo (sin teletransporte), above 0 will be laps to serve drive through.
local jumpstartGearboxLockSeconds = 5

local URL = ""
local lightCount = 6
local adminFlag = ui.OnlineExtraFlags.None
local overrideTimer = 0
local started = true
local startTime = 0
local delayTime = 0
local lightsOutMax = 5000
local lightsOutMin = 3000
local seqStartTime = 12000
local seqDuration = 17000
local replaceACStart = 0
math.randomseed(sim.randomSeed)
local gracePeriod = 1000 * math.random(1, 2)
local debugMode = 0
local isf1style = 0
local f1delay = 100

local greenHoldTime = 1000 -- ms que se mantienen las luces en verde tras la largada, antes de apagarse
local maxStartArmWindow = 300000 -- ms: solo se arma el chequeo de falsa largada si la sesión lleva menos de esto (evita teleports random tarde en la carrera)

-- Cola de reenvíos: el mensaje de largada se manda 3 veces en total (una vez al toque, y 2
-- reenvíos más con una pequeña pausa) para que, si a algún piloto se le pierde una copia del
-- mensaje por la red, le llegue igual con alguno de los reenvíos. Como el mensaje lleva un
-- horario ABSOLUTO (no "arrancá ahora"), reenviarlo tal cual no desincroniza nada -- todos
-- calculan la misma cuenta regresiva real sin importar cuál de las 3 copias les llegó.
local resendQueue = {}
local function scheduleResend(payload, delaySeconds)
    table.insert(resendQueue, { timer = delaySeconds, payload = payload })
end

-- Lógica de disparo de la secuencia, en una función aparte para poder llamarla tanto desde
-- el botón de admin como desde el aviso automático de vueltaPrevia.lua (al desactivar Vuelta
-- Previa).
local function doTriggerStart()
    math.randomseed(os.time())
    ac.log("Start Lights Message Sent")
    ac.setMessage("Start Lights Command Sent", "")
    local payload
    if isf1style == 0 then
        payload = {
            startTime = sim.currentSessionTime + seqDuration,
            delayTime = math.random(lightsOutMin, lightsOutMax)
        }
    else
        payload = { startTime = sim.currentSessionTime + seqDuration, delayTime = 99999999 }
    end
    triggerStart(payload)
    -- Reenvíos distribuidos en una ventana más amplia, mismo mecanismo ya probado
    scheduleResend(payload, 0.2)
    scheduleResend(payload, 0.5)
    scheduleResend(payload, 1)
    scheduleResend(payload, 2)
    scheduleResend(payload, 4)
    scheduleResend(payload, 7)
end

-- Aviso de vueltaPrevia.lua: al desactivar Vuelta Previa, arranca la secuencia sola, sin
-- depender de que el admin apriete el botón de acá aparte.
autoStartLightsEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Auto Start Lights")
}, function(sender, message)
    -- Sin este filtro, TODOS los clientes recibirían el aviso y cada uno dispararía su
    -- propia secuencia con un horario aleatorio distinto, desincronizando todo -- solo
    -- actúa el mismo cliente que mandó el aviso (el admin que desactivó Vuelta Previa),
    -- igual que si hubiera apretado el botón manual él mismo.
    if sender:driverName() ~= car:driverName() then return end
    ac.log("[STARTLIGHTS] Disparo automático recibido (Vuelta Previa desactivada)")
    doTriggerStart()
end,
ac.SharedNamespace.ServerScript)

-- Colores "flúor" (valores por encima de 1 generan un leve glow/bloom en CSP)
local neonRed = rgbm(1.6, 0.05, 0.05, 1)
local neonGreen = rgbm(0.05, 1.8, 0.1, 1)

-- Sonidos
local beepURL = ""
local goURL = ""
local beepSound = nil
local goSound = nil
local prevLightState = {}
local greenSoundPlayed = false
local soundVolumeMultiplier = 2.5 -- sube el volumen del beep/go por encima del volumen general del juego

local light = ui.ExtraCanvas(vec2(64, 64))
--ac.debug("a", ui.imageSize(light))
light:setName("light")
if ui.imageSize(texFilePath .. "off.png") < vec2(32, 32) then
    light:update(function()
        ui.drawCircleFilled(vec2(32, 32), 30, rgbm.colors.white, 24)
    end)
else
    light:update(function()
        ui.drawImage(texFilePath .. "off.png", vec2(0, 0), vec2(64, 64))
    end)
end


local windowWidth, windowHeight = ac.getSim().windowWidth/ac.getUI().uiScale, ac.getSim().windowHeight/ac.getUI().uiScale
local lightWidth, lightHeight = ui.imageSize(light):unpack()
local lightCenter = vec2((lightWidth / 2), (lightHeight / 2))
local lightArrayStart = ((windowWidth / 2) - (lightWidth * 2) - lightWidth / 2)
local lightState = {}
for i = 1, lightCount, 1 do
    lightState[i] = false
    prevLightState[i] = false
end


local function overrideStart()
    if replaceACStart == 1 and sim.raceSessionType == ac.SessionType.Race then
        started = false
        startTime = sim.currentSessionTime + sim.timeToSessionStart
        math.randomseed(sim.randomSeed + sim.currentSessionIndex * 100)
        if isf1style == 1 then
            delayTime = 999999999
        else
            delayTime = math.random(lightsOutMin, lightsOutMax)
        end

        ac.disableExtraHUDElements('startingLights', true)
        --ac.debug("d", startTime)
        --ac.log(sim.currentSessionTime,sim.timeToSessionStart)
        --ac.debug("a", sim.currentSessionTime+sim.timeToSessionStart)
    else
        started = true
        startTime = 0
        delayTime = 0
    end
end

ac.onOnlineWelcome(function(message, config) --Reads the script config from the extra options config
    local parsedConfig = tostring(config)
    --ac.debug("config", parsedConfig)
    local configCheck = config:mapSection("STARTLIGHTS", { TARGET_RATE_OF_CHANGE = 0, SAMPLE_TIME = 0, DISPLAY_WARNING_FOR = 0 })
    lightsOutMin, lightsOutMax = config:get("STARTLIGHTS", "RANDOM_DELAY_RANGE", 3, 1) * 1000, config:get("STARTLIGHTS", "RANDOM_DELAY_RANGE", 5, 2) * 1000
    penaltyType = config:get("STARTLIGHTS", "PENALTY_TYPE", -1)
    jumpstartGearboxLockSeconds = config:get("STARTLIGHTS", "JUMPSTART_GEARBOX_LOCK_SECONDS", 5)
    seqDuration, seqStartTime = config:get("STARTLIGHTS", "SEQUENCE_LENGTH", 17) * 1000, config:get("STARTLIGHTS", "SEQUENCE_START", 12) * 1000
    isf1style = config:get("STARTLIGHTS", "F1_STYLE", 0)
    f1delay = config:get("STARTLIGHTS", "F1_STYLE_DELAY", 50)
    maxStartArmWindow = config:get("STARTLIGHTS", "MAX_START_ARM_WINDOW", 300) * 1000
    greenHoldTime = config:get("STARTLIGHTS", "GREEN_HOLD_TIME", 1) * 1000
    if config:get("STARTLIGHTS", "ADMIN_ONLY", 1) == 1 then
        adminFlag = ui.OnlineExtraFlags.Admin
    else
        adminFlag = ui.OnlineExtraFlags.None
    end
    replaceACStart = config:get("STARTLIGHTS", "REPLACE_AC_START", 0)
    URL = config:get("STARTLIGHTS", "ICON_URL", "")
    debugMode = config:get("STARTLIGHTS", "DEBUG_MODE", 0)

    beepURL = config:get("STARTLIGHTS", "SOUND_BEEP_URL", "")
    goURL = config:get("STARTLIGHTS", "SOUND_GO_URL", "")
    soundVolumeMultiplier = config:get("STARTLIGHTS", "SOUND_VOLUME_MULTIPLIER", 2.5)
    if beepURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(beepURL) end)
        if ok then
            beepSound = result
            ac.log("[STARTLIGHTS] Beep sound cargado OK: " .. beepURL)
        else
            ac.log("[STARTLIGHTS] ERROR cargando beep sound (" .. beepURL .. "): " .. tostring(result))
        end
    end
    if goURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(goURL) end)
        if ok then
            goSound = result
            ac.log("[STARTLIGHTS] Go sound cargado OK: " .. goURL)
        else
            ac.log("[STARTLIGHTS] ERROR cargando go sound (" .. goURL .. "): " .. tostring(result))
        end
    end

    overrideTimer = 1
    requestLightsSyncEvent({})

    ui.registerOnlineExtra(ui.Icons.TrafficLight, "Start Lights", function() return true end, nil, function(okClicked)
        if debugMode == 1 then
            ac.debug("Settings Dump", tostring(config))
        end
        doTriggerStart()
    end, adminFlag)

    if isf1style == 1 then
        ui.registerOnlineExtra(ui.Icons.TrafficLight, "Start Lights Out", function()
            if startTime + delayTime - sim.currentSessionTime > 0 then
                return true
            else
                return false
            end
        end, nil, function(okClicked)
            math.randomseed(os.time())
            ac.log("Start Lights Message Sent")
            ac.setMessage("Start Lights Command Sent", "")
            if debugMode == 1 then
                ac.debug("Settings Dump", tostring(config))
            end

            triggerStart({ startTime = sim.currentSessionTime, delayTime = f1delay })
        end, adminFlag)
    end
end)

ac.onClientConnected(function(connectedCarIndex, connectedSessionID)
    if isf1style == 1 and started then
        triggerStart({ startTime = startTime, delayTime = f1delay })
    end
end)

ac.onSessionStart(function()
    overrideTimer = 1
end)

ac.debug("!version", "startLights v0.9-verde")

function script.update(dt)
    for i = #resendQueue, 1, -1 do
        local item = resendQueue[i]
        item.timer = item.timer - dt
        if item.timer <= 0 then
            triggerStart(item.payload)
            table.remove(resendQueue, i)
        end
    end

    if overrideTimer > 0 then
        overrideTimer = overrideTimer - dt
    elseif overrideTimer < 0 and overrideTimer > -1 then
        overrideStart()
        overrideTimer = -2
    end

    if URL ~= "" and ui.isImageReady(URL) then
        light:clear()
        light:update(function()
            ui.drawImage(URL, vec2(0, 0), vec2(64, 64))
        end)
        URL = ""
    end
    --ac.debug("t", overrideTimer )
    --ac.debug("c",car.speedKmh)
    --ac.debug("time to start", startTime + delayTime - sim.currentSessionTime)
    --ac.debug("b", (seqDuration + delayTime - gracePeriod) )

    -- Solo se arma la detección de falsa largada a partir de que TODAS las luces (el último
    -- rojo) están encendidas -- antes de eso, la gente todavía se está acomodando en su
    -- casillero de grilla, y ese movimiento normal no debería contar como falsa largada.
    if sim.currentSessionTime >= startTime and startTime + delayTime - sim.currentSessionTime > -5000 and not started then
        if car.speedKmh > 0.5 then
            started = true
            if startTime + delayTime - sim.currentSessionTime > 0 then
                ac.sendChatMessage(car:driverName() ..
                    " Jumped the start by:" .. math.round(startTime + delayTime - sim.currentSessionTime, 0) .. "ms.")
                if penaltyType == 0 then
                    -- Bloqueo de caja de cambios, sin teletransporte a boxes
                    physics.lockUserGearboxFor(jumpstartGearboxLockSeconds, true)
                elseif penaltyType > 0 then
                    physics.setCarPenalty(ac.PenaltyType.MandatoryPits, penaltyType)
                end
            else
                ac.sendChatMessage(car:driverName() ..
                    " Reacted in: " .. math.abs(math.round(startTime + delayTime - sim.currentSessionTime, 0)) .. "ms.")
            end
        end
    end
end

-- ===== Sincronización para quien se conecta después de que ya se disparó la secuencia =====
-- El reenvío triple (más abajo) solo ayuda a quien YA estaba conectado en el momento del
-- click -- si alguien se conecta o reconecta DESPUÉS (por ejemplo durante la propia Vuelta
-- Previa), nunca recibe ningún aviso, porque los eventos no se repiten para tardíos. Con
-- esto, al conectarte, le preguntás a los demás si ya hay una secuencia en curso.
requestLightsSyncEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Request Lights Sync")
}, function(sender, message)
    if startTime > 0 then
        lightsSyncResponseEvent({ startTime = startTime, delayTime = delayTime })
    end
end,
ac.SharedNamespace.ServerScript)

lightsSyncResponseEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Lights Sync Response"),
    startTime = ac.StructItem.float(),
    delayTime = ac.StructItem.float()
}, function(sender, message)
    if startTime == 0 then -- solo si todavía no tengo ninguna secuencia propia
        startTime = message.startTime
        delayTime = message.delayTime
        if sim.currentSessionTime < maxStartArmWindow then
            started = false
        end
        ac.log("[STARTLIGHTS] Sincronizado con secuencia ya en curso (llegué tarde a la conexión)")
    end
end,
ac.SharedNamespace.ServerScript)

triggerStart = ac.OnlineEvent({
    key = ac.StructItem.key("Start Lights"),
    startTime = ac.StructItem.float(),
    delayTime = ac.StructItem.float()
}, function(sender, message)
    -- Si startTime/delayTime son IDÉNTICOS a los que ya tenía guardados, es un reenvío
    -- duplicado de la misma orden (no una orden nueva) -- no hay que resetear los sonidos,
    -- si no los beeps ya reproducidos podrían volver a sonar de más al llegar el reenvío.
    local isDuplicate = (startTime == message.startTime and delayTime == message.delayTime)

    startTime = message.startTime
    delayTime = message.delayTime
    if sim.currentSessionTime < maxStartArmWindow then
        started = false
    else
        ac.log("[STARTLIGHTS] Falsa largada NO armada: la sesión ya lleva " ..
            math.floor(sim.currentSessionTime / 1000) .. "s (fuera de la ventana de seguridad de " ..
            math.floor(maxStartArmWindow / 1000) .. "s). Las luces igual se muestran, pero sin riesgo de teletransporte.")
    end

    if not isDuplicate then
        greenSoundPlayed = false
        for i = 1, lightCount, 1 do
            prevLightState[i] = false
        end
    end

    ac.log("TIME: Start Light Trigger Received at " ..
        ac.lapTimeToString(sim.currentSessionTime, true) ..
        " | " .. ac.lapTimeToString(sim.sessionTimeLeft, true) .. " Remaining." ..
        "\n COMMS: Sent By: " .. sender:driverName() .. " Penalty Type:" .. penaltyType ..
        "\n SYNC: Lights will all be lit in:" ..
        ac.lapTimeToString(startTime - sim.currentSessionTime) ..
        " Expected roughly: " ..
        ac.lapTimeToString(seqDuration) ..
        " Delay between: " .. lightsOutMin / 1000 .. "s and " .. lightsOutMax / 1000 .. "s")

    if debugMode == 1 then
        ac.sendChatMessage("Start Light Command Successfully Recieved. Lights Out in: " ..
        ac.lapTimeToString(startTime + delayTime - sim.currentSessionTime, true))
    end
    if penaltyType == -2 then
        physics.lockUserGearboxFor((startTime + delayTime - sim.currentSessionTime) / 1000, true)
    end
end, ac.SharedNamespace.ServerScript)

ac.onResolutionChange(function()
    windowWidth, windowHeight = ac.getSim().windowWidth, ac.getSim().windowHeight
    lightWidth, lightHeight = ui.imageSize(light):unpack()
    lightCenter = vec2((lightWidth / 2), (lightHeight / 2))
    lightArrayStart =( (windowWidth / 2) - (lightWidth * 2) - lightWidth / 2)
    
end)
ac.log(ac.getUI().uiScale)

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

-- Desplazamiento guardado por el usuario respecto a la posición central por defecto (persiste entre sesiones, por piloto)
local posCfg = ac.storage({ offsetX = 0, offsetY = 0 })
local dragging = false
local dragOffsetX, dragOffsetY = 0, 0

function script.drawUI() -- Panel tipo gantry F1
    --ac.debug("path", texFilePath .. "texture_trafficlight_off.png")
    --ac.debug("size", "x:" .. windowWidth .. " y:" .. windowHeight)
    --ac.debug("a", sim.currentSessionTime)
    --ac.debug("b", startTime-delayTime-seqStartTime)

    -- El mouse se lee UNA SOLA VEZ acá arriba y se reutiliza en toda la función -- llamarlo
    -- de nuevo más abajo podía dar un resultado distinto en el mismo cuadro, provocando
    -- arrastres fantasma que se autocorregían al cuadro siguiente sin parar.
    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()

    -- Chequeo de seguridad INCONDICIONAL: si había un cartel en arrastre y el mouse ya no
    -- está apretado, se libera YA, sin importar si el semáforo dejó de ser visible a mitad
    -- de camino (por ejemplo si terminó la secuencia mientras se estaba moviendo el
    -- cartel). Sin esto, el candado compartido puede quedar trabado para siempre.
    if dragging and not mouseIsDown then
        dragging = false
        panelDragStateEvent4({ dragging = false, panelId = 0 })
        ac.log("[STARTLIGHTS] Arrastre liberado por seguridad")
    end

    if shouldHideForDrag() then
        return
    end

    local phase
    if editingPanelId == MY_PREVIEW_ID then
        -- Muestra la carcasa con todas las luces encendidas, sin depender del reloj de sesión
        phase = "red"
        for i = 1, lightCount, 1 do
            lightState[i] = true
        end
    elseif sim.currentSessionTime < startTime + delayTime then
        -- Secuencia de encendido progresivo en rojo
        phase = "red"
        for i = 1, lightCount, 1 do
            local isOn = sim.currentSessionTime > startTime - seqDuration + seqStartTime + ((seqDuration - seqStartTime) / 6) * i
            if isOn and not prevLightState[i] and beepSound then
                local ok, err = pcall(function()
                    beepSound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
                    beepSound:play()
                end)
                if not ok then
                    ac.log("[STARTLIGHTS] ERROR reproduciendo beep: " .. tostring(err))
                end
            end
            prevLightState[i] = isOn
            lightState[i] = isOn
        end
    elseif sim.currentSessionTime < startTime + delayTime + greenHoldTime then
        -- Flash verde al momento de largar
        phase = "green"
        if not greenSoundPlayed and goSound then
            local ok, err = pcall(function()
                goSound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
                goSound:play()
            end)
            if not ok then
                ac.log("[STARTLIGHTS] ERROR reproduciendo go sound: " .. tostring(err))
            end
            greenSoundPlayed = true
        end
        for i = 1, lightCount, 1 do
            lightState[i] = true
        end
    else
        return
    end

    local litColor = (phase == "red") and neonRed or neonGreen
    local radius = lightWidth * 0.42
    local vGap = 0 -- 1 sola luz por columna (sin separación vertical)
    local padding = 22

    -- Parpadeo del verde
    local blinkOn = true
    if phase == "green" then
        local blinkInterval = 180 -- ms por ciclo on/off
        local elapsed = sim.currentSessionTime - (startTime + delayTime)
        blinkOn = math.floor(elapsed / blinkInterval) % 2 == 0
    end

    local panelX1 = lightArrayStart - lightCenter.x - padding + posCfg.offsetX
    local panelY1 = 256 - vGap / 2 - radius - padding + posCfg.offsetY
    local panelX2 = lightArrayStart + lightWidth * (lightCount - 1) + lightCenter.x + padding + posCfg.offsetX
    local panelY2 = 256 + vGap / 2 + radius + padding + posCfg.offsetY

    -- Detección de arrastre sobre la carcasa
    do
        if mp ~= nil then
            local overPanel = mp.x >= panelX1 and mp.x <= panelX2 and mp.y >= panelY1 and mp.y <= panelY2
            if not dragging and mouseIsDown and overPanel then
                dragging = true
                dragOffsetX = mp.x - posCfg.offsetX
                dragOffsetY = mp.y - posCfg.offsetY
                panelDragStateEvent4({ dragging = true, panelId = MY_PANEL_ID })
            end
            if dragging then
                if mouseIsDown then
                    posCfg.offsetX = mp.x - dragOffsetX
                    posCfg.offsetY = mp.y - dragOffsetY
                    panelX1 = lightArrayStart - lightCenter.x - padding + posCfg.offsetX
                    panelY1 = 256 - vGap / 2 - radius - padding + posCfg.offsetY
                    panelX2 = lightArrayStart + lightWidth * (lightCount - 1) + lightCenter.x + padding + posCfg.offsetX
                    panelY2 = 256 + vGap / 2 + radius + padding + posCfg.offsetY
                else
                    dragging = false
                    panelDragStateEvent4({ dragging = false, panelId = 0 })
                end
            end
        end
    end

    -- Carcasa del semáforo
    ui.drawRectFilled(vec2(panelX1, panelY1), vec2(panelX2, panelY2), rgbm(0.03, 0.03, 0.03, 0.92), 14)
    ui.drawRect(vec2(panelX1, panelY1), vec2(panelX2, panelY2), rgbm(0.16, 0.16, 0.16, 1), 14, 0, 2)
    ui.drawLine(vec2(panelX1 + 10, panelY2 - 6), vec2(panelX2 - 10, panelY2 - 6), rgbm(0, 0, 0, 0.5), 2)

    for i = 1, lightCount, 1 do
        local cx = lightArrayStart + lightWidth * (i - 1)
        local isLit = lightState[i]
        if phase == "green" then
            isLit = isLit and blinkOn
        end

        local center = vec2(cx + posCfg.offsetX, 256 + posCfg.offsetY)

        -- Portalámpara (bezel oscuro)
        ui.drawCircleFilled(center, radius + 6, rgbm(0.10, 0.10, 0.10, 1), 32)
        ui.drawCircle(center, radius + 6, rgbm(0.22, 0.22, 0.22, 1), 32, 1.5)

        if isLit then
            -- Resplandor en capas (glow)
            ui.drawCircleFilled(center, radius * 2.1, rgbm(litColor.r, litColor.g, litColor.b, 0.12), 32)
            ui.drawCircleFilled(center, radius * 1.5, rgbm(litColor.r, litColor.g, litColor.b, 0.28), 32)
            -- Núcleo brillante
            ui.drawCircleFilled(center, radius, litColor, 32)
            ui.drawCircle(center, radius, rgbm(1, 1, 1, 0.35), 32, 1)
        else
            -- Lámpara apagada
            ui.drawCircleFilled(center, radius, rgbm(0.16, 0.02, 0.02, 1), 32)
        end
    end
end
