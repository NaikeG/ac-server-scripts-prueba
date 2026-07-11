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

local function shouldHideForDrag(id)
    return globalDragging and globalDragPanelId ~= id
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

-- Mapa final: [puesto de grilla] = posición del mundo (vec3) capturada ahí
local gridSlotWorldPos = {}
local myGridPosition = nil

local function captureGridMap()
    local okCount, carsCount = pcall(function() return sim.carsCount end)
    if not okCount then
        ac.log("[FORMATION] No se pudo leer sim.carsCount para capturar la grilla")
        return
    end

    -- Junta a todos los conectados con su splinePosition y posición real
    local entries = {}
    for i = 0, carsCount - 1 do
        local okOther, otherCar = pcall(function() return ac.getCar(i) end)
        if okOther and otherCar then
            local okConn, connected = pcall(function() return otherCar.isConnected end)
            if okConn and connected then
                local okPos, pos = pcall(function() return otherCar.position end)
                local okSpline, splinePos = pcall(function() return otherCar.splinePosition end)
                local okName, name = pcall(function() return otherCar:driverName() end)
                if okPos and okSpline then
                    table.insert(entries, { index = i, name = okName and name or "?", pos = pos, spline = splinePos })
                end
            end
        end
    end

    -- Ordena de mayor a menor splinePosition: el que está más adelante en la pista es P1
    table.sort(entries, function(a, b) return a.spline > b.spline end)

    gridSlotWorldPos = {}
    myGridPosition = nil
    ac.log("[FORMATION] --- Mapa de grilla capturado (ordenado por splinePosition) ---")
    for rank, entry in ipairs(entries) do
        gridSlotWorldPos[rank] = entry.pos
        ac.log("[FORMATION] Puesto " .. rank .. ": " .. entry.name .. " (splinePosition=" .. tostring(entry.spline) .. ")")
        if entry.name == car:driverName() then
            myGridPosition = rank
        end
    end
    ac.log("[FORMATION] Mi puesto de grilla: " .. tostring(myGridPosition))
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

-- Distintas versiones de Lua llaman diferente a la función de arcotangente de 2 argumentos
-- (math.atan2 en Lua 5.1/5.2, math.atan(y,x) en 5.3+) -- probamos las dos, por las dudas.
local function safeAtan2(y, x)
    local ok, result = pcall(function() return math.atan2(y, x) end)
    if ok then return result end
    local ok2, result2 = pcall(function() return math.atan(y, x) end)
    if ok2 then return result2 end
    return math.atan(y / x) -- último recurso, no maneja todos los cuadrantes bien
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

-- Posición del cartel de navegación al puesto de grilla (independiente del combo de arriba)
local navPosCfg = ac.storage({ posX = 0.5, posY = 340 / 1080 })
local navDragging = false
local navDragOffsetX, navDragOffsetY = 0, 0

-- Candado local: como este script tiene 2 carteles (Vuelta Previa y el de navegación al
-- puesto), evita que un click agarre a los dos si llegan a superponerse.
local activeLocalDrag = nil -- nil, "vueltaPrevia" o "nav"

local dragging = false
local dragOffsetX, dragOffsetY = 0, 0
local blockWidth, blockHeight = 420, 226
local navDiagTimer = 0

