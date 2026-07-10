local sim = ac.getSim()
local car = ac.getCar(0)

local screen = { w = sim.windowWidth, h = sim.windowHeight }
ac.onResolutionChange(function()
    screen.w = ac.getSim().windowWidth
    screen.h = ac.getSim().windowHeight
end)

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
    local candidates = { "isUnderBlueFlag", "blueFlag", "hasBlueFlag", "underBlueFlag", "showBlueFlag" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "boolean" then
            ac.log("[PENALTIES] Campo de bandera azul encontrado: car." .. name .. " = " .. tostring(val))
            blueFlagField = name
            return
        end
    end
    ac.log("[PENALTIES] No se encontró campo de bandera azul -> ese aviso queda desactivado")
end

local function isUnderBlueFlag()
    if blueFlagField == nil then return false end
    local ok, val = pcall(function() return car[blueFlagField] end)
    if ok and val == true then return true end
    return false
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

-- ===== Cartel en pantalla (mismo estilo F1 usado en announcements.lua: fondo negro, marco de color) =====
local banner = { label = "", value = "", color = rgbm(1, 1, 1, 1), timer = 0, alpha = 0 }

local function showBanner(label, value, color, duration)
    banner.label = label
    banner.value = value
    banner.color = color
    banner.timer = duration
end

local pendingChats = {}

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

-- Contador compartido: cuántos autos están cumpliendo la sanción en este momento. Mientras
-- sea > 0, no se arrancan avisos nuevos para nadie -- si alguien está frenado cumpliendo la
-- sanción, es normal que otros autos lo pasen, y eso no debe contar como una infracción de ellos.
local penaltyActiveCount = 0
local function isAnyoneUnderScPenalty() return penaltyActiveCount > 0 end

scPenaltyActiveEvent = ac.OnlineEvent({
    key = ac.StructItem.key("SC Overtake Penalty Active"),
    active = ac.StructItem.boolean()
}, function(sender, message)
    if message.active then
        penaltyActiveCount = penaltyActiveCount + 1
    else
        penaltyActiveCount = math.max(0, penaltyActiveCount - 1)
    end
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
        -- Si se apaga el SC en medio de un aviso pendiente, se cancela: ya no aplica sancionar
        -- algo que pasó bajo un régimen que ya terminó.
        if overtakeWarningActive then
            overtakeWarningActive = false
            banner.timer = 0
            ac.log("[PENALTIES] Safety Car desactivado con aviso pendiente -> se cancela, sin sanción")
        end
    end
end,
ac.SharedNamespace.ServerScript)

-- ===== Sonido de bandera azul =====
local blueFlagSoundURL = ""
local blueFlagSound = nil
local soundVolumeMultiplier = 2.5

ac.onOnlineWelcome(function(message, config)
    findPositionField()
    findBlueFlagField()
    findInPitField()

    blueFlagSoundURL = config:get("PENALTIES", "BLUEFLAG_SOUND_URL", "")
    soundVolumeMultiplier = config:get("PENALTIES", "SOUND_VOLUME_MULTIPLIER", 2.5)
    GEARBOX_LOCK_SECONDS = config:get("PENALTIES", "GEARBOX_LOCK_SECONDS", 5)
    if blueFlagSoundURL ~= "" then
        local ok, result = pcall(function() return ui.MediaPlayer(blueFlagSoundURL) end)
        if ok then
            blueFlagSound = result
            ac.log("[PENALTIES] Sonido de bandera azul cargado OK")
        else
            ac.log("[PENALTIES] ERROR cargando sonido de bandera azul: " .. tostring(result))
        end
    end
end)

function script.drawUI()
    -- El chat solo se manda desde acá (drawUI), que no corre en la copia headless del
    -- servidor, para evitar que el mismo aviso se mande dos veces.
    for _, msg in ipairs(pendingChats) do
        ac.sendChatMessage(msg)
    end
    pendingChats = {}

    if banner.alpha > 0 then
        local a = banner.alpha
        local c = banner.color
        local panelWidth = 620
        local panelHeight = 96
        local x = (screen.w - panelWidth) * 0.5
        local y = 200 -- más abajo, para no chocar con los carteles de announcements.lua

        ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(0, 0, 0, 0.85 * a), 10)
        ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), rgbm(c.r, c.g, c.b, a), 10, 0, 3)

        ui.pushFont(ui.Font.Small)
        local labelText = string.upper(banner.label)
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
end

