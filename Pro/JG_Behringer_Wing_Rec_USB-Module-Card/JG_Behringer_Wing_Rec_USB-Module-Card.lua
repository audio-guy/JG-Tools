-- @description Behringer Wing to Reaper Rec Setup
-- @author Julius Gass
-- @version 1.0.0
-- @about
--   Queries routing data from a Behringer Wing console via OSC
--   and creates/updates REAPER tracks accordingly.
--   Requires SWS Extension, ReaImGui, Python 3 and python-osc.

local _, script_path = reaper.get_action_context()
local script_dir  = script_path:match("(.*[/\\])") or "./"
local py_script   = script_dir .. "JG_Behringer_Wing_Rec_USB-Module-Card_get_track_infos.py"
local json_file   = script_dir .. "wing_routing.json"
local config_file = script_dir .. "wing_config.txt"
local config_lua  = script_dir .. "JG_Behringer_Wing_Rec_USB-Module-Card_CONFIG.lua"

local TRACK_COUNT = 48
local SAVED_AUDIO_DEVICE = ""
local VIRTUAL_SOUNDCHECK = false

local function LaunchConfig()
    local f = io.open(config_lua, "r")
    if f then
        f:close()
        local cmd_id = reaper.AddRemoveReaScript(true, 0, config_lua, true)
        if cmd_id ~= 0 then reaper.Main_OnCommand(cmd_id, 0) else dofile(config_lua) end
    else
        reaper.ShowMessageBox("Error: CONFIG script missing!\n\nSearched in:\n" .. config_lua, "Missing File", 0)
    end
end

local c_file = io.open(config_file, "r")
if not c_file then
    reaper.ShowMessageBox("No config found. The setup window will open now.", "Initial Setup", 0)
    LaunchConfig()
    return
else
    for line in c_file:lines() do
        local key, val = line:match("^([^=]+)=(.*)$")
        if key == "INTERFACE" then
            TRACK_COUNT = (val == "MOD" or val == "CRD") and 64 or 48
        elseif key == "AUDIO_DEVICE" then
            SAVED_AUDIO_DEVICE = val
        elseif key == "VIRTUAL_SOUNDCHECK" then
            VIRTUAL_SOUNDCHECK = (val == "1")
        end
    end
    c_file:close()
end

if reaper.GetAudioDeviceInfo and SAVED_AUDIO_DEVICE ~= "" then
    local s, current_device = reaper.GetAudioDeviceInfo("IDENT_IN", "")
    if not s or current_device == "" then s, current_device = reaper.GetAudioDeviceInfo("NAME", "") end
    if s and current_device ~= "" and current_device ~= SAVED_AUDIO_DEVICE then
        reaper.ShowMessageBox("Warning: Audio interface changed!\n\nPrevious: " .. SAVED_AUDIO_DEVICE .. "\nCurrent: " .. current_device, "Interface Changed", 0)
        LaunchConfig()
        return
    end
end

local EXT_SLOT = "WING_SLOT"
local PLACEHOLDER = "(stereo placeholder)"

local function GetPythonCmd()
    local os_name = reaper.GetOS()
    local paths = os_name:match("Win") and {"python", "py -3"} or {"/opt/homebrew/bin/python3", "/usr/local/bin/python3", "python3", "/usr/bin/python3", os.getenv("HOME") .. "/.local/bin/python3"}
    for _, p in ipairs(paths) do
        local handle = io.popen(p .. ' -c "import pythonosc" 2>&1')
        if handle and handle:read("*a") == "" then handle:close() return p end
        if handle then handle:close() end
    end
    return nil
end

local function parse_json_tracks(txt)
  local tracks = {}
  for block in txt:gmatch("{([^{}]+)}") do
    local t = {}
    for k, v in block:gmatch('"([%w_]+)"%s*:%s*(-?%d+)') do t[k] = tonumber(v) end
    for k, v in block:gmatch('"([%w_]+)"%s*:%s*(%a+)') do t[k] = (v == "true") end
    for k, v in block:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do t[k] = v end
    if t.slot then tracks[t.slot] = t end
  end
  return tracks
end

local function strip_lr(name) return (name:gsub("%s+[LRlr]$", "")) end

local function run_python(python_exe)
  local handle = io.popen(python_exe .. ' "' .. py_script .. '" 2>&1')
  local output = handle:read("*a")
  handle:close()
  return output
end

local function find_wing_tracks()
  local children = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, sv = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. EXT_SLOT, "", false)
    local slot = tonumber(sv)
    if slot then children[slot] = tr end
  end
  return children
end

