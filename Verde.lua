local health = { t = 0, lastDraw = 0, welcome = false } -- autodiagnóstico, ver el final del archivo
-- ===== Cartel "VERDE" =====
-- Mismo estilo visual que el ícono de Safety Car (caja negra + franja intermitente abajo),
-- pero en verde, con parpadeo más rápido, y texto "VERDE" en vez de "SC". Completamente
-- independiente del script de Safety Car -- se activa y desactiva con su propio botón, sin
-- ninguna conexión al estado de Safety Car (ni se prende ni se apaga junto con él).

local sim = ac.getSim()
local car = ac.getCar(0)
local adminFlag = ui.OnlineExtraFlags.Admin

local screen = {
    w = sim.windowWidth,
    h = sim.windowHeight
}

local state = { enabled = false, alpha = 0 }

-- Segundos que el cartel queda visible antes de apagarse solo
local AUTO_OFF_SECONDS = 3
local autoOffTimer = 0

-- Sonido al activarse -- así, aunque el cartel no llegue a verse por el bug conocido de
-- CSP/apps, el piloto se entera igual por el audio. La URL se completa después en Extra
-- Options (queda vacía por defecto, sin sonido, hasta que se consiga un archivo).
local greenSoundURL = ""
local greenSound = nil
local soundVolumeMultiplier = 2.5

local function playSound(sound, label)
    if sound == nil then return end
    local ok, err = pcall(function()
        sound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
        sound:play()
    end)
    if not ok then
        ac.log("[GREENFLAG] ERROR reproduciendo sonido (" .. label .. "): " .. tostring(err))
    end
end

local function alphaColor(r, g, b, mult)
    return rgbm(r, g, b, state.alpha * (mult or 1))
end

-- ===== Contenido del cartel: caja negra "VERDE" + franja verde intermitente (rápida) =====
local function drawContent(originX, originY)
    local boxWidth = 150
    local blackHeight = 70
    local greenHeight = 80
    local x = originX
    local y = originY

    ui.drawRectFilled(vec2(x, y), vec2(x + boxWidth, y + blackHeight), alphaColor(0.05, 0.05, 0.05, 1))
    ui.drawRect(vec2(x, y), vec2(x + boxWidth, y + blackHeight), alphaColor(0.25, 0.25, 0.25, 1), 0, 0, 2)

    -- "VERDE" es más largo que "SC", así que usa Title (no Huge, que no entraría en 150px)
    ui.pushFont(ui.Font.Title)
    local text = "VERDE"
    local textSize = ui.measureText(text)
    ui.setCursor(vec2(x + (boxWidth - textSize.x) * 0.5, y + (blackHeight - textSize.y) * 0.5))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1, 1, 1))
    ui.text(text)
    ui.popStyleColor()
    ui.popFont()

    -- Franja verde intermitente -- el doble de rápido que la del Safety Car (200ms en vez
    -- de 400ms), como se pidió.
    local blinkOn = math.floor(sim.currentSessionTime / 200) % 2 == 0
    local barY = y + blackHeight
    if blinkOn then
        ui.drawRectFilled(vec2(x, barY), vec2(x + boxWidth, barY + greenHeight), alphaColor(0.1, 0.85, 0.15, 1))
    else
        ui.drawRectFilled(vec2(x, barY), vec2(x + boxWidth, barY + greenHeight), alphaColor(0.02, 0.14, 0.03, 1))
    end
    ui.drawRect(vec2(x, barY), vec2(x + boxWidth, barY + greenHeight), alphaColor(0.25, 0.25, 0.25, 1), 0, 0, 2)

    return boxWidth, blackHeight + greenHeight
end

-- ===== Posición arrastrable (propia, independiente de todos los demás scripts) =====
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

local panelPosCfg = ac.storage({
    posX = (screen.w - 150) * 0.5 / screen.w,
    posY = 300 / 1080
})
local dragging = false
local dragOffsetX, dragOffsetY = 0, 0

-- ID global de este cartel: 12 (ver la lista completa de IDs en announcements.lua)
local MY_PANEL_ID = 12
local MY_PREVIEW_ID = 12
local globalDragging = false
local globalDragPanelId = 0
local editingPanelId = 0

panelPreviewEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Preview Mode"),
    selectedId = ac.StructItem.float()
}, function(sender, message)
    if sender:driverName() ~= car:driverName() then return end
    editingPanelId = message.selectedId
end,
ac.SharedNamespace.ServerScript)

panelDragStateEventGreen = ac.OnlineEvent({
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

-- ===== Evento de activación, 100% propio -- no tiene ninguna relación con Safety Car =====
greenFlagEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Green Flag Sign"),
    enabled = ac.StructItem.boolean()
}, function(sender, message)
    state.enabled = message.enabled
    if state.enabled then
        autoOffTimer = AUTO_OFF_SECONDS
        playSound(greenSound, "verde activado")
    else
        autoOffTimer = 0
    end
    ac.log("[GREENFLAG] " .. sender:driverName() .. " -> " .. tostring(state.enabled))
end,
ac.SharedNamespace.ServerScript)

