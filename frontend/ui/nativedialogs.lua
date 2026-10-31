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
local DateTimeWidget = require("ui/widget/datetimewidget")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local SpinWidget = require("ui/widget/spinwidget")
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

--- Returns a number picker as a form control, and how to give it its new value.
local function getPickerControl(picker, label, unit)
    local control = {
        kind = "number",
        label = label or "",
        unit = unit and tostring(unit) or "",
        wrap = picker.wrap and true or false,
    }
    if picker.value_table then
        control.min, control.max, control.step = 1, #picker.value_table, 1
        control.value = picker.value_index or 1
        control.decimals = 0
        control.labels = {}
        for i, value in ipairs(picker.value_table) do
            control.labels[i] = tostring(value)
        end
        return control, function(text)
            picker.value_index = tonumber(text) or picker.value_index
            picker.value = picker.value_table[picker.value_index]
        end
    end
    local decimals = picker.precision and picker.precision:match("%.(%d+)f")
    control.min, control.max = picker.value_min, picker.value_max
    control.step = picker.value_step or 1
    control.value = picker.value
    control.decimals = tonumber(decimals) or (control.step % 1 ~= 0 and 2 or 0)
    return control, function(text)
        picker.value = tonumber(text) or picker.value
    end
end

--- Builds a form out of number pickers, with the widget's own buttons: they read
-- the pickers, so all it takes is giving those the values from the native form.
local function describePickers(widget, title, message, pickers)
    local button_table = findButtonTable(widget, 10)
    local buttons = button_table and getButtons(button_table.buttons)
    if not buttons then return end
    local controls, setters = {}, {}
    for i, picker in ipairs(pickers) do
        controls[i], setters[i] = getPickerControl(picker.widget, picker.label, picker.unit)
    end
    return {
        form = true,
        title = title,
        message = message,
        controls = controls,
        buttons = buttons,
        apply = function(texts)
            for i, set in ipairs(setters) do
                set(texts[i])
            end
        end,
    }
end

local function describeDateTime(widget)
    local has_date = widget.year and widget.month and widget.day
    local has_time = widget.hour and widget.min
    local is_clock = has_time and not (widget.year or widget.month or widget.day or widget.sec)
        and (widget.hour_max or 23) <= 23
    if (has_date and not (widget.hour or widget.min or widget.sec)) or is_clock then
        local button_table = findButtonTable(widget, 10)
        local buttons = button_table and getButtons(button_table.buttons)
        if not buttons then return end
        local value = is_clock
            and string.format("%02d:%02d", widget.hour_widget.value, widget.min_widget.value)
            or string.format("%04d-%02d-%02d", widget.year_widget.value,
                widget.month_widget.value, widget.day_widget.value)
        return {
            form = true,
            title = widget.title_text,
            message = widget.info_text,
            controls = { { kind = "date", mode = is_clock and "time" or "date", value = value } },
            buttons = buttons,
            apply = function(texts)
                if is_clock then
                    local hour, min = texts[1]:match("(%d+):(%d+)")
                    widget.hour_widget.value = tonumber(hour)
                    widget.min_widget.value = tonumber(min)
                else
                    local year, month, day = texts[1]:match("(%d+)-(%d+)-(%d+)")
                    widget.year_widget.value = tonumber(year)
                    widget.month_widget.value = tonumber(month)
                    widget.day_widget.value = tonumber(day)
                end
            end,
        }
    end
    local pickers = {}
    for _i, part in ipairs{ {"year", _("Year")}, {"month", _("Month")}, {"day", _("Days")},
                            {"hour", _("Hours")}, {"min", _("Minutes")}, {"sec", _("Seconds")} } do
        if widget[part[1]] then
            table.insert(pickers, { widget = widget[part[1] .. "_widget"], label = part[2] })
        end
    end
    return describePickers(widget, widget.title_text, widget.info_text, pickers)
end

local function describeTextBox(widget)
    if not widget.buttons then return end
    local rows = {}
    for i, row in ipairs(widget.buttons) do
        rows[i] = {}
        for _j, button in ipairs(row) do
            -- The sheet scrolls by itself.
            if not (button.id == "top" or button.id == "bottom" or button.id == "up"
                    or button.id == "down") then
                table.insert(rows[i], button)
            end
        end
    end
    local buttons = getButtons(rows, true)
    if not buttons then return end
    local original = widget:getInputText()
    return {
        form = true,
        title = widget.title,
        message = widget.description,
        controls = { { kind = "text", text = original, readonly = widget.readonly and true or false } },
        buttons = buttons,
        apply = function(texts)
            widget:setInputText(texts[1], widget._buttons_edit_callback and texts[1] ~= original or nil)
        end,
    }
end

--- Returns what the native dialog should show, nil to keep the KOReader one.
function NativeDialogs.describe(widget)
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
    elseif class == SpinWidget then
        return describePickers(widget, widget.title_text, widget.info_text,
            { { widget = widget.value_widget, unit = widget.unit } })
    elseif class == DoubleSpinWidget then
        return describePickers(widget, widget.title_text, widget.info_text, {
            { widget = widget.left_widget, label = widget.left_text, unit = widget.unit },
            { widget = widget.right_widget, label = widget.right_text, unit = widget.unit },
        })
    elseif class == DateTimeWidget then
        return describeDateTime(widget)
    elseif class == InputDialog or class == MultiInputDialog then
        if widget.fullscreen or widget.add_nav_bar then return end
        if class == InputDialog and widget.allow_newline then
            return describeTextBox(widget)
        end
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
    if entry.spec.form then -- its buttons may have changed the widget's values
        entry.spec = self.describe(entry.widget) or entry.spec
    end
    local buttons = {}
    for i, button in ipairs(entry.spec.buttons) do
        local role
        if entry.spec.form then
            -- Like the Cancel and OK of the widget's last row, which go up on the
            -- sheet's bar. Those buttons are enabled by changes it doesn't see.
            button.enabled = true
            if i == #entry.spec.buttons then
                role = "ok"
            elseif i == #entry.spec.buttons - 1 then
                role = "cancel"
            end
        end
        buttons[i] = { i = i, text = button.text, enabled = button.enabled,
            preferred = button.preferred, role = role }
    end
    ffi.C.ko_ios_dialog_show(json.encode{
        id = id,
        sheet = entry.spec.sheet or false,
        title = entry.spec.title or "",
        message = entry.spec.message or "",
        fields = entry.spec.fields,
        buttons = buttons,
        cancel = entry.spec.cancel or "",
        controls = entry.spec.controls,
        dark = G_reader_settings:isTrue("night_mode"),
    })
end

function NativeDialogs:handleButton(id, button, texts)
    local UIManager = require("ui/uimanager")
    local entry = self.open[id]
    if not entry then return end
    local widget = entry.widget
    local class = getmetatable(widget)
    if entry.spec.apply then
        if button > 0 then
            entry.spec.apply(texts)
        end
    elseif class == MultiInputDialog then
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
    local spec = self.describe(widget)
    if not spec then return end
    self.poll_button = self.poll_button or ffi.new("int[1]")
    self.poll_texts = self.poll_texts or ffi.new("char[?]", TEXTS_CAP)
    self.poll_func = self.poll_func or function() self:poll() end

    local id = self.next_id
    self.next_id = id + 1
    self.open[id] = { widget = widget, spec = spec }
    widget.native_dialog_id = id
    widget.paintTo = noop
    widget.covers_fullscreen = nil
    if spec.form then
        -- Apply ends a form, and the page is still in view behind its sheet.
        widget.keep_shown_on_apply = nil
    end
    if spec.fields or spec.form then
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
