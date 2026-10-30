--[[--
TouchMenu shown in a native iOS sheet (see platform/ios/ios_menu.m).

This keeps all of TouchMenu's logic and only replaces its drawing: each menu
level is sent to the sheet as a snapshot, and what the user does there is
polled back here and fed to the same TouchMenu methods as its widgets would.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local json = require("json")
local util = require("util")

ffi.cdef[[
void ko_ios_menu_update(const char *json);
void ko_ios_menu_set_visible(bool visible);
void ko_ios_menu_close(void);
int ko_ios_menu_poll(int *value, int *depth);
]]

local EV_SELECT, EV_HOLD, EV_BACK, EV_TAB, EV_DISMISS = 1, 2, 3, 4, 5
local POLL_INTERVAL_S = 0.05

local TAB_SYMBOLS = {
    ["appbar.navigation"] = "bookmark",
    ["appbar.typeset"] = "textformat",
    ["appbar.settings"] = "gearshape",
    ["appbar.tools"] = "wrench.and.screwdriver",
    ["appbar.search"] = "magnifyingglass",
    ["appbar.filebrowser"] = "folder",
    ["appbar.menu"] = "line.3.horizontal",
}

local NativeTouchMenu = TouchMenu:extend{}

function NativeTouchMenu:init()
    self.dimen = Geom:new{ w = 0, h = 0 }
    self.show_parent = self.show_parent or self
    self.close_callback = self.close_callback or function()
        UIManager:close(self.show_parent)
    end
    self.titles = {}
    self.tab_symbols = {}
    for i, tab in ipairs(self.tab_item_table) do
        self.tab_symbols[i] = TAB_SYMBOLS[tab.icon] or "circle"
    end
    self.poll_value = ffi.new("int[1]")
    self.poll_depth = ffi.new("int[1]")
    self.poll_func = function() self:poll() end
    self:switchMenuTab(self.last_index or 1)
end

function NativeTouchMenu:paintTo() end

function NativeTouchMenu:updateItems(target_page, target_item_id)
    self.page = 1 -- the sheet scrolls, so there's only ever one page
    local depth = #self.item_table_stack
    if self.pending_title and depth > 0 then
        self.titles[depth] = self.pending_title
    end
    self.pending_title = nil

    local items = {}
    local scroll_to = self.scroll_to or 0
    self.scroll_to = nil
    for i, item in ipairs(self.item_table) do
        local enabled = item.enabled
        if item.enabled_func then
            enabled = item.enabled_func()
        end
        local checked = item.checked
        if item.checked_func then
            checked = item.checked_func()
        end
        local text = item.text_func and item.text_func() or item.text
        items[i] = {
            i = i,
            text = text and tostring(text) or "",
            enabled = enabled ~= false,
            checkable = item.checked_func ~= nil,
            checked = checked and true or false,
            radio = item.radio and true or false,
            sub = (item.sub_item_table or item.sub_item_table_func) and true or false,
            sep = item.separator and true or false,
        }
        if target_item_id ~= nil and item.menu_item_id == target_item_id then
            scroll_to = i
        end
    end
    ffi.C.ko_ios_menu_update(json.encode{
        depth = depth,
        tab = self.cur_tab,
        tabs = self.tab_symbols,
        title = self.titles[depth] or "",
        items = items,
        scroll_to = scroll_to,
        dark = G_reader_settings:isTrue("night_mode"),
    })
end

function NativeTouchMenu:onMenuSelect(item, tap_on_checkmark)
    self.pending_title = item.text_func and item.text_func() or item.text
    TouchMenu.onMenuSelect(self, item, tap_on_checkmark)
    self.pending_title = nil
end

--- Jumps straight to a menu item found by menu search.
function NativeTouchMenu:openMenu(path)
    if self.not_shown then
        UIManager:show(self.show_parent)
    end
    local parts = {}
    for part in util.gsplit(path, "%.", false) do -- path is ie. "2.3.3.1"
        table.insert(parts, tonumber(part))
    end
    self:switchMenuTab(parts[1])
    for i = 2, #parts - 1 do
        self:onMenuSelect(self.item_table[parts[i]])
    end
    if #parts > 1 then
        self.scroll_to = parts[#parts]
        self:updateItems()
    end
end

--- Whether the sheet should be up: KOReader's own widgets paint under it, so
-- it steps aside for whatever a menu item opened (toasts can stay under it).
function NativeTouchMenu:isOnTop()
    local n = 1
    local widget = UIManager:getNthTopWidget(n)
    while widget do
        if widget == self.show_parent then
            return true
        end
        if not widget.toast and not widget.invisible then
            return false
        end
        n = n + 1
        widget = UIManager:getNthTopWidget(n)
    end
    return false
end

function NativeTouchMenu:handleMenuEvent(event, value, depth)
    if event == EV_TAB then
        self:switchMenuTab(value)
    elseif event == EV_DISMISS then
        self:closeMenu()
    elseif event == EV_BACK then
        while #self.item_table_stack > depth do
            self:backToUpperMenu(true)
        end
    elseif depth == #self.item_table_stack and self.item_table[value] then
        local item = self.item_table[value]
        if event == EV_SELECT then
            self:onMenuSelect(item)
        elseif event == EV_HOLD then
            local enabled = item.enabled
            if item.enabled_func then
                enabled = item.enabled_func()
            end
            if enabled == false then
                local help_text = item.help_text_func and item.help_text_func(self) or item.help_text
                if help_text then
                    UIManager:show(InfoMessage:new{ text = help_text })
                end
            else
                self:onMenuHold(item, false)
            end
        end
    end
end

function NativeTouchMenu:poll()
    local on_top = self:isOnTop()
    if on_top ~= self.sheet_visible then
        self.sheet_visible = on_top
        ffi.C.ko_ios_menu_set_visible(on_top)
    end
    local event = ffi.C.ko_ios_menu_poll(self.poll_value, self.poll_depth)
    while event ~= 0 and not self.closed do
        self:handleMenuEvent(event, self.poll_value[0], self.poll_depth[0])
        event = ffi.C.ko_ios_menu_poll(self.poll_value, self.poll_depth)
    end
    if not self.closed then
        UIManager:scheduleIn(POLL_INTERVAL_S, self.poll_func)
    end
end

function NativeTouchMenu:onShow()
    self:poll()
end

function NativeTouchMenu:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.poll_func)
    ffi.C.ko_ios_menu_close()
end

return NativeTouchMenu
