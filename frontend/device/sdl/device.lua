local Event = require("ui/event")
local Geom = require("ui/geometry")
local Gamepad = require("device/sdl/gamepad")
local Generic = require("device/generic/device")
local Key = require("device/key")
local UIManager
local SDL = require("ffi/SDL3")
local ffi = require("ffi")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")

-- SDL computes WM_CLASS on X11/Wayland based on process's binary name.
-- Some desktop environments rely on WM_CLASS to name the app and/or to assign the proper icon.
if jit.os == "Linux" or jit.os == "BSD" or jit.os == "POSIX" then
    if not os.getenv("SDL_VIDEO_WAYLAND_WMCLASS") then ffi.C.setenv("SDL_VIDEO_WAYLAND_WMCLASS", "KOReader", 1) end
    if not os.getenv("SDL_VIDEO_X11_WMCLASS") then ffi.C.setenv("SDL_VIDEO_X11_WMCLASS", "KOReader", 1) end
end

local function yes() return true end
local function no() return false end
local function notOSX() return jit.os ~= "OSX" end
-- Set by platform/ios/ios_loader.m. iOS is a pure touch device: it has no
-- physical keyboard, so Menu must not draw the per-item shortcut letters
-- (a/s/d/w...) that Menu gates on Device:hasKeyboard().
local isIOS = os.getenv("KO_IOS") == "1"

local function isUrl(s)
    return type(s) == "string" and s:match("*?://")
end

local function isCommand(s)
    return os.execute("command -v "..s.." >/dev/null") == 0
end

local function runCommand(command)
    return os.execute(command) == 0
end

local function getDesktopDicts()
    local t = {
        { "Goldendict", "Goldendict", false, "goldendict" },
    }
    -- apple dict is always present in osx
    if jit.os == "OSX" then
        table.insert(t, 1, { "Apple", "AppleDict", false, "dict://" })
    end
    return t
end

local function getLinkOpener()
    if jit.os == "Linux" and isCommand("xdg-open") then
        return true, "xdg-open"
    elseif jit.os == "OSX" and isCommand("open") then
        return true, "open"
    end
    return false
end

-- third-party app support
local external = require("device/thirdparty"):new{
    dicts = getDesktopDicts(),
    check = function(self, app)
        if (isUrl(app) and getLinkOpener()) or isCommand(app) then
            return true
        end
        return false
    end,
}

local Device = Generic:extend{
    model = "SDL",
    isSDL = yes,
    home_dir = os.getenv("XDG_DOCUMENTS_DIR") or os.getenv("HOME"),
    hasBattery = SDL.getPowerInfo,
    hasKeyboard = isIOS and no or yes,
    hasKeys = yes,
    hasSymKey = os.getenv("DISABLE_TOUCH") == "1" and yes or no,
    hasDPad = yes,
    useDPadAsActionKeys = os.getenv("DISABLE_TOUCH") == "1" and yes or no,
    supportsGamepad = yes,
    hasWifiToggle = no,
    hasSeamlessWifiToggle = no,
    isTouchDevice = yes,
    isDefaultFullscreen = no,
    needsScreenRefreshAfterResume = no,
    hasColorScreen = yes,
    hasEinkScreen = no,
    hasSystemFonts = yes,
    canSuspend = no,
    canStandby = no,
    -- On iOS, SDL_StartTextInput pops up the system keyboard, which replaces
    -- KOReader's own VirtualKeyboard (see Device:hidesVirtualKeyboard).
    hasSystemKeyboard = isIOS and yes or no,
    hasNativeMenu = isIOS and yes or no,
    hasNativeDictionary = isIOS and yes or no,
    canRequestLocation = isIOS and yes or no,
    startTextInput = function(self)
        self.text_input_started = true
        SDL.startTextInput()
    end,
    stopTextInput = function(self)
        self.text_input_started = false
        SDL.stopTextInput()
    end,
    canOpenLink = getLinkOpener,
    openLink = function(self, link)
        local enabled, tool = getLinkOpener()
        if not enabled or not tool or not link or type(link) ~= "string" then return end
        return runCommand(util.shell_escape{tool, link})
    end,
    canExternalDictLookup = yes,
    getExternalDictLookupList = function() return external.dicts end,
    doExternalDictLookup = function(self, text, method, callback)
        external.when_back_callback = callback
        local ok, app = external:checkMethod("dict", method)
        if app then
            if isUrl(app) and getLinkOpener() then
                ok = self:openLink(app..text)
            elseif isCommand(app) then
                ok = runCommand(util.shell_escape{app, text} .. " &")
            end
        end
        if ok and external.when_back_callback then
            external.when_back_callback()
            external.when_back_callback = nil
        end
    end,
    window = G_reader_settings:readSetting("sdl_window", {}),
}

