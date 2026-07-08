-- SeedSelector.lua v2.0
-- FS25 mod: Y-Taste öffnet scrollbare, alphabetische Saatgutliste
-- Autor: User | Lua 5.1 (GIANTS Engine FS25)

SeedSelector = {}
SeedSelector.MOD_DIR = g_currentModDirectory

SeedSelector.isOpen         = false
SeedSelector.currentVehicle = nil
SeedSelector.entries        = {}
SeedSelector.hoveredIndex   = nil
SeedSelector.scrollOffset   = 1
SeedSelector.cursorWasShown = false

SeedSelector.POS_X         = 0.63
SeedSelector.POS_Y_BOTTOM  = 0.10   -- untere Kante der Liste (10% vom unteren Rand)
SeedSelector.LIST_WIDTH    = 0.26   -- overwritten dynamically on open
SeedSelector.PERIOD_COL_W  = 0.065
SeedSelector.ROW_HEIGHT    = 0.032
SeedSelector.ICON_SIZE     = 0.025
SeedSelector.FONT_SIZE     = 0.015
SeedSelector.PADDING       = 0.005
SeedSelector.MAX_ROWS      = 10

-- Exakte LS25 HUD-Farben, etwas transparenter (LS-Standard ~0.75 alpha)
SeedSelector.BG_COLOR       = {0.00913, 0.01033, 0.00651, 0.75}
SeedSelector.HEADER_COLOR   = {0.01500, 0.01700, 0.01100, 0.85}
SeedSelector.HIGHLIGHT_COLOR= {0.05,    0.12,    0.05,    0.70}
SeedSelector.ALPHA_DISABLED = 0.12

SeedSelector.MOD_VERSION   = "1.0.0"

-- FS25: 24 Perioden/Jahr, 2 pro Monat, Periode 1+2 = März
SeedSelector.MONTH_NAMES = {"Mär","Apr","Mai","Jun","Jul","Aug","Sep","Okt","Nov","Dez","Jan","Feb"}

-- gesetzt wenn Mission vollständig geladen (für Keyboard via FSBaseMission.update)
SeedSelector.missionReady  = false

addModEventListener(SeedSelector)

-- Lifecycle
function SeedSelector:loadMap()
end

function SeedSelector:deleteMap()
    self:forceClose()
    if self.bgOverlay  then self.bgOverlay:delete();  self.bgOverlay  = nil end
    if self.rowOverlay then self.rowOverlay:delete(); self.rowOverlay = nil end
end

-- Action: hook TOGGLE_SEEDS (Y-Taste) auf der Sämaschine
local function onRegisterActionEvents(vehicle, _, isActiveForInputIgnoreSelection)
    -- close list if this vehicle loses active status
    if not isActiveForInputIgnoreSelection then
        if SeedSelector.isOpen and SeedSelector.currentVehicle == vehicle then
            SeedSelector:forceClose()
        end
    end
end
SowingMachine.onRegisterActionEvents = Utils.appendedFunction(
    SowingMachine.onRegisterActionEvents, onRegisterActionEvents)

local function onDelete(vehicle)
    if SeedSelector.isOpen and SeedSelector.currentVehicle == vehicle then
        SeedSelector:forceClose()
    end
end
SowingMachine.onDelete = Utils.appendedFunction(SowingMachine.onDelete, onDelete)


-- Kalender
local function getPlantability(fd)
    local n = (Environment and Environment.PERIODS_IN_YEAR) or 12
    if fd == nil or fd.getIsPlantableInPeriod == nil then return true, nil, n end
    local gm = g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.growthMode
    local cp = g_currentMission and g_currentMission.environment and g_currentMission.environment.currentPeriod
    if gm == nil or cp == nil then return true, nil, n end
    local allowed, anyFalse = {}, false
    for p = 1, n do
        local s, r = pcall(fd.getIsPlantableInPeriod, fd, gm, p)
        local ok = s and (r == true)
        allowed[p] = ok
        if not ok then anyFalse = true end
    end
    if not anyFalse then return true, nil, n end
    return allowed[cp] == true, allowed, n
end

