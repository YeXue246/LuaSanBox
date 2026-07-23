--
-- DESCRIPTION
--
-- @COMPANY **
-- @AUTHOR **
-- @DATE ${date} ${time}
--

---@type TestUI_C
local M = UnLua.Class()

function M:Initialize()
    -- 初始化 UI 数据
    self.shuruText = ""  -- 输入框内容
    self.shuchuText = "" -- 输出框内容
end

--function M:PreConstruct(IsDesignTime)
--end

function M:ConstructUI()
    -- 创建多行输出
    self.shuchuMultiLine:SetText("=== 测试用输出 ===\n")

    -- 创建多行输入
    self.shuruMultiLine:SetText("这里输入测试文本...")

    -- 创建按钮 Send
    self.Send.OnClicked:Add(self, self.OnSendClicked)

        -- 创建按钮 Rest
    self.Rest.OnClicked:Add(self, self.OnRestClicked)


end

function M:OnSendClicked()
    local inputText = self.shuruMultiLine:GetText()
    if inputText == "" then
        return
    end

    -- 调用发送函数
    self:Send(inputText)
end

-- Rest 按钮回调（示例也是发送内容）
function M:OnRestClicked()
    local inputText = self.shuruMultiLine:GetText()
    if inputText == "" then
        return
    end

    -- 调用 Rest 函数，示例也是发送
    self:Rest(inputText)
end

-- 示例 Send 函数
function M:Send(text)

self.control:ModelDataToModel(DT)
end

-- 示例 Rest 函数
function M:Rest(text)

end


return M
--function M:Tick(MyGeometry, InDeltaTime)
--end

return M
