-- InkgloSpace Was Here!
-- ER6_v1.1.6
----------------------------------------------------------------
-- Config
local POLL_MS = 0.5
local REQ_TIMEOUT = 2.0
local PENDING_MS = 0.7 

-- Mode tombol "RelayAll": true=Toggle, false=Momentary
local RELAY_ALL_TOGGLE = false

----------------------------------------------------------------
-- Require untuk Digest path
local HttpClient = require("HttpClient")

----------------------------------------------------------------
-- Utils
local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
local function set_text(ctrl, txt)
    if not ctrl then
        return
    end
    if pcall(function()
        ctrl.String = txt
    end) then
        return
    end
    if pcall(function()
        ctrl.Text = txt
    end) then
        return
    end
    if pcall(function()
        ctrl.ValueText = txt
    end) then
        return
    end
    pcall(function()
        ctrl.SetString(txt)
    end)
end
local function get_text(ctrl)
    if not ctrl then
        return ""
    end
    local v
    pcall(function()
        v = ctrl.String
    end);
    if v and v ~= "" then
        return v
    end
    pcall(function()
        v = ctrl.Text
    end);
    if v and v ~= "" then
        return v
    end
    pcall(function()
        v = ctrl.ValueText
    end);
    if v and v ~= "" then
        return v
    end
    pcall(function()
        v = tostring(ctrl.Value)
    end)
    return v or ""
end
local function get_val(ctrl)
    local v = 0;
    if ctrl then
        pcall(function()
            v = ctrl.Value
        end)
    end
    return tonumber(v) or 0
end
local function set_val_no_event(ctrl, v)
    if not ctrl then
        return
    end
    local old = ctrl.EventHandler
    ctrl.EventHandler = nil
    pcall(function()
        ctrl.Value = v
    end)
    ctrl.EventHandler = old
end

local function set_led(on)
    local L = Controls["StatusLED"]
    if L then
        pcall(function()
            L.Value = on and 1 or 0
        end)
    end
end
local function now_s()
    return os.clock()
end

----------------------------------------------------------------
-- UI refs
local mon = Controls["RemoteMonitor"]
local ipBx = Controls["DeviceIP"]
local ptBx = Controls["DevicePort"]
local usrBx = Controls["DeviceUser"]
local pwdBx = Controls["DevicePassword"]

local r0 = Controls["Relay0"]
local r1 = Controls["Relay1"]
local r2 = Controls["Relay2"]
local r3 = Controls["Relay3"]
local r4 = Controls["Relay4"]
local r5 = Controls["Relay5"]
local rall = Controls["RelayAll"]

-- Relay helpers
local RELAY_COUNT = 6
local relCtrls = {r0, r1, r2, r3, r4, r5}

-- Groups (A..D)
local grpA, grpB, grpC, grpD = Controls["GroupA"], Controls["GroupB"], Controls["GroupC"], Controls["GroupD"]
local asnA, asnB, asnC, asnD = Controls["AssignA"], Controls["AssignB"], Controls["AssignC"], Controls["AssignD"]
local clrA, clrB, clrC, clrD = Controls["ClearA"], Controls["ClearB"], Controls["ClearC"], Controls["ClearD"]

-- Ping
local pingBtn = Controls["Ping"]

----------------------------------------------------------------
-- State
local HOST, PORT = "", 4444
local AUTH_USER, AUTH_PASS = "", ""
local USE_DIGEST = false

local pollT = Timer.New()
local inflight_get = false

local ALL_DEBOUNCE = 0.15
local last_all_fire_at = 0

local relaysState = {
    [0] = 0,
    [1] = 0,
    [2] = 0,
    [3] = 0,
    [4] = 0,
    [5] = 0
} -- cache state device
-- pending window per-relay (abaikan polling yg belum match selama window aktif)
local pend_target = {
    [0] = nil,
    [1] = nil,
    [2] = nil,
    [3] = nil,
    [4] = nil,
    [5] = nil
}
local pend_until = {
    [0] = 0,
    [1] = 0,
    [2] = 0,
    [3] = 0,
    [4] = 0,
    [5] = 0
}

-- cache aksi UI biar gak spam nilai sama
local lastUI = {
    [0] = -1,
    [1] = -1,
    [2] = -1,
    [3] = -1,
    [4] = -1,
    [5] = -1
}
local groupFetchNextAllowed = 0.0 -- throttle pull /groups