function script.drawUI()
    if state.alpha <= 0 or shouldHideForDrag(MY_PANEL_ID) then
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

        if not dragging and activeLocalDrag == nil and mouseIsDown and overBlock then
            dragging = true
            activeLocalDrag = "vueltaPrevia"
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
                activeLocalDrag = nil
                panelDragStateEvent3({ dragging = false, panelId = 0 })
            end
        end
    end

    drawInfoPanel(centerX, panelY)
    drawGantry(centerX, gantryY)

    ------------------------------------------------
    -- Cartel de navegación: "TE CORRESPONDE EL PUESTO N" + flecha + distancia
    ------------------------------------------------
    local NAV_PANEL_ID = 10
    local ARROW_ACTIVATION_DISTANCE = 100 -- metros: la flecha recién se activa a esta distancia o menos
    local hasRealTarget = (myGridPosition ~= nil and gridSlotWorldPos[myGridPosition] ~= nil)
    local showNav = (state.enabled and hasRealTarget) or editingPanelId == NAV_PANEL_ID

    -- Diagnóstico throttled (una vez por segundo, para no inundar el log)
    navDiagTimer = navDiagTimer + 1
    if navDiagTimer % 60 == 0 then
        local okT, errT = pcall(function()
            ac.log("[FORMATION] NAV DIAG: state.enabled=" .. tostring(state.enabled) ..
                " hasRealTarget=" .. tostring(hasRealTarget) ..
                " myGridPosition=" .. tostring(myGridPosition) ..
                " showNav=" .. tostring(showNav) ..
                " hideForDrag=" .. tostring(shouldHideForDrag(NAV_PANEL_ID)))
        end)
        if not okT then
            ac.log("[FORMATION] NAV DIAG ERROR: " .. tostring(errT))
        end
    end

    if showNav and not shouldHideForDrag(NAV_PANEL_ID) then
        local okBlock, errBlock = pcall(function()
        local displayPuesto = editingPanelId == NAV_PANEL_ID and 5 or myGridPosition
        local displayDistance = 0
        local displayArrow = "↑"
        local arrowActive = false

        if editingPanelId == NAV_PANEL_ID and not hasRealTarget then
            displayDistance = 42 -- valor de ejemplo
            displayArrow = "↗"
            arrowActive = true
        else
            local target = gridSlotWorldPos[myGridPosition]
            local okLook, look = pcall(function() return car.look end)
            local dx = target.x - car.position.x
            local dz = target.z - car.position.z
            displayDistance = math.sqrt(dx * dx + dz * dz)
            arrowActive = displayDistance <= ARROW_ACTIVATION_DISTANCE
            if okLook and look ~= nil then
                local dot = look.x * dx + look.z * dz
                local cross = look.x * dz - look.z * dx
                local angleDeg = math.deg(safeAtan2(cross, dot))
                if angleDeg < 0 then angleDeg = angleDeg + 360 end
                local sector = math.floor((angleDeg + 22.5) / 45) % 8
                local arrows = { "↑", "↗", "→", "↘", "↓", "↙", "←", "↖" }
                displayArrow = arrows[sector + 1]
            end
        end

        local panelWidth = 340
        local panelHeight = 90
        local baseX = navPosCfg.posX * screen.w - panelWidth * 0.5
        local baseY = navPosCfg.posY * screen.h

        if mp ~= nil then
            local overNav = mp.x >= baseX and mp.x <= baseX + panelWidth and mp.y >= baseY and mp.y <= baseY + panelHeight
            if not navDragging and activeLocalDrag == nil and mouseIsDown and overNav then
                navDragging = true
                activeLocalDrag = "nav"
                navDragOffsetX = mp.x - baseX
                navDragOffsetY = mp.y - baseY
                panelDragStateEvent3({ dragging = true, panelId = NAV_PANEL_ID })
            end
            if navDragging then
                if mouseIsDown then
                    baseX = mp.x - navDragOffsetX
                    baseY = mp.y - navDragOffsetY
                    navPosCfg.posX = (baseX + panelWidth * 0.5) / screen.w
                    navPosCfg.posY = baseY / screen.h
                else
                    navDragging = false
                    activeLocalDrag = nil
                    panelDragStateEvent3({ dragging = false, panelId = 0 })
                end
            end
        end

        ui.drawRectFilled(vec2(baseX, baseY), vec2(baseX + panelWidth, baseY + panelHeight), rgbm(0, 0, 0, 0.88), 10)
        ui.drawRect(vec2(baseX, baseY), vec2(baseX + panelWidth, baseY + panelHeight), rgbm(0.2, 0.8, 1.0, 1), 10, 0, 3)

        ui.pushFont(ui.Font.Small)
        local label = "TE CORRESPONDE EL PUESTO " .. tostring(displayPuesto)
        local labelSize = ui.measureText(label)
        ui.setCursor(vec2(baseX + (panelWidth - labelSize.x) * 0.5, baseY + 12))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.2, 0.8, 1.0, 1))
        ui.text(label)
        ui.popStyleColor()
        ui.popFont()

        ui.pushFont(ui.Font.Title)
        local valueText
        if arrowActive then
            valueText = displayArrow .. "  " .. math.floor(displayDistance) .. "m"
        else
            valueText = "ACERCÁNDOSE..."
        end
        local valueSize = ui.measureText(valueText)
        ui.setCursor(vec2(baseX + (panelWidth - valueSize.x) * 0.5, baseY + 42))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, 1))
        ui.text(valueText)
        ui.popStyleColor()
        ui.popFont()
        end) -- cierra el pcall del bloque completo
        if not okBlock then
            ac.log("[FORMATION] NAV BLOCK ERROR: " .. tostring(errBlock))
        end
    end
end
