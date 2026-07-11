local sim = ac.getSim()
local car = ac.getCar(0)
local adminFlag = ui.OnlineExtraFlags.Admin

-- ===== Modo de edición compartido: mismo evento que el resto de los scripts. Este cartel es
-- el ID 7 -- solo se muestra cuando el menú lo tiene seleccionado. =====
local editingPanelId = 0
local MY_PREVIEW_ID = 7
panelPreviewEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Panel Preview Mode"),
    selectedId = ac.StructItem.float()
}, function(sender, message)
    if sender:driverName() ~= car:driverName() then return end
    editingPanelId = message.selectedId
end,
ac.SharedNamespace.ServerScript)

-- ===== Ocultar todos los carteles de todos los scripts menos el que se está arrastrando =====
-- ID global de este cartel: 7 (ver la lista completa de IDs en announcements.lua)
local MY_PANEL_ID = 7
local globalDragging = false
local globalDragPanelId = 0

panelDragStateEvent3 = ac.OnlineEvent({
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

-- ===== Diagnóstico: captura de la grilla real =====
-- Cuando arranca una sesión de Carrera, el juego teletransporta a cada auto a su casillero
-- de grilla correcto. Unos segundos después de ese momento (para que se termine de acomodar
-- todo el mundo), guardamos la posición de cada auto conectado junto a su puesto de grilla --
-- así armamos nuestro propio "mapa" de casilleros, sin depender de ningún dato de la pista.

-- Campo de posición en carrera (mismo patrón que usamos en penalties.lua)
local positionField = nil
local function findPositionField()
    local candidates = { "racePosition", "position", "leaderboardPosition", "place", "raceOrder", "racePos", "sessionPosition" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        if ok and type(val) == "number" and val > 0 then
            ac.log("[FORMATION] Campo de posición encontrado: car." .. name .. " = " .. tostring(val))
            positionField = name
            return
        end
    end
    ac.log("[FORMATION] No se encontró campo de posición")
end

-- Campo de "hacia dónde mira el auto" (para poder armar una flecha más adelante). Nunca lo
-- probamos en este proyecto -- este diagnóstico es solo para confirmar si existe.
local lookField = nil
local function findLookField()
    local candidates = { "look", "direction", "heading", "carDirection", "forward", "lookVector" }
    for _, name in ipairs(candidates) do
        local ok, val = pcall(function() return car[name] end)
        ac.log("[FORMATION] car." .. name .. " = " .. tostring(ok and val or "no existe"))
        if ok and val ~= nil and lookField == nil then
            lookField = name
        end
    end
end

local gridCaptured = false
local gridCaptureTimer = 0
local GRID_CAPTURE_DELAY_SECONDS = 4 -- espera a que se termine de acomodar todo el mundo

-- Va guardando el último puesto de clasificación válido de cada auto MIENTRAS dura la sesión
-- de Qualify (ahí racePosition sí se actualiza bien con cada vuelta). Una vez que arranca la
-- Carrera, este valor queda "congelado" -- no lo seguimos leyendo, porque ya sabemos que en
-- Carrera se queda pegado en un valor viejo hasta que cada uno cruza la línea de meta.
local lastKnownGridPosition = {} -- [carIndex] = puesto

local function updateQualifyPositionTracking()
    if positionField == nil then return end
    if sim.raceSessionType ~= ac.SessionType.Qualify then return end

    local okCount, carsCount = pcall(function() return sim.carsCount end)
    if not okCount then return end

    for i = 0, carsCount - 1 do
        local okOther, otherCar = pcall(function() return ac.getCar(i) end)
        if okOther and otherCar then
            local okConn, connected = pcall(function() return otherCar.isConnected end)
            if okConn and connected then
                local okPos, pos = pcall(function() return otherCar[positionField] end)
                if okPos and type(pos) == "number" and pos > 0 then
                    lastKnownGridPosition[i] = pos
                end
            end
        end
    end
end

local function captureGridMap()
    local okCount, carsCount = pcall(function() return sim.carsCount end)
    if not okCount then
        ac.log("[FORMATION] No se pudo leer sim.carsCount para capturar la grilla")
        return
    end

    ac.log("[FORMATION] --- Capturando mapa de grilla ---")
    for i = 0, carsCount - 1 do
        local okOther, otherCar = pcall(function() return ac.getCar(i) end)
        if okOther and otherCar then
            local okConn, connected = pcall(function() return otherCar.isConnected end)
            if okConn and connected then
                local okName, name = pcall(function() return otherCar:driverName() end)
                local okPos, pos = pcall(function() return otherCar.position end)
                local okSpline, splinePos = pcall(function() return otherCar.splinePosition end)
                local okGrid = false
                local gridPos = nil
                if positionField ~= nil then
                    okGrid, gridPos = pcall(function() return otherCar[positionField] end)
                end
                ac.log("[FORMATION] Auto " .. i .. " (" .. tostring(okName and name or "?") .. "): grid(quali_congelado)=" ..
                    tostring(lastKnownGridPosition[i]) .. ", grid(en_vivo, sabemos que no sirve)=" ..
                    tostring(okGrid and gridPos or "no disponible") .. ", splinePosition=" ..
                    tostring(okSpline and splinePos or "no disponible") .. ", position=" .. tostring(okPos and pos or "no disponible"))
            end
        end
    end
end

ac.onSessionStart(function()
    if sim.raceSessionType == ac.SessionType.Race then
        gridCaptured = false
        gridCaptureTimer = GRID_CAPTURE_DELAY_SECONDS
    end
end)

local state = {
    enabled = false,
    alpha = 0
}
local title = "VUELTA DE FORMACION"
local subtitle = "MANTENER POSICIONES"

local lightCount = 6
local neonYellow = rgbm(1.6, 1.1, 0.05, 1)

local screen = {
    w = sim.windowWidth,
    h = sim.windowHeight
}

formationEvent = ac.OnlineEvent({
    key = ac.StructItem.key("Formation Lap"),
    enabled = ac.StructItem.boolean()
}, function(sender, message)
    state.enabled = message.enabled
    ac.log(
        "[FORMATION] " ..
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
    findPositionField()
    findLookField()
    if config:get("FORMATION", "ADMIN_ONLY", 1) == 0 then
        adminFlag = ui.OnlineExtraFlags.None
    else
        adminFlag = ui.OnlineExtraFlags.Admin
    end
    ui.registerOnlineExtra(
        ui.Icons.Warning,
        "🏁 Vuelta Previa",
        function()
            return true
        end,
        nil,
        function()
            state.enabled = not state.enabled
            formationEvent({
                enabled = state.enabled
            })
            ac.log("[FORMATION] Estado: " .. tostring(state.enabled))
        end,
        adminFlag
    )
end)

function script.update(dt)
    updateQualifyPositionTracking()

    if not gridCaptured and gridCaptureTimer > 0 then
        gridCaptureTimer = gridCaptureTimer - dt
        if gridCaptureTimer <= 0 then
            gridCaptured = true
            captureGridMap()
        end
    end

    local speed = 3.5
    if state.enabled or editingPanelId == MY_PREVIEW_ID then
        state.alpha = math.min(state.alpha + dt * speed, 1)
    else
        state.alpha = math.max(state.alpha - dt * speed, 0)
    end
end

local function alphaColor(r, g, b, mult)
    return rgbm(r, g, b, state.alpha * (mult or 1))
end

local function drawInfoPanel(centerX, y)
    local panelWidth = 420
    local panelHeight = 110
    local x = centerX - panelWidth * 0.5

    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), alphaColor(0, 0, 0, 0.88), 10)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), alphaColor(1.0, 0.82, 0.0, 1), 10, 0, 3)

    ui.pushFont(ui.Font.Title)
    local titleSize = ui.measureText(title)
    ui.setCursor(vec2(x + (panelWidth - titleSize.x) * 0.5, y + 18))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1.0, 0.82, 0.0))
    ui.text(title)
    ui.popStyleColor()
    ui.popFont()

    ui.pushFont(ui.Font.Main)
    local subSize = ui.measureText(subtitle)
    ui.setCursor(vec2(x + (panelWidth - subSize.x) * 0.5, y + 62))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1, 1, 1))
    ui.text(subtitle)
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

    local blinkOn = math.floor(sim.currentSessionTime / 400) % 2 == 0

    for i = 1, lightCount, 1 do
        local center = vec2(lightsStartX + (i - 1) * spacing, lightsY)

        ui.drawCircleFilled(center, radius + 6, alphaColor(0.10, 0.10, 0.10, 1), 32)
        ui.drawCircle(center, radius + 6, alphaColor(0.22, 0.22, 0.22, 1), 32, 1.5)

        if blinkOn then
            ui.drawCircleFilled(center, radius * 2.1, rgbm(neonYellow.r, neonYellow.g, neonYellow.b, state.alpha * 0.12), 32)
            ui.drawCircleFilled(center, radius * 1.5, rgbm(neonYellow.r, neonYellow.g, neonYellow.b, state.alpha * 0.28), 32)
            ui.drawCircleFilled(center, radius, rgbm(neonYellow.r, neonYellow.g, neonYellow.b, state.alpha), 32)
            ui.drawCircle(center, radius, alphaColor(1, 1, 1, 0.35), 32, 1)
        else
            ui.drawCircleFilled(center, radius, alphaColor(0.16, 0.02, 0.02, 1), 32)
        end
    end
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
local cfg = ac.storage({
    posX = 0.5,      -- proporción de pantalla (centro horizontal del conjunto)
    posY = 90 / 1080  -- proporción de pantalla (borde superior del conjunto)
})

