local sim = ac.getSim()
local car = ac.getCar(0)
local adminFlag = ui.OnlineExtraFlags.Admin

-- ===== Modo de edición compartido: mismo evento que el resto de los scripts. Este cartel es
-- el ID 7 -- solo se muestra cuando el menú lo tiene seleccionado. =====
local editingPanelId = 0
local MY_PREVIEW_ID = 7
local NAV_PANEL_ID = 10 -- el cartel de navegación vive en este mismo script, pero es un ID de edición aparte
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
local gridRowAngle = nil -- ángulo (radianes) de orientación de la grilla, capturado junto a las posiciones

-- Distintas versiones de Lua llaman diferente a la función de arcotangente de 2 argumentos
-- (math.atan2 en Lua 5.1/5.2, math.atan(y,x) en 5.3+) -- probamos las dos, por las dudas.
local function safeAtan2(y, x)
    local ok, result = pcall(function() return math.atan2(y, x) end)
    if ok then return result end
    local ok2, result2 = pcall(function() return math.atan(y, x) end)
    if ok2 then return result2 end
    return math.atan(y / x) -- último recurso, no maneja todos los cuadrantes bien
end

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
                    -- OJO: se copian los valores numéricos (x,y,z) a una tabla nueva, en vez
                    -- de guardar el objeto "pos" tal cual -- si CSP lo devuelve como una
                    -- referencia viva a la posición actual del auto (no una foto congelada),
                    -- guardarlo sin copiar haría que el "objetivo" te siga a vos mismo, dando
                    -- siempre distancia 0.
                    table.insert(entries, {
                        index = i,
                        name = okName and name or "?",
                        pos = { x = pos.x, y = pos.y, z = pos.z },
                        spline = splinePos
                    })
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

    -- También se captura MI PROPIA orientación en este mismo instante (en mi propio
    -- casillero, así que está bien orientada) -- se usa como referencia para dibujar el
    -- marcador del piso alineado con el sentido real de la pista en la grilla, ya que no
    -- confirmamos si render.debugBox soporta rotación. Asume que todas las filas de la
    -- grilla son aproximadamente paralelas entre sí, lo cual es así en la gran mayoría de
    -- los circuitos.
    local okLook, myLook = pcall(function() return car.look end)
    if okLook and myLook ~= nil then
        gridRowAngle = safeAtan2(myLook.x, myLook.z) -- ángulo de la grilla en el plano XZ
        ac.log("[FORMATION] Ángulo de la grilla capturado: " .. tostring(gridRowAngle))
    end
end

local wasRaceSession = false
local ARROW_ACTIVATION_DISTANCE = 100 -- metros: el cartel entero recién aparece a esta distancia o menos
local ARRIVAL_DISTANCE = 2 -- metros: una vez que estás así de cerca (o menos), se apaga el cartel, ya llegaste
-- Aproximación de "sector 3" usando splinePosition (avance 0-1 en la pista, ya confirmado
-- que funciona) -- no tenemos un campo de "número de sector" real confirmado en CSP, así
-- que se aproxima como "último tercio de la vuelta". Si en algún circuito no coincide bien
-- con el sector 3 real, se puede ajustar el valor en Extra Options.
local SECTOR3_SPLINE_THRESHOLD = 2 / 3
-- Una vez que se activa (con la dirección justo hacia adelante), se queda "prendido" y la
-- flecha puede ir cambiando libremente para guiar ajustes de izquierda/derecha, hasta que
-- te alejes de nuevo -- así no hace falta seguir mirando exactamente para adelante todo el
-- tiempo, pero el primer disparo sí exige esa dirección para evitar falsos positivos en
-- otras partes del circuito que casualmente queden cerca de la grilla.
local navActive = false
local navActivationTimer = 0
local NAV_ACTIVATION_SUSTAIN_SECONDS = 0.3 -- la condición de activación tiene que sostenerse este ratito antes de prender de verdad, para filtrar algún cuadro suelto raro
local navLastFrameTime = nil
local navFrameDt = 0
-- Una vez que llegás (distancia <= ARRIVAL_DISTANCE), esto queda en true PARA SIEMPRE hasta
-- que te alejás más de ARROW_ACTIVATION_DISTANCE de nuevo. Sin esto, apenas se apaga el
-- cartel por haber llegado, la condición de activación (segus cerca y mirando adelante)
-- se cumple de nuevo al instante, prendiéndolo y apagándolo en bucle cada cuadro -- el
-- parpadeo rápido que se veía entre 1 y 0 metros.
local hasArrived = false

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
    ARROW_ACTIVATION_DISTANCE = config:get("FORMATION", "ARROW_ACTIVATION_DISTANCE_METERS", 100)
    ARRIVAL_DISTANCE = config:get("FORMATION", "ARRIVAL_DISTANCE_METERS", 2)
    SECTOR3_SPLINE_THRESHOLD = config:get("FORMATION", "SECTOR3_SPLINE_THRESHOLD", 2 / 3)
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

-- ===== Marcador 3D en el piso, en el casillero de grilla (como el resaltado de boxes) =====
-- Se arma con 4 líneas (render.debugLine, ya confirmado) formando un rectángulo, en vez de
-- render.debugBox -- así lo podemos rotar nosotros mismos con matemática simple, alineado al
-- sentido real de la pista (gridRowAngle), sin depender de un parámetro de rotación de
-- debugBox que no confirmamos que exista.
local BOX_WIDTH = 2.4  -- ancho del auto
local BOX_LENGTH = 4.6 -- largo del auto

function script.draw3D()
    if myGridPosition == nil or gridSlotWorldPos[myGridPosition] == nil or gridRowAngle == nil then return end
    if not (state.enabled and navActive) then return end -- solo mientras el cartel de navegación está activo

    local target = gridSlotWorldPos[myGridPosition]
    local halfW, halfL = BOX_WIDTH * 0.5, BOX_LENGTH * 0.5
    local sin, cos = math.sin(gridRowAngle), math.cos(gridRowAngle)

    -- 4 esquinas del rectángulo, rotadas según gridRowAngle alrededor del centro (target)
    local function corner(lx, lz)
        local rx = lx * cos - lz * sin
        local rz = lx * sin + lz * cos
        return vec3(target.x + rx, target.y + 0.05, target.z + rz)
    end

    local c1 = corner(-halfW, -halfL)
    local c2 = corner(halfW, -halfL)
    local c3 = corner(halfW, halfL)
    local c4 = corner(-halfW, halfL)

    local red = rgbm(1, 0, 0, 1)
    local ok, err = pcall(function()
        render.debugLine(c1, c2, red)
        render.debugLine(c2, c3, red)
        render.debugLine(c3, c4, red)
        render.debugLine(c4, c1, red)
        -- Diagonales también, para que se vea más como un cartel sólido y no solo un marco fino
        render.debugLine(c1, c3, red)
        render.debugLine(c2, c4, red)
    end)
    if not ok then
        ac.log("[FORMATION] Error dibujando el marcador de grilla: " .. tostring(err))
    end
end

function script.update(dt)
    -- Vigila la transición a sesión de Carrera en TODOS los frames (no en un solo evento
    -- puntual), porque sim.raceSessionType puede leerse con un valor viejo justo en el
    -- instante exacto de la transición -- de esta forma se autocorrige apenas se actualiza.
    local isRaceSession = (sim.raceSessionType == ac.SessionType.Race)
    if isRaceSession and not wasRaceSession then
        gridCaptured = false
        gridCaptureTimer = GRID_CAPTURE_DELAY_SECONDS
        ac.log("[FORMATION] Transición a sesión de Carrera detectada, arranca el timer de captura de grilla")
    end
    wasRaceSession = isRaceSession

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

