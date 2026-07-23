local Json = require("dkjson")
local Model = require("SandBox.ModelNameInitialize")
local PlacementCollision = require("SandBox.AI.AIPlacementCollision")

local AICommand = {}
AICommand.__index = AICommand

local ALLOWED = {
    DrawModel = true,
    DrawPlace = true,
    SelectModelMenu = true,
    ModelInfo = true,
    DeleteModel = true,
    ClearSelect = true,
    toBig = true,
    Undo = true,
    Redo = true,
    StopCrossCopy = true,
    ModelTip = true,
    ModelTipHide = true,
    MessageInfo = true
}

local DESTRUCTIVE = {
    DeleteModel = true
}

local DIRECT_POINT_MODEL_CODES = {
    Passage = true,
    diyssx = true,
    Area = true
}

local function is_null(value)
    return value == nil or value == Json.null
end

local function is_empty(value)
    return is_null(value) or value == ""
end

local SELECT_ID_KEYS = {
    "ID",
    "id",
    "controlId",
    "controlID",
    "actorId",
    "actorID",
    "targetId",
    "targetID",
    "modelCode",
    "showName",
    "displayName",
    "name"
}

local function normalize_lookup_text(value)
    if is_null(value) then
        return nil
    end
    local text = tostring(value)
    text = string.gsub(text, "%s+", "")
    text = string.gsub(text, "%-%d+$", "")
    return string.lower(text)
end

local function compact_lookup_text(value)
    if is_null(value) then
        return nil
    end
    local text = tostring(value)
    text = string.gsub(text, "%s+", "")
    return string.lower(text)
end

local function strip_actor_suffix(value)
    if is_null(value) then
        return value
    end
    return string.gsub(tostring(value), "%-s$", "")
end

