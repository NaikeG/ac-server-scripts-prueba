local sim = ac.getSim()
local car = ac.getCar(0)

-- ===== Estado de Vuelta Previa (mismo evento "Formation Lap" que usa vueltaPrevia.lua) =====
-- Durante la Vuelta Previa ya se está técnicamente en sesión de Carrera, y como cada piloto
-- llega a su casillero de grilla en un momento distinto, pueden aparecer diferencias de
-- vuelta parecidas a las del arranque -- pero esta vez duran más que el sostenido de 1.5s
-- porque la Vuelta Previa entera puede tardar bastante. Por eso directamente no se chequea
-- bandera azul de Carrera mientras esté activa, y unos segundos MÁS después de que se apaga
-- -- si el admin la apaga apenas ve que todos están más o menos ubicados, los números de
-- vuelta de cada auto pueden no haber terminado de asentarse todavía en ese instante.
local formationLapActive = false
local FORMATION_GRACE_SECONDS = 8
local formationGraceTimer = 0
formationEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Formation Lap"),
    enabled = ac.StructItem.boolean()
}, function(sender, message)
    if formationLapActive and not message.enabled then
        formationGraceTimer = FORMATION_GRACE_SECONDS
    end
    formationLapActive = message.enabled
end,
ac.SharedNamespace.ServerScript)

local function isFormationSuppressed()
    return formationLapActive or formationGraceTimer > 0
end

local screen = { w = sim.windowWidth, h = sim.windowHeight }
ac.onResolutionChange(function()
    screen.w = ac.getSim().windowWidth
    screen.h = ac.getSim().windowHeight
end)

-- Fuente usada para el contenido principal del cartel (se probó Huge, pero resultó
-- demasiado grande -- Title da un buen equilibrio entre legible y compacto)
local biggestFont = ui.Font.Title

-- ===== Modo de edición: mismo evento que announcements.lua. Este cartel es el ID 5 -- solo
-- se muestra con contenido de ejemplo cuando el menú de admin lo tiene seleccionado a él. =====
local editingPanelId = 0
local MY_PREVIEW_ID = 5
local BLUEFLAG_PREVIEW_ID = 11

panelPreviewEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Preview Mode"),
    selectedId = ac.StructItem.float()
}, function(sender, message)
    if sender:driverName() ~= car:driverName() then return end
    editingPanelId = message.selectedId
end,
ac.SharedNamespace.ServerScript)

