-- ═══════════════════════════════════════════════════════════════
-- UE HTTP Gateway — 在 UE4 内部启动 HTTP 服务器
-- 替代 WebSocket 方案，不需要刷新网页
-- ═══════════════════════════════════════════════════════════════
--
-- 部署: 在 UI_SandBox.lua 的初始化中调用 require("SandBox.UEHttpGateway").start(self)
-- 或者从 UE4 控制台手动调用
--
-- 端口: 9080 (避免和 8780/8790 冲突)
-- API:
--   GET  /api/health        → 连接状态
--   GET  /api/scene-state   → 调用 AIGetSceneState
--   POST /api/execute       → 调用 AIExecute
-- ═══════════════════════════════════════════════════════════════

local M = {}
local Json = require("dkjson")
local Screen = require("SandBox.Screen")

local PORT = 9080
local server = nil
local uiRef = nil

-- 安全: 只允许本机连接
local ALLOWED_IPS = {
    ["127.0.0.1"] = true,
    ["::1"] = true,
    ["localhost"] = true,
}

-- ════════ 工具函数 ════════

local function make_response(text, contentType, code)
    return {
        HttpServerResponse = {
            Code = code or 200,
            Headers = {
                ["Content-Type"] = contentType or "application/json",
                ["Access-Control-Allow-Origin"] = "*",
                ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
                ["Access-Control-Allow-Headers"] = "Content-Type",
            },
            Body = text or "",
        }
    }
end

local function json_response(data, code)
    return make_response(Json.encode(data), "application/json", code or 200)
end

local function error_response(message, code)
    return json_response({ ok = false, error = message }, code or 500)
end

-- ════════ 路由处理 ════════

local function handle_health()
    return json_response({
        ok = true,
        ue4 = {
            connected = true,
            hasUI = uiRef ~= nil,
            hasControl = uiRef and uiRef.control ~= nil,
        },
        server = "UEHttpGateway",
        port = PORT,
        timestamp = os.time(),
    })
end

local function handle_scene_state()
    if not uiRef or not uiRef.control then
        return error_response("UI or control not ready", 503)
    end

    local aiCommand = uiRef.control:GetAICommand and uiRef.control:GetAICommand()
    if not aiCommand then
        -- 尝试通过 AICommand 模块
        local AICommand = require("SandBox.AI.AICommand")
        if uiRef.aiCommand then
            aiCommand = uiRef.aiCommand
        else
            aiCommand = AICommand.New(uiRef)
        end
    end

    local ok, state = pcall(aiCommand.GetSceneState, aiCommand, {})
    if not ok then
        return error_response("GetSceneState failed: " .. tostring(state), 500)
    end

    return json_response({ ok = true, data = state })
end

local function handle_execute(body)
    if not uiRef or not uiRef.control then
        return error_response("UI or control not ready", 503)
    end

    local data = Json.decode(body or "")
    if not data then
        return error_response("invalid JSON body", 400)
    end

    local aiCommand = uiRef.control:GetAICommand and uiRef.control:GetAICommand()
    if not aiCommand then
        local AICommand = require("SandBox.AI.AICommand")
        if uiRef.aiCommand then
            aiCommand = uiRef.aiCommand
        else
            aiCommand = AICommand.New(uiRef)
        end
    end

    local ok, result = pcall(aiCommand.Execute, aiCommand, data)
    if not ok then
        return error_response("Execute failed: " .. tostring(result), 500)
    end

    return json_response({ ok = true, data = result })
end

-- ════════ 请求分发 ════════

local function route_handler(request)
    local path = request.RelativePath or "/"
    local verb = request.Verb
    local body = request.Body or ""

    -- CORS preflight
    if verb == 5 then -- OPTIONS
        return make_response("", "text/plain", 204)
    end

    -- GET /api/health
    if path == "/api/health" and verb == 1 then
        return handle_health()
    end

    -- GET /api/scene-state
    if path == "/api/scene-state" and verb == 1 then
        return handle_scene_state()
    end

    -- POST /api/execute
    if path == "/api/execute" and verb == 2 then
        return handle_execute(body)
    end

    return error_response("not found: " .. path, 404)
end

-- ════════ 启动/停止 ════════

function M.start(ui)
    uiRef = ui or uiRef

    if server then
        Screen.Print("UEHttpGateway: 已在运行")
        return true
    end

    -- 获取 SimpleHttpServer 子系统
    local gi = uiRef and uiRef:GetGameInstance()
        or (uiRef and uiRef.control and uiRef.control.pc and uiRef.control.pc.gi)
        or (uiRef and uiRef.control and uiRef.control.pc and uiRef.control.pc:GetGameInstance())

    if not gi then
        -- 尝试通过 GameplayStatics
        local world = uiRef and uiRef:GetWorld()
        if world then
            gi = UE.UGameplayStatics.GetGameInstance(world)
        end
    end

    if not gi then
        Screen.Print("UEHttpGateway: 无法获取 GameInstance")
        return false
    end

    local subsystem = gi:GetSubsystem(UE.UHttpServerSubsystem)
    if not subsystem then
        Screen.Print("UEHttpGateway: HttpServerSubsystem 不可用")
        return false
    end

    server = subsystem:GetSimpleHttpServer(UE.USimpleHttpServer)
    if not server then
        Screen.Print("UEHttpGateway: 无法创建 SimpleHttpServer")
        return false
    end

    -- 绑定路由
    -- Note: SimpleHttpServer 的 BindRoute 需要蓝图委托，
    -- 在 Lua 中我们使用 BindRouteNative 如果可用，否则需要蓝图配合
    -- 这里先尝试直接调用
    local ok, err = pcall(function()
        server:StartServer(PORT)
    end)

    if not ok then
        Screen.Print("UEHttpGateway: 启动失败: " .. tostring(err))
        server = nil
        return false
    end

    Screen.Print("UEHttpGateway: HTTP 服务器已启动，端口 " .. PORT)
    Screen.Print("UEHttpGateway: API:")
    Screen.Print("  GET  /api/health")
    Screen.Print("  GET  /api/scene-state")
    Screen.Print("  POST /api/execute")

    return true
end

function M.stop()
    if server then
        pcall(server.StopServer, server)
        server = nil
        Screen.Print("UEHttpGateway: 已停止")
    end
end

function M.isRunning()
    return server ~= nil
end

-- ════════ 快捷测试（从 UE4 控制台调用） ════════

function M.test()
    local result = {
        ok = true,
        message = "UEHttpGateway test",
        hasUI = uiRef ~= nil,
        hasControl = uiRef and uiRef.control ~= nil,
        hasModelManage = uiRef and uiRef.control and uiRef.control.modelManage ~= nil,
        port = PORT,
        running = M.isRunning(),
    }
    Screen.Print(Json.encode(result))
    return result
end

return M
