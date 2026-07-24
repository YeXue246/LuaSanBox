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


local function BuildHTTPResponse(name, ok, result, message)
    return {
        type = "UE",
        name = name,
        ok = ok,
        success = ok,
        result = result,
        message = message
    }
end

function M:SendHTTPResponse(response)
    if not (self.WebSocketObject and self.WebSocketObject:IsConnected()) then
        print("WS response skipped: websocket disconnected")
        return
    end
    local Success, Payload = pcall(Json.encode, response)
    if not Success then
        print("WS response encode failed: " .. tostring(Payload))
        return
    end
    self.WebSocketObject:Send(Payload)
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
        self:SendHTTPResponse(BuildHTTPResponse(nil, false, nil, "WS message nil"))
        return
    end
    local Success, Data = pcall(Json.decode, message)
    if not Success or not Data then
        print("WS json decode failed: " .. tostring(Data))
        self:SendHTTPResponse(BuildHTTPResponse(nil, false, nil, "WS json decode failed: " .. tostring(Data)))
        return
    end
    if Data.type ~= "UE" then
        print(
            "WS type invalid:",
            tostring(Data.type)
        )
        self:SendHTTPResponse(BuildHTTPResponse(Data.name, false, nil, "WS type invalid: " .. tostring(Data.type)))
        return
    end
    if not Data.name then
        print("WS name missing")
        self:SendHTTPResponse(BuildHTTPResponse(nil, false, nil, "WS name missing"))
        return
    end
    local Params = Data.table or {}
    if type(Params) == "string" then
        local ParamsSuccess, DecodedParams = pcall(Json.decode, Params)
        if not ParamsSuccess or not DecodedParams then
            local ErrorMessage = "WS params json decode failed: " .. tostring(DecodedParams)
            print(ErrorMessage)
            self:SendHTTPResponse(BuildHTTPResponse(Data.name, false, nil, ErrorMessage))
            return
        end
        Params = DecodedParams
    end
    local CallSuccess, result = pcall(MFL.Communication,
        Data.name,
        Params,
        Api
    )
    if not CallSuccess then
        local ErrorMessage = "WS call failed: " .. tostring(result)
        print(ErrorMessage)
        self:SendHTTPResponse(BuildHTTPResponse(Data.name, false, nil, ErrorMessage))
        return
    end

    local ok = true
    local messageText = "调用成功"
    if type(result) == "table" then
        if result.ok ~= nil then
            ok = result.ok
        elseif result.success ~= nil then
            ok = result.success
        end
        messageText = result.message or messageText
    end
    self:SendHTTPResponse(BuildHTTPResponse(Data.name, ok, result, messageText))
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