local function area_signed_xy(points)
    if type(points) ~= "table" or #points < 3 then
        return 0
    end
    local signed = 0
    for index, point in ipairs(points) do
        local nextPoint = points[(index % #points) + 1]
        signed = signed + ((point.X or 0) * (nextPoint.Y or 0)) - ((nextPoint.X or 0) * (point.Y or 0))
    end
    return signed
end

local function normalize_area_points(points)
    if type(points) ~= "table" or #points < 3 then
        return points
    end
    if area_signed_xy(points) <= 0 then
        return points
    end
    local normalized = {}
    for index = #points, 1, -1 do
        table.insert(normalized, points[index])
    end
    return normalized
end

local function match_score(query, candidate, exactScore, containsScore)
    local q = normalize_lookup_text(query)
    local c = normalize_lookup_text(candidate)
    if is_empty(q) or is_empty(c) then
        return 0
    end
    if q == c then
        return exactScore
    end
    if string.find(q, c, 1, true) or string.find(c, q, 1, true) then
        return containsScore
    end
    return 0
end

local function select_id_from_item(item)
    if type(item) ~= "table" then
        return item
    end
    for _, key in ipairs(SELECT_ID_KEYS) do
        if not is_empty(item[key]) then
            return item[key]
        end
    end
    return nil
end

local function to_select_items(data)
    if type(data) ~= "table" then
        return { data }
    end
    if #data > 0 then
        return data
    end
    return { data }
end

local function has_meaningful_value(value)
    if is_empty(value) then
        return false
    end
    if type(value) ~= "table" then
        return true
    end
    for _, item in pairs(value) do
        if has_meaningful_value(item) then
            return true
        end
    end
    return false
end

local function is_clear_select_request(data)
    if is_null(data) then
        return true
    end
    if type(data) ~= "table" then
        return false
    end
    return not has_meaningful_value(data)
end

local function copy_array(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end
    for i, item in ipairs(value) do
        result[i] = item
    end
    return result
end

local function table_count(value)
    if type(value) ~= "table" then
        return 0
    end
    local count = #value
    if count > 0 then
        return count
    end
    for _ in pairs(value) do
        count = count + 1
    end
    return count
end

local function point_axis(point, lower, upper, index)
    if type(point) ~= "table" then
        return nil
    end
    local value = point[lower]
    if is_null(value) then value = point[upper] end
    if is_null(value) then value = point[index] end
    if is_null(value) then
        return nil
    end
    return tonumber(value)
end

local function to_number_or_nil(value)
    if is_null(value) then
        return nil
    end
    return tonumber(value)
end

local function encode_error(err)
    return tostring(err or "unknown error")
end

local function actor_valid(actor)
    if not actor then
        return false
    end
    if UE and UE.UKismetSystemLibrary and UE.UKismetSystemLibrary.IsValid then
        local ok, valid = pcall(UE.UKismetSystemLibrary.IsValid, actor)
        if ok then
            return valid
        end
    end
    return true
end

local function transform_to_table(actor)
    if not actor_valid(actor) then
        return nil
    end
    local ok, jsonStr = pcall(function()
        return UE.UJsonLibraryHelpers.JsonValue_Stringify(
            UE.UJsonLibraryHelpers.FromTransform(actor:GetTransform())
        )
    end)
    if not ok or not jsonStr then
        return nil
    end
    return Json.decode(jsonStr)
end

local function actor_location_to_table(actor)
    if not actor_valid(actor) then
        return nil
    end
    local ok, location = pcall(actor.K2_GetActorLocation, actor)
    if not ok or not location then
        return nil
    end
    return {
        x = location.X,
        y = location.Y,
        z = location.Z
    }
end

local function actor_display_name(actor)
    if not actor_valid(actor) then
        return nil
    end
    local ok, name = pcall(Model.GetActorAccurateDisplayName, actor)
    if ok and not is_empty(name) then
        return name
    end
    if UE and UE.UKismetSystemLibrary and UE.UKismetSystemLibrary.GetObjectName then
        local okName, objectName = pcall(UE.UKismetSystemLibrary.GetObjectName, actor)
        if okName and not is_empty(objectName) then
            return objectName
        end
    end
    return nil
end

function AICommand.New(ui)
    local self = setmetatable({}, AICommand)
    self.ui = ui
    self.control = ui and ui.control or nil
    return self
end

function AICommand:find_actor(id)
    if is_empty(id) or not self.control or not self.control.modelManage then
        return nil
    end
    local ok, actor = pcall(self.control.modelManage.FindActor, self.control.modelManage, id)
    if ok and actor_valid(actor) then
        return actor
    end
    return nil
end

function AICommand:to_control_id(id)
    local actor = self:find_actor(id)
    if not actor then
        return id
    end

    -- Frontend SelectModelMenu uses the tree/control id. For normal equipment
    -- this is the parent group id, while actorId often ends with "-s".
    if actor.bGroup then
        return Model.GetActorAccurateDisplayName(actor)
    end

    local ok, parent = pcall(actor.GetAttachParentActor, actor)
    if ok and actor_valid(parent) then
        return Model.GetActorAccurateDisplayName(parent)
    end
    return id
end

function AICommand:resolve_select_id(id)
    if is_empty(id) then
        return id
    end

    local tree = self.control and self.control.treeT or nil
    if type(tree) ~= "table" then
        return self:to_control_id(id)
    end

    local function visit(nodes, callback)
        if type(nodes) ~= "table" then
            return
        end
        for _, node in ipairs(nodes) do
            if type(node) == "table" then
                callback(node)
                visit(node.Childs, callback)
            end
        end
    end

    local function find_exact_id(value)
        local query = compact_lookup_text(value)
        if is_empty(query) then
            return nil
        end
        local found = nil
        visit(tree, function(node)
            if found then
                return
            end
            if compact_lookup_text(node.ID) == query then
                found = node.ID
            end
        end)
        return found
    end

    local exactId = find_exact_id(id)
    if exactId then
        return exactId
    end

    local strippedActorId = strip_actor_suffix(id)
    if tostring(strippedActorId) ~= tostring(id) then
        exactId = find_exact_id(strippedActorId)
        if exactId then
            return exactId
        end
    end

    local bestId = nil
    local bestScore = 0
    local bestTime = -1
    local queryRaw = compact_lookup_text(id)

    visit(tree, function(node)
        if is_empty(node.ID) then
            return
        end
        local score = 0
        if compact_lookup_text(node.showName) == queryRaw or compact_lookup_text(node.name) == queryRaw then
            score = 900
        else
            local q = normalize_lookup_text(id)
            if q and string.len(q) >= 2 then
                score = math.max(score, match_score(id, node.showName, 800, 500))
                score = math.max(score, match_score(id, node.name, 800, 500))
            end
        end

        local nodeTime = tonumber(node.time) or 0
        if score > bestScore or (score == bestScore and score > 0 and nodeTime > bestTime) then
            bestId = node.ID
            bestScore = score
            bestTime = nodeTime
        end
    end)

    if bestId then
        return bestId
    end

    local controlId = self:to_control_id(id)
    exactId = find_exact_id(controlId)
    if exactId then
        return exactId
    end

    return id
end

function AICommand:normalize_draw_model(data)
    data = data or {}
    if is_empty(data.modelCode) then
        return nil, { "DrawModel.modelCode" }
    end
    if is_empty(data.showName) then
        data.showName = data.modelCode
    end
    if is_null(data.modelUrl) then
        data.modelUrl = ""
    end
    if is_null(data.modelType) then
        data.modelType = true
    end
    if is_null(data.modelCategoryCode) then
        data.modelCategoryCode = ""
    end
    if is_null(data.isAnimation) then
        data.isAnimation = false
    end
    if is_null(data.autoPlace) then
        data.autoPlace = true
    end
    if is_null(data.autoClearSelect) then
        data.autoClearSelect = true
    end
    return data
end

function AICommand:normalize_select(data)
    local items = to_select_items(data)
    if #items == 0 then
        return nil, { "SelectModelMenu[1].ID" }
    end

    local result = {}
    local missing = {}
    for index, item in ipairs(items) do
        local id = select_id_from_item(item)
        if is_empty(id) then
            table.insert(missing, "SelectModelMenu[" .. tostring(index) .. "].ID")
        else
            table.insert(result, { ID = self:resolve_select_id(id) })
        end
    end
    if #missing > 0 then
        return nil, missing
    end
    return result
end

function AICommand:normalize_model_info(data)
    data = data or {}
    local transform = data.transform or data.Transform
    if type(transform) == "table" then
        local translation = transform.translation or transform.Translation
        local rotation = transform.rotation or transform.Rotation
        if type(translation) == "table" then
            if is_null(data.x) then data.x = translation.x or translation.X end
            if is_null(data.y) then data.y = translation.y or translation.Y end
            if is_null(data.z) then data.z = translation.z or translation.Z end
        else
            if is_null(data.x) then data.x = transform.x or transform.X end
            if is_null(data.y) then data.y = transform.y or transform.Y end
            if is_null(data.z) then data.z = transform.z or transform.Z end
        end
        if type(rotation) == "table" then
            if is_null(data.angle) then data.angle = rotation.yaw or rotation.Yaw or rotation.angle end
        else
            if is_null(data.angle) then data.angle = transform.angle or transform.yaw or transform.Yaw end
        end
    end
    return data
end

function AICommand:current_model_info()
    if not self.control or not actor_valid(self.control.buildActor) or not self.control.modelManage then
        return nil
    end

    local actor = self.control.buildActor
    local floorHeight = 0
    if actor.modelType == 6 and self.control.currentFloor and self.control.modelManage.FindActor then
        local okFloor, floor = pcall(self.control.modelManage.FindActor, self.control.modelManage, self.control.currentFloor .. "Floor-s")
        if okFloor and actor_valid(floor) then
            local okLoc, loc = pcall(floor.K2_GetActorLocation, floor)
            if okLoc and loc then
                floorHeight = loc.Z
            end
        end
    end

    local getter = self.control.modelManage.GetData and self.control.modelManage.GetData[actor.modelType]
    if not getter and self.control.modelManage.GetData then
        getter = self.control.modelManage.GetData["default"]
    end
    if getter then
        local ok, data = pcall(getter, actor, self.control.CurrentCH, floorHeight)
        if ok and type(data) == "table" then
            return data
        end
    end

    local transform = transform_to_table(actor)
    local translation = transform and transform.translation or {}
    local rotation = transform and transform.rotation or {}
    return {
        x = translation.x or 0,
        y = translation.y or 0,
        z = translation.z or 0,
        angle = rotation.yaw or 0,
        length = actor.size and actor.size.X or 0,
        width = actor.size and actor.size.Y or 0,
        height = actor.size and actor.size.Z or 0,
        showname = actor.showName or ""
    }
end

function AICommand:prepare_model_info_for_execute(data)
    data = self:normalize_model_info(data or {})
    local base = self:current_model_info() or {}
    local result = {}
    for _, key in ipairs({ "x", "y", "z", "angle", "length", "width", "height", "showname" }) do
        if not is_null(data[key]) and data[key] ~= "" then
            result[key] = data[key]
        else
            result[key] = base[key]
        end
    end
    if is_null(result.showname) then
        result.showname = ""
    end

    local missing = {}
    for _, key in ipairs({ "x", "y", "z", "angle", "length", "width", "height" }) do
        if is_null(result[key]) then
            table.insert(missing, "ModelInfo." .. key)
        end
    end
    if #missing > 0 then
        return nil, missing
    end
    return result
end

function AICommand:notify_web_selection(funcData)
    if not self.ui or not self.ui.UECallWeb or type(funcData) ~= "table" then
        return {
            ok = false,
            message = "UECallWeb not ready"
        }
    end

    local selection = nil
    if #funcData == 1 then
        selection = {
            id = funcData[1].ID
        }
    elseif #funcData > 1 then
        selection = {}
        for _, item in ipairs(funcData) do
            table.insert(selection, {
                id = item.ID
            })
        end
    else
        selection = {
            id = Json.null
        }
    end

    local okSelect, errSelect = pcall(self.ui.UECallWeb, self.ui, "selectModel", selection)
    if not okSelect then
        return {
            ok = false,
            message = encode_error(errSelect)
        }
    end

    pcall(self.ui.UECallWeb, self.ui, "automaticPositioningFun", nil)
    return {
        ok = true,
        selection = selection
    }
end

function AICommand:normalize_command(command)
    if type(command) ~= "table" then
        return nil, { "command" }
    end

    local funcName = command.funcName or command.FunctionName
    local funcData = command.funcData
    if is_null(funcData) then
        funcData = command.data
    end

    if is_empty(funcName) then
        return nil, { "funcName" }
    end
    if not ALLOWED[funcName] then
        return nil, { "unsupported funcName: " .. tostring(funcName) }
    end

    local normalizedData = funcData
    local missing
    if funcName == "DrawModel" then
        normalizedData, missing = self:normalize_draw_model(funcData)
    elseif funcName == "SelectModelMenu" then
        if is_clear_select_request(funcData) then
            funcName = "ClearSelect"
            normalizedData = {}
        else
            normalizedData, missing = self:normalize_select(funcData)
        end
    elseif funcName == "ModelInfo" then
        normalizedData, missing = self:normalize_model_info(funcData)
    elseif is_null(normalizedData) then
        normalizedData = {}
    end

    if missing then
        return nil, missing
    end

    return {
        funcName = funcName,
        funcData = normalizedData,
        confirmed = command.confirmed == true
    }
end

function AICommand:model_info_from_action(data)
    local info = data.modelInfo or data.transform or {}
    for _, key in ipairs({ "x", "y", "z", "angle", "length", "width", "height", "showname" }) do
        if not is_null(data[key]) then
            info[key] = data[key]
        end
    end
    if is_null(info.showname) then
        info.showname = data.showName or data.displayName or data.showname
    end
    return info
end

function AICommand:commands_from_action(data)
    local action = data.action
    local commands = {}

    if action == "create" then
        table.insert(commands, {
            funcName = "DrawModel",
            funcData = {
                modelCode = data.modelCode,
                showName = data.showName or data.displayName,
                modelUrl = data.modelUrl or "",
                modelType = true,
                modelCategoryCode = data.modelCategoryCode or "",
                isAnimation = data.isAnimation == true
            }
        })
        if data.modelInfo or data.transform or not is_null(data.x) then
            table.insert(commands, {
                funcName = "ModelInfo",
                funcData = self:model_info_from_action(data)
            })
        end
    elseif action == "select" or action == "focus" then
        table.insert(commands, {
            funcName = "SelectModelMenu",
            funcData = {
                { ID = data.controlId or data.actorId or data.id or data.ID or data.showName or data.displayName or data.name }
            }
        })
        if action == "focus" then
            table.insert(commands, { funcName = "toBig", funcData = {} })
        end
    elseif action == "move" or action == "update" then
        if not is_null(data.controlId) or not is_null(data.actorId) or not is_null(data.id) or not is_null(data.ID)
            or not is_null(data.showName) or not is_null(data.displayName) or not is_null(data.name) then
            table.insert(commands, {
                funcName = "SelectModelMenu",
                funcData = {
                    { ID = data.controlId or data.actorId or data.id or data.ID or data.showName or data.displayName or data.name }
                }
            })
        end
        table.insert(commands, {
            funcName = "ModelInfo",
            funcData = self:model_info_from_action(data)
        })
    elseif action == "delete" then
        table.insert(commands, {
            funcName = "SelectModelMenu",
            funcData = {
                { ID = data.controlId or data.actorId or data.id or data.ID or data.showName or data.displayName or data.name }
            }
        })
        table.insert(commands, {
            funcName = "DeleteModel",
            funcData = {},
            confirmed = data.confirmed == true
        })
    elseif action == "clearSelect" then
        table.insert(commands, { funcName = "ClearSelect", funcData = {} })
    elseif action == "undo" then
        table.insert(commands, { funcName = "Undo", funcData = {} })
    elseif action == "redo" then
        table.insert(commands, { funcName = "Redo", funcData = {} })
    end

    return commands
end

function AICommand:normalize_commands(data)
    if type(data) ~= "table" then
        return nil, { "data" }
    end

    local rawCommands
    if data.commands then
        if type(data.commands) == "table" and #data.commands > 0 then
            rawCommands = copy_array(data.commands)
        else
            rawCommands = { data.commands }
        end
    elseif data.funcName or data.FunctionName then
        rawCommands = { data }
    elseif data.action then
        rawCommands = self:commands_from_action(data)
    else
        return nil, { "commands or funcName or action" }
    end

    local commands = {}
    for index, command in ipairs(rawCommands) do
        local normalized, missing = self:normalize_command(command)
        if not normalized then
            return nil, {
                index = index,
                missing = missing
            }
        end
        table.insert(commands, normalized)
    end
    return commands
end

function AICommand:execute_one(command, rootData)
    if rootData.dryRun == true then
        return {
            ok = true,
            funcName = command.funcName,
            dryRun = true,
            destructive = DESTRUCTIVE[command.funcName] == true,
            requiresConfirmation = DESTRUCTIVE[command.funcName] == true,
            funcData = command.funcData
        }
    end

    if DESTRUCTIVE[command.funcName] and not (command.confirmed or rootData.confirmed == true) then
        return {
            ok = false,
            funcName = command.funcName,
            blocked = true,
            requiresConfirmation = true,
            message = "DeleteModel requires confirmed=true"
        }
    end

    if command.funcName == "ModelInfo" then
        local modelInfo, missing = self:prepare_model_info_for_execute(command.funcData)
        if not modelInfo then
            return {
                ok = false,
                funcName = command.funcName,
                missing = missing,
                message = "ModelInfo requires a selected model"
            }
        end
        command.funcData = modelInfo
    end

    local handler = self.ui and self.ui[command.funcName]
    if not handler then
        return {
            ok = false,
            funcName = command.funcName,
            message = "UI handler not found"
        }
    end

    local ok, result = pcall(handler, self.ui, command.funcData)
    if not ok then
        return {
            ok = false,
            funcName = command.funcName,
            message = encode_error(result)
        }
    end
    local response = {
        ok = true,
        funcName = command.funcName,
        result = result or Json.null
    }

    if command.funcName == "DrawModel" then
        response.autoPlace = self:auto_place_after_draw(command.funcData)
        if response.autoPlace and response.autoPlace.ok == false then
            response.ok = false
            response.message = response.autoPlace.message
        end
    elseif command.funcName == "DrawPlace" then
        response.autoPlace = self:auto_place_area_after_draw_place(command.funcData)
        if response.autoPlace and response.autoPlace.ok == false then
            response.ok = false
            response.message = response.autoPlace.message
        end
    elseif command.funcName == "SelectModelMenu" then
        response.selectionNotify = self:notify_web_selection(command.funcData)
    end

    return response
end

function AICommand:actor_reference(actor)
    if not actor_valid(actor) then
        return Json.null
    end

    local parent = nil
    local okParent, p = pcall(actor.GetAttachParentActor, actor)
    if okParent and actor_valid(p) then
        parent = p
    end

    local actorId = actor_display_name(actor)
    local controlId = parent and actor_display_name(parent) or actorId
    local sequenceMeta = self:actor_sequence_meta(actor, parent)
    return {
        controlId = controlId or Json.null,
        actorId = actorId or Json.null,
        showName = actor.showName or (parent and parent.showName) or Json.null,
        modelCode = actor.modelCode or (parent and parent.modelCode) or Json.null,
        modelType = actor.modelType or (parent and parent.modelType) or Json.null,
        location = actor_location_to_table(actor) or Json.null,
        productionLineOrder = sequenceMeta.productionLineOrder or Json.null,
        aiSequenceDrawIndex = sequenceMeta.aiSequenceDrawIndex or Json.null,
        sequenceOrder = sequenceMeta.sequenceOrder or Json.null,
        layoutMode = sequenceMeta.layoutMode or Json.null,
        layoutDirection = sequenceMeta.layoutDirection or Json.null
    }
end

function AICommand:actor_bounds(actor)
    if not actor_valid(actor) then
        return nil, nil, "actor invalid"
    end

    if actor.modelType == 10 then
        local okModelBounds, origin, boxExtent = pcall(function()
            return actor:GetModelBounds()
        end)
        if okModelBounds and origin and boxExtent then
            return origin, boxExtent
        end
    end

    local okBounds, origin, boxExtent = pcall(function()
        return actor:GetActorBounds(false)
    end)
    if okBounds and origin and boxExtent then
        return origin, boxExtent
    end

    return nil, nil, "actor bounds unavailable"
end

local function vector_to_table(value)
    if not value then
        return Json.null
    end
    return {
        x = value.X,
        y = value.Y,
        z = value.Z
    }
end

local function bounds_to_table(origin, boxExtent)
    if not origin or not boxExtent then
        return Json.null
    end
    return {
        center = vector_to_table(origin),
        extent = vector_to_table(boxExtent),
        size = {
            x = (boxExtent.X or 0) * 2,
            y = (boxExtent.Y or 0) * 2,
            z = (boxExtent.Z or 0) * 2
        },
        min = {
            x = (origin.X or 0) - (boxExtent.X or 0),
            y = (origin.Y or 0) - (boxExtent.Y or 0),
            z = (origin.Z or 0) - (boxExtent.Z or 0)
        },
        max = {
            x = (origin.X or 0) + (boxExtent.X or 0),
            y = (origin.Y or 0) + (boxExtent.Y or 0),
            z = (origin.Z or 0) + (boxExtent.Z or 0)
        }
    }
end

function AICommand:actor_spatial_record(actor)
    if not actor_valid(actor) then
        return nil
    end

    local origin, boxExtent = self:actor_bounds(actor)
    local ref = self:actor_reference(actor)
    local record = type(ref) == "table" and ref or {}
    record.transform = transform_to_table(actor) or Json.null
    record.bounds = bounds_to_table(origin, boxExtent)
    return record
end

function AICommand:is_spatial_model(actor)
    if not actor_valid(actor) then
        return false
    end
    if type(actor.modelType) ~= "number" then
        return false
    end
    return actor.modelType ~= 1
end

function AICommand:is_placement_occupancy(actor)
    return PlacementCollision.IsPlacementOccupancy(actor)
end

function AICommand:is_same_actor_or_group(actor, other)
    if not actor_valid(actor) or not actor_valid(other) then
        return false
    end
    if actor == other then
        return true
    end

    local actorRef = self:actor_reference(actor)
    local otherRef = self:actor_reference(other)
    if type(actorRef) ~= "table" or type(otherRef) ~= "table" then
        return false
    end
    return not is_empty(actorRef.controlId) and actorRef.controlId == otherRef.controlId
end

function AICommand:scene_spatial_models(excludeActor, occupancyOnly)
    local result = {}
    if not self.control or not self.control.modelManage or not self.control.modelManage.Actors then
        return result
    end

    local seen = {}
    for _, actor in pairs(self.control.modelManage.Actors) do
        local include = false
        if occupancyOnly then
            include = self:is_placement_occupancy(actor)
        else
            include = self:is_spatial_model(actor)
        end
        if include and not self:is_same_actor_or_group(actor, excludeActor) then
            local record = self:actor_spatial_record(actor)
            if record and type(record.bounds) == "table" then
                local key = not is_empty(record.actorId) and record.actorId or record.controlId
                if is_empty(key) then
                    key = tostring(#result + 1)
                end
                if not seen[key] then
                    seen[key] = true
                    table.insert(result, record)
                end
            end
        end
    end

    table.sort(result, function(a, b)
        local ax = a.bounds and a.bounds.center and a.bounds.center.x or 0
        local bx = b.bounds and b.bounds.center and b.bounds.center.x or 0
        if ax == bx then
            local ay = a.bounds and a.bounds.center and a.bounds.center.y or 0
            local by = b.bounds and b.bounds.center and b.bounds.center.y or 0
            return ay < by
        end
        return ax < bx
    end)

    return result
end

function AICommand:scene_space_summary(models)
    local summary = {
        count = #models,
        bounds = Json.null,
        occupiedArea = 0
    }
    if #models == 0 then
        return summary
    end

    local minX = math.huge
    local minY = math.huge
    local minZ = math.huge
    local maxX = -math.huge
    local maxY = -math.huge
    local maxZ = -math.huge

    for _, model in ipairs(models) do
        local bounds = model.bounds
        if bounds and bounds.min and bounds.max then
            minX = math.min(minX, bounds.min.x or minX)
            minY = math.min(minY, bounds.min.y or minY)
            minZ = math.min(minZ, bounds.min.z or minZ)
            maxX = math.max(maxX, bounds.max.x or maxX)
            maxY = math.max(maxY, bounds.max.y or maxY)
            maxZ = math.max(maxZ, bounds.max.z or maxZ)
            summary.occupiedArea = summary.occupiedArea +
                math.max(0, (bounds.max.x or 0) - (bounds.min.x or 0)) *
                math.max(0, (bounds.max.y or 0) - (bounds.min.y or 0))
        end
    end

    if minX ~= math.huge then
        summary.bounds = {
            min = { x = minX, y = minY, z = minZ },
            max = { x = maxX, y = maxY, z = maxZ },
            size = { x = maxX - minX, y = maxY - minY, z = maxZ - minZ },
            center = { x = (minX + maxX) / 2, y = (minY + maxY) / 2, z = (minZ + maxZ) / 2 }
        }
    end

    return summary
end

function AICommand:bounds_overlap_xy(a, b, padding)
    if type(a) ~= "table" or type(b) ~= "table" or not a.min or not a.max or not b.min or not b.max then
        return false
    end

    padding = padding or 0
    local aMinX = (a.min.x or 0) - padding
    local aMaxX = (a.max.x or 0) + padding
    local aMinY = (a.min.y or 0) - padding
    local aMaxY = (a.max.y or 0) + padding
    local bMinX = b.min.x or 0
    local bMaxX = b.max.x or 0
    local bMinY = b.min.y or 0
    local bMaxY = b.max.y or 0

    return aMinX < bMaxX and aMaxX > bMinX and aMinY < bMaxY and aMaxY > bMinY
end

function AICommand:overlap_padding_from_data(funcData)
    local padding = to_number_or_nil(funcData and (funcData.overlapPadding or funcData.collisionPadding or funcData.minClearance))
    if padding and padding >= 0 then
        return padding
    end
    padding = to_number_or_nil(funcData and (funcData.autoPlaceMargin or funcData.margin))
    if padding and padding >= 0 then
        return padding
    end
    return 600
end

function AICommand:detect_bounds_overlap(actor, funcData)
    local origin, boxExtent, boundsError = self:actor_bounds(actor)
    if not origin or not boxExtent then
        return {
            ok = false,
            hasOverlap = false,
            count = 0,
            actors = {},
            message = boundsError or "actor bounds unavailable"
        }
    end

    local sourceBounds = bounds_to_table(origin, boxExtent)
    local padding = self:overlap_padding_from_data(funcData)
    local overlaps = {}
    local seen = {}

    for _, item in ipairs(self:scene_spatial_models(actor, true)) do
        if item and not self:is_sequence_non_blocking_item(item, funcData)
            and item.bounds and self:bounds_overlap_xy(sourceBounds, item.bounds, padding) then
            local key = not is_empty(item.controlId) and item.controlId or item.actorId
            if is_empty(key) then
                key = tostring(#overlaps + 1)
            end
            if not seen[key] then
                seen[key] = true
                table.insert(overlaps, {
                    controlId = item.controlId or Json.null,
                    actorId = item.actorId or Json.null,
                    showName = item.showName or Json.null,
                    modelCode = item.modelCode or Json.null,
                    modelType = item.modelType or Json.null,
                    bounds = item.bounds or Json.null
                })
            end
        end
    end

    return {
        ok = true,
        hasOverlap = #overlaps > 0,
        count = #overlaps,
        source = self:actor_reference(actor),
        sourceBounds = sourceBounds,
        padding = padding,
        actors = overlaps
    }
end

function AICommand:detect_actor_overlap(actor, funcData)
    local okDetect, collision = pcall(PlacementCollision.Detect, self, actor, funcData)
    if okDetect and collision then
        return collision
    end

    if not actor_valid(actor) then
        return {
            ok = false,
            hasOverlap = false,
            count = 0,
            actors = {},
            message = "actor invalid"
        }
    end

    local origin, boxExtent, boundsError = self:actor_bounds(actor)
    if not origin or not boxExtent then
        return {
            ok = false,
            hasOverlap = false,
            count = 0,
            actors = {},
            message = boundsError or "actor bounds unavailable"
        }
    end

    local objectTypes = UE.TArray(UE.EObjectTypeQuery)
    objectTypes:Add(UE.EObjectTypeQuery.WorldStatic)

    local actorsToIgnore = UE.TArray(UE.AActor)
    actorsToIgnore:Add(actor)

    local okParent, parent = pcall(actor.GetAttachParentActor, actor)
    if okParent and actor_valid(parent) then
        actorsToIgnore:Add(parent)
    end

    local hitActors = UE.TArray(UE.AActor)
    local okOverlap, bTrace = pcall(
        UE.UKismetSystemLibrary.BoxOverlapActors,
        actor:GetWorld(),
        origin,
        boxExtent,
        objectTypes,
        UE.AStaticMeshActor,
        actorsToIgnore,
        hitActors
    )

    if not okOverlap then
        return {
            ok = false,
            hasOverlap = false,
            count = 0,
            actors = {},
            message = encode_error(bTrace)
        }
    end

    local source = self:actor_reference(actor)
    local sourceActorId = type(source) == "table" and source.actorId or nil
    local sourceControlId = type(source) == "table" and source.controlId or nil
    local overlaps = {}
    local seen = {}

    local function add_overlap(ref)
        if type(ref) ~= "table" then
            return
        end
        local actorId = ref.actorId
        local controlId = ref.controlId
        local sameActor = not is_empty(actorId) and actorId == sourceActorId
        local sameControl = not is_empty(controlId) and controlId == sourceControlId

        if not sameActor and not sameControl then
            local key = not is_empty(controlId) and controlId or actorId
            if is_empty(key) then
                key = tostring(#overlaps + 1)
            end
            if not seen[key] then
                seen[key] = true
                table.insert(overlaps, ref)
            end
        end
    end

    for _, hitActor in pairs(hitActors) do
        if actor_valid(hitActor) then
            local ref = self:actor_reference(hitActor)
            add_overlap(ref)
        end
    end

    local boundsOverlap = self:detect_bounds_overlap(actor, funcData)
    if boundsOverlap and boundsOverlap.ok == true then
        for _, ref in ipairs(boundsOverlap.actors or {}) do
            add_overlap(ref)
        end
    end

    return {
        ok = true,
        hasOverlap = #overlaps > 0,
        count = #overlaps,
        rawCount = hitActors:Num(),
        source = source,
        boundsOverlap = boundsOverlap or Json.null,
        actors = overlaps
    }
end

function AICommand:placement_check(actor)
    if not actor_valid(actor) then
        return nil
    end

    local overlap = self:detect_actor_overlap(actor)
    local buildMode = self.control and self.control.bBuild == true
    local canPlace = self.control and self.control.bBlock == true
    local blocked = buildMode and canPlace ~= true
    local blockedReason = Json.null

    if blocked then
        if overlap and overlap.ok == true and overlap.hasOverlap == true then
            blockedReason = "overlap"
        else
            blockedReason = "invalidPlacementPoint"
        end
    end

    return {
        ok = true,
        buildMode = buildMode,
        canPlace = canPlace,
        blocked = blocked,
        blockedReason = blockedReason,
        actor = self:actor_reference(actor),
        overlap = overlap or Json.null
    }
end

function AICommand:auto_place_location_from_data(funcData, actor)
    funcData = funcData or {}
    local source = funcData.location or funcData.position
    if type(source) ~= "table" and type(funcData.transform) == "table" then
        source = funcData.transform.translation or funcData.transform.Translation or funcData.transform.location
    end

    local x = nil
    local y = nil
    local z = nil
    if type(source) == "table" then
        x = point_axis(source, "x", "X", 1)
        y = point_axis(source, "y", "Y", 2)
        z = point_axis(source, "z", "Z", 3)
    end
    if is_null(x) then x = to_number_or_nil(funcData.x or funcData.X) end
    if is_null(y) then y = to_number_or_nil(funcData.y or funcData.Y) end
    if is_null(z) then z = to_number_or_nil(funcData.z or funcData.Z) end

    if is_null(x) and is_null(y) and is_null(z) then
        return nil
    end

    local current = UE.FVector(0, 0, 0)
    if actor_valid(actor) then
        local ok, loc = pcall(actor.K2_GetActorLocation, actor)
        if ok and loc then
            current = loc
        end
    end

    return UE.FVector(x or current.X, y or current.Y, z or current.Z)
end

function AICommand:vector_from_point_table(point)
    if type(point) ~= "table" then
        return nil
    end
    local x = point_axis(point, "x", "X", 1)
    local y = point_axis(point, "y", "Y", 2)
    local z = point_axis(point, "z", "Z", 3)
    if is_null(x) or is_null(y) then
        return nil
    end
    return UE.FVector(x, y, z or 0)
end

function AICommand:placement_region_from_data(funcData)
    if type(funcData) ~= "table" then
        return nil
    end
    local region = funcData.placementRegion or funcData.region or funcData.placementBounds or funcData.bounds
    if type(region) ~= "table" then
        return nil
    end

    local function bounds_from_min_max(minValue, maxValue)
        local minPoint = nil
        local maxPoint = nil
        if minValue and minValue.X and minValue.Y then
            minPoint = minValue
        else
            minPoint = self:vector_from_point_table(minValue)
        end
        if maxValue and maxValue.X and maxValue.Y then
            maxPoint = maxValue
        else
            maxPoint = self:vector_from_point_table(maxValue)
        end
        if not minPoint or not maxPoint then
            return nil
        end
        return {
            type = "bounds",
            min = {
                x = math.min(minPoint.X, maxPoint.X),
                y = math.min(minPoint.Y, maxPoint.Y),
                z = math.min(minPoint.Z, maxPoint.Z)
            },
            max = {
                x = math.max(minPoint.X, maxPoint.X),
                y = math.max(minPoint.Y, maxPoint.Y),
                z = math.max(minPoint.Z, maxPoint.Z)
            }
        }
    end

    if type(region.min) == "table" and type(region.max) == "table" then
        return bounds_from_min_max(region.min, region.max)
    end

    local points = {}
    local rawPoints = region.points or region.PointLocations or region
    if type(rawPoints) == "table" then
        for _, point in ipairs(rawPoints) do
            local vector = self:vector_from_point_table(point)
            if vector then
                table.insert(points, vector)
            end
        end
    end

    if #points == 2 then
        return bounds_from_min_max(points[1], points[2])
    elseif #points >= 3 then
        local minX = math.huge
        local minY = math.huge
        local maxX = -math.huge
        local maxY = -math.huge
        for _, point in ipairs(points) do
            minX = math.min(minX, point.X)
            minY = math.min(minY, point.Y)
            maxX = math.max(maxX, point.X)
            maxY = math.max(maxY, point.Y)
        end
        return {
            type = "polygon",
            points = points,
            bounds = {
                min = { x = minX, y = minY, z = 0 },
                max = { x = maxX, y = maxY, z = 0 }
            }
        }
    end

    if not is_null(region.minX or region.xMin) and not is_null(region.maxX or region.xMax)
        and not is_null(region.minY or region.yMin) and not is_null(region.maxY or region.yMax) then
        return bounds_from_min_max(
            { x = region.minX or region.xMin, y = region.minY or region.yMin, z = region.minZ or region.zMin or 0 },
            { x = region.maxX or region.xMax, y = region.maxY or region.yMax, z = region.maxZ or region.zMax or 0 }
        )
    end

    return nil
end

function AICommand:area_points_from_region(funcData)
    local region = self:placement_region_from_data(funcData)
    if not region then
        return nil
    end

    if region.type == "bounds" and region.min and region.max then
        local z = region.min.z or region.max.z or 0
        return normalize_area_points({
            UE.FVector(region.min.x, region.min.y, z),
            UE.FVector(region.max.x, region.min.y, z),
            UE.FVector(region.max.x, region.max.y, z),
            UE.FVector(region.min.x, region.max.y, z)
        })
    end

    if region.type == "polygon" and type(region.points) == "table" and #region.points >= 3 then
        local points = {}
        for _, point in ipairs(region.points) do
            table.insert(points, UE.FVector(point.X, point.Y, point.Z or 0))
        end
        return normalize_area_points(points)
    end

    return nil
end

function AICommand:find_existing_floor()
    if not self.control or not self.control.modelManage or not self.control.modelManage.Actors then
        return nil
    end
    local fallback = nil
    for _, actor in pairs(self.control.modelManage.Actors) do
        if actor_valid(actor) and tonumber(actor.modelType) == 6 then
            fallback = fallback or actor
            local parent = nil
            local okParent, parentActor = pcall(actor.GetAttachParentActor, actor)
            if okParent and actor_valid(parentActor) then
                parent = parentActor
            end
            local showName = tostring(actor.showName or (parent and parent.showName) or "")
            local actorId = actor_display_name(actor)
            if showName == "地板" or actor.modelCode == "Area" or actorId == "Area-s" then
                return actor
            end
        end
    end
    return fallback
end

function AICommand:has_existing_floor()
    return self:find_existing_floor() ~= nil
end

function AICommand:update_existing_floor_area(actor, points, funcData, region)
    funcData = funcData or {}
    if not actor_valid(actor) then
        return {
            ok = false,
            modelCode = "Area",
            message = "existing floor actor is invalid"
        }
    end
    if type(points) ~= "table" or #points < 3 then
        return {
            ok = false,
            modelCode = "Area",
            message = "auto floor update requires at least three points"
        }
    end

    points = normalize_area_points(points)

    actor.simplePoints:Clear()
    for _, point in ipairs(points) do
        actor.simplePoints:Add(point)
    end
    self:apply_direct_point_defaults(actor, funcData)
    pcall(actor.SetActorHiddenInGame, actor, false)
    if actor.PMesh then
        pcall(actor.PMesh.SetVisibility, actor.PMesh, true, true)
        pcall(actor.PMesh.SetHiddenInGame, actor.PMesh, false, true)
        pcall(actor.PMesh.SetRenderCustomDepth, actor.PMesh, false)
    end
    actor:SetSplineModel()
    if actor.SetDynamicMaterial then
        pcall(actor.SetDynamicMaterial, actor)
    end

    if self.control and self.control.modelManage then
        pcall(self.control.modelManage.ClearPoints, self.control.modelManage)
        pcall(self.control.modelManage.BuildShowArea, self.control.modelManage, actor)
    end
    if self.control and actor.modelType == 6 and self.control.FloorDataToView then
        pcall(self.control.FloorDataToView, self.control)
    end
    if self.control and self.control.ModelDataToView then
        local oldBuildActor = self.control.buildActor
        self.control.buildActor = actor
        pcall(self.control.ModelDataToView, self.control, true)
        self.control.buildActor = oldBuildActor
    end

    local clearResult = nil
    if funcData.autoClearSelect ~= false then
        clearResult = self:clear_selection_after_auto_place()
    end

    return {
        ok = true,
        updated = true,
        modelCode = "Area",
        actorId = actor_display_name(actor) or Json.null,
        pointCount = #points,
        placementRegion = region or Json.null,
        clearSelect = clearResult or Json.null
    }
end

function AICommand:is_floor_spatial_record(record)
    if type(record) ~= "table" then
        return false
    end
    if tonumber(record.modelType) == 6 then
        return true
    end
    local modelCode = tostring(record.modelCode or "")
    local showName = tostring(record.showName or "")
    return modelCode == "Area" or showName == "地板"
end

function AICommand:floor_fit_region_from_scene(margin)
    local models = self:scene_spatial_models(nil, false)
    local targets = {}
    for _, model in ipairs(models) do
        if not self:is_floor_spatial_record(model) then
            table.insert(targets, model)
        end
    end

    local space = self:scene_space_summary(targets)
    if type(space.bounds) ~= "table" or space.bounds == Json.null or not space.bounds.min or not space.bounds.max then
        return nil
    end

    local b = space.bounds
    local padding = tonumber(margin) or 1200
    return {
        type = "bounds",
        source = "autoFitFloor",
        min = {
            x = (b.min.x or 0) - padding,
            y = (b.min.y or 0) - padding,
            z = 0
        },
        max = {
            x = (b.max.x or 0) + padding,
            y = (b.max.y or 0) + padding,
            z = 0
        }
    }
end

function AICommand:auto_fit_existing_floor_after_execute(rootData)
    rootData = rootData or {}
    if rootData.dryRun == true or rootData.autoFitFloor ~= true then
        return nil
    end

    local floor = self:find_existing_floor()
    if not floor then
        return nil
    end

    local margin = rootData.autoFloorMargin or rootData.floorMargin or rootData.fitFloorMargin or 1200
    local region = self:floor_fit_region_from_scene(margin)
    if not region then
        return {
            ok = true,
            skipped = true,
            modelCode = "Area",
            message = "no non-floor model bounds available for floor fit"
        }
    end

    local funcData = {
        modelCode = "Area",
        showName = "地板",
        placementRegion = region,
        autoClearSelect = true
    }
    local points = self:area_points_from_region(funcData)
    if not points then
        return {
            ok = false,
            modelCode = "Area",
            placementRegion = region,
            message = "auto floor fit could not build area points"
        }
    end

    return self:update_existing_floor_area(floor, points, funcData, region)
end

function AICommand:point_inside_polygon_xy(x, y, points)
    if type(points) ~= "table" or #points < 3 then
        return false
    end

    local inside = false
    local j = #points
    for i = 1, #points do
        local pi = points[i]
        local pj = points[j]
        if pi and pj then
            local yi = pi.Y or 0
            local yj = pj.Y or 0
            local xi = pi.X or 0
            local xj = pj.X or 0
            local intersects = ((yi > y) ~= (yj > y))
                and (x < (xj - xi) * (y - yi) / ((yj - yi) ~= 0 and (yj - yi) or 0.000001) + xi)
            if intersects then
                inside = not inside
            end
        end
        j = i
    end
    return inside
end

function AICommand:location_fits_placement_region(location, boxExtent, region)
    if not region or not location then
        return true
    end

    local ex = boxExtent and math.abs(boxExtent.X or 0) or 0
    local ey = boxExtent and math.abs(boxExtent.Y or 0) or 0
    local minX = location.X - ex
    local maxX = location.X + ex
    local minY = location.Y - ey
    local maxY = location.Y + ey

    if region.type == "bounds" then
        return minX >= region.min.x and maxX <= region.max.x and minY >= region.min.y and maxY <= region.max.y
    elseif region.type == "polygon" then
        return self:point_inside_polygon_xy(minX, minY, region.points)
            and self:point_inside_polygon_xy(minX, maxY, region.points)
            and self:point_inside_polygon_xy(maxX, minY, region.points)
            and self:point_inside_polygon_xy(maxX, maxY, region.points)
    end

    return true
end

function AICommand:clamp_location_to_placement_region(location, boxExtent, region, margin)
    if not location or not region or region.type ~= "bounds" or not region.min or not region.max then
        return nil
    end

    local minX = to_number_or_nil(region.min.x)
    local maxX = to_number_or_nil(region.max.x)
    local minY = to_number_or_nil(region.min.y)
    local maxY = to_number_or_nil(region.max.y)
    if not minX or not maxX or not minY or not maxY then
        return nil
    end

    local ex = boxExtent and math.abs(boxExtent.X or 0) or 0
    local ey = boxExtent and math.abs(boxExtent.Y or 0) or 0
    local sourceX = location.X or 0
    local sourceY = location.Y or 0
    local z = location.Z or 0
    local paddings = { math.max(0, to_number_or_nil(margin) or 0), 0 }

    for _, padding in ipairs(paddings) do
        local allowedMinX = minX + ex + padding
        local allowedMaxX = maxX - ex - padding
        local allowedMinY = minY + ey + padding
        local allowedMaxY = maxY - ey - padding
        if allowedMinX <= allowedMaxX and allowedMinY <= allowedMaxY then
            local x = math.max(allowedMinX, math.min(allowedMaxX, sourceX))
            local y = math.max(allowedMinY, math.min(allowedMaxY, sourceY))
            local candidate = UE.FVector(x, y, z)
            if self:location_fits_placement_region(candidate, boxExtent, region) then
                return candidate
            end
        end
    end

    return nil
end

function AICommand:placement_region_seed_locations(region, z, boxExtent, margin)
    local seeds = {}
    if not region then
        return seeds
    end

    local bounds = region.type == "bounds" and region or region.bounds
    if not bounds or not bounds.min or not bounds.max then
        return seeds
    end

    local ex = boxExtent and math.abs(boxExtent.X or 0) or 0
    local ey = boxExtent and math.abs(boxExtent.Y or 0) or 0
    local minX = bounds.min.x + ex + margin
    local maxX = bounds.max.x - ex - margin
    local minY = bounds.min.y + ey + margin
    local maxY = bounds.max.y - ey - margin
    if minX > maxX or minY > maxY then
        return seeds
    end

    local centerX = (minX + maxX) / 2
    local centerY = (minY + maxY) / 2
    local stepX = math.max(ex * 2 + margin, (maxX - minX) / 4, 800)
    local stepY = math.max(ey * 2 + margin, (maxY - minY) / 4, 800)

    table.insert(seeds, UE.FVector(centerX, centerY, z))
    for x = minX, maxX, stepX do
        for y = minY, maxY, stepY do
            table.insert(seeds, UE.FVector(x, y, z))
        end
    end
    for x = maxX, minX, -stepX do
        for y = maxY, minY, -stepY do
            table.insert(seeds, UE.FVector(x, y, z))
        end
    end

    return seeds
end

function AICommand:auto_place_spacing(actor, funcData)
    local spacing = to_number_or_nil(funcData and (funcData.autoPlaceSpacing or funcData.spacing))
    if spacing and spacing > 0 then
        return spacing
    end

    local _, boxExtent = self:actor_bounds(actor)
    local maxExtent = 0
    if boxExtent then
        maxExtent = math.max(math.abs(boxExtent.X or 0), math.abs(boxExtent.Y or 0))
    end
    return math.max(maxExtent * 2 + 1200, 7000)
end

function AICommand:should_spread_auto_place(funcData)
    if type(funcData) ~= "table" then
        return false
    end
    if funcData.autoPlaceStrategy == "smart" or funcData.autoPlaceStrategy == "spaceAware"
        or funcData.autoPlaceStrategy == "spread" or funcData.avoidOverlap == true then
        return true
    end
    return (tonumber(funcData.aiSequenceCount) or tonumber(funcData.sequenceCount) or 0) > 1
end

function AICommand:is_sequence_layout(funcData)
    if type(funcData) ~= "table" then
        return false
    end
    return funcData.layoutMode == "productionLine"
        or funcData.autoPlaceStrategy == "lineSequence"
        or funcData.autoPlaceStrategy == "lineConnector"
end

function AICommand:is_sequence_non_blocking_item(item, funcData)
    if not self:is_sequence_layout(funcData) then
        return false
    end
    local modelType = item and tonumber(item.modelType)
    local modelCode = item and tostring(item.modelCode or "") or ""
    local showName = item and tostring(item.showName or "") or ""
    return modelType == 7
        or modelType == 14
        or modelCode == "diyssx"
        or modelCode == "Passage"
        or string.find(showName, "输送线", 1, true) ~= nil
        or string.find(showName, "通道", 1, true) ~= nil
end

function AICommand:sequence_actor_key(value)
    if is_null(value) then
        return nil
    end
    local numberValue = tonumber(value)
    if numberValue then
        return tostring(math.floor(numberValue))
    end
    local text = tostring(value)
    if text == "" then
        return nil
    end
    return text
end

function AICommand:sequence_meta_from_data(funcData)
    if type(funcData) ~= "table" then
        return nil
    end
    local meta = {
        productionLineOrder = funcData.productionLineOrder,
        aiSequenceDrawIndex = funcData.aiSequenceDrawIndex,
        sequenceOrder = funcData.sequenceOrder,
        layoutMode = funcData.layoutMode,
        layoutDirection = funcData.layoutDirection
    }
    if is_null(meta.productionLineOrder) and is_null(meta.aiSequenceDrawIndex)
        and is_null(meta.sequenceOrder) then
        return nil
    end
    return meta
end

function AICommand:remember_actor_sequence_meta(actor, meta)
    if not actor_valid(actor) or type(meta) ~= "table" then
        return
    end

    local actorId = actor_display_name(actor)
    local parent = nil
    local okParent, p = pcall(actor.GetAttachParentActor, actor)
    if okParent and actor_valid(p) then
        parent = p
    end
    local controlId = parent and actor_display_name(parent) or actorId

    if self.control then
        self.control.aiSequenceActorMeta = self.control.aiSequenceActorMeta or {}
        if not is_empty(actorId) then
            self.control.aiSequenceActorMeta[actorId] = meta
        end
        if not is_empty(controlId) then
            self.control.aiSequenceActorMeta[controlId] = meta
        end
    end

    pcall(function()
        actor.aiSequenceMeta = meta
    end)
    pcall(function()
        actor.productionLineOrder = meta.productionLineOrder
        actor.aiSequenceDrawIndex = meta.aiSequenceDrawIndex
        actor.sequenceOrder = meta.sequenceOrder
        actor.layoutMode = meta.layoutMode
        actor.layoutDirection = meta.layoutDirection
    end)
    if parent then
        pcall(function()
            parent.aiSequenceMeta = meta
        end)
    end
end

function AICommand:actor_sequence_meta(actor, parent)
    if not actor_valid(actor) then
        return {}
    end

    local okDirect, directMeta = pcall(function()
        return actor.aiSequenceMeta
    end)
    if okDirect and type(directMeta) == "table" then
        return directMeta
    end

    local actorId = actor_display_name(actor)
    local controlId = nil
    if parent and actor_valid(parent) then
        controlId = actor_display_name(parent)
    end

    local store = self.control and self.control.aiSequenceActorMeta
    if type(store) == "table" then
        if not is_empty(actorId) and type(store[actorId]) == "table" then
            return store[actorId]
        end
        if not is_empty(controlId) and type(store[controlId]) == "table" then
            return store[controlId]
        end
    end

    local meta = {}
    pcall(function()
        meta.productionLineOrder = actor.productionLineOrder
        meta.aiSequenceDrawIndex = actor.aiSequenceDrawIndex
        meta.sequenceOrder = actor.sequenceOrder
        meta.layoutMode = actor.layoutMode
        meta.layoutDirection = actor.layoutDirection
    end)
    if parent and actor_valid(parent) then
        pcall(function()
            meta.productionLineOrder = meta.productionLineOrder or parent.productionLineOrder
            meta.aiSequenceDrawIndex = meta.aiSequenceDrawIndex or parent.aiSequenceDrawIndex
            meta.sequenceOrder = meta.sequenceOrder or parent.sequenceOrder
            meta.layoutMode = meta.layoutMode or parent.layoutMode
            meta.layoutDirection = meta.layoutDirection or parent.layoutDirection
        end)
    end
    return meta
end

function AICommand:remember_sequence_actor(funcData, actor)
    if not self:is_sequence_layout(funcData) or not actor_valid(actor) then
        return
    end
    if funcData.connectRole == "between_models" then
        return
    end

    self.sequenceLayoutActors = self.sequenceLayoutActors or {}
    local meta = self:sequence_meta_from_data(funcData)
    self:remember_actor_sequence_meta(actor, meta)
    local keys = {
        funcData.productionLineOrder,
        funcData.aiSequenceDrawIndex,
        funcData.sequenceOrder
    }
    for _, value in pairs(keys) do
        local key = self:sequence_actor_key(value)
        if key then
            self.sequenceLayoutActors[key] = actor
        end
    end
end

function AICommand:rebuild_sequence_actors_from_scene()
    if not self.control or not self.control.modelManage or not self.control.modelManage.Actors then
        return
    end
    self.sequenceLayoutActors = self.sequenceLayoutActors or {}
    for _, actor in pairs(self.control.modelManage.Actors) do
        if actor_valid(actor) then
            local meta = self:actor_sequence_meta(actor)
            local keys = {
                meta.productionLineOrder,
                meta.aiSequenceDrawIndex,
                meta.sequenceOrder
            }
            for _, value in pairs(keys) do
                local key = self:sequence_actor_key(value)
                if key and not self.sequenceLayoutActors[key] then
                    self.sequenceLayoutActors[key] = actor
                end
            end
        end
    end
end

function AICommand:sequence_actor(value)
    local key = self:sequence_actor_key(value)
    if not key then
        return nil
    end
    if type(self.sequenceLayoutActors) ~= "table" then
        self.sequenceLayoutActors = self.sequenceLayoutActors or {}
    end
    local actor = self.sequenceLayoutActors[key]
    if actor_valid(actor) then
        return actor
    end
    self:rebuild_sequence_actors_from_scene()
    actor = self.sequenceLayoutActors[key]
    if actor_valid(actor) then
        return actor
    end
    return nil
end

function AICommand:connection_actor_orders(funcData)
    if type(funcData) ~= "table" or funcData.connectRole ~= "between_models" then
        return nil, nil
    end
    local fromOrder = funcData.connectFromOrder or funcData.fromOrder or funcData.prevOrder or funcData.sourceOrder
    local toOrder = funcData.connectToOrder or funcData.toOrder or funcData.nextOrder or funcData.targetOrder
    return fromOrder, toOrder
end

local function first_connection_ref(funcData, keys)
    if type(funcData) ~= "table" then
        return nil
    end
    for _, key in ipairs(keys) do
        local value = funcData[key]
        if type(value) == "table" then
            value = select_id_from_item(value)
        end
        if not is_empty(value) then
            return value
        end
    end
    return nil
end

function AICommand:actor_from_connection_ref(funcData, side)
    local keys = side == "from" and {
        "connectFromActorId",
        "connectFromControlId",
        "connectFromId",
        "fromActorId",
        "fromControlId",
        "fromId",
        "sourceActorId",
        "sourceControlId",
        "sourceId"
    } or {
        "connectToActorId",
        "connectToControlId",
        "connectToId",
        "toActorId",
        "toControlId",
        "toId",
        "targetActorId",
        "targetControlId",
        "targetId"
    }
    local rawId = first_connection_ref(funcData, keys)
    if is_empty(rawId) then
        return nil
    end

    local candidates = {
        rawId,
        strip_actor_suffix(rawId)
    }
    local resolved = self:resolve_select_id(rawId)
    if not is_empty(resolved) then
        table.insert(candidates, resolved)
    end

    for _, id in ipairs(candidates) do
        if not is_empty(id) then
            local actor = self:find_actor(id)
            if actor_valid(actor) then
                return actor
            end
        end
    end
    return nil
end

function AICommand:connection_actor(funcData, side, order)
    local actor = self:actor_from_connection_ref(funcData, side)
    if actor_valid(actor) then
        return actor
    end
    return self:sequence_actor(order)
end

function AICommand:try_sequence_cross_axis_fallback(actor, funcData, baseLocation, placementRegion)
    if not placementRegion or placementRegion.type ~= "bounds" or not placementRegion.min or not placementRegion.max then
        return nil
    end

    local _, actorExtent = self:actor_bounds(actor)
    local direction = tostring(funcData.layoutDirection or "")
    local vertical = direction == "topToBottom" or direction == "bottomToTop"
    local minCross = vertical and placementRegion.min.x or placementRegion.min.y
    local maxCross = vertical and placementRegion.max.x or placementRegion.max.y
    local crossExtent = actorExtent and math.abs(vertical and (actorExtent.X or 0) or (actorExtent.Y or 0)) or 0
    local usableMin = (minCross or 0) + crossExtent
    local usableMax = (maxCross or 0) - crossExtent
    if usableMin > usableMax then
        return nil
    end

    local fractions = { 0.5, 0.25, 0.75, 0.15, 0.85, 0.35, 0.65 }
    local seen = {}
    for _, fraction in ipairs(fractions) do
        local cross = usableMin + (usableMax - usableMin) * fraction
        local key = tostring(math.floor(cross * 100))
        if not seen[key] then
            seen[key] = true
            local candidate = vertical
                and UE.FVector(cross, baseLocation.Y, baseLocation.Z)
                or UE.FVector(baseLocation.X, cross, baseLocation.Z)
            if self:location_fits_placement_region(candidate, actorExtent, placementRegion) then
                local hit = UE.FHitResult()
                local okSet = pcall(actor.K2_SetActorLocation, actor, candidate, false, hit, false)
                if okSet then
                    local overlap = self:detect_actor_overlap(actor, funcData)
                    local canPlace = overlap and overlap.ok == true and overlap.hasOverlap ~= true
                    self:set_build_feedback(actor, canPlace, overlap)
                    if canPlace then
                        return {
                            ok = true,
                            buildMode = self.control and self.control.bBuild == true,
                            canPlace = true,
                            blocked = false,
                            blockedReason = Json.null,
                            actor = self:actor_reference(actor),
                            overlap = overlap or Json.null,
                            placementRegion = placementRegion or Json.null,
                            autoLocation = {
                                x = candidate.X,
                                y = candidate.Y,
                                z = candidate.Z
                            },
                            sequenceLocked = true,
                            crossAxisFallback = true
                        }
                    end
                end
            end
        end
    end

    return nil
end

function AICommand:boundary_connection_points(funcData)
    local fromOrder, toOrder = self:connection_actor_orders(funcData)

    local fromActor = self:connection_actor(funcData, "from", fromOrder)
    local toActor = self:connection_actor(funcData, "to", toOrder)
    if not actor_valid(fromActor) or not actor_valid(toActor) then
        return nil
    end

    local fromOrigin, fromExtent = self:actor_bounds(fromActor)
    local toOrigin, toExtent = self:actor_bounds(toActor)
    if not fromOrigin or not fromExtent or not toOrigin or not toExtent then
        return nil
    end

    local dx = (toOrigin.X or 0) - (fromOrigin.X or 0)
    local dy = (toOrigin.Y or 0) - (fromOrigin.Y or 0)
    local z = to_number_or_nil(funcData.z or funcData.Z) or 0

    if math.abs(dx) >= math.abs(dy) then
        local sign = dx >= 0 and 1 or -1
        local startX = (fromOrigin.X or 0) + sign * math.abs(fromExtent.X or 0)
        local endX = (toOrigin.X or 0) - sign * math.abs(toExtent.X or 0)
        local startY = fromOrigin.Y or 0
        local endY = toOrigin.Y or 0
        if math.abs(startY - endY) < 1 then
            return {
                { x = startX, y = startY, z = z },
                { x = endX, y = endY, z = z }
            }
        end
        return {
            { x = startX, y = startY, z = z },
            { x = endX, y = startY, z = z },
            { x = endX, y = endY, z = z }
        }
    end

    local sign = dy >= 0 and 1 or -1
    local startY = (fromOrigin.Y or 0) + sign * math.abs(fromExtent.Y or 0)
    local endY = (toOrigin.Y or 0) - sign * math.abs(toExtent.Y or 0)
    local startX = fromOrigin.X or 0
    local endX = toOrigin.X or 0
    if math.abs(startX - endX) < 1 then
        return {
            { x = startX, y = startY, z = z },
            { x = endX, y = endY, z = z }
        }
    end
    return {
        { x = startX, y = startY, z = z },
        { x = startX, y = endY, z = z },
        { x = endX, y = endY, z = z }
    }
end

function AICommand:smart_auto_place_margin(actor, funcData)
    local margin = to_number_or_nil(funcData and (funcData.autoPlaceMargin or funcData.margin))
    if margin and margin >= 0 then
        return margin
    end

    local _, boxExtent = self:actor_bounds(actor)
    local maxExtent = 0
    if boxExtent then
        maxExtent = math.max(math.abs(boxExtent.X or 0), math.abs(boxExtent.Y or 0))
    end
    return math.max(600, maxExtent * 0.25)
end

function AICommand:auto_place_candidate_locations(actor, funcData)
    local candidates = {}
    local seen = {}
    local placementRegion = self:placement_region_from_data(funcData)
    local _, actorExtent = self:actor_bounds(actor)
    local function add(location)
        if not location then
            return
        end
        if not self:location_fits_placement_region(location, actorExtent, placementRegion) then
            return
        end
        local key = tostring(math.floor((location.X or 0) * 100)) .. "," ..
            tostring(math.floor((location.Y or 0) * 100)) .. "," ..
            tostring(math.floor((location.Z or 0) * 100))
        if not seen[key] then
            seen[key] = true
            table.insert(candidates, location)
        end
    end

    local explicitLocation = self:auto_place_location_from_data(funcData, actor)
    add(explicitLocation)

    local ok, baseLocation = pcall(actor.K2_GetActorLocation, actor)
    if not ok or not baseLocation then
        baseLocation = UE.FVector(0, 0, 0)
    end
    local base = explicitLocation or baseLocation
    add(base)

    local occupancy = self:scene_spatial_models(actor, true)
    local _, newExtent = self:actor_bounds(actor)
    local newX = newExtent and math.abs(newExtent.X or 0) or 0
    local newY = newExtent and math.abs(newExtent.Y or 0) or 0
    local margin = self:smart_auto_place_margin(actor, funcData or {})
    local candidateRows = {}
    local function queue(location)
        if not location then
            return
        end
        local dx = (location.X or 0) - (base.X or 0)
        local dy = (location.Y or 0) - (base.Y or 0)
        table.insert(candidateRows, {
            location = location,
            distance = dx * dx + dy * dy
        })
    end

    for _, item in ipairs(occupancy) do
        local bounds = item.bounds
        if bounds and bounds.min and bounds.max and bounds.center then
            local minX = bounds.min.x or 0
            local maxX = bounds.max.x or 0
            local minY = bounds.min.y or 0
            local maxY = bounds.max.y or 0
            local centerX = bounds.center.x or ((minX + maxX) / 2)
            local centerY = bounds.center.y or ((minY + maxY) / 2)
            queue(UE.FVector(maxX + newX + margin, centerY, base.Z))
            queue(UE.FVector(minX - newX - margin, centerY, base.Z))
            queue(UE.FVector(centerX, maxY + newY + margin, base.Z))
            queue(UE.FVector(centerX, minY - newY - margin, base.Z))
            queue(UE.FVector(maxX + newX + margin, maxY + newY + margin, base.Z))
            queue(UE.FVector(maxX + newX + margin, minY - newY - margin, base.Z))
            queue(UE.FVector(minX - newX - margin, maxY + newY + margin, base.Z))
            queue(UE.FVector(minX - newX - margin, minY - newY - margin, base.Z))
        end
    end

    local space = self:scene_space_summary(occupancy)
    for _, seed in ipairs(self:placement_region_seed_locations(placementRegion, base.Z, newExtent, margin)) do
        queue(seed)
    end

    if type(space.bounds) == "table" and space.bounds ~= Json.null and space.bounds.min and space.bounds.max then
        local b = space.bounds
        local minX = b.min.x or 0
        local maxX = b.max.x or 0
        local minY = b.min.y or 0
        local maxY = b.max.y or 0
        local centerX = b.center and b.center.x or ((minX + maxX) / 2)
        local centerY = b.center and b.center.y or ((minY + maxY) / 2)
        queue(UE.FVector(maxX + newX + margin, centerY, base.Z))
        queue(UE.FVector(minX - newX - margin, centerY, base.Z))
        queue(UE.FVector(centerX, maxY + newY + margin, base.Z))
        queue(UE.FVector(centerX, minY - newY - margin, base.Z))
    elseif not explicitLocation then
        local spacing = self:auto_place_spacing(actor, funcData or {})
        local offsets = {
            { 0, 0 },
            { 1, 0 },
            { -1, 0 },
            { 0, 1 },
            { 0, -1 }
        }
        for _, offset in ipairs(offsets) do
            queue(UE.FVector(base.X + offset[1] * spacing, base.Y + offset[2] * spacing, base.Z))
        end
    end

    table.sort(candidateRows, function(a, b)
        return a.distance < b.distance
    end)

    for _, row in ipairs(candidateRows) do
        add(row.location)
    end

    return candidates
end

function AICommand:set_build_feedback(actor, canPlace, overlap)
    if self.control then
        self.control.bBlock = canPlace == true
    end

    if not self.control or not actor_valid(actor) then
        return
    end

    local hasOverlap = overlap and overlap ~= Json.null and overlap.hasOverlap == true
    if actor.modelType == 10 and actor.UpdateCollisionStatus then
        pcall(actor.UpdateCollisionStatus, actor, hasOverlap)
        return
    end

    local bpm = self.control.modelManage and self.control.modelManage.BPM
    if bpm and bpm.SetCreateM then
        local color = canPlace and UE.FLinearColor(0, 1, 0, 0) or UE.FLinearColor(1, 0, 0, 0)
        pcall(bpm.SetCreateM, bpm, actor, color, actor.bBuildRotate)
    end
end

function AICommand:try_sequence_explicit_location(actor, funcData)
    if not self:is_sequence_layout(funcData) then
        return nil
    end

    local location = self:auto_place_location_from_data(funcData, actor)
    if not location then
        return nil
    end

    local _, actorExtent = self:actor_bounds(actor)
    local placementRegion = self:placement_region_from_data(funcData)
    if not self:location_fits_placement_region(location, actorExtent, placementRegion) then
        local adjusted = self:clamp_location_to_placement_region(
            location,
            actorExtent,
            placementRegion,
            self:smart_auto_place_margin(actor, funcData or {})
        )
        if adjusted then
            location = adjusted
        else
            self:set_build_feedback(actor, false, Json.null)
            return {
                ok = true,
                buildMode = self.control and self.control.bBuild == true,
                canPlace = false,
                blocked = true,
                blockedReason = "noSpaceInRegion",
                actor = self:actor_reference(actor),
                overlap = Json.null,
                placementRegion = placementRegion or Json.null,
                autoLocation = {
                    x = location.X,
                    y = location.Y,
                    z = location.Z
                },
                message = "sequence location is outside the requested region"
            }
        end
    end

    local hit = UE.FHitResult()
    local okSet = pcall(actor.K2_SetActorLocation, actor, location, false, hit, false)
    if not okSet then
        return nil
    end

    local overlap = self:detect_actor_overlap(actor, funcData)
    local canPlace = overlap and overlap.ok == true and overlap.hasOverlap ~= true
    if canPlace and self.control and self.control.drawMode and self.control.IsActorInsideCurrentRegion then
        local modeText = tostring(self.control.drawMode)
        if string.find(modeText, "RegionInner", 1, true) then
            local okInside, inside = pcall(self.control.IsActorInsideCurrentRegion, self.control, actor)
            canPlace = okInside and inside == true
        end
    end

    self:set_build_feedback(actor, canPlace, overlap)
    local lockSequenceCrossAxis = funcData.lockSequenceCrossAxis == true or funcData.strictSequenceLine == true
    if not lockSequenceCrossAxis and not canPlace and overlap and overlap.ok == true and overlap.hasOverlap == true then
        local fallbackCheck = self:try_sequence_cross_axis_fallback(actor, funcData, location, placementRegion)
        if fallbackCheck then
            return fallbackCheck
        end
    end

    return {
        ok = true,
        buildMode = self.control and self.control.bBuild == true,
        canPlace = canPlace,
        blocked = canPlace ~= true,
        blockedReason = canPlace and Json.null or (overlap and overlap.hasOverlap == true and "overlap" or "invalidPlacementPoint"),
        actor = self:actor_reference(actor),
        overlap = overlap or Json.null,
        placementRegion = placementRegion or Json.null,
        autoLocation = {
            x = location.X,
            y = location.Y,
            z = location.Z
        },
        sequenceLocked = true
    }
end

function AICommand:try_auto_place_candidates(actor, funcData)
    local sequenceCheck = self:try_sequence_explicit_location(actor, funcData)
    if sequenceCheck then
        return sequenceCheck
    end

    local candidates = self:auto_place_candidate_locations(actor, funcData)
    local placementRegion = self:placement_region_from_data(funcData)
    if #candidates == 0 then
        if placementRegion then
            self:set_build_feedback(actor, false, Json.null)
            return {
                ok = true,
                buildMode = self.control and self.control.bBuild == true,
                canPlace = false,
                blocked = true,
                blockedReason = "noSpaceInRegion",
                actor = self:actor_reference(actor),
                overlap = Json.null,
                placementRegion = placementRegion,
                message = "no valid placement point inside the requested region"
            }
        end
        return nil
    end

    local lastCheck = nil
    for _, location in ipairs(candidates) do
        local hit = UE.FHitResult()
        local okSet = pcall(actor.K2_SetActorLocation, actor, location, false, hit, false)
        if okSet then
            local overlap = self:detect_actor_overlap(actor, funcData)
            local canPlace = overlap and overlap.ok == true and overlap.hasOverlap ~= true

            if canPlace and self.control and self.control.drawMode and self.control.IsActorInsideCurrentRegion then
                local modeText = tostring(self.control.drawMode)
                if string.find(modeText, "RegionInner", 1, true) then
                    local okInside, inside = pcall(self.control.IsActorInsideCurrentRegion, self.control, actor)
                    canPlace = okInside and inside == true
                end
            end

            self:set_build_feedback(actor, canPlace, overlap)
            lastCheck = {
                ok = true,
                buildMode = self.control and self.control.bBuild == true,
                canPlace = canPlace,
                blocked = canPlace ~= true,
                blockedReason = canPlace and Json.null or (overlap and overlap.hasOverlap == true and "overlap" or "invalidPlacementPoint"),
                actor = self:actor_reference(actor),
                overlap = overlap or Json.null,
                placementRegion = placementRegion or Json.null,
                autoLocation = {
                    x = location.X,
                    y = location.Y,
                    z = location.Z
                }
            }

            if canPlace then
                return lastCheck
            end
        end
    end

    return lastCheck
end

function AICommand:auto_place_after_draw(funcData)
    if not funcData or funcData.autoPlace == false then
        return {
            ok = true,
            skipped = true,
            message = "autoPlace disabled"
        }
    end

    local modelCode = funcData.modelCode or (self.control and self.control.modelCode)
    if DIRECT_POINT_MODEL_CODES[modelCode] and funcData.connectRole == "between_models" then
        return self:auto_place_direct_point_model(funcData)
    end

    if funcData.points or funcData.splinePoints or funcData.PointLocations then
        return self:auto_place_direct_point_model(funcData)
    end

    if not self.control then
        return {
            ok = false,
            message = "control not ready for autoPlace"
        }
    end

    local actor = self.control.buildActor
    if not actor_valid(actor) then
        local createError = self.control.lastCreateModelError
        if type(createError) == "table" then
            return {
                ok = false,
                code = createError.code or Json.null,
                modelCode = createError.modelCode or (funcData and funcData.modelCode) or Json.null,
                showName = createError.showName or (funcData and funcData.showName) or Json.null,
                currentFloor = createError.currentFloor or Json.null,
                message = createError.message or "DrawModel did not create buildActor"
            }
        end
        if self.control.clickType and self.control.clickType ~= 1 then
            return {
                ok = true,
                skipped = true,
                clickType = self.control.clickType,
                message = "clickType=2 models require points/splinePoints for AI direct creation"
            }
        end
        return {
            ok = false,
            message = "DrawModel did not create buildActor"
        }
    end

    if self.control.bBuild ~= true then
        return {
            ok = true,
            skipped = true,
            actorId = Model.GetActorAccurateDisplayName(actor),
            message = "buildActor already placed"
        }
    end

    if self.control.clickType ~= 1 then
        return {
            ok = true,
            skipped = true,
            clickType = self.control.clickType or Json.null,
            actorId = Model.GetActorAccurateDisplayName(actor),
            message = "autoPlace only supports clickType=1 models"
        }
    end

    if self.control.RemoveTip then
        pcall(self.control.RemoveTip, self.control)
    end
    if self.control.MoveActor then
        pcall(self.control.MoveActor, self.control)
    end

    local placementCheck = self:try_auto_place_candidates(actor, funcData)
    if not placementCheck then
        placementCheck = self:placement_check(actor)
    end

    if self.control.bBlock ~= true then
        local blockedReason = "invalidPlacementPoint"
        local message = "current mouse ray is not a valid placement point"
        if placementCheck and placementCheck.blockedReason and placementCheck.blockedReason ~= Json.null then
            blockedReason = placementCheck.blockedReason
            if blockedReason == "noSpaceInRegion" then
                message = "no valid placement point inside the requested region"
            end
        end
        if placementCheck
            and placementCheck.overlap
            and placementCheck.overlap ~= Json.null
            and placementCheck.overlap.ok == true
            and placementCheck.overlap.hasOverlap == true then
            blockedReason = "overlap"
            message = "placement overlaps existing model"
        end

        return {
            ok = false,
            buildMode = self.control.bBuild == true,
            actorId = Model.GetActorAccurateDisplayName(actor),
            placementBlocked = true,
            blockedReason = blockedReason,
            overlap = placementCheck and placementCheck.overlap or Json.null,
            placementCheck = placementCheck or Json.null,
            message = message
        }
    end

    local ok, err = pcall(self.control.StopMove, self.control)
    if not ok then
        return {
            ok = false,
            buildMode = self.control.bBuild == true,
            actorId = Model.GetActorAccurateDisplayName(actor),
            message = encode_error(err)
        }
    end

    self:remember_sequence_actor(funcData, actor)

    local clearResult = nil
    if funcData.autoClearSelect ~= false then
        clearResult = self:clear_selection_after_auto_place()
    end

    print("AIAutoPlace", Model.GetActorAccurateDisplayName(actor))
    return {
        ok = self.control.bBuild ~= true,
        buildMode = self.control.bBuild == true,
        actorId = Model.GetActorAccurateDisplayName(actor),
        placementCheck = placementCheck or Json.null,
        clearSelect = clearResult or Json.null
    }
end

function AICommand:auto_place_area_after_draw_place(funcData)
    funcData = funcData or {}
    funcData.modelCode = funcData.modelCode or "Area"
    funcData.showName = funcData.showName or funcData.showname or "地板"
    funcData.autoPlace = true

    local region = self:placement_region_from_data(funcData)
    local source = type(funcData.placementRegion) == "table" and funcData.placementRegion.source or nil
    if source == "autoFloor" and funcData.allowDuplicateFloor ~= true then
        local existingFloor = self:find_existing_floor()
        if existingFloor then
            local points = nil
            local pointError = nil
            if funcData.points or funcData.splinePoints or funcData.PointLocations then
                points, pointError = self:parse_direct_points(funcData, 3)
            else
                points = self:area_points_from_region(funcData)
                if not points then
                    pointError = "Area direct creation requires at least three points or a placementRegion"
                end
            end
            if not points then
                return {
                    ok = false,
                    modelCode = "Area",
                    placementRegion = region or Json.null,
                    message = pointError
                }
            end
            return self:update_existing_floor_area(existingFloor, points, funcData, region)
        end
    end

    if not (funcData.points or funcData.splinePoints or funcData.PointLocations or region) then
        return {
            ok = true,
            skipped = true,
            modelCode = "Area",
            message = "DrawPlace entered interactive area drawing mode; provide at least three points or placementRegion for AI direct creation"
        }
    end

    return self:auto_place_direct_point_model(funcData)
end

function AICommand:parse_direct_points(funcData, minCount)
    minCount = minCount or 2
    local rawPoints = funcData.points or funcData.splinePoints or funcData.PointLocations
    if type(rawPoints) ~= "table" or table_count(rawPoints) < minCount then
        return nil, "direct point creation requires at least " .. tostring(minCount) .. " points"
    end

    local points = {}
    for index, point in ipairs(rawPoints) do
        local x = point_axis(point, "x", "X", 1)
        local y = point_axis(point, "y", "Y", 2)
        local z = point_axis(point, "z", "Z", 3)
        if is_null(z) then
            z = 0
        end
        if is_null(x) or is_null(y) then
            return nil, "point[" .. tostring(index) .. "] requires x and y"
        end
        table.insert(points, UE.FVector(x, y, z))
    end
    local modelCode = tostring(funcData.modelCode or funcData.ModelCode or "")
    if modelCode == "Area" then
        points = normalize_area_points(points)
    end
    return points
end

function AICommand:read_direct_option(funcData, key, defaultValue)
    local value = funcData[key]
    if is_null(value) and type(funcData.defaults) == "table" then
        value = funcData.defaults[key]
    end
    if is_null(value) then
        return defaultValue
    end
    local numberValue = tonumber(value)
    if numberValue ~= nil then
        return numberValue
    end
    return value
end

function AICommand:apply_direct_point_defaults(actor, funcData)
    if not actor then
        return
    end

    if actor.modelType == 14 then
        actor.frameWidth = self:read_direct_option(funcData, "FrameWidth", actor.frameWidth or 10)
        actor.passageWidth = self:read_direct_option(funcData, "PassageWidth", actor.passageWidth or 80)
        actor.length = self:read_direct_option(funcData, "Length", actor.length or 500)
        actor.width = actor.frameWidth * 2 + actor.passageWidth
        actor.passageType = self:read_direct_option(funcData, "passageType", actor.passageType or 1)
        actor.passageTexture = self:read_direct_option(funcData, "passageTexture", actor.passageTexture or 0)
    elseif actor.modelType == 7 then
        actor.radius = self:read_direct_option(funcData, "r", actor.radius or 20)
        actor.zzinterval = self:read_direct_option(funcData, "sillPillarInterval", actor.zzinterval or 200)
        actor.ssdWitch = self:read_direct_option(funcData, "ssdWidth", actor.ssdWitch or 50)
        local sillPillarLength = self:read_direct_option(funcData, "sillPillarLength", actor.zzSize and actor.zzSize.X or 4)
        local sillPillarWidth = self:read_direct_option(funcData, "sillPillarWidth", actor.zzSize and actor.zzSize.Y or 4)
        actor.zzSize = UE.FVector2D(sillPillarLength, sillPillarWidth)
        actor.ssdType = self:read_direct_option(funcData, "type", actor.ssdType or 1)
    elseif actor.modelType == 6 then
        actor.thickness = self:read_direct_option(funcData, "thickness", actor.thickness or 20)
        actor.materialCode = self:read_direct_option(funcData, "materialCode", actor.materialCode or "l1")
        actor.cp = self:read_direct_option(funcData, "cp", actor.cp or 1)
    end
end

function AICommand:auto_place_direct_point_model(funcData)
    if not self.control or not self.control.modelManage then
        return {
            ok = false,
            message = "control or modelManage not ready for direct point creation"
        }
    end

    local modelCode = funcData.modelCode or self.control.modelCode
    if not DIRECT_POINT_MODEL_CODES[modelCode] then
        return {
            ok = false,
            modelCode = modelCode or Json.null,
            message = "direct point creation currently supports Passage, diyssx and Area only"
        }
    end

    local connectionPoints = self:boundary_connection_points(funcData)
    if connectionPoints then
        funcData.points = connectionPoints
    elseif funcData.connectRole == "between_models" then
        return {
            ok = false,
            modelCode = modelCode,
            message = "bounds connector could not resolve source/target sequence actors"
        }
    end

    local minPointCount = modelCode == "Area" and 3 or 2
    local points = nil
    local pointError = nil
    if modelCode == "Area" and not (funcData.points or funcData.splinePoints or funcData.PointLocations) then
        points = self:area_points_from_region(funcData)
        if not points then
            pointError = "Area direct creation requires at least three points or a placementRegion"
        end
    else
        points, pointError = self:parse_direct_points(funcData, minPointCount)
    end
    if not points then
        return {
            ok = false,
            modelCode = modelCode,
            message = pointError
        }
    end

    local meshLoad = self.control.MeshLoad
    local modelType = meshLoad and meshLoad.MType
    if modelCode == "Area" and not modelType then
        modelType = 6
    end
    if not modelType then
        return {
            ok = false,
            modelCode = modelCode,
            message = "DrawModel did not prepare MeshLoad for direct point creation"
        }
    end

    if self.control.Timer then
        pcall(UE.UKismetSystemLibrary.K2_ClearAndInvalidateTimerHandle, self.control:GetWorld(), self.control.Timer)
    end

    local createHandler = self.control.modelManage.ModelCreate[modelType]
    if not createHandler then
        return {
            ok = false,
            modelCode = modelCode,
            modelType = modelType or Json.null,
            message = "direct point ModelCreate handler not found"
        }
    end

    local name = self.control:NameCheck(modelCode)
    local showName = self.control:ShowNameCheck(funcData.showName or self.control.showName or modelCode)
    local actor = createHandler(
        name,
        self.control,
        nil,
        nil,
        showName,
        self.control.ModelCategory or funcData.modelCategoryCode
    )
    if not actor_valid(actor) then
        return {
            ok = false,
            modelCode = modelCode,
            message = "failed to create direct point actor"
        }
    end

    actor.simplePoints:Clear()
    for _, point in ipairs(points) do
        actor.simplePoints:Add(point)
    end
    self:apply_direct_point_defaults(actor, funcData)
    actor:SetSplineModel()
    if actor.modelType == 14 and actor.SetM then
        local colorA = UE.FLinearColor(
            self:read_direct_option(funcData, "ra", 255) / 255,
            self:read_direct_option(funcData, "ga", 255) / 255,
            self:read_direct_option(funcData, "ba", 255) / 255,
            1
        )
        local colorB = UE.FLinearColor(
            self:read_direct_option(funcData, "rb", 26) / 255,
            self:read_direct_option(funcData, "gb", 26) / 255,
            self:read_direct_option(funcData, "bb", 26) / 255,
            1
        )
        actor:SetM(actor.passageType, actor.passageTexture, colorA, colorB)
    end

    self.control.buildActor = actor
    self.control.bBuild = false
    self.control.bBlock = nil
    self.control.bRec = false
    self.control.clickType = 1
    self:remember_sequence_actor(funcData, actor)

    if self.control.drawMode == "RegionInner" and self.control.IsActorInsideCurrentRegion
        and not self.control:IsActorInsideCurrentRegion(actor) then
        self.control.modelManage.ModelDelete[actor.modelType](actor, self.control)
        self.control.buildActor = nil
        return {
            ok = false,
            modelCode = modelCode,
            message = "direct point model is outside the selected region"
        }
    end

    self.control.modelManage:BuildPoint(actor.simplePoints)
    self.control.modelManage.ModelSelect[actor.modelType](actor, self.control)
    if self.control and actor.modelType == 6 and self.control.FloorDataToView then
        pcall(self.control.FloorDataToView, self.control)
    end
    if self.control and self.control.ModelDataToView then
        if not self.control.buildActor then
            self.control.buildActor = actor
        end
        pcall(self.control.ModelDataToView, self.control)
    end
    if self.control.undo then
        self.control.undo:AddAction(1, actor)
    end

    local clearResult = nil
    if funcData.autoClearSelect ~= false then
        clearResult = self:clear_selection_after_auto_place()
    end

    print("AIAutoDirectPoint", Model.GetActorAccurateDisplayName(actor))
    return {
        ok = true,
        modelCode = modelCode,
        actorId = Model.GetActorAccurateDisplayName(actor),
        pointCount = #points,
        clearSelect = clearResult or Json.null
    }
end

function AICommand:clear_selection_after_auto_place()
    if not self.control or not self.control.modelManage then
        return {
            ok = false,
            message = "control or modelManage not ready for clearSelect"
        }
    end

    local okClear, errClear = pcall(self.control.modelManage.ModelClear, self.control.modelManage, self.control)
    if not okClear then
        return {
            ok = false,
            message = encode_error(errClear)
        }
    end

    if self.control.ShowSel then
        pcall(self.control.ShowSel, self.control)
    end

    return {
        ok = not actor_valid(self.control.buildActor)
    }
end

function AICommand:selected_actor()
    if not self.control or not actor_valid(self.control.buildActor) then
        return nil
    end
    local actor = self.control.buildActor
    local parent = nil
    if actor.modelType ~= "Group" and actor.modelType ~= "Multi" then
        local ok, p = pcall(actor.GetAttachParentActor, actor)
        if ok and actor_valid(p) then
            parent = p
        end
    end
    local controlId = parent and Model.GetActorAccurateDisplayName(parent) or Model.GetActorAccurateDisplayName(actor)
    return {
        controlId = controlId,
        actorId = Model.GetActorAccurateDisplayName(actor),
        showName = actor.showName or (parent and parent.showName) or Json.null,
        modelCode = actor.modelCode or Json.null,
        modelType = actor.modelType or Json.null,
        transform = transform_to_table(actor) or Json.null
    }
end

function AICommand:GetSceneState(data)
    data = data or {}
    local state = {
        ok = true,
        tree = {},
        modelNum = 0,
        selected = Json.null,
        buildMode = false,
        drawMode = Json.null,
        assetCount = 0,
        models = {},
        space = Json.null
    }

    if not self.control or not self.control.modelManage then
        state.ok = false
        state.message = "control or modelManage not ready"
        return state
    end

    if data.refreshTree ~= false and self.control.TreeDataOut then
        pcall(self.control.TreeDataOut, self.control)
    end

    state.tree = self.control.treeT or {}
    state.buildMode = self.control.bBuild == true
    state.drawMode = self.control.drawMode or Json.null

    local okNum, modelNum = pcall(self.control.modelManage.GetModelNum, self.control.modelManage)
    if okNum then
        state.modelNum = modelNum
    end

    if self.control.modelManage.MeshDatas and self.control.modelManage.MeshDatas.Num then
        local okAsset, assetCount = pcall(self.control.modelManage.MeshDatas.Num, self.control.modelManage.MeshDatas)
        if okAsset then
            state.assetCount = assetCount
        end
    end

    if data.includeModels ~= false then
        local models = self:scene_spatial_models(nil, false)
        local limit = tonumber(data.modelLimit)
        if limit and limit > 0 and #models > limit then
            state.models = {}
            for i = 1, limit do
                state.models[i] = models[i]
            end
            state.modelLimit = limit
            state.modelTotal = #models
        else
            state.models = models
            state.modelTotal = #models
        end
        state.space = self:scene_space_summary(models)
    end

    local selected = self:selected_actor()
    if selected then
        state.selected = selected
    end

    if self.control.bBuild == true and actor_valid(self.control.buildActor) then
        local placementCheck = self:placement_check(self.control.buildActor)
        if placementCheck then
            state.placementCheck = placementCheck
        end
    end

    if data.includeSnapshot == true and self.control.SaveData then
        local ok, snapshot = pcall(
            self.control.SaveData,
            self.control,
            data.planName or self.ui.planName or "",
            data.planId or self.ui.planId,
            data.userId or self.ui.userId or ""
        )
        if ok then
            state.snapshot = snapshot
        else
            state.snapshotError = encode_error(snapshot)
        end
    end

    return state
end

function AICommand:Execute(data)
    data = data or {}
    local commands, missing = self:normalize_commands(data)
    if not commands then
        return {
            ok = false,
            message = "invalid AI command",
            missing = missing
        }
    end
    self.sequenceLayoutActors = {}
    local suppressSceneDelta = data.suppressSceneDelta == true
    local previousSuppressSceneDelta = nil
    local previousSuppressedSceneDeltaCount = nil
    if self.ui and suppressSceneDelta then
        previousSuppressSceneDelta = self.ui._aiSuppressSceneDelta
        previousSuppressedSceneDeltaCount = self.ui._aiSuppressedSceneDeltaCount
        self.ui._aiSuppressSceneDelta = true
        self.ui._aiSuppressedSceneDeltaCount = 0
        self.ui._aiSuppressedSceneDeltaKind = nil
    end

    local response = {
        ok = true,
        dryRun = data.dryRun == true,
        results = {},
        commands = commands,
        meta = data.meta or Json.null
    }

    local drawCount = 0
    for _, command in ipairs(commands) do
        if command.funcName == "DrawModel" then
            drawCount = drawCount + 1
        end
    end

    local drawIndex = 0
    for _, command in ipairs(commands) do
        if command.funcName == "DrawModel" then
            drawIndex = drawIndex + 1
            command.funcData = command.funcData or {}
            if is_null(command.funcData.aiSequenceDrawIndex) then
                command.funcData.aiSequenceDrawIndex = drawIndex
            end
            if is_null(command.funcData.aiSequenceCount) then
                command.funcData.aiSequenceCount = drawCount
            end
            if drawCount > 1 and is_null(command.funcData.autoPlaceStrategy) then
                command.funcData.autoPlaceStrategy = "smart"
            end
        end
        local okExecute, result = pcall(self.execute_one, self, command, data)
        if not okExecute then
            result = {
                ok = false,
                funcName = command.funcName,
                message = encode_error(result)
            }
        end
        table.insert(response.results, result)
        if not result.ok then
            response.ok = false
            response.message = result.message
            break
        end
    end

    if response.ok and data.autoFitFloor == true then
        local okFit, floorFit = pcall(self.auto_fit_existing_floor_after_execute, self, data)
        if okFit then
            response.floorFit = floorFit or Json.null
        else
            response.floorFit = {
                ok = false,
                message = encode_error(floorFit)
            }
        end
    end

    if self.ui and suppressSceneDelta then
        response.suppressedSceneDeltaCount = self.ui._aiSuppressedSceneDeltaCount or 0
        response.suppressedSceneDeltaLastKind = self.ui._aiSuppressedSceneDeltaKind or Json.null
        self.ui._aiSuppressSceneDelta = previousSuppressSceneDelta
        self.ui._aiSuppressedSceneDeltaCount = previousSuppressedSceneDeltaCount
        self.ui._aiSuppressedSceneDeltaKind = nil
    end

    if data.returnState ~= false then
        response.sceneState = self:GetSceneState({
            refreshTree = data.refreshTree,
            includeSnapshot = data.includeSnapshot,
            planName = data.planName,
            planId = data.planId,
            userId = data.userId
        })
    end

    if response.ok and self.ui and data.silent ~= true and data.pushState ~= false and response.sceneState then
        if self.ui.UECallAIWeb then
            self.ui:UECallAIWeb("AISceneState", response.sceneState)
        elseif self.ui.UECallWeb then
            self.ui:UECallWeb("AISceneState", response.sceneState)
        end
    end

    return response
end

return AICommand
