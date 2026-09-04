--[[
Habits First sync — pushes daily pages read to Habits First.

Reads KOReader's own statistics.sqlite3 (distinct pages turned per local
day) and upserts changed days into the Habits First inbox:

    POST /rest/v1/hf_reports   (x-hf-token: hf_...)
    [{"token":"hf_...","channel":"koreader","day":"YYYY-MM-DD","value":N,
      "meta":{"source":"koreader","plugin":"1.1.0","books":[{title,pages,minutes},...]}}]

Pairing: on first run the plugin generates its own hf_ token, posts
{code, token} to the hf_pairings handshake table, and shows a 6-digit
code (popup + Tools → Habits First sync). Entering the code in the app
adopts the token — nothing to type on the reader, no files to edit.
Pairing is only offered for tokens the plugin minted itself: a token it
did not mint (hand-written settings, an installer that provisioned one)
is treated as already paired. Hand-set settings/habitsfirst.lua:
    return { token = "hf_...", channel = "koreader", window = 21 }
(A legacy settings/habitdesu.lua with an hf_ token also works.)

Sync triggers: KOReader start (~15s), closing a book (+5s), suspend,
network reconnect, page turns (throttled to one sync per ~25s, with a
statistics flush first so the page just turned is included), and
Tools → Habits First sync → Sync now.
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

-- Where updates come from: the public repo's latest release. The
-- files are fetched by tag from raw.githubusercontent.com and dropped
-- over this folder; KOReader loads them on its next start.
local HF_REPO = "reysu/habitsfirst-koreader"
local HF_RELEASE_API = "https://api.github.com/repos/" .. HF_REPO .. "/releases/latest"
local HF_RAW = "https://raw.githubusercontent.com/" .. HF_REPO .. "/"
local PLUGIN_FILES = { "main.lua", "_meta.lua" }

local HF_ENDPOINT = "https://xqkgklfcxrlmjgghgzji.supabase.co/rest/v1/hf_reports"
local HF_PAIRINGS = "https://xqkgklfcxrlmjgghgzji.supabase.co/rest/v1/hf_pairings"
local HF_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhxa2drbGZjeHJsbWpnZ2hnemppIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4Njg3NjcsImV4cCI6MjA5ODQ0NDc2N30.WyK2OLUxYTjsq5KBMClpn8SQDWz-g0di_k7NpJ-n6QU"

-- module-level so the FileManager and Reader instances share one rate limit
local last_auto_sync = 0

-- Hex from /dev/urandom, with a clock-mix fallback for platforms that
-- hide it. Token quality matters: the token IS the account boundary.
local function randomHex(bytes)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local raw = f:read(bytes)
        f:close()
        if raw and #raw == bytes then
            local out = {}
            for i = 1, #raw do out[i] = string.format("%02x", raw:byte(i)) end
            return table.concat(out)
        end
    end
    math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6))
    local out = {}
    for i = 1, bytes do out[i] = string.format("%02x", math.random(0, 255)) end
    return table.concat(out)
end

local HabitsFirst = WidgetContainer:extend{
    name = "habitsfirst",
    is_doc_only = false,
}

function HabitsFirst:init()
    local dir = DataStorage:getSettingsDir()
    self.settings = LuaSettings:open(dir .. "/habitsfirst.lua")
    -- The version lives in _meta.lua only (the release workflow reads it
    -- from there too); it shows in the menu so a bug report can name it.
    self.plugin_dir = self.path or (DataStorage:getDataDir() .. "/plugins/habitsfirst.koplugin")
    self.version = "?"
    local ok_meta, meta = pcall(dofile, self.plugin_dir .. "/_meta.lua")
    if ok_meta and type(meta) == "table" and meta.version then
        self.version = tostring(meta.version)
    end
    if (self.settings:readSetting("token") or "") == "" then
        -- Legacy install: the settings file kept its old name.
        local legacy = LuaSettings:open(dir .. "/habitdesu.lua")
        if (legacy:readSetting("token") or ""):sub(1, 3) == "hf_" then
            self.settings = legacy
        end
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if (self.settings:readSetting("token") or "") == "" then
        -- First run: mint the token now; reports start piling up under it
        -- immediately and history is already there when the app pairs.
        -- "minted" marks the token as OURS: only minted tokens ever offer
        -- pairing. A token we did not mint (hand-written settings, an
        -- installer that provisioned one) is already known to an app.
        self.settings:saveSetting("token", "hf_" .. randomHex(16))
        self.settings:saveSetting("minted", true)
        self.settings:flush()
    end
    UIManager:scheduleIn(15, function()
        if self:needsPairing() then self:offerPairing(true) end
        self:autoSync()
    end)