-- Se probó "Huge" pero resultó demasiado grande (cartel enorme); se usa Title, que ya
-- veníamos usando en el resto del proyecto con buenos resultados de legibilidad.
local biggestFont = ui.Font.Title

local function alphaColor(r, g, b, mult)
    return rgbm(r, g, b, state.alpha * (mult or 1))
end

local function drawInfoPanel(centerX, y)
    ui.pushFont(biggestFont)
    local titleSize = ui.measureText(title)
    local subSize = ui.measureText(subtitle)
    ui.popFont()

    local panelWidth = math.max(titleSize.x, subSize.x) + 30
    local panelHeight = titleSize.y + subSize.y + 22
    local x = centerX - panelWidth * 0.5

    ui.drawRectFilled(vec2(x, y), vec2(x + panelWidth, y + panelHeight), alphaColor(0, 0, 0, 0.88), 10)
    ui.drawRect(vec2(x, y), vec2(x + panelWidth, y + panelHeight), alphaColor(1.0, 0.82, 0.0, 1), 10, 0, 3)

    ui.pushFont(biggestFont)
    ui.setCursor(vec2(x + (panelWidth - titleSize.x) * 0.5, y + 8))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1.0, 0.82, 0.0))
    ui.text(title)
    ui.popStyleColor()

    ui.setCursor(vec2(x + (panelWidth - subSize.x) * 0.5, y + titleSize.y + 12))
    ui.pushStyleColor(ui.StyleColor.Text, alphaColor(1, 1, 1))
    ui.text(subtitle)
    ui.popStyleColor()
    ui.popFont()

    return panelWidth, panelHeight
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
-- Las 2 posiciones van en UNA sola llamada a ac.storage() (no 2 separadas), para eliminar
-- cualquier posibilidad de que ambas terminen compartiendo el mismo espacio de guardado por
-- tener la misma forma -- es el mismo bug que ya habíamos encontrado y solucionado en
-- announcements.lua, que acá se había vuelto a colar sin darnos cuenta.
local panelPositions = ac.storage({
    comboPosX = 0.5,     -- combo de Vuelta Previa (centro horizontal)
    comboPosY = 90 / 1080, -- combo de Vuelta Previa (borde superior)
    navPosX = 0.5,        -- cartel de navegación (centro horizontal)
    navPosY = 550 / 1080  -- cartel de navegación (borde superior)
})

local navDragging = false
local navDragOffsetX, navDragOffsetY = 0, 0

-- Candado local: como este script tiene 2 carteles (Vuelta Previa y el de navegación al
-- puesto), evita que un click agarre a los dos si llegan a superponerse.
local activeLocalDrag = nil -- nil, "vueltaPrevia" o "nav"

local dragging = false
local dragOffsetX, dragOffsetY = 0, 0
local blockWidth, blockHeight = 460, 266 -- área de arrastre; se ajustó al crecer el texto con Huge
local navDiagTimer = 0
local navSizeLogTimer = 0

-- Dibuja una flecha como gráfico (no como texto), rotada al ángulo exacto -- así no depende
-- de ningún glifo de fuente (podía fallar con caracteres especiales en fuentes grandes) y
-- puede apuntar a cualquier ángulo real, no solo a 8 direcciones fijas.
-- angleRad: 0 = derecho para arriba/adelante, positivo = hacia la derecha (sentido horario)
local function drawArrow(cx, cy, angleRad, length, color, thickness)
    local dx = math.sin(angleRad)
    local dy = -math.cos(angleRad)
    local tipX, tipY = cx + dx * length * 0.5, cy + dy * length * 0.5
    local tailX, tailY = cx - dx * length * 0.5, cy - dy * length * 0.5

    ui.drawLine(vec2(tailX, tailY), vec2(tipX, tipY), color, thickness)

    local headLen = length * 0.4
    local headAngle = math.rad(28)
    local a1 = angleRad + math.pi - headAngle
    local a2 = angleRad + math.pi + headAngle
    local h1x, h1y = tipX + math.sin(a1) * headLen, tipY - math.cos(a1) * headLen
    local h2x, h2y = tipX + math.sin(a2) * headLen, tipY - math.cos(a2) * headLen
    ui.drawLine(vec2(tipX, tipY), vec2(h1x, h1y), color, thickness)
    ui.drawLine(vec2(tipX, tipY), vec2(h2x, h2y), color, thickness)
