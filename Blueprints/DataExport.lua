--
-- DESCRIPTION
--
-- @COMPANY **
-- @AUTHOR **
-- @DATE ${date} ${time}
--

---@type DataExport_C
local M = UnLua.Class()

function M:ReceiveBeginPlay()
    local DSAs = UE.UGameplayStatics.GetAllActorsOfClass(self:GetWorld(), UE.AStaticMeshActor)
    self.DSAs = UE.UGameplayStatics.GetAllActorsOfClass(self:GetWorld(), UE.AStaticMeshActor)
    self.CsvArray1 = UE.TArray("")
    self.CsvArray2 = UE.TArray("")
    self.CsvArray3 = UE.TArray("")
    self.Count = 1
    local Csv1 = "---,Mesh,bDefaultSetting,Size,MType,CType"
    self.CsvArray1:Add(Csv1)
    self.CsvArray2:Add(Csv1)
    for key, value in pairs(DSAs) do
        print(key)
        local Name = UE.UKismetSystemLibrary.GetObjectName(value.StaticMeshComponent.StaticMesh)
        local Path = UE.UKismetSystemLibrary.GetPathName(value.StaticMeshComponent.StaticMesh)
        print(Path)
        print("Path")

        local ActorCsv = Name .. "," .. Path .. ",FALSE,(X=0.000000Y=0.000000Z=0.000000),3,1"
        print(ActorCsv)
        self.CsvArray1:Add(ActorCsv)
    end
    ModelPath = UE.UMyBFL.GetExeURL("ModelPath")
    UE.UMyBFL.SaveTextArray(ModelPath, "模型数据.csv", self.CsvArray1, true)

    for key, value in pairs(DSAs) do
        local Name = UE.UKismetSystemLibrary.GetObjectName(value.StaticMeshComponent.StaticMesh)
        local Path = UE.UKismetSystemLibrary.GetPathName(value.StaticMeshComponent.StaticMesh)
        print(Path)
        print("Path")

        local ActorCsv = Name .. "," .. "StaticMesh'" .. Path .. "'" .. ",FALSE,(X=0.000000Y=0.000000Z=0.000000),3,1"
        self.CsvArray2:Add(ActorCsv)
    end
    ModelPath = UE.UMyBFL.GetExeURL("ModelPath")
    UE.UMyBFL.SaveTextArray(ModelPath, "模型图片数据.csv", self.CsvArray2, true)

    for key, value in pairs(DSAs) do
        local Name = UE.UKismetSystemLibrary.GetObjectName(value.StaticMeshComponent.StaticMesh)
        local Path = UE.UKismetSystemLibrary.GetPathName(value.StaticMeshComponent.StaticMesh)
        print(Path)
        print("Path")

        local ActorCsv = key .. "," .. Name .. ",/statics/modelResourceImage/" .. Name .. ".png"
        self.CsvArray3:Add(ActorCsv)
    end
    ModelPath = UE.UMyBFL.GetExeURL("ModelPath")
    UE.UMyBFL.SaveTextArray(ModelPath, "后端数据表.csv", self.CsvArray3, true)

    self:Examine()
    -- self:ExamineTime()
end

function M:ExamineTime()
    self.GroupsTimer = UE.UKismetSystemLibrary.K2_SetTimerDelegate({self, self.Examine}, 10, true)
end

function M:Examine()
    --生成模型
    if self.Actor then
        self.Actor:K2_DestroyActor()
        self.Actor = nil
    end

    print(self.Count)
    print(self.DSAs[self.Count])
    local Path = UE.UKismetSystemLibrary.GetPathName(self.DSAs[self.Count].StaticMeshComponent.StaticMesh)
    -- if self.Actor then
    self.Actor =
        self:GetWorld():SpawnActor(
        LoadClass("/Game/SandBox/Blueprints/DrawModel/BP_Model.BP_Model_C"),
        nil,
        UE.ESpawnActorCollisionHandlingMethod.Default,
        self,
        self,
        ""
    )

    self.Actor.StaticMeshComponent:SetStaticMesh(LoadObject(Path))
    self.Count = self.Count + 1
    print(UE.UKismetSystemLibrary.GetObjectName(self.DSAs[self.Count].StaticMeshComponent.StaticMesh))

    --判断是否有碰撞
    local Start = UE.FVector(100, 100, 10000)
    local End = UE.FVector(100, 100, -50)
    local HitRes = UE.FHitResult()
    UE.UKismetSystemLibrary.LineTraceSingle(self:GetWorld(), Start, End, UE.ETraceTypeQuery.Visibility, true, nil, 0, HitRes, true)
    print(UE.UKismetSystemLibrary.GetObjectName(HitRes.Actor))
    if HitRes.Actor == self.Actor then
        print("有碰撞")
    else
        print("无碰撞")
    end

    --判断坐标轴位置
    local Origin, BoxExtent = self.Actor:GetActorBounds(false)
    print(Origin, BoxExtent)
    print(self.Actor.StaticMeshComponent)
    local Origin1, BoxExtent1, SphereRadius= UE.UKismetSystemLibrary.GetComponentBounds(self.PMesh)
    print(Origin1, BoxExtent1, SphereRadius)


    self.Actor:K2_DestroyActor()
    self.Actor = nil
end

return M
