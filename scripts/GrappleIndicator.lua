-- FS25 prototype: detect log grapples on the controlled vehicle/attachment chain.
GrappleIndicator = {}
GrappleIndicator.DOT_RADIUS_PIXELS = 3.5
GrappleIndicator.FLAT_DOT_RADIUS = 0.07 -- Metres; fixed world size for the flat style.
GrappleIndicator.FLAT_DOT_SEGMENTS = 24
GrappleIndicator.FLAT_DOT_MIN_DIAMETER_PIXELS = 8
GrappleIndicator.CIRCLE_RADIUS = 0.4
GrappleIndicator.CIRCLE_SEGMENTS = 32
GrappleIndicator.STYLE_FLAT_DOT = 1
GrappleIndicator.STYLE_SCREEN_DOT = 2
GrappleIndicator.STYLE_CIRCLE = 3
GrappleIndicator.STYLE_KEYS = {"flatDot", "screenDot", "circle"}
GrappleIndicator.markerStyle = GrappleIndicator.STYLE_FLAT_DOT
GrappleIndicator.verticalBeam = false
GrappleIndicator.COLORS = {
    {key = "green", r = 0, g = 1, b = 0},
    {key = "white", r = 1, g = 1, b = 1},
    {key = "yellow", r = 1, g = 1, b = 0},
    {key = "orange", r = 1, g = 0.4, b = 0},
    {key = "red", r = 1, g = 0, b = 0},
    {key = "cyan", r = 0, g = 1, b = 1},
    {key = "blue", r = 0, g = 0.3, b = 1},
    {key = "magenta", r = 1, g = 0, b = 1}
}
GrappleIndicator.markerColor = 1
GrappleIndicator.GROUND_OFFSET = 0.05
GrappleIndicator.RAY_START_OFFSET = 0.1
GrappleIndicator.MAX_RAY_DISTANCE = 200
GrappleIndicator.DEBUG = false -- Optional diagnostics, at most once per second.
GrappleIndicator.DEBUG_INTERVAL_MS = 1000
GrappleIndicator.INPUT_RETRY_MS = 2000
GrappleIndicator.enabled = false
GrappleIndicator.isClient = false

function GrappleIndicator:log(message)
    print("[GrappleIndicator] " .. message)
end

function GrappleIndicator:debugLog(message)
    if self.DEBUG then
        self:log(message)
    end
end

function GrappleIndicator:loadMap(mapName)
    self.mapLoaded = true
    -- A hosted game is both server and client; a dedicated server has no
    -- local display. Mission client status is available before Player exists.
    self.isClient = g_currentMission ~= nil and g_currentMission:getIsClient()
    self.enabled = false
    -- Remember each machine separately for this map session. Weak keys avoid
    -- retaining sold/deleted vehicles solely for their indicator preference.
    self.enabledVehicles = self.isClient and setmetatable({}, {__mode = "k"}) or nil
    self.activeVehicle = nil
    self.currentTarget = nil
    self.settingsWarningShown = false
    self.actionEventId = nil
    self.inputWarningShown = false
    self.inputVehicle = nil
    self.inputDirty = false
    self.inputRetryElapsed = self.INPUT_RETRY_MS
    self.debugElapsed = self.DEBUG_INTERVAL_MS
    self.lastDiagnostic = nil
    self.surfacePosition = nil
    self.raycastQuery = nil
    if self.isClient then
        self:loadSettings()
        self:log("Map loaded; local indicators disabled. Use the configured Grapple Indicator toggle while driving.")
    else
        self:log("Map loaded on server; indicator display runs on each player's client.")
    end
end

function GrappleIndicator:removeInputAction()
    if self.actionEventId ~= nil and g_inputBinding ~= nil then
        g_inputBinding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)
        g_inputBinding:removeActionEvent(self.actionEventId)
        g_inputBinding:endActionEventsModification()
    end
    self.actionEventId = nil
    self.actionText = nil
end

function GrappleIndicator:deleteMap()
    self.mapLoaded = false
    self:removeSettingsControls()
    self:removeInputAction()
    self.enabled = false
    self.enabledVehicles = nil
    self.activeVehicle = nil
    self.currentTarget = nil
    self.inputVehicle = nil
    self.inputDirty = false
    self.lastDiagnostic = nil
    self.surfacePosition = nil
    self.raycastQuery = nil
    self.isClient = false
    self:log("Map unloaded; input action removed")
end