local function formatPeriods(allowed, n)
    if not allowed then return nil end
    local m = SeedSelector.MONTH_NAMES
    local numMonthNames = #m  -- 12 by default
    -- periods per month = n / numMonthNames (e.g. 24/12 = 2)
    local perMonth = math.max(1, math.floor(n / numMonthNames))
    local numMonths = math.ceil(n / perMonth)
    local monthAllowed = {}
    for mo = 1, numMonths do
        local anyOk = false
        for sub = 1, perMonth do
            local p = (mo-1)*perMonth + sub
            if p <= n and allowed[p] == true then anyOk = true; break end
        end
        monthAllowed[mo] = anyOk
    end
    local ranges, rs = {}, nil
    for mo = 1, numMonths do
        if monthAllowed[mo] then if not rs then rs = mo end
        else if rs then table.insert(ranges, {rs, mo-1}); rs = nil end end
    end
    if rs then table.insert(ranges, {rs, numMonths}) end
    if #ranges == 0 then return nil end
    -- merge wrap-around (last range ending at numMonths + first starting at 1)
    if #ranges > 1 and ranges[1][1] == 1 and ranges[#ranges][2] == numMonths then
        ranges[#ranges][2] = ranges[1][2]; table.remove(ranges, 1)
    end
    local parts = {}
    for _, r in ipairs(ranges) do
        local from = m[r[1]] or tostring(r[1])
        local to   = m[r[2]] or tostring(r[2])
        table.insert(parts, r[1]==r[2] and from or (from.."-"..to))
    end
    return table.concat(parts, ", ")
end

-- Liste öffnen/schließen
function SeedSelector:openList(vehicle)
    local spec = vehicle.spec_sowingMachine
    if not spec or not spec.seeds or #spec.seeds == 0 then return end
    local entries = {}
    for _, fti in ipairs(spec.seeds) do
        local fli = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fti)
        local ft  = fli and g_fillTypeManager:getFillTypeByIndex(fli)
        local fd  = g_fruitTypeManager:getFruitTypeByIndex(fti)
        local title = (ft and ft.title) or (fd and fd.name) or "?"
        local icon  = nil
        if ft and ft.hudOverlayFilename and ft.hudOverlayFilename ~= "" then
            icon = Overlay.new(ft.hudOverlayFilename, 0, 0, self.ICON_SIZE, self.ICON_SIZE)
        end
        local plantable, allowed, np = getPlantability(fd)
        table.insert(entries, {
            fruitTypeIndex = fti, title = title, icon = icon,
            isCurrent = (fti == spec.seeds[spec.currentSeed]),
            isPlantable = plantable, allowedPeriods = allowed,
            nperiods = np, periodText = formatPeriods(allowed, np),
        })
    end
    table.sort(entries, function(a, b)
        -- 1. aktive (säbare) Früchte zuerst
        if a.isPlantable ~= b.isPlantable then
            return a.isPlantable
        end
        -- 2. innerhalb jeder Gruppe alphabetisch
        return string.lower(a.title) < string.lower(b.title)
    end)
    self.entries = entries

    -- dynamic width: measure longest title to avoid excess whitespace
    local maxTitleW = 0.08  -- minimum
    local maxPeriodW = 0.04 -- minimum
    for _, e in ipairs(entries) do
        local tw = getTextWidth(self.FONT_SIZE, e.title)
        if tw > maxTitleW then maxTitleW = tw end
        local label = e.periodText or (not e.isPlantable and g_i18n:getText("seedSelector_notInSeason")) or g_i18n:getText("seedSelector_allYear")
        local pw = getTextWidth(self.FONT_SIZE * 0.9, label)
        if pw > maxPeriodW then maxPeriodW = pw end
    end
    local iconCol   = self.ICON_SIZE + self.PADDING
    local periodCol = maxPeriodW + self.PADDING * 2
    local totalW    = self.PADDING + iconCol + maxTitleW + self.PADDING * 2 + periodCol
    self.LIST_WIDTH   = math.max(0.16, math.min(0.28, totalW))
    self.PERIOD_COL_W = periodCol - self.PADDING

    -- anchor from right edge next to tachometer HUD (which starts at ~x=0.82)
    self.POS_X = math.max(0.40, 0.82 - self.LIST_WIDTH - 0.01)
    self.currentVehicle = vehicle
    self.hoveredIndex = nil
    self.scrollOffset = 1
    for i, e in ipairs(entries) do
        if e.isCurrent then
            self.scrollOffset = math.min(math.max(1, i - math.floor(self.MAX_ROWS/2)), math.max(1, #entries - self.MAX_ROWS + 1))
            break
        end
    end
    self.isOpen = true
    local ok, shown = pcall(function() return g_inputBinding:getShowMouseCursor() end)
    self.cursorWasShown = ok and shown or false
    g_inputBinding:setShowMouseCursor(true)
end

function SeedSelector:closeList()
    self:releaseEntries()
    self.isOpen = false; self.currentVehicle = nil; self.hoveredIndex = nil
    pcall(function() g_inputBinding:setShowMouseCursor(self.cursorWasShown) end)
end

function SeedSelector:forceClose()
    self:releaseEntries()
    self.isOpen = false; self.currentVehicle = nil; self.hoveredIndex = nil
    pcall(function() g_inputBinding:setShowMouseCursor(false) end)
end

function SeedSelector:releaseEntries()
    for _, e in ipairs(self.entries or {}) do if e.icon then e.icon:delete() end end
    self.entries = {}
end

function SeedSelector:select(e)
    if not e or not e.isPlantable then return end
    if self.currentVehicle and self.currentVehicle.setSeedFruitType then
        self.currentVehicle:setSeedFruitType(e.fruitTypeIndex)
    end
    self:closeList()
end

-- Overlays
function SeedSelector:bg()
    if not self.bgOverlay then self.bgOverlay = Overlay.new("data/shared/white_diffuse.dds",0,0,1,1) end
    return self.bgOverlay
end
function SeedSelector:rowOvl()
    if not self.rowOverlay then self.rowOverlay = Overlay.new("data/shared/white_diffuse.dds",0,0,1,1) end
    return self.rowOverlay
end

-- Draw
function SeedSelector:draw()
    if not self.isOpen then return end
    local ok, err = pcall(self.drawList, self)
    if not ok then
        print("SeedSelector DRAW ERROR: " .. tostring(err))
        -- don't close, keep open so we can see repeated errors
    end
end

function SeedSelector:drawList()
    if not self.currentVehicle or not self.currentVehicle.spec_sowingMachine then
        self:forceClose(); return
    end
    -- ESC/Pause-Menü oder anderes Gui offen -> unsere Liste schliessen
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        self:forceClose(); return
    end
    local n   = #self.entries
    local vis = math.min(self.MAX_ROWS, n)
    local lw  = self.LIST_WIDTH
    local lh  = vis * self.ROW_HEIGHT + self.PADDING * 2
    local headerH = self.ROW_HEIGHT * 0.65  -- kompaktere Headerzeile (sonst wirkt sie wie 2 Zeilen)

    -- anchor from bottom: y_bottom = POS_Y_BOTTOM, liste wächst nach oben
    local yBottom = self.POS_Y_BOTTOM
    local yTop    = yBottom + lh + headerH
    -- clamp: nie über 0.95 (oben) und POS_X nie zu weit rechts
    yTop = math.min(yTop, 0.95)
    local x = math.min(self.POS_X, 1.0 - lw - 0.01)
    local y = yTop   -- y = oberkante inkl. header

    self._drawX = x; self._drawY = y; self._drawLW = lw
    self._drawLH = lh + headerH

    local bg = self:bg()
    local bgc = self.BG_COLOR
    bg:setColor(bgc[1],bgc[2],bgc[3],bgc[4])
    bg:setPosition(x, y - lh - headerH)
    bg:setDimension(lw, lh + headerH)
    bg:render()

    -- header
    local hdr = self:rowOvl()
    hdr:setColor(self.HEADER_COLOR[1],self.HEADER_COLOR[2],self.HEADER_COLOR[3],self.HEADER_COLOR[4])
    hdr:setPosition(x, y - headerH)
    hdr:setDimension(lw, headerH)
    hdr:render()
    setTextColor(1,1,1,1); setTextBold(true)
    renderText(x+self.PADDING, y-headerH+(headerH-self.FONT_SIZE*0.8)*0.5, self.FONT_SIZE * 0.8,
        "SeedSelector v" .. self.MOD_VERSION)
    setTextBold(false)

    self.scrollOffset = math.min(math.max(1,self.scrollOffset), math.max(1,n-vis+1))
    -- rows grow upward from yBottom+PADDING
    local rowsBottom = yBottom + self.PADDING
    local pcx = x + lw - self.PERIOD_COL_W - self.PADDING
    for i = 1, vis do
        local ei = self.scrollOffset + (i - 1)
        local e  = self.entries[ei]
        if not e then break end
        local ry = rowsBottom + (vis - i) * self.ROW_HEIGHT
        local al = e.isPlantable and 1.0 or self.ALPHA_DISABLED
        local rw = self:rowOvl()
        if e.isPlantable and ei == self.hoveredIndex then
            local hc = self.HIGHLIGHT_COLOR
            rw:setColor(hc[1],hc[2],hc[3],hc[4]); rw:setPosition(x,ry); rw:setDimension(lw,self.ROW_HEIGHT); rw:render()
        end
        local tx = x + self.PADDING
        if e.icon then
            e.icon:setColor(1,1,1,al)
            e.icon:setPosition(x+self.PADDING, ry+(self.ROW_HEIGHT-self.ICON_SIZE)*0.5)
            e.icon:setDimension(self.ICON_SIZE,self.ICON_SIZE); e.icon:render()
            tx = tx + self.ICON_SIZE + self.PADDING
        end
        setTextColor(al,al,al,1)
        if e.isCurrent then
            setTextColor(1, 0.85, 0.1, al)  -- gelb für aktuell ausgewählte Frucht
            setTextBold(true)
        end
        renderText(tx, ry+(self.ROW_HEIGHT-self.FONT_SIZE)*0.5, self.FONT_SIZE, e.title)
        setTextBold(false)
        -- season text right-aligned (e.g. "Mär-Jun" or "nicht in Saison")
        do
            local label = nil
            if not e.isPlantable then
                label = e.periodText and (e.periodText .. " ✗") or g_i18n:getText("seedSelector_notInSeason")
            elseif e.periodText then
                label = e.periodText
            end
            -- always show something: "ganzjährig" if no restriction
            if label == nil then
                label = g_i18n:getText("seedSelector_allYear")
            end
            -- Saatzeitraum in Kalendergrün (wie Anbaukalender), "nicht in Saison" gedimmt grau
            if not e.isPlantable then
                local tc = 0.35
                setTextColor(tc, tc, tc, 1)
            else
                -- Kalender-Grün (Saatzeitpunkt-Farbe aus dem Anbaukalender)
                setTextColor(0.55, 0.78, 0.18, 1)
            end
            setTextAlignment(RenderText.ALIGN_RIGHT)
            renderText(pcx + self.PERIOD_COL_W,
                ry + (self.ROW_HEIGHT - self.FONT_SIZE * 0.9) * 0.5,
                self.FONT_SIZE * 0.9, label)
            setTextAlignment(RenderText.ALIGN_LEFT)
        end
    end
    setTextColor(1,1,1,1)
end

-- Input
function SeedSelector:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.isOpen then return end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        self:forceClose(); return
    end

    local ok, err = pcall(self.mouseInternal, self, posX, posY, isDown, button)
    if not ok then print("SeedSelector mouse error: "..tostring(err)); self:forceClose() end
end

function SeedSelector:mouseInternal(posX, posY, isDown, button)
    local n, vis = #self.entries, math.min(self.MAX_ROWS, #self.entries)
    local x   = self._drawX  or self.POS_X
    local y   = self._drawY  or (self.POS_Y_BOTTOM + vis * self.ROW_HEIGHT + self.ROW_HEIGHT)
    local lw  = self._drawLW or self.LIST_WIDTH
    local lh  = self._drawLH or (vis * self.ROW_HEIGHT + self.PADDING * 2 + self.ROW_HEIGHT)
    local inside = posX>=x and posX<=x+lw and posY>=(y-lh) and posY<=y
    self.hoveredIndex = nil
    if inside then
        local rowsBottom = self.POS_Y_BOTTOM + self.PADDING
        for i=1,vis do
            local ry = rowsBottom + (vis - i) * self.ROW_HEIGHT
            if posY>=ry and posY<=ry+self.ROW_HEIGHT then
                local ei = self.scrollOffset + (i - 1)
                local e  = self.entries[ei]
                if e and e.isPlantable then self.hoveredIndex = ei end
                break
            end
        end
        if Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_UP)   then self.scrollOffset = self.scrollOffset-1 end
        if Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_DOWN)  then self.scrollOffset = self.scrollOffset+1 end
        self.scrollOffset = math.min(math.max(1,self.scrollOffset), math.max(1,n-vis+1))
        if isDown and button==Input.MOUSE_BUTTON_LEFT and self.hoveredIndex then
            self:select(self.entries[self.hoveredIndex])
        end
    elseif isDown and button==Input.MOUSE_BUTTON_LEFT then
        self:closeList()
    end