-- ===== Loop principal =====
local wasUnderBlueFlag = false

function script.update(dt)
    if banner.timer > 0 then
        banner.timer = banner.timer - dt
        banner.alpha = math.min(banner.alpha + 0.10, 1)
    else
        banner.alpha = math.max(banner.alpha - 0.10, 0)
    end

    -- Bandera azul: aviso simple (cartel + sonido), sin sanción automática.
    -- Se dispara solo en el momento en que la bandera pasa de apagada a encendida (flanco).
    local nowUnderBlueFlag = isUnderBlueFlag()
    if nowUnderBlueFlag and not wasUnderBlueFlag then
        showBanner("ATENCIÓN", "DAR PASO A VEHÍCULOS RÁPIDOS", rgbm(0.15, 0.45, 1.0, 1), 5)
        if blueFlagSound then
            local ok, err = pcall(function()
                blueFlagSound:setVolume(ac.getAudioVolume(ac.AudioChannel.Main) * soundVolumeMultiplier)
                blueFlagSound:play()
            end)
            if not ok then
                ac.log("[PENALTIES] ERROR reproduciendo sonido de bandera azul: " .. tostring(err))
            end
        end
        ac.log("[PENALTIES] Bandera azul mostrada a " .. car:driverName())
    end
    wasUnderBlueFlag = nowUnderBlueFlag

    -- Adelantamiento bajo Safety Car: aviso de 15 segundos para devolver la posición
    -- antes de aplicar la sanción real. No arranca un aviso nuevo si alguien más está
    -- cumpliendo la sanción en este momento (evita marcar como infractores a los autos
    -- que simplemente pasan a alguien que está frenado cumpliendo su propia sanción).
    if scActive and positionField ~= nil and not isCarInPit() then
        local currentPos = getRacePosition()

        if not overtakeWarningActive then
            if currentPos ~= nil and lastKnownPosition ~= nil and currentPos < lastKnownPosition and not isAnyoneUnderScPenalty() then
                -- Se detectó una mejora de posición: arranca el aviso, todavía sin sancionar
                overtakeWarningActive = true
                overtakeWarningTimer = OVERTAKE_WARNING_SECONDS
                positionBeforeOvertake = lastKnownPosition

                showBanner("ADELANTAMIENTO BAJO SAFETY CAR", "DEVOLVER LA POSICIÓN", rgbm(1.0, 0.65, 0.0, 1), 16)
                table.insert(pendingChats, "⚠️ " .. car:driverName() .. " adelantó bajo Safety Car - tiene " ..
                    OVERTAKE_WARNING_SECONDS .. "s para devolver la posición")
                ac.log("[PENALTIES] Aviso de adelantamiento bajo SC para " .. car:driverName() ..
                    " (posición a devolver: " .. tostring(positionBeforeOvertake) .. ")")
            end
            if currentPos ~= nil then
                lastKnownPosition = currentPos
            end
        else
            -- Ya está en aviso: chequea si devolvió la posición o si se le acabó el tiempo
            if currentPos ~= nil and currentPos >= positionBeforeOvertake then
                overtakeWarningActive = false
                banner.timer = 0 -- corta el cartel de aviso de inmediato
                table.insert(pendingChats, "✅ " .. car:driverName() .. " devolvió la posición, sin sanción")
                ac.log("[PENALTIES] " .. car:driverName() .. " devolvió la posición a tiempo, sin sanción")
                lastKnownPosition = currentPos
            else
                overtakeWarningTimer = overtakeWarningTimer - dt
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
                    table.insert(pendingChats, "🚫 " .. car:driverName() .. " sancionado (caja bloqueada) por no devolver la posición bajo Safety Car")

                    if currentPos ~= nil then
                        lastKnownPosition = currentPos
                    end
                end
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
