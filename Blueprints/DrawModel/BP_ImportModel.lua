--
-- DESCRIPTION
--
-- @COMPANY **
-- @AUTHOR **
-- @DATE ${date} ${time}
--

---@class BP_ImportModel_C
local M = UnLua.Class()
local Class = require("SandBox.Class")
local DFL = require("SandBox.DataFunction")
local Json = require("dkjson")
local Screen = require("Screen")
local MaterialTemplateData = require("SandBox.MaterialTemplateData")

-- 默认材质参数
local DefaultMaterialParams = {
    BaseColorConstant = { R = 1, G = 1, B = 1 },
    MetallicRation    = 0.100,
    RoughnessRation   = 0.500,
    EmissiveRation    = 0.000,
    NormalRation      = 1.000
}

function M:Initialize(Initializer)
    self.modelType = 10
    self.clickType = 1
    self.modelCode = ""
    self.modelManage = nil
    -- self.showName = ""
    self.path = ""
    self.bMove = true
    self.bLoading = false -- 加载状态标记
    self.MaterialDatas = {}
    self.SaveSourceState = {}
end

function M:ReceiveBeginPlay()
    self.control = UE.UGameplayStatics.GetActorOfClass(self:GetWorld(), LoadClass(Class.control))
    self.ImportFunc = self.control.modelManage.importFunc
end

function M:UpdateCollisionBoxSize()
    if self.CollisionBox then
        if self.size then
            local scale = self.size / 100
            -- print("scale:", scale, "name:", self:GetAttachParentActor().showName,
            -- UE.UKismetSystemLibrary.GetDisplayName(self))
            self.CollisionBox:SetWorldScale3D(scale, false, nil, false)
            -- print("scale:", self.CollisionBox:K2_GetComponentScale(), "name:", self:GetAttachParentActor().showName)
        elseif self.originalSize then
            self.CollisionBox:SetWorldScale3D(self.originalSize / 100, false, nil, false)
        end
        self.CollisionBox:K2_SetRelativeLocation(UE.FVector(0, 0, 0), false, nil, false)
    end
end

function M:UpdateCollisionStatus(bColliding)
    if self.CollisionBox then
        if self.bLoading then
            -- 加载过程中：黄色材质
            local yellowMat = LoadObject("/Game/SandBox/Materials/M_Light_Inst3.M_Light_Inst3")
            self.CollisionBox:SetMaterial(0, yellowMat)
        else
            if bColliding then
                -- 碰撞状态：红色材质
                local redMat = LoadObject("/Game/SandBox/Materials/M_Light_Inst.M_Light_Inst")
                self.CollisionBox:SetMaterial(0, redMat)
            else
                -- 可放置状态：绿色材质
                local greenMat = LoadObject("/Game/SandBox/Materials/M_Light_Inst2.M_Light_Inst2")
                self.CollisionBox:SetMaterial(0, greenMat)
            end
        end
        self.CollisionBox:SetHiddenInGame(false)
    end
end

function M:UpdateLoadingStatus(bLoading)
    self.bLoading = bLoading
    if self.CollisionBox then
        -- 设置盒体可见性
        self.CollisionBox:SetHiddenInGame(false)
        -- 设置盒体材质为黄色
        local yellowMat = LoadObject("/Game/SandBox/Materials/M_Light_Inst3.M_Light_Inst3")
        self.CollisionBox:SetMaterial(0, yellowMat)
    end
end

function M:HideCollisionBox()
    if self.CollisionBox then
        self.CollisionBox:SetHiddenInGame(true)
    end
end

function M:GetModelBounds()
    local origin, boxExtent
    if self.Meshs:Num() == 0 then
        origin, boxExtent = UE.UKismetSystemLibrary.GetComponentBounds(self.PMesh)
    else
        _, origin, boxExtent = UE.UMyBFL.GetComponentsBound(self.Meshs)
    end
    return origin, boxExtent
end

