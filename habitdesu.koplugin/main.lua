--[[
habitsです sync — pushes daily pages read to habitdesu.

Reads KOReader's own statistics.sqlite3 (distinct pages turned per local day)
and POSTs changed days to the log-habit edge function:

    POST <endpoint>
    Authorization: Bearer hd_live_...
    {"date":"YYYY-MM-DD","entries":[{"name":"<habit>","value":<pages>}]}

Config lives in settings/habitdesu.lua:
    return { token = "hd_live_...", habit = "read", window = 21 }

Sync triggers: KOReader start (~15s), closing a book (+5s), suspend,
network reconnect, and Tools → habitsです sync → Sync now.
All work is wrapped in pcall — a failure can never interrupt reading.
]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local ltn12 = require("ltn12")
local _ = require("gettext")

local ENDPOINT = "https://xqkgklfcxrlmjgghgzji.supabase.co/functions/v1/log-habit"

-- module-level so the FileManager and Reader instances share one rate limit
local last_auto_sync = 0

local HabitDesu = WidgetContainer:extend{
    name = "habitdesu",
    is_doc_only = false,
}

function HabitDesu:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/habitdesu.lua")
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    UIManager:scheduleIn(15, function()
        self:autoSync()
    end)
end

function HabitDesu:addToMainMenu(menu_items)
    menu_items.habitdesu = {
        text = _("habitsです sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                callback = function()
                    self:sync(true)
                end,
            },
            {
                text_func = function()
                    local token = self.settings:readSetting("token") or ""
                    local habit = self.settings:readSetting("habit") or "read"
                    local last = self.settings:readSetting("last_result") or _("never")
                    if token == "" then
                        return _("Status: no token configured")
                    end
                    return string.format("%s → %s", habit, last)
                end,
                keep_menu_open = true,
                callback = function() end,
            },
        },
    }
end

function HabitDesu:onCloseDocument()
    UIManager:scheduleIn(5, function()
        self:autoSync()
    end)
end

function HabitDesu:onSuspend()
    self:autoSync()
end

function HabitDesu:onNetworkConnected()
    UIManager:scheduleIn(5, function()
        self:autoSync()
    end)
end

function HabitDesu:autoSync()
    if os.time() - last_auto_sync < 300 then return end
    self:sync(false)
end

function HabitDesu:sync(manual)
    local ok, err = pcall(function()
        self:_sync(manual)
    end)
    if not ok then
        logger.warn("habitdesu: sync failed", err)
        if manual then
            UIManager:show(InfoMessage:new{ text = _("habitsです sync failed: ") .. tostring(err) })
        end
    end
end

function HabitDesu:_sync(manual)
    local token = self.settings:readSetting("token") or ""
    local habit = self.settings:readSetting("habit") or "read"
    local window = self.settings:readSetting("window") or 21
    if token == "" then
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("No habitsです token configured (settings/habitdesu.lua)."),
            })
        end
        return
    end
    if not NetworkMgr:isConnected() then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Not connected to a network.") })
        end
        return
    end

    last_auto_sync = os.time()

    local daily = self:getDailyPages(window)
    if daily == nil then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Could not read reading statistics.") })
        end
        return
    end

    local synced = self.settings:readSetting("synced") or {}
    local sent, failed = 0, 0
    for day, info in pairs(daily) do
        if synced[day] ~= info.total then
            if self:post(token, habit, day, info) then
                synced[day] = info.total
                sent = sent + 1
            else
                failed = failed + 1
            end
        end
    end

    -- prune bookkeeping outside the sync window (those days are final)
    local cutoff = os.date("%Y-%m-%d", os.time() - (window + 40) * 86400)
    for day in pairs(synced) do
        if day < cutoff then synced[day] = nil end
    end

    local result
    if failed > 0 then
        result = string.format(_("%d sent, %d failed"), sent, failed)
    elseif sent > 0 then
        result = string.format(_("%d day(s) sent"), sent)
    else
        result = _("up to date")
    end
    self.settings:saveSetting("synced", synced)
    self.settings:saveSetting("last_result", os.date("%m-%d %H:%M ") .. result)
    self.settings:flush()
    logger.info("habitdesu:", result)
    if manual then
        UIManager:show(InfoMessage:new{ text = _("habitsです: ") .. result })
    end
end

-- per-day, per-book pages for the last `days` days:
-- { ["2026-07-03"] = { total = 38, books = { {title=..., pages=..., minutes=...}, ... } } }
function HabitDesu:getDailyPages(days)
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local ok, conn = pcall(SQ3.open, db_path, "ro")
    if not ok or not conn then return nil end
    local sql = string.format([[
        SELECT date(ps.start_time, 'unixepoch', 'localtime') AS day,
               b.title AS title,
               count(DISTINCT ps.page) AS pages,
               sum(ps.duration) AS secs
        FROM page_stat ps
        JOIN book b ON b.id = ps.id_book
        WHERE ps.start_time >= strftime('%%s', 'now', '-%d days')
        GROUP BY day, b.id
        ORDER BY day, pages DESC;
    ]], days)
    local res_ok, res = pcall(function() return conn:exec(sql) end)
    pcall(function() conn:close() end)
    if not res_ok or not res then return {} end
    local out = {}
    for i = 1, #res[1] do
        local day = tostring(res[1][i])
        local entry = out[day] or { total = 0, books = {} }
        local pages = tonumber(res[3][i]) or 0
        entry.total = entry.total + pages
        table.insert(entry.books, {
            title = tostring(res[2][i]),
            pages = pages,
            minutes = math.floor((tonumber(res[4][i]) or 0) / 60 + 0.5),
        })
        out[day] = entry
    end
    return out
end

local function jsonEscape(s)
    return s:gsub('[\\"]', '\\%0'):gsub("[%c]", " ")
end

function HabitDesu:post(token, habit, day, info)
    -- meta mirrors the whoop/apple_health pattern so clients can render
    -- "Book title — 35 pages" when a day is tapped
    local books = {}
    for _, b in ipairs(info.books) do
        table.insert(books, string.format(
            '{"title":"%s","pages":%d,"minutes":%d}',
            jsonEscape(b.title), b.pages, b.minutes))
    end
    local body = string.format(
        '{"date":"%s","entries":[{"name":"%s","value":%d,"meta":{"source":"koreader","books":[%s]}}]}',
        day, jsonEscape(habit), info.total, table.concat(books, ","))
    local sink = {}
    local requester = require("ssl.https")
    local has_su, socketutil = pcall(require, "socketutil")
    if has_su then socketutil:set_timeout(10, 30) end
    local ok, code = pcall(function()
        local _res, c = requester.request{
            url = ENDPOINT,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
                ["Authorization"] = "Bearer " .. token,
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
        }
        return c
    end)
    if has_su then socketutil:reset_timeout() end
    if not ok then
        logger.warn("habitdesu: request error", code)
        return false
    end
    if code == 200 or code == 201 then
        return true
    end
    logger.warn("habitdesu: HTTP", code, table.concat(sink))
    return false
end

return HabitDesu
