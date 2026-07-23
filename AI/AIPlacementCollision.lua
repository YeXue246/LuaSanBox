local Json = require("dkjson")

local M = {}

local NON_OCCUPANCY_TYPES = { [1] = true, [6] = true }

local SEQUENCE_NON_BLOCKING_TYPES = { [7] = true, [14] = true }

local function is_null(value)
    return value == nil or value == Json.null
end

local function is_empty(value)
    return is_null(value) or value == ""
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
    if actor.IsValid then
        local ok, valid = pcall(actor.IsValid, actor)
        if ok then
            return valid
        end
    end
    return true
end

local function to_number_or_nil(value)
    if is_null(value) then
        return nil
    end
    return tonumber(value)
end

local function vector_to_table(value)
    if not value then
        return Json.null
    end
    return { x = value.X, y = value.Y, z = value.Z }
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

local function reference_from_context(context, actor)
    if context and context.actor_reference then
        local ok, ref = pcall(context.actor_reference, context, actor)
        if ok then
            return ref
        end
    end

    local actorId = Json.null
    if UE and UE.UKismetSystemLibrary and UE.UKismetSystemLibrary.GetObjectName then
        local okName, name = pcall(UE.UKismetSystemLibrary.GetObjectName, actor)
        if okName then
            actorId = name
        end
    end
    return {
        controlId = actorId,
        actorId = actorId,
        showName = actor and actor.showName or Json.null,
        modelCode = actor and actor.modelCode or Json.null,
        modelType = actor and actor.modelType or Json.null
    }
end

local function is_sequence_layout(funcData)
    if type(funcData) ~= "table" then
        return false
    end
    return funcData.layoutMode == "productionLine" or funcData.autoPlaceStrategy == "lineSequence"
        or funcData.autoPlaceStrategy == "lineConnector"
end

local function is_blocking_ref(ref, funcData)
    if is_sequence_layout(funcData) then
        local modelType = ref and tonumber(ref.modelType)
        local modelCode = ref and tostring(ref.modelCode or "") or ""
        local showName = ref and tostring(ref.showName or "") or ""
        if SEQUENCE_NON_BLOCKING_TYPES[modelType] or modelCode == "diyssx" or modelCode == "Passage"
            or string.find(showName, "输送线", 1, true) or string.find(showName, "通道", 1, true) then
            return false
        end
    end
    return true
end

local function add_overlap(overlaps, seen, ref, source, funcData)
    if type(ref) ~= "table" then
        return
    end

    if not is_blocking_ref(ref, funcData) then
        return
    end

    local actorId = ref.actorId
    local controlId = ref.controlId
    local sourceActorId = type(source) == "table" and source.actorId or nil
    local sourceControlId = type(source) == "table" and source.controlId or nil
    local sameActor = not is_empty(actorId) and actorId == sourceActorId
    local sameControl = not is_empty(controlId) and controlId == sourceControlId

    if sameActor or sameControl then
        return
    end

    local key = not is_empty(controlId) and controlId or actorId
    if is_empty(key) then
        key = tostring(#overlaps + 1)
    end
    if seen[key] then
        return
    end

    seen[key] = true
    table.insert(overlaps, ref)
end

function M.IsPlacementOccupancy(actor)
    return actor_valid(actor) and type(actor.modelType) == "number" and NON_OCCUPANCY_TYPES[actor.modelType] ~= true
end

function M.OverlapPadding(funcData)
    local padding = to_number_or_nil(
        funcData and (funcData.overlapPadding or funcData.collisionPadding or funcData.minClearance)
    )
    if padding and padding >= 0 then
        return padding
    end
    padding = to_number_or_nil(funcData and (funcData.autoPlaceMargin or funcData.margin))
    if padding and padding >= 0 then
        return padding
    end
    return 600
end

function M.BoundsOverlapXY(a, b, padding)
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

function M.ActorBounds(context, actor)
    if context and context.actor_bounds then
        local ok, origin, boxExtent, err = pcall(context.actor_bounds, context, actor)
        if ok then
            return origin, boxExtent, err
        end
    end
    if actor_valid(actor) and actor.GetActorBounds then
        local ok, origin, boxExtent = pcall(actor.GetActorBounds, actor, false)
        if ok then
            return origin, boxExtent
        end
    end
    return nil, nil, "actor bounds unavailable"
end

function M.EngineTraceOtherModel(actor)
    if not actor_valid(actor) or not actor.TraceOtherModel then
        return { ok = true, hasOverlap = false, skipped = true, reason = "TraceOtherModel unavailable" }
    end

    local ok, result = pcall(actor.TraceOtherModel, actor, true)
    if not ok then
        return { ok = false, hasOverlap = false, message = tostring(result) }
    end

    return { ok = true, hasOverlap = result == true }
end

function M.BoxOverlapActors(context, actor, origin, boxExtent, source, overlaps, seen, funcData)
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
        UE.UKismetSystemLibrary.BoxOverlapActors, actor:GetWorld(), origin, boxExtent, objectTypes, UE.AStaticMeshActor,
        actorsToIgnore, hitActors
    )

    if not okOverlap then
        return { ok = false, hasOverlap = false, count = 0, rawCount = 0, message = tostring(bTrace) }
    end

    for _, hitActor in pairs(hitActors) do
        if actor_valid(hitActor) then
            add_overlap(overlaps, seen, reference_from_context(context, hitActor), source, funcData)
        end
    end

    return { ok = true, hasOverlap = bTrace == true, rawCount = hitActors:Num() }