local dragging = false
local dragOffsetX, dragOffsetY = 0, 0
local blockWidth, blockHeight = 420, 226

function script.drawUI()
    if state.alpha <= 0 or shouldHideForDrag() then
        return
    end

    local panelHeight = 110
    local centerX = cfg.posX * screen.w
    local panelY = cfg.posY * screen.h
    local gantryY = panelY + panelHeight + 20

    local blockX = centerX - blockWidth * 0.5
    local blockY = panelY

    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()

    if mp ~= nil then
        local overBlock = mp.x >= blockX and mp.x <= blockX + blockWidth and mp.y >= blockY and mp.y <= blockY + blockHeight

        if not dragging and mouseIsDown and overBlock then
            dragging = true
            dragOffsetX = mp.x - blockX
            dragOffsetY = mp.y - blockY
            panelDragStateEvent3({ dragging = true, panelId = MY_PANEL_ID })
        end

        if dragging then
            if mouseIsDown then
                blockX = mp.x - dragOffsetX
                blockY = mp.y - dragOffsetY
                centerX = blockX + blockWidth * 0.5
                panelY = blockY
                gantryY = panelY + panelHeight + 20
                cfg.posX = centerX / screen.w
                cfg.posY = panelY / screen.h
            else
                dragging = false
                panelDragStateEvent3({ dragging = false, panelId = 0 })
            end
        end
    end

    drawInfoPanel(centerX, panelY)
    drawGantry(centerX, gantryY)
end
