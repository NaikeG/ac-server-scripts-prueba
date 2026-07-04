local sim = ac.getSim()
local car = ac.getCar(0)
local adminFlag = ui.OnlineExtraFlags.Admin

local state = {
    enabled = false,
    alpha = 0
}

-- Config (se sobreescribe desde Extra Options, sección [SAFETYCAR])
-- IMPORTANTE: escala 0-100 (porcentaje), NO 0-1. Ej: 80 = 80% de restricción.
local restrictorValue = 80
local ballastValue = 150 -- kg extra que se le suman al auto mientras el SC está afuera

local function applyRestrictor(value)
    local ok, err = pcall(function() physics.setCarRestrictor(0, value) end)
    if ok then
        local okRead, currentVal = pcall(function() return car.restrictor end)
        ac.log("[SAFETYCAR] Restrictor aplicado con éxito (valor pedido: " .. tostring(value) ..
            ", car.restrictor ahora: " .. tostring(okRead and currentVal or "no se pudo leer") .. ")")
    else
        ac.log("[SAFETYCAR] ERROR aplicando restrictor: " .. tostring(err))
    end
    return ok
end

local function applyBallast(value)
    local ok, err = pcall(function() physics.setCarBallast(0, value) end)
    if ok then
        local okRead, currentVal = pcall(function() return car.ballast end)
        ac.log("[SAFETYCAR] Ballast aplicado con éxito (valor pedido: " .. tostring(value) ..
            " kg, car.ballast ahora: " .. tostring(okRead and currentVal or "no se pudo leer") .. ")")
    else
        ac.log("[SAFETYCAR] ERROR aplicando ballast: " .. tostring(err))
    end
    return ok
end

local function applyRestrictorQuiet(value)
    pcall(function() physics.setCarRestrictor(0, value) end)
end

local function applyBallastQuiet(value)
    pcall(function() physics.setCarBallast(0, value) end)
end

local function onSafetyCarStateChanged()
    if state.enabled then
        applyRestrictor(restrictorValue)
        applyBallast(ballastValue)
        ac.log("[SAFETYCAR] Activado: restrictor=" .. tostring(restrictorValue) .. " ballast=" .. tostring(ballastValue))
    else
        applyRestrictor(0)
        applyBallast(0)
        ac.log("[SAFETYCAR] Desactivado, potencia y peso normales restaurados")
    end
end

local screen = {
    w = sim.windowWidth,
    h = sim.windowHeight
}

-- Sonido (se reproduce una sola vez al activar el Safety Car)
local activateURL = ""
local activateSound = nil
local soundVolumeMultiplier = 2.5
local activateSoundPlayed = false

safetyCarEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Safety Car"),
    enabled = ac.StructItem.boolean()
}, function(sender, message)
    state.enabled = message.enabled
    if state.enabled then
        activateSoundPlayed = false
    end
    onSafetyCarStateChanged()
    ac.log(
        "[SAFETYCAR] " ..
        sender:driverName() ..
        " -> " ..
        tostring(state.enabled)
    )
end,
ac.SharedNamespace.ServerScript)

ac.onResolutionChange(function()
    screen.w = ac.getSim().windowWidth
    screen.h = ac.getSim().windowHeight
end)

ac.onOnlineWelcome(function(message, config)
    if config:get("SAFETYCAR", "ADMIN_ONLY", 1) == 0 then
        adminFlag = ui.OnlineExtraFlags.None
    else
        adminFlag = ui.OnlineExtraFlags.Admin
    end

    restrictorValue = config:get("SAFETYCAR", "RESTRICTOR_VALUE", 80)
    ballastValue = config:get("SAFETYCAR", "BALLAST_VALUE", 150)

    activateURL = config:get("SAFETYCAR", "SOUND_ACTIVATE_URL", "")
    soundVolumeMultiplier = config:get("SAFETYCAR", "SOUND_VOLUME_MULTIPLIER", 2.5)
    if activateURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(activateURL) end)
        if ok then
            activateSound = result
            ac.log("[SAFETYCAR] Sonido cargado OK: " .. activateURL)
        else
            ac.log("[SAFETYCAR] ERROR cargando sonido (" .. activateURL .. "): " .. tostring(result))
        end
    end

    ui.registerOnlineExtra(
        ui.Icons.Warning,
        "🚧 Safety Car",
        function() return true end,
        nil,
        function()
            state.enabled = not state.enabled
            if state.enabled then
                activateSoundPlayed = false
            end
            onSafetyCarStateChanged()
            safetyCarEvent({ enabled = state.enabled })
            ac.log("[SAFETYCAR] Estado: " .. tostring(state.enabled))
        end,
        adminFlag
    )
end)

