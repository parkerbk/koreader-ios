--[[--
Reads reflowable books aloud on iOS, through platform/ios/ios_tts.m, with the
system voices or the downloadable Kokoro ones.

Lua only prepares the text: it walks the book by sentence and queues well ahead
of the voice, so that speech carries on if Lua stops running in the background.
Polling then follows along when it can, marking the sentence and turning pages.
]]

if os.getenv("KO_IOS") ~= "1" then
    return { disabled = true }
end

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")

ffi.cdef[[
    void ko_ios_tts_configure(const char *book, const char *title, const char *author);
    void ko_ios_tts_set_voice(const char *voice_id, const char *language);
    void ko_ios_tts_set_rate(float rate, float speed);
    void ko_ios_tts_enqueue(int item_id, const char *text, const char *position);
    void ko_ios_tts_queue_complete(void);
    void ko_ios_tts_start(void);
    void ko_ios_tts_pause(void);
    void ko_ios_tts_resume(void);
    void ko_ios_tts_stop(void);
    int ko_ios_tts_poll(int *current_id);
    int ko_ios_tts_is_foreground(void);
    void ko_ios_tts_list_voices(char *out, size_t cap);
    void ko_ios_tts_saved_position(const char *book, char *out, size_t cap);
    void ko_ios_kokoro_download(void);
    int ko_ios_kokoro_status(float *progress);
    void ko_ios_kokoro_delete(void);
]]

local STATE_IDLE, STATE_SPEAKING, STATE_PAUSED = 0, 1, 2
local KOKORO_MISSING, KOKORO_DOWNLOADING, KOKORO_UNPACKING, KOKORO_READY, KOKORO_FAILED = 0, 1, 2, 3, 4

local POLL_INTERVAL = 0.25
-- About half an hour of speech, for when Lua can't top the queue up.
local SENTENCES_AHEAD = 600
local SENTENCES_PER_TICK = 30
local MAX_WORDS_PER_SENTENCE = 80
local SPEEDS = { 0.75, 1, 1.25, 1.5, 1.75, 2 }
local VOICES_BUFFER_SIZE = 256 * 1024
local POSITION_BUFFER_SIZE = 4096
-- AVSpeechSynthesisVoiceQuality; the basic quality goes unlabelled.
local QUALITY_NAMES = { [2] = _("Enhanced"), [3] = _("Premium") }
local KOKORO_POLL_INTERVAL = 1
local KOKORO_PREFIX = "kokoro:"
-- In the model's order, which is also how ios_tts.m picks them.
local KOKORO_VOICES = {
    _("Blend (US)"), _("Bella (US)"), _("Nicole (US)"), _("Sarah (US)"), _("Sky (US)"), _("Adam (US)"),
    _("Michael (US)"), _("Emma (UK)"), _("Isabella (UK)"), _("George (UK)"), _("Lewis (UK)"),
}

-- Words whose period doesn't end the sentence.
local ABBREVIATIONS = {}
for word in ("mr mrs ms dr prof st sr jr vs etc inc ltd no fig e.g i.e"):gmatch("%S+") do
    ABBREVIATIONS[word] = true
end

-- Marks that voices can say by name, especially alone at the end of a sentence.
local SILENT_MARKS = { "“", "”", "„", "‟", "«", "»", "‹", "›", "\"", "‘", "*", "_", "#", "~", "|", "➔", "→" }
local PAUSE_MARKS = { "—", "–" }

--- Leaves only what should be heard. A right single quote stays as an
-- apostrophe, which it is far more often than not.
local function cleanText(text)
    for _i, mark in ipairs(SILENT_MARKS) do
        text = text:gsub(mark:gsub("%p", "%%%0"), " ")
    end
    for _i, mark in ipairs(PAUSE_MARKS) do
        text = text:gsub(mark, ", ")
    end
    text = text:gsub("’%s", " "):gsub("’$", ""):gsub("’", "'")
    return (text:gsub("%s+", " "))
end

--- AVSpeech's rate is 0.5 at normal speed, and past that it speeds up quickly.
local function speedToRate(speed)
    if speed <= 1 then
        return 0.5 * speed
    end
    return 0.5 + (speed - 1) * 0.25
end

local ReadAloud = WidgetContainer:extend{
    name = "readaloud",
    is_doc_only = true,
}

function ReadAloud:init()
    if not self.ui.rolling then
        return
    end
    self.current_id = ffi.new("int[1]")
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function ReadAloud:onDispatcherRegisterActions()
    Dispatcher:registerAction("read_aloud_toggle",
        {category="none", event="ToggleReadAloud", title=_("Read aloud: start or pause"), rolling=true})
end