-- Set semua tombol relay di UI (+ optional pending window/optimistic)
local function set_relays_ui(target, with_pending)
    local tUntil = now_s() + PENDING_MS
    for i = 0, RELAY_COUNT - 1 do
        local ctrl = relCtrls[i + 1]
        if ctrl then
            set_val_no_event(ctrl, target)
        end
        if with_pending then
            lastUI[i] = target
            relaysState[i] = target
            pend_target[i] = target
            pend_until[i] = tUntil
        end
    end
end

----------------------------------------------------------------
-- Builder URL untuk HttpClient + parser query
local function parse_query(qs)
    local t = {}
    if not qs or qs == "" then
        return t
    end
    for kv in string.gmatch(qs, "([^&]+)") do
        local k, v = kv:match("^([^=]+)=?(.*)$")
        if k then
            t[k] = v
        end
    end
    return t
end

local function make_url_for_httpclient(full_path)
    local p, q = full_path, nil
    local qi = full_path:find("?", 1, true)
    if qi then
        p = full_path:sub(1, qi - 1)
        q = parse_query(full_path:sub(qi + 1))
    end
    return HttpClient.CreateUrl {
        Scheme = "http",
        Host = HOST,
        Port = PORT,
        Path = p,
        Query = q
    }
end

----------------------------------------------------------------
-- HTTP GET via TcpSocket (tanpa auth)
local function tcp_http_get(path, cb)
    if HOST == "" or not PORT then
        if cb then
            cb(false, "no-host")
        end
        return
    end
    local s = TcpSocket.New()
    s.ReadTimeout, s.WriteTimeout = 2, 2

    local buf, got_eoh, body = "", false, nil
    local done = false
    local killer = Timer.New()
    killer.EventHandler = function()
        if not done then
            done = true
            if cb then
                cb(false, "timeout")
            end
            pcall(function()
                s:Disconnect()
            end)
        end
        killer:Stop()
    end

    s.EventHandler = function(_, e, err)
        if e == TcpSocket.Events.Connected then
            s:Write("GET " .. path .. " HTTP/1.1\r\nHost: " .. HOST .. "\r\nConnection: close\r\n\r\n")
            killer:Start(REQ_TIMEOUT)

        elseif e == TcpSocket.Events.Data then
            local chunk = s:ReadLine(TcpSocket.EOL.Any)
            while chunk do
                buf = (buf or "") .. chunk .. "\n"
                chunk = s:ReadLine(TcpSocket.EOL.Any)
            end
            if not got_eoh and buf and #buf > 0 then
                local p = buf:find("\r\n\r\n", 1, true) or buf:find("\n\n", 1, true) or buf:find("\r\r", 1, true)
                if p then
                    got_eoh = true
                    local jump = (buf:sub(p, p + 3) == "\r\n\r\n") and 4 or 2
                    body = buf:sub(p + jump)
                end
            end

        elseif e == TcpSocket.Events.Closed then
            if done then
                return
            end
            done = true
            killer:Stop()
            if (not body or #body == 0) and buf and #buf > 0 then
                body = buf
            end
            if body and #body > 0 then
                if cb then
                    cb(true, body)
                end
            else
                if cb then
                    cb(false, "no-body")
                end
            end
            pcall(function()
                s:Disconnect()
            end)

        elseif e == TcpSocket.Events.Error then
            if done then
                return
            end
            done = true
            killer:Stop()
            if cb then
                cb(false, tostring(err))
            end
            pcall(function()
                s:Disconnect()
            end)
        end
    end

    s:Connect(HOST, PORT)
end

----------------------------------------------------------------
-- HTTP GET via HttpClient Digest
local function digest_http_get(path, cb)
    local url = make_url_for_httpclient(path)
    HttpClient.Get {
        Url = url,
        User = AUTH_USER,
        Password = AUTH_PASS,
        Auth = "digest",
        Timeout = 5,
        EventHandler = function(_, code, data, err)
            if code == 200 and data and #data > 0 then
                if cb then
                    cb(true, data)
                end
            elseif code == 200 then
                if cb then
                    cb(false, "no-body")
                end
            else
                if cb then
                    cb(false, err or tostring(code))
                end
            end
        end
    }
end

----------------------------------------------------------------
-- http_get: otomatis pilih Digest atau TcpSocket
local function http_get(path, cb)
    if USE_DIGEST and AUTH_USER ~= "" and AUTH_PASS ~= "" then
        return digest_http_get(path, cb)
    else
        return tcp_http_get(path, cb)
    end
end

----------------------------------------------------------------
-- Helpers
local function mask_from_relays()
    local m = 0
    for i = 0, 5 do
        if (relaysState[i] or 0) ~= 0 then
            m = m | (1 << i)
        end
    end
    return m
end

----------------------------------------------------------------
-- Apply status sinkron tombol & LED
local function apply_status(body)
    local b = (body or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local arr = b:match('"relays"%s*:%s*%[([^%]]*)%]') or b:match("relays%s*:%s*%[([^%]]*)%]") or
                    b:match("%[([^%]]*)%]")
    if not arr then
        set_text(mon, "bad status")
        set_led(false)
        return
    end

    local nums = {}
    for n in arr:gmatch("([%-]?%d+)") do
        local v = tonumber(n)
        if v then
            nums[#nums + 1] = v
        end
        if #nums >= 6 then
            break
        end
    end

    local tnow = now_s()
    for i = 0, 5 do
        local dev = nums[i + 1] or 0
        local pend = pend_target[i]
        if pend ~= nil and tnow < (pend_until[i] or 0) and dev ~= pend then
            -- pending window 
        else
            relaysState[i] = dev
            pend_target[i] = nil
            pend_until[i] = 0
        end
    end

    -- update tombol (tanpa trigger) + sinkron lastUI
    for i = 0, RELAY_COUNT - 1 do
        local on = relaysState[i] ~= 0 and 1 or 0
        set_val_no_event(relCtrls[i + 1], on)
        lastUI[i] = relaysState[i]
    end

    -- sinkron status tombol "All"
    -- jika mode Toggle: mirror 1 bila SEMUA ON (biar LED tombol nyala)
    -- jika mode Momentary: jangan mirror; jaga OFF supaya tampil momentary
    if rall then
        if RELAY_ALL_TOGGLE then
            local allOn = 1
            for i = 0, 5 do
                if (relaysState[i] or 0) == 0 then
                    allOn = 0
                    break
                end
            end
            set_val_no_event(rall, allOn)
        else
            -- momentary: OFF (visual), supaya tidak terlihat nempel
            set_val_no_event(rall, 0)
        end
    end

    set_text(mon,
        ("Status:[%d,%d,%d,%d,%d,%d]"):format(relaysState[0], relaysState[1], relaysState[2], relaysState[3],
            relaysState[4], relaysState[5]))
    set_led(true)

    -- tarik grup (throttle biar gak banjir)
    local now = now_s()
    if now >= (groupFetchNextAllowed or 0) then
        groupFetchNextAllowed = now + 1.2
        -- soft refresh (false)
        refresh_groups(false)
    end
end

----------------------------------------------------------------
-- Polling
local function poll_once()
    if inflight_get or HOST == "" then
        return
    end
    inflight_get = true
    http_get("/inkglo/status", function(ok, body)
        inflight_get = false
        if ok then
            apply_status(body)
        else
            set_led(false)
            set_text(mon, "poll err: " .. tostring(body))
        end
    end)
end
pollT.EventHandler = function()
    poll_once()
end

----------------------------------------------------------------
-- Reconnect (IP/Port/User/Pass dari UI)
local function reconnect()
    local ip = trim(get_text(ipBx))
    local pr = tonumber(trim(get_text(ptBx))) or 0
    local us = trim(get_text(usrBx)) or ""
    local pw = trim(get_text(pwdBx)) or ""

    if ip == "" then
        set_led(false);
        set_text(mon, "Masukkan IP device");
        pollT:Stop();
        return
    end
    if pr < 1 or pr > 65535 then
        pr = 80
        if ptBx then
            if ptBx.String ~= nil then
                ptBx.String = "80"
            else
                ptBx.Value = 80
            end
        end
    end

    HOST, PORT = ip, pr
    AUTH_USER, AUTH_PASS = us, pw
    USE_DIGEST = (AUTH_USER ~= "" and AUTH_PASS ~= "") -- aktifkan Digest bila kredensial ada

    set_text(mon, ("Connecting to %s:%d ..."):format(HOST, PORT))
    set_led(false)

    http_get("/inkglo/status", function(ok, body)
        if ok then
            apply_status(body)
            pollT:Stop();
            pollT:Start(POLL_MS)
            -- hard refresh grup saat connect
            refresh_groups(true)
        else
            set_led(false)
            set_text(mon, "connect fail: " .. tostring(body))
            pollT:Stop()
        end
    end)
end
if ipBx then
    ipBx.EventHandler = function()
        reconnect()
    end
end
if ptBx then
    ptBx.EventHandler = function()
        reconnect()
    end
end
if usrBx then
    usrBx.EventHandler = function()
        reconnect()
    end
end
if pwdBx then
    pwdBx.EventHandler = function()
        reconnect()
    end
end

----------------------------------------------------------------
-- GPIO
local function send_gpio(idx, v)
    local path = ("/inkglo/gpio/%d?value=%d"):format(idx, v)
    set_text(mon, "Req: " .. path)
    http_get(path, function(ok, body)
        if ok then
            local preview = (tostring(body):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, 120)
            set_text(mon, ("OK R%d->%d: %s"):format(idx, v, preview))
        else
            set_text(mon, ("ERR R%d->%d: %s"):format(idx, v, tostring(body)))
        end
    end)
end

--  ALL
local function send_gpio_all(target)
    local path = ("/inkglo/gpio/all?value=%d"):format(target)
    set_text(mon, "Req ALL: " .. path)
    http_get(path, function(ok, body)
        if ok then
            local preview = (tostring(body):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, 120)
            set_text(mon, ("OK ALL->%d: %s"):format(target, preview))
        else
            set_text(mon, ("ERR ALL->%d: %s"):format(target, tostring(body)))
        end
    end)
end

local function bind_relay_ui_as_source(btn, idx)
    if not btn then
        return
    end
    btn.EventHandler = function(ctrl)
        local v = (get_val(btn) > 0.5) and 1 or 0
        if lastUI[idx] == v and relaysState[idx] == v then
            return
        end
        lastUI[idx] = v

        -- optimistic + pending
        relaysState[idx] = v
        pend_target[idx] = v
        pend_until[idx] = now_s() + PENDING_MS

        send_gpio(idx, v)
    end
end

bind_relay_ui_as_source(r0, 0)
bind_relay_ui_as_source(r1, 1)
bind_relay_ui_as_source(r2, 2)
bind_relay_ui_as_source(r3, 3)
bind_relay_ui_as_source(r4, 4)
bind_relay_ui_as_source(r5, 5)

-- Group All (toggle / momentary)
if rall then
    -- true bila boleh mengeksekusi (edge detect + debounce)
    local function can_fire_all()
        local t = now_s()
        if (t - last_all_fire_at) < ALL_DEBOUNCE then
            return false
        end
        last_all_fire_at = t
        return true
    end

    if RELAY_ALL_TOGGLE then
        -- === MODE TOGGLE ===
        rall.EventHandler = function(c)
            -- Edge detect berbasis perubahan Value (tanpa andalkan c.Boolean)
            if not can_fire_all() then
                return
            end
            local target = (get_val(rall) > 0.5) and 1 or 0

            -- UI + optimistic + pending
            set_relays_ui(target, true)

            -- panggil endpoint ALL
            send_gpio_all(target)
        end
    else
        -- === MODE MOMENTARY ===
        rall.EventHandler = function(c)
            -- Jangan andalkan c.Boolean; cukup debounce
            if not can_fire_all() then
                return
            end

            -- majority rule menentukan ON/OFF massal
            local onCnt = 0
            for i = 0, RELAY_COUNT - 1 do
                if (relaysState[i] or 0) ~= 0 then
                    onCnt = onCnt + 1
                end
            end
            local target = (onCnt >= 4) and 0 or 1

            -- UI + optimistic + pending
            set_relays_ui(target, true)

            -- panggil endpoint ALL
            send_gpio_all(target)

            -- momentary: biarkan tombol visual OFF
            set_val_no_event(rall, 0)
        end
    end
end

----------------------------------------------------------------
-- Ping
local PING_DEBOUNCE = 0.2
local last_ping_t = 0
local function do_ping()
    local t0 = now_s()
    set_text(mon, "Req: /inkglo/ping")
    http_get("/inkglo/ping", function(ok, body_or_err)
        local dt_ms = math.floor((now_s() - t0) * 1000 + 0.5)
        if ok then
            local preview = (tostring(body_or_err):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, 160)
            set_text(mon, string.format("PING >> %s", preview))
        else
            set_text(mon, string.format("PING ERR (%d ms): %s", dt_ms, tostring(body_or_err)))
        end
    end)
end
if pingBtn then
    pingBtn.EventHandler = function(c)
        if c.Boolean ~= true then
            return
        end
        local t = now_s()
        if (t - last_ping_t) < PING_DEBOUNCE then
            return
        end
        last_ping_t = t
        do_ping()
    end
end

----------------------------------------------------------------
-- GROUPS
-- Tombol di UI (urut fix A..D = idx 0..3)
local groupBtns = {grpA, grpB, grpC, grpD}
local assignBtns = {asnA, asnB, asnC, asnD}
local clearBtns = {clrA, clrB, clrC, clrD}

-- Cache dari device per index
local devLabelByIdx = {"", "", "", ""} -- label device per slot
local grpMaskByIdx = {0, 0, 0, 0} -- mask>0 = terisi

-- Helper legend (aman di berbagai style)
local function set_legend(ctrl, txt)
    if not ctrl then
        return
    end
    if pcall(function()
        ctrl.Legend = txt
    end) then
        return
    end
    if pcall(function()
        ctrl.Text = txt
    end) then
        return
    end
    pcall(function()
        ctrl.String = txt
    end)
end

local function has_group_idx(i0)
    local i = (i0 or 0) + 1
    return (grpMaskByIdx[i] or 0) > 0
end

local function fmt_disp_label(lbl, hasThis, idx1)
    if not hasThis then
        return "—"
    end
    lbl = tostring(lbl or "")
    if lbl:match("^[A-Da-d]$") then
        return "Group " .. lbl:upper()
    end
    -- fallback kalau device nggak kirim label tapi slot terisi
    if lbl == "" and idx1 then
        return "Group " .. ("ABCD"):sub(idx1, idx1)
    end
    return lbl
end

-- Render UI per slot:
local function apply_group_visuals_by_idx()
    for i = 1, 4 do
        local hasThis = (grpMaskByIdx[i] or 0) > 0
        local lbl = tostring(devLabelByIdx[i] or "")
        local disp = fmt_disp_label(lbl, hasThis, i)

        if groupBtns[i] then
            set_legend(groupBtns[i], disp)
        end
        if assignBtns[i] then
            set_legend(assignBtns[i], "SET")
        end
        if clearBtns[i] then
            set_legend(clearBtns[i], "Clear")
        end

        if assignBtns[i] then
            set_val_no_event(assignBtns[i], hasThis and 1 or 0)
        end
        if groupBtns[i] and not hasThis then
            set_val_no_event(groupBtns[i], 0)
        end
    end
end

-- Tarik grup dari device > isi cache > render
function refresh_groups(hard)
    http_get("/inkglo/groups", function(ok, body)
        if not ok then
            if hard then
                set_text(mon, "groups err")
            end
            return
        end

        -- reset cache
        for i = 1, 4 do
            devLabelByIdx[i], grpMaskByIdx[i] = "", 0
        end

        local j = tostring(body or "")
        -- contoh item: {"idx":0,"label":"Ruang Meeting","mask":13}
        for idx, lab, m in j:gmatch('{"idx"%s*:%s*(%d+)%s*,%s*"label"%s*:%s*"(.-)"%s*,%s*"mask"%s*:%s*(%d+)%s*}') do
            local i0 = tonumber(idx) or -1
            local i = i0 + 1
            local label = tostring(lab or "")
            local mask = tonumber(m) or 0
            if i >= 1 and i <= 4 then
                devLabelByIdx[i] = label
                grpMaskByIdx[i] = mask
            end
        end

        apply_group_visuals_by_idx()
        if hard then
            set_text(mon, "groups synced")
        end
    end)
end

-- GROUP: press-only, toggle by idx; auto-release
local function bind_group_toggle_idx(ctrl, i0)
    if not ctrl then
        return
    end
    ctrl.EventHandler = function(c)
        if c.Boolean ~= true then
            return
        end
        local idx0 = i0 or 0
        if not has_group_idx(idx0) then
            set_val_no_event(ctrl, 0)
            set_text(mon, ("Group %s: belum ada"):format(("ABCD"):sub(idx0 + 1, idx0 + 1)))
            return
        end
        local path = ("/inkglo/groups?op=toggle&idx=%d"):format(idx0)
        set_text(mon, "Req: " .. path)
        http_get(path, function(ok, body)
            if ok then
                local pv = (tostring(body):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, 100)
                set_text(mon, ("OK Group %s toggle: %s"):format(tostring(devLabelByIdx[idx0 + 1] or idx0), pv))
                refresh_groups(false)
            else
                set_text(mon, ("ERR Group %s toggle"):format(tostring(devLabelByIdx[idx0 + 1] or idx0)))
            end
        end)
        set_val_no_event(ctrl, 0) -- auto-release
    end
end

-- ASSIGN (locked): urutan optional (aktifin kalau mau paksa A→B→C→D)
local ENFORCE_ORDER = true
local function bind_group_assign_locked_idx(ctrl, i0)
    if not ctrl then
        return
    end
    ctrl.EventHandler = function(c)
        local idx0 = i0 or 0
        local i = idx0 + 1

        -- tolak jika slot sudah ada
        if has_group_idx(idx0) then
            set_val_no_event(ctrl, 1)
            set_text(mon, ("Assign %s: sudah ada (Clear dulu)"):format(
                tostring(devLabelByIdx[i] ~= "" and devLabelByIdx[i] or ("ABCD"):sub(i, i))))
            return
        end

        -- enforce urutan (opsional)
        if ENFORCE_ORDER and idx0 > 0 and not has_group_idx(idx0 - 1) then
            set_val_no_event(ctrl, 0)
            set_text(mon, ("Assign idx%d ditolak: isi slot sebelumnya dulu."):format(idx0))
            return
        end

        -- respond hanya saat ON
        local v = (ctrl.Value or 0) > 0.5 and 1 or 0
        if v ~= 1 then
            return
        end

        local mask = mask_from_relays()
        if mask == 0 then
            set_text(mon, ("Assign idx%d: mask=0 (tidak ada relay ON)"):format(idx0))
            set_val_no_event(ctrl, 0)
            return
        end

        local label_to_add = ("ABCD"):sub(i, i)
        local path = ("/inkglo/groups?op=add&label=%s&mask=%d"):format(label_to_add, mask)
        set_text(mon, "Req: " .. path)
        http_get(path, function(ok, body)
            if ok then
                grpMaskByIdx[i] = mask
                set_val_no_event(ctrl, 1) -- lock ON
                set_text(mon, ("OK assign idx%d (mask=%d)"):format(idx0, mask))
                refresh_groups(true) -- baca balik label device (rename)
            else
                set_val_no_event(ctrl, 0)
                set_text(mon, ("ERR assign idx%d"):format(idx0))
            end
        end)
    end
end

-- CLEAR (press-only) by idx
local function bind_group_clear_idx(ctrl, i0)
    if not ctrl then
        return
    end
    ctrl.EventHandler = function(c)
        if c.Boolean ~= true then
            return
        end
        local idx0 = i0 or 0
        local i = idx0 + 1
        if not has_group_idx(idx0) then
            set_text(mon, ("Clear idx%d: tidak ada grup"):format(idx0))
            return
        end
        local path = ("/inkglo/groups?op=del&idx=%d"):format(idx0)
        set_text(mon, "Req: " .. path)
        http_get(path, function(ok, body)
            if ok then
                grpMaskByIdx[i] = 0
                devLabelByIdx[i] = devLabelByIdx[i] or "" -- label bakal diset jadi "" saat refresh
                if assignBtns[i] then
                    set_val_no_event(assignBtns[i], 0)
                end
                if groupBtns[i] then
                    set_val_no_event(groupBtns[i], 0)
                end
                set_text(mon, ("OK clear idx%d"):format(idx0))
                refresh_groups(true)
            else
                set_text(mon, ("ERR clear idx%d"):format(idx0))
            end
        end)
    end
end

-- Pasang binders A..D (idx 0..3)
bind_group_toggle_idx(groupBtns[1], 0)
bind_group_toggle_idx(groupBtns[2], 1)
bind_group_toggle_idx(groupBtns[3], 2)
bind_group_toggle_idx(groupBtns[4], 3)

bind_group_assign_locked_idx(assignBtns[1], 0)
bind_group_assign_locked_idx(assignBtns[2], 1)
bind_group_assign_locked_idx(assignBtns[3], 2)
bind_group_assign_locked_idx(assignBtns[4], 3)

bind_group_clear_idx(clearBtns[1], 0)
bind_group_clear_idx(clearBtns[2], 1)
bind_group_clear_idx(clearBtns[3], 2)
bind_group_clear_idx(clearBtns[4], 3)

-- Visual awal + sinkron dari device
apply_group_visuals_by_idx()
refresh_groups(true)

----------------------------------------------------------------
-- Kick awal
reconnect()
