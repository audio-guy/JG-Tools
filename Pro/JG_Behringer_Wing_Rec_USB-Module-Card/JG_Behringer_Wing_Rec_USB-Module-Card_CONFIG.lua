-- @description Behringer Wing to Reaper Rec Setup - CONFIG
-- @author Julius Gass
-- @version 1.0.0
-- @about
--   Configuration window for the Behringer Wing to Reaper Rec Setup script.
--   Run this first to set up IP, interface, naming and routing options.
--   Requires ReaImGui.

if not reaper.ImGui_CreateContext then
    reaper.MB("Please install the 'ReaImGui' extension via ReaPack!", "Missing ReaImGui", 0)
    return
end

local ctx = reaper.ImGui_CreateContext('WING Config')

local _, script_path = reaper.get_action_context()
local dir = script_path:match("(.*[/\\])")
local config_file = dir .. "wing_config.txt"

-- Dynamically find the main script by removing " - CONFIG" from this script's name
local script_name = script_path:match("([^/\\]+)$")
local main_script_name = script_name:gsub("_CONFIG", "")
local main_script_file = dir .. main_script_name

local function GetPythonCmd()
    local os_name = reaper.GetOS()
    local paths = {}
    if os_name:match("Win") then
        paths = {"python", "py -3"}
    else
        paths = {
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
            "python3", "/usr/bin/python3", os.getenv("HOME") .. "/.local/bin/python3"
        }
    end
    for _, p in ipairs(paths) do
        local check_cmd = p .. ' -c "import pythonosc" 2>&1'
        local handle = io.popen(check_cmd)
        if handle then
            local result = handle:read("*a")
            handle:close()
            if result == "" then return p end
        end
    end
    return nil
end

local PYTHON_EXE = GetPythonCmd()

local config = {
    ip = "192.168.8.3",
    interface = "USB", 
    name_mode = "CH",  
    force_hw_colors = false,
    virtual_soundcheck = false
}

local interfaces = {"USB Audio (48 Channels)", "Internal Module (64 Channels)", "External Card (64 Channels)"}
local interface_keys = {"USB", "MOD", "CRD"}

local modes = {"Channel", "Source", "Hardware"}
local mode_keys = {"CH", "SRC", "HW"}

local function LoadConfig()
    local f = io.open(config_file, "r")
    if not f then return end
    for line in f:lines() do
        local key, val = line:match("^([^=]+)=(.*)$")
        if key == "IP" then config.ip = val end
        if key == "INTERFACE" then config.interface = val end
        if key == "NAME_MODE" then config.name_mode = val end
        if key == "FORCE_HW_COLORS" then config.force_hw_colors = (val == "1") end
        if key == "VIRTUAL_SOUNDCHECK" then config.virtual_soundcheck = (val == "1") end
    end
    f:close()
end

local function GetAudioDeviceName()
    if not reaper.GetAudioDeviceInfo then return "" end
    local s, dev = reaper.GetAudioDeviceInfo("IDENT_IN", "")
    if not s or dev == "" then s, dev = reaper.GetAudioDeviceInfo("NAME", "") end
    if s and type(dev) == "string" then return dev end
    return ""
end

local function SaveConfig(dev_name)
    local f = io.open(config_file, "w")
    f:write("IP=" .. config.ip .. "\n")
    f:write("INTERFACE=" .. config.interface .. "\n")
    f:write("NAME_MODE=" .. config.name_mode .. "\n")
    f:write("FORCE_HW_COLORS=" .. (config.force_hw_colors and "1" or "0") .. "\n")
    f:write("VIRTUAL_SOUNDCHECK=" .. (config.virtual_soundcheck and "1" or "0") .. "\n")
    f:write("AUDIO_DEVICE=" .. dev_name .. "\n")
    f:flush() 
    f:close()
end

LoadConfig()

local run_main_script = false