end

function SeedSelector:keyEvent(unicode, sym, modifier, isDown)
    if not self.isOpen then return end
    if isDown and Input.KEY_esc and sym==Input.KEY_esc then self:closeList() end
end


--------------------------------------------------------------------
-- Vanilla override: replace TOGGLE_SEEDS action with our list
--------------------------------------------------------------------
-- Store original for fallback
local originalToggleSeedType = SowingMachine.actionEventToggleSeedType

SowingMachine.actionEventToggleSeedType = function(vehicle, actionName, inputValue, callbackState, isAnalog)
    if not vehicle:getIsSeedChangeAllowed() then return end
    local spec = vehicle.spec_sowingMachine
    if spec and spec.seeds and #spec.seeds > 1 then
        if SeedSelector.isOpen and SeedSelector.currentVehicle == vehicle then
            SeedSelector:closeList()
        else
            SeedSelector:openList(vehicle)
        end
    else
        originalToggleSeedType(vehicle, actionName, inputValue, callbackState, isAnalog)
    end
end

--------------------------------------------------------------------
-- Engine hooks (FarmTablet-Muster: missionReady Guard)
--------------------------------------------------------------------
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
    SeedSelector.missionReady = true
end)

FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, function()
    SeedSelector.missionReady = false
end)

-- draw + mouseEvent via addModEventListener (funktioniert für diese Callbacks)
-- Keyboard Alt_r+F via FSBaseMission.update (FarmTablet-Muster, nur nach missionReady)
-- KEY_f = 102 (SDL keycode, bestätigt via scan wie KEY_o=111)
local KEY_F      = 102
local _kbWasDown = false

FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
    if not SeedSelector.missionReady then return end

    -- Alt rechts + F: öffnet/schliesst die Liste (Tastatur-Fallback unabhängig vom Input-Modus)
    local raltDown = Input.isKeyPressed(Input.KEY_ralt) == true
    local fDown    = Input.isKeyPressed(KEY_F) == true
    local hotkeyDown = raltDown and fDown

    if hotkeyDown and not _kbWasDown then
        _kbWasDown = true
        if g_gui ~= nil and g_gui:getIsGuiVisible() then
            return  -- Menü offen -> ignorieren
        end
        -- Flag setzen; SowingMachine:onUpdate (siehe unten) reagiert für
        -- das Fahrzeug, das die Engine selbst als aktiv gesteuert kennt
        -- (über isActiveForInputIgnoreSelection) - das ist robuster als
        -- selbst nach g_currentMission.controlledVehicle zu suchen.
        SeedSelector._hotkeyPending = true
    elseif not hotkeyDown then
        _kbWasDown = false
    end
end)

-- Hotkey-Auswertung direkt im Fahrzeug-Update-Zyklus: das Fahrzeug selbst
-- weiss zuverlässig, ob es gerade aktiv vom Spieler gesteuert wird
-- (isActiveForInputIgnoreSelection gilt auch für angehängte Sämaschinen).
local function sowingMachineHotkeyCheck(vehicle, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if not SeedSelector._hotkeyPending then return end
    if not isActiveForInputIgnoreSelection or not vehicle.isClient then return end

    SeedSelector._hotkeyPending = false  -- nur ein Fahrzeug reagiert

    local spec = vehicle.spec_sowingMachine
    if spec == nil or spec.seeds == nil or #spec.seeds <= 1 then return end
    if vehicle.getIsSeedChangeAllowed ~= nil and not vehicle:getIsSeedChangeAllowed() then return end

    if SeedSelector.isOpen and SeedSelector.currentVehicle == vehicle then
        SeedSelector:closeList()
    else
        SeedSelector:openList(vehicle)
    end
end

SowingMachine.onUpdate = Utils.appendedFunction(SowingMachine.onUpdate, sowingMachineHotkeyCheck)

-- draw, mouseEvent und keyEvent laufen über addModEventListener(SeedSelector)
-- (oben registriert) - das ist die einzige verlässliche Methode die auch im
-- MP-Client funktioniert. FSBaseMission-Patches sind nicht nötig und können
-- im MP-Client fehlen.