end

-- Paired = the app claimed our row (it deletes the row on claim). Until
-- then we keep a live code posted. "paired" survives restarts. Tokens we
-- did not mint never pair: whoever wrote them already has them.
function HabitsFirst:needsPairing()
    if not self.settings:readSetting("minted") then return false end
    return not self.settings:readSetting("paired")
end

-- Ensure a fresh pairing row exists and (optionally) pop the code up.
function HabitsFirst:offerPairing(popup)
    local ok, err = pcall(function()
        local token = self.settings:readSetting("token") or ""
        if token == "" then return end
        local code = self.settings:readSetting("pair_code")
        local at = self.settings:readSetting("pair_at") or 0
        if not code or os.time() - at > 12 * 60 then
            code = string.format("%06d", tonumber(randomHex(3), 16) % 1000000)
            if not self:postPairing(code, token) then return end
            self.settings:saveSetting("pair_code", code)
            self.settings:saveSetting("pair_at", os.time())
            self.settings:flush()
        end
        if popup then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Habits First pairing code: %s\n\nIn the app: More integrations → KOReader → enter this code."), code),
                timeout = 30,
            })
        end
    end)
    if not ok then logger.warn("habitsfirst: pairing failed", err) end
end

-- The app deletes the claimed row; a row missing well before its 15 min
-- TTL therefore means "paired". Called after each sync.
function HabitsFirst:checkPaired()
    if not self:needsPairing() then return end
    local code = self.settings:readSetting("pair_code")
    local at = self.settings:readSetting("pair_at") or 0
    if not code then return end
    local age = os.time() - at
    if age < 60 or age > 13 * 60 then return end
    local sink = {}
    local requester = require("ssl.https")
    local okReq, result = pcall(function()
        local _res, c = requester.request{
            url = HF_PAIRINGS .. "?code=eq." .. code .. "&select=code",
            method = "GET",
            headers = { ["apikey"] = HF_ANON, ["Authorization"] = "Bearer " .. HF_ANON },
            sink = ltn12.sink.table(sink),
        }
        return c
    end)
    if okReq and result == 200 and table.concat(sink) == "[]" then
        self.settings:saveSetting("paired", true)
        self.settings:flush()
        logger.info("habitsfirst: paired")
    end
end

function HabitsFirst:postPairing(code, token)
    local body = string.format('[{"code":"%s","token":"%s"}]', code, token)
    local sink = {}
    local requester = require("ssl.https")
    local ok, result = pcall(function()
        local _res, c = requester.request{
            url = HF_PAIRINGS,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
                ["apikey"] = HF_ANON,
                ["Authorization"] = "Bearer " .. HF_ANON,
                ["Prefer"] = "resolution=merge-duplicates",
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
        }
        return c
    end)
    return ok and (result == 200 or result == 201)
end