function GrappleIndicator:loadSettings()
    if not self.mapLoaded or not self.isClient then
        return
    end
    if self.settingsSchema == nil then
        self.settingsSchema = XMLSchema.new("GrappleIndicatorSettings")
        self.settingsSchema:register(XMLValueType.STRING, "grappleIndicator#markerStyle", "Marker style")
        self.settingsSchema:register(XMLValueType.BOOL, "grappleIndicator#flatDot", "Legacy flat-dot preference", true)
        self.settingsSchema:register(XMLValueType.BOOL, "grappleIndicator#verticalBeam", "Show vertical beam", false)
        self.settingsSchema:register(XMLValueType.STRING, "grappleIndicator#markerColor", "Marker and beam color", "green")
        self.settingsSchema:register(XMLValueType.BOOL, "grappleIndicator#diagnostics", "Diagnostic logging", false)
    end
    self.markerStyle = self.STYLE_FLAT_DOT
    self.verticalBeam = false
    self.markerColor = 1
    self.DEBUG = false
    self.settingsFilename = getUserProfileAppPath() .. "modSettings/FS25_GrappleIndicator.xml"
    if fileExists(self.settingsFilename) then
        local xmlFile = XMLFile.load("grappleIndicatorSettings", self.settingsFilename, self.settingsSchema)
        if xmlFile ~= nil then
            self.DEBUG = xmlFile:getValue("grappleIndicator#diagnostics", false)
            self.verticalBeam = xmlFile:getValue("grappleIndicator#verticalBeam", false)
            local savedColor = xmlFile:getValue("grappleIndicator#markerColor", "green")
            for index, color in ipairs(self.COLORS) do
                if color.key == savedColor then
                    self.markerColor = index
                    break
                end
            end
            local savedStyle = xmlFile:getValue("grappleIndicator#markerStyle", "")
            if savedStyle == "" then
                -- Preserve preferences saved by v0.4.0's On/Off setting.
                self.markerStyle = xmlFile:getValue("grappleIndicator#flatDot", true)
                    and self.STYLE_FLAT_DOT or self.STYLE_SCREEN_DOT
            else
                for index, key in ipairs(self.STYLE_KEYS) do
                    if key == savedStyle then
                        self.markerStyle = index
                        break
                    end
                end
            end
            xmlFile:delete()
        end
    end
end

function GrappleIndicator:saveSettings()
    if not self.mapLoaded or not self.isClient then
        return
    end
    createFolder(getUserProfileAppPath() .. "modSettings/")
    local xmlFile = XMLFile.create("grappleIndicatorSettings", self.settingsFilename, "grappleIndicator", self.settingsSchema)
    if xmlFile ~= nil then
        xmlFile:setValue("grappleIndicator#markerStyle", self.STYLE_KEYS[self.markerStyle])
        xmlFile:setValue("grappleIndicator#verticalBeam", self.verticalBeam)
        xmlFile:setValue("grappleIndicator#markerColor", self.COLORS[self.markerColor].key)
        xmlFile:setValue("grappleIndicator#diagnostics", self.DEBUG)
        xmlFile:save()
        xmlFile:delete()
    else
        self:log("WARNING: Could not save indicator settings")
    end
end

function GrappleIndicator:onMarkerStyleChanged(state)
    if not self.mapLoaded or not self.isClient or self.STYLE_KEYS[state] == nil then
        return
    end
    self.markerStyle = state
    self:saveSettings()
    self:debugLog("Marker style: " .. self.STYLE_KEYS[state])
end

function GrappleIndicator:onVerticalBeamChanged(state)
    if not self.mapLoaded or not self.isClient or (state ~= 1 and state ~= 2) then
        return
    end
    self.verticalBeam = state == 2
    self:saveSettings()
    self:debugLog(self.verticalBeam and "Vertical beam enabled" or "Vertical beam disabled")
end

function GrappleIndicator:onMarkerColorChanged(state)
    if not self.mapLoaded or not self.isClient or self.COLORS[state] == nil then
        return
    end
    self.markerColor = state
    self:saveSettings()
    self:debugLog("Marker color: " .. self.COLORS[state].key)
end

function GrappleIndicator:onDiagnosticsChanged(state)
    if not self.mapLoaded or not self.isClient or (state ~= 1 and state ~= 2) then
        return
    end
    self.DEBUG = state == 2
    self.lastDiagnostic = nil
    self.debugElapsed = self.DEBUG_INTERVAL_MS
    self:saveSettings()
    self:log(self.DEBUG and "Diagnostics enabled" or "Diagnostics disabled")
end

function GrappleIndicator:getMarkerColor()
    local color = self.COLORS[self.markerColor] or self.COLORS[1]
    return color.r, color.g, color.b
end

