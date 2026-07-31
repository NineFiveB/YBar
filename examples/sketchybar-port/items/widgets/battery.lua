local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- Resolve battery CLI path
local battery_bin = "/opt/homebrew/bin/battery"
if os.execute("test -x /opt/homebrew/bin/battery") == nil then
  battery_bin = "/usr/local/bin/battery"
end

local popup_width = 250

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  icon = {
    font = {
      style = settings.font.style_map["Regular"],
      size = 19.0,
    }
  },
  label = { font = { family = settings.font.numbers } },
  update_freq = 4,
  popup = { align = "center", height = 30 }
})

local battery_bracket = sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 }
})

-- Popup Items
local power_source = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    font = {
      style = settings.font.style_map["Bold"]
    },
    string = "⚡",
  },
  width = popup_width,
  align = "center",
  label = {
    font = {
      size = 15,
      style = settings.font.style_map["Bold"]
    },
    string = "Battery Status",
  },
  background = {
    height = 2,
    color = colors.grey,
    y_offset = -15
  }
})

local remaining_time = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Time Remaining:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "??:??h",
    width = popup_width / 2,
    align = "right"
  },
})

local battery_percentage = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Charge:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "??%",
    width = popup_width / 2,
    align = "right"
  },
})

local battery_condition = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Condition:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "...",
    width = popup_width / 2,
    align = "right"
  },
})

local battery_capacity = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Max Capacity:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "...%",
    width = popup_width / 2,
    align = "right"
  },
})

local current_status_item = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Current Status:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "...",
    width = popup_width / 2,
    align = "right"
  },
  background = {
    height = 2,
    color = colors.grey,
    y_offset = -15
  }
})

local low_power_mode = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Low Power Mode:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "...",
    width = popup_width / 2,
    align = "right"
  }
})

local maintenance_status = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Charge limit:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "...",
    width = popup_width / 2,
    align = "right"
  },
  background = {
    height = 2,
    color = colors.grey,
    y_offset = -15
  }
})

local maintenance_disable = sbar.add("item", {
  position = "popup." .. battery_bracket.name,
  icon = {
    string = "Maintenance:",
    width = popup_width / 2,
    align = "left"
  },
  label = {
    string = "Disable",
    width = popup_width / 2,
    align = "right",
    color = colors.red
  }
})

local maintenance_slider = sbar.add("slider", popup_width, {
  position = "popup." .. battery_bracket.name,
  slider = {
    highlight_color = colors.green,
    background = {
      height = 6,
      corner_radius = 3,
      color = colors.bg2,
    },
    knob = {
      string = "􀀁",
      drawing = true,
    },
  },
  background = { 
    color = colors.bg1, 
    height = 2, 
    y_offset = -20 
  }
})







local function hide_details()
  battery_bracket:set({ popup = { drawing = false } })
end