function ReadAloud:getState()
    return ffi.C.ko_ios_tts_poll(self.current_id)
end

--- Whether a gap between two words ends a sentence.
function ReadAloud:endsSentence(gap, word_start, word_end)
    if gap:find("\n", 1, true) then
        return true
    end
    -- The space matters: it tells the end of a sentence from "3.14".
    if not gap:find("[.!?][\"')%]]*%s") and not gap:find("[.!?…][”’»]*%s") and not gap:find("…%s") then
        return false
    end
    if gap:sub(1, 1) == "." then
        local word = self.ui.document:getTextFromXPointers(word_start, word_end, false) or ""
        word = word:lower()
        if ABBREVIATIONS[word] or #word == 1 then
            return false
        end
    end
    return true
end

--- Reads one sentence from the cursor.
-- Returns its text and start and end xpointers, or nil at the end of the book.
function ReadAloud:nextSentence()
    local document = self.ui.document
    local sentence_start = self.cursor
    local word_start = sentence_start
    local sentence_end
    for _i = 1, MAX_WORDS_PER_SENTENCE do
        local word_end = document:getNextVisibleWordEnd(word_start)
        if not word_end then
            break
        end
        sentence_end = word_end
        local next_word = document:getNextVisibleWordStart(word_end)
        if not next_word then
            self.cursor = nil
            break
        end
        self.cursor = next_word
        -- Past the next word's first letter, or a paragraph break doesn't show.
        local gap = document:getTextFromXPointers(word_end, document:getNextVisibleChar(next_word), false) or ""
        if self:endsSentence(gap, word_start, word_end) then
            break
        end
        word_start = next_word
    end
    if not sentence_end then
        self.cursor = nil
        return
    end
    local text = document:getTextFromXPointers(sentence_start, self.cursor or sentence_end, false) or ""
    return text, sentence_start, sentence_end
end