function M:GetBox(bBasic)
    local origin, boxExtent = self:GetModelBounds()

    if boxExtent ~= UE.FVector(0, 0, 0) then
        self.originalSize = boxExtent * 2
        self.size = self.originalSize
    end
    self.bBasic = bBasic
    if self.control then
        self.control:ModelDataToView()
    end
end

-- 数据出
function M:ModelSave()
    if self.size == UE.FVector(0, 0, 0) then
        local origin, boxExtent = self:GetModelBounds()
        self.size = boxExtent * 2
    end
    self:SaveMaterialSourceState()
    local table = {
        ["ModelCode"] = self.modelCode,
        ["OriginalSize"] = UE.UJsonLibraryHelpers.JsonValue_Stringify(
            UE.UJsonLibraryHelpers.FromVector(self.originalSize)),
        ["BSize"] = UE.UJsonLibraryHelpers.JsonValue_Stringify(UE.UJsonLibraryHelpers.FromVector(self.size)),
        ["Path"] = self.path,
        ["CType"] = self.clickType,
        ["Type"] = self.modelType,
        ["Materials"] = self:GetSaveSourceStateAsJson(),
    }
    return table
end

-- 数据进
function M:ModelLoad(table, bUndo)
    local BS          = UE.UJsonLibraryHelpers.ToVector(UE.UJsonLibraryHelpers.Parse(table["BSize"]))
    local OS          = UE.UJsonLibraryHelpers.ToVector(UE.UJsonLibraryHelpers.Parse(table["OriginalSize"]))

    self.modelCode    = table["ModelCode"]
    self.path         = table["Path"]
    self.clickType    = table["CType"] ~= 0 and table["CType"] or self.clickType
    self.modelType    = table["Type"]
    self.size         = BS
    self.originalSize = OS
    self:LoadSaveSourceStateFromJson(table["Materials"])
    if bUndo then
        return
    end
    self:LoadModel()
end

function M:TraceOtherModel()
    local origin, boxExtent = self:GetModelBounds()
    local objectTypes = UE.TArray(UE.EObjectTypeQuery)
    objectTypes:Add(UE.EObjectTypeQuery.WorldStatic)
    local actorsToIgnore = UE.TArray(UE.AActor)
    actorsToIgnore:Add(self)
    local bTrace = UE.UKismetSystemLibrary.BoxOverlapActors(self:GetWorld(), origin, boxExtent,
        objectTypes, UE.AStaticMeshActor, actorsToIgnore, UE.TArray(UE.AActor))
    return bTrace
end

function M:SetData(table)
    print(self.originalSize, "OriginalSize")
    self.size = table.Size
    table.T.Scale3D = table.Size / self.originalSize
    self:K2_SetActorTransform(table.T, false, UE.FHitResult(), false)
    -- self.showName = table.showname
    self:GetAttachParentActor().showName = table.showname

    -- -------------------------------
    -- 2️⃣ 更新材质
    -- -------------------------------

    local jsonData = Json.encode(table.Materials)
    print("SetDataData:::", jsonData)
    if table.Materials then
        for MaterialKey, MaterialInfo in pairs(table.Materials) do
            local TemplateName = MaterialInfo.TemplateName
            local Params       = MaterialInfo.Params or {}

            local Data         = self.MaterialDatas[MaterialKey]
            if not Data then
                -- 如果没有初始化的 MaterialData，先创建一个占位
                Data = {
                    MID = nil,
                    SourceState = {
                        TemplateName = nil,
                        Params = {}
                    },
                    CurrentState = {
                        TemplateName = nil,
                        Params = {}
                    }
                }
                self.MaterialDatas[MaterialKey] = Data
            end

            local ActualTemplateName = TemplateName
            if ActualTemplateName == "NONE" then
                ActualTemplateName = nil
            end

            -- 1️⃣ 应用模板 + 参数到 CurrentState
            if ActualTemplateName or next(Params or {}) then
                local FinalParams = {}

                -- 如果模板存在，先拷贝模板参数
                if ActualTemplateName and MaterialTemplateData[ActualTemplateName] then
                    FinalParams = self:DeepCopy(MaterialTemplateData[ActualTemplateName])
                end

                -- 再覆盖参数列表
                for ParamName, ParamValue in pairs(Params) do
                    FinalParams[ParamName] = self:DeepCopy(ParamValue)
                end

                -- 更新 CurrentState
                Data.CurrentState = {
                    TemplateName = ActualTemplateName,
                    Params = FinalParams
                }
                
                self:CommitMaterial(MaterialKey)
                -- 应用到 MID 显示
                self:ApplyMaterial(MaterialKey)
            end

            -- 2️⃣ 恢复材质到 SourceState（覆盖 CurrentState）
            if MaterialInfo.RestoreMaterial then
                self:RestoreMaterial(MaterialKey)
            end

            -- 3️⃣ 提交 CurrentState 到 SourceState
            if MaterialInfo.CommitMaterial then
                self:CommitMaterial(MaterialKey)
            end
        end
    end
