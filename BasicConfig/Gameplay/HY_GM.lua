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
    self:InitWebSocketState()
    self:CreateHTTP()
end

function M:InitStreamer()
    local PCClass = LoadClass("/Game/SandBox/BasicConfig/Gameplay/PC.PC_C")
    self.PC = UE.UGameplayStatics.GetPlayerController(self:GetWorld(), 0):Cast(PCClass)
    self.PC.uiSandBox:addNullPlan();
end


local HEARTBEAT_NAME = "__heartbeat"
local HEARTBEAT_PING = "ping"
local HEARTBEAT_PONG = "pong"
local WS_STATE_DISCONNECTED = "Disconnected"
local WS_STATE_CONNECTING = "Connecting"
local WS_STATE_CONNECTED = "Connected"
local WS_STATE_TIMEOUT = "Timeout"

local function NowSeconds()
    return os.time()
end

local function BuildHeartbeatMessage(action, sequence)
    return {
        type = "UE",
        name = HEARTBEAT_NAME,
        action = action,
        sequence = sequence,
        timestamp = NowSeconds()
    }
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

function M:InitWebSocketState()
    self.WebSocketUrl = self.WebSocketUrl or "ws://127.0.0.1:9900"
    self.WebSocketProtocol = self.WebSocketProtocol or "ws"
    self.WSHeartbeatInterval = self.WSHeartbeatInterval or 10
    self.WSHeartbeatTimeout = self.WSHeartbeatTimeout or 30
    self.WSReconnectInterval = self.WSReconnectInterval or 5
    self.WSHeartbeatSequence = 0
    self.WSConnectionState = WS_STATE_DISCONNECTED
    self.WSLastReceiveTime = NowSeconds()
    self.WSLastPongTime = NowSeconds()
    self.WSLastPingTime = 0
end

function M:SetWebSocketState(state, reason)
    if self.WSConnectionState == state and self.WSConnectionReason == reason then
        return
    end
    self.WSConnectionState = state
    self.WSConnectionReason = reason
    print(string.format("WS state changed: %s, reason: %s", tostring(state), tostring(reason or "")))
end

function M:IsWebSocketReady()
    return self.WebSocketObject and self.WebSocketObject:IsConnected() and self.WSConnectionState == WS_STATE_CONNECTED
end

function M:SendWebSocketJson(payload)
    if not (self.WebSocketObject and self.WebSocketObject:IsConnected()) then
        print("WS send skipped: websocket disconnected")
        return false
    end
    local Success, Payload = pcall(Json.encode, payload)
    if not Success then
        print("WS encode failed: " .. tostring(Payload))
        return false
    end
    self.WebSocketObject:Send(Payload)
    return true
end

function M:SendHTTPResponse(response)
    self:SendWebSocketJson(response)
end

function M:SendHeartbeat(action, sequence)
    return self:SendWebSocketJson(BuildHeartbeatMessage(action, sequence))
end

function M:StartHeartbeatTimer()
    if self.WSHeartbeatTimer then
        UE.UKismetSystemLibrary.K2_ClearAndInvalidateTimerHandle(self:GetWorld(), self.WSHeartbeatTimer)
    end
    self.WSHeartbeatTimer = UE.UKismetSystemLibrary.K2_SetTimerDelegate(
        { self, self.CheckWebSocketHeartbeat },
        self.WSHeartbeatInterval,
        true
    )
end

function M:CheckWebSocketHeartbeat()
    if not (self.WebSocketObject and self.WebSocketObject:IsConnected()) then
        self:SetWebSocketState(WS_STATE_DISCONNECTED, "socket disconnected")
        if self.WSReconnectTimer then
            return
        end
        self.WSReconnectTimer = UE.UKismetSystemLibrary.K2_SetTimerDelegate(
            { self, self.ReconnectWebSocket },
            self.WSReconnectInterval,
            true
        )
        return
    end

    local Now = NowSeconds()
    if self.WSConnectionState == WS_STATE_CONNECTED and Now - (self.WSLastReceiveTime or Now) > self.WSHeartbeatTimeout then
        self:SetWebSocketState(WS_STATE_TIMEOUT, "server heartbeat timeout")
    end

    self.WSHeartbeatSequence = (self.WSHeartbeatSequence or 0) + 1
    self.WSLastPingTime = Now
    self:SendHeartbeat(HEARTBEAT_PING, self.WSHeartbeatSequence)