function Device:hasKeyboardTextInput()
    return true
end

local AppImage = Device:extend{
    model = "AppImage",
    hasOTAUpdates = yes,
    isDesktop = yes,
}

function AppImage:otaModel()
    local arch = jit.arch
    local model
    if arch == "arm64" then
        model = "appimage-aarch64"
    elseif arch == "arm" then
        model = "appimage-armhf"
    elseif arch == "x64" then
        model = "appimage-x86_64"
    end
    return model, "link"
end

local Desktop = Device:extend{
    model = SDL.getPlatform(),
    isDesktop = yes,
    canRestart = notOSX,
    hasExitOptions = notOSX,
}

local Flatpak = Device:extend{
    model = "Flatpak",
    isDesktop = yes,
    canExternalDictLookup = no,
}

local Emulator = Device:extend{
    model = "Emulator",
    isEmulator = yes,
    hasBattery = yes,
    hasEinkScreen = isIOS and no or yes,
    hasFrontlight = isIOS and no or yes,
    hasNaturalLight = isIOS and no or yes,
    hasNaturalLightApi = isIOS and no or yes,
    hasWifiToggle = yes,
    -- Not really, Device:reboot & Device:powerOff are not implemented, so we just exit ;).
    canPowerOff = yes,
    canReboot = yes,
    -- NOTE: Via simulateSuspend, which on iOS would only leave a "Sleeping" screen
    -- that nothing can dismiss: iOS handles sleep itself.
    canSuspend = isIOS and no or yes,
    canStandby = no,
}

local UbuntuTouch = Device:extend{
    model = "UbuntuTouch",
    hasFrontlight = yes,
    isDefaultFullscreen = yes,
}