local function update_battery_details()
  -- Update power source
  sbar.exec("pmset -g batt", function(batt_info)
    local is_charging = batt_info:find("charging") ~= nil
    local is_charged = batt_info:find("charged") ~= nil
    -- More robust check: explicitly check for Battery Power, if not found then assume AC Power
    local is_battery_power = batt_info:find("Battery Power") ~= nil
    local is_ac_power = not is_battery_power

    -- Update time remaining
    local found, _, remaining = batt_info:find(" (%d+:%d+) remaining")
    local label = found and remaining .. "h" or "No estimate"
    remaining_time:set({ label = label })
    
    -- Update percentage
    local found_pct, _, charge = batt_info:find("(%d+)%%")
    if found_pct then
      charge = tonumber(charge)
      battery_percentage:set({ label = charge .. "%" })
    end

    -- Check battery maintenance status and Current Status (dependent on power source)
    sbar.exec(battery_bin .. " status 2>&1", function(battery_status)
      -- Update Current Status
      local smc_charging_disabled = battery_status:find("smc charging disabled")
      local status_text = "Unknown"
      
      if is_ac_power then
        if smc_charging_disabled then
          status_text = "Not charging"
        else
          status_text = "Charging"
        end
      else
        status_text = "Discharging"
      end
      current_status_item:set({ label = status_text })

      -- Update Header Icon (Dynamic)
      local maintenance_active = battery_status:match("maintained at") ~= nil
      -- Only show charging if on AC power - never show charging when on battery
      -- Also check if SMC charging is disabled (battery reached upper limit or maintenance active)
      -- Check battery power first to be absolutely sure
      local should_show_charging = not is_battery_power and is_ac_power and not smc_charging_disabled and (is_charging or (is_charged and not maintenance_active))
      local icon = icons.battery._0
      local color = colors.red

      if should_show_charging then
        icon = icons.battery.charging
        color = colors.green
      else
        if found_pct and charge > 80 then
          icon = icons.battery._100
          color = colors.green
        elseif found_pct and charge > 60 then
          icon = icons.battery._75
          color = colors.green
        elseif found_pct and charge > 40 then
          icon = icons.battery._50
          color = colors.green
        elseif found_pct and charge > 20 then
          icon = icons.battery._25
          color = colors.orange
        else
          icon = icons.battery._0
          color = colors.red
        end
        
        -- Check Low Power Mode for tint (we need to fetch it here since it's not in batt_info)
        sbar.exec("pmset -g", function(pmset_info)
          local lowpower = pmset_info:match("lowpowermode%s+(%d+)")
          if lowpower == "1" and color ~= colors.red and color ~= colors.orange then
            color = colors.yellow
          end
          -- Apply icon update here to ensure color is ready
          power_source:set({ 
            icon = { string = icon, color = color }
          })
        end)
      end
      
      -- If charging, apply immediately (no need to wait for pmset -g)
      if should_show_charging then
        power_source:set({ 
          icon = { string = icon, color = color }
        })
      end

      -- Try to match range mode first (e.g., "70% - 80%")
      local range_low, range_high = battery_status:match("maintained at (%d+)%%[%s%-]+(%d+)%%")
      -- Try to match single percentage mode (e.g., "80%")
      local single = battery_status:match("maintained at (%d+)%%")
      
      if range_low and range_high then
        -- Range mode: display as "70-80%"
        local low = tonumber(range_low)
        local high = tonumber(range_high)
        local midpoint = math.floor((low + high) / 2)
        maintenance_status:set({ 
          label = { 
            string = low .. "-" .. high .. "%",
            color = colors.green
          }
        })
        maintenance_slider:set({ slider = { percentage = midpoint } })
      elseif single then
        -- Single percentage mode: display as "80%"
        local percentage = tonumber(single)
        maintenance_status:set({ 
          label = { 
            string = percentage .. "%",
            color = colors.green
          }
        })
        maintenance_slider:set({ slider = { percentage = percentage } })
      else
        -- Not maintained
        maintenance_status:set({ 
          label = { 
            string = "Disabled",
            color = colors.grey
          }
        })
        maintenance_slider:set({ slider = { percentage = 80 } })
      end
    end)
  end)
  
  -- Update battery health info (Condition and Capacity only)
  sbar.exec("system_profiler SPPowerDataType", function(info)
    -- Condition
    local condition = info:match("Condition: ([^\n]+)")
    if condition then
      battery_condition:set({ label = condition })
    end
    
    -- Max Capacity
    local capacity = info:match("Maximum Capacity: (%d+)%%")
    if capacity then
      battery_capacity:set({ label = capacity .. "%" })
    end
    
    -- Cycle Count removed as per request
  end)
  
  -- Check low power mode
  sbar.exec("pmset -g", function(pmset_info)
    local lowpower = pmset_info:match("lowpowermode%s+(%d+)")
    if lowpower then
      local mode_text = (lowpower == "1") and "Enabled" or "Disabled"
      local mode_color = (lowpower == "1") and colors.yellow or colors.grey
      low_power_mode:set({ 
        label = { 
          string = mode_text,
          color = mode_color 
        }
      })
    end
  end)
end



local function update_main_icon()
  sbar.exec("pmset -g batt", function(batt_info)
    local icon = "!"
    local label = "?"

    local found, _, charge = batt_info:find("(%d+)%%")
    if found then
      charge = tonumber(charge)
      label = charge .. "%"
    end

    local color = colors.green
    local is_charging = batt_info:find("charging") ~= nil
    local is_charged = batt_info:find("charged") ~= nil
    -- More robust check: explicitly check for Battery Power, if not found then assume AC Power
    local is_battery_power = batt_info:find("Battery Power") ~= nil
    local on_ac_power = not is_battery_power

    sbar.exec("pmset -g", function(pmset_info)
      local lowpower = pmset_info:match("lowpowermode%s+(%d+)")
      local is_low_power = lowpower == "1"

      -- Check if battery maintenance is active
      sbar.exec(battery_bin .. " status 2>&1", function(battery_status)
        local maintenance_active = battery_status:match("maintained at") ~= nil
        local smc_charging_disabled = battery_status:find("smc charging disabled")
        
        -- Only show charging if on AC power - never show charging when on battery
        -- Also check if SMC charging is disabled (battery reached upper limit or maintenance active)
        -- Check battery power first to be absolutely sure
        local should_show_charging = not is_battery_power and on_ac_power and not smc_charging_disabled and (is_charging or (is_charged and not maintenance_active))
        
        if should_show_charging then
          icon = icons.battery.charging
          color = colors.green -- Always green when charging
        else
          if found and charge > 80 then
            icon = icons.battery._100
          elseif found and charge > 60 then
            icon = icons.battery._75
          elseif found and charge > 40 then
            icon = icons.battery._50
          elseif found and charge > 20 then
            icon = icons.battery._25
            color = colors.orange
          else
            icon = icons.battery._0
            color = colors.red
          end

          -- Override color for Low Power Mode if not critical/charging
          if is_low_power and color ~= colors.red and color ~= colors.orange then
            color = colors.yellow
          end
        end

        local lead = ""
        if found and charge < 10 then
          lead = "0"
        end

        battery:set({
          icon = {
            string = icon,
            color = color
          },
          label = { string = lead .. label },
        })
      end)
    end)
  end)
end

local function toggle_details()
  local should_draw = battery_bracket:query().popup.drawing == "off"
  if should_draw then
    battery_bracket:set({ popup = { drawing = true }})
    update_battery_details()
    update_main_icon()
  else
    hide_details()
  end
end

battery:subscribe("mouse.clicked", toggle_details)
battery:subscribe("mouse.exited.global", hide_details)

-- Update battery icon and label
battery:subscribe({"routine", "power_source_change", "system_woke"}, function()
  update_main_icon()

  -- Sync popup details if open
  if battery_bracket:query().popup.drawing == "on" then
    update_battery_details()
  end
end)



-- Button click handlers

local last_slider_event = 0
maintenance_slider:subscribe("mouse.clicked", function()
  -- Update timestamp to invalidate previous pending calls
  local now = os.clock()
  last_slider_event = now
  
  -- Get current slider value immediately for responsiveness
  local slider_value = maintenance_slider:query().slider.percentage
  
  -- Visual feedback immediately
  maintenance_status:set({ 
    label = { string = slider_value .. "% (Pending...)", color = colors.orange }
  })
  
  -- Delay execution
  sbar.delay(1.0, function()
    -- Check if this is still the latest event
    if last_slider_event == now then
      local low = math.max(50, slider_value - 5)
      local high = math.min(100, slider_value + 5)
      
      -- Get current battery percentage to determine if we need to discharge first
      sbar.exec("pmset -g batt", function(batt_info)
        local found_pct, _, current_charge = batt_info:find("(%d+)%%")
        local current_percentage = found_pct and tonumber(current_charge) or nil
        
        if current_percentage and current_percentage > low then
          -- Battery is above the lower limit, discharge to lower end first
          maintenance_status:set({ 
            label = { string = "Discharging to " .. low .. "%...", color = colors.orange }
          })
          
          -- Stop any existing maintenance/discharge first
          sbar.exec(battery_bin .. " maintain stop")
          
          -- Small delay to ensure stop command completes
          sbar.delay(0.5, function()
            -- Discharge to the lower end of the range
            sbar.exec(battery_bin .. " discharge " .. low)
            
            -- Wait for discharge to complete (poll battery status)
            -- Check every 5 seconds until we're close to the target
            local function check_discharge_status(attempts)
              attempts = attempts or 0
              if attempts > 60 then -- Max 5 minutes (60 * 5 seconds)
                -- Timeout: start maintenance anyway
                sbar.exec(battery_bin .. " maintain " .. low .. "-" .. high)
                maintenance_status:set({ 
                  label = { string = low .. "-" .. high .. "%", color = colors.green }
                })
                sbar.delay(1.5, function()
                  update_battery_details()
                  sbar.trigger("routine")
                end)
                return
              end
              
              sbar.exec("pmset -g batt", function(batt_info)
                local found_pct, _, charge = batt_info:find("(%d+)%%")
                local charge_pct = found_pct and tonumber(charge) or nil
                
                if charge_pct and charge_pct <= low + 2 then
                  -- Close enough to target, start maintenance mode
                  sbar.exec(battery_bin .. " maintain " .. low .. "-" .. high)
                  
                  -- Reset visuals
                  maintenance_status:set({ 
                    label = { string = low .. "-" .. high .. "%", color = colors.green }
                  })
                  
                  -- Force update after delay to ensure system catches up
                  sbar.delay(1.5, function()
                    update_battery_details()
                    sbar.trigger("routine")
                  end)
                else
                  -- Still discharging, check again in 5 seconds
                  sbar.delay(5.0, function()
                    check_discharge_status(attempts + 1)
                  end)
                end
              end)
            end
            
            -- Start checking discharge status after a short delay
            sbar.delay(2.0, function()
              check_discharge_status()
            end)
          end)
        else
          -- Battery is already at or below the lower limit, just start maintenance
          sbar.exec(battery_bin .. " maintain " .. low .. "-" .. high)
          
          -- Reset visuals (will be overwritten by next routine update anyway, but good for immediate feedback)
          maintenance_status:set({ 
            label = { string = low .. "-" .. high .. "%", color = colors.green }
          })
          
          -- Force update after delay to ensure system catches up
          sbar.delay(1.5, function()
            update_battery_details()
            sbar.trigger("routine")
          end)
        end
      end)
    end
  end)
end)

maintenance_disable:subscribe("mouse.clicked", function()
  maintenance_disable:set({ label = { color = colors.orange }})
  sbar.exec(battery_bin .. " maintain stop")
  sbar.delay(0.5, function()
    maintenance_disable:set({ label = { color = colors.red }})
    update_battery_details()
    -- Trigger battery icon update
    sbar.trigger("routine")
  end)
end)

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = settings.group_paddings
})