local function configure_track(tr, t)
  for i = reaper.GetTrackNumSends(tr, 1) - 1, 0, -1 do reaper.RemoveTrackSend(tr, 1, i) end
  reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 0)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", VIRTUAL_SOUNDCHECK and 0 or 1)

  if t.is_empty_routing then
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "(INPUT " .. tostring(t.slot) .. " NOT ROUTED)", true)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECARM",  0)
    reaper.SetTrackColor(tr, reaper.ColorToNative(0, 0, 0) | 0x1000000) 
    if reaper.NF_SetSWSTrackNotes then reaper.NF_SetSWSTrackNotes(tr, "WING Routing:\nEmpty / OFF") end
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:WING_NOTES", "Empty / OFF", true)
  elseif t.stereo_R then
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", PLACEHOLDER, true)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECARM",  0)
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
    reaper.SetTrackColor(tr, reaper.ColorToNative(0, 0, 0) | 0x1000000) 
    if reaper.NF_SetSWSTrackNotes then reaper.NF_SetSWSTrackNotes(tr, "Stereo R Channel") end
  else
    local r, g, b = t.color_r or -1, t.color_g or -1, t.color_b or -1
    local name = t.stereo_L and strip_lr(t.name or ("Input " .. t.slot)) or (t.name or ("Input " .. t.slot))
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)

    local inp = math.floor(t.reaper_input or (t.slot - 1))
    reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", inp)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE",  0)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECARM",   1)
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
    reaper.SetTrackColor(tr, r == -1 and 0 or (reaper.ColorToNative(r, g, b) | 0x1000000))
    
    local notes_str = "WING Routing:\nHardware: " .. (t.hw_name or "-") .. "\nSource: " .. (t.stereo_L and strip_lr(t.src_name or "-") or (t.src_name or "-")) .. "\nChannel: " .. (t.stereo_L and strip_lr(t.ch_name or "-") or (t.ch_name or "-"))
    if reaper.NF_SetSWSTrackNotes then reaper.NF_SetSWSTrackNotes(tr, notes_str) end
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:WING_NOTES", notes_str, true)

    if VIRTUAL_SOUNDCHECK then
        local s_idx = reaper.CreateTrackSend(tr, nil)
        reaper.SetTrackSendInfo_Value(tr, 1, s_idx, "I_SENDMODE", 0)
        local hw_out_idx = (inp >= 1024) and (inp - 1024) or inp
        reaper.SetTrackSendInfo_Value(tr, 1, s_idx, "I_DSTCHAN", t.stereo_L and hw_out_idx or (hw_out_idx | 1024))
    end
  end
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. EXT_SLOT, tostring(t.slot), true)
end

local function update_and_manage_tracks(slot_data, children)
  local master_tr = reaper.GetMasterTrack(0)
  if VIRTUAL_SOUNDCHECK then
      for i = reaper.GetTrackNumSends(master_tr, 1) - 1, 0, -1 do reaper.RemoveTrackSend(master_tr, 1, i) end
  else
      local has_main = false
      for i = 0, reaper.GetTrackNumSends(master_tr, 1) - 1 do
          if reaper.GetTrackSendInfo_Value(master_tr, 1, i, "I_DSTCHAN") == 0 then has_main = true break end
      end
      if not has_main then reaper.SetTrackSendInfo_Value(master_tr, 1, reaper.CreateTrackSend(master_tr, nil), "I_DSTCHAN", 0) end
  end

  local block_has_items = false
  for slot, tr in pairs(children) do
    if slot > TRACK_COUNT and reaper.ValidatePtr(tr, "MediaTrack*") and reaper.CountTrackMediaItems(tr) > 0 then
      block_has_items = true break
    end
  end

  for slot, tr in pairs(children) do
    if slot > TRACK_COUNT then
      if reaper.ValidatePtr(tr, "MediaTrack*") then
        if not block_has_items then reaper.DeleteTrack(tr)
        else
          reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", true)
          reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 0)
          reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", -1)
          reaper.SetTrackColor(tr, 0)
          if reaper.NF_SetSWSTrackNotes then reaper.NF_SetSWSTrackNotes(tr, "") end
        end
      end
      children[slot] = nil
    end
  end

  local insert_idx = reaper.CountTracks(0)
  for slot = 1, TRACK_COUNT do
      if children[slot] and reaper.ValidatePtr(children[slot], "MediaTrack*") then
          local tr_idx = reaper.CSurf_TrackToID(children[slot], false) - 1
          if tr_idx < insert_idx then insert_idx = tr_idx end
      end
  end

  for slot = 1, TRACK_COUNT do
    local tr = children[slot]
    if tr and reaper.ValidatePtr(tr, "MediaTrack*") then
      local has_notes, old_notes = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:WING_NOTES", "", false)
      if has_notes and old_notes ~= "" and old_notes ~= "Empty / OFF" then
          for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
              local item = reaper.GetTrackMediaItem(tr, i)
              local _, current_notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
              if current_notes == "" then 
                  reaper.GetSetMediaItemInfo_String(item, "P_NOTES", old_notes, true) 
              end
          end
      end
      configure_track(tr, slot_data[slot] or { slot = slot, reaper_input = slot - 1, is_empty_routing = true })
      insert_idx = reaper.CSurf_TrackToID(tr, false)
    else
      reaper.InsertTrackAtIndex(insert_idx, true)
      tr = reaper.GetTrack(0, insert_idx)
      configure_track(tr, slot_data[slot] or { slot = slot, reaper_input = slot - 1, is_empty_routing = true })
      children[slot] = tr
      insert_idx = insert_idx + 1
    end
  end
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
reaper.ClearConsole()

local PYTHON_EXE = GetPythonCmd()
if not PYTHON_EXE then
    reaper.ShowMessageBox("Error: Python/python-osc not found.", "Error", 0)
    return
end

os.remove(json_file)
reaper.ShowConsoleMsg("Querying WING routing data...\n" .. run_python(PYTHON_EXE) .. "\n")

local f = io.open(json_file, "r")
if not f then return end
local txt = f:read("*a")
f:close()

update_and_manage_tracks(parse_json_tracks(txt), find_wing_tracks())

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("WING: track setup", -1)
reaper.UpdateArrange()