ac.onOnlineWelcome(function(message, config)
    if config:get("GREENFLAG", "ADMIN_ONLY", 1) == 0 then
        adminFlag = ui.OnlineExtraFlags.None
    else
        adminFlag = ui.OnlineExtraFlags.Admin
    end

    greenSoundURL = config:get("GREENFLAG", "SOUND_URL", "")
    soundVolumeMultiplier = config:get("GREENFLAG", "SOUND_VOLUME_MULTIPLIER", 2.5)
    if greenSoundURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(greenSoundURL) end)
        if ok then
            greenSound = result
            ac.log("[GREENFLAG] Sonido cargado OK: " .. greenSoundURL)
        else
            ac.log("[GREENFLAG] ERROR cargando sonido (" .. greenSoundURL .. "): " .. tostring(result))
        end
    end

    ui.registerOnlineExtra(
        ui.Icons.Flag,
        "🟢 Verde",
        function() return true end,
        nil,
        function()
            state.enabled = not state.enabled
            autoOffTimer = state.enabled and AUTO_OFF_SECONDS or 0
            greenFlagEvent({ enabled = state.enabled })
            ac.log("[GREENFLAG] Estado: " .. tostring(state.enabled))
        end,
        adminFlag
    )
end)

ac.onResolutionChange(function()
    screen.w = ac.getSim().windowWidth
    screen.h = ac.getSim().windowHeight
end)

function script.update(dt)
    health.t = health.t + dt
    if health.tick then health.tick(dt) end
    -- Se actualiza el ancho/alto de pantalla TODOS los cuadros -- ver nota igual en el resto
    -- de los scripts del proyecto sobre por qué (posible causa de carteles invisibles tras
    -- cambiar de cámara a otro auto).
    screen.w = sim.windowWidth
    screen.h = sim.windowHeight

    -- Apagado automático: cada cliente apaga el cartel solo a los AUTO_OFF_SECONDS
    if state.enabled and autoOffTimer > 0 then
        autoOffTimer = autoOffTimer - dt
        if autoOffTimer <= 0 then
            autoOffTimer = 0
            state.enabled = false
        end
    end

    if state.enabled or editingPanelId == MY_PREVIEW_ID then
        state.alpha = math.min(state.alpha + 0.08, 1)
    else
        state.alpha = math.max(state.alpha - 0.08, 0)
    end
end

function script.drawUI()
    health.lastDraw = health.t
    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()

    if dragging and not mouseIsDown then
        dragging = false
        panelDragStateEventGreen({ dragging = false, panelId = 0 })
        ac.log("[GREENFLAG] Arrastre liberado por seguridad")
    end

    if state.alpha <= 0 and editingPanelId ~= MY_PREVIEW_ID then return end
    if shouldHideForDrag() then return end

    local baseX = panelPosCfg.posX * screen.w
    local baseY = panelPosCfg.posY * screen.h
    local boxWidth, boxHeight = 150, 150

    if mp ~= nil then
        local overBox = mp.x >= baseX and mp.x <= baseX + boxWidth and mp.y >= baseY and mp.y <= baseY + boxHeight
        if not dragging and mouseIsDown and overBox then
            dragging = true
            dragOffsetX = mp.x - baseX
            dragOffsetY = mp.y - baseY
            panelDragStateEventGreen({ dragging = true, panelId = MY_PANEL_ID })
        end
        if dragging then
            if mouseIsDown then
                baseX = mp.x - dragOffsetX
                baseY = mp.y - dragOffsetY
                panelPosCfg.posX = baseX / screen.w
                panelPosCfg.posY = baseY / screen.h
            else
                dragging = false
                panelDragStateEventGreen({ dragging = false, panelId = 0 })
            end
        end
    end

    drawContent(baseX, baseY)
end

-- ===================================================================================
-- Autodiagnóstico y reparación suave (mismo bloque en los 7 scripts, ver announcements.lua
-- para el botón de admin y el reporte). ID de este script: 7 (Bandera Verde)
--   1 Anuncios | 2 Penalizaciones | 3 Safety Car | 4 Vuelta Previa | 5 Luces de largada
--   6 Largada en Movimiento | 7 Bandera Verde
-- Qué hace: (1) responde cuando el admin pide un chequeo, informando si este script está
-- corriendo, si recibió la configuración del servidor y si realmente está dibujando
-- (drawUI se ejecutó en los últimos 3 s). (2) Si detecta que corre pero NO dibuja, se
-- repara solo (como mucho una vez cada 30 s). Reparar = reiniciar el estado que ya vimos que
-- deja carteles invisibles: tamaño de pantalla y bloqueos de arrastre. No es una recarga
-- del script (CSP no ofrece eso).
-- ===================================================================================
local HEALTH_SCRIPT_ID = 7
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
    ac.log("[HEALTH] Reparación suave en Bandera Verde (" .. tostring(reason) .. ")" ..
        (okRepair and "" or (" ERROR: " .. tostring(errRepair))))
end

health.tick = function(dt)
    if healthPending and health.t >= healthPending.at then
        local p = healthPending
        healthPending = nil
        pcall(function()
            healthPongEvent({ scriptId = HEALTH_SCRIPT_ID, visualOk = health.ok(), welcome = health.welcome, nonce = p.nonce })
        end)
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
