local sproto = require "sproto.sproto"
local conn = require "conn"


local mt = {}


local function new(client_pbin, server_pbin)
    local client_proto = sproto.new(client_pbin)
    local server_proto = sproto.new(server_pbin)

    local client = client_proto:host "package"
    -- local server = server_proto:host "package"

    local client_request = client:attach(server_proto)

    local raw = {
        v_session_index = 0,
        v_request_session = {},
        v_response_handle = {},
        v_out = {},
        v_conn = false,

        v_client = client,
        v_client_request = client_request,
    }

    return setmetatable(raw, {__index = mt})
end



function mt:connect(host, port)
    self.v_request_session = {}
    local obj, errcode = conn.connect_host(host, port)
    if not obj then
        return false, errcode
    else
        self.v_conn = obj
        return true
    end
end


local function dispatch(self, resp)
    local client = self.v_client
    local _type, v1, v2, v3 = client:dispatch(resp)
    -- print("dispatch:", _type, v1, v2, v3)
    if _type == "RESPONSE" then
        local session, response = v1, v2
        local session_item = self.v_request_session[session]
        local handle = session_item.handle
        local tt  = type(handle)
        if tt == "function" then
            handle(response)
        elseif tt == "thread" then
            local success, err = coroutine.resume(handle, response)
            if not success then
                error(err)
            end
        else
            error("error handle type:"..tt.." from msg:"..tostring(session_item.name))
        end
        self.v_request_session[session] = nil

    elseif _type == "REQUEST" then
        local name, request, response = v1, v2, v3
        local handle = self.v_response_handle[name]
        local data = handle(request)
        if response then
            data = response(data)
            self.v_conn:send_msg(data)
        end
    else
        error("error dispatch type: "..tostring(_type))
    end
end


function mt:update()
    local success, err, status = self.v_conn:update()

    if success then
        local client = self.v_client
        local out = self.v_out
        local conn = self.v_conn
        local count = conn:recv_msg(out)

        for i=1,count do
            local resp = out[i]
            dispatch(self, resp)
        end
    end

    return success, err, status
end


local function request(self, name, t, session_index)
    local req = self.v_client_request(name, t, session_index)
    return self.v_conn:send_msg(req)
end


function mt:call(name, t, cb)
    local session_index = self.v_session_index
    self.v_session_index = session_index + 1

    assert(self.v_request_session[session_index]==nil, session_index)
    local session_item = {
        name = name,
        handle = false,
    }
    self.v_request_session[session_index] = session_item

    if cb then
        session_item.handle = cb
        request(self, name, t, session_index)
    elseif coroutine.isyieldable() then
        session_item.handle = coroutine.running()
        request(self, name, t, session_index)
        return coroutine.yield()
    else
        assert(cb)
    end
end


function mt:invoke(name, t)
    return request(self, name, t)
end


function mt:register(name, cb)
    assert(cb)
    assert(self.v_response_handle[name] == nil)
    self.v_response_handle[name] = cb
end



return new


