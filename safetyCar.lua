local sim = ac.getSim()
local adminFlag = ui.OnlineExtraFlags.Admin

local state = {
    enabled = false,
    alpha = 0
}

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

-- Posición guardada por el usuario (persiste entre sesiones, es individual de cada piloto)
local cfg = ac.storage({
    posX = 552 / 1920,  -- guardado como proporción de pantalla, no en píxeles fijos
    posY = 213 / 1080
})

local movableFailed = false

function script.drawUI()
    if state.alpha <= 0 then
        return
    end

    if not movableFailed then
        local ok, err = pcall(function()
            local ret1, ret2 = ui.transparentWindow("safetyCarSignWindow", vec2(cfg.posX * screen.w, cfg.posY * screen.h), vec2(150, 150), function()
                drawContent(0, 0)
            end)
            -- Si la función devuelve la posición actual de la ventana, la guardamos para la próxima sesión
            for _, ret in ipairs({ ret1, ret2 }) do
                if type(ret) == "userdata" and ret.x ~= nil and ret.y ~= nil then
                    cfg.posX = ret.x / screen.w
                    cfg.posY = ret.y / screen.h
                end
            end
        end)
        if not ok then
            movableFailed = true
            ac.log("[SAFETYCAR] ERROR con ventana movible (se usa posición fija de respaldo): " .. tostring(err))
        end
    end

    if movableFailed then
        drawContent(cfg.posX * screen.w, cfg.posY * screen.h)
    end
end

