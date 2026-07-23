--
-- DESCRIPTION
--
-- @COMPANY **
-- @AUTHOR **
-- @DATE ${date} ${time}
--

---@class HY_GM_C
local M = UnLua.Class()
local Screen = require("Screen")
local MFL = require("Framework.FunctionLibrary.MessageFunctionLibrary")
local QMAPI = require("Framework.FunctionLibrary.QMAPI")
local Api = require("SandBox.Api")
local Json = require("dkjson")

-- function M:Initialize(Initializer)
-- end

-- function M:UserConstructionScript()
-- end

function M:ReceiveBeginPlay()
    self:CreateHTTP()
end

function M:InitStreamer()
    local PCClass = LoadClass("/Game/SandBox/BasicConfig/Gameplay/PC.PC_C")
    self.PC = UE.UGameplayStatics.GetPlayerController(self:GetWorld(), 0):Cast(PCClass)
    self.PC.uiSandBox:addNullPlan();
end

-- 生成 http 通信绑定
function M:CreateHTTP()
    self.WebSocketObject = UE.UWebSocketFunctionLibrary.CreateWebSocket("ws://127.0.0.1:9900", "ws")
    if not self.WebSocketObject:IsConnected() then
        self.WebSocketObject:Connect()
    end
    if self.WebSocketObject:IsConnected() then
        print("WS连接成功")
    end
    self.WebSocketObject.OnWebSocketConnected:Add(self, self.WebSocketConnected)
    self.WebSocketObject.OnWebSocketMessageReceived:Add(self, self.BindHTTP)
end

function M:WebSocketConnected()
    print("WS连接成功")
end

-- http 通信绑定
function M:BindHTTP(message)

    print("WS Message:" .. tostring(message))
    if not message then
        print("WS message nil")
        return
    end
    local Success, Data = pcall(Json.decode, message)
    if not Success or not Data then
        print("WS json decode failed: " .. tostring(Data))
        return
    end
    if Data.type ~= "UE" then
        print(
            "WS type invalid:",
            tostring(Data.type)
        )
        return
    end
    if not Data.name then
        print("WS name missing")
        return
    end
    local Params = Data.table or {}
    if type(Params) == "string" then
        Params = Json.decode(Params)
    end
    local result = MFL.Communication(
        Data.name,
        Params,
        Api
    )
    return result

end

-- function M:ReceiveEndPlay()
-- end

-- function M:ReceiveTick(DeltaSeconds)
-- end

-- function M:ReceiveAnyDamage(Damage, DamageType, InstigatedBy, DamageCauser)
-- end

-- function M:ReceiveActorBeginOverlap(OtherActor)
-- end

-- function M:ReceiveActorEndOverlap(OtherActor)
-- end
return M