function HabitsFirst:addToMainMenu(menu_items)
    menu_items.habitsfirst = {
        text = _("Habits First sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    if self:needsPairing() then
                        local code = self.settings:readSetting("pair_code")
                        if code then
                            return string.format(_("Pairing code: %s (tap to renew)"), code)
                        end
                        return _("Get pairing code")
                    end
                    return _("Paired with the app")
                end,
                keep_menu_open = true,
                callback = function()
                    if self:needsPairing() then
                        self.settings:saveSetting("pair_at", 0)
                        self:offerPairing(true)
                    end
                end,
            },
            {
                text = _("Sync now"),
                callback = function()
                    self:sync(true)
                end,
            },
            {
                -- Forget the pairing, mint a fresh token and offer its code
                -- straight away. Replacing the plugin folder never touches
                -- the settings file, so a reader stayed paired to a token no
                -- phone held any more and there was no way out but deleting
                -- the file by hand (Eric, 09-02).
                text = _("Unpair"),
                enabled_func = function() return not self:needsPairing() end,
                callback = function()
                    for _i, k in ipairs({ "paired", "pair_code", "pair_at", "last_result" }) do
                        self.settings:delSetting(k)
                    end
                    self.settings:saveSetting("token", "hf_" .. randomHex(16))
                    self.settings:saveSetting("minted", true)
                    self.settings:flush()
                    self:offerPairing(true)
                end,
            },
            {
                text_func = function()
                    local token = self.settings:readSetting("token") or ""
                    local channel = self.settings:readSetting("channel") or "koreader"
                    local last = self.settings:readSetting("last_result") or _("never")
                    if token == "" then
                        return _("Status: no token configured")
                    end
                    return string.format("v%s · %s → %s", self.version, channel, last)
                end,
                keep_menu_open = true,
                callback = function() end,
            },
            {
                -- copy-pending
                text_func = function()
                    return string.format(_("Check for updates (v%s)"), self.version)
                end,
                keep_menu_open = true,
                callback = function()
                    self:checkForUpdates(true)
                end,
            },
            {
                -- copy-pending
                text = _("Update automatically"),
                checked_func = function()
                    return self.settings:readSetting("auto_update") ~= false
                end,
                callback = function()
                    local on = self.settings:readSetting("auto_update") ~= false
                    self.settings:saveSetting("auto_update", not on)
                    self.settings:flush()
                end,
            },
        },
    }
end

-- MARK: Updates

local function httpGet(url, headers)
    local sink = {}
    local requester = require("ssl.https")
    local has_su, socketutil = pcall(require, "socketutil")
    if has_su then socketutil:set_timeout(10, 30) end
    local ok, code = pcall(function()
        local _res, c = requester.request{
            url = url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(sink),
        }
        return c
    end)
    if has_su then pcall(function() socketutil:reset_timeout() end) end
    if not ok or code ~= 200 then return nil, code end
    return table.concat(sink), code
end