function GrappleIndicator:ensureSettingsControls(frame)
    if not self.mapLoaded or not self.isClient then
        return
    end
    local layout = frame.generalSettingsLayout
    local rowsPresent = 0
    for _, row in ipairs(layout ~= nil and layout.elements or {}) do
        if row == self.settingsRow or row == self.beamSettingsRow
            or row == self.colorSettingsRow or row == self.diagnosticsSettingsRow then
            rowsPresent = rowsPresent + 1
        end
    end
    if rowsPresent == 4 and self.settingsControl ~= nil and self.settingsFrame == frame then
        self.settingsControl:setState(self.markerStyle)
        self.beamSettingsControl:setState(self.verticalBeam and 2 or 1)
        self.colorSettingsControl:setState(self.markerColor)
        self.diagnosticsSettingsControl:setState(self.DEBUG and 2 or 1)
        return
    end
    -- Another GUI mod may rebuild the layout while retaining the frame.
    -- Release old rows before finding a fresh, validated template.
    self:removeSettingsControls()
    local function isUsableRow(row)
        local control = row.elements ~= nil and row.elements[1] or nil
        local label = row.elements ~= nil and row.elements[2] or nil
        return row.clone ~= nil and control ~= nil and control.target == frame
            and control.isa ~= nil and control:isa(MultiTextOptionElement)
            and not control:isa(BinaryOptionElement) and not control:isa(CheckedOptionElement)
            and not control:isa(OptionSliderElement)
            and control.setTexts ~= nil and control.setState ~= nil
            and label ~= nil and label.setText ~= nil
    end
    local template = nil
    if layout ~= nil and layout.elements ~= nil then
        -- Prefer the known base-game selector, but only when its actual type
        -- and layout still match. Never clone another mod's injected controls.
        for _, row in ipairs(layout.elements) do
            if isUsableRow(row) then
                template = template or row
                if row == frame.checkWoodHarvesterAutoCutBox then
                    template = row
                    break
                end
            end
        end
    end
    if layout == nil or template == nil or frame.controlsList == nil then
        if not self.settingsWarningShown then
            self:log("WARNING: General settings template unavailable; indicator settings could not be added")
            self.settingsWarningShown = true
        end
        return
    end
    self.settingsWarningShown = false
    -- Reuse FS25's general-settings row so mouse/keyboard/gamepad interactions
    -- and styling match the game. Suppress inherited onCreate callbacks and
    -- assign fresh focus IDs before registering any cloned controls.
    local function prepareFocus(element)
        element.focusId = FocusManager:serveAutoFocusId()
        element.focusChangeData = {}
        element.isAlwaysFocusedOnOpen = false
        for _, child in ipairs(element.elements or {}) do
            prepareFocus(child)
        end
    end
    local headerTemplate = nil
    for _, element in ipairs(layout.elements) do
        if element.name == "sectionHeader" then
            headerTemplate = element
            break
        end
    end
    if headerTemplate ~= nil then
        self.settingsHeader = headerTemplate:clone(layout, false, true, true)
        self.settingsHeader.id = "grappleIndicatorSection"
        self.settingsHeader:setText(g_i18n:getText("gi_settingsTitle"))
        prepareFocus(self.settingsHeader)
        self.settingsHeader:reloadFocusHandling(true)
        table.insert(frame.controlsList, self.settingsHeader)
    end

    local function addSettingRow(id, callback, texts, state, labelKey, tooltipKey)
        local row = template:clone(layout, false, true, true)
        row.id, row.name = id .. "Box", id .. "Box"
        local control, label = row.elements[1], row.elements[2]
        control.target = self
        control.id, control.name = id, id
        control:setCallback("onClickCallback", callback)
        control.onFocusCallback = nil -- Inherited callbacks target the game's setting.
        control.onLeaveCallback = nil
        control:setDisabled(false)
        control:setTexts(texts)
        control:setState(state)
        local tooltip = control.elements[1]
        if tooltip ~= nil then
            tooltip:setText(g_i18n:getText(tooltipKey))
        end
        if label ~= nil then
            label:setText(g_i18n:getText(labelKey))
        end
        prepareFocus(row)
        row:reloadFocusHandling(true)
        table.insert(frame.controlsList, row)
        return row, control
    end
    self.settingsRow, self.settingsControl = addSettingRow("grappleIndicatorMarkerStyle", "onMarkerStyleChanged",
        {g_i18n:getText("gi_styleFlatDot"), g_i18n:getText("gi_styleScreenDot"), g_i18n:getText("gi_styleCircle")},
        self.markerStyle, "gi_markerStyleLabel", "gi_markerStyleTooltip")
    self.beamSettingsRow, self.beamSettingsControl = addSettingRow("grappleIndicatorVerticalBeam", "onVerticalBeamChanged",
        {g_i18n:getText("gi_optionOff"), g_i18n:getText("gi_optionOn")},
        self.verticalBeam and 2 or 1, "gi_verticalBeamLabel", "gi_verticalBeamTooltip")
    local colorTexts = {}
    for _, color in ipairs(self.COLORS) do
        colorTexts[#colorTexts + 1] = g_i18n:getText("gi_color_" .. color.key)
    end
    self.colorSettingsRow, self.colorSettingsControl = addSettingRow("grappleIndicatorMarkerColor", "onMarkerColorChanged",
        colorTexts, self.markerColor, "gi_markerColorLabel", "gi_markerColorTooltip")
    self.diagnosticsSettingsRow, self.diagnosticsSettingsControl = addSettingRow("grappleIndicatorDiagnostics", "onDiagnosticsChanged",
        {g_i18n:getText("gi_optionOff"), g_i18n:getText("gi_optionOn")},
        self.DEBUG and 2 or 1, "gi_diagnosticsLabel", "gi_diagnosticsTooltip")
    self.settingsFrame = frame
    layout:invalidateLayout()
end

function GrappleIndicator:removeSettingsControls()
    local frame = self.settingsFrame
    if frame ~= nil then
        for i = #frame.controlsList, 1, -1 do
            local element = frame.controlsList[i]
            if element == self.settingsRow or element == self.settingsHeader or element == self.beamSettingsRow
                or element == self.colorSettingsRow or element == self.diagnosticsSettingsRow then
                table.remove(frame.controlsList, i)
            end
        end
    end
    if self.settingsRow ~= nil then
        self.settingsRow:delete()
    end
    if self.beamSettingsRow ~= nil then
        self.beamSettingsRow:delete()
    end
    if self.colorSettingsRow ~= nil then
        self.colorSettingsRow:delete()
    end
    if self.diagnosticsSettingsRow ~= nil then
        self.diagnosticsSettingsRow:delete()
    end
    if self.settingsHeader ~= nil then
        self.settingsHeader:delete()
    end
    if frame ~= nil and frame.generalSettingsLayout ~= nil then
        frame.generalSettingsLayout:invalidateLayout()
    end
    self.settingsRow, self.settingsHeader, self.settingsControl, self.settingsFrame = nil, nil, nil, nil
    self.beamSettingsRow, self.beamSettingsControl = nil, nil
    self.colorSettingsRow, self.colorSettingsControl = nil, nil
    self.diagnosticsSettingsRow, self.diagnosticsSettingsControl = nil, nil
end

function GrappleIndicator:getControlledVehicle()
    -- FS25 moved local vehicle access to the local Player object.
    if not self.mapLoaded or not self.isClient or g_localPlayer == nil then
        return nil
    end
    local vehicle = g_localPlayer:getCurrentVehicle()
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

function GrappleIndicator:getIsGameplayActive()
    return self.mapLoaded and self.isClient and g_currentMission ~= nil
        and g_currentMission.isRunning == true
        and g_localPlayer ~= nil
        and (g_gui == nil or not g_gui:getIsGuiVisible())
end

function GrappleIndicator:registerInputAction()
    if not self.mapLoaded or not self.isClient or self.actionEventId ~= nil or g_inputBinding == nil then
        return
    end
    local action = InputAction.GRAPPLE_INDICATOR_TOGGLE
    if action == nil then
        if not self.inputWarningShown then
            self:log("WARNING: GRAPPLE_INDICATOR_TOGGLE missing from InputAction; check modDesc.xml")
        end
        self.inputWarningShown = true
        return
    end

    -- FS25 vehicle input contexts can be rebuilt during direct vehicle switches.
    -- Always name the context: the currently active context may still belong to
    -- the previous vehicle/player during a transition. Do not force conflicts
    -- off, since that could disable another mod's controls.
    g_inputBinding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)
    local success, eventId = g_inputBinding:registerActionEvent(
        action, self, self.onToggle, false, true, false, true)
    if success then
        self.actionEventId = eventId
        g_inputBinding:setActionEventTextVisibility(eventId, true)
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
        self:updateActionText()
    end
    g_inputBinding:endActionEventsModification()
    if success then
        self.inputWarningShown = false
        self:debugLog("Input action registered: GRAPPLE_INDICATOR_TOGGLE")
    else
        if not self.inputWarningShown then
            self:log("WARNING: Could not register GRAPPLE_INDICATOR_TOGGLE; retrying every 2 seconds. Check key conflicts in Controls")
        end
        self.inputWarningShown = true
    end
