local buff_queue = require "buffer_queue"
local socket = require "socket.c"
local sleep = socket.sleep

local EAGAIN = socket.EAGAIN

local sock, errcode = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
assert(socket, errcode)

local ok, errcode = sock:bind('127.0.0.1', 9527)
assert(ok, errcode)

sock:listen()
print("begin accept...")


local function sendall(fd, data)
    local len = #data
    local count = fd:send(data)

    print("send:", data, "len:", #data)

    while count < len do
        local n = fd:send(data, count)
        count = count + n
    end
end


while true do 
    local csock, err = sock:accept()
    csock:setblocking(false)

    assert(csock, err)
    local info = csock:getsockname()
    print("accept from:", info)
    local recv_buf = buff_queue.create()

    local count = 0
    while true do 
        count =  count + 1

        local data, errno = csock:recv()
        print("recv: ", data, "len:", data and #data or 0)
        if data and data=="" then
            print("break: ", info)
            csock:close()
            break
        end

        local s = "hello_"..(count)
        sendall(csock, s)

        sleep(1)
    end
end




