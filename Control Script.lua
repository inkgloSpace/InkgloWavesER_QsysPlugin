-- InkgloSpace Was Here! --

-- Config
local POLL_MS     = 0.5
local REQ_TIMEOUT = 2.0
local PENDING_MS  = 0.6   


local RELAY_ALL_TOGGLE = false

----------------------------------------------------------------
-- Require untuk Digest path
local HttpClient = require("HttpClient")

----------------------------------------------------------------
-- Utils
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function set_text(ctrl, txt)
  if not ctrl then return end
  if pcall(function() ctrl.String = txt end) then return end
  if pcall(function() ctrl.Text = txt end) then return end
  if pcall(function() ctrl.ValueText = txt end) then return end
  pcall(function() ctrl.SetString(txt) end)
end
local function get_text(ctrl)
  if not ctrl then return "" end
  local v
  pcall(function() v = ctrl.String end);     if v and v~="" then return v end
  pcall(function() v = ctrl.Text end);       if v and v~="" then return v end
  pcall(function() v = ctrl.ValueText end);  if v and v~="" then return v end
  pcall(function() v = tostring(ctrl.Value) end)
  return v or ""
end
local function get_val(ctrl) local v=0; if ctrl then pcall(function() v=ctrl.Value end) end; return tonumber(v) or 0 end
local function set_val_no_event(ctrl, v)
  if not ctrl then return end
  local old = ctrl.EventHandler
  ctrl.EventHandler = nil
  pcall(function() ctrl.Value = v end)
  ctrl.EventHandler = old
end
-- coba disable/enable control (tergantung properti yang tersedia)
local function set_disabled(ctrl, on)
  if not ctrl then return end
  local ok = pcall(function() ctrl.IsDisabled = on and 1 or 0 end); if ok then return end
  ok = pcall(function() ctrl.IsEnabled  = on and 0 or 1 end);      if ok then return end
  pcall(function() ctrl.Enabled = on and 0 or 1 end)
end
local function set_led(on)
  local L = Controls["StatusLED"]
  if L then pcall(function() L.Value = on and 1 or 0 end) end
end
local function now_s() return os.clock() end

----------------------------------------------------------------
-- UI refs
local mon   = Controls["RemoteMonitor"]
local ipBx  = Controls["DeviceIP"]
local ptBx  = Controls["DevicePort"]
local usrBx = Controls["DeviceUser"]
local pwdBx = Controls["DevicePassword"]

local r0   = Controls["Relay0"]
local r1   = Controls["Relay1"]
local r2   = Controls["Relay2"]
local r3   = Controls["Relay3"]
local r4   = Controls["Relay4"]
local r5   = Controls["Relay5"]
local rall = Controls["RelayAll"]

-- Groups (A..D)
local grpA, grpB, grpC, grpD = Controls["GroupA"], Controls["GroupB"], Controls["GroupC"], Controls["GroupD"]
local asnA, asnB, asnC, asnD = Controls["AssignA"], Controls["AssignB"], Controls["AssignC"], Controls["AssignD"]
local clrA, clrB, clrC, clrD = Controls["ClearA"],  Controls["ClearB"],  Controls["ClearC"],  Controls["ClearD"]

-- Ping
local pingBtn = Controls["Ping"]

----------------------------------------------------------------
-- State
local HOST, PORT = "", 4444
local AUTH_USER, AUTH_PASS = "", ""
local USE_DIGEST = false

local pollT = Timer.New()
local inflight_get = false
local connected = false

local relaysState = { [0]=0, [1]=0, [2]=0, [3]=0, [4]=0, [5]=0 }     

local pend_target = { [0]=nil, [1]=nil, [2]=nil, [3]=nil, [4]=nil, [5]=nil }
local pend_until  = { [0]=0,   [1]=0,   [2]=0,   [3]=0,   [4]=0,   [5]=0   }


local lastUI = { [0]=-1, [1]=-1, [2]=-1, [3]=-1, [4]=-1, [5]=-1 }

-- Groups cache (berdasarkan label 'A'..'D')
local grpIdxByLabel  = { A=nil, B=nil, C=nil, D=nil }  
local grpMaskByLabel = { A=0,   B=0,   C=0,   D=0   }  
local groupFetchNextAllowed = 0.0                      

----------------------------------------------------------------
-- Builder URL untuk HttpClient + parser query
local function parse_query(qs)
  local t = {}
  if not qs or qs == "" then return t end
  for kv in string.gmatch(qs, "([^&]+)") do
    local k,v = kv:match("^([^=]+)=?(.*)$")
    if k then t[k] = v end
  end
  return t
