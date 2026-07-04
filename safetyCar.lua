local sim = ac.getSim()
local car = ac.getCar(0)
local adminFlag = ui.OnlineExtraFlags.Admin

local state = {
    enabled = false,
    alpha = 0
}

-- ===== Congelamiento de posiciones bajo Safety Car =====
local positionFieldName = nil
local positionFieldLogged = false
local function findPositionField()
    if positionFieldLogged then return positionFieldName end
    positionFieldLogged = true
    local candidates = { "racePosition", "position", "leaderboardPosition", "place", "raceOrder", "racePos", "sessionPosition" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "number" and val > 0 then
            ac.log("[SAFETYCAR] Campo de posición encontrado: car." .. name .. " = " .. tostring(val))
            positionFieldName = name
            return name
        end
    end
    ac.log("[SAFETYCAR] No se encontró ningún campo de posición válido en car")
    return nil
end

local function getRacePosition()
    if positionFieldName == nil then
        findPositionField()
    end
    if positionFieldName == nil then return nil end
    local ok, val = pcall(function() return car[positionFieldName] end)
    if ok then return val end
    return nil
end

local frozenPosition = nil
local warningActive = false
local warningTimer = 0
local WARNING_DURATION = 15 -- segundos para devolver la posición antes del Restrictor

local function onSafetyCarStateChanged()
    if state.enabled then
        frozenPosition = getRacePosition()
        warningActive = false
        warningTimer = 0
        if frozenPosition then
            ac.log("[SAFETYCAR] Posición congelada en: " .. tostring(frozenPosition))
        end
    else
        frozenPosition = nil
        warningActive = false
        warningTimer = 0
    end
end

local function applyOvertakeRestrictor(value)
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
    local ok, err = pcall(function() physics.lockUserGearboxFor(5, true) end)
    if not ok then
        ac.log("[SAFETYCAR] ERROR con alternativa de caja: " .. tostring(err))
    end
    return false
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

    findPositionField()
end)

function script.update(dt)
    local speed = 3.5
    if state.enabled then
        state.alpha = math.min(state.alpha + dt * speed, 1)
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

    -- Vigilancia de posiciones congeladas
    if state.enabled and frozenPosition then
        local current = getRacePosition()
        if current then
            if not warningActive and current < frozenPosition then
                -- Adelantamiento detectado: arranca el aviso y la cuenta regresiva
                warningActive = true
                warningTimer = WARNING_DURATION
                ac.sendChatMessage(
                    "⚠️ " .. car:driverName() ..
                    ": ADELANTAMIENTO ILEGAL bajo Safety Car. Devolvé la posición en " ..
                    WARNING_DURATION .. "s o se aplicará un Restrictor."
                )
            elseif warningActive then
                if current >= frozenPosition then
                    -- Devolvió la posición a tiempo
                    warningActive = false
                    warningTimer = 0
                    ac.sendChatMessage(car:driverName() .. " devolvió la posición correctamente.")
                else
                    warningTimer = warningTimer - dt
                    if warningTimer <= 0 then
                        warningActive = false
                        warningTimer = 0
                        ac.sendChatMessage(
                            car:driverName() ..
                            " no devolvió la posición a tiempo. Restrictor aplicado."
                        )
                        applyOvertakeRestrictor(1.0)
                    end
                end
            end
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

-- ===== Arrastre manual con Ctrl + Click (igual gesto que las apps tipo Real Penalty) =====

local ctrlKeyIndex = nil
local function findCtrlKeyIndex()
    local candidates = { "LeftControl", "LCtrl", "Control", "Ctrl", "LeftCtrl", "ControlLeft", "LControl" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return ui.KeyIndex[name] end)
        if ok and val ~= nil then
            ac.log("[SAFETYCAR] Ctrl encontrado como ui.KeyIndex." .. name)
            return val
        end
    end
    ac.log("[SAFETYCAR] No se encontró ninguna variante de Ctrl en ui.KeyIndex")
    return nil
end

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

local function isCtrlDown()
    if not ctrlKeyIndex then return false end
    local ok, val = pcall(function() return ui.keyboardButtonDown(ctrlKeyIndex) end)
    if ok then return val end
    return false
end

-- Posición guardada por el usuario (persiste entre sesiones, es individual de cada piloto)
local cfg = ac.storage({
    posX = 552 / 1920,  -- proporción de pantalla, no píxeles fijos
    posY = 213 / 1080
})

local dragging = false
local dragOffsetX, dragOffsetY = 0, 0
local boxW, boxH = 150, 150

local function drawWarningPanel()
    if not warningActive then return end

    local panelWidth = 520
    local panelHeight = 130
    local x = (screen.w - panelWidth) * 0.5
    local y = 90

    local blink = (math.floor(sim.currentSessionTime / 250) % 2 == 0)
    local borderAlpha = blink and 1 or 0.4

    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0.05, 0.02, 0.02, 0.92), 10)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(1.0, 0.15, 0.1, borderAlpha), 10, 0, 3)

    ui.pushFont(ui.Font.Title)
    local title = "ADELANTAMIENTO ILEGAL"
    local titleSize = ui.measureText(title)
    ui.setCursor(vec2(x + (panelWidth - titleSize.x) * 0.5, y + 14))
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1.0, 0.2, 0.15, 1))
    ui.text(title)
    ui.popStyleColor()
    ui.popFont()

    ui.pushFont(ui.Font.Main)
    local subtitle = "DEVOLVER POSICIÓN"
    local subSize = ui.measureText(subtitle)
    ui.setCursor(vec2(x + (panelWidth - subSize.x) * 0.5, y + 56))
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, 1))
    ui.text(subtitle)
    ui.popStyleColor()
    ui.popFont()

    ui.pushFont(ui.Font.Huge)
    local countdownText = tostring(math.ceil(math.max(warningTimer, 0)))
    local countSize = ui.measureText(countdownText)
    ui.setCursor(vec2(x + (panelWidth - countSize.x) * 0.5, y + 82))
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1.0, 0.85, 0.0, 1))
    ui.text(countdownText)
    ui.popStyleColor()
    ui.popFont()
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

function script.drawUI()
    drawWarningPanel()

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