end

function M.BoundsOverlap(context, actor, funcData, origin, boxExtent, source, overlaps, seen)
    local sourceBounds = bounds_to_table(origin, boxExtent)
    local padding = M.OverlapPadding(funcData)
    local records = {}

    if context and context.scene_spatial_models then
        local okRecords, value = pcall(context.scene_spatial_models, context, actor, true)
        if okRecords and type(value) == "table" then
            records = value
        end
    end

    for _, item in ipairs(records) do
        local itemType = item and tonumber(item.modelType)
        local isOccupancy = itemType ~= 1 and itemType ~= 6
        local isBlocking = not (is_sequence_layout(funcData) and SEQUENCE_NON_BLOCKING_TYPES[itemType])
        if isOccupancy and isBlocking and item and item.bounds and M.BoundsOverlapXY(sourceBounds, item.bounds, padding) then
            add_overlap(overlaps, seen, {
                controlId = item.controlId or Json.null,
                actorId = item.actorId or Json.null,
                showName = item.showName or Json.null,
                modelCode = item.modelCode or Json.null,
                modelType = item.modelType or Json.null,
                bounds = item.bounds or Json.null
            }, source, funcData
            )
        end
    end

    return { ok = true, hasOverlap = #overlaps > 0, count = #overlaps, sourceBounds = sourceBounds, padding = padding }
end

function M.Detect(context, actor, funcData)
    if not actor_valid(actor) then
        return { ok = false, hasOverlap = false, count = 0, actors = {}, message = "actor invalid" }
    end

    local origin, boxExtent, boundsError = M.ActorBounds(context, actor)
    if not origin or not boxExtent then
        return {
            ok = false,
            hasOverlap = false,
            count = 0,
            actors = {},
            message = boundsError or "actor bounds unavailable"
        }
    end

    local source = reference_from_context(context, actor)
    local overlaps = {}
    local seen = {}

    local engineTrace = M.EngineTraceOtherModel(actor)
    local boxOverlap = M.BoxOverlapActors(context, actor, origin, boxExtent, source, overlaps, seen, funcData)
    local boundsOverlap = M.BoundsOverlap(context, actor, funcData, origin, boxExtent, source, overlaps, seen)
    local hasQualifiedOverlap = #overlaps > 0

    return {
        ok = true,
        hasOverlap = hasQualifiedOverlap,
        count = #overlaps,
        rawCount = boxOverlap.rawCount or 0,
        source = source,
        engineTrace = engineTrace,
        engineTraceOnly = engineTrace.hasOverlap == true and not hasQualifiedOverlap,
        boxOverlap = boxOverlap,
        boundsOverlap = boundsOverlap,
        actors = overlaps
    }
end

return M