end

local function make_url_for_httpclient(full_path)
  -- full_path bisa mengandung query, contoh: /inkglo/gpio/1?value=0
  local p, q = full_path, nil
  local qi = full_path:find("?", 1, true)
  if qi then
    p = full_path:sub(1, qi-1)
    q = parse_query(full_path:sub(qi+1))
  end
  return HttpClient.CreateUrl{
    Scheme = "http",
    Host   = HOST,
    Port   = PORT,
    Path   = p,
    Query  = q
  }
end

----------------------------------------------------------------
-- HTTP GET via TcpSocket (tanpa auth)
local function tcp_http_get(path, cb)
  if HOST == "" or not PORT then if cb then cb(false, "no-host") end return end
  local s = TcpSocket.New()
  s.ReadTimeout, s.WriteTimeout = 2, 2

  local buf, got_eoh, body = "", false, nil
  local done = false
  local killer = Timer.New()
  killer.EventHandler = function()
    if not done then
      done = true
      if cb then cb(false, "timeout") end
      pcall(function() s:Disconnect() end)
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
          local jump = (buf:sub(p, p+3) == "\r\n\r\n") and 4 or 2
          body = buf:sub(p + jump)
        end
      end

    elseif e == TcpSocket.Events.Closed then
      if done then return end
      done = true
      killer:Stop()
      if (not body or #body == 0) and buf and #buf > 0 then body = buf end
      if body and #body > 0 then
        if cb then cb(true, body) end
      else
        if cb then cb(false, "no-body") end
      end
      pcall(function() s:Disconnect() end)

    elseif e == TcpSocket.Events.Error then
      if done then return end
      done = true
      killer:Stop()
      if cb then cb(false, tostring(err)) end
      pcall(function() s:Disconnect() end)
    end
  end

  s:Connect(HOST, PORT)
end

----------------------------------------------------------------
-- HTTP GET via HttpClient Digest
local function digest_http_get(path, cb)
  local url = make_url_for_httpclient(path)
  HttpClient.Get{
    Url      = url,
    User     = AUTH_USER,
    Password = AUTH_PASS,
    Auth     = "digest",
    Timeout  = 5,
    EventHandler = function(_, code, data, err)
      if code == 200 and data and #data > 0 then
        if cb then cb(true, data) end
      elseif code == 200 then
        if cb then cb(false, "no-body") end
      else
        if cb then cb(false, err or tostring(code)) end
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
  for i=0,5 do if (relaysState[i] or 0) ~= 0 then m = m | (1<<i) end end
  return m
end

----------------------------------------------------------------
-- Apply status → sinkron tombol & LED (dengan pending window)
local function apply_status(body)
  local b = (body or ""):gsub("^%s+",""):gsub("%s+$","")
  local arr = b:match('"relays"%s*:%s*%[([^%]]*)%]') or b:match("relays%s*:%s*%[([^%]]*)%]") or b:match("%[([^%]]*)%]")
  if not arr then
    set_text(mon, "bad status")
    set_led(false)
    connected = false
    return
  end

  local nums = {}
  for n in arr:gmatch("([%-]?%d+)") do
    local v = tonumber(n)
    if v then nums[#nums+1] = v end
    if #nums >= 6 then break end
  end

  local tnow = now_s()
  for i=0,5 do
    local dev = nums[i+1] or 0
    local pend = pend_target[i]
    if pend ~= nil and tnow < (pend_until[i] or 0) and dev ~= pend then
      
    else
      relaysState[i] = dev
      pend_target[i] = nil
      pend_until[i]  = 0
    end
  end


  set_val_no_event(r0, relaysState[0] ~= 0 and 1 or 0)
  set_val_no_event(r1, relaysState[1] ~= 0 and 1 or 0)
  set_val_no_event(r2, relaysState[2] ~= 0 and 1 or 0)
  set_val_no_event(r3, relaysState[3] ~= 0 and 1 or 0)
  set_val_no_event(r4, relaysState[4] ~= 0 and 1 or 0)
  set_val_no_event(r5, relaysState[5] ~= 0 and 1 or 0)

  -- sinkron status tombol "All":
  if rall then
    if RELAY_ALL_TOGGLE then
      local allOn = 1
      for i=0,5 do if (relaysState[i] or 0) == 0 then allOn = 0 break end end
      set_val_no_event(rall, allOn)
    else

      set_val_no_event(rall, 0)
    end
  end


  set_text(mon, ("Status:[%d,%d,%d,%d,%d,%d]"):format(
    relaysState[0], relaysState[1], relaysState[2],
    relaysState[3], relaysState[4], relaysState[5]
  ))
  set_led(true)
  connected = true


  local now = now_s()
  if now >= (groupFetchNextAllowed or 0) then
    groupFetchNextAllowed = now + 1.2

    if http_get then refresh_groups(false) end
  end
end

----------------------------------------------------------------
-- Polling
local function poll_once()
  if inflight_get or HOST == "" then return end
  inflight_get = true
  http_get("/inkglo/status", function(ok, body)
    inflight_get = false
    if ok then
      apply_status(body)
    else
      set_led(false)
      set_text(mon, "poll err: " .. tostring(body))
      connected = false
    end
  end)
end
pollT.EventHandler = function() poll_once() end

----------------------------------------------------------------
-- Reconnect (IP/Port/User/Pass dari UI)
local function reconnect()
  local ip = trim(get_text(ipBx))
  local pr = tonumber(trim(get_text(ptBx))) or 0
  local us = trim(get_text(usrBx)) or ""
  local pw = trim(get_text(pwdBx)) or ""

  if ip == "" then
    set_led(false); set_text(mon, "Masukkan IP device"); pollT:Stop(); connected=false; return
  end
  if pr < 1 or pr > 65535 then
    pr = 80
    if ptBx then if ptBx.String ~= nil then ptBx.String = "80" else ptBx.Value = 80 end end
  end

  HOST, PORT = ip, pr
  AUTH_USER, AUTH_PASS = us, pw
  USE_DIGEST = (AUTH_USER ~= "" and AUTH_PASS ~= "")  -- aktifkan Digest bila kredensial ada

  set_text(mon, ("Connecting to %s:%d ..."):format(HOST, PORT))
  set_led(false); connected=false

  http_get("/inkglo/status", function(ok, body)
    if ok then
      apply_status(body)
      pollT:Stop(); pollT:Start(POLL_MS)
      -- hard refresh grup saat connect
      refresh_groups(true)
    else
      set_led(false)
      set_text(mon, "connect fail: " .. tostring(body))
      pollT:Stop(); connected=false
    end
  end)
end
if ipBx then ipBx.EventHandler = function() reconnect() end end
if ptBx then ptBx.EventHandler = function() reconnect() end end
if usrBx then usrBx.EventHandler = function() reconnect() end end
if pwdBx then pwdBx.EventHandler = function() reconnect() end end

----------------------------------------------------------------
-- GPIO
local function send_gpio(idx, v)
  local path = ("/inkglo/gpio/%d?value=%d"):format(idx, v)
  set_text(mon, "Req: " .. path)
  http_get(path, function(ok, body)
    if ok then
      local preview = (tostring(body):gsub("^%s+",""):gsub("%s+$","")):sub(1,120)
      set_text(mon, ("OK R%d->%d: %s"):format(idx, v, preview))
    else
      set_text(mon, ("ERR R%d->%d: %s"):format(idx, v, tostring(body)))
    end
  end)
end

local function bind_relay_ui_as_source(btn, idx)
  if not btn then return end
  btn.EventHandler = function(ctrl)
    local v = (get_val(btn) > 0.5) and 1 or 0
    if lastUI[idx] == v then return end
    lastUI[idx] = v


    relaysState[idx] = v
    pend_target[idx] = v
    pend_until[idx]  = now_s() + PENDING_MS

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
  if RELAY_ALL_TOGGLE then

    -- === MODE TOGGLE ===
    rall.EventHandler = function(c)

      local target = (rall.Value or 0) > 0.5 and 1 or 0

      local tUntil = now_s() + PENDING_MS
      for i = 0, 5 do
        lastUI[i]      = target
        relaysState[i] = target
        pend_target[i] = target
        pend_until[i]  = tUntil
      end

      -- update UI relays
      set_val_no_event(r0, target)
      set_val_no_event(r1, target)
      set_val_no_event(r2, target)
      set_val_no_event(r3, target)
      set_val_no_event(r4, target)
      set_val_no_event(r5, target)

      set_text(mon, ("Req: /inkglo/gpio/all?value=%d"):format(target))
      http_get(("/inkglo/gpio/all?value=%d"):format(target), function(ok, body)
        if ok then
          local preview = (tostring(body):gsub("^%s+",""):gsub("%s+$","")):sub(1,120)
          set_text(mon, ("OK ALL->%d: %s"):format(target, preview))
        else
          set_text(mon, ("ERR ALL->%d: %s"):format(target, tostring(body)))
        end
      end)
    end

  else
    -- === MODE MOMENTARY ===
    rall.EventHandler = function(c)
      if c.Boolean ~= true then return end

      -- majority rule untuk menentukan target ON/OFF
      local onCnt = 0
      for i = 0, 5 do
        if (relaysState[i] or 0) ~= 0 then onCnt = onCnt + 1 end
      end
      local target = (onCnt >= 4) and 0 or 1  -- >=4 ON -> OFF semua, else ON semua

      local tUntil = now_s() + PENDING_MS
      for i = 0, 5 do
        lastUI[i]      = target
        relaysState[i] = target
        pend_target[i] = target
        pend_until[i]  = tUntil
      end

      -- update UI relays
      set_val_no_event(r0, target)
      set_val_no_event(r1, target)
      set_val_no_event(r2, target)
      set_val_no_event(r3, target)
      set_val_no_event(r4, target)
      set_val_no_event(r5, target)

      set_text(mon, ("Req: /inkglo/gpio/all?value=%d"):format(target))
      http_get(("/inkglo/gpio/all?value=%d"):format(target), function(ok, body)
        if ok then
          local preview = (tostring(body):gsub("^%s+",""):gsub("%s+$","")):sub(1,120)
          set_text(mon, ("OK ALL->%d: %s"):format(target, preview))
        else
          set_text(mon, ("ERR ALL->%d: %s"):format(target, tostring(body)))
        end
      end)

      -- momentary: jaga tombol tetap OFF secara visual
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
      local preview = (tostring(body_or_err):gsub("^%s+",""):gsub("%s+$","")):sub(1,160)
      set_text(mon, string.format("PING >> %s", preview))
    else
      set_text(mon, string.format("PING ERR (%d ms): %s", dt_ms, tostring(body_or_err)))
    end
  end)
end
if pingBtn then
  pingBtn.EventHandler = function(c)
    if c.Boolean ~= true then return end
    local t = now_s()
    if (t - last_ping_t) < PING_DEBOUNCE then return end
    last_ping_t = t
    do_ping()
  end
end

----------------------------------------------------------------
-- ==== GROUPS (A..D) ====  (otomatis ikut ButtonType: Toggle/Momentary)
local labelList = { 'A','B','C','D' }

local grpA, grpB, grpC, grpD = Controls["GroupA"], Controls["GroupB"], Controls["GroupC"], Controls["GroupD"]
local asnA, asnB, asnC, asnD = Controls["AssignA"], Controls["AssignB"], Controls["AssignC"], Controls["AssignD"]
local clrA, clrB, clrC, clrD = Controls["ClearA"],  Controls["ClearB"],  Controls["ClearC"],  Controls["ClearD"]

local groupBtnByLabel  = { A=grpA, B=grpB, C=grpC, D=grpD }
local assignBtnByLabel = { A=asnA, B=asnB, C=asnC, D=asnD }
local clearBtnByLabel  = { A=clrA, B=clrB, C=clrC, D=clrD }


local grpIdxByLabel  = { A=nil, B=nil, C=nil, D=nil }
local grpMaskByLabel = { A=0,   B=0,   C=0,   D=0   }

local function has_group(L)
  return (grpIdxByLabel[L] ~= nil) and (grpMaskByLabel[L] or 0) > 0
end

local function mask_from_relays()
  local m = 0
  for i=0,5 do if (relaysState[i] or 0) ~= 0 then m = m | (1<<i) end end
  return m
end


local function apply_assign_visuals()
  for _,L in ipairs(labelList) do
    local a = assignBtnByLabel[L]
    if a then set_val_no_event(a, has_group(L) and 1 or 0) end
  end
  for _,L in ipairs(labelList) do
    local g = groupBtnByLabel[L]
    if g and not has_group(L) then set_val_no_event(g, 0) end
  end
end

-- sinkron cache grup dari device
function refresh_groups(hard)
  http_get("/inkglo/groups", function(ok, body)
    if not ok then
      if hard then set_text(mon, "groups err") end
      return
    end
    local j = tostring(body or "")
    for _,L in ipairs(labelList) do grpIdxByLabel[L], grpMaskByLabel[L] = nil, 0 end
    for idx, lab, m in j:gmatch('{"idx"%s*:%s*(%d+)%s*,%s*"label"%s*:%s*"(.-)"%s*,%s*"mask"%s*:%s*(%d+)%s*}') do
      lab = tostring(lab or ""):match("^%s*([A-Za-z])%s*$") or ""
      idx = tonumber(idx) or nil
      m   = tonumber(m) or 0
      if lab ~= "" and groupBtnByLabel[lab] then
        grpIdxByLabel[lab], grpMaskByLabel[lab] = idx, m
      end
    end
    apply_assign_visuals()
    if hard then set_text(mon, "groups synced") end
  end)
end


local function bind_group_toggle_by_label(ctrl, label)
  if not ctrl then return end
  ctrl.EventHandler = function(c)
    if c.Boolean ~= true then return end           -- press-only
    if not has_group(label) then
      set_val_no_event(ctrl, 0)                    -- tampil OFF jika belum ada grup
      set_text(mon, "Group "..label..": belum ada")
      return
    end
    local idx = grpIdxByLabel[label]
    local path = ("/inkglo/groups?op=toggle&idx=%d"):format(idx)
    set_text(mon, "Req: "..path)
    http_get(path, function(ok, body)
      if ok then
        local pv = (tostring(body):gsub("^%s+",""):gsub("%s+$","")):sub(1,100)
        set_text(mon, ("OK Group %s toggle: %s"):format(label, pv))
        -- Jangan paksa OFF — biarkan sesuai ButtonType (momentary akan off sendiri, toggle akan stay)
        refresh_groups(false)
      else
        set_text(mon, "ERR Group "..label.." toggle")
      end
    end)
  end
end

-- Assign (toggle) terkunci: tidak boleh menimpa.
local function bind_group_assign_locked(ctrl, label)
  if not ctrl then return end
  ctrl.EventHandler = function(c)
    -- Apapun eventnya, kalau sudah ada grup: tampil ON dan abaikan klik
    if has_group(label) then
      set_val_no_event(ctrl, 1)
      set_text(mon, "Assign "..label..": sudah ada (Clear dulu)")
      return
    end
    -- Hanya respon kalau user mengaktifkan (nilai 1)
    local v = (ctrl.Value or 0) > 0.5 and 1 or 0
    if v ~= 1 then return end

    local mask = mask_from_relays()
    if mask == 0 then
      set_text(mon, "Assign "..label..": mask=0 (tidak ada relay ON)")
      set_val_no_event(ctrl, 0)
      return
    end

    local path = ("/inkglo/groups?op=add&mask=%d&label=%s"):format(mask, label)
    set_text(mon, "Req: "..path)
    http_get(path, function(ok, body)
      if ok then
        grpMaskByLabel[label] = mask
        set_val_no_event(ctrl, 1)           -- kunci ON (assigned)
        set_text(mon, ("OK assign %s (mask=%d)"):format(label, mask))
        refresh_groups(true)                 -- biar idx terisi
      else
        set_val_no_event(ctrl, 0)
        set_text(mon, ("ERR assign %s"):format(label))
      end
    end)
  end
end

-- Clear
local function bind_group_clear_by_label(ctrl, label)
  if not ctrl then return end
  ctrl.EventHandler = function(c)
    if c.Boolean ~= true then return end
    if not has_group(label) then
      set_text(mon, "Clear "..label..": tidak ada grup")
      return
    end
    local idx = grpIdxByLabel[label] or 0
    local path = ("/inkglo/groups?op=del&idx=%d"):format(idx)
    set_text(mon, "Req: "..path)
    http_get(path, function(ok, body)
      if ok then
        grpIdxByLabel[label], grpMaskByLabel[label] = nil, 0
        local a = assignBtnByLabel[label]; if a then set_val_no_event(a, 0) end
        local g = groupBtnByLabel[label];  if g then set_val_no_event(g, 0) end
        set_text(mon, "OK clear "..label)
        refresh_groups(true)
      else
        set_text(mon, "ERR clear "..label)
      end
    end)
  end
end

-- Bind semua
bind_group_toggle_by_label(groupBtnByLabel.A, 'A')
bind_group_toggle_by_label(groupBtnByLabel.B, 'B')
bind_group_toggle_by_label(groupBtnByLabel.C, 'C')
bind_group_toggle_by_label(groupBtnByLabel.D, 'D')

bind_group_assign_locked(assignBtnByLabel.A, 'A')
bind_group_assign_locked(assignBtnByLabel.B, 'B')
bind_group_assign_locked(assignBtnByLabel.C, 'C')
bind_group_assign_locked(assignBtnByLabel.D, 'D')

bind_group_clear_by_label(clearBtnByLabel.A, 'A')
bind_group_clear_by_label(clearBtnByLabel.B, 'B')
bind_group_clear_by_label(clearBtnByLabel.C, 'C')
bind_group_clear_by_label(clearBtnByLabel.D, 'D')

-- Visual awal + sinkron dari device (panggil sekali saat init / setelah connect)
apply_assign_visuals()
refresh_groups(true)

----------------------------------------------------------------
-- Kick awal
reconnect()