-- ===== Diagnóstico: campo de posición en carrera (para sanción de adelantamiento bajo SC) =====
local positionField = nil
local function findPositionField()
    local candidates = { "racePosition", "position", "leaderboardPosition", "place", "raceOrder", "racePos", "sessionPosition" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "number" and val > 0 then
            ac.log("[PENALTIES] Campo de posición encontrado: car." .. name .. " = " .. tostring(val))
            positionField = name
            return
        end
    end
    ac.log("[PENALTIES] No se encontró campo de posición -> sanción de adelantamiento bajo SC queda desactivada")
end

local function getRacePosition()
    if positionField == nil then return nil end
    local ok, val = pcall(function() return car[positionField] end)
    if ok then return val end
    return nil
end

-- ===== Diagnóstico: campo de bandera azul =====
local blueFlagField = nil
local function findBlueFlagField()
    local candidates = {
        "isUnderBlueFlag", "blueFlag", "hasBlueFlag", "underBlueFlag", "showBlueFlag",
        "isBlueFlag", "blueFlagShown", "blueFlagActive", "flagBlue"
    }
    ac.log("[PENALTIES] --- Probando todos los campos de bandera azul candidatos ---")
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        ac.log("[PENALTIES] car." .. name .. " = " .. tostring(ok and val or "no existe"))
    end
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "boolean" then
            blueFlagField = name
            ac.log("[PENALTIES] Usando car." .. name .. " para la bandera azul")
            return
        end
    end
    ac.log("[PENALTIES] No se encontró ningún campo de bandera azul -> ese aviso queda desactivado")
end

-- ===== Campo de "está en boxes" (para no disparar sanciones por error dentro de boxes) =====
local inPitField = nil
local function findInPitField()
    local candidates = { "isInPit", "isInPitlane", "inPitlane", "inPit", "isInPitLane", "isInPitBox" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "boolean" then
            ac.log("[PENALTIES] Campo de pits encontrado: car." .. name .. " = " .. tostring(val))
            inPitField = name
            return
        end
    end
    ac.log("[PENALTIES] No se encontró campo de pits")
end

local function isCarInPit()
    if inPitField == nil then return false end
    local ok, val = pcall(function() return car[inPitField] end)
    if ok and val == true then return true end
    return false
end

-- ===== Diagnóstico: campo de "fuera de pista" (para no confundir un incidente ajeno con un
-- adelantamiento real bajo Safety Car) =====
local offTrackField = nil
local function findOffTrackField()
    local candidates = { "isOffTrack", "isOutOfTrack", "outOfTrack", "offTrack", "isOffRoad" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "boolean" then
            ac.log("[PENALTIES] Campo de fuera de pista encontrado: car." .. name .. " = " .. tostring(val))
            offTrackField = name
            return
        end
    end
    ac.log("[PENALTIES] No se encontró campo de fuera de pista -> se usa velocidad muy baja como señal de respaldo")
end

-- Si CUALQUIER auto conectado (que no esté en boxes) está fuera de pista, o casi detenido,
-- asumimos que hay un incidente en curso en algún lugar de la pista, y no arrancamos ninguna
-- advertencia nueva de "adelantamiento bajo SC" mientras eso esté pasando -- para no penalizar
-- a pilotos inocentes que simplemente pasaron de largo al que tuvo el problema.
-- Tiene un límite de tiempo: si un auto queda detenido/fuera de pista por mucho tiempo (por
-- ejemplo alguien que abandona sin desconectarse), después de un rato se deja de tratar como
-- "incidente en curso" para no bloquear la detección para todos los demás indefinidamente.
local INCIDENT_SPEED_THRESHOLD_KMH = 25
local INCIDENT_MAX_DURATION_SECONDS = 30
local incidentStartTimes = {} -- [carIndex] = sim.currentSessionTime en que empezó a verse detenido

local function isAnyoneHavingIncident()
    local okCount, carsCount = pcall(function() return sim.carsCount end)
    if not okCount then return false end

    local anyIncident = false

    for i = 0, carsCount - 1 do
        local okOther, otherCar = pcall(function() return ac.getCar(i) end)
        if okOther and otherCar then
            local okConn, connected = pcall(function() return otherCar.isConnected end)
            if okConn and connected then
                local otherInPit = false
                if inPitField ~= nil then
                    local okOtherPit, val = pcall(function() return otherCar[inPitField] end)
                    otherInPit = okOtherPit and val == true
                end

                local looksLikeIncident = false
                if not otherInPit then
                    if offTrackField ~= nil then
                        local okOff, isOff = pcall(function() return otherCar[offTrackField] end)
                        looksLikeIncident = okOff and isOff
                    else
                        local okSpeed, speed = pcall(function() return otherCar.speedKmh end)
                        looksLikeIncident = okSpeed and speed < INCIDENT_SPEED_THRESHOLD_KMH
                    end
                end

                if looksLikeIncident then
                    if incidentStartTimes[i] == nil then
                        incidentStartTimes[i] = sim.currentSessionTime
                    end
                    local elapsedSeconds = (sim.currentSessionTime - incidentStartTimes[i]) / 1000
                    if elapsedSeconds <= INCIDENT_MAX_DURATION_SECONDS then
                        anyIncident = true
                    end
                else
                    incidentStartTimes[i] = nil
                end
            end
        end
    end
    return anyIncident
end

-- Distintas versiones de Lua llaman diferente a la función de arcotangente de 2 argumentos
-- (math.atan2 en Lua 5.1/5.2, math.atan(y,x) en 5.3+) -- probamos las dos, por las dudas.
local function safeAtan2(y, x)
    local ok, result = pcall(function() return math.atan2(y, x) end)
    if ok then return result end
    local ok2, result2 = pcall(function() return math.atan(y, x) end)
    if ok2 then return result2 end
    return math.atan(y / x) -- último recurso, no maneja todos los cuadrantes bien
end

-- ===== Detección aproximada de bandera azul (auto más rápido/adelantado cerca) =====
-- No hay campo nativo expuesto a Lua para esto, así que lo aproximamos, con distinta lógica
-- según el tipo de sesión: en Práctica no se muestra nunca; en Clasificación se usa diferencia
-- de velocidad sostenida (para no confundir una frenada puntual en una curva con alguien que
-- realmente viene mucho más rápido); en Carrera se usa vueltas de diferencia (te están por doblar).
local BLUEFLAG_DISTANCE_METERS = 60
local BLUEFLAG_QUALY_SPEED_DIFF_KMH = 30
local BLUEFLAG_QUALY_RELATIVE_SPEED_FACTOR = 1.15 -- además de la diferencia absoluta, tiene que ir un 15% más rápido en términos relativos -- filtra el caso de "los dos van rápido, en distintos puntos de sus respectivas vueltas"
local QUALY_SUSTAIN_SECONDS = 1.5
local qualySpeedDiffTimer = 0
local RACE_LAP_SUSTAIN_SECONDS = 1.5 -- filtra el "1 de diferencia" transitorio justo al cruzar la línea de largada tras la Vuelta Previa
local raceLapDiffTimer = 0
local lastDistanceToCar = {} -- [carIndex] = última distancia conocida a ese auto, para exigir que se esté achicando de verdad

local function checkBlueFlagApprox(dt)
    if isCarInPit() then
        qualySpeedDiffTimer = 0
        raceLapDiffTimer = 0
        return false, nil
    end

    local isRaceSession = (sim.raceSessionType == ac.SessionType.Race)
    local isQualifySession = (sim.raceSessionType == ac.SessionType.Qualify)

    if not isRaceSession and not isQualifySession then
        qualySpeedDiffTimer = 0
        raceLapDiffTimer = 0
        return false, nil -- Práctica (o cualquier otra sesión que no sea Carrera/Clasificación): nunca
    end

    if isRaceSession and isFormationSuppressed() then
        -- Durante la Vuelta Previa (y unos segundos después de que se apaga), aunque ya sea
        -- técnicamente sesión de Carrera, cada uno llega a su casillero en un momento
        -- distinto -- las diferencias de vuelta que aparecen ahí no son una vuelta de
        -- diferencia real, así que no corresponde bandera azul mientras esto esté pasando.
        raceLapDiffTimer = 0
        return false, nil
    end

    local okCount, carsCount = pcall(function() return sim.carsCount end)
    local okMyPos, myPos = pcall(function() return car.position end)
    local okLook, look = pcall(function() return car.look end)
    local foundCandidate = false
    local foundDirection = nil -- ángulo en radianes hacia el auto (0=adelante, ±π=atrás), solo para Clasificación
    local foundCarIndex = nil -- índice del auto que la disparó, para poder seguirlo en vivo después

    if okCount and okMyPos then
        for i = 1, carsCount - 1 do
            local okOther, otherCar = pcall(function() return ac.getCar(i) end)
            if okOther and otherCar then
                local okConn, connected = pcall(function() return otherCar.isConnected end)
                if okConn and connected then
                    local otherInPit = false
                    if inPitField ~= nil then
                        local okOtherPit, val = pcall(function() return otherCar[inPitField] end)
                        otherInPit = okOtherPit and val == true
                    end

                    local okPos, otherPos = pcall(function() return otherCar.position end)
                    local qualifies = false
                    local candidateDirection = nil

                    if okPos and not otherInPit then
                        if isRaceSession then
                            local okLap, otherLap = pcall(function() return otherCar.lapCount end)
                            qualifies = okLap and otherLap > car.lapCount
                        else
                            -- Clasificación: diferencia de velocidad (absoluta Y relativa, para filtrar
                            -- el caso de "los dos van rápido, en distintos puntos de sus vueltas"),
                            -- ignorando autos en vuelta inválida, que además vengan de ATRÁS mío
                            -- (no de adelante), y que se estén acercando de verdad (no solo que estén
                            -- cerca en un instante).
                            local okValid, otherValid = pcall(function() return otherCar.isLapValid end)
                            local otherLapCountsAsValid = (not okValid) or otherValid
                            local okSpeed, otherSpeed = pcall(function() return otherCar.speedKmh end)

                            local speedOk = okSpeed and otherLapCountsAsValid
                                and (otherSpeed - car.speedKmh) > BLUEFLAG_QUALY_SPEED_DIFF_KMH
                                and otherSpeed > car.speedKmh * BLUEFLAG_QUALY_RELATIVE_SPEED_FACTOR

                            local isBehind = false
                            local angleRad = nil
                            if speedOk and okLook and look ~= nil then
                                local toOtherX = otherPos.x - myPos.x
                                local toOtherZ = otherPos.z - myPos.z
                                local dot = look.x * toOtherX + look.z * toOtherZ
                                local cross = look.x * toOtherZ - look.z * toOtherX
                                isBehind = dot < 0
                                angleRad = safeAtan2(cross, dot)
                            end

                            local isClosing = false
                            if speedOk and isBehind then
                                local dx = otherPos.x - myPos.x
                                local dz = otherPos.z - myPos.z
                                local currentDist = math.sqrt(dx * dx + dz * dz)
                                local prevDist = lastDistanceToCar[i]
                                -- Si no hay dato previo (primera vez que se lo ve calificar), se da
                                -- el beneficio de la duda; de ahí en más, tiene que achicarse de verdad.
                                isClosing = prevDist == nil or currentDist < prevDist
                                lastDistanceToCar[i] = currentDist
                            else
                                lastDistanceToCar[i] = nil
                            end

                            qualifies = speedOk and isBehind and isClosing
                            if qualifies then
                                candidateDirection = angleRad
                            end
                        end
                    end

                    if qualifies then
                        local dx = myPos.x - otherPos.x
                        local dy = myPos.y - otherPos.y
                        local dz = myPos.z - otherPos.z
                        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                        if dist < BLUEFLAG_DISTANCE_METERS then
                            foundCandidate = true
                            foundDirection = candidateDirection
                            foundCarIndex = i
                            break
                        end
                    end
                end
            end
        end
    end

    if isRaceSession then
        -- También tiene que sostenerse un rato -- justo al cruzar la línea de largada tras
        -- la Vuelta Previa, un auto puede figurar momentáneamente "una vuelta arriba" solo
        -- por el orden en que cada uno cruzó la línea, sin que eso sea una vuelta real de
        -- diferencia. Sostenerlo filtra ese falso positivo transitorio.
        if foundCandidate then
            raceLapDiffTimer = raceLapDiffTimer + dt
        else
            raceLapDiffTimer = 0
        end
        local raceActive = raceLapDiffTimer >= RACE_LAP_SUSTAIN_SECONDS
        return raceActive, raceActive and foundDirection or nil, raceActive and foundCarIndex or nil
    end

    -- En Clasificación, la diferencia de velocidad tiene que sostenerse un rato antes de
    -- mostrar el cartel, para filtrar frenadas puntuales al entrar a una curva.
    if foundCandidate then
        qualySpeedDiffTimer = qualySpeedDiffTimer + dt
    else
        qualySpeedDiffTimer = 0
    end
    local active = qualySpeedDiffTimer >= QUALY_SUSTAIN_SECONDS
    return active, active and foundDirection or nil, active and foundCarIndex or nil
end

local function isUnderBlueFlag(dt)
    if blueFlagField ~= nil then
        local ok, val = pcall(function() return car[blueFlagField] end)
        if ok and val == true then return true, nil, nil end
        return false, nil, nil
    end
    return checkBlueFlagApprox(dt)
end

-- ===== Diagnóstico: acceso a OTROS autos (nunca lo probamos en este proyecto, todo lo demás
-- solo miraba el auto propio con ac.getCar(0)). Necesario para armar la detección aproximada
-- de bandera azul: "hay un auto más rápido cerca por detrás".
local function diagnoseOtherCars()
    local okCount, carsCount = pcall(function() return sim.carsCount end)
    ac.log("[PENALTIES] sim.carsCount = " .. tostring(okCount and carsCount or "no se pudo leer"))
    if not okCount then return end

    local okPos, myPos = pcall(function() return car.position end)
    ac.log("[PENALTIES] car.position = " .. tostring(okPos and myPos or "no existe"))

    -- Recorre TODOS los índices, pero solo loguea los que tengan un piloto real conectado
    -- (nombre no vacío), para no llenar el log con los ~40 lugares vacíos del servidor.
    for i = 0, carsCount - 1 do
        local okOther, otherCar = pcall(function() return ac.getCar(i) end)
        if okOther and otherCar then
            local okName, name = pcall(function() return otherCar:driverName() end)
            if okName and name ~= nil and name ~= "" then
                local okLap, lapCount = pcall(function() return otherCar.lapCount end)
                local okOtherPos, otherPos = pcall(function() return otherCar.position end)
                local okConnected, isConnected = pcall(function() return otherCar.isConnected end)
                ac.log("[PENALTIES] Auto " .. i .. " (" .. name .. "): lapCount=" ..
                    tostring(okLap and lapCount or "no existe") .. ", position=" .. tostring(okOtherPos and otherPos or "no existe") ..
                    ", isConnected=" .. tostring(okConnected and isConnected or "no existe"))
            end
        end
    end
end

-- Dibuja una flecha como gráfico (no como texto), rotada al ángulo exacto -- mismo helper
-- que usamos en vueltaPrevia.lua para el cartel de navegación a la grilla.
-- angleRad: 0 = derecho para arriba/adelante, positivo = hacia la derecha (sentido horario)
local function drawArrow(cx, cy, angleRad, length, color, thickness)
    local dx = math.sin(angleRad)
    local dy = -math.cos(angleRad)
    local tipX, tipY = cx + dx * length * 0.5, cy + dy * length * 0.5
    local tailX, tailY = cx - dx * length * 0.5, cy - dy * length * 0.5

    -- Vara
    ui.drawLine(vec2(tailX, tailY), vec2(tipX, tipY), color, thickness)

    -- Cabeza "rellena": como no hay una función de triángulo relleno confirmada, se simula
    -- con varias líneas paralelas entre la punta y la base, además del contorno.
    local headLen = length * 0.42
    local headAngle = math.rad(26)
    local a1 = angleRad + math.pi - headAngle
    local a2 = angleRad + math.pi + headAngle
    local h1x, h1y = tipX + math.sin(a1) * headLen, tipY - math.cos(a1) * headLen
    local h2x, h2y = tipX + math.sin(a2) * headLen, tipY - math.cos(a2) * headLen

    ui.drawLine(vec2(tipX, tipY), vec2(h1x, h1y), color, thickness)
    ui.drawLine(vec2(tipX, tipY), vec2(h2x, h2y), color, thickness)
    ui.drawLine(vec2(h1x, h1y), vec2(h2x, h2y), color, thickness)

    local fillSteps = 5
    for s = 1, fillSteps do
        local t = s / (fillSteps + 1)
        local px, py = tipX + (h1x - tipX) * t, tipY + (h1y - tipY) * t
        local qx, qy = tipX + (h2x - tipX) * t, tipY + (h2y - tipY) * t
        ui.drawLine(vec2(px, py), vec2(qx, qy), color, thickness)
    end
end

-- Cartel cuadrado dedicado a la bandera azul, MISMO TAMAÑO que el ícono "SC" de
-- safetyCar.lua (150x150: 70 de caja negra + 80 de franja): acá la caja negra tiene la
-- flecha grande centrada, y la franja (azul en vez de amarilla, parpadeo más rápido) tiene
-- el texto "CUIDADO".
local function drawBlueFlagPanel(x, y, angle, alpha)
    local boxWidth = 105
    local blackHeight = 49
    local blueHeight = 56

    ui.drawRectFilled(vec2(x, y), vec2(x + boxWidth, y + blackHeight), rgbm(0.05, 0.05, 0.05, alpha))
    ui.drawRect(vec2(x, y), vec2(x + boxWidth, y + blackHeight), rgbm(0.25, 0.25, 0.25, alpha), 0, 0, 2)

    local ARROW_SIZE = 35
    drawArrow(x + boxWidth * 0.5, y + blackHeight * 0.5, angle or 0, ARROW_SIZE, rgbm(1, 1, 1, alpha), 4)

    -- Franja azul intermitente (el doble de rápido que la franja amarilla de safetyCar.lua)
    -- con el texto "CUIDADO" centrado adentro
    local blinkOn = math.floor(sim.currentSessionTime / 200) % 2 == 0
    local barY = y + blackHeight
    if blinkOn then
        ui.drawRectFilled(vec2(x, barY), vec2(x + boxWidth, barY + blueHeight), rgbm(0.15, 0.45, 1.0, alpha))
    else
        ui.drawRectFilled(vec2(x, barY), vec2(x + boxWidth, barY + blueHeight), rgbm(0.04, 0.09, 0.22, alpha))
    end
    ui.drawRect(vec2(x, barY), vec2(x + boxWidth, barY + blueHeight), rgbm(0.25, 0.25, 0.25, alpha), 0, 0, 2)

    ui.pushFont(ui.Font.Small)
    local text = "CUIDADO"
    local textSize = ui.measureText(text)
    ui.setCursor(vec2(x + (boxWidth - textSize.x) * 0.5, barY + (blueHeight - textSize.y) * 0.5))
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, alpha))
    ui.text(text)
    ui.popStyleColor()
    ui.popFont()

    return boxWidth, blackHeight + blueHeight
end

-- ===== Cartel en pantalla (mismo estilo F1 usado en announcements.lua: fondo negro, marco de color) =====
local banner = { label = "", value = "", color = rgbm(1, 1, 1, 1), timer = 0, alpha = 0 }

local function showBanner(label, value, color, duration)
    banner.label = label
    banner.value = value
    banner.color = color
    banner.timer = duration
end

-- ===== Arrastre manual con click sostenido, igual que el resto de los carteles del proyecto =====
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

-- Ambas posiciones van en UNA sola llamada a ac.storage() (no separadas), para eliminar
-- cualquier posibilidad de que terminen compartiendo el mismo espacio de guardado por tener
-- forma parecida -- el mismo bug que ya encontramos y solucionamos en otros scripts.
local panelPositions = ac.storage({
    bannerPosX = (screen.w - 620) * 0.5 / screen.w,
    bannerPosY = 200 / 1080,
    blueFlagPosX = (screen.w - 220) * 0.5 / screen.w,
    blueFlagPosY = 300 / 1080
})
local bannerDragging = false
local bannerDragOffsetX, bannerDragOffsetY = 0, 0

-- Cartel cuadrado dedicado a la bandera azul (estilo SC: caja negra + franja que titila)
local blueFlagPanel = { timer = 0, alpha = 0, angle = 0 }
local blueFlagDragging = false
local blueFlagDragOffsetX, blueFlagDragOffsetY = 0, 0

-- ===== Ocultar todos los carteles de todos los scripts menos el que se está arrastrando =====
-- ID global de este cartel: 5 (ver la lista completa de IDs en announcements.lua)
local MY_PANEL_ID = 5
local globalDragging = false
local globalDragPanelId = 0

panelDragStateEvent = ac.OnlineEvent({
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

local pendingChats = {}

-- ===== Sonidos =====
local blueFlagSoundURL = ""
local blueFlagSound = nil
local overtakeWarningSoundURL = ""
local overtakeWarningSound = nil
local soundVolumeMultiplier = 2.5

local function playSound(sound, label)
    if not sound then return end
    local ok, err = pcall(function()
        sound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
        sound:play()
    end)
    if not ok then
        ac.log("[PENALTIES] ERROR reproduciendo sonido (" .. tostring(label) .. "): " .. tostring(err))
    end
end

-- ===== Estado del Safety Car (mismo evento que usa safetyCar.lua) =====
local scActive = false
local lastKnownPosition = nil

-- Estado del aviso de "devolver la posición" antes de sancionar
local OVERTAKE_WARNING_SECONDS = 15
local GEARBOX_LOCK_SECONDS = 5 -- duración del bloqueo de caja, igual mecanismo que Largada en Movimiento
local overtakeWarningActive = false
local overtakeWarningTimer = 0
local positionBeforeOvertake = nil
local myGearboxLockEndTime = nil
-- Queda en true desde que se detecta la infracción hasta que REALMENTE se devuelve la posición,
-- sin importar cuántos ciclos de aviso+sanción hagan falta. Así el infractor no puede "pagar
-- una sola sanción" y quedarse con el lugar robado -- sigue bajo la lupa hasta cumplir.
local owesPosition = false
local warningBaseText = ""

-- Contador compartido: cuántos autos están cumpliendo la sanción en este momento. Mientras
-- sea > 0, no se arrancan avisos nuevos para nadie -- si alguien está frenado cumpliendo la
-- sanción, es normal que otros autos lo pasen, y eso no debe contar como una infracción de ellos.
-- Además, apenas termina CUALQUIER sanción, se extiende esa misma tregua unos segundos más --
-- así el piloto que había sido perjudicado tiene margen para recuperar su lugar original sin
-- que se le dispare un aviso nuevo por "adelantar" a quien lo había pasado ilegalmente.
local penaltyActiveCount = 0
local GRACE_AFTER_PENALTY_SECONDS = 10
local graceTimer = 0
local function isAnyoneUnderScPenalty() return penaltyActiveCount > 0 or graceTimer > 0 end

scPenaltyActiveEvent = ac.OnlineEvent({
    key = ac.StructItem.key("SC Overtake Penalty Active"),
    active = ac.StructItem.boolean()
}, function(sender, message)
    if message.active then
        penaltyActiveCount = penaltyActiveCount + 1
    else
        penaltyActiveCount = math.max(0, penaltyActiveCount - 1)
        graceTimer = GRACE_AFTER_PENALTY_SECONDS
        ac.log("[PENALTIES] Sanción terminada, tregua de " .. GRACE_AFTER_PENALTY_SECONDS .. "s para recuperar posiciones")
    end
end,
ac.SharedNamespace.ServerScript)

-- Aviso visual para TODOS los clientes de quién está sancionado, no solo el propio infractor
scPenaltyBannerEvent = ac.OnlineEvent({
    key = ac.StructItem.key("SC Penalty Banner")
}, function(sender, message)
    showBanner("SANCIÓN", sender:driverName() .. " - NO DEVOLVIÓ LA POSICIÓN", rgbm(0.85, 0.15, 0.15, 1), 6)
end,
ac.SharedNamespace.ServerScript)

safetyCarEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Safety Car"),
    enabled = ac.StructItem.boolean()
}, function(sender, message)
    scActive = message.enabled
    if scActive then
        lastKnownPosition = getRacePosition()
        ac.log("[PENALTIES] Safety Car activado, posición de referencia: " .. tostring(lastKnownPosition))
    else
        lastKnownPosition = nil
        -- Si se apaga el SC en medio de un aviso o una deuda pendiente, se cancela todo: ya no
        -- aplica sancionar algo que pasó bajo un régimen que ya terminó.
        if overtakeWarningActive or owesPosition then
            overtakeWarningActive = false
            owesPosition = false
            banner.timer = 0
            ac.log("[PENALTIES] Safety Car desactivado con deuda/aviso pendiente -> se cancela, sin sanción")
        end
    end
end,
ac.SharedNamespace.ServerScript)

ac.onOnlineWelcome(function(message, config)
    findPositionField()
    findBlueFlagField()
    findInPitField()
    findOffTrackField()
    diagnoseOtherCars()

    blueFlagSoundURL = config:get("PENALTIES", "BLUEFLAG_SOUND_URL", "")
    soundVolumeMultiplier = config:get("PENALTIES", "SOUND_VOLUME_MULTIPLIER", 2.5)
    GEARBOX_LOCK_SECONDS = config:get("PENALTIES", "GEARBOX_LOCK_SECONDS", 5)
    BLUEFLAG_DISTANCE_METERS = config:get("PENALTIES", "BLUEFLAG_DISTANCE_METERS", 60)
    BLUEFLAG_QUALY_SPEED_DIFF_KMH = config:get("PENALTIES", "BLUEFLAG_QUALY_SPEED_DIFF_KMH", 30)
    BLUEFLAG_QUALY_RELATIVE_SPEED_FACTOR = config:get("PENALTIES", "BLUEFLAG_QUALY_RELATIVE_SPEED_FACTOR", 1.15)
    INCIDENT_SPEED_THRESHOLD_KMH = config:get("PENALTIES", "INCIDENT_SPEED_THRESHOLD_KMH", 25)
    INCIDENT_MAX_DURATION_SECONDS = config:get("PENALTIES", "INCIDENT_MAX_DURATION_SECONDS", 30)
    GRACE_AFTER_PENALTY_SECONDS = config:get("PENALTIES", "GRACE_AFTER_PENALTY_SECONDS", 10)
    ac.log("[PENALTIES] sim.raceSessionType = " .. tostring(sim.raceSessionType) ..
        " | ac.SessionType.Race = " .. tostring(ac.SessionType.Race) ..
        " | ac.SessionType.Qualify = " .. tostring(ac.SessionType.Qualify))
    if blueFlagSoundURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(blueFlagSoundURL) end)
        if ok then
            blueFlagSound = result
            ac.log("[PENALTIES] Sonido de bandera azul cargado OK")
        else
            ac.log("[PENALTIES] ERROR cargando sonido de bandera azul: " .. tostring(result))
        end
    end

    overtakeWarningSoundURL = config:get("PENALTIES", "OVERTAKE_WARNING_SOUND_URL", "")
    if overtakeWarningSoundURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(overtakeWarningSoundURL) end)
        if ok then
            overtakeWarningSound = result
            ac.log("[PENALTIES] Sonido de aviso de adelantamiento cargado OK")
        else
            ac.log("[PENALTIES] ERROR cargando sonido de aviso de adelantamiento: " .. tostring(result))
        end
    end
