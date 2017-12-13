local conn = require "conn"
local crypt = require "crypt"
local rc4 = require "rc4.c"
local buffer_queue = require "buffer_queue"

local pack_data = buffer_queue.pack_data


local CACHE_MAX_COUNT = 100
local DEF_MSG_HEADER_LEN = 2
local DEF_MSG_ENDIAN = "little"

local mt = {}
local cache_mt = {}


-------------- for test ---------------
local VERBOSE = true
local log = VERBOSE and print or 
    function(...)
    end

-------------- cache ------------------
local function cache_create()
    local raw = {
        size = 0,

        top = 0,
        cache = {},
    }
    return setmetatable(raw, {__index = cache_mt})
end

function cache_mt:insert(data)
    local cache = self.cache
    self.top = self.top + 1
    cache[self.top] = data
    self.size = self.size + #data
    local remove_cache_value = cache[self.top-CACHE_MAX_COUNT]
    cache[self.top-CACHE_MAX_COUNT] = nil  -- 只缓存最近CACHE_MAX_COUNT个包
    if remove_cache_value then
        self.size = self.size - #remove_cache_value
    end
end

function cache_mt:get(nbytes)
    if self.size < nbytes then
        return false
    end

    local cache = self.cache
    local i = self.top
    local count = 0
    local ret = {}
    while count<nbytes do
        local v = cache[i]
        local len = #v
        local n = len
        local vv = v
        if count + len > nbytes then
            local sub_n = nbytes - count
            local pos = len-sub_n
            local sub_v = string.sub(v, pos+1)
            n = sub_n
            vv = sub_v
        end
        table.insert(ret, 1, vv)
        count = count + n
        i = i-1
    end

    return table.concat(ret)
end


function cache_mt:clear()
    self.size = 0
    self.top = 0
end

local function dummy(...)
    log("send dummy")
end

local function dispose_error(state_self, _success, _err, _status)
    local success = false
    local err = state_self.name
    local status = "reconnect_error"
    return success, err, status
end

-------------- state ------------------

local state = {
    newconnect = {
        name = "newconnect",
        request = false,
        dispatch = false,
        send = false,
        dispose = false,
    },

    reconnect = {
        name = "reconnect",
        request = false,
        dispatch = false,
        send = false,
        dispose = false,
    },

    forward = {
        name = "forward",
        request = false,
        dispatch = false,
        send = false,
        dispose = false,
    },

    reconnect_error = {
        name = "reconnect_error",
        send = dummy,
        dispose = dispose_error,
    },

    reconnect_match_error = {
        name = "reconnect_match_error",
        send = dummy, 
        dispose = dispose_error,
    },

    reconnect_cache_error = {
        name = "reconnect_cache_error",
        send = dummy, 
        dispose = dispose_error,
    },

    close = {
        name = "close",
        send = dummy,
        dispose = false,
    },
}

local function switch_state(self, s)
    local v = state[s]
    assert(v)
    log(">>>>>>>>>>>>>switch_state:", s)
    self.v_state = v
    if v.request then
        v.request(self)
    end
end

local out = {}

-------------- new connect state ------------------
function state.newconnect.request(self)
    -- 0\n
    -- base64(DH_key)\n

    local clientkey = crypt.randomkey()
    local data = string.format("0\n%s\n",
        crypt.base64encode(crypt.dhexchange(clientkey)))

    data = pack_data(data, 2, "big")
    self.v_sock:send(data)
    self.v_clientkey = clientkey
    log("request:", data)
    self.v_send_buf_top = 0
end


function state.newconnect.send(self, data)
    self.v_send_buf_top = self.v_send_buf_top + 1
    self.v_send_buf[self.v_send_buf_top] = data
end