end

function M:ReconnectWebSocket()
    if self.WebSocketObject and self.WebSocketObject:IsConnected() then
        if self.WSReconnectTimer then
            UE.UKismetSystemLibrary.K2_ClearAndInvalidateTimerHandle(self:GetWorld(), self.WSReconnectTimer)
            self.WSReconnectTimer = nil
        end
        self:SetWebSocketState(WS_STATE_CONNECTED, "reconnected")
        return
    end
    self:SetWebSocketState(WS_STATE_CONNECTING, "reconnecting")
    if self.WebSocketObject then
        self.WebSocketObject:Connect()
    end
end

-- 生成 http 通信绑定
function M:CreateHTTP()
    self.WebSocketObject = UE.UWebSocketFunctionLibrary.CreateWebSocket(self.WebSocketUrl, self.WebSocketProtocol)
    self:SetWebSocketState(WS_STATE_CONNECTING, "initial connect")
    if not self.WebSocketObject:IsConnected() then
        self.WebSocketObject:Connect()
    end
    if self.WebSocketObject:IsConnected() then
        self:WebSocketConnected()
    end
    self.WebSocketObject.OnWebSocketConnected:Add(self, self.WebSocketConnected)
    self.WebSocketObject.OnWebSocketMessageReceived:Add(self, self.BindHTTP)
    self:StartHeartbeatTimer()
end

function M:WebSocketConnected()
    self.WSLastReceiveTime = NowSeconds()
    self.WSLastPongTime = self.WSLastReceiveTime
    self:SetWebSocketState(WS_STATE_CONNECTED, "connected")
    print("WS连接成功")
    self:SendHeartbeat(HEARTBEAT_PING, 0)
end

function M:HandleHeartbeatMessage(Data)
    local Name = Data.name
    local Action = Data.action or Data.event or Data.cmd
    if Name == HEARTBEAT_PING or Action == HEARTBEAT_PING then
        self.WSLastReceiveTime = NowSeconds()
        self:SendHeartbeat(HEARTBEAT_PONG, Data.sequence)
        return true
    end
    if Name == HEARTBEAT_PONG or Action == HEARTBEAT_PONG then
        self.WSLastPongTime = NowSeconds()
        return true
    end
    if Name == HEARTBEAT_NAME then
        return true
    end
    return false
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
    self.WSLastReceiveTime = NowSeconds()
    if self.WSConnectionState ~= WS_STATE_CONNECTED then
        self:SetWebSocketState(WS_STATE_CONNECTED, "message received")
    end
    if self:HandleHeartbeatMessage(Data) then
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

function M:ReceiveEndPlay()
    if self.WSHeartbeatTimer then
        UE.UKismetSystemLibrary.K2_ClearAndInvalidateTimerHandle(self:GetWorld(), self.WSHeartbeatTimer)
        self.WSHeartbeatTimer = nil
    end
    if self.WSReconnectTimer then
        UE.UKismetSystemLibrary.K2_ClearAndInvalidateTimerHandle(self:GetWorld(), self.WSReconnectTimer)
        self.WSReconnectTimer = nil
    end
    self:SetWebSocketState(WS_STATE_DISCONNECTED, "end play")
end

-- function M:ReceiveTick(DeltaSeconds)
-- end

-- function M:ReceiveAnyDamage(Damage, DamageType, InstigatedBy, DamageCauser)
-- end

-- function M:ReceiveActorBeginOverlap(OtherActor)
-- end

-- function M:ReceiveActorEndOverlap(OtherActor)
-- end
return M