end

function M:GetData(CH)
    local T = self:GetTransform()
    if self.size == nil then
        return {}
    end
    local MDTV = {
        length = DFL.integrate(self.size.X),
        width = DFL.integrate(self.size.Y),
        height = DFL.integrate(self.size.Z),
        -- top = CH - DFL.integrate(self.size.Z),
        angle = DFL.integrate(UE.UKismetMathLibrary.Quat_Rotator(T.Rotation).Yaw),
        x = DFL.integrate(T.Translation.X),
        y = DFL.integrate(T.Translation.Y),
        z = DFL.integrate(T.Translation.Z),
        bBasic = self.bBasic,
        showname = self:GetAttachParentActor().showName,
        bMove = self.bMove,
    }

    self:AppendMaterialInteractionData(MDTV)

    return MDTV
end

function M:LoadModel()
    self:SetActorScale3D(UE.FVector(1, 1, 1))
    if not self.CollisionBox then
        self:CreateCollisionBox() -- 蓝图函数
        -- 设置加载状态
        self:UpdateLoadingStatus(true)
        if self.originalSize then
            self:UpdateCollisionBoxSize()
        end
    end
    -- print("scale1:", self.CollisionBox:K2_GetComponentScale(), "name:", self:GetAttachParentActor().showName)
    self.PMesh:ClearAllMeshSections()
    -- print("scale1.5:", self.CollisionBox:K2_GetComponentScale(), "name:", self:GetAttachParentActor().showName)
    local extension = string.match(self.path, "^.+(%..+)$")
    extension = string.lower(extension)
    local LoadMesh
    if extension == ".zip" then
        local path = UE.UBlueprintPathsLibrary.ProjectDir() .. string.match(self.path, "model/[^%.]+")
        if not UE.UBlueprintPathsLibrary.DirectoryExists(path) then
            print("Zip model directory not exists:", path)
            return
        end
        local modelPath
        local fileType = 0
        for key, value in pairs(DFL.modelType) do
            modelPath = self:FindModelPath(path, key)
            if modelPath then
                fileType = value
                local fullModelPath = path .. "/" .. modelPath
                if UE.UBlueprintPathsLibrary.FileExists(fullModelPath) then
                    self:LoadMeshfFile(fileType, fullModelPath)
                    print(fullModelPath)
                else
                    print("Model file not exists:", fullModelPath)
                end
                break
            end
        end
    else
        local DownModelName = string.match(self.path, "%.-([^\\/]-%.?[^%.\\/]*)$")
        local path = UE.UBlueprintPathsLibrary.ProjectDir() .. "model/" .. DownModelName
        if not UE.UBlueprintPathsLibrary.FileExists(path) then
            print("Model file not exists:", path)
            -- print("scale2:", self.CollisionBox:K2_GetComponentScale(), "name:", self:GetAttachParentActor().showName)
            return
        end
        if extension == ".stp" or extension == ".step" then
            local pathStp = string.sub(path, 0, -(#extension + 1)) .. "Temp.stl"
            if UE.UBlueprintPathsLibrary.FileExists(pathStp) then
                self:LoadMeshfFile(2, pathStp)
                -- LoadMesh = UE.URealTimeImportAsyncNodeLoadMesh.LoadMeshFileAsyncNode(
                --     2, 1, Path, 1, true, true, true)
                goto continue
            end
        end
        local fileType = DFL.modelType[extension]
        -- if extension == ".fbx" and UE.UMyBFL.GetExeURL("Mode") == "testImport" then
        if extension == ".fbx" then
            -- self:LoadNewFBX(path)

            self.ImportFunc:LoadNewFBX(path, self)
            -- local L = self:K2_GetActorLocation()
            -- local actors = UE.TArray(UE.AActor)
            -- actors:Add(self)
            -- local bHaveBox, O, B = UE.UMyBFL.GetComponentsBound(self.Meshs)
            -- if bHaveBox then
            --     local Location = -O + UE.FVector(0, 0, B.Z)
            --     self.PMesh:K2_SetWorldLocation(Location, false, nil, false)
            --     if not self.OriginalSize then
            --         self:GetBox(self.bBasic)
            --     end
            -- end
            -- return
        else
            local fileType = DFL.modelType[extension]
            if fileType then
                self:LoadMeshfFile(fileType, path)
            else
                print("Invalid file type:", extension)
            end
        end
        -- LoadMesh = UE.URealTimeImportAsyncNodeLoadMesh.LoadMeshFileAsyncNode(
        --     FileType, 1, Path, 1, true, true, true)
    end
    ::continue::
    -- if LoadMesh then
    --     LoadMesh.OnSuccess:Add(self, self.LoadSuccess)
    --     LoadMesh.OnFail:Add(self, self.LoadFail)
    --     LoadMesh:Activate()
    -- else
    --     print("无模型")
    -- end
end

function M:FindModelPath(Path, str)
    local filepaths = UE.UMyBFL.GetFolderFiles(Path)
    for key, file in pairs(filepaths) do
        if file:find(str) then
            print(file)
            return file
        end
    end
end

function M:LoadSuccess(modelStructs, errorMessage)
    for k, val in pairs(modelStructs) do
        for index, value in pairs(val.meshStructs) do
            local MaterialStruct = value.materialData
            local i = index - 1
            self.PMesh:CreateMeshSection(i, value.vertices, value.triangles, value.normals, value.UV0, nil, nil, true)
            if not MaterialStruct.isEmpty and MaterialStruct.textures:Num() > 0 then
                local DMI = self.PMesh:CreateDynamicMaterialInstance(i, self.MTex, nil)
                for key, Texval in pairs(MaterialStruct.textures) do
                    local tex = self:GetTexture(Texval)
                    if tex then
                        if Texval.textureType == UE.ERTITextureType.E_Kd then
                            DMI:SetTextureParameterValue("Diffuse", tex)
                        elseif Texval.textureType == UE.ERTITextureType.E_bump or Texval.textureType == UE.ERTITextureType.E_norm then
                            DMI:SetTextureParameterValue("Normal", tex)
                        end
                    end
                end
            else
                local DMI = self.PMesh:CreateDynamicMaterialInstance(i, self.MRGB, nil)
                DMI:SetVectorParameterValue("Diffuse",
                    UE.UKismetMathLibrary.Conv_ColorToLinearColor(MaterialStruct.diffuse))
            end
        end
    end
    self:GetModelSize()
end

function M:GetModelSize()
    -- 加载完成，更新状态
    self.bLoading = false

    local L = self.PMesh:K2_GetComponentLocation()
    local bGet, O, B
    if self.Meshs:Num() > 0 then
        bGet, O, B = UE.UMyBFL.GetComponentsBound(self.Meshs)
    else
        O, B = UE.UKismetSystemLibrary.GetComponentBounds(self.PMesh)
    end
    local Location = L - O + UE.FVector(0, 0, B.Z)
    self.PMesh:K2_SetRelativeLocation(Location, false, nil, false)
    -- print("O:", O, "B:", B)
    if (not self.control.bBuild or self.control.clickType == "Array") and self.size then
        self:HideCollisionBox()
        local scale = self.size / self.originalSize
        self.CollisionBox:SetWorldScale3D(self.originalSize / 100)
        self:SetActorScale3D(scale)
    else
        self:GetBox(self.bBasic)
        if self.control.bBuild then
            self:UpdateCollisionBoxSize()
            self:UpdateCollisionStatus(false)
        end
    end

    self:InitMaterialDatas()
end

function M:LoadFail(modelStructs, errorMessage)
    -- 加载失败，更新状态
    self.bLoading = false
    print(errorMessage, 3333333333)
    -- 隐藏碰撞盒
    self:HideCollisionBox()
end

function M:ReceiveEndPlay()
    -- 取消当前模型的异步生成任务
    if self.ImportFunc then
        self.ImportFunc:CancelImportForActor(self)
    end
end

-- 初始化材质数据
function M:InitMaterialDatas()
    self.MaterialDatas = {}
    self.totalMats = 0
    print("[InitMaterialDatas] Warning: InitMaterialDatas StartStart!")
    if not self.PMesh and (not self.Meshs or self.Meshs:Num() == 0) then
        print("[InitMaterialDatas] Warning: No mesh component found!")
        return
    end

    -- 收集组件
    local Components = {}
    if self.Meshs and self.Meshs:Num() > 0 then
        for i = 1, self.Meshs:Num() do
            local Comp = self.Meshs[i]
            if Comp and UE.UKismetSystemLibrary.IsValid(Comp) then
                Components[#Components + 1] = Comp
            end
        end
    end
    -- 如果没有 Meshs，使用 PMesh
    if #Components == 0 and self.PMesh and UE.UKismetSystemLibrary.IsValid(self.PMesh) then
        Components[#Components + 1] = self.PMesh
    end

    local function GetScalarParamSafe(OrigMat, ParamName)
        if OrigMat and OrigMat:IsA(UE.UMaterialInstanceDynamic) then
            local Value = OrigMat:K2_GetScalarParameterValue(ParamName)
            if Value ~= nil then
                return Value
            end
        end
    
        -- 默认值备份
        if ParamName == "MetallicRation" then return 1.0
        elseif ParamName == "RoughnessRation" then return 0.3
        elseif ParamName == "EmissiveRation" then return 0.0
        elseif ParamName == "NormalRation" then return 1.0
        end
    
        return 0.0
    end
    
    -- 安全获取 Vector 参数值
    local function GetVectorParamSafe(OrigMat, ParamName)
        if OrigMat and OrigMat:IsA(UE.UMaterialInstanceDynamic) then
            local Value = OrigMat:K2_GetVectorParameterValue(ParamName)
            if Value then
                return Value
            end
        end
    
        -- 默认白色
        return UE.FLinearColor(1, 1, 1)
    end
    

    -- 遍历组件，生成 MaterialDatas
    for i, Comp in ipairs(Components) do
        local Count = Comp:GetNumMaterials()
        print("[InitMaterialDatas] Component", i, "NumMaterials:", Count)
        for SlotIndex = 0, Count - 1 do
            local OrigMat = Comp:GetMaterial(SlotIndex)
            local ParentMat = nil
            if OrigMat:IsA(UE.UMaterialInstanceDynamic) then
                ParentMat = OrigMat.Parent
            else
                ParentMat = OrigMat
            end

            local MID = Comp:CreateDynamicMaterialInstance(SlotIndex, ParentMat)
            if not MID then return nil end

            Comp:SetMaterial(SlotIndex, MID)
        
            -- 设置 Scalar 参数
            local ScalarNames = { "MetallicRation", "RoughnessRation", "EmissiveRation", "NormalRation" }
            for _, ParamName in ipairs(ScalarNames) do
                MID:SetScalarParameterValue(ParamName, GetScalarParamSafe(OrigMat, ParamName))
            end
        
            -- 设置 Vector 参数
            local VectorNames = { "BaseColorConstant" }
            for _, ParamName in ipairs(VectorNames) do
                MID:SetVectorParameterValue(ParamName, GetVectorParamSafe(OrigMat, ParamName))
            end


            if MID then
                local Name = self:GetAttachParentActor().showName .. "_" .. "M" .. i .. "_" .. SlotIndex
                --
                local SourceState

                if self.SaveSourceState ~= nil and self.SaveSourceState[Name] ~= nil then
                    SourceState = self:DeepCopy(self.SaveSourceState[Name].SourceState)
                else
                    SourceState = {
                        TemplateName = nil,
                        Params = self:ReadSourceMaterial(MID)
                    }
                end

                self.MaterialDatas[Name] = {
                    MID = MID,
                    SourceState = self:DeepCopy(SourceState),
                    CurrentState = self:DeepCopy(SourceState)
                }

                self:ApplyMaterial(Name)
                self.totalMats = self.totalMats + 1
            else
                print("[InitMaterialDatas] Failed to create MID for Component", i, "Slot", SlotIndex)
            end
        end
    end

    print("[InitMaterialDatas] Total MaterialDatas:", self.totalMats)
end

-- 从 MaterialDatas 保存 SourceState 到 SaveSourceState
function M:SaveMaterialSourceState()
    local Save = {}
    for Name, Data in pairs(self.MaterialDatas) do
        Save[Name] = {
            SourceState = self:DeepCopy(Data.SourceState)
        }
    end
    self.SaveSourceState = Save
    return Save
end

-- 读取 MID 参数生成 SourceState Params
function M:ReadSourceMaterial(DynamicMaterialInstance)
    local Params = self:DeepCopy(DefaultMaterialParams)
    local MID = DynamicMaterialInstance
    if not MID then return Params end

    -- BaseColor
    if MID then
        local value = MID:K2_GetVectorParameterValue("BaseColorConstant")
        if value then
            Params.BaseColorConstant = { R = value.R, G = value.G, B = value.B }
        end
    end

    -- Scalar
    local function ReadScalar(Name, Default)
        if MID then
            local val = MID:K2_GetScalarParameterValue(Name)
            if val then return val end
        end
        return Default
    end
    Params.MetallicRation = ReadScalar("MetallicRation", 0)
    Params.RoughnessRation = ReadScalar("RoughnessRation", 0.5)
    Params.EmissiveRation = ReadScalar("EmissiveRation", 0)
    Params.NormalRation = ReadScalar("NormalRation", 1)

    return Params
end

-- 计算最终参数并应用到 MID
function M:ApplyMaterial(MaterialKey)
    local Data = self.MaterialDatas[MaterialKey]
    if not Data or not Data.MID then return end

    -- 优先 CurrentState -> SourceState
    local FinalParams = {}
    for k, v in pairs(Data.SourceState.Params) do FinalParams[k] = v end
    for k, v in pairs(Data.CurrentState.Params) do FinalParams[k] = v end

    local MID = Data.MID
    if FinalParams.BaseColorConstant then
        MID:SetVectorParameterValue("BaseColorConstant", UE.FLinearColor(FinalParams.BaseColorConstant.R,
            FinalParams.BaseColorConstant.G,
            FinalParams.BaseColorConstant.B, 1))
    end
    if FinalParams.MetallicRation then MID:SetScalarParameterValue("MetallicRation", FinalParams.MetallicRation) end
    if FinalParams.RoughnessRation then MID:SetScalarParameterValue("RoughnessRation", FinalParams.RoughnessRation) end
    if FinalParams.EmissiveRation then MID:SetScalarParameterValue("EmissiveRation", FinalParams.EmissiveRation) end
    if FinalParams.NormalRation then MID:SetScalarParameterValue("NormalRation", FinalParams.NormalRation) end
end

-- 修改材质参数
function M:SetMaterialParam(MaterialKey, ParamName, Value)
    local Data = self.MaterialDatas[MaterialKey]
    if not Data then return end
    Data.CurrentState.Params[ParamName] = Value
    self:ApplyMaterial(MaterialKey)
end

-- 提交修改，保存到 SourceState
function M:CommitMaterial(MaterialKey)
    local Data = self.MaterialDatas[MaterialKey]
    if not Data then return end
    Data.SourceState.TemplateName = Data.CurrentState.TemplateName
    for k, v in pairs(Data.CurrentState.Params) do
        Data.SourceState.Params[k] = v
    end
end

-- 恢复到 SourceState
function M:RestoreMaterial(MaterialKey)
    local Data = self.MaterialDatas[MaterialKey]
    if not Data then
        return
    end
    Data.CurrentState = self:DeepCopy(Data.SourceState)
    self:ApplyMaterial(MaterialKey)
end

-- 将 SaveSourceState 转成可序列化的表格
function M:GetSaveSourceStateAsTable()
    if not self.SaveSourceState then
        return nil
    end

    local TableData = {}

    for MaterialName, Data in pairs(self.SaveSourceState) do
        local Params = Data.SourceState.Params or {}
        local BaseColor = Params.BaseColorConstant or { R = 0.65, G = 0.65, B = 0.68 }

        TableData[MaterialName] = {
            TemplateName = Data.SourceState.TemplateName or "NONE",
            Params = {
                BaseColorConstant = {
                    R = BaseColor.R,
                    G = BaseColor.G,
                    B = BaseColor.B
                },
                MetallicRation    = Params.MetallicRation or 0.1,
                RoughnessRation   = Params.RoughnessRation or 0.50,
                EmissiveRation    = Params.EmissiveRation or 0.0,
                NormalRation      = Params.NormalRation or 1.0
            }
        }
    end

    return TableData
end

-- 转成 JSON 字符串保存
function M:GetSaveSourceStateAsJson()
    local TableData = self:GetSaveSourceStateAsTable()
    if not TableData then
        return nil
    end

    local jsonData = Json.encode(TableData)
    local jsonValue = UE.UJsonLibraryHelpers.FromString(jsonData)
    return UE.UJsonLibraryHelpers.JsonValue_Stringify(jsonValue)
end

--- 从JSON字符串加载并解析材质源状态数据
function M:LoadSaveSourceStateFromJson(JsonString)
    if not JsonString or JsonString == "" then
        return
    end

    local function decode_clean_json(s)
        while s:match('^"') and s:match('"$') do
            s = s:sub(2, -2)
        end
        s = s:gsub('\\"', '"')

        local obj, pos, err = Json.decode(s, 1, nil)
        if err then
            return nil, "解析失败: " .. err
        end

        return obj
    end

    local TableData = decode_clean_json(JsonString)

    print("[LoadSaveSourceStateFromJson] JSON decode failed:", JsonString)
    -- 再 decode

    if not TableData then
        return
    end

    self.SaveSourceState = {}

    for MaterialName, Data in pairs(TableData) do
        if Data then
            local templateName = Data.TemplateName
            if templateName == "NONE" then
                templateName = nil -- 如果需要，转回 nil
            end
            self.SaveSourceState[MaterialName] = {
                SourceState = {
                    TemplateName = templateName,
                    Params = Data.Params or self:DeepCopy(DefaultMaterialParams)
                }
            }
        end
    end
end

--- 将材质交互数据追加到模型数据表中
function M:AppendMaterialInteractionData(MDTV)
    if not MDTV then
        return
    end

    local Materials = {}

    if self.MaterialDatas then
        for Key, Data in pairs(self.MaterialDatas) do
            if Data.CurrentState then
                -- 组合输出结构
                Materials[Key] = {
                    TemplateName = Data.CurrentState.TemplateName or "NONE",
                    Params = self:DeepCopy(Data.CurrentState.Params)
                }
            end
        end
    end

    if next(Materials) then
        MDTV.Materials = Materials
    else
        MDTV.Materials = nil
    end

    return MDTV
end

function M:DeepCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for k, v in pairs(orig) do
            copy[self:DeepCopy(k)] = self:DeepCopy(v)
        end
        local mt = getmetatable(orig)
        if mt then
            setmetatable(copy, self:DeepCopy(mt))
        end
    else
        copy = orig
    end
    return copy
end

return M