end

function script.drawUI()
    -- Chequeo de seguridad INCONDICIONAL, antes que cualquier "return" por visibilidad: si
    -- yo tenía un cartel en arrastre y el mouse ya no está apretado, lo libero y aviso YA,
    -- sin importar si ese cartel sigue visible en este momento. Sin esto, si un cartel
    -- desaparece a mitad de un arrastre (por ejemplo el de navegación, que depende de la
    -- distancia), nunca se llega a mandar el aviso de "solté el mouse", y el candado
    -- compartido queda trabado para siempre, ocultando TODOS los carteles de TODOS los
    -- scripts hasta reiniciar.
    --
    -- IMPORTANTE: el mouse se lee UNA SOLA VEZ acá arriba, y se reutiliza ese mismo valor
    -- en todo el resto de la función -- llamar a isMouseButtonDown() de nuevo más abajo
    -- podía dar un resultado distinto en el mismo cuadro (parpadeo/inconsistencia),
    -- provocando arrastres fantasma que se autocorregían al cuadro siguiente sin parar.
    local mp = getMousePos()
    local mouseIsDown = isMouseButtonDown()

    if (dragging or navDragging) and not mouseIsDown then
        dragging = false
        navDragging = false
        activeLocalDrag = nil
        panelDragStateEvent3({ dragging = false, panelId = 0 })
        ac.log("[FORMATION] Arrastre liberado por seguridad (cartel se había ocultado a mitad de camino)")
    end

    -- El "state.alpha <= 0" solo debería cortar el combo de Vuelta Previa -- pero el cartel
    -- de navegación (más abajo en esta misma función) también necesita poder mostrarse en
    -- modo edición (editingPanelId == NAV_PANEL_ID) aunque Vuelta Previa no esté activada.
    --
    -- Y el chequeo de "algo se está arrastrando" tiene que tolerar CUALQUIERA de los dos
    -- IDs de este script (7 o 10) -- antes solo toleraba el 7, así que arrastrar
    -- específicamente el cartel de navegación (ID 10) hacía que toda la función se cortara
    -- y desapareciera todo de golpe, justo a mitad del arrastre.
    if (state.alpha <= 0 and editingPanelId ~= NAV_PANEL_ID) or
        (shouldHideForDrag(MY_PANEL_ID) and shouldHideForDrag(NAV_PANEL_ID)) then
        return
    end

    ui.pushFont(biggestFont)
    local titleSizeCalc = ui.measureText(title)
    local subSizeCalc = ui.measureText(subtitle)
    ui.popFont()
    local panelHeight = titleSizeCalc.y + subSizeCalc.y + 22

    local centerX = panelPositions.comboPosX * screen.w
    local panelY = panelPositions.comboPosY * screen.h
    local gantryY = panelY + panelHeight + 20

    local blockX = centerX - blockWidth * 0.5
    local blockY = panelY

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
                panelPositions.comboPosX = centerX / screen.w
                panelPositions.comboPosY = panelY / screen.h
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
    -- Cartel de navegación: aparece recién a los 100m (configurable) de tu casillero, con
    -- "POSICIÓN N°" + flecha + distancia -- todo el cartel queda oculto hasta ese momento.
    ------------------------------------------------
    local hasRealTarget = (myGridPosition ~= nil and gridSlotWorldPos[myGridPosition] ~= nil)

    local displayPuesto, displayDistance, displayArrow
    local shouldRenderPanel = false

    if editingPanelId == NAV_PANEL_ID then
        -- Modo de edición: siempre visible con datos de ejemplo, para poder acomodarlo
        shouldRenderPanel = true
        displayPuesto = hasRealTarget and myGridPosition or 5
        displayDistance = 42
        displayArrow = math.rad(45) -- ejemplo: diagonal, para mostrar en modo edición
    elseif state.enabled and hasRealTarget then
        navFrameDt = navLastFrameTime and math.max((sim.currentSessionTime - navLastFrameTime) / 1000, 0) or 0
        navLastFrameTime = sim.currentSessionTime

        local target = gridSlotWorldPos[myGridPosition]
        local okLook, look = pcall(function() return car.look end)
        local dx = target.x - car.position.x
        local dz = target.z - car.position.z
        local dist = math.sqrt(dx * dx + dz * dz)

        local arrow = "^" -- se sigue usando para decidir si "mira justo para adelante" (activación)
        local angleRad = 0 -- ángulo continuo real, para dibujar la flecha (0 = derecho para adelante)
        if okLook and look ~= nil then
            local dot = look.x * dx + look.z * dz
            local cross = look.x * dz - look.z * dx
            angleRad = safeAtan2(cross, dot)
            local angleDeg = math.deg(angleRad)
            if angleDeg < 0 then angleDeg = angleDeg + 360 end
            local sector = math.floor((angleDeg + 22.5) / 45) % 8
            local arrows = { "^", "^>", ">", "v>", "v", "<v", "<", "<^" }
            arrow = arrows[sector + 1]
        end

        if hasArrived then
            -- Ya llegaste antes: no se vuelve a mostrar nada hasta que te alejes en serio
            -- (por ejemplo, la próxima vez que haya que volver a la grilla).
            if dist > ARROW_ACTIVATION_DISTANCE then
                hasArrived = false
            end
        elseif not navActive then
            -- Todavía no está activo: la condición (cerca, mirando adelante, Y en el último
            -- tercio de la vuelta) tiene que sostenerse un ratito antes de prender de verdad
            -- -- así no se dispara en el sector 1, lejos de la grilla, aunque en algún punto
            -- del circuito pase cerca y mirando para adelante por casualidad.
            local okSpline, mySpline = pcall(function() return car.splinePosition end)
            local inFinalSector = okSpline and mySpline >= SECTOR3_SPLINE_THRESHOLD

            if dist <= ARROW_ACTIVATION_DISTANCE and arrow == "^" and inFinalSector then
                navActivationTimer = navActivationTimer + navFrameDt
                if navActivationTimer >= NAV_ACTIVATION_SUSTAIN_SECONDS then
                    navActive = true
                end
            else
                navActivationTimer = 0
            end
        else
            -- Ya está activo: se apaga si te alejaste de nuevo, o si ya llegaste (distancia
            -- muy chica) -- en este último caso, además, queda bloqueado con hasArrived para
            -- que no se pueda volver a prender solo mientras sigas ahí parado.
            if dist > ARROW_ACTIVATION_DISTANCE then
                navActive = false
                navActivationTimer = 0
            elseif dist <= ARRIVAL_DISTANCE then
                navActive = false
                navActivationTimer = 0
                hasArrived = true
            end
        end

        if navActive then
            shouldRenderPanel = true
            displayPuesto = myGridPosition
            displayDistance = dist
            displayArrow = angleRad
        end
    else
        navActive = false -- se resetea si se apaga Vuelta Previa o no hay objetivo real
        navActivationTimer = 0
        hasArrived = false
    end

    -- Diagnóstico throttled (una vez por segundo, para no inundar el log)
    navDiagTimer = navDiagTimer + 1
    if navDiagTimer % 60 == 0 then
        pcall(function()
            ac.log("[FORMATION] NAV DIAG: state.enabled=" .. tostring(state.enabled) ..
                " hasRealTarget=" .. tostring(hasRealTarget) ..
                " myGridPosition=" .. tostring(myGridPosition) ..
                " shouldRenderPanel=" .. tostring(shouldRenderPanel) ..
                " distance=" .. tostring(displayDistance))
        end)
    end

    if shouldRenderPanel and not shouldHideForDrag(NAV_PANEL_ID) then
        local okBlock, errBlock = pcall(function()
        local label = "TU LUGAR DE LARGADA EN GRILLA N " .. tostring(displayPuesto)
        local valueText = math.floor(displayDistance) .. " m"
        local ARROW_SIZE = 44 -- un poco más grande que antes, y ya no depende de ningún glifo de fuente
        local ARROW_GAP = 14

        ui.pushFont(biggestFont)
        local labelSize = ui.measureText(label)
        local valueSize = ui.measureText(valueText)
        ui.popFont()

        local valueRowWidth = ARROW_SIZE + ARROW_GAP + valueSize.x
        local panelWidth = math.max(labelSize.x, valueRowWidth) + 30
        local panelHeight = labelSize.y + math.max(valueSize.y, ARROW_SIZE) + 22
        local baseX = panelPositions.navPosX * screen.w - panelWidth * 0.5
        local baseY = panelPositions.navPosY * screen.h

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
                    panelPositions.navPosX = (baseX + panelWidth * 0.5) / screen.w
                    panelPositions.navPosY = baseY / screen.h
                else
                    navDragging = false
                    activeLocalDrag = nil
                    panelDragStateEvent3({ dragging = false, panelId = 0 })
                end
            end
        end

        ui.drawRectFilled(vec2(baseX, baseY), vec2(baseX + panelWidth, baseY + panelHeight), rgbm(0, 0, 0, 0.88), 10)
        ui.drawRect(vec2(baseX, baseY), vec2(baseX + panelWidth, baseY + panelHeight), rgbm(0.2, 0.8, 1.0, 1), 10, 0, 3)

        ui.pushFont(biggestFont)
        ui.setCursor(vec2(baseX + (panelWidth - labelSize.x) * 0.5, baseY + 4))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(0.2, 0.8, 1.0, 1))
        ui.text(label)
        ui.popStyleColor()
        ui.popFont()

        -- Segunda fila: flecha (gráfico, no texto) + distancia, centradas juntas como grupo
        local rowY = baseY + labelSize.y + 8
        local rowHeight = math.max(valueSize.y, ARROW_SIZE)
        local groupX = baseX + (panelWidth - valueRowWidth) * 0.5

        local arrowCenterX = groupX + ARROW_SIZE * 0.5
        local arrowCenterY = rowY + rowHeight * 0.5
        drawArrow(arrowCenterX, arrowCenterY, displayArrow, ARROW_SIZE, rgbm(1, 1, 1, 1), 5)

        ui.pushFont(biggestFont)
        ui.setCursor(vec2(groupX + ARROW_SIZE + ARROW_GAP, rowY + (rowHeight - valueSize.y) * 0.5))
        ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 1, 1, 1))
        ui.text(valueText)
        ui.popStyleColor()
        ui.popFont()

        navSizeLogTimer = navSizeLogTimer + 1
        if navSizeLogTimer == 30 then -- se loguea una sola vez, medio segundo después de aparecer
            ac.log("[FORMATION] usandoHuge=" .. tostring(biggestFont == ui.Font.Huge) .. " | Tamaño real: label alto=" ..
                tostring(labelSize.y) .. "px, value alto=" .. tostring(valueSize.y) .. "px (con Title daba 24px)")
        end
        end) -- cierra el pcall del bloque completo
        if not okBlock then
            ac.log("[FORMATION] NAV BLOCK ERROR: " .. tostring(errBlock))
        end
    end
end
