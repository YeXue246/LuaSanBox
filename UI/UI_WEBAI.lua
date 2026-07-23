--
-- DESCRIPTION
--
-- @COMPANY **
-- @AUTHOR **
-- @DATE ${date} ${time}
--

---@type UI_AI_C
local M = UnLua.Class()
local Screen = require("SandBox.Screen")
local MFL = require("Framework.FunctionLibrary.MessageFunctionLibrary")
local Api = require("SandBox.Api")

local DEFAULT_AI_URL = "http://127.0.0.1:8780/agent-pipeline.html"
--http://127.0.0.1:8780/agent-pipeline.html
--http://127.0.0.1:8780/index.html
local DIALOG_WIDTH = 430
local DIALOG_HEIGHT = 680

local function AppendCacheBuster(url)
    local hashStart = string.find(url, "#", 1, true)
    local baseUrl = url
    local hash = ""
    if hashStart then
        baseUrl = string.sub(url, 1, hashStart - 1)
        hash = string.sub(url, hashStart)
    end

    local joiner = "?"
    if string.find(baseUrl, "?", 1, true) then
        joiner = "&"
    end
    return baseUrl .. joiner .. "_ai_ts=" .. tostring(os.time()) .. hash
end

--function M:Initialize(Initializer)
--end

--function M:PreConstruct(IsDesignTime)
--end

function M:Construct()
    self:InitAIWeb()
end

--function M:Tick(MyGeometry, InDeltaTime)
--end

function M:InitAIWeb(parentUi)
    self.parentUi = parentUi or self.parentUi or Api.Object
    if self.parentUi then
        self.parentUi.aiWebUi = self
    end

    self:SetDialogSize()

    if not self.WEBAI then
        Screen.Print("UI_WEBAI: WEBAI WebBrowser variable not found")
        return
    end

    if self.bAIWebInited then
        return
    end
    self.bAIWebInited = true

    if self.WEBAI.SetEnabledDevTool then
        pcall(function()
            self.WEBAI:SetEnabledDevTool(true)
        end)
    end

    if self.WEBAI.OnInterfaceEvent then
        self.WEBAI.OnInterfaceEvent:Add(self, self.BindWEBAI)
    end
    self:LoadAIPage()
end

function M:SetDialogSize()
    local size = UE.FVector2D(DIALOG_WIDTH, DIALOG_HEIGHT)

    if self.SetDesiredSizeInViewport then
        pcall(function()
            self:SetDesiredSizeInViewport(size)
        end)
    end

    if self.Slot and self.Slot.SetSize then
        pcall(function()
            self.Slot:SetSize(size)
        end)
    end
end

function M:GetAIURL()
    if self.AIWebURL and self.AIWebURL ~= "" then
        return self.AIWebURL
    end
    return DEFAULT_AI_URL
end

function M:LoadAIPage(url)
    if not self.WEBAI then
        return
    end
    local aiUrl = AppendCacheBuster(url or self:GetAIURL())
    self.WEBAI:LoadURL(aiUrl)
    Screen.Print("AI 页面加载：" .. tostring(aiUrl))
end

function M:BindWEBAI(name, data, callback)
    if Api.Object then
        Api.Object.aiWebUi = self
    end
    -- 页面已就绪（能主动调用 UE 说明已加载完成）
    self._aiWebReady = true
    MFL.CEFCommunication(name, data, callback, Api)
end

function M:UECallAIWeb(text, data, bStr)
    if not self.WEBAI then
        return
    end

    -- scene.delta 在页面未完全加载时会报错，暂时跳过
    -- 页面通过 hash 回调主动获取场景状态
    if text == "scene.delta" and not self._aiWebReady then
        return
    end

    if bStr then
        MFL.CallWebString(self.WEBAI, text, data)
    else
        MFL.CallWeb(self.WEBAI, text, data)
    end
end

function M:ShowAI()
    self:SetVisibility(0)
    -- 每次显示时重新加载页面（确保拿到最新版本）
    if self.WEBAI then
        self:LoadAIPage()
    end
end

function M:HideAI()
    self:SetVisibility(1)
end

function M:ToggleAI()
    if self:GetVisibility() == 0 then
        self:HideAI()
    else
        self:ShowAI()
    end
end

return M
