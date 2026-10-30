--[[--
Shows KOReader's dialog widgets as native iOS alerts (see platform/ios/ios_dialog.m).

The widget itself stays in UIManager's stack, unpainted, so that the code which
opened it works unchanged: callers still get their button callbacks, and
`getInputText()` and `getFields()` still return what was typed. Widgets that
aren't plain text and buttons keep their usual KOReader look.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ffi = require("ffi")
local json = require("json")
local _ = require("gettext")

ffi.cdef[[
void ko_ios_dialog_show(const char *json);
void ko_ios_dialog_close(int dialog_id);
int ko_ios_dialog_poll(int *button, char *out_texts, int cap);
]]

local POLL_INTERVAL_S = 0.05
local REPRESENT_DELAY_S = 0.15
local TEXTS_CAP = 1024 * 1024

local NativeDialogs = {
    open = {}, -- id -> { widget, buttons }
    next_id = 1,
}

local function findButtonTable(widget, depth)
    if getmetatable(widget) == ButtonTable then
        return widget
    end
    if depth > 0 then
        for _i, child in ipairs(widget) do
            local found = type(child) == "table" and findButtonTable(child, depth - 1)
            if found then return found end
        end
    end
end

--- Flattens button rows, or returns nil if one needs more than a text label.
local function getButtons(rows, preferred_last)
    local buttons = {}
    for _i, row in ipairs(rows) do
        for _j, button in ipairs(row) do
            local text = button.text_func and button.text_func() or button.text
            if text == nil then
                return
            end
            if text ~= "" then
                local enabled = button.enabled
                if button.enabled_func then
                    enabled = button.enabled_func()
                end
                table.insert(buttons, {
                    text = tostring(text),
                    enabled = enabled ~= false,
                    callback = button.callback,
                    preferred = button.is_enter_default and true or false,
                })
            end
        end
    end
    if preferred_last and #buttons > 0 then
        buttons[#buttons].preferred = true
    end
    return buttons
end

local function getInputField(field)
    return {
        text = field.text or field.input or "",
        hint = field.hint or field.input_hint or "",
        secure = field.text_type == "password",
        number = field.input_type == "number",
    }
end

--- Returns what the native dialog should show, nil to keep the KOReader one.
local function describe(widget)
    local class = getmetatable(widget)
    if class == InfoMessage then
        -- Timed messages are toasts, which an alert would make heavier.
        if widget.timeout or widget.image or widget.show_delay then return end
        return { message = widget.text, buttons = {}, cancel = _("OK") }
    elseif class == ConfirmBox or class == MultiConfirmBox then
        if widget.custom_content then return end
        local button_table = findButtonTable(widget, 8)
        local buttons = button_table and getButtons(button_table.buttons, true)
        return buttons and { message = widget.text, buttons = buttons }
    elseif class == ButtonDialog then
        local buttons = getButtons(widget.buttons)
        return buttons and {
            sheet = true,
            title = widget.title,
            buttons = buttons,
            cancel = widget.dismissable and _("Cancel") or nil,
        }
    elseif class == InputDialog or class == MultiInputDialog then
        if widget.fullscreen or widget.add_nav_bar or widget.allow_newline then return end
        local buttons = getButtons(widget.buttons, true)
        local fields = {}
        for i, field in ipairs(class == MultiInputDialog and widget.fields or { widget }) do
            fields[i] = getInputField(field)
        end
        return buttons and {
            title = widget.title,
            message = widget.description,
            fields = fields,
            buttons = buttons,
        }
    end
end

function NativeDialogs:present(id)
    local entry = self.open[id]
    local buttons = {}
    for i, button in ipairs(entry.spec.buttons) do
        buttons[i] = { i = i, text = button.text, enabled = button.enabled, preferred = button.preferred }
    end
    ffi.C.ko_ios_dialog_show(json.encode{
        id = id,
        sheet = entry.spec.sheet or false,
        title = entry.spec.title or "",
        message = entry.spec.message or "",
        fields = entry.spec.fields,
        buttons = buttons,
        cancel = entry.spec.cancel or "",
        dark = G_reader_settings:isTrue("night_mode"),
    })
end

function NativeDialogs:handleButton(id, button, texts)
    local UIManager = require("ui/uimanager")
    local entry = self.open[id]
    if not entry then return end
    local widget = entry.widget
    local class = getmetatable(widget)
    if class == MultiInputDialog then
        for i, field in ipairs(widget.input_fields) do
            field:setText(texts[i] or "", true)
        end
    elseif class == InputDialog then
        widget:setInputText(texts[1] or "", nil, false)
    end
    local spec_button = entry.spec.buttons[button]
    if spec_button then
        if spec_button.callback then
            spec_button.callback()
        end
    elseif widget.onClose then
        widget:onClose()
    else
        UIManager:close(widget)
    end
    -- The alert is gone either way: bring it back for buttons that keep the
    -- widget open, like one that validates what was typed.
    UIManager:scheduleIn(REPRESENT_DELAY_S, function()
        if self.open[id] then
            self:present(id)
        end
    end)
end

function NativeDialogs:poll()
    local UIManager = require("ui/uimanager")
    self.polling = false
    local id = ffi.C.ko_ios_dialog_poll(self.poll_button, self.poll_texts, TEXTS_CAP)
    while id ~= 0 do
        self:handleButton(id, self.poll_button[0], json.decode(ffi.string(self.poll_texts)))
        id = ffi.C.ko_ios_dialog_poll(self.poll_button, self.poll_texts, TEXTS_CAP)
    end
    if next(self.open) and not self.polling then
        self.polling = true
        UIManager:scheduleIn(POLL_INTERVAL_S, self.poll_func)
    end
end

local function noop() end

--- Called by UIManager before showing a widget.
function NativeDialogs:onShow(widget)
    local spec = describe(widget)
    if not spec then return end
    self.poll_button = self.poll_button or ffi.new("int[1]")
    self.poll_texts = self.poll_texts or ffi.new("char[?]", TEXTS_CAP)
    self.poll_func = self.poll_func or function() self:poll() end

    local id = self.next_id
    self.next_id = id + 1
    self.open[id] = { widget = widget, spec = spec }
    widget.native_dialog_id = id
    widget.paintTo = noop
    if spec.fields then
        -- The alert's text fields bring the system keyboard themselves.
        widget.onShowKeyboard = noop
        widget.onCloseKeyboard = noop
    end
    -- A menu item opens its dialog and then closes the menu, which would take
    -- an alert presented on the menu's sheet away with it.
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        if self.open[id] then
            self:present(id)
        end
    end)
    if not self.polling then
        self.polling = true
        UIManager:scheduleIn(POLL_INTERVAL_S, self.poll_func)
    end
end

--- Called by UIManager when closing a widget.
function NativeDialogs:onClose(widget)
    local id = widget.native_dialog_id
    if id and self.open[id] then
        self.open[id] = nil
        ffi.C.ko_ios_dialog_close(id)
    end
end

return NativeDialogs