end

function GrappleIndicator:updateActionText()
    if self.actionEventId == nil or g_inputBinding == nil then
        return
    end
    local key = self.enabled and "gi_disableIndicator" or "gi_enableIndicator"
    local text = g_i18n:getText(key)
    if text ~= self.actionText then
        g_inputBinding:setActionEventText(self.actionEventId, text)
        self.actionText = text
    end
end

function GrappleIndicator:onVehicleActionEventsChanged(vehicle)
    if not self.mapLoaded then
        return
    end
    local controlled = self:getControlledVehicle()
    if controlled == nil then
        return
    end
    local root = controlled.getRootVehicle ~= nil and controlled:getRootVehicle() or controlled
    local changedRoot = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    if vehicle == controlled or changedRoot == root then
        -- Defer until update, after FS25 finishes its registration context.
        self.inputDirty = true
    end
end

function GrappleIndicator:syncVehicleState(vehicle)
    if vehicle ~= self.activeVehicle then
        self.activeVehicle = vehicle
        self.surfacePosition = nil
        self.lastDiagnostic = nil
        self.debugElapsed = self.DEBUG_INTERVAL_MS
    end
    local node, _, selected, source, object = self:getCurrentTargetNode()
    self.currentTarget = {node = node, vehicle = vehicle, selected = selected, source = source, object = object}
    local hasGrapple = vehicle ~= nil and node ~= nil
    self.enabled = hasGrapple and self.enabledVehicles ~= nil
        and self.enabledVehicles[vehicle] == true
    if not self.enabled then
        self.surfacePosition = nil
    end
    return hasGrapple
end