function state.newconnect.dispatch(self)
    local data = self.v_sock:pop_msg(2, "big")

    if not data then return end

    log("dispatch:", data)
    local id, key = data:match("([^\n]*)\n([^\n]*)")

    self.v_id = tonumber(id)
    key = crypt.base64decode(key)

    local secret = crypt.dhsecret(key, self.v_clientkey)

    local rc4_key
        = crypt.hmac64_md5(secret, "\0\0\0\0\0\0\0\0")
        ..crypt.hmac64_md5(secret, "\1\0\0\0\0\0\0\0")
        ..crypt.hmac64_md5(secret, "\2\0\0\0\0\0\0\0")
        ..crypt.hmac64_md5(secret, "\3\0\0\0\0\0\0\0")

    self.v_secret = secret
    self.v_rc4_c2s = rc4.rc4(rc4_key)
    self.v_rc4_s2c = rc4.rc4(rc4_key)

    switch_state(self, "forward")

    -- 发送在新连接建立中间缓存的数据包
    for i=1,self.v_send_buf_top do
        self:send(self.v_send_buf[i])
    end
    self.v_send_buf_top = 0
    self.v_send_buf = {}
end


function state.newconnect.dispose(state_self, success, err, status)
    if success then
        return true, nil, "connect"
    else
        err = string.format("sock_error:%s sock_status:%s sconn_state:newconnect", err, status)
        return false, err, "connect"
    end
end

--------------  reconnect state ------------------
function state.reconnect.request(self)
    --id\n
    --index\n
    --recvnumber\n
    --base64(HMAC_CODE)\n
    
    self.v_reconnect_index = self.v_reconnect_index + 1

    local content = string.format("%d\n%d\n%d\n",
        self.v_id,
        self.v_reconnect_index,
        self.v_recvnumber)

    local hmac = crypt.base64encode(crypt.hmac64_md5(crypt.hashkey(content), self.v_secret))
    local data = string.format("%s%s\n", content, hmac)
    data = pack_data(data, 2, "big")

    log("request:", data)

    self.v_sock:send(data)
end


-- 在断线重连期间，仅仅是把数据插入到cache中
function state.reconnect.send(self, data)
    local rc4_c2s = self.v_rc4_c2s
    local cache = self.v_cache
    data = rc4_c2s:crypt(data)

    self.v_sendnumber = self.v_sendnumber + #data
    cache:insert(data)
end