end)

function script.drawUI()
    -- El mouse se lee UNA SOLA VEZ acá arriba y se reutiliza en toda la función -- llamarlo
    -- de nuevo más abajo podía dar un resultado distinto en el mismo cuadro, provocando
    -- arrastres fantasma que se autocorregían al cuadro siguiente sin parar.
    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()

    -- Chequeo de seguridad INCONDICIONAL: si había un cartel en arrastre y el mouse ya no
    -- está apretado, se libera YA, sin importar si el cartel dejó de ser visible a mitad
    -- de camino. Sin esto, el candado compartido puede quedar trabado para siempre.
    if bannerDragging and not mouseIsDown then
        bannerDragging = false
        panelDragStateEvent({ dragging = false, panelId = 0 })
        ac.log("[PENALTIES] Arrastre liberado por seguridad")
    end

    -- El chat solo se manda desde acá (drawUI), que no corre en la copia headless del
    -- servidor, para evitar que el mismo aviso se mande dos veces.
    for _, msg in ipairs(pendingChats) do
        ac.sendChatMessage(msg)
    end
    pendingChats = {}

    if (banner.alpha > 0 or editingPanelId == MY_PREVIEW_ID) and not shouldHideForDrag() then
        local a = editingPanelId == MY_PREVIEW_ID and 1 or banner.alpha
        local c = editingPanelId == MY_PREVIEW_ID and rgbm(1.0, 0.65, 0.0, 1) or banner.color
        local labelToShow = editingPanelId == MY_PREVIEW_ID and "ADELANTAMIENTO BAJO SAFETY CAR" or banner.label
        local valueToShow = editingPanelId == MY_PREVIEW_ID and "DEVOLVER LA POSICIÓN (15s)" or banner.value

        local labelText = string.upper(labelToShow)
        ui.pushFont(ui.Font.Small)
        local labelSize = ui.measureText(labelText)
        ui.popFont()

        local valueText = string.upper(valueToShow)
        ui.pushFont(biggestFont)
        local valueSize = ui.measureText(valueText)
        ui.popFont()

        -- Ancho/alto dinámicos según el contenido, no un tamaño fijo -- los mensajes cortos
        -- dan cajas chicas, los largos se siguen viendo completos sin cortarse.
        local panelWidth = math.max(labelSize.x, valueSize.x) + 40
        local panelHeight = labelSize.y + valueSize.y + 26

        local baseX = panelPositions.bannerPosX * screen.w
        local baseY = panelPositions.bannerPosY * screen.h

        if mp ~= nil then
            local overPanel = mp.x >= baseX and mp.x <= baseX + panelWidth and mp.y >= baseY and mp.y <= baseY + panelHeight
            if not bannerDragging and mouseIsDown and overPanel then
                bannerDragging = true
                bannerDragOffsetX = mp.x - baseX
                bannerDragOffsetY = mp.y - baseY
                panelDragStateEvent({ dragging = true, panelId = MY_PANEL_ID })
            end
            if bannerDragging then
                if mouseIsDown then
                    baseX = mp.x - bannerDragOffsetX
                    baseY = mp.y - bannerDragOffsetY
                    panelPositions.bannerPosX = baseX / screen.w
                    panelPositions.bannerPosY = baseY / screen.h
                else
                    bannerDragging = false
                    panelDragStateEvent({ dragging = false, panelId = 0 })
                end
            end
        end

        local x = baseX
        local y = baseY

        ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0, 0, 0, 0.85 * a), 10)
        ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(c.r, c.g, c.b, a), 10, 0, 3)

        ui.pushFont(ui.Font.Small)
        ui.setCursor(vec2(x + (panelWidth - labelSize.x) * 0.5, y + 10))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(c.r, c.g, c.b, a))
        ui.text(labelText)
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(biggestFont)
        ui.setCursor(vec2(x + (panelWidth - valueSize.x) * 0.5, y + labelSize.y + 16))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, a))
        ui.text(valueText)
        ui.popStyleColor()
        ui.popFont()
    end

    -- Panel cuadrado dedicado a la bandera azul (estilo SC + flecha), independiente del
    -- cartel de arriba -- no se muestra nada más junto con esto.
    if (blueFlagPanel.alpha > 0 or editingPanelId == BLUEFLAG_PREVIEW_ID) and not shouldHideForDrag() then
        local a = editingPanelId == BLUEFLAG_PREVIEW_ID and 1 or blueFlagPanel.alpha
        local angle = editingPanelId == BLUEFLAG_PREVIEW_ID and math.rad(45) or blueFlagPanel.angle
        local baseX = panelPositions.blueFlagPosX * screen.w
        local baseY = panelPositions.blueFlagPosY * screen.h
        local boxWidth, boxHeight = 105, 105 -- tamaño fijo conocido (49+56), para el hitbox de arrastre

        if mp ~= nil then
            local overBox = mp.x >= baseX and mp.x <= baseX + boxWidth and mp.y >= baseY and mp.y <= baseY + boxHeight
            if not blueFlagDragging and mouseIsDown and overBox then
                blueFlagDragging = true
                blueFlagDragOffsetX = mp.x - baseX
                blueFlagDragOffsetY = mp.y - baseY
                panelDragStateEvent({ dragging = true, panelId = MY_PANEL_ID })
            end
            if blueFlagDragging then
                if mouseIsDown then
                    baseX = mp.x - blueFlagDragOffsetX
                    baseY = mp.y - blueFlagDragOffsetY
                    panelPositions.blueFlagPosX = baseX / screen.w
                    panelPositions.blueFlagPosY = baseY / screen.h
                else
                    blueFlagDragging = false
                    panelDragStateEvent({ dragging = false, panelId = 0 })
                end
            end
        end

        drawBlueFlagPanel(baseX, baseY, angle, a)
    end