if isIOS then
    ffi.cdef[[
        void ko_ios_get_window_pixels(int *out_w, int *out_h);
        void ko_ios_end_editing(void);
        bool ko_ios_is_phone(void);
        double ko_ios_get_screen_scale(void);
        void ko_ios_fit_root_view(void);
        void ko_ios_location_start(void);
        int ko_ios_location_poll(double *latitude, double *longitude, double *altitude, int *has_altitude);
    ]]

    function Device:readIOSWindowPixels()
        local w, h = ffi.new("int[1]"), ffi.new("int[1]")
        ffi.C.ko_ios_get_window_pixels(w, h)
        return tonumber(w[0]), tonumber(h[0])
    end

    --- The window's size, or its last usable one while it's too small to lay
    -- anything out in: entering Split View can pass through an empty window,
    -- and widgets raise an error at that size, which ends the app.
    function Device:getIOSWindowPixels()
        local w, h = self:readIOSWindowPixels()
        local min_size = 200 * ffi.C.ko_ios_get_screen_scale()
        if self.ios_window_w and (w < min_size or h < min_size) then
            return self.ios_window_w, self.ios_window_h
        end
        self.ios_window_w, self.ios_window_h = w, h
        return w, h
    end

    ffi.cdef[[
        bool SDL_SetRenderLogicalPresentation(SDL_Renderer *renderer, int w, int h, int mode);
    ]]

    --- Two columns on the iPhone Duo's inner screen in landscape, one otherwise.
    -- The Duo is told apart by its screen sizes: the short side of its cover
    -- screen is 466 points and of its inner screen 669, past any other iPhone's.
    function Device:getAutoVisiblePages()
        if not ffi.C.ko_ios_is_phone() then return end
        local w, h = self:getIOSWindowPixels()
        local short_side = math.min(w, h) / ffi.C.ko_ios_get_screen_scale()
        -- (Once it's known to be a Duo, any size can be the cover screen.)
        if short_side < 450 and not self.is_duo then return end
        self.is_duo = true
        return (short_side >= 600 and w > h) and 2 or 1
    end

    ffi.cdef[[
        void ko_ios_get_font_dirs(char *out, size_t cap);
    ]]

    function Device:getIOSFontDirs()
        local cap = 64 * 1024
        local dirs = ffi.new("char[?]", cap)
        ffi.C.ko_ios_get_font_dirs(dirs, cap)
        return ffi.string(dirs)
    end

    ffi.cdef[[
        void ko_ios_dictionary_show(const char *term);
        bool ko_ios_dictionary_is_open(void);
    ]]

    --- Looks a word up in iOS's own dictionary, which stands in for sdcv: iOS
    -- can't run that, and its dictionaries are set up in that same sheet.
    function Device:doExternalDictLookup(text, _method, callback)
        local UIManager = require("ui/uimanager")
        if not text or text == "" then
            if callback then callback() end
            return
        end
        ffi.C.ko_ios_dictionary_show(text)
        local function poll()
            if ffi.C.ko_ios_dictionary_is_open() then
                UIManager:scheduleIn(0.2, poll)
            elseif callback then
                callback()
            end
        end
        poll()
    end

    --- Asks iOS for the device's location, prompting for permission if needed.
    -- Calls back with (latitude, longitude, altitude or nil) or (nil, nil, nil, error),
    -- where error is "denied" or "failed".
    function Device:requestLocation(callback)
        local UIManager = require("ui/uimanager")
        local latitude, longitude = ffi.new("double[1]"), ffi.new("double[1]")
        local altitude, has_altitude = ffi.new("double[1]"), ffi.new("int[1]")
        ffi.C.ko_ios_location_start()
        local function poll()
            local state = ffi.C.ko_ios_location_poll(latitude, longitude, altitude, has_altitude)
            if state == 0 then
                UIManager:scheduleIn(0.2, poll)
            elseif state == 1 then
                callback(latitude[0], longitude[0], has_altitude[0] ~= 0 and altitude[0] or nil)
            else
                callback(nil, nil, nil, state == 2 and "denied" or "failed")
            end
        end
        poll()
    end
end

function Device:init()
    -- allows to set a viewport via environment variable
    -- syntax is Lua table syntax, e.g. EMULATE_READER_VIEWPORT="{x=10,w=550,y=5,h=790}"
    local viewport = os.getenv("EMULATE_READER_VIEWPORT")
    if viewport then
        self.viewport = require("ui/geometry"):new(loadstring("return " .. viewport)())
    end

    local touchless = os.getenv("DISABLE_TOUCH") == "1"
    if touchless then
        self.isTouchDevice = no
    end

    local portrait = os.getenv("EMULATE_READER_FORCE_PORTRAIT")
    if portrait then
        self.isAlwaysPortrait = yes
    end

    self.hasClipboard = yes
    self.screen = require("ffi/framebuffer_SDL3"):new{
        device = self,
        debug = logger.dbg,
        w = self.window.width,
        h = self.window.height,
        x = self.window.left,
        y = self.window.top,
        is_always_portrait = self.isAlwaysPortrait(),
    }
    -- Pickup the updated window sizes if they were enforced in S.open (we'll get the coordinates via the initial SDL_WINDOWEVENT_MOVED)...
    self.window.width = self.screen.w
    self.window.height = self.screen.h
    self.powerd = require("device/sdl/powerd"):new{device = self}

    if isIOS then
        -- Native helper in platform/ios/ios_filepicker.m: SDL3 doesn't queue
        -- app lifecycle events, this re-posts them so the EV_SDL handlers
        -- below (flush on background, repaint on foreground) actually run.
        ffi.cdef[[
            void ko_ios_install_lifecycle_watch(void);
            void ko_ios_set_inline_child(int on);
        ]]
        ffi.C.ko_ios_install_lifecycle_watch()

        -- No fork() on iOS: runInSubProcess runs the child inline, in our
        -- process. Children that end with os.exit() or ffi.C._exit() (e.g.
        -- Readest's sync workers) would then quit the whole app without
        -- saving anything; make both just end the child instead. See
        -- platform/ios/ios_exit.c for the _exit side.
        local ffiUtil = require("ffi/util")
        local runInSubProcess = ffiUtil.runInSubProcess
        ffiUtil.runInSubProcess = function(func, ...)
            local wrapped = function(...)
                local os_exit = os.exit
                os.exit = function() end -- luacheck: ignore 122
                ffi.C.ko_ios_set_inline_child(1)
                local ok, err = pcall(func, ...)
                ffi.C.ko_ios_set_inline_child(0)
                os.exit = os_exit -- luacheck: ignore 122
                if not ok then error(err, 0) end
            end
            return runInSubProcess(wrapped, ...)
        end
    end

    local ok, re = pcall(self.screen.setWindowIcon, self.screen, "resources/koreader.png")
    if not ok then logger.warn(re) end

    local function makeKeyPressEvent(keycode)
        if not keycode then
            return nil
        end
        return Event:new("KeyPress", Key:new(keycode, {}))
    end

    local function dispatchGamepadAxisMotion(axis, value, event_time)
        local axis_ev = {
            axis = axis,
            value = value,
            time = event_time,
        }
        if not UIManager:broadcastEvent(Event:new("GamepadAxisMotion", axis_ev)) then
            local key_ev = makeKeyPressEvent(Gamepad:getAxisKeyName(axis, value))
            if key_ev then
                UIManager:sendEvent(key_ev)
            end
        end
    end

    local function unscheduleAxisRepeat(clear_state)
        if self._axis_repeat_action then
            UIManager:unschedule(self._axis_repeat_action)
            self._axis_repeat_action = nil
        end
        if clear_state ~= false then
            Gamepad:clearRepeatingAxis()
        end
    end

    local function scheduleAxisRepeat(axis, delay_s)
        unscheduleAxisRepeat(false)
        Gamepad:setRepeatingAxis(axis)
        self._axis_repeat_action = function()
            local axis_ev = Gamepad:getHeldAxisEvent()
            if not axis_ev then
                Gamepad:clearRepeatingAxis()
                self._axis_repeat_action = nil
                return
            end
            dispatchGamepadAxisMotion(axis_ev.axis, axis_ev.value, time.now())
            UIManager:scheduleIn(Gamepad.axis_repeat_interval_s, self._axis_repeat_action)
        end
        UIManager:scheduleIn(delay_s, self._axis_repeat_action)
    end

    self.input = require("device/input"):new{
        device = self,
        event_map = dofile("frontend/device/sdl/event_map_sdl2.lua"),
        handleSdlEv = function(device_input, ev)

            if ev.code == SDL.SDL.SDL_EVENT_MOUSE_WHEEL and (ev.value.integer_x ~= 0 or ev.value.integer_y ~= 0) then
                local pos = Geom:new{
                    x = 0,
                    y = 0,
                    w = 0, h = 0,
                }

                local fake_ges = {
                    ges = "pan",
                    distance = 200,
                    relative = {
                        x = 50 * ev.value.integer_x,
                        y = 100 * ev.value.integer_y,
                    },
                    pos = pos,
                    time = time.timeval(ev.time),
                    mousewheel_direction = ev.value.integer_y,
                    direction = ev.value.integer_y > 0 and "south" or "north"
                }
                local fake_ges_release = {
                    ges = "pan_release",
                    distance = fake_ges.distance,
                    relative = fake_ges.relative,
                    pos = pos,
                    time = time.timeval(ev.time),
                    from_mousewheel = true,
                }
                local fake_pan_ev = Event:new("Pan", nil, fake_ges)
                local fake_release_ev = Event:new("Gesture", fake_ges_release)
                UIManager:sendEvent(fake_pan_ev)
                UIManager:sendEvent(fake_release_ev)
            elseif ev.code == SDL.SDL.SDL_EVENT_DROP_FILE then
                local dropped_file_path = ev.value
                if dropped_file_path and dropped_file_path ~= "" then
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:doShowReader(dropped_file_path)
                end
            elseif ev.code == SDL.SDL.SDL_EVENT_WINDOW_RESIZED then
                self:onWindowResized(ev.value.data1, ev.value.data2, device_input)
            elseif ev.code == SDL.SDL.SDL_EVENT_WINDOW_MOVED then
                self.window.left = ev.value.data1
                self.window.top = ev.value.data2
            elseif ev.code == SDL.SDL.SDL_EVENT_GAMEPAD_AXIS_MOTION then
                local should_process = Gamepad:shouldProcessAxisMotion(ev.value.axis, ev.value.value)
                local held_direction = Gamepad:getHeldDirection(ev.value.axis)

                if not held_direction then
                    if Gamepad.repeating_axis == ev.value.axis then
                        unscheduleAxisRepeat()
                    end
                    return
                end

                if should_process then
                    scheduleAxisRepeat(ev.value.axis, Gamepad.axis_repeat_delay_s)
                    dispatchGamepadAxisMotion(ev.value.axis, ev.value.value, time.timeval(ev.time))
                end
                return
            elseif ev.code == SDL.SDL.SDL_EVENT_GAMEPAD_BUTTON_DOWN then
                -- Broadcast for plugins; if not handled, emit default key events
                if not UIManager:broadcastEvent(Event:new("GamepadButtonDown", ev.value)) then
                    return makeKeyPressEvent(Gamepad:getButtonKeyName(ev.value.button))
                end
            elseif ev.code == SDL.SDL.SDL_EVENT_GAMEPAD_BUTTON_UP then
                UIManager:broadcastEvent(Event:new("GamepadButtonUp", ev.value))
            elseif ev.code == SDL.SDL.SDL_EVENT_TEXT_INPUT then
                UIManager:sendEvent(Event:new("TextInput", tostring(ev.value)))
            elseif ev.code == SDL.SDL.SDL_EVENT_DID_ENTER_FOREGROUND then
                -- iOS resume: SDL3's renderer/texture state may have
                -- been invalidated while we were backgrounded — the
                -- last frame is still on-screen but stale, and any
                -- new bb writes are going into a texture that won't
                -- composite. Force a full repaint to re-establish
                -- the texture and present.
                UIManager:setDirty("all", "full")
            elseif ev.code == SDL.SDL.SDL_EVENT_WILL_ENTER_BACKGROUND
                    or ev.code == SDL.SDL.SDL_EVENT_DID_ENTER_BACKGROUND
                    or ev.code == SDL.SDL.SDL_EVENT_TERMINATING then
                -- iOS: a backgrounded app gets killed without notice (memory
                -- pressure, swipe-away from the app switcher, reinstall), so
                -- there's no clean exit to save on. Flush like we would before
                -- a suspend, or recent settings (reading position, plugin
                -- logins...) are lost. WILL_ENTER_BACKGROUND is the one that
                -- matters for a swipe-away: the app is killed while inactive.
                logger.info("iOS lifecycle event", ev.code, "- flushing settings")
                UIManager:flushSettings()
                -- FileManager/ReaderUI flush the global settings on that event,
                -- but a fullscreen plugin view may have replaced both.
                G_reader_settings:flush()
            end
        end,
    }

    self.keyboard_layout = dofile("frontend/device/sdl/keyboard_layout.lua")

    if self.input.gameControllerRumble(0, 0, 0) then
        self.isHapticFeedbackEnabled = yes
        self.performHapticFeedback = function(type)
            self.input.gameControllerRumble()
        end
    end

    if portrait then
        self.input:registerEventAdjustHook(
            self.input.adjustTouchSwitchAxesAndMirrorX,
            (self.screen:getScreenWidth() - 1)
        )
    end

    Generic.init(self)
end

--- Has SDL's renderer pick up the window's size.
-- It only does so on a resize event, and SDL drops those once its own idea of
-- the window's size agrees, which leaves the renderer clipping at the old size.
-- Setting the logical presentation is the one public way to make it update.
function Device:refreshIOSRenderer()
    ffi.C.ko_ios_fit_root_view()
    SDL.SDL.SDL_SetRenderLogicalPresentation(SDL.renderer, 0, 0, 0) -- SDL_LOGICAL_PRESENTATION_DISABLED
end

--- Resizes the framebuffer to the size UIKit reports for the window.
-- screen.resize() can't be used here: during a rotation the size it's given and
-- the renderer's size it prefers are each out of date in one direction.
function Device:resizeIOSScreen()
    local w, h = self:getIOSWindowPixels()
    local scale = ffi.C.ko_ios_get_screen_scale()
    SDL.win_w = w / scale
    SDL.win_h = h / scale
    SDL.applyIOSSafeArea(w, h)
    self:refreshIOSRenderer()
    self.screen:_newBB(SDL.w, SDL.h)
    SDL.destroyTexture(SDL.texture)
    SDL.texture = SDL.createTexture(SDL.w, SDL.h)
    self.screen.bb:fill(require("ffi/blitbuffer").COLOR_WHITE)
    self.screen:refreshFull(0, 0, self.screen:getWidth(), self.screen:getHeight())
end

function Device:onWindowResized(w, h, device_input)
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    if isIOS then
        self:resizeIOSScreen()
    else
        device_input.device.screen.resize(device_input.device.screen, w, h)
    end
    self.window.width = w or SDL.win_w
    self.window.height = h or SDL.win_h

    local new_size = device_input.device.screen:getSize()
    device_input.device.screen.screen_size.w = new_size.w
    device_input.device.screen.screen_size.h = new_size.h

    logger.dbg("Resizing screen to", new_size)

    -- try to catch as many flies as we can
    -- this means we can't just return one ScreenResize or SetDimensons event
    UIManager:broadcastEvent(Event:new("SetDimensions", new_size))
    UIManager:broadcastEvent(Event:new("ScreenResize", new_size))
    --- @todo Toggle this elsewhere based on ScreenResize?

    -- this triggers paged media like PDF and DjVu to redraw
    -- CreDocument doesn't need it
    UIManager:broadcastEvent(Event:new("RedrawCurrentPage"))

    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:reinit(FileManager.instance.path,
            FileManager.instance.focused_file)
    end

    -- make sure dialogs are displayed
    UIManager:setDirty("all", "ui")

    if isIOS then
        -- UIKit only settles on the new size and safe area once the rotation
        -- is done, after this event.
        UIManager:unschedule(self.window_size_check)
        UIManager:scheduleIn(0.5, self.window_size_check)
    end
end

--- Settles the layout once a rotation is done: lays out again if the size or
-- safe area turned out different, and otherwise has the renderer catch up.
function Device:checkIOSWindowSize()
    -- SDL's hidden text field can take focus back during a rotation.
    if not self.text_input_started then
        ffi.C.ko_ios_end_editing()
    end
    local pixel_w, pixel_h = self:getIOSWindowPixels()
    if SDL.applyIOSSafeArea(pixel_w, pixel_h) then
        self:onWindowResized(nil, nil, self.input)
    else
        self:refreshIOSRenderer()
        self.screen:refreshFull(0, 0, self.screen:getWidth(), self.screen:getHeight())
    end
end

--- SDL drops a rotation's resize event if it thinks the size hasn't changed, and
-- a fold can settle its safe area well after the resize, so nothing else would
-- tell us about either.
function Device:watchIOSWindowSize()
    local pixel_w, pixel_h = self:getIOSWindowPixels()
    if SDL.applyIOSSafeArea(pixel_w, pixel_h) then
        self:onWindowResized(nil, nil, self.input)
    end
    UIManager:scheduleIn(2, self.window_size_watch)
end

--- How far a touch can move before it's a pan, which also cancels a hold.
-- Fingers wobble by points, not pixels, so this has to follow the screen's
-- scale: on a 3x phone the default is under 12 points, which a thumb often
-- exceeds while holding still.
function Device:getPanThreshold()
    if isIOS then
        return 20 * ffi.C.ko_ios_get_screen_scale()
    end
end

function Device:setDateTime(year, month, day, hour, min, sec)
    if hour == nil or min == nil then return true end
    local command
    if year and month and day then
        command = string.format("date -s '%d-%d-%d %d:%d:%d'", year, month, day, hour, min, sec)
    else
        command = string.format("date -s '%d:%d'",hour, min)
    end
    if os.execute(command) == 0 then
        os.execute('hwclock -u -w')
        return true
    else
        return false
    end
end

function Device:isAlwaysFullscreen()
    -- return true on embedded devices, which should default to fullscreen
    return self:isDefaultFullscreen()
end

if isIOS then
    ffi.cdef[[
        bool SDL_SetTextInputArea(SDL_Window *window, const SDL_Rect *rect, int cursor);
    ]]
    -- SDL slides its view up when the system keyboard would cover this rect,
    -- so the focused field stays visible while typing. SDL wants window
    -- coordinates (points, full window); KOReader's are pixels inside the
    -- safe-area letterbox.
    function Device:setTextInputArea(dimen)
        if not dimen or SDL.window_pixel_w == 0 then return end
        local scale = 1 / ffi.C.ko_ios_get_screen_scale()
        local rect = ffi.new("SDL_Rect", {
            math.floor((dimen.x + SDL.safe_left) * scale),
            math.floor((dimen.y + SDL.safe_top) * scale),
            math.ceil(dimen.w * scale),
            math.ceil(dimen.h * scale),
        })
        SDL.SDL.SDL_SetTextInputArea(SDL.screen, rect, 0)
    end
end

function Device:toggleFullscreen()
    local current_mode = self.fullscreen or self:isDefaultFullscreen()
    local new_mode = not current_mode
    local ok, err = SDL.setWindowFullscreen(new_mode)
    if not ok then
        logger.warn("Unable to toggle fullscreen mode to", new_mode, "\n", err)
    else
        self.fullscreen = new_mode
    end
end

function Device:UIManagerReady(uimgr)
    UIManager = uimgr
    if isIOS then
        self.window_size_check = function() self:checkIOSWindowSize() end
        self.window_size_watch = function() self:watchIOSWindowSize() end
        UIManager:scheduleIn(2, self.window_size_watch)
    end
end

function Device:setEventHandlers(uimgr)
    if not self:canSuspend() then
        -- If we can't suspend, we have no business even trying to, as we may not have overloaded `Device:simulateResume`.
        -- Instead, rely on the Generic Suspend/Resume handlers.
        return
    end

    UIManager.event_handlers.Suspend = function()
        self:simulateSuspend()
    end
    UIManager.event_handlers.Resume = function()
        self:simulateResume()
    end
    UIManager.event_handlers.PowerRelease = function()
        -- Resume if we were suspended
        if self.screen_saver_mode then
            if self.screen_saver_lock then
                UIManager.event_handlers.Suspend()
            else
                UIManager.event_handlers.Resume()
            end
        else
            UIManager.event_handlers.Suspend()
        end
    end
end

function Device:initNetworkManager(NetworkMgr)
    function NetworkMgr:isWifiOn() return true end
    function NetworkMgr:isConnected()
        if not Device:hasWifiToggle() then
            -- NOTE: This is necessary so as not to confuse NetworkMghr's beforeWifiAction framework.
            --       c.f., the default implementation in `NetworkMgr` itself for more details.
            return true
        end
        -- Pull the default gateway first, so we don't even try to ping anything if there isn't one...
        local default_gw = Device:getDefaultRoute()
        if not default_gw then
            return false
        end
        return 0 == os.execute("ping -c1 -w2 " .. default_gw .. " > /dev/null")
    end
end

function Emulator:supportsScreensaver() return not isIOS end

function Emulator:simulateSuspend()
    local Screensaver = require("ui/screensaver")
    Screensaver:setup()
    Screensaver:show()

    self.powerd:beforeSuspend()
end

function Emulator:simulateResume()
    local Screensaver = require("ui/screensaver")
    Screensaver:close()

    self.powerd:afterResume()
end

-- fake network manager for the emulator
function Emulator:initNetworkManager(NetworkMgr)
    local connectionChangedEvent = function(complete_callback)
        if G_reader_settings:nilOrTrue("emulator_fake_wifi_connected") then
            UIManager:broadcastEvent(Event:new("NetworkConnected"))
        else
            UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
        end
        if complete_callback then
            complete_callback()
        end
    end
    function NetworkMgr:turnOffWifi(complete_callback)
        G_reader_settings:flipNilOrTrue("emulator_fake_wifi_connected")
        UIManager:scheduleIn(2, connectionChangedEvent, complete_callback)
    end
    function NetworkMgr:turnOnWifi(complete_callback)
        G_reader_settings:flipNilOrTrue("emulator_fake_wifi_connected")
        UIManager:scheduleIn(2, connectionChangedEvent, complete_callback)
    end
    function NetworkMgr:isWifiOn()
        return G_reader_settings:nilOrTrue("emulator_fake_wifi_connected")
    end
    NetworkMgr.isConnected = NetworkMgr.isWifiOn
end

-------------- device probe ------------
if os.getenv("APPIMAGE") then
    return AppImage
elseif os.getenv("FLATPAK") then
    return Flatpak
elseif os.getenv("KO_MULTIUSER") then
    return Desktop
elseif os.getenv("UBUNTU_APPLICATION_ISOLATION") then
    return UbuntuTouch
else
    return Emulator
end
