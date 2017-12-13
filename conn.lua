local socket = require "socket.c"
local buffer_queue = require "buffer_queue"

local OK = 0
local EINTR = socket.EINTR
local EAGAIN = socket.EAGAIN
local EINPROGRESS = socket.EINPROGRESS
local ECONNREFUSED = socket.ECONNREFUSED
local EISCONN = socket.EISCONN

local DEF_MSG_HEADER_LEN = 2
local DEF_MSG_ENDIAN = "little"

local mt = {}

local function conn_error(errcode)
    return socket.strerror(errcode).."["..tostring(errcode).."]"
end

local function resolve(host)
    local addr_tbl, err = socket.resolve(host)
    if not addr_tbl then
        return false, socket.gai_strerror(err).."["..tostring(err).."]"
    end
    return assert(addr_tbl[1])
end


local function connect(addr, port)
    local fd = socket.socket(addr.family, socket.SOCK_STREAM, 0);
    fd:setblocking(false)

    local errcode = fd:connect(addr.addr, port)
    if errcode == OK or
       errcode == EAGAIN or
       errcode == EINPROGRESS or
       errcode == EINTR or 
       errcode == EISCONN  then
       local raw = {
            v_send_buf = buffer_queue.create(),
            v_recv_buf = buffer_queue.create(),
            v_fd = fd,

            o_host_addr = addr,
            o_port = port,
            v_check_connect = true,
       }
       return setmetatable(raw, {__index = mt})
   else
       return nil, conn_error(errcode)
   end
end


local function connect_host(host, port)
    local addr, err = resolve(host)
    if not addr then
        return false, err
    end

    return connect(addr, port)
end

local function _flush_send(self)
    local send_buf = self.v_send_buf
    local v = send_buf:get_head_data()
    local fd = self.v_fd
    local count = 0

    while v do
        local len = #v
        local n, err = fd:send(v)
        if not n then
            if err == EAGAIN or err == EINTR then
                break
            end
            return false, conn_error(err)
        else
            count = count + n
            send_buf:pop(n)
            if n < len then
                break
            end
        end
        v = send_buf:get_head_data()
    end
    return count
end


local function _flush_recv(self)
    local recv_buf = self.v_recv_buf
    local fd = self.v_fd
    local count = 0

    while true do
    ::CONTINUE::
        local data, err = fd:recv()
        if not data then
            if err == EAGAIN or err == 0 then
                return true
            elseif err == EINTR then
                goto CONTINUE
            else
                return false, conn_error(err)
            end
        elseif #data == 0 then
            return false, "connect_break"
        else
            local len = #data
            count = count + len
            recv_buf:push(data)
            break
        end
    end

    return count
end

local function _check_connect(self)
    local fd = self.v_fd
    if not fd then
        return false, 'fd is nil'
    end

    if self.v_check_connect then
        local success, err = fd:check_async_connect()
        if not success then
            return false, err and conn_error(err) or "connecting"
        else
            self.v_check_connect = false
            return true
        end
    else
        return true
    end
end



function mt:send_msg(data, header_len, endian)
    local send_buf = self.v_send_buf
    header_len = header_len or DEF_MSG_HEADER_LEN
    endian = endian or DEF_MSG_ENDIAN

    send_buf:push_block(data, header_len, endian)
end



function mt:recv_msg(out_msg, header_len, endian)
    local recv_buf = self.v_recv_buf
    header_len = header_len or DEF_MSG_HEADER_LEN
    endian = endian or DEF_MSG_ENDIAN

    return recv_buf:pop_all_block(out_msg, header_len, endian)
end

function mt:pop_msg(header_len, endian)
    local recv_buf = self.v_recv_buf
    header_len = header_len or DEF_MSG_HEADER_LEN
    endian = endian or DEF_MSG_ENDIAN

    return recv_buf:pop_block(header_len, endian)
end


function mt:send(data)
   self.v_send_buf:push(data)
end



function mt:recv(out)
    local recv_buf = self.v_recv_buf
    return recv_buf:pop_all(out)
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
    "recv": 接受状态数据状态
    "send": 发送数据状态
    "close": 关闭状态
]]

function mt:update()
    local fd = self.v_fd
    if not fd then
        return false, "fd is nil", "close"
    end

    local success, err = _check_connect(self)
    if not success then
        if err == "connecting" then
            return true, nil, "connect"
        else
            return false, err, "connect"
        end
    end

    success, err = _flush_send(self)
    if not success then
        return false, err, "send"
    end

    success, err = _flush_recv(self)
    if not success then
        if err == "connect_break" then
            return false, "connect break", "connect_break"
        else
            return false, err, "recv"
        end
    end

    return true, nil, "forward"
end


function mt:flush_send()
    local count = false
    repeat
        count = _flush_send(self)
    until not count or count == 0
end

function mt:getsockname()
    return self.v_fd:getsockname()
end


function mt:new_connect(addr, port)
    local fd = socket.socket(addr.family, socket.SOCK_STREAM, 0)
    fd:setblocking(false)

    local errcode = fd:connect(addr.addr, port)
    if errcode == OK or
       errcode == EAGAIN or
       errcode == EINPROGRESS or
       errcode == EINTR or 
       errcode == EISCONN  then
       self.v_fd:close()
       self.v_recv_buf:clear()
       self.v_send_buf:clear()
       self.v_fd = fd
       self.o_host_addr = addr
       self.o_port = port
       self.v_check_connect = true
       return true
    else
        return false, conn_error(errcode)
    end
end

function mt:close()
    self:flush_send()
    self.v_fd:close()
    self.v_fd = nil
    self.v_check_connect = true
end


return {
    resolve = resolve,
    connect = connect,
    connect_host = connect_host,
}