end

-- ===== Loop principal =====
local wasUnderBlueFlag = false
local blueFlagTrackedCarIndex = nil -- para poder seguir en vivo al auto que disparó la bandera azul

function script.update(dt)
    if graceTimer > 0 then
        graceTimer = math.max(graceTimer - dt, 0)
    end

    if formationGraceTimer > 0 then
        formationGraceTimer = math.max(formationGraceTimer - dt, 0)
    end

    if banner.timer > 0 then
        banner.timer = banner.timer - dt
        banner.alpha = math.min(banner.alpha + 0.10, 1)
    else
        banner.alpha = math.max(banner.alpha - 0.10, 0)
    end

    if blueFlagPanel.timer > 0 then
        blueFlagPanel.timer = blueFlagPanel.timer - dt
        blueFlagPanel.alpha = math.min(blueFlagPanel.alpha + 0.10, 1)
    else
        blueFlagPanel.alpha = math.max(blueFlagPanel.alpha - 0.10, 0)
    end

    -- Bandera azul: cartel cuadrado dedicado (estilo SC, con flecha), no el cartel rectangular
    -- compartido con el aviso de Safety Car. Se dispara en el flanco de apagada -> encendida,
    -- pero la FLECHA se recalcula todos los cuadros mientras el cartel esté visible, siguiendo
    -- al auto específico que la disparó -- así no queda clavada en el ángulo del instante en
    -- que se prendió, sigue en vivo la posición real del auto que se acerca.
    local nowUnderBlueFlag, blueFlagAngle, blueFlagCarIdx = isUnderBlueFlag(dt)
    if nowUnderBlueFlag and not wasUnderBlueFlag then
        blueFlagPanel.timer = 5
        blueFlagPanel.angle = blueFlagAngle
        blueFlagTrackedCarIndex = blueFlagCarIdx
        playSound(blueFlagSound, "bandera azul")
        ac.log("[PENALTIES] Bandera azul mostrada a " .. car:driverName() .. " (ángulo: " .. tostring(blueFlagAngle) .. ")")
    end
    wasUnderBlueFlag = nowUnderBlueFlag

    -- Mientras el cartel siga visible, se recalcula el ángulo en vivo hacia el auto
    -- rastreado (si sigue conectado), en vez de quedarse con el valor del instante inicial.
    if blueFlagPanel.timer > 0 and blueFlagTrackedCarIndex ~= nil then
        local okTracked, trackedCar = pcall(function() return ac.getCar(blueFlagTrackedCarIndex) end)
        if okTracked and trackedCar then
            local okConn, connected = pcall(function() return trackedCar.isConnected end)
            local okPos, trackedPos = pcall(function() return trackedCar.position end)
            local okMyPos, myPos = pcall(function() return car.position end)
            local okLook, look = pcall(function() return car.look end)
            if okConn and connected and okPos and okMyPos and okLook and look ~= nil then
                local dx = trackedPos.x - myPos.x
                local dz = trackedPos.z - myPos.z
                local dot = look.x * dx + look.z * dz
                local cross = look.x * dz - look.z * dx
                blueFlagPanel.angle = safeAtan2(cross, dot)
            end
        end
    end

    -- Adelantamiento bajo Safety Car: aviso de 15 segundos para devolver la posición antes de
    -- sancionar. CLAVE: si tras la sanción todavía no devolvió la posición, se lo vuelve a
    -- avisar y sancionar de nuevo, las veces que hagan falta -- no alcanza con "pagar una vez"
    -- y quedarse con el lugar robado.
    if scActive and positionField ~= nil and not isCarInPit() then
        local currentPos = getRacePosition()

        if myGearboxLockEndTime ~= nil then
            -- Cumpliendo la sanción en este momento: no se evalúa nada más, solo se sigue
            -- registrando la posición para cuando termine.
            if currentPos ~= nil then
                lastKnownPosition = currentPos
            end
        elseif not owesPosition then
            -- Sin deuda pendiente: se busca una infracción NUEVA
            if currentPos ~= nil and lastKnownPosition ~= nil and currentPos < lastKnownPosition
                and not isAnyoneUnderScPenalty() and not isAnyoneHavingIncident() then
                owesPosition = true
                positionBeforeOvertake = lastKnownPosition
                overtakeWarningActive = true
                overtakeWarningTimer = OVERTAKE_WARNING_SECONDS
                warningBaseText = "DEVOLVER LA POSICIÓN"

                showBanner("ADELANTAMIENTO BAJO SAFETY CAR", warningBaseText .. " (" .. OVERTAKE_WARNING_SECONDS .. "s)", rgbm(1.0, 0.65, 0.0, 1), 16)
                playSound(overtakeWarningSound, "aviso de adelantamiento")
                table.insert(pendingChats, "⚠️ " .. car:driverName() .. " adelantó bajo Safety Car - tiene " ..
                    OVERTAKE_WARNING_SECONDS .. "s para devolver la posición")
                ac.log("[PENALTIES] Aviso de adelantamiento bajo SC para " .. car:driverName() ..
                    " (posición a devolver: " .. tostring(positionBeforeOvertake) .. ")")
            end
            if currentPos ~= nil then
                lastKnownPosition = currentPos
            end
        else
            -- Con deuda pendiente (ya sea recién detectada o de un ciclo de sanción anterior):
            -- se chequea si por fin devolvió la posición.
            if currentPos ~= nil and currentPos >= positionBeforeOvertake then
                owesPosition = false
                overtakeWarningActive = false
                banner.timer = 0
                table.insert(pendingChats, "✅ " .. car:driverName() .. " devolvió la posición, deuda saldada")
                ac.log("[PENALTIES] " .. car:driverName() .. " devolvió la posición, deuda saldada")
                lastKnownPosition = currentPos
            elseif overtakeWarningActive then
                -- Aviso en curso: cuenta regresiva normal, con el contador visible en el cartel
                overtakeWarningTimer = overtakeWarningTimer - dt
                banner.value = warningBaseText .. " (" .. math.max(math.ceil(overtakeWarningTimer), 0) .. "s)"
                if overtakeWarningTimer <= 0 then
                    overtakeWarningActive = false

                    -- Mismo mecanismo que usa Largada en Movimiento: bloqueo de caja de cambios
                    local ok, err = pcall(function() physics.lockUserGearboxFor(GEARBOX_LOCK_SECONDS, true) end)
                    if ok then
                        ac.log("[PENALTIES] Sanción aplicada a " .. car:driverName() ..
                            " por no devolver la posición tras adelantar bajo Safety Car (caja bloqueada " .. GEARBOX_LOCK_SECONDS .. "s)")
                    else
                        ac.log("[PENALTIES] ERROR aplicando sanción: " .. tostring(err))
                    end

                    myGearboxLockEndTime = sim.currentSessionTime + GEARBOX_LOCK_SECONDS * 1000
                    scPenaltyActiveEvent({ active = true })

                    showBanner("SANCIÓN", car:driverName() .. " - NO DEVOLVIÓ LA POSICIÓN", rgbm(0.85, 0.15, 0.15, 1), 6)
                    scPenaltyBannerEvent({}) -- para que el cartel se vea también en la pantalla de todos los demás
                    table.insert(pendingChats, "🚫 " .. car:driverName() .. " sancionado (caja bloqueada) por no devolver la posición bajo Safety Car")
                end
            else
                -- Recién terminó una sanción y TODAVÍA no devolvió la posición: se lo vuelve a
                -- avisar de inmediato, sin esperar una nueva "mejora de posición" (porque no
                -- está mejorando más, simplemente se quedó con el lugar robado).
                overtakeWarningActive = true
                overtakeWarningTimer = OVERTAKE_WARNING_SECONDS
                warningBaseText = "SIGUE SIN DEVOLVER LA POSICIÓN"
                showBanner("ADELANTAMIENTO BAJO SAFETY CAR", warningBaseText .. " (" .. OVERTAKE_WARNING_SECONDS .. "s)", rgbm(1.0, 0.65, 0.0, 1), 16)
                playSound(overtakeWarningSound, "aviso de adelantamiento (reincidencia)")
                table.insert(pendingChats, "⚠️ " .. car:driverName() .. " sigue sin devolver la posición - " ..
                    OVERTAKE_WARNING_SECONDS .. "s más antes de otra sanción")
                ac.log("[PENALTIES] " .. car:driverName() .. " sigue sin devolver la posición tras la sanción, nuevo aviso")
            end

            if currentPos ~= nil then
                lastKnownPosition = currentPos
            end
        end
    end

    -- Avisa cuando termina mi propia sanción, para que los demás dejen de "perdonar"
    -- adelantamientos por mi culpa.
    if myGearboxLockEndTime ~= nil and sim.currentSessionTime >= myGearboxLockEndTime then
        myGearboxLockEndTime = nil
        scPenaltyActiveEvent({ active = false })
        ac.log("[PENALTIES] Mi sanción de caja bloqueada terminó")
    end
end
