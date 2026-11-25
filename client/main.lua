local aiming=false
local function register()
    if GetResourceState('whip_phone')~='started' then return end
    local ok,why=exports.whip_phone:RegisterModule({id='waink',script='html/phone_app.js',ns='whip_waink'})
    if ok==false then print('[whip_waink] Phone registration: '..tostring(why)) end
end
CreateThread(register)
AddEventHandler('onClientResourceStart',function(r) if r=='whip_phone' then register() end end)
-- Original phone stays visible; direct in-phone WebGL and temporary first-person view.
local generation, crop, progress, locked = 0,nil,0,false
local reason
local oldPedView, oldVehicleView
local function restoreView()
    if oldPedView~=nil then SetFollowPedCamViewMode(oldPedView); oldPedView=nil end
    if oldVehicleView~=nil then SetFollowVehicleCamViewMode(oldVehicleView); oldVehicleView=nil end
end
local function phonePush(event,data)
    if GetResourceState('whip_phone')=='started' and exports.whip_phone:IsOpen() then exports.whip_phone:Push('waink',event,data) end
end
local function makeCrop()
    local w,h=GetActiveScreenResolution()
    local aspect=(w and h and h>0) and w/h or 16/9
    local width=math.max(0.15,math.min(0.65,(tonumber(Config.PreviewWidth) or 40)/100))
    local height=math.min(0.8,width*aspect/(16/9)); width=height*(16/9)/aspect
    return {x=0.5,y=0.5,w=width,h=height}
end
-- Scan the actual rendered camera, independent of the browser renderer.
-- The centre ray has priority; small offset rays fit inside the visible reticle.
local function ray(preferred)
    if not crop then return nil end
    local ped=PlayerPedId()
    local range=math.max(3,math.min(35,tonumber(Config.ScanRange) or 25))
    local origin=GetFinalRenderedCamCoord()
    local rot=GetFinalRenderedCamRot(2)
    local pitch,yaw=math.rad(rot.x),math.rad(rot.z)
    local forward=vector3(-math.sin(yaw)*math.cos(pitch),math.cos(yaw)*math.cos(pitch),math.sin(pitch))
    local samples={{0,0},{-0.13,0},{0.13,0},{0,-0.12},{0,0.12}}
    local probes={}
    for i,offset in ipairs(samples) do
        local direction=forward
        if i>1 then
            local _,normal=GetWorldCoordFromScreenCoord(crop.x+offset[1]*crop.w,crop.y+offset[2]*crop.h)
            if normal and #normal>0.001 then direction=normal/#normal end
        end
        local dest=origin+direction*(range+3.0)
        probes[i]=StartShapeTestLosProbe(origin.x,origin.y,origin.z,dest.x,dest.y,dest.z,19,ped,4)
    end
    local hits={}
    for _=1,8 do
        local pending=false
        for i,handle in pairs(probes) do
            local status,hit,_,_,entity=GetShapeTestResult(handle)
            if status~=1 then
                probes[i]=nil
                if status==2 and (hit==1 or hit==true) and entity and entity~=0 and DoesEntityExist(entity) and IsEntityAVehicle(entity)
                    and entity~=GetVehiclePedIsIn(ped,false) and #(GetEntityCoords(ped)-GetEntityCoords(entity))<=range then
                    hits[i]=entity
                end
            else pending=true end
        end
        if not pending then break end
        Wait(0)
    end
    if preferred then for _,entity in pairs(hits) do if entity==preferred then return entity end end end
    for i=1,#samples do if hits[i] then return hits[i] end end
end
local function status()
    return {active=aiming,progress=progress,locked=locked,reason=reason,generation=generation,crop=crop,
        fps=math.max(10,math.min(30,tonumber(Config.PreviewFps) or 24))}
end
-- Keep the older phone bridge compatible, but never require a preview acknowledgement.
exports('CameraPoll',function()
    if GetInvokingResource()~='whip_phone' then return {active=false,reason='Camera access refused'} end
    return status()
end)
local function endAim(why,completed)
    local wasAiming=aiming
    aiming=false; generation=generation+1; reason=why
    progress=0; locked=false; crop=nil
    restoreView()
    phonePush('camera',{active=false,completed=completed==true,reason=why})
    if wasAiming and GetResourceState('whip_phone')=='started' then pcall(function() exports.whip_phone:SetWainkAim(false) end) end
end
RegisterNetEvent('whip_waink:cancelAim',function() if source==65535 and aiming then endAim('Scan cancelled.'); phonePush('scanEnded',{reason='Scan cancelled.'}) end end)
local function cancelServer()
    CreateThread(function() pcall(function() Whip.core:Callback('whip_waink:cancelScan',{}) end) end)
end
AddEventHandler('whip_phone:client:opened',function(open)
    if not open and aiming then endAim('Phone closed.'); cancelServer() end
end)
AddEventHandler('whip_phone:client:state',function(state)
    if aiming and state~='phone' then endAim('Scan cancelled: handset closed or unfolded.'); cancelServer() end
end)
RegisterNetEvent('whip_waink:overlayPush',function(event,data)
    if source==65535 and event=='result' and (GetResourceState('whip_phone')=='started' and exports.whip_phone:IsOpen()) then
        phonePush(event,data)
    end
end)
local function scanOpen()
    return GetResourceState('whip_phone')=='started' and exports.whip_phone:IsOpen() and not exports.whip_phone:IsHeld()
