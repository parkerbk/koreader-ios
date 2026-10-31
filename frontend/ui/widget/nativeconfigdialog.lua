--[[--
ConfigDialog shown in the native iOS menu sheet (see platform/ios/ios_menu.m).

This keeps ConfigDialog's logic and only replaces its drawing: the current panel
is sent to the sheet as a snapshot, and what the user does there is polled back
here and fed to the same ConfigDialog methods as its widgets would.
--]]

local ConfigDialog = require("ui/widget/configdialog")
local Geom = require("ui/geometry")
local NativeTouchMenu = require("ui/widget/nativetouchmenu")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local json = require("json")
local _ = require("gettext")

local EV_HOLD, EV_TAB, EV_DISMISS, EV_CHOOSE, EV_MORE = 2, 4, 5, 6, 7
-- A choice comes back as item * CHOICE_FACTOR + position.
local CHOICE_FACTOR = 1000
local POLL_INTERVAL_S = 0.05
local MAX_SEGMENTS = 7
local MORE_POSITION = "⋮"

local TAB_SYMBOLS = {
    ["appbar.rotation"] = "rectangle.split.2x1",
    ["appbar.crop"] = "crop",
    ["appbar.pagefit"] = "arrow.up.left.and.arrow.down.right",
    ["appbar.pageview"] = "doc.text",
    ["appbar.textsize"] = "textformat.size",
    ["appbar.contrast"] = "circle.lefthalf.filled",
    ["appbar.settings"] = "gearshape",
}

-- iOS turns the app with the device.
local HIDDEN_OPTIONS = {
    rotation_mode = true,
}

-- The slider above this one is already called Font Size.
local ROW_NAMES = {
    font_fine_tune = _("Fine Adjustment"),
}

local function isShown(self, option)
    if HIDDEN_OPTIONS[option.name] then
        return false
    end
    if option.show_func then
        return option.show_func(self.configurable, self.document) ~= false
    end
    return option.show ~= false
end

local function valueDifference(val1, val2)
    if type(val1) == "table" then
        val1 = val1[1]
    end
    if type(val2) == "table" then
        val2 = val2[1]
    end
    if type(val1) == "number" and type(val2) == "number" then
        return math.abs(val1 - val2)
    end
    return val1 == val2 and 0 or 1
end

--- The position of the option's current value, or the nearest one to it.
local function currentPosition(self, option)
    local list = option.values or option.args
    if not list or not list[1] or not option.name then
        return 0
    end
    local current = option.current_func and option.current_func() or self.configurable[option.name]
    local position, smallest = 0, math.huge
    for i, value in ipairs(list) do
        local difference = valueDifference(current, value)
        if difference < smallest then
            position, smallest = i, difference
        end
    end
    return position
end

local function asLabel(value, position)
    if type(value) == "number" then
        return string.format("%g", value)
    elseif type(value) == "string" then
        return value
    end
    return tostring(position)
end

--- What to show for each position of an option.
local function optionLabels(option)
    local source = option.toggle or option.item_text or option.labels or option.args or option.values or {}
    local labels = {}
    for i, value in ipairs(source) do
        labels[i] = asLabel(value, i)
    end
    return labels
end

local NativeConfigDialog = ConfigDialog:extend{
    name = "NativeConfigDialog",
}

function NativeConfigDialog:init()
    -- ReaderConfig calls this again when the window changes size.
    if self.poll_func then
        self:update()
        return
    end
    self.show_parent = self
    self.dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
    self.dialog_frame = { dimen = self.dimen }
    self.poll_value = ffi.new("int[1]")
    self.poll_depth = ffi.new("int[1]")
    self.poll_func = function() self:poll() end
    self.tab_symbols = {}
    for i, panel in ipairs(self.config_options) do
        self.tab_symbols[i] = TAB_SYMBOLS[panel.icon] or "circle"
    end
    self:update()
end

function NativeConfigDialog:paintTo() end

function NativeConfigDialog:getOptionName(option)
    return ROW_NAMES[option.name] or option.name_text_func and option.name_text_func(self.configurable, self.document)
        or option.name_text or option.alt_name_text or ""