function GrappleIndicator:onToggle(actionName, inputValue)
    local vehicle = self:getControlledVehicle()
    if not self:getIsGameplayActive() or vehicle == nil or self.enabledVehicles == nil then
        return
    end
    -- Input can arrive before update processes a direct vehicle switch.
    if not self:syncVehicleState(vehicle) then
        return
    end
    self.enabled = not self.enabled
    self.enabledVehicles[vehicle] = self.enabled or nil
    self:updateActionText()
    self:debugLog(self.enabled and "Indicator enabled" or "Indicator disabled")
    self.lastDiagnostic = nil
    self.debugElapsed = self.DEBUG_INTERVAL_MS
    if self.enabled then
        self:updateSurfacePosition(self.currentTarget)
        self:logCurrentTarget()
        self.debugElapsed = 0
    else
        self.surfacePosition = nil
    end
end

function GrappleIndicator:isValidNode(node)
    return type(node) == "number" and node ~= 0 and entityExists(node)
end

function GrappleIndicator:getLogGrabNode(object)
    if object == nil or object.isDeleted then
        return nil
    end
    -- Confirmed in FS25 LogGrab:onLoad/loadLogGrabFromXML: these are already
    -- resolved for the installed configuration, including modded vehicles.
    -- Prefer the physical grab joint over the detection trigger or moving jaws.
    local spec = object.spec_logGrab
    if spec ~= nil and spec.grabs ~= nil then
        for index, grab in ipairs(spec.grabs) do
            if self:isValidNode(grab.jointNode) then
                return grab.jointNode, string.format("LogGrab.grabs[%d].jointNode", index)
            end
            if self:isValidNode(grab.jointRoot) then
                return grab.jointRoot, string.format("LogGrab.grabs[%d].jointRoot", index)
            end
        end
    end
    return nil
end

