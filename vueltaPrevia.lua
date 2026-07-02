local sim = ac.getSim()
local adminFlag = ui.OnlineExtraFlags.Admin
local state = {
    enabled = false,
    alpha = 0
}
local title = "VUELTA PREVIA"
local subtitle = "MANTENER POSICIONES"
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
    local speed = 3.5
    if state.enabled then
        state.alpha = math.min(state.alpha + dt * speed, 1)
    else
        state.alpha = math.max(state.alpha - dt * speed, 0)
    end
end

local function alphaColor(r, g, b)
    return rgbm(r, g, b, state.alpha)
end

function script.drawUI()
    if state.alpha <= 0 then
        return
    end
    local panelWidth = 820
    local panelHeight = 210
    local x = (screen.w - panelWidth) * 0.5
    local y = 120

    -- Fondo
    ui.drawRectFilled(
        vec2(x, y),
        vec2(x + panelWidth, y + panelHeight),
        alphaColor(0, 0, 0),
        10
    )
    -- Borde
    ui.drawRect(
        vec2(x, y),
        vec2(x + panelWidth, y + panelHeight),
        alphaColor(1.0, 0.82, 0.0),
        10,
        0,
        3
    )

    ------------------------------------------------
    -- Título
    ------------------------------------------------
    ui.pushFont(ui.Font.Title)
    local titleSize = ui.measureText(title)
    ui.setCursor(vec2(
        x + (panelWidth - titleSize.x) * 0.5,
        y + 45
    ))
    ui.pushStyleColor(ui.StyleColor.Text,
        alphaColor(1.0, 0.82, 0.0))
    ui.text(title)
    ui.popStyleColor()
    ui.popFont()

    ------------------------------------------------
    -- Subtítulo
    ------------------------------------------------
    ui.pushFont(ui.Font.Title)
    local subSize = ui.measureText(subtitle)
    ui.setCursor(vec2(
        x + (panelWidth - subSize.x) * 0.5,
        y + 130
    ))
    ui.pushStyleColor(ui.StyleColor.Text,
        alphaColor(1, 1, 1))
    ui.text(subtitle)
    ui.popStyleColor()
    ui.popFont()
end