end

function NativeConfigDialog:update()
    if self.closed then
        return
    end
    local items = {}
    local panel = self.config_options[self.panel_index]
    for i, option in ipairs(panel and panel.options or {}) do
        if isShown(self, option) then
            local labels = optionLabels(option)
            local enabled = true
            if option.enabled_func then
                enabled = option.enabled_func(self.configurable, self.document) and true or false
            end
            local item = {
                i = i,
                text = tostring(self:getOptionName(option)),
                enabled = enabled,
                checked = false,
                control = (option.buttonprogress or #labels > MAX_SEGMENTS) and "slider" or "segments",
                labels = labels,
                selected = currentPosition(self, option),
                count = option.buttonprogress and #option.values or #labels,
                -- A pair like decrease/increase is a pair of actions, not a state.
                momentary = option.alternate == false or nil,
                more = option.more_options and true or false,
            }
            table.insert(items, item)
        end
    end
    ffi.C.ko_ios_menu_update(json.encode{
        depth = 0,
        tab = self.panel_index,
        tabs = self.tab_symbols,
        title = "",
        items = items,
        scroll_to = 0,
        dark = G_reader_settings:isTrue("night_mode"),
    })
end

function NativeConfigDialog:onShowConfigPanel(index)
    self.panel_index = index
    self:update()
    return true
end

function NativeConfigDialog:currentOptions()
    return self.config_options[self.panel_index].options
end

function NativeConfigDialog:showMore(option)
    local default_value = option.default_value
    local param = option.more_options_param
    if param and param.names then
        local option1 = self:findOptionByName(param.names[1])
        local option2 = self:findOptionByName(param.names[2])
        default_value = { option1.default_value, option2.default_value }
    end
    if param and option.show_true_value_func and not param.show_true_value_func then
        param.show_true_value_func = option.show_true_value_func
    end
    self:onConfigMoreChoose(option.values, default_value, option.name, option.event,
        MORE_POSITION, self:getOptionName(option), param)
end

--- Holding a row sets its current value as the default for new books, or
-- otherwise shows what the option has of its own for a hold.
function NativeConfigDialog:hold(option)
    local position = currentPosition(self, option)
    if option.values and option.values[1] and position > 0 and option.alternate ~= false then
        self:onMakeDefault(option.name, self:getOptionName(option), option.values,
            option.labels or option.args, position)
    elseif option.name_text_hold_callback then
        option.name_text_hold_callback(self.configurable, option, self.config_options.prefix, self.document)
    end
end

function NativeConfigDialog:handleMenuEvent(event, value)
    if event == EV_TAB then
        self:onShowConfigPanel(value)
    elseif event == EV_DISMISS then
        self:closeDialog()
    elseif event == EV_CHOOSE then
        local option = self:currentOptions()[math.floor(value / CHOICE_FACTOR)]
        if option then
            self:onConfigChoose(option.values, option.name, option.event, option.args,
                value % CHOICE_FACTOR, option.hide_on_apply)
        end
    elseif event == EV_MORE then
        local option = self:currentOptions()[value]
        if option then
            self:showMore(option)
        end
    elseif event == EV_HOLD then
        local option = self:currentOptions()[value]
        if option then
            self:hold(option)
        end
    end
end

function NativeConfigDialog:poll()
    local on_top = NativeTouchMenu.isOnTop(self)
    if on_top ~= self.sheet_visible then
        self.sheet_visible = on_top
        ffi.C.ko_ios_menu_set_visible(on_top)
    end
    local event = ffi.C.ko_ios_menu_poll(self.poll_value, self.poll_depth)
    while event ~= 0 and not self.closed do
        self:handleMenuEvent(event, self.poll_value[0])
        event = ffi.C.ko_ios_menu_poll(self.poll_value, self.poll_depth)
    end
    if not self.closed then
        UIManager:scheduleIn(POLL_INTERVAL_S, self.poll_func)
    end
end

function NativeConfigDialog:onShow()
    self:poll()
end

function NativeConfigDialog:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.poll_func)
    ffi.C.ko_ios_menu_close()
end

return NativeConfigDialog
