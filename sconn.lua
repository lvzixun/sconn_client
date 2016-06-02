local conn = require "conn"
local socket = require "socket.c"
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

function cache_mt:pop(nbytes)
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
            cache[i] = string.sub(v, 1, pos)
            n = sub_n
            vv = sub_v
        else
            cache[i] = nil
        end
        table.insert(ret, 1, vv)
        count = count + n
        i = i-1
    end

    self.size = self.size - nbytes
    return table.concat(ret)
end


function cache_mt:clear()
    self.size = 0
    self.top = 0
end

-------------- state ------------------

local state = {
    newconnect = {
        name = "newconnect",
        request = false,
        dispatch = false,
        send = false,
    },

    reconnect = {
        name = "reconnect",
        request = false,
        dispatch = false,
        send = false,
    },

    forward = {
        name = "forward",
        request = false,
        dispatch = false,
        send = false,
    },

    reconnect_error = {
        name = "reconnect_error",
    },

    reconnect_match_error = {
        name = "reconnect_match_error",
    },

    reconnect_cache_error = {
        name = "reconnect_cache_error",
    },

    close = {
        name = "close",
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
    local count = self.v_sock:recv_msg(out, 2, "big")

    if count<=0 then return end

    assert(count==1)
    local data = out[1]
    log("dispatch:", data)
    local id, key = data:match("([^\n]*)\n([^\n]*)")

    self.v_id = tonumber(id)
    key = crypt.base64decode(key)

    local secret = crypt.dhsecret(key, self.v_clientkey)

    local rc4_key
        = crypt.hmac64(secret, "\0\0\0\0\0\0\0\0")
        ..crypt.hmac64(secret, "\1\0\0\0\0\0\0\0")
        ..crypt.hmac64(secret, "\2\0\0\0\0\0\0\0")
        ..crypt.hmac64(secret, "\3\0\0\0\0\0\0\0")

    self.v_secret = secret
    self.v_rc4_c2s = rc4.rc4(rc4_key)
    self.v_rc4_s2c = rc4.rc4(rc4_key)

    switch_state(self, "forward")

    -- 发送在新连接建立中间缓存的数据包
    for i=1,self.v_send_buf_top do
        self:send(self.v_send_buf[i])
    end
    self.v_send_buf_top = 0
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

    local hmac = crypt.base64encode(crypt.hmac64(crypt.hashkey(content), self.v_secret))
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
    local count = self.v_sock:recv_msg(out, 2, "big")

    if count<=0 then return end

    assert(count==1)
    local data = out[1]
    log("dispatch:", data)
    local recv,msg = data:match "([^\n]*)\n([^\n]*)"
    recv = tonumber(recv)

    local sendnumber = self.v_sendnumber

    -- 重连失败
    if msg ~= "200" then
        log("msg:", msg)
        switch_state(self, "reconnect_error")

    -- 服务器接受的数据要比客户端记录的发送的数据还要多
    elseif recv>sendnumber then
        switch_state(self, "reconnect_match_error")

    -- 需要补发的数据
    elseif recv < sendnumber then 
        local nbytes = sendnumber - recv
        local data = self.v_cache:pop(nbytes)
        -- 缓存的数据不足
        if not data then
            switch_state(self, "reconnect_cache_error")
        else
            assert(#data == nbytes)
            self.v_sock:send(data)
            switch_state(self, "forward")
        end

    -- 不需要补发
    else
        switch_state(self, "forward")
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
        v_dispatch = _newconnect_dispatch,
        v_send = _newconnect_send,
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

function mt:reconnect()
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

    switch_state(self, "reconnect")
    return true
end



function mt:update()
    local sock = self.v_sock
    local state = self.v_state
    local state_name = state.name

    if state_name == "reconnect_error" or 
       state_name == "reconnect_match_error" or 
       state_name == "reconnect_cache_error" then
        return false, state_name, "reconnect"
    end

    local success, err, status = sock:update()
    local dispatch = state.dispatch
    if success and dispatch then
        dispatch(self)
    end

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


