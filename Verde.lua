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
    ac.log("[GREENFLAG] " .. sender:driverName() .. " -> " .. tostring(state.enabled))
end,
ac.SharedNamespace.ServerScript)

ac.onOnlineWelcome(function(message, config)
    if config:get("GREENFLAG", "ADMIN_ONLY", 1) == 0 then
        adminFlag = ui.OnlineExtraFlags.None
    else
        adminFlag = ui.OnlineExtraFlags.Admin
    end

    ui.registerOnlineExtra(
        ui.Icons.Flag,
        "🟢 Verde",
        function() return true end,
        nil,
        function()
            state.enabled = not state.enabled
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
    if state.enabled or editingPanelId == MY_PREVIEW_ID then
        state.alpha = math.min(state.alpha + 0.08, 1)
    else
        state.alpha = math.max(state.alpha - 0.08, 0)
    end
end

function script.drawUI()
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