--- Queues some more sentences, a few at a time to keep the page responsive.
function ReadAloud:fillQueue()
    local last_id = #self.sentences
    local ahead = last_id - self.current_id[0]
    for _i = 1, SENTENCES_PER_TICK do
        if not self.cursor or ahead >= SENTENCES_AHEAD then
            break
        end
        local text, xp0, xp1 = self:nextSentence()
        text = text and cleanText(text)
        if text and text:find("[%w\128-\255]") then
            table.insert(self.sentences, { xp0 = xp0, xp1 = xp1 })
            ffi.C.ko_ios_tts_enqueue(#self.sentences, text, xp0)
            ahead = ahead + 1
        end
    end
    if not self.cursor and not self.queue_completed then
        self.queue_completed = true
        ffi.C.ko_ios_tts_queue_complete()
    end
end

function ReadAloud:clearMark()
    if self.marked then
        self.marked = false
        self.ui.document:clearSelection()
        UIManager:setDirty(self.view.dialog, "ui")
    end
end

--- Marks the sentence being spoken, turning the page if speech has left it.
-- If the reader has gone elsewhere in the book, they're left there.
function ReadAloud:showSentence(sentence, force_page)
    local document = self.ui.document
    local was_on_page = self.last_sentence == nil
        or document:isXPointerInCurrentPage(self.last_sentence.xp0)
    self.last_sentence = sentence
    if not document:isXPointerInCurrentPage(sentence.xp0) then
        if not (was_on_page or force_page) then
            self:clearMark()
            return
        end
        self.ui:handleEvent(Event:new("GotoXPointer", sentence.xp0))
    end
    document:clearSelection()
    document:getTextFromXPointers(sentence.xp0, sentence.xp1, true)
    self.marked = true
    UIManager:setDirty(self.view.dialog, "ui")
end

function ReadAloud:poll()
    local state = self:getState()
    if state == STATE_IDLE then
        self:clearMark()
        self.polling = false
        return
    end
    self:fillQueue()
    local id = self.current_id[0]
    if ffi.C.ko_ios_tts_is_foreground() == 0 then
        self.was_backgrounded = true
    elseif id ~= self.shown_id and self.sentences[id] then
        self.shown_id = id
        self:showSentence(self.sentences[id], self.was_backgrounded)
        self.was_backgrounded = false
    end
    UIManager:scheduleIn(POLL_INTERVAL, self.poll_func)
end

function ReadAloud:isKokoroLanguage()
    local language = self:getLanguage():sub(1, 2):lower()
    return language == "" or language == "en"
end

function ReadAloud:applyVoice()
    local voice = G_reader_settings:readSetting("read_aloud_voice") or ""
    -- Kokoro only knows English, so other books go to the best system voice.
    if voice:sub(1, #KOKORO_PREFIX) == KOKORO_PREFIX and not self:isKokoroLanguage() then
        voice = ""
    end
    ffi.C.ko_ios_tts_set_voice(voice, self:getLanguage())
end

function ReadAloud:getLanguage()
    return self.ui.doc_props and self.ui.doc_props.language or ""
end

function ReadAloud:applySpeed()
    local speed = G_reader_settings:readSetting("read_aloud_speed") or 1
    ffi.C.ko_ios_tts_set_rate(speedToRate(speed), speed)
end

function ReadAloud:start()
    local props = self.ui.doc_props or {}
    self.sentences = {}
    self.cursor = self.ui.document:getXPointer()
    self.queue_completed = false
    self.shown_id = nil
    self.last_sentence = nil
    self.was_backgrounded = false
    ffi.C.ko_ios_tts_configure(self.document.file, props.display_title or "", props.authors or "")
    self:applyVoice()
    self:applySpeed()
    self:fillQueue()
    if #self.sentences == 0 then
        UIManager:show(InfoMessage:new{ text = _("There's no text to read from here.") })
        return
    end
    ffi.C.ko_ios_tts_start()
    if not self.polling then
        self.polling = true
        self.poll_func = self.poll_func or function() self:poll() end
        UIManager:scheduleIn(POLL_INTERVAL, self.poll_func)
    end
end

function ReadAloud:stop()
    ffi.C.ko_ios_tts_stop()
    if self.polling then
        UIManager:unschedule(self.poll_func)
        self.polling = false
    end
    self:clearMark()
end

function ReadAloud:onToggleReadAloud()
    local state = self:getState()
    if state == STATE_SPEAKING then
        ffi.C.ko_ios_tts_pause()
    elseif state == STATE_PAUSED then
        ffi.C.ko_ios_tts_resume()
    else
        self:start()
    end
    return true
end

--- Goes back to where speech had got to if the app was killed mid-book.
function ReadAloud:onReaderReady()
    if not self.ui.rolling then
        return
    end
    local position = ffi.new("char[?]", POSITION_BUFFER_SIZE)
    ffi.C.ko_ios_tts_saved_position(self.document.file, position, POSITION_BUFFER_SIZE)
    local xp = ffi.string(position)
    if xp ~= "" and self:getState() == STATE_IDLE then
        logger.dbg("ReadAloud: going back to", xp)
        self.ui:handleEvent(Event:new("GotoXPointer", xp))
        -- Once only: from here on, the reader's own position is the one to keep.
        ffi.C.ko_ios_tts_stop()
    end
end

function ReadAloud:onCloseDocument()
    if self.ui.rolling then
        self:stop()
    end
end

function ReadAloud:getVoices()
    local buffer = ffi.new("char[?]", VOICES_BUFFER_SIZE)
    ffi.C.ko_ios_tts_list_voices(buffer, VOICES_BUFFER_SIZE)
    local ok, voices = pcall(json.decode, ffi.string(buffer))
    if not ok then
        logger.warn("ReadAloud: can't read the voice list:", voices)
        return {}
    end
    local language = self:getLanguage():sub(1, 2):lower()
    local matching = {}
    for _i, voice in ipairs(voices) do
        -- The older identifiers are the novelty voices, such as Bubbles.
        if not voice.id:find("speech.synthesis.voice", 1, true)
                and (language == "" or voice.language:sub(1, 2):lower() == language) then
            table.insert(matching, voice)
        end
    end
    table.sort(matching, function(a, b)
        if a.quality ~= b.quality then
            return a.quality > b.quality
        end
        return a.name < b.name
    end)
    return matching
end

function ReadAloud:getKokoroStatus()
    local progress = ffi.new("float[1]")
    local status = ffi.C.ko_ios_kokoro_status(progress)
    return status, progress[0]
end

function ReadAloud:setVoice(id)
    G_reader_settings:saveSetting("read_aloud_voice", id)
    self:applyVoice()
end

--- Follows the download, so it can finish with the menu closed.
function ReadAloud:watchKokoroDownload()
    local status = self:getKokoroStatus()
    if status == KOKORO_DOWNLOADING or status == KOKORO_UNPACKING then
        UIManager:scheduleIn(KOKORO_POLL_INTERVAL, function() self:watchKokoroDownload() end)
    elseif status == KOKORO_READY then
        self:setVoice(KOKORO_PREFIX .. "1")
        UIManager:show(InfoMessage:new{
            text = _("Kokoro voices are ready, and read aloud now uses Bella. Choose another under Voice."),
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Kokoro voices couldn't be downloaded. Check your connection and try again."),
        })
    end
end

function ReadAloud:downloadKokoro()
    UIManager:show(ConfirmBox:new{
        text = _("Download the Kokoro voices? The download is about 100 MB, so Wi-Fi is best, and they take up 135 MB once installed. They read books in English only."),
        ok_text = _("Download"),
        ok_callback = function()
            ffi.C.ko_ios_kokoro_download()
            UIManager:scheduleIn(KOKORO_POLL_INTERVAL, function() self:watchKokoroDownload() end)
        end,
    })
end

function ReadAloud:removeKokoro()
    UIManager:show(ConfirmBox:new{
        text = _("Remove the Kokoro voices from this device? You can download them again later."),
        ok_text = _("Remove"),
        ok_callback = function()
            local voice = G_reader_settings:readSetting("read_aloud_voice") or ""
            self:stop()
            if voice:sub(1, #KOKORO_PREFIX) == KOKORO_PREFIX then
                self:setVoice(nil)
            end
            ffi.C.ko_ios_kokoro_delete()
        end,
    })
end

--- The menu items for Kokoro: its voices if it's here, or a way of getting them.
function ReadAloud:getKokoroItems()
    local status, progress = self:getKokoroStatus()
    if status == KOKORO_DOWNLOADING then
        return {{
            text = string.format(_("Downloading Kokoro voices: %d%%"), math.floor(progress * 100)),
            enabled = false,
            separator = true,
        }}
    elseif status == KOKORO_UNPACKING then
        return {{ text = _("Installing Kokoro voices…"), enabled = false, separator = true }}
    elseif status == KOKORO_MISSING or status == KOKORO_FAILED then
        return {{
            text = _("Download Kokoro voices"),
            keep_menu_open = true,
            callback = function() self:downloadKokoro() end,
            separator = true,
        }}
    end
    local items = {}
    if self:isKokoroLanguage() then
        for i, name in ipairs(KOKORO_VOICES) do
            local id = KOKORO_PREFIX .. (i - 1)
            table.insert(items, {
                text = "Kokoro: " .. name,
                checked_func = function()
                    return G_reader_settings:readSetting("read_aloud_voice") == id
                end,
                callback = function() self:setVoice(id) end,
            })
        end
    end
    table.insert(items, {
        text = _("Remove Kokoro voices"),
        keep_menu_open = true,
        callback = function() self:removeKokoro() end,
        separator = true,
    })
    return items
end

function ReadAloud:getVoiceMenu()
    local items = {
        {
            text = _("Best available"),
            checked_func = function()
                return not G_reader_settings:readSetting("read_aloud_voice")
            end,
            callback = function() self:setVoice(nil) end,
            separator = true,
        },
    }
    for _i, item in ipairs(self:getKokoroItems()) do
        table.insert(items, item)
    end
    table.insert(items, {
            text = _("Get better voices"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Voices are downloaded in the iOS Settings app, under Accessibility, in the spoken content section, then Voices. Look for Enhanced or Premium versions, then choose one here."),
                })
            end,
            separator = true,
    })
    for _i, voice in ipairs(self:getVoices()) do
        table.insert(items, {
            text = QUALITY_NAMES[voice.quality]
                and string.format("%s (%s, %s)", voice.name, voice.language, QUALITY_NAMES[voice.quality])
                or string.format("%s (%s)", voice.name, voice.language),
            checked_func = function()
                return G_reader_settings:readSetting("read_aloud_voice") == voice.id
            end,
            callback = function() self:setVoice(voice.id) end,
        })
    end
    return items
end

function ReadAloud:getSpeedMenu()
    local items = {}
    for _i, speed in ipairs(SPEEDS) do
        table.insert(items, {
            text = string.format("%g×", speed),
            checked_func = function()
                return (G_reader_settings:readSetting("read_aloud_speed") or 1) == speed
            end,
            callback = function()
                G_reader_settings:saveSetting("read_aloud_speed", speed)
                self:applySpeed()
            end,
        })
    end
    return items
end

function ReadAloud:addToMainMenu(menu_items)
    menu_items.read_aloud = {
        text = _("Read aloud"),
        sorting_hint = "navi",
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        local state = self:getState()
                        if state == STATE_SPEAKING then
                            return _("Pause")
                        elseif state == STATE_PAUSED then
                            return _("Resume")
                        end
                        return _("Read from this page")
                    end,
                    callback = function() self:onToggleReadAloud() end,
                },
                {
                    text = _("Stop"),
                    enabled_func = function() return self:getState() ~= STATE_IDLE end,
                    callback = function() self:stop() end,
                    separator = true,
                },
                {
                    text = _("Speed"),
                    sub_item_table_func = function() return self:getSpeedMenu() end,
                },
                {
                    text = _("Voice"),
                    sub_item_table_func = function() return self:getVoiceMenu() end,
                },
            }
        end,
    }
end

return ReadAloud
