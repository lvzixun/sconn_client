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


local function resolve(host)
    local addr_tbl, err = socket.resolve(host)
    if not addr_tbl then
        return false, socket.gai_strerror(err)
    end
    return assert(addr_tbl[1])
end


local function connect(addr, port)
    local fd = socket.socket(addr.family, socket.SOCK_STREAM, 0);
    fd:setblocking(false)

    local errcode = fd:connect(addr.addr, port)
    if errcode == OK or
       errcode == EINPROGRESS or
       errcode == EINTR or 
       errcode == EISCONN  then
       local raw = {
            v_send_buf = buffer_queue.create(),
            v_recv_buf = buffer_queue.create(),
            v_fd = fd,

            o_host_addr = addr,
            o_port = port,
       }
       return setmetatable(raw, {__index = mt})
   else
        return nil, socket.strerror(errcode)
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
            return false, socket.strerror(err)
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
            if err == EAGAIN then
                return true
            elseif err == EINTR then
                goto CONTINUE
            else
                return false, socket.strerror(err)
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
    local success, err = fd:check_async_connect()
    if not success then
        return false, err and socket.strerror(err) or "connecting"
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



function mt:send(data)
   self.v_send_buf:push(data)
end



function mt:recv(out)
    local recv_buf = self.v_recv_buf
    return recv_buf:pop_all(out)
end



function mt:update()
    local success, err = _check_connect(self)
    if not success then
        return false, err
    end

    success, err = _flush_send(self)
    if not success then
        return false, err
    end

    success, err = _flush_recv(self)
    if not success then
        return false, err
    end

    return true
end


function mt:new_connect(addr, port)
    self.v_fd:close()
    self.v_recv_buf:clear()
    self.v_send_buf:clear()

    local fd = socket.socket(addr.family, socket.SOCK_STREAM, 0)
    fd:setblocking(false)

    local errcode = fd:connect(addr.addr, port)
    if errcode == OK or
       errcode == EINPROGRESS or
       errcode == EINTR or 
       errcode == EISCONN  then
       self.v_fd = fd
       self.o_host_addr = addr
       self.o_port = port
       return true
    else
        return false, socket.strerror(errcode)
    end
end

function mt:close()
    self.v_fd:close()
    self.v_fd = nil
end


return {
    resolve =resolve,
    connect = connect,

    connect_host = connect_host,
}
