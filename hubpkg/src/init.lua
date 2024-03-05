--[[
  Copyright 2023 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  Arylic driver

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                 -- just for time
local socket = require "cosock.socket"          -- just for time
local comms = require "comms"
local json = require "dkjson"
local log = require "log"

-- Module variables
local thisDriver = {}
local initialized = false

-- Constants
local DEVICE_PROFILE = 'arylicdevice.v1'

local PLAYBACK_MODE = {
                        ['0'] = 'Idling',
                        ['1'] = 'Airplay streaming',
                        ['2'] = 'DLNA streaming',
                        ['10'] = 'Playing network content',
                        ['11'] = 'Playing UDISK',
                        ['20'] = 'Playback start by HTTPAPI',
                        ['31'] = 'Spotify Connect streaming',
                        ['40'] = 'Line-In input',
                        ['41'] = 'Bluetooth input',
                        ['43'] = 'Optical input',
                        ['47'] = 'Line-In #2 input',
                        ['51'] = 'USBDAC input',
                        ['99'] = 'Guest device'
                      }

-- Custom capabilities
local cap_source = capabilities['partyvoice23922.inputsource']
local cap_playpreset = capabilities['partyvoice23922.playpreset']
local cap_playtrack = capabilities['partyvoice23922.playtrack']
local cap_title = capabilities["partyvoice23922.mediatitle"]
local cap_status = capabilities["partyvoice23922.status"]


local function update_device(device, data)

  if data then
  
    device:emit_event(cap_source.source(data.source))
    device:emit_event(capabilities.mediaPlayback.playbackStatus(data.playback))
    device:emit_event(cap_playtrack.track(data.track))
    device:emit_event(capabilities.audioVolume.volume(data.volume))
    device:emit_event(capabilities.audioMute.mute(data.mute))
    
    device:emit_component_event(device.profile.components.status, cap_status.status(data.status))
    device:emit_component_event(device.profile.components.status, cap_title.title(data.title))
    
  end

end


function unhex(input)
  return (input:gsub("..", function(c)
    return string.char(tonumber(c, 16))
  end))
end

local function parse_data(device, response)

  local dataobj, pos, err = json.decode (response, 1, nil)
  if err then
    log.error ("JSON decode error:", err)
    return nil
  end

  local emitdata = {}
  
  if not dataobj then
    log.error ("Missing response JSON")
    return nil
  end
  
  emitdata.status = PLAYBACK_MODE[dataobj.mode]
  emitdata.status = emitdata.status .. '-' .. dataobj.status

  local source = 'Wifi'
  if dataobj.mode == '40' then
    source = 'Line-in'
  elseif dataobj.mode == '47' then
    source = 'Line-in2'
  elseif dataobj.mode == '41' then
    source = 'Bluetooth'
  elseif dataobj.mode == '43' then
    source = 'Optical'
  elseif dataobj.mode == '11' then
    source = 'UDisk'
  elseif dataobj.mode == '51' then
    source = 'PCUSB'
  end
  
  emitdata.source = source

  
  local MEDIASTATE = {
                        ['stop'] = 'stopped',
                        ['play'] = 'playing',
                        ['load'] = 'buffering',
                        ['pause'] = 'paused'
                      }
  
  emitdata.playback = MEDIASTATE[dataobj.status]
  
  emitdata.track = dataobj.plicurr
  
  device:set_field('numtracks', tonumber(dataobj.plicount))
  
  emitdata.title = unhex(dataobj.Title)
  
  emitdata.volume = tonumber(dataobj.vol)
  
  local MUTESTATE = {
                      ['0'] = 'unmuted',
                      ['1'] = 'muted'
                    }
                    
  emitdata.mute = MUTESTATE[dataobj.mute]
  
  return emitdata

end


local function arylic_api(device, cmd)

  local retmsg

  if comms.validate_address(device.preferences.ipaddr) then

    local url="http://" .. device.preferences.ipaddr .. '/httpapi.asp?command=' .. cmd
    log.debug ('url:', url)
    local headers = {['Accept']='application/json', ['Host']=device.preferences.ipaddr}
    
    
    local ret, response = comms.issue_request(device, 'GET', url, nil, headers)
    
    if ret == 'OK' then; return ret, response; end
    retmsg = ret

  else
    retmsg = 'IP Address invalid'
    log.warn (retmsg, device.preferences.ipaddr)
    
  end

  device:emit_component_event(device.profile.components.status, cap_status.status(retmsg))

end


--local testresp = '{"type":"0", "ch":"0", "mode":"10", "loop":"3", "eq":"0", "status":"play", "curpos":"11", "offset_pts":"11", "totlen":"170653", "Title":"596F752661706F733B766520476F7420746865204C6F7665205B2A5D", "Artist":"466C6F72656E636520616E6420746865204D616368696E65", "Album":"4C756E6773205B31362F34345D", "alarmflag":"0", "plicount":"11", "plicurr":"9", "vol":"47", "mute":"0" }'

local function do_refresh(device)

  local ret, response = arylic_api(device, 'getPlayerStatus')

  if ret == 'OK' then
    update_device(device, parse_data(device, response))
  end
    
end


local function setup_periodic_refresh(driver, device)

  if device:get_field('refreshtimer') then
    driver:cancel_timer(device:get_field('refreshtimer'))
  end
  
  log.debug (string.format('Resetting interval timer to %d seconds', device.preferences.refreshfreq))
  device:set_field('refreshtimer', driver:call_on_schedule(device.preferences.refreshfreq, function()
      do_refresh(device)
    end))
    
end

-----------------------------------------------------------------------
--                    COMMAND HANDLERS
-----------------------------------------------------------------------

local function handle_refresh(_, device, command)

  do_refresh(device)
  
end

local media_status = {
                        ['fastForward'] = 'fast forwarding',
                        ['pause'] = 'paused',
                        ['play'] = 'playing',
                        ['rewind'] = 'rewinding',
                        ['stop'] = 'stopped'
                      }

local function handle_mediacmd(driver, device, command)

  log.info ('Media Playback command:', command.command)

  device:emit_event(capabilities.mediaPlayback.playbackStatus(media_status[command.command]))
  
  if (command.command ~= 'fastForward') and (command.command ~= 'rewind') then
    
    local arylic_cmd = command.command
    if command.command == play then
      arylic_cmd = 'resume'
    end
    
    arylic_api(device, 'setPlayerCmd:' .. arylic_cmd)
    
  end
  
end

local function handle_trackcontrol(driver, device, command)

  log.info ('Track control:', command.command)
  
  local arylic_cmd
  
  if command.command == 'nextTrack' then
    arylic_cmd = 'next'
  elseif command.command == 'previousTrack' then
    arylic_cmd = 'prev'
  end
  
  arylic_api(device, 'setPlayerCmd:' .. arylic_cmd)
  
  local curtrack = device.state_cache.main[cap_playtrack.ID].track.value
  log.debug ('Current track=', curtrack)
  
  local newtracknum
  if command.command == 'nextTrack' then
    newtracknum = tonumber(curtrack) + 1
    local maxtracks = 30
    if device:get_field('numtracks') then; maxtracks = device:get_field('numtracks'); end
    if newtracknum > maxtracks then; newtracknum = maxtracks; end
  elseif command.command == 'previousTrack' then
    newtracknum = tonumber(curtrack) - 1
    if newtracknum < 1 then; newtracknum = 1; end
  end
  
  device:emit_event(cap_playtrack.track(tostring(newtracknum)))
  
end


local function handle_inputsource(driver, device, command)

  log.debug('Input source selection:', command.command, command.args.value)

  device:emit_event(cap_source.source(command.args.value))
  
  local ARYLIC_INPUT = {
                          ['Wifi'] = 'wifi',
                          ['Line-in'] = 'line-in',
                          ['Bluetooth'] = 'bluetooth',
                          ['Optical'] = 'optical',
                          ['Co-Axial'] = 'co-axial',
                          ['Line-in2'] = 'line-in2',
                          ['UDisk'] = 'udisk',
                          ['PCUSB'] = 'PCUSB'
                        }
  
  arylic_api(device, 'setPlayerCmd:switchmode:' .. ARYLIC_INPUT[command.args.value])

end


local function handle_playpreset(driver, device, command)

  log.debug('Play preset selection:', command.command, command.args.value)
  
  device:emit_event(cap_playpreset.preset(command.args.value))
  
  arylic_api(device, 'MCUKeyShortClick:' .. command.args.value)

end

local function handle_playtrack(driver, device, command)

  log.debug('Play track selection:', command.command, command.args.value)
  
  device:emit_event(cap_playtrack.track(command.args.value))
  
  arylic_api(device, 'setPlayerCmd:playindex:' .. command.args.value)

end

local function calc_new_vol(device, incdec)

  local curvol = device.state_cache.main.audioVolume.volume.value
  local newvol = curvol + incdec
  
  if newvol > 100 then; newvol = 100; end
  if newvol < 0 then; newvol = 0; end
  
  return newvol

end

local function handle_volume(driver, device, command)

  log.info(string.format('Volume triggered; command=%s, arg=%s', command.command, command.args.volume))

  local newvol = command.args.volume
  
  if command.command ~= 'setVolume' then

    local curvol = device.state_cache.main.audioVolume.volume.value
    log.debug('Current volume=', curvol)
    
    local incdec = 1
    if command.command == 'volumeDown' then; incdec = -1; end
    
    newvol = calc_new_vol(device, incdec)
    
    log.debug ('New volume=', newvol)
  end
  
  device:emit_event(capabilities.audioVolume.volume({value=newvol, unit='%'}))
  
  arylic_api(device, 'setPlayerCmd:vol:' .. tostring(newvol))

end

local function handle_mute(driver, device, command)

  local st_state = 'unmuted'
  local arylic_state = '0'
  
  if command.command == 'mute' then
    st_state = 'muted'
    arylic_state = '1'
  end

  device:emit_event(capabilities.audioMute.mute(st_state))
  
  arylic_api(device, 'setPlayerCmd:mute:' .. arylic_state)

end



------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.info(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  
  device:emit_event(capabilities.mediaPlayback.supportedPlaybackCommands({'pause', 'play', 'stop'}))
  device:emit_event(capabilities.mediaTrackControl.supportedTrackControlCommands({'nextTrack', 'previousTrack'}))
  
  device.thread:queue_event(do_refresh, device)
  
  setup_periodic_refresh(driver, device)
  
  initialized = true
  
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")

  local init_data = {
			  ['source'] = ' ',
        ['playback'] = 'stopped',
        ['track'] = '1',
        ['volume'] = 0,
        ['mute'] = 'unmuted',
        ['title'] = ' ',
        ['status'] = 'unknown'
			}
  
  device:emit_event(cap_playpreset.preset('1'))
  
  update_device(device, init_data)
  
  
  
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  -- Nothing to do here!

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)
  
  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")
  
  driver:cancel_timer(device:get_field('refreshtimer'))
  
  initialized = false
  
end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end

local function shutdown_handler(driver, event)

  log.info ('*** Driver being shut down ***')

end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

  -- Did preferences change?
  if args.old_st_store.preferences then
  
    if args.old_st_store.preferences.ipaddr ~= device.preferences.ipaddr then 
      log.info ('Device IP address changed to: ', device.preferences.ipaddr)      
      device.thread:queue_event(do_refresh, device)
    
    end
  else
    log.warn ('Old preferences missing')
  end  
     
end


-- Create Device
local function discovery_handler(driver, _, should_continue)

  if not initialized then

    log.info("Creating device")

    local MFG_NAME = 'TAUSTIN'
    local MODEL = 'ArylicV1'
    local VEND_LABEL = 'Arylic Device'
    local ID = 'Arylic_' .. tostring(socket.gettime())
    local PROFILE = DEVICE_PROFILE

    -- Create master creator device

    local create_device_msg = {
                                type = "LAN",
                                device_network_id = ID,
                                label = VEND_LABEL,
                                profile = PROFILE,
                                manufacturer = MFG_NAME,
                                model = MODEL,
                                vendor_provided_label = VEND_LABEL,
                              }

    assert (driver:try_create_device(create_device_msg), "failed to create device")

    log.debug("Exiting device creation")

  else
    log.info ('Arylic device already created')
  end
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("thisDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
    [capabilities.mediaPlayback.ID] = {
      [capabilities.mediaPlayback.commands.setPlaybackStatus.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.fastForward.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.pause.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.play.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.rewind.NAME] = handle_mediacmd,
      [capabilities.mediaPlayback.commands.stop.NAME] = handle_mediacmd,
    },
    [capabilities.audioVolume.ID] = {
      [capabilities.audioVolume.commands.setVolume.NAME] = handle_volume,
      [capabilities.audioVolume.commands.volumeDown.NAME] = handle_volume,
      [capabilities.audioVolume.commands.volumeUp.NAME] = handle_volume,
    },
    [capabilities.audioMute.ID] = {
      [capabilities.audioMute.commands.setMute.NAME] = handle_mute,
      [capabilities.audioMute.commands.mute.NAME] = handle_mute,
      [capabilities.audioMute.commands.unmute.NAME] = handle_mute,
    },
    [capabilities.mediaTrackControl.ID] = {
      [capabilities.mediaTrackControl.commands.nextTrack.NAME] = handle_trackcontrol,
      [capabilities.mediaTrackControl.commands.previousTrack.NAME] = handle_trackcontrol,
    },
    [cap_source.ID] = {
      [cap_source.commands.setSource.NAME] = handle_inputsource
    },
    [cap_playtrack.ID] = {
      [cap_playtrack.commands.setTrack.NAME] = handle_playtrack
    },
    [cap_playpreset.ID] = {
      [cap_playpreset.commands.setPreset.NAME] = handle_playpreset
    },
  }
})

log.info ('Arylic V1 Started')

thisDriver:run()