-- "1.2.10" > "1.2.9": numeric per segment, missing segments read as 0.
local function isNewer(candidate, current)
    local a, b = {}, {}
    for n in tostring(candidate):gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in tostring(current):gmatch("%d+") do b[#b + 1] = tonumber(n) end
    if #a == 0 then return false end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- Latest release tag on GitHub, without the leading "v"; nil offline or
-- when the API answers anything but a release.
function HabitsFirst:latestVersion()
    local body = httpGet(HF_RELEASE_API, {
        ["User-Agent"] = "habitsfirst-koplugin/" .. self.version,
        ["Accept"] = "application/vnd.github+json",
    })
    if not body then return nil end
    return body:match('"tag_name"%s*:%s*"v?([%d%.]+)"')
end

-- Fetch every plugin file at the tag, check that main.lua at least
-- compiles, then swap them in. A half-fetched update never replaces a
-- working plugin: files land as .new first and rename only once all of
-- them are on disk.
function HabitsFirst:installVersion(version)
    local fetched = {}
    for _i, name in ipairs(PLUGIN_FILES) do
        local body = httpGet(HF_RAW .. "v" .. version .. "/habitsfirst.koplugin/" .. name, {
            ["User-Agent"] = "habitsfirst-koplugin/" .. self.version,
        })
        if not body or #body == 0 then return false, name end
        if name:match("%.lua$") then
            local compile = loadstring or load
            if not compile(body, "=" .. name) then return false, name end
        end
        fetched[name] = body
    end
    for name, body in pairs(fetched) do
        local f = io.open(self.plugin_dir .. "/" .. name .. ".new", "w")
        if not f then return false, name end
        f:write(body)
        f:close()
    end
    for name in pairs(fetched) do
        local ok = os.rename(self.plugin_dir .. "/" .. name .. ".new", self.plugin_dir .. "/" .. name)
        if not ok then return false, name end
    end
    return true
end

-- Manual: always reports. Automatic (autoSync, once a day): silent
-- unless an update actually landed, when it asks for the restart.
function HabitsFirst:checkForUpdates(manual)
    if not NetworkMgr:isConnected() then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Not connected to a network.") })
        end
        return
    end
    local latest = self:latestVersion()
    if not latest then
        if manual then
            -- copy-pending
            UIManager:show(InfoMessage:new{ text = _("Could not check for updates.") })
        end
        return
    end
    if not isNewer(latest, self.version) then
        if manual then
            -- copy-pending
            UIManager:show(InfoMessage:new{ text = string.format(_("Up to date (v%s)."), self.version) })
        end
        return
    end
    local ok, failed = self:installVersion(latest)
    if not ok then
        logger.warn("habitsfirst: update to", latest, "failed at", failed)
        if manual then
            -- copy-pending
            UIManager:show(InfoMessage:new{ text = string.format(_("Could not download v%s."), latest) })
        end
        return
    end
    logger.info("habitsfirst: updated to", latest)
    -- copy-pending
    UIManager:show(InfoMessage:new{
        text = string.format(_("Updated to v%s. Restart KOReader to finish."), latest),
    })
end

function HabitsFirst:autoUpdateCheck()
    if self.settings:readSetting("auto_update") == false then return end
    local today = os.date("%Y-%m-%d")
    if self.settings:readSetting("update_checked") == today then return end
    self.settings:saveSetting("update_checked", today)
    self.settings:flush()
    local ok, err = pcall(function() self:checkForUpdates(false) end)
    if not ok then logger.warn("habitsfirst: update check failed", err) end
end

function HabitsFirst:onCloseDocument()
    UIManager:scheduleIn(5, function()
        self:autoSync()
    end)
end

function HabitsFirst:onSuspend()
    self:autoSync()
end

function HabitsFirst:onNetworkConnected()
    UIManager:scheduleIn(5, function()
        self:autoSync()
    end)
end

function HabitsFirst:autoSync()
    if os.time() - last_auto_sync < 300 then return end
    self:sync(false)
    self:autoUpdateCheck()
end

-- Near-live page counts (card d0e8dcaa): a page turn schedules a sync
-- ~25s out, throttled to one pending timer at a time, skipping the
-- 5-minute autoSync limit. The statistics plugin is flushed first so
-- the page just turned is already in the DB when we read it.
local PAGE_SYNC_DELAY = 25

function HabitsFirst:onPageUpdate()
    if self.page_sync_pending then return end
    self.page_sync_pending = true
    UIManager:scheduleIn(PAGE_SYNC_DELAY, function()
        self.page_sync_pending = nil
        self:flushStatistics()
        self:sync(false)
    end)
end

-- Ask the statistics plugin to write its in-memory page data to the DB.
-- pcall absorbs signature drift across KOReader versions: if the flush
-- fails we just sync numbers that are a page or two stale.
function HabitsFirst:flushStatistics()
    local ok, err = pcall(function()
        local st = self.ui and self.ui.statistics
        if st and st.insertDB then st:insertDB() end
    end)
    if not ok then logger.dbg("habitsfirst: stats flush failed", err) end
end

function HabitsFirst:sync(manual)
    local ok, err = pcall(function()
        self:_sync(manual)
    end)
    if not ok then
        logger.warn("habitsfirst: sync failed", err)
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Habits First sync failed: ") .. tostring(err) })
        end
    end
end

function HabitsFirst:_sync(manual)
    local token = self.settings:readSetting("token") or ""
    local channel = self.settings:readSetting("channel") or "koreader"
    local window = self.settings:readSetting("window") or 21
    if token:sub(1, 3) ~= "hf_" then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("No token — restart KOReader to generate one.") })
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
    local synced_min = self.settings:readSetting("synced_min") or {}
    local sent, failed = 0, 0
    for day, info in pairs(daily) do
        if synced[day] ~= info.total then
            if self:post(token, channel, day, info) then
                synced[day] = info.total
                sent = sent + 1
            else
                failed = failed + 1
            end
        end
        -- Sibling channel "<channel>.minutes": minutes-read goals in the
        -- app read this; pages stay the primary value above.
        if info.minutes and synced_min[day] ~= info.minutes then
            if self:postValue(token, channel .. ".minutes", day, info.minutes) then
                synced_min[day] = info.minutes
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
    for day in pairs(synced_min) do
        if day < cutoff then synced_min[day] = nil end
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
    self.settings:saveSetting("synced_min", synced_min)
    self.settings:saveSetting("last_result", os.date("%m-%d %H:%M ") .. result)
    self.settings:flush()
    self:checkPaired()
    if self:needsPairing() then self:offerPairing(false) end
    logger.info("habitsfirst:", result)
    if manual then
        UIManager:show(InfoMessage:new{ text = _("Habits First: ") .. result })
    end