function state.reconnect.dispatch(self)
    local data = self.v_sock:pop_msg(2, "big")

    if not data then return end
    
    log("dispatch:", data)
    local recv,msg = data:match "([^\n]*)\n([^\n]*)"
    recv = tonumber(recv)

    local sendnumber = self.v_sendnumber

    local cb = self.v_reconnect_cb
    self.v_reconnect_cb = nil

    -- 重连失败
    if msg ~= "200" then
        log("msg:", msg)
        if cb then cb(false) end
        switch_state(self, "reconnect_error")
        return
    end

    -- 服务器接受的数据要比客户端记录的发送的数据还要多
    if recv > sendnumber then
        if cb then cb(false) end
        switch_state(self, "reconnect_match_error")
        return
    end

    -- 需要补发的数据
    local nbytes = 0
    if recv < sendnumber then
        nbytes = sendnumber - recv
        local data = self.v_cache:get(nbytes)
        -- 缓存的数据不足
        if not data then
            if cb then cb(false) end
            switch_state(self, "reconnect_cache_error")
            return
        end

        -- 发送补发数据
        assert(#data == nbytes)
        self.v_sock:send(data)
    end

    -- 重连成功
    if cb then cb(true) end
    switch_state(self, "forward")
end


function state.reconnect.dispose(state_self, success, err, status)
    if success then
        return true, nil, "reconnect"
    else
        err = string.format("sock_error:%s sock_status:%s sconn_state:reconnect", err, status)
        return false, err, "reconnect"
    end
end

--------------  forward ------------------
function state.forward.dispatch(self)
    local recv_buf = self.v_recv_buf
    local rc4_s2c = self.v_rc4_s2c
    local sock = self.v_sock
    local count = sock:recv(out)

    for i=1,count do
        local v = out[i]
        self.v_recvnumber = self.v_recvnumber + #v
        v = rc4_s2c:crypt(v)
        recv_buf:push(v)
    end
end

function state.forward.send(self, data)
    local sock = self.v_sock
    local rc4_c2s = self.v_rc4_c2s
    local cache = self.v_cache
    data = rc4_c2s:crypt(data)

    sock:send(data)

    self.v_sendnumber = self.v_sendnumber + #data
    cache:insert(data)
end


function state.forward.dispose(state_self, success, err, status)
    if success then
        if status ~= "forward" then
            errorf("invalid sock_status:%s", status)
        end
        return true, nil, "forward"
    else
        err = string.format("sock_error:%s sock_status:%s sconn_state:forward", err, status)
        return false, err, "forward"
    end
end

--------------  close ------------------
function state.close.dispose(state_self, success, err, status)
    err = string.format("sock_error:%s sock_status:%s sconn_state:close", err, status)
    return false, err, "close"
end


local function connect(host, port)
    local raw = {
        v_state = false,
        v_sock = false,

        v_clientkey = false,
        v_secret  = false,
        v_id = false,

        v_rc4_c2s = false,
        v_rc4_s2c = false,

        v_sendnumber = 0,
        v_recvnumber = 0,
        v_reconnect_index = 0,
        v_cache = cache_create(),

        v_send_buf = {},
        v_send_buf_top = 0,


        v_recv_buf = buffer_queue.create(),
    }

    local sock, err = conn.connect_host(host, port)
    if not sock then
        return nil, err
    end

    raw.v_sock = sock
    local self = setmetatable(raw, {__index = mt})
    switch_state(self, "newconnect")
    return self
end

function mt:cur_state()
    return self.v_state.name
end

function mt:reconnect(cb)
    local state_name = self.v_state.name
    if state_name ~= "forward" and state_name ~= "reconnect" then
        return false, string.format("error state switch `%s` to reconnect", state_name)
    end

    local addr = self.v_sock.o_host_addr
    local port = self.v_sock.o_port

    local success, err = self.v_sock:new_connect(addr, port)
    if not success then
        return false, err
    end

    self.v_reconnect_cb = cb
    switch_state(self, "reconnect")
    return true
end

function mt:flush_send()

end


--[[ 
update 接口现在会返回三个参数 success, err, status

success: boolean类型 表示当前status是否正常
    true: err返回值为nil
    false: err返回值为string，描述错误信息

err: string类型 表示当前status的错误信息，在success 为false才会有效

status: string类型 当前sconn所在的状态，状态只能是:
    "connect": 连接状态
    "forward": 连接成功状态
    "reconnect": 断线重连状态
    "connect_break": 断开连接状态
    "close": 关闭状态
]]

function mt:update()
    local sock = self.v_sock
    local state = self.v_state
    local success, err, status = sock:update()
    local dispatch = state.dispatch
    if success and dispatch then
        dispatch(self)
    end

    -- 网络连接主动断开
    if status == "connect_break" then
        return success, err, status
    end

    -- 处理返回状态值
    success, err, status = state.dispose(state, success, err, status)
    return success ,err, status
end


function mt:send(data)
    local _send = self.v_state.send
    _send(self, data)
    return true
end



function mt:send_msg(data, header_len, endian)
    local _send = self.v_state.send
    header_len = header_len or DEF_MSG_HEADER_LEN
    endian = endian or DEF_MSG_ENDIAN

    data = pack_data(data, header_len, endian)
    _send(self, data)
    return true
end


function mt:recv(out)
    local recv_buf = self.v_recv_buf
    return recv_buf:pop_all(out)
end



function mt:recv_msg(out_msg, header_len, endian)
    header_len = header_len or DEF_MSG_HEADER_LEN
    endian = endian or DEF_MSG_ENDIAN

    local recv_buf = self.v_recv_buf
    return recv_buf:pop_all_block(out_msg, header_len, endian)
end


function mt:close()
    self.v_sock:close()
    self.v_recv_buf:clear()
    switch_state(self, "close")
end

return {
    connect_host = connect,
}