function script.update(dt)
    local speed = 3.5
    if state.enabled then
        state.alpha = math.min(state.alpha + dt * speed, 1)
        applyRestrictorQuiet(restrictorValue)
        applyBallastQuiet(ballastValue)
    else
        state.alpha = math.max(state.alpha - dt * speed, 0)
    end

    if state.enabled and not activateSoundPlayed and activateSound then
        activateSoundPlayed = true
        local ok, err = pcall(function()
            activateSound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
            activateSound:play()
        end)
        if not ok then
            ac.log("[SAFETYCAR] ERROR reproduciendo sonido: " .. tostring(err))
        end
    end
end

local function alphaColor(r, g, b, mult)
    return rgbm(r, g, b, state.alpha * (mult or 1))
end

local function drawContent(originX, originY)
    local boxWidth = 150
    local blackHeight = 70
    local yellowHeight = 80
    local x = originX
    local y = originY

    -- Caja negra con "SC"
    ui.drawRectFilled(vec2(x, y), vec2(x + boxWidth, y + blackHeight), alphaColor(0.05, 0.05, 0.05, 1))
    ui.drawRect(vec2(x, y), vec2(x + boxWidth, y + blackHeight), alphaColor(0.25, 0.25, 0.25, 1), 0, 0, 2)

    ui.pushFont(ui.Font.Huge)
    local text = "SC"
    local textSize = ui.measureText(text)
    ui.setCursor(vec2(x + (boxWidth - textSize.x) * 0.5, y + (blackHeight - textSize.y) * 0.5))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1, 1, 1))
    ui.text(text)
    ui.popStyleColor()
    ui.popFont()

    -- Franja amarilla intermitente
    local blinkOn = math.floor(sim.currentSessionTime / 400) % 2 == 0
    local barY = y + blackHeight
    if blinkOn then
        ui.drawRectFilled(vec2(x, barY), vec2(x + boxWidth, barY + yellowHeight), alphaColor(1.0, 0.82, 0.0, 1))
    else
        ui.drawRectFilled(vec2(x, barY), vec2(x + boxWidth, barY + yellowHeight), alphaColor(0.12, 0.10, 0.02, 1))
    end
    ui.drawRect(vec2(x, barY), vec2(x + boxWidth, barY + yellowHeight), alphaColor(0.25, 0.25, 0.25, 1), 0, 0, 2)

    return boxWidth, blackHeight + yellowHeight
end

local function drawSidePanel(x, y, height)
    local panelWidth = 300
    local title = "SAFETY CAR"
    local subtitle = "MANTENER POSICIONES"

    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + height), alphaColor(0.03, 0.03, 0.03, 0.92), 10)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + height), alphaColor(1.0, 0.82, 0.0, 1), 10, 0, 3)

    ui.pushFont(ui.Font.Title)
    local titleSize = ui.measureText(title)
    ui.setCursor(vec2(x + (panelWidth - titleSize.x) * 0.5, y + (height * 0.5) - titleSize.y - 4))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1.0, 0.82, 0.0))
    ui.text(title)
    ui.popStyleColor()
    ui.popFont()

    ui.pushFont(ui.Font.Main)
    local subSize = ui.measureText(subtitle)
    ui.setCursor(vec2(x + (panelWidth - subSize.x) * 0.5, y + (height * 0.5) + 6))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1, 1, 1))
    ui.text(subtitle)
    ui.popStyleColor()
    ui.popFont()

    return panelWidth
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

-- Posición guardada por el usuario (persiste entre sesiones, es individual de cada piloto)
local cfg = ac.storage({
    posX = 552 / 1920,  -- proporción de pantalla, no píxeles fijos
    posY = 213 / 1080
})

local dragging = false
local dragOffsetX, dragOffsetY = 0, 0
local boxW, boxH = 150, 150

function script.drawUI()
    if state.alpha <= 0 then
        return
    end

    local boxX = cfg.posX * screen.w
    local boxY = cfg.posY * screen.h

    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()

    if mp ~= nil then
        local overBox = mp.x >= boxX and mp.x <= boxX + boxW and mp.y >= boxY and mp.y <= boxY + boxH

        if not dragging and mouseIsDown and overBox then
            dragging = true
            dragOffsetX = mp.x - boxX
            dragOffsetY = mp.y - boxY
        end

        if dragging then
            if mouseIsDown then
                boxX = mp.x - dragOffsetX
                boxY = mp.y - dragOffsetY
                cfg.posX = boxX / screen.w
                cfg.posY = boxY / screen.h
            else
                dragging = false
            end
        end
    end

    boxW, boxH = drawContent(boxX, boxY)
    drawSidePanel(boxX + boxW + 16, boxY, boxH)
end