end

-- per-day, per-book pages for the last `days` days:
-- { ["2026-07-03"] = { total = 38, books = { {title=..., pages=..., minutes=...}, ... } } }
function HabitsFirst:getDailyPages(days)
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
    -- Seconds are summed first and turned into minutes ONCE, to a tenth:
    -- rounding each book to a whole minute and adding those up reported
    -- three 25-second reads as 0 minutes (Eric, 09-04).
    local function tenths(secs) return math.floor(secs / 6 + 0.5) / 10 end
    local out = {}
    for i = 1, #res[1] do
        local day = tostring(res[1][i])
        local entry = out[day] or { total = 0, secs = 0, books = {} }
        local pages = tonumber(res[3][i]) or 0
        local secs = tonumber(res[4][i]) or 0
        entry.total = entry.total + pages
        entry.secs = entry.secs + secs
        table.insert(entry.books, {
            title = tostring(res[2][i]),
            pages = pages,
            minutes = tenths(secs),
        })
        out[day] = entry
    end
    for _, entry in pairs(out) do
        entry.minutes = tenths(entry.secs)
        entry.secs = nil
    end
    return out
end

-- Post a bare number to a channel (no books meta) — the minutes sibling.
function HabitsFirst:postValue(token, channel, day, value)
    return self:post(token, channel, day, { total = value, books = {} })
end

local function jsonEscape(s)
    return s:gsub('[\\"]', '\\%0'):gsub("[%c]", " ")
end

-- Whole numbers stay bare ("37"), tenths keep one decimal ("68.4"): the
-- pages value is an integer and the minutes value may not be.
local function jsonNumber(x)
    if x == math.floor(x) then return string.format("%d", x) end
    return string.format("%.1f", x)
end

function HabitsFirst:post(token, channel, day, info)
    -- meta lets clients render "Book title — 35 pages" when a day is tapped
    local books = {}
    for _, b in ipairs(info.books) do
        table.insert(books, string.format(
            '{"title":"%s","pages":%d,"minutes":%s}',
            jsonEscape(b.title), b.pages, jsonNumber(b.minutes)))
    end
    local body = string.format(
        '[{"token":"%s","channel":"%s","day":"%s","value":%s,"meta":{"source":"koreader","plugin":"%s","books":[%s]}}]',
        token, jsonEscape(channel), day, jsonNumber(info.total), jsonEscape(self.version or "?"), table.concat(books, ","))
    local sink = {}
    local requester = require("ssl.https")
    local has_su, socketutil = pcall(require, "socketutil")
    if has_su then socketutil:set_timeout(10, 30) end
    local ok, code = pcall(function()
        local _res, c = requester.request{
            url = HF_ENDPOINT,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
                ["apikey"] = HF_ANON,
                ["Authorization"] = "Bearer " .. HF_ANON,
                ["x-hf-token"] = token,
                ["Prefer"] = "resolution=merge-duplicates",
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
        }
        return c
    end)
    if has_su then socketutil:reset_timeout() end
    if not ok then
        logger.warn("habitsfirst: request error", code)
        return false
    end
    if code == 200 or code == 201 then
        return true
    end
    logger.warn("habitsfirst: HTTP", code, table.concat(sink))
    return false
end

return HabitsFirst
