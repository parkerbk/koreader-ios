--[[--
Diagnostic log for an iOS crash we haven't been able to reproduce: in build 12
the app crashed in the background because Lua's memory had been damaged at
some earlier point, and the crash report can't say by what.

Writes what the app does to KO_HOME/background.log, which shows in the Files
app: going to the background and back, each scheduled task it runs, inline
"subprocesses", and settings flushes. It also runs a full garbage collection
at each of those steps and every two minutes, so damage makes the app crash
near whatever caused it, and the last lines of the log name it.

Remove once that crash is found.
]]

local ffi = require("ffi")

local IOSLog = {}

local path = (os.getenv("KO_HOME") or ".") .. "/background.log"
local max_size = 512 * 1024
local file

local function open()
    file = io.open(path, "a")
    -- Unbuffered: the app dies on the spot, and anything still buffered is lost.
    if file then file:setvbuf("no") end
end

local function inBackground()
    return ffi.C.ko_ios_in_background() ~= 0
end

function IOSLog.log(fmt, ...)
    if not file then
        open()
        if not file then return end
    end
    file:write(os.date("%H:%M:%S "), inBackground() and "[bg] " or "", string.format(fmt, ...), "\n")
    if file:seek("end") > max_size then
        -- Keep the previous part, so a crash right after this still has history.
        file:close()
        os.rename(path, path .. ".1")
        open()
    end
end

--- Where a function was defined, which is how tasks are told apart.
function IOSLog.describe(func)
    if type(func) ~= "function" then return tostring(func) end
    local info = debug.getinfo(func, "S")
    return string.format("%s:%d", info.short_src, info.linedefined)
end

function IOSLog.collect(why)
    IOSLog.log("gc start (%s) %d KB", why, collectgarbage("count"))
    local start = os.clock()
    collectgarbage()
    IOSLog.log("gc done %d KB, %d ms cpu", collectgarbage("count"), (os.clock() - start) * 1000)
end

function IOSLog.start(UIManager)
    local version = require("version"):getCurrentRevision()
    IOSLog.log("==== launch %s %s", os.date("%Y-%m-%d"), version or "")

    local function periodic()
        IOSLog.collect("every 2 min")
        UIManager:scheduleIn(120, periodic)
    end
    UIManager:scheduleIn(120, periodic)

    -- UIManager:_checkTasks, logging each task before it runs: if one damages
    -- memory, the next collection crashes, and this is the trail back to it.
    local time = require("ui/time")
    local describe = IOSLog.describe
    -- Polls and watchers run every few seconds or faster; a line per run would
    -- push everything else out of the log. Log each at most every 30 seconds,
    -- with how often it ran since; every 5 in the background, which is short.
    local last_logged, runs = {}, {}
    local function logTask(action)
        local where = describe(action)
        local now = os.time()
        local every = inBackground() and 5 or 30
        runs[where] = (runs[where] or 0) + 1
        if not last_logged[where] or now - last_logged[where] >= every then
            IOSLog.log(runs[where] > 1 and "task %s (ran %d times)" or "task %s", where, runs[where])
            last_logged[where] = now
            runs[where] = 0
        end
    end
    UIManager._checkTasks = function(self)
        self._now = time.now()
        local wait_until = nil
        self._task_queue_dirty = false
        while self._task_queue[1] do
            local task_time = self._task_queue[#self._task_queue].time
            if task_time <= self._now then
                local task = table.remove(self._task_queue)
                logTask(task.action)
                task.action(unpack(task.args, 1, task.args.n))
            else
                wait_until = task_time
                break
            end
        end
        return wait_until, self._now
    end
end

return IOSLog