local function loop()
    local visible, open = reaper.ImGui_Begin(ctx, 'Wing -> Reaper Tracks Config', true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
    
    if visible then
        if not PYTHON_EXE then
            reaper.ImGui_TextColored(ctx, 0xFF0000FF, "ERROR: Python or 'python-osc' not found!")
            reaper.ImGui_Text(ctx, "Please open your Terminal and run this exact command:")
            reaper.ImGui_InputText(ctx, "##cmd", "python3 -m pip install python-osc", reaper.ImGui_InputTextFlags_ReadOnly())
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
        else
            -- === CONNECTION ===
            reaper.ImGui_Text(ctx, "Connection Settings")
            reaper.ImGui_Separator(ctx)
            local changed, new_ip = reaper.ImGui_InputText(ctx, 'WING IP Address', config.ip)
            if changed then config.ip = new_ip end
            
            local iface_idx = 1
            for i, k in ipairs(interface_keys) do 
                if config.interface == k then iface_idx = i end 
            end
            if reaper.ImGui_BeginCombo(ctx, 'Recording Interface', interfaces[iface_idx]) then
                for i, iface in ipairs(interfaces) do
                    local is_selected = (iface_idx == i)
                    if reaper.ImGui_Selectable(ctx, iface, is_selected) then
                        config.interface = interface_keys[i]
                    end
                    if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            
            reaper.ImGui_Spacing(ctx)
            
            -- === NAMING ===
            reaper.ImGui_Text(ctx, "Name & Color by")
            reaper.ImGui_Separator(ctx)
            
            local current_idx = 1
            for i, k in ipairs(mode_keys) do 
                if config.name_mode == k then current_idx = i end 
            end
            
            if reaper.ImGui_BeginCombo(ctx, '##NameTracksBy', modes[current_idx]) then
                for i, mode in ipairs(modes) do
                    local is_selected = (current_idx == i)
                    if reaper.ImGui_Selectable(ctx, mode, is_selected) then
                        config.name_mode = mode_keys[i]
                    end
                    if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            
            reaper.ImGui_Spacing(ctx)
            
            -- === ADVANCED COLORS & ROUTING ===
            reaper.ImGui_Text(ctx, "Advanced Settings")
            reaper.ImGui_Separator(ctx)
            
            local changed_hw, new_hw = reaper.ImGui_Checkbox(ctx, 'Force fixed colors for hardware inputs', config.force_hw_colors)
            if changed_hw then config.force_hw_colors = new_hw end
            
            local changed_vs, new_vs = reaper.ImGui_Checkbox(ctx, 'Virtual Soundcheck (1:1 Routing)', config.virtual_soundcheck)
            if changed_vs then config.virtual_soundcheck = new_vs end
            
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            
            -- === SAVE ===
            if reaper.ImGui_Button(ctx, 'Save, Close & RUN', -1) then
                local cur_dev = GetAudioDeviceName()
                local cur_dev_upper = cur_dev:upper()
                local is_suspicious = false
                local warning_msg = ""
                
                local display_name = "USB Audio"
                if config.interface == "MOD" then display_name = "Internal Module" end
                if config.interface == "CRD" then display_name = "External Card" end
                
                if config.interface == "USB" then
                    if cur_dev_upper ~= "" and not (cur_dev_upper:match("WING") or cur_dev_upper:match("BEHRINGER") or cur_dev_upper:match("USB")) then
                        is_suspicious = true
                        warning_msg = "You selected '" .. display_name .. "' as Recording Interface, but your REAPER interface is:\n'" .. cur_dev .. "'\n\nAre you sure this is correct?"
                    end
                elseif config.interface == "MOD" or config.interface == "CRD" then
                    if cur_dev_upper ~= "" and (cur_dev_upper:match("WING") or cur_dev_upper:match("BEHRINGER")) and not cur_dev_upper:match("DANTE") then
                        is_suspicious = true
                        warning_msg = "You selected '" .. display_name .. "' as Recording Interface, but your REAPER interface is:\n'" .. cur_dev .. "'\n\nAre you sure this is correct?"
                    end
                end
                
                if is_suspicious then
                    local answer = reaper.MB(warning_msg, "Possible Configuration Error", 260) 
                    if answer == 6 then 
                        SaveConfig(cur_dev)
                        open = false
                        run_main_script = true
                    end
                else
                    SaveConfig(cur_dev)
                    open = false
                    run_main_script = true
                end
            end
        end
        reaper.ImGui_End(ctx)
    end
    
    if open then 
        reaper.defer(loop) 
    else
        if run_main_script then
            local delay_start = reaper.time_precise()
            local function delayed_run()
                if reaper.time_precise() - delay_start < 0.2 then
                    reaper.defer(delayed_run)
                else
                    local cmd_id = reaper.AddRemoveReaScript(true, 0, main_script_file, true)
                    if cmd_id ~= 0 then
                        reaper.Main_OnCommand(cmd_id, 0)
                    else
                        reaper.MB("Could not launch the main script automatically.\nPlease run it manually.", "Launch Error", 0)
                    end
                end
            end
            reaper.defer(delayed_run) 
        end
    end
end

reaper.defer(loop)