end
RegisterNetEvent('whip_waink:aim',function(side)
    if source~=65535 or aiming or not scanOpen() or not Config.Enabled then return end
    local ok, acquired=pcall(function() return exports.whip_phone:SetWainkAim(true) end)
    if not ok or not acquired then phonePush('scanEnded',{reason='Native camera unavailable. Install the WAiNK-compatible WHIP phone bridge and open the handset.'}); cancelServer(); return end
    aiming=true; generation=generation+1; local current=generation
    crop=makeCrop(); progress=0; locked=false; reason=nil
    oldPedView=GetFollowPedCamViewMode(); oldVehicleView=GetFollowVehicleCamViewMode()
    SetFollowPedCamViewMode(4); if IsPedInAnyVehicle(PlayerPedId(),false) then SetFollowVehicleCamViewMode(4) end
    phonePush('camera',status())
    local mine=generation
    CreateThread(function()
        while aiming and generation==mine do
            for _,key in ipairs({0,24,25,37,140,141,142,177,199,200,257,263,264}) do DisableControlAction(0,key,true) end
            if IsDisabledControlJustPressed(0,177) or IsDisabledControlJustPressed(0,200) or IsPauseMenuActive() then
                endAim('Scan cancelled.'); phonePush('scanEnded',{reason='Scan cancelled.'}); cancelServer(); break
            end
            Wait(0)
        end
    end)
    CreateThread(function()
        local submitted=false
        local ok,err=xpcall(function()
            if not scanOpen() then return end
            local duration=math.max(500,math.min(4000,tonumber(Config.ScanMs) or 1000)); local start=GetGameTimer(); local deadline=start+14000
            local target,heldSince,lastSeen=nil,nil,0
            local lastSent,lastLock,lastProgress=0,false,-1
            while aiming and current==generation and GetGameTimer()<deadline and scanOpen() and Config.Enabled and not IsEntityDead(PlayerPedId()) do
                local entity=ray(target); local t=GetGameTimer()
                if not aiming or generation~=current then break end
                if entity then
                    if entity~=target then target=entity; heldSince=t end
                    lastSeen=t
                elseif t-lastSeen>450 then target=nil; heldSince=nil end
                locked=target~=nil
                progress=heldSince and math.min(1,(lastSeen-heldSince)/duration) or 0
                if lastLock~=locked or (t-lastSent>=125 and math.abs(progress-lastProgress)>=0.02) then
                    phonePush('scanStatus',status()); lastSent=t; lastLock=locked; lastProgress=progress
                end
                if entity and entity==target and progress>=1 and DoesEntityExist(target) then
                    if not NetworkGetEntityIsNetworked(target) then reason='Vehicle is not synced to the server. Try another vehicle.'; break end
                    local netId=NetworkGetNetworkIdFromEntity(target)
                    if not netId or netId==0 then reason='Vehicle is not synced to the server. Try another vehicle.'; break end
                    local model=GetDisplayNameFromVehicleModel(GetEntityModel(target))
                    local label=GetLabelText(model); if label=='NULL' then label=model end
                    local class=GetVehicleClass(target)
                    phonePush('scanStatus',status())
                    endAim(nil,true); submitted=true
                    local success,why=Whip.core:Callback('whip_waink:scanResult',{netId=netId,display=label,modelLabel=model,class=class})
                    if success then PlaySoundFrontend(-1,'SELECT','HUD_FRONTEND_DEFAULT_SOUNDSET',true)
                    else reason=why or 'Scan failed'; phonePush('scanEnded',{reason=reason}); Whip.core:Notify(reason,'error') end
                    break
                end
                Wait(90)
            end
        end,debug.traceback)
        if not submitted and generation==current then
            local why=reason or (ok and 'No vehicle identified in the preview.' or 'Camera unavailable.')
            endAim(why); phonePush('scanEnded',{reason=why}); cancelServer()
        end
        if not ok then
            if submitted then phonePush('scanEnded',{reason='Vehicle lookup failed. Check F8 console.'}); cancelServer() end
            print('[whip_waink] Scanner error: '..tostring(err))
        end
    end)
end)
RegisterNetEvent('whip_waink:launchSkill',function()
    if source~=65535 then return end
    CreateThread(function()
        if exports.whip_phone:IsOpen() then exports.whip_phone:Close() end
        Wait(350)
        TriggerServerEvent('whip_waink:runSkill')
    end)
end)
RegisterNetEvent('whip_waink:waypoint',function(x,y) if source==65535 and type(x)=='number' and type(y)=='number' then SetNewWaypoint(x,y) end end)
RegisterNetEvent('whip_waink:alarm',function(netId) if source~=65535 then return end; local v=NetToVeh(netId); if v~=0 and DoesEntityExist(v) then SetVehicleAlarm(v,true); StartVehicleAlarm(v); SetVehicleAlarmTimeLeft(v,10000) end end)
AddEventHandler('onClientResourceStop',function(r)
    if r=='whip_phone' then if aiming then endAim('Phone stopped.'); cancelServer() end; return end
    if r~=GetCurrentResourceName() then return end
    endAim()
    if GetResourceState('whip_phone')=='started' then exports.whip_phone:UnregisterModule('waink') end
end)