function GrappleIndicator:getMappedGrappleNode(object)
    if object == nil or object.isDeleted or object.i3dMappings == nil then
        return nil
    end
    -- Best-effort fallback for custom scripts without LogGrab. Match only
    -- explicit body/root IDs, not any node containing "grab" (which would also
    -- match jaw hydraulics, crane targets and reference frames).
    local candidates = {}
    for id, mapping in pairs(object.i3dMappings) do
        local name = string.lower(id)
        local isBody = name:match("_grab_component%d+$")
            or name:match("_grapple_component%d+$")
            or name:match("_claw_component%d+$")
            or name == "grapple" or name == "grappleroot" or name == "grapplebody"
            or name == "grabroot" or name == "grabbody" or name == "clawroot"
        if isBody and type(mapping) == "table" and self:isValidNode(mapping.nodeId) then
            candidates[#candidates + 1] = id
        end
    end
    table.sort(candidates) -- Stable choice if a custom mod exposes several bodies.
    local id = candidates[1]
    if id ~= nil then
        return object.i3dMappings[id].nodeId, "mapping heuristic: " .. id
    end
    return nil
end

function GrappleIndicator:collectTargetObjects(object, objects, visited)
    if object == nil or object.isDeleted or visited[object] then
        return
    end
    visited[object] = true
    objects[#objects + 1] = object
    if object.getAttachedImplements ~= nil then
        for _, implement in ipairs(object:getAttachedImplements() or {}) do
            self:collectTargetObjects(implement.object, objects, visited)
        end
    end
end

function GrappleIndicator:getCurrentTargetNode()
    local vehicle = self:getControlledVehicle()
    if vehicle == nil then
        return nil, nil, nil
    end

    -- Search the selected branch first (e.g. excavator -> coupler -> grapple),
    -- then the controlled vehicle's full attachment chain. Do not search other
    -- vehicles in the world or choose nodes by distance to the terrain.
    local selected = nil
    if vehicle.getSelectedVehicle ~= nil then
        selected = vehicle:getSelectedVehicle()
    end
    if selected == nil and vehicle.getSelectedImplement ~= nil then
        local implement = vehicle:getSelectedImplement()
        selected = implement ~= nil and implement.object or nil
    end
    local objects, visited = {}, {}
    self:collectTargetObjects(selected, objects, visited)
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    self:collectTargetObjects(root, objects, visited)
    self:collectTargetObjects(vehicle, objects, visited)

    -- Authoritative specialization data wins over naming heuristics anywhere
    -- in the chain. With multiple grabs on one object, use the first valid grab
    -- in its loaded XML order; there is no universal active-grab selector.
    for _, object in ipairs(objects) do
        local node, source = self:getLogGrabNode(object)
        if node ~= nil then
            return node, vehicle, selected, source, object
        end
    end
    for _, object in ipairs(objects) do
        local node, source = self:getMappedGrappleNode(object)
        if node ~= nil then
            return node, vehicle, selected, source, object
        end
    end
    return nil, vehicle, selected, "no supported grapple found", nil
end

function GrappleIndicator:getGroundPosition(node)
    if not self:isValidNode(node) or not self:isValidNode(g_terrainNode) then
        return nil
    end
    local x, y, z = getWorldTranslation(node)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    return x, terrainY, z, y
end

function GrappleIndicator:getIgnoredSurfaceNodes(trackedObject)
    local vehicle = self:getControlledVehicle()
    local root = vehicle ~= nil and vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    local objects, visited, nodes = {}, {}, {}
    self:collectTargetObjects(root, objects, visited)
    self:collectTargetObjects(vehicle, objects, visited)
    self:collectTargetObjects(trackedObject, objects, visited)
    for _, object in ipairs(objects) do
        if self:isValidNode(object.rootNode) then
            nodes[object.rootNode] = true
        end
        for _, component in ipairs(object.components or {}) do
            if self:isValidNode(component.node) then
                nodes[component.node] = true
            end
        end
    end
    return nodes
end

function GrappleIndicator:isIgnoredSurfaceNode(node, ignoredNodes)
    -- Compound collision shapes can be descendants of a vehicle component.
    while self:isValidNode(node) do
        if ignoredNodes[node] then
            return true
        end
        node = getParent(node)
    end
    return false
end

function GrappleIndicator:surfaceRaycastCallback(hitNode, x, y, z, distance, nx, ny, nz, subShapeIndex, shapeId)
    local query = self.raycastQuery
    if query == nil or not self:isValidNode(hitNode) then
        return false
    end
    if self:isIgnoredSurfaceNode(hitNode, query.ignoredNodes)
        or self:isIgnoredSurfaceNode(shapeId, query.ignoredNodes)
        or CollisionFlag.getHasGroupFlagSet(hitNode, CollisionFlag.TRIGGER) then
        return false
    end
    -- Callbacks need not arrive nearest-first. Keep scanning after rejected
    -- hits and choose the nearest solid surface above the terrain baseline.
    if distance >= 0 and distance < query.distance and y >= query.terrainY then
        query.distance = distance
        query.hitNode = hitNode
        query.y = y
    end
    -- FS25 raycastAll: returning true stops further callbacks; false continues.
    return false
end

function GrappleIndicator:updateSurfacePosition(target)
    self.surfacePosition = nil
    local node, trackedObject
    if target ~= nil then
        node, trackedObject = target.node, target.object
    else
        local detectedNode, _, _, _, detectedObject = self:getCurrentTargetNode()
        node, trackedObject = detectedNode, detectedObject
    end
    local x, terrainY, z, targetY = self:getGroundPosition(node)
    if x == nil then
        return
    end
    local startY = math.max(targetY, terrainY) + self.RAY_START_OFFSET
    local query = {
        terrainY = terrainY, y = terrainY, distance = math.huge,
        ignoredNodes = self:getIgnoredSurfaceNodes(trackedObject)
    }
    self.raycastQuery = query
    -- FS25 collision groups, including split logs (TREE), other vehicles,
    -- dynamic objects, buildings, roads and terrain. No physics is modified.
    local mask = CollisionFlag.TREE + CollisionFlag.DYNAMIC_OBJECT
        + CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING + CollisionFlag.ROAD
        + CollisionFlag.VEHICLE + CollisionFlag.TERRAIN + CollisionFlag.TERRAIN_DELTA
        + CollisionFlag.TERRAIN_DISPLACEMENT
    local distance = math.min(self.MAX_RAY_DISTANCE, startY - terrainY + 1)
    raycastAll(x, startY, z, 0, -1, 0, distance, "surfaceRaycastCallback", self, mask)
    self.raycastQuery = nil -- Synchronous: every callback has completed now.
    self.surfacePosition = {
        x = x, y = query.y, z = z, hitNode = query.hitNode, targetNode = node
    }
end

function GrappleIndicator:drawIndicator(node)
    local position = self.surfacePosition
    if position == nil or position.targetNode ~= node then
        return
    end
    if self.verticalBeam then
        self:drawVerticalBeam(node, position)
    end
    if self.markerStyle == self.STYLE_CIRCLE then
        self:drawCircle(position)
    elseif self.markerStyle == self.STYLE_FLAT_DOT then
        self:drawFlatDot(position)
    else
        self:drawScreenDot(position)
    end
end

function GrappleIndicator:drawVerticalBeam(node, position)
    if not self:isValidNode(node) then
        return
    end
    local x, y, z = getWorldTranslation(node)
    local surfaceY = position.y + self.GROUND_OFFSET
    local r, g, b = self:getMarkerColor()
    if y > surfaceY then
        drawDebugLine(x, y, z, r, g, b, x, surfaceY, z, r, g, b)
    end
end

function GrappleIndicator:drawCircle(position)
    local r, g, b = self:getMarkerColor()
    -- Restore the original terrain-following ring. Over an object, retain the
    -- single center-ray height rather than casting 32 additional rays per frame.
    local onTerrain = position.hitNode == nil or position.hitNode == g_terrainNode
    local function vertex(angle)
        local x = position.x + math.cos(angle) * self.CIRCLE_RADIUS
        local z = position.z + math.sin(angle) * self.CIRCLE_RADIUS
        local y = position.y
        if onTerrain and self:isValidNode(g_terrainNode) then
            y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
        end
        return x, y + self.GROUND_OFFSET, z
    end
    local previousX, previousY, previousZ = vertex(0)
    for segment = 1, self.CIRCLE_SEGMENTS do
        local x, y, z = vertex(segment * 2 * math.pi / self.CIRCLE_SEGMENTS)
        drawDebugLine(previousX, previousY, previousZ, r, g, b, x, y, z, r, g, b)
        previousX, previousY, previousZ = x, y, z
    end
end

function GrappleIndicator:drawFlatDot(position)
    local r, g, b = self:getMarkerColor()
    if g_cameraManager == nil or g_pixelSizeX == nil or g_pixelSizeY == nil then
        return
    end
    local camera = g_cameraManager:getActiveCamera()
    if not self:isValidNode(camera) then
        return
    end
    local x, y, z = position.x, position.y + self.GROUND_OFFSET, position.z
    local _, _, cameraZ = worldToLocal(camera, x, y, z)
    local nearClip = getNearClip(camera)
    if cameraZ >= -nearClip then
        return
    end
    local centerX, centerY = project(x, y, z)
    if centerX < 0 or centerX > 1 or centerY < 0 or centerY > 1 then
        return
    end

    -- Project a horizontal world-space disc, then fill its screen polygon with
    -- the same drawing API as the working screen-facing dot. Perspective gives
    -- it a flat/elliptical appearance, without relying on debug-triangle faces.
    local points = {}
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for segment = 0, self.FLAT_DOT_SEGMENTS - 1 do
        local angle = segment * 2 * math.pi / self.FLAT_DOT_SEGMENTS
        local vx = x + math.cos(angle) * self.FLAT_DOT_RADIUS
        local vz = z + math.sin(angle) * self.FLAT_DOT_RADIUS
        local _, _, vertexZ = worldToLocal(camera, vx, y, vz)
        if vertexZ >= -nearClip then
            return -- Do not project a polygon crossing the camera's near plane.
        end
        local sx, sy = project(vx, y, vz)
        local px, py = (sx - centerX) / g_pixelSizeX, (sy - centerY) / g_pixelSizeY
        points[#points + 1] = {px, py}
        minX, maxX = math.min(minX, px), math.max(maxX, px)
        minY, maxY = math.min(minY, py), math.max(maxY, py)
    end
    local diameter = math.max(maxX - minX, maxY - minY)
    if diameter <= 0 then
        return
    end
    local scale = math.max(1, self.FLAT_DOT_MIN_DIAMETER_PIXELS / diameter)
    local height = maxY - minY
    if height <= 0.000001 then
        -- Exactly edge-on, a horizontal disc appears as a thin line.
        drawFilledRect(centerX + minX * scale * g_pixelSizeX, centerY - g_pixelSizeY * 0.5,
            (maxX - minX) * scale * g_pixelSizeX, g_pixelSizeY, r, g, b, 1)
        return
    end
    -- Keep shallow viewing angles from collapsing between pixel scanlines.
    local heightScale = math.max(1, 2 / (height * scale))
    for _, point in ipairs(points) do
        point[2] = point[2] * heightScale
    end
    minY, maxY = minY * heightScale, maxY * heightScale
    local firstRow = math.max(math.floor(minY * scale), math.floor(-centerY / g_pixelSizeY))
    local lastRow = math.min(math.ceil(maxY * scale), math.ceil((1 - centerY) / g_pixelSizeY))
    for row = firstRow, lastRow do
        local sampleY = (row + 0.5) / scale
        local left, right = math.huge, -math.huge
        local previous = points[#points]
        for _, point in ipairs(points) do
            if (previous[2] <= sampleY and point[2] > sampleY)
                or (point[2] <= sampleY and previous[2] > sampleY) then
                local hitX = previous[1] + (sampleY - previous[2])
                    * (point[1] - previous[1]) / (point[2] - previous[2])
                left, right = math.min(left, hitX), math.max(right, hitX)
            end
            previous = point
        end
        if right > left then
            drawFilledRect(centerX + left * scale * g_pixelSizeX,
                centerY + row * g_pixelSizeY, (right - left) * scale * g_pixelSizeX,
                g_pixelSizeY, r, g, b, 1)
        end
    end
end

function GrappleIndicator:drawScreenDot(position)
    local r, g, b = self:getMarkerColor()
    if g_cameraManager == nil
        or g_pixelSizeX == nil or g_pixelSizeY == nil then
        return
    end
    local camera = g_cameraManager:getActiveCamera()
    if not self:isValidNode(camera) then
        return
    end
    local x, y, z = position.x, position.y + self.GROUND_OFFSET, position.z
    -- FS25 NavigationMarker uses worldToLocal + near clip before project().
    -- Do not mirror the dot onto the screen when the hit is behind the camera.
    local _, _, cameraZ = worldToLocal(camera, x, y, z)
    if cameraZ >= -getNearClip(camera) then
        return
    end
    local screenX, screenY = project(x, y, z)
    if screenX < 0 or screenX > 1 or screenY < 0 or screenY > 1 then
        return
    end
    -- A filled screen-space disc stays circular and readable at every zoom.
    -- One-pixel horizontal strips need no texture or overlay resource. This is
    -- a HUD marker at the projected surface point, so it draws over scene meshes.
    local radius = self.DOT_RADIUS_PIXELS
    local rows = math.max(1, math.ceil(radius * 2))
    for row = 0, rows - 1 do
        local offsetY = row + 0.5 - rows * 0.5
        local halfWidth = math.sqrt(math.max(0, radius * radius - offsetY * offsetY))
        drawFilledRect(screenX - halfWidth * g_pixelSizeX,
            screenY + (offsetY - 0.5) * g_pixelSizeY,
            2 * halfWidth * g_pixelSizeX, g_pixelSizeY, r, g, b, 1)
    end
end

function GrappleIndicator:logDiagnostics(node, vehicle, selected, source, trackedObject)
    if not self.DEBUG then
        return
    end
    local function describe(object)
        if object == nil then
            return "none"
        end
        return tostring(object.configFileName or object.typeName or object)
    end
    local nodeName = self:isValidNode(node) and getName(node) or "none"
    local surface = self.surfacePosition
    local surfaceNode = surface ~= nil and surface.hitNode or nil
    local diagnostic = string.format("Target: vehicle=%s; selected=%s; selectedRoot=%s; selectedComponent=%s; trackedNode=%s (%s); terrainAvailable=%s; source=%s; trackedObject=%s; surfaceNode=%s",
        describe(vehicle), describe(selected), tostring(selected ~= nil and selected.rootNode or nil),
        tostring(selected ~= nil and selected.components ~= nil and selected.components[1] ~= nil and selected.components[1].node or nil),
        tostring(node), tostring(nodeName), tostring(self:isValidNode(g_terrainNode)), tostring(source), describe(trackedObject), tostring(surfaceNode))
    if diagnostic ~= self.lastDiagnostic then
        self:log(diagnostic)
        local x, terrainY, z, targetY = self:getGroundPosition(node)
        if x ~= nil then
            self:log(string.format("Projection: target=(%.2f, %.2f, %.2f); ground=(%.2f, %.2f, %.2f)", x, targetY, z, x, terrainY, z))
            if surface ~= nil then
                self:log(string.format("Surface: dot=(%.2f, %.2f, %.2f); hit=%s", surface.x, surface.y, surface.z,
                    self:isValidNode(surfaceNode) and tostring(getName(surfaceNode)) or "terrain fallback"))
            end
        end
        self.lastDiagnostic = diagnostic
    end
end

function GrappleIndicator:logCurrentTarget()
    local target = self.currentTarget
    if target ~= nil and self.DEBUG then
        self:logDiagnostics(target.node, target.vehicle, target.selected, target.source, target.object)
    end
end

function GrappleIndicator:update(dt)
    if not self.mapLoaded or not self.isClient then
        return
    end
    local vehicle = self:getControlledVehicle()
    local hasGrapple = self:syncVehicleState(vehicle)
    local canToggle = self:getIsGameplayActive() and hasGrapple
    if canToggle then
        if vehicle ~= self.inputVehicle or self.inputDirty then
            self:removeInputAction()
            self.inputVehicle = vehicle
            self.inputDirty = false
            self.inputWarningShown = false
            self.inputRetryElapsed = self.INPUT_RETRY_MS
        end
        if self.actionEventId == nil then
            self.inputRetryElapsed = self.inputRetryElapsed + dt
            if self.inputRetryElapsed >= self.INPUT_RETRY_MS then
                self.inputRetryElapsed = 0
                self:registerInputAction()
            end
        end
    else
        self:removeInputAction()
        self.inputVehicle = nil
        self.inputDirty = false
        self.inputWarningShown = false
        self.inputRetryElapsed = self.INPUT_RETRY_MS
    end
    self:updateActionText()
    if self.enabled and self:getIsGameplayActive() then
        self:updateSurfacePosition(self.currentTarget)
    else
        self.surfacePosition = nil
    end
    if self.enabled and self:getIsGameplayActive() and self.DEBUG then
        self.debugElapsed = self.debugElapsed + dt
        if self.debugElapsed >= self.DEBUG_INTERVAL_MS then
            self.debugElapsed = 0
            self:logCurrentTarget()
        end
    end
end

function GrappleIndicator:draw()
    if not self.mapLoaded or not self.isClient then
        return
    end
    -- Render the update's snapshot. A switch between update and draw must
    -- never show the old machine's marker; the next update detects the new one.
    if self.activeVehicle ~= self:getControlledVehicle() then
        self.enabled = false
        self.surfacePosition = nil
        return
    end
    if self.enabled and self:getIsGameplayActive() then
        local target = self.currentTarget
        if target ~= nil and self:isValidNode(target.node)
            and target.object ~= nil and not target.object.isDeleted then
            self:drawIndicator(target.node)
        end
    end
end

-- Standard script-only mod listener: map lifecycle, update and draw callbacks.
-- Watch FS25's standard vehicle input rebuild without replacing its behavior.
Vehicle.registerActionEvents = Utils.appendedFunction(Vehicle.registerActionEvents, function(vehicle)
    GrappleIndicator:onVehicleActionEventsChanged(vehicle)
end)
addModEventListener(GrappleIndicator)
if InGameMenuSettingsFrame ~= nil then
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function(frame)
        GrappleIndicator:ensureSettingsControls(frame)
    end)
end
GrappleIndicator:log("Mod loaded (v1.0.1.0)")
