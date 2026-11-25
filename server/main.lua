local core = Whip.core
local profiles, scans, pending, busy, cooldowns, history = {}, {}, {}, {}, {}, {}
local origins = {}
local lastScan = {}
local activeDealerTag
local dealerSequence = 0
local dealerEpoch = tostring(os.time()) .. ':' .. tostring(GetGameTimer())
local function releaseDealer()
    if not activeDealerTag then return end
    local tag = activeDealerTag
    local ok, why = core:ReleaseTag(tag)
    if not ok then error('Dealer cleanup: '..tostring(why)) end
    activeDealerTag = nil
end
local labels = {low='Slim Jim',medium='Lock Kit',high='Key Cloner',elite='Advanced Key Cloner',tracker='Signal Tool'}
local descriptions = {low='Fictional WAiNK classic vehicle access token.',medium='Fictional WAiNK standard vehicle access token.',high='Fictional WAiNK modern vehicle access token.',elite='Fictional WAiNK elite vehicle access token.',tracker='Fictional tracker challenge token.'}
-- Catalogue class names, GTA numeric IDs and common display-name variants.
local classNames = {[0]='compacts','sedans','suvs','coupes','muscle','sportsclassics','sports','super','motorcycles','offroad','industrial','utility','vans','cycles','boats','helicopters','planes','service','emergency','military','commercial','trains','openwheel'}
local allowed = {compacts='low',sedans='medium',suvs='medium',coupes='medium',muscle='low',sportsclassics='low',sports='high',super='elite',motorcycles='low',offroad='medium',industrial='medium',utility='medium',vans='medium',commercial='medium',openwheel='elite'}
local aliases = {compact='compacts',sedan='sedans',suv='suvs',coupe='coupes',sportsclassic='sportsclassics',sportclassic='sportsclassics',sport='sports',supercar='super',supercars='super',motorcycle='motorcycles',van='vans',offroadvehicles='offroad',commercialvehicles='commercial',openwheels='openwheel'}
local function normalizeClass(value)
    if type(value)=='number' then return classNames[value] end
    if type(value)~='string' then return nil end
    local n=tonumber(value); if n then return classNames[n] end
    local key=value:lower():gsub('[^%w]',''):gsub('^vehicleclass',''):gsub('^vehclass','')
    return aliases[key] or (key~='' and key or nil)
end
local function sameHash(a,b)
    return type(a)=='number' and type(b)=='number' and (a & 0xffffffff)==(b & 0xffffffff)
end
local function catalogueEntry(model,hash)
    local ok,cat=pcall(function() return core:GetVehicleCatalog() end)
    if not ok or type(cat)~='table' then return nil end
    if model and cat[model] and sameHash(joaat(model),hash) then return cat[model] end
    for key,entry in pairs(cat) do
        if type(entry)=='table' and type(key)=='string' and sameHash(joaat(key),hash) then return entry end
    end
end
local function resolveTier(v,hash)
    local model=v and tostring(v.model or ''):lower() or ''
    local class=normalizeClass(v and v.class)
    local known=class and (allowed[class] or class=='cycles' or class=='boats' or class=='helicopters' or class=='planes' or class=='service' or class=='emergency' or class=='military' or class=='trains')
    local entry
    if not known or model=='' or not sameHash(joaat(model),hash) then
        entry=catalogueEntry(model,hash)
        if entry then model=tostring(entry.model or model):lower(); class=normalizeClass(entry.class) or class end
    end
    -- Explicit protected/non-road classes are never made eligible by a model override.
    if class and not allowed[class] and (class=='cycles' or class=='boats' or class=='helicopters' or class=='planes' or class=='service' or class=='emergency' or class=='military' or class=='trains') then return nil,class,model,entry,'restricted' end
    for _,m in ipairs(Config.Protected) do if sameHash(joaat(m),hash) then return nil,class,model,entry,'restricted' end end
    local override=Config.Models[model]
    if not override then for m,t in pairs(Config.Models) do if sameHash(joaat(m),hash) then override=t; break end end end
    if not override then
        for name in tostring(Config.AdditionalStreetModels or ''):lower():gmatch('[%w_]+') do
            if name~='none' and sameHash(joaat(name),hash) then override='medium'; if model=='' then model=name end; break end
        end
    end
    local tier=override or allowed[class]
    if tier and labels[tier] and tier~='tracker' then return tier,class,model,entry end
    return nil,class,model,entry,'unknown'
end
local function clamp(v,a,b) return math.max(a,math.min(b,tonumber(v) or a)) end
local function now() return GetGameTimer() end
local function ident(p) return p.charId or p.session end
local function push(src,event,data) TriggerClientEvent('whip_waink:overlayPush',src,event,data) end
local function phone(src) return core:HasItem(src,'phone',1) end
local function near(src,coords,range)
    local ped=GetPlayerPed(src); return ped~=0 and DoesEntityExist(ped) and coords and #(GetEntityCoords(ped)-coords)<=range
end
-- Fail closed on persisted, secured, temporary or owner-bearing framework records.
local function isStreetRecord(v)
    if type(v)~='table' or v.session~=true or v.temp or v.secure then return false end
    local function empty(x) return x==nil or x==false or x==0 or x=='0' or x=='' end
    for _,key in ipairs({'charId','ownerId','ownerCharId','citizenid','characterId','owned','persistent','registered','rental','rented','isRental','mission','protected'}) do
        if not empty(v[key]) then return false end
    end
    if type(v.owner)=='table' then
        for _,key in ipairs({'charId','id','ownerId','characterId','citizenid','identifier','accountId','businessId','job','gang'}) do
            if not empty(v.owner[key]) then return false end
        end
    elseif not empty(v.owner) then return false end
    -- Honour explicit protection flags in resource data as well as the snapshot.
    if type(v.data)=='table' then
        for _,key in ipairs({'rental','rented','isRental','mission','protected','wainkProtected'}) do
            if not empty(v.data[key]) then return false end
        end
    end
    return true
end
-- Plate lookup catches an owned record even if the live entity has not yet been linked.
local function protectedPlate(ent)
    local plate=GetVehicleNumberPlateText(ent)
    if type(plate)~='string' or not plate:match('%S') then return true end
    local ok,v,why=pcall(function() return core:GetVehicle({plate=plate}) end)
    if not ok or v==false then return true end
    return v~=nil and not isStreetRecord(v)
end
local function playerOccupies(ent,except)
    for _,sid in ipairs(GetPlayers()) do
        local src=tonumber(sid)
        if src~=except then local ped=GetPlayerPed(src); if ped~=0 and GetVehiclePedIsIn(ped,false)==ent then return true end end
    end
    return false
end
-- Population type can change when a framework adopts an ambient vehicle.
-- Record server-observed random origin before adoption; never trust a client flag.
local function randomPopulation(pop)
    return type(pop)=='number' and pop>=1 and pop<=5
end
local function rememberOrigin(ent)
    if ent==0 or not DoesEntityExist(ent) or GetEntityType(ent)~=2 then return false end
    local net=NetworkGetNetworkIdFromEntity(ent)
    if not net or net==0 then return false end
    local hash=GetEntityModel(ent)
    local origin=origins[ent]
    if origin and origin.net==net and origin.hash==hash then return true end
    origins[ent]=nil
    local pop=GetEntityPopulationType(ent)
    if not randomPopulation(pop) then return false end
    origins[ent]={net=net,hash=hash,pop=pop}
    return true
end
local function compatibleOrigin(ent,old,tier)
    if not tier or protectedPlate(ent) then return false end
    if old and not isStreetRecord(old) then return false end
    local pop=GetEntityPopulationType(ent)
    -- Unknown sync population is not proof of ownership. Require the known model,
    -- live entity/plate lookups and WHIP's ownership guard at every action.
    if Config.UnknownPopulation and pop==0 then return true end
    -- A WHIP non-temp/non-secure session may already have been pinned. This is
    -- configurable because other resources can use sessions for rentals.
    if Config.SessionPopulation and old and isStreetRecord(old) and (pop==6 or pop==7) then return true end
    -- Explicit server-admin opt-in for non-WHIP scripted cars. Off by default.
    if Config.ScriptedPopulation and not old and (pop==6 or pop==7) then return true end
    return false
end
local function verifiedOrigin(ent,old,tier)
    local p=old and profiles[old.vehicleId]
    if p and p.ambient and p.entity==ent and p.netId==NetworkGetNetworkIdFromEntity(ent) and sameHash(joaat(p.model),GetEntityModel(ent)) then return true end
    return rememberOrigin(ent) or compatibleOrigin(ent,old,tier)
end
AddEventHandler('entityCreated',function(ent)
    -- Reset reused handles before recording the newly created entity.
    origins[ent]=nil
    if DoesEntityExist(ent) and GetEntityType(ent)==2 then rememberOrigin(ent) end
end)
AddEventHandler('entityRemoved',function(ent) origins[ent]=nil end)
-- Seed already-streamed random vehicles once; no recurring vehicle-pool scan.
CreateThread(function()
    Wait(0)
    for _,ent in ipairs(GetAllVehicles()) do rememberOrigin(ent) end
end)
local function current(src,id,range,parked,allowNew)
    if type(id)~='number' or id%1~=0 then return nil,'Invalid vehicle' end
    local v=core:GetVehicle(id,{occupants=true})
    if not isStreetRecord(v) then return nil,'Protected or unavailable vehicle' end
    local ent=v.entity
    if not ent or ent==0 or not DoesEntityExist(ent) or GetEntityType(ent)~=2 then return nil,'Vehicle no longer available' end
    if protectedPlate(ent) then return nil,'Protected vehicle plate' end
    if GetPlayerRoutingBucket(src)~=GetEntityRoutingBucket(ent) then return nil,'Vehicle unavailable' end
    if range and not near(src,GetEntityCoords(ent),range) then return nil,'Move closer to the vehicle' end
    local model=tostring(v.model):lower()
    for _,m in ipairs(Config.Protected) do if model==m then return nil,'Restricted vehicle' end end
    local tier,class,_,_,kind=resolveTier(v,GetEntityModel(ent))
    if not tier then return nil,kind=='restricted' and 'Restricted vehicle category' or 'Vehicle model not verified in WHIP catalogue' end
    if parked and (playerOccupies(ent,nil) or GetPedInVehicleSeat(ent,-1)~=0 or GetEntitySpeed(ent)>1.0 or (v.occupants and next(v.occupants))) then return nil,'Vehicle must be parked and empty' end
    local p=profiles[id]
    if p and (p.entity~=ent or p.model~=model or p.netId~=v.netId) then profiles[id]=nil; p=nil end
    if not p then
        if not allowNew then return nil,'Vehicle is not a verified WAiNK street vehicle' end
        -- Never opt mission/scripted cars into this activity. Existing WAiNK cars remain valid after WHIP pins them.
        if not verifiedOrigin(ent,v,tier) then return nil,'Street origin unverified; scan only' end
        p={ambient=true,entity=ent,netId=v.netId,model=model,class=class,tier=tier,alarm=math.random(100)<=clamp(Config.AlarmChance,0,100),tracker=0}
        if math.random(100)<=clamp(Config.TrackerChance,0,100) then p.tracker=math.random(100)<=clamp(Config.AdvancedChance,0,100) and 2 or 1 end
        profiles[id]=p
    end
    if not p.ambient then return nil,'Vehicle provenance could not be verified' end
    p.class=class or p.class; p.tier=tier
    return v,p
end
local function values(v,p)
    local base=clamp(Config.Prices[p.tier],100,2000000)
    local health=clamp(v.stats and v.stats.bodyHealth or 1000,0,1000)
    local factor=0.4+health/1000*0.6
    return math.max(1,math.floor(base*clamp(Config.SalePercent,1,80)/100*factor)),math.max(1,math.floor(base*clamp(Config.RegistrationPercent,1,100)/100)),math.floor(health/10)
end
local function details(v,p,src)
    local sale,registration,condition=values(v,p)
    return {id=v.vehicleId or p.id,model=p.model,name=v.displayName or p.model,class=tostring(p.class or v.class or 'Vehicle'),plate=v.plate,locked=v.locked==true,
        item=labels[p.tier],itemKey=Config.Items[p.tier],tier=p.tier,alarm=p.alarm,tracker=p.tracker,condition=condition,sale=sale,registration=registration,
        image=core:GetVehicleImage(p.model),accessed=p.owner==src,hasTool=core:HasItem(src,Config.Items[p.tier],1)==true,hasSignal=core:HasItem(src,Config.Items.tracker,1)==true}
end
local function record(src,player,data)
    local key=tostring(ident(player)); local h=history[key] or {}; history[key]=h
    for i=#h,1,-1 do if h[i].model==data.model then table.remove(h,i) end end
    table.insert(h,1,{model=data.model,name=data.name,class=data.class,image=data.image}); if #h>100 then table.remove(h) end
end
local function guard(src) if not Config.Enabled then return false,'WAiNK disabled' end; if not phone(src) then return false,'Phone required' end; return true end
local function scan(src,player,args)
    local ok,why=guard(src); if not ok then return false,why end
    if type(args)~='table' or type(args.netId)~='number' or args.netId%1~=0 or args.netId<1 then return false,'No target' end
    local ticket=scans[src]
    if not ticket or ticket.char~=ident(player) or now()>ticket.untilAt or now()-ticket.start<clamp(Config.ScanMs,500,4000)-150 then return false,'Scan expired' end
    scans[src]=nil
    lastScan[src]=nil
    local e=NetworkGetEntityFromNetworkId(args.netId)
    if e==0 or not DoesEntityExist(e) or GetEntityType(e)~=2 or GetEntityRoutingBucket(e)~=GetPlayerRoutingBucket(src) or not near(src,GetEntityCoords(e),clamp(Config.ScanRange,3,35)) then return false,'No nearby vehicle' end
    local old=core:GetVehicle({entity=e})
    if (old and not isStreetRecord(old)) or protectedPlate(e) then return false,'Player-owned or protected vehicle' end
    if playerOccupies(e,nil) then return false,'Player vehicle occupied' end
    local hash=GetEntityModel(e)
    local tier,class,model,entry,kind=resolveTier(old,hash)
    if kind=='restricted' then return false,'Restricted vehicle category' end
    local moving=GetPedInVehicleSeat(e,-1)~=0 or GetEntitySpeed(e)>1 or (old and old.occupants and next(old.occupants))
    local street=verifiedOrigin(e,old,tier)
    if moving or not tier or not street then
        if not street or not tier then
            print(('[whip_waink] Identification only: model=%s net=%s population=%s WHIP record=%s class=%s'):format(tostring(hash),tostring(args.netId),tostring(GetEntityPopulationType(e)),tostring(old and old.vehicleId or 'none'),tostring(class)))
        end
        -- Client-reported class and name are display-only, never used to grant a transaction.
        local function label(v,fallback) if type(v)~='string' then return fallback end; return v:sub(1,64):gsub('[%c]','') end
        if model=='' then model=label(args.modelLabel,tostring(hash)) end
        local p=old and profiles[old.vehicleId]
        local seed=(math.abs(hash)+args.netId*31)%100
        local tracker=p and p.tracker or ((seed<clamp(Config.TrackerChance,0,100)) and ((seed%10<clamp(Config.AdvancedChance,0,100)/10) and 2 or 1) or 0)
        local alarm=p and p.alarm or (not p and seed<clamp(Config.AlarmChance,0,100))
        local sale,registration,condition=values(old or {},{tier=tier or 'medium'})
        local lock=GetVehicleDoorLockStatus(e)
        local data={previewOnly=true,previewReason=not street and 'Vehicle identified. Its NPC street origin could not be verified; access, sale and registration are protected.' or not tier and 'Model not verified in WHIP vehicle catalogue. An admin can approve this model in /whip WAiNK settings.' or nil,
            model=model,name=old and old.displayName or entry and entry.displayName or label(args.display,model),class=class or normalizeClass(args.class) or 'Unknown',plate=GetVehicleNumberPlateText(e),locked=lock>1,item=tier and labels[tier] or 'Not verified',tier=tier or 'Unknown',unverified=not tier,alarm=alarm,tracker=tracker,condition=condition,sale=tier and sale or nil,registration=tier and registration or nil,accessed=false}
        record(src,player,data); push(src,'result',data); return true
    end
    local id=old and old.vehicleId
    if not id then
        if not verifiedOrigin(e,old,tier) then return false,'Street origin unverified; scan again' end
        id,why=core:AdoptVehicle({entity=e,player=src}); if not id then return false,why end
        -- Adoption may pin the ambient car and change its native population type; remember its verified origin.
        local nv=core:GetVehicle(id)
        local tier=nv and resolveTier(nv,hash)
        if isStreetRecord(nv) and tier and labels[tier] and not protectedPlate(e) then
            local p={ambient=true,entity=e,netId=nv.netId,model=tostring(nv.model):lower(),class=class,tier=tier,alarm=math.random(100)<=clamp(Config.AlarmChance,0,100),tracker=0}
            if math.random(100)<=clamp(Config.TrackerChance,0,100) then p.tracker=math.random(100)<=clamp(Config.AdvancedChance,0,100) and 2 or 1 end
            profiles[id]=p
        end
    end
    local v,p=current(src,id,clamp(Config.ScanRange,3,35),true,true); if not v then return false,p end
    p.id=id; p.last=now(); lastScan[src]={id=id,session=player.session}; local data=details(v,p,src); record(src,player,data); push(src,'result',data); return true
end
local function startTask(src,player,args)
    local ok,why=guard(src); if not ok then return false,why end
    if type(args)~='table' or (args.kind~='access' and args.kind~='tracker') then return false,'Invalid action' end
    local v,p=current(src,args.id,clamp(Config.AccessRange,2,5),true); if not v then return false,p end
    if pending[src] and pending[src].expires>now() then return false,'Already working' end
    if busy[args.id] and busy[args.id].expires>now() then return false,'Someone is working on this vehicle' end
    if p.owner and (p.owner~=src or p.char~=ident(player)) then return false,'Vehicle already claimed for this activity' end
    if args.kind=='access' and p.owner==src then return false,'Access already granted' end
    if args.kind=='tracker' and (p.owner~=src or p.tracker==0) then return false,'No active tracker challenge' end
    local item=Config.Items[args.kind=='access' and p.tier or 'tracker']
    if not core:HasItem(src,item,1) then return false,'Required item missing' end
    if args.item and args.item~=item then return false,'This is not the required WAiNK tool' end
    local difficulty=({low='easy',medium='medium',high='medium',elite='hard'})[p.tier] or 'medium'
    -- WHIP accepts inline ring levels on both server and client; no core preset required.
    if args.kind=='access' and p.tier=='medium' then
        local seconds=clamp(tonumber(Config.LockKitSeconds) or 18,8,36)
        difficulty={level={pieces=8,parts=12,widest=4,narrowest=1,msPerPart=math.floor(seconds*1000/12)}}
    end
    local game=({high='phone.override',elite='phone.bruteforce'})[p.tier]
    if args.kind=='tracker' then difficulty=p.tracker==2 and 'hard' or 'medium'; game='phone.reroute' end
    local t={id=args.id,kind=args.kind,item=item,character=ident(player),session=player.session,start=now(),expires=now()+150000,src=src,difficulty=difficulty,game=game}
    pending[src]=t; busy[args.id]=t
    TriggerClientEvent('whip_waink:launchSkill',src)
    return true
end
local function finishTask(src,player)
    local t=pending[src]; if not t then return false,'No active challenge' end
    pending[src]=nil
    if busy[t.id]~=t then return false,'Challenge replaced' end
    local function done(ok,why) if busy[t.id]==t then busy[t.id]=nil end; return ok,why end
    if not Config.Enabled or not phone(src) or t.character~=ident(player) or not t.passed or not core:IsSessionCurrent(src,t.session) or core:IsPlayerDead(src) or now()>t.expires then return done(false,'Challenge expired') end
    local v,p=current(src,t.id,clamp(Config.AccessRange,2,5),true); if not v then return done(false,p) end
    if p.owner and (p.owner~=src or p.char~=ident(player)) then return done(false,'Vehicle reserved') end
    if not core:HasItem(src,t.item,1) then return done(false,'Tool missing') end
    if t.kind=='access' then
        if p.owner then return done(false,'Already accessed') end
        local granted,why=core:GiveVehicleKey(src,t.id)
        if not granted and not core:HasVehicleKey(src,t.id) then return done(false,why or 'Could not grant in-game key') end
        local unlocked,err=core:SetVehicleLocked(t.id,false)
        if not unlocked then if granted then core:RemoveVehicleKey(src,t.id) end; return done(false,err) end
        p.owner=src; p.char=ident(player); p.last=now()
        if p.alarm or p.tracker>0 then TriggerEvent('whip_waink:securityAlert',{source=src,vehicleId=t.id,coords=GetEntityCoords(v.entity),alarm=p.alarm,tracker=p.tracker}) end
        if p.alarm then TriggerClientEvent('whip_waink:alarm',src,v.netId) end
    else
        if p.owner~=src or p.char~=ident(player) or p.tracker==0 then return done(false,'No tracker challenge') end
        p.tracker=0
    end
    if Config.ItemConsume then core:RemoveItem(src,t.item,1,nil,{reason='WAiNK gameplay'}) end
    v=core:GetVehicle(t.id) or v; push(src,'result',details(v,p,src)); return done(true)
end
local function releaseTask(src,t)
    if pending[src]==t then pending[src]=nil end
    if busy[t.id]==t then busy[t.id]=nil end
end
local function runSkill(src,player)
    local t=pending[src]
    if not Config.Enabled then if t then releaseTask(src,t) end; return false,'WAiNK disabled' end
    if not t or t.running or now()>t.expires or t.session~=player.session then return false,'No active tool challenge' end
    t.running=true
    local v,why=current(src,t.id,clamp(Config.AccessRange,2,5),true)
    if not v or not core:HasItem(src,t.item,1) then releaseTask(src,t); return false,v and 'Required tool missing' or why end
    local ok,passed,reason=pcall(function()
        return core:SkillCheck(src,t.difficulty,t.game and {game=t.game} or {})
    end)
    if pending[src]~=t then return false,'Challenge cancelled' end
    if not ok or passed~=true then releaseTask(src,t); return false,ok and ('Challenge '..tostring(reason or 'failed')) or 'Skill game unavailable' end
    t.passed=true
    local success,err=finishTask(src,player)
    if success then core:NotifyPlayer(src,t.kind=='tracker' and 'Signal challenge complete' or 'Vehicle access granted','success') end
    return success,err
end
local function deal(src,player,args)
    if not Config.Enabled or not player or player.isDead then return false,"Dealer unavailable" end
    if type(args)~='table' or (args.kind~='sell' and args.kind~='register') then return false,'Invalid deal' end
    local loc=Config.Buyer
    if not loc.enabled or not near(src,loc.coords,3.5) then return false,'Visit the configured location first' end
    local id=args.id; if not id then return false,'Bring a WAiNK vehicle' end
    local v,p=current(src,id,clamp(loc.radius,3,30)+3.5,true); if not v then return false,p end
    if p.owner~=src or p.char~=ident(player) then return false,'Complete WAiNK access first' end
    if p.tracker>0 then return false,'Complete the fictional tracker challenge first' end
    if GetVehiclePedIsIn(GetPlayerPed(src),false)~=0 or #(GetEntityCoords(v.entity)-loc.coords)>clamp(loc.radius,3,30) then return false,'Park beside Moses and get out' end
    if GetEntitySpeed(v.entity)>0.8 then return false,'Stop the vehicle' end
    if busy[id] and busy[id].expires>now() then return false,'Vehicle busy' end
    if next(v.occupants or {}) then return false,'All occupants must exit' end
    local k=tostring(ident(player)); if args.kind=='sell' and (cooldowns[k] or 0)>now() then return false,'Buyer is on cooldown' end
    local lock={expires=now()+60000}; busy[id]=lock
    local sale,fee=values(v,p)
    local function finish(a,b) if busy[id]==lock then busy[id]=nil end; return a,b end
    if sale~=args.sale or fee~=args.fee then return finish(false,'Price changed; ask for a new quote') end
    local function recheck()
        local latest,lp=current(src,id,clamp(loc.radius,3,30)+3.5,true)
        if not Config.Enabled or not loc.enabled or not latest or lp~=p or p.owner~=src or p.char~=ident(player) or p.tracker>0 or not core:IsSessionCurrent(src,player.session) or core:IsPlayerDead(src) or GetVehiclePedIsIn(GetPlayerPed(src),false)~=0 or not near(src,loc.coords,3.5) or GetEntitySpeed(latest.entity)>0.8 or #(GetEntityCoords(latest.entity)-loc.coords)>clamp(loc.radius,3,30) then return nil end
        if next(latest.occupants or {}) then return nil end
        return latest
    end
    if not recheck() then return finish(false,'Vehicle changed or is protected') end
    if args.kind=='register' then
        local receipt,err=core:ChargePlayer(src,fee,{method='bank',reason='WAiNK vehicle registration'}); if not receipt then return finish(false,err) end
        if not recheck() then core:RefundPlayer(receipt); return finish(false,'Vehicle changed') end
        local new,err2=core:ClaimVehicle(id,src,{reason='WAiNK registration'}); if not new then core:RefundPlayer(receipt); return finish(false,err2) end
        profiles[id]=nil; return finish({message='Vehicle registered',amount=fee})
    end
    local latest=recheck(); if not latest then return finish(false,'Vehicle changed or is protected') end
    local entity=latest.entity
    local deleted,err=core:DeleteVehicle(id); if not deleted then return finish(false,err) end
    profiles[id]=nil; cooldowns[k]=now()+clamp(Config.SaleCooldown,0,3600)*1000
    if DoesEntityExist(entity) then DeleteEntity(entity) end
    local paid,err2=core:PayPlayer({charId=player.charId},sale,{method='bank',reason='WAiNK vehicle sale'})
    if not paid then print(('[whip_waink] PAYMENT FAILED char=%s amount=%s: %s'):format(k,sale,tostring(err2))); return finish(false,'Sale recorded; payment failed. Contact an admin.') end
    return finish({message='Vehicle sold',amount=sale})
end
local function dealerQuote(src,player)
    if not Config.Enabled or not Config.Buyer.enabled or not player or player.isDead then return nil end
    local loc=Config.Buyer
    if not near(src,loc.coords,3.5) or GetVehiclePedIsIn(GetPlayerPed(src),false)~=0 then return nil end
    local best,dist
    for id,p in pairs(profiles) do
        if p.owner==src and p.char==ident(player) and p.tracker==0 then
            local v,profile=current(src,id,clamp(loc.radius,3,30)+3.5,true)
            if v and profile==p then
                local d=#(GetEntityCoords(v.entity)-loc.coords)
                if d<=clamp(loc.radius,3,30) and (not dist or d<dist) then
                    local sale,fee=values(v,p); best={id=id,sale=sale,fee=fee,name=v.displayName or p.model}; dist=d
                end
            end
        end
    end
    return best
end
local function refreshDealer()
    releaseDealer()
    local loc=Config.Buyer
    if not Config.Enabled or not loc.enabled then
        print('[whip_waink] Dealer disabled. Enable Vehicle dealer in /whip > Settings > WAiNK.')
        return true
    end
    if not loc.coords or (loc.coords.x==0 and loc.coords.y==0 and loc.coords.z==0) then
        print('[whip_waink] Dealer location not set. Place Moses in /whip > Settings > WAiNK > Vehicle dealer.')
        return true
    end
    dealerSequence=dealerSequence+1
    local dealerTag='whip_waink:dealer:'..dealerEpoch..':'..dealerSequence
    activeDealerTag=dealerTag
    local npc,net=core:SpawnNpc({model=loc.model,coords=vector4(loc.coords.x,loc.coords.y,loc.coords.z+(tonumber(loc.zOffset) or 0),loc.heading),behaviour='stand',interior=loc.useInteriorGate==true,conditions={invincible=true,canMove=false,reacts=false}}, {tag=dealerTag,fightBack=false})
    if not npc or type(net)~='number' or net<=0 then return false,'SpawnNpc: '..tostring(net) end
    local point,err=core:AddPoint({at={netId=net,offset=vector3(0,0,0.3)},label='Speak to '..loc.speaker,icon='talk',talk=true,reach=3.0,seeFrom=8.0,tag=dealerTag,onUse=function(src,use)
        local player=core:GetPlayer(src)
        local quote=dealerQuote(src,player)
        local leave={id='bye',label='I will come back later.',ends=true}
        local options={leave}
        local line="Alright, mate. Bring me a car from WAiNK, park it nearby and make sure it's ready. Then we can talk business."
        if quote then
            line=('Alright, mate. I take it that %s out there is yours to deal with? I can take it off your hands or register it for you. What are you thinking?'):format(quote.name)
            options={{id='sell',label='What will you pay for it?'},{id='register',label='I want to register it.'},leave}
        end
        return core:StartConversation(src,{fromUse=use.useId,npcId=npc,speaker=loc.speaker,line=line,options=options,layout='stack',tag=dealerTag,onChoose=function(who,answer,conv)
            if answer=='bye' then return end
            if not quote then return core:EndConversation(conv) end
            if answer=='sell' or answer=='register' then
                local selling=answer=='sell'; local price=selling and quote.sale or quote.fee
                core:UpdateConversation(conv,{line=selling and ("I'll give you $%d for it. Straight into your bank. Once we shake on it, the car stays with me. Sound fair?"):format(price) or ("I can put the %s in your name for $%d. You'll keep the car and it will be in your WHIP garage records. You happy with that?"):format(quote.name,price),options={{id=selling and 'confirm_sell' or 'confirm_register',label=selling and 'Deal. Sell it.' or 'Deal. Register it.'},leave}})
            elseif answer=='confirm_sell' or answer=='confirm_register' then
                local latest=core:GetPlayer(who)
                if not latest or not player or latest.session~=player.session then core:EndConversation(conv); return end
                local kind=answer=='confirm_sell' and 'sell' or 'register'
                local ok,why=deal(who,latest,{kind=kind,id=quote.id,sale=quote.sale,fee=quote.fee})
                core:UpdateConversation(conv,{line=ok and (kind=='sell' and "Nice doing business with you. Money's in your account. See you next time." or "All sorted, mate. She's yours now. Look after her.") or ("Can't do that deal right now. "..tostring(why or 'Try again later.')),options={{id='bye',label='Cheers, mate.',ends=true}}})
            end
        end})
    end})
    if not point then return false,'AddPoint: '..tostring(err) end
    print(('[whip_waink] Dealer ready: %s (NPC %s, net %s) at %.2f, %.2f, %.2f'):format(loc.speaker,tostring(npc),tostring(net),loc.coords.x,loc.coords.y,loc.coords.z))
    return true
end
-- WHIP owns this map marker independently of the dealer's short-lived NPC tag.
local dealerBlipId = 'waink_vehicle_dealer'
local function refreshDealerBlip()
    local loc, style = Config.Buyer, Config.Blips
    local coords = loc and loc.coords
    local ok, why
    if not Config.Enabled or not loc or not loc.enabled or not loc.blip or not coords or
        (coords.x == 0 and coords.y == 0 and coords.z == 0) then
        ok, why = core:HideBlip(dealerBlipId)
    else
        local label = type(loc.name) == 'string' and loc.name:match('^%s*(.-)%s*$') or ''
        if label == '' then label = 'Moses - Vehicle dealer' end
        -- WHIP's legend accepts at most 40 characters; never split a UTF-8 sequence.
        local length = utf8.len(label)
        if not length then label = 'Moses - Vehicle dealer'
        elseif length > 40 then label = label:sub(1, utf8.offset(label, 41)-1) end
        ok, why = core:ShowBlip('everyone', dealerBlipId, {
            coords = vector3(coords.x, coords.y, coords.z), label = label,
            sprite = math.floor(tonumber(style.Sprite) or 225),
            color = math.floor(tonumber(style.Colour) or 27),
            scale = tonumber(style.Scale) or 0.72, shortRange = style.ShortRange == true
        })
    end
    if ok == false then print('[whip_waink] Dealer blip: '..tostring(why)) end
    return ok, why
end
local blipRegistered, blipScheduled = false, false
local function scheduleDealerBlip()
    if not blipRegistered or blipScheduled then return end
    blipScheduled = true
    CreateThread(function()
        Wait(350)
        blipScheduled = false
        local ok, err = pcall(refreshDealerBlip)
        if not ok then print('[whip_waink] Dealer blip API error: '..tostring(err)) end
    end)
end
-- Settings hooks must not yield. Coalesce a whole save into one server thread.
local dealerRegistered, dealerWorker, dealerRevision=false,false,0
local function scheduleDealer()
    dealerRevision=dealerRevision+1
    if not dealerRegistered or dealerWorker then return end
    dealerWorker=true
    CreateThread(function()
        repeat
            Wait(350)
            local revision=dealerRevision
            for attempt=1,3 do
                if revision~=dealerRevision then break end
                local called,ok,why=pcall(refreshDealer)
                if called and ok then break end
                print(('[whip_waink] Dealer attempt %d/3 failed: %s'):format(attempt,tostring(called and why or ok)))
                local cleaned,cleanupError=pcall(releaseDealer)
                if not cleaned then print('[whip_waink] '..tostring(cleanupError)) end
                if attempt<3 then Wait(1500) end
            end
        until revision==dealerRevision
        dealerWorker=false
    end)
end
Whip.register(function()
    profiles,scans,pending,busy,cooldowns={},{},{},{},{}
    lastScan={}
    for tier,key in pairs(Config.Items) do
        local toolTier,toolKey=tier,key
        core:RegisterItem(key,{name=labels[tier],desc=descriptions[tier],weight=tier=='elite' and 0.8 or 0.35,stack=false,usable=true,type='tool',image='html/img/items/'..(tier=='low' and 'waink_slimjim_vi' or key)..'.webp'})
        core:RegisterUseHandler(key,function(src,player)
            local last=lastScan[src]
            if not last or last.session~=player.session then return false,'Scan an eligible vehicle with WAiNK first' end
            local ok,why=startTask(src,player,{id=last.id,kind=toolTier=='tracker' and 'tracker' or 'access',item=toolKey})
            if not ok then return false,why end
            return false -- tool kept here; optional consumption only after the skill check passes
        end)
    end
    core:SecureEvent('whip_waink:runSkill',{rateLimit=1000},runSkill)
    activeDealerTag=nil -- core has rebuilt its NPC registry
    dealerRegistered=true
    blipRegistered=true
    scheduleDealer()
    scheduleDealerBlip()
    local function cb(name,rate,fn) core:SecureCallback('whip_waink:'..name,{rateLimit=rate,params={{'args','any'}}},fn) end
    cb('beginScan',1000,function(src,player,args) local ok,why=guard(src); if not ok then return false,why end; scans[src]={char=ident(player),start=now(),untilAt=now()+17000}; TriggerClientEvent('whip_waink:aim',src,type(args)=='table' and args.side=='left' and 'left' or 'right'); return true end)
    cb('scanResult',1000,scan)
    cb('cancelScan',500,function(src) scans[src]=nil; TriggerClientEvent('whip_waink:cancelAim',src); return true end)
    cb('history',500,function(src,player) return history[tostring(ident(player))] or {} end)
    cb('lastVehicle',500,function(src,player)
        local last=lastScan[src]; if not last or last.session~=player.session then return {} end
        local v,p=current(src,last.id,clamp(Config.ScanRange,3,35),false)
        if not v then return {} end
        return {vehicle=details(v,p,src)}
    end)
    cb('startTask',1000,startTask)
    cb('cancelTask',500,function(src) local t=pending[src]; if t and not t.running then releaseTask(src,t) end; return true end)
    cb('locations',500,function() return {buyer={enabled=Config.Buyer.enabled,name=Config.Buyer.name,coords={x=Config.Buyer.coords.x,y=Config.Buyer.coords.y,z=Config.Buyer.coords.z}},registrar={enabled=Config.Registrar.enabled,name=Config.Registrar.name,coords={x=Config.Registrar.coords.x,y=Config.Registrar.coords.y,z=Config.Registrar.coords.z}}} end)
    cb('waypoint',500,function(src,_,args) if type(args)~='table' then return false,'Invalid location' end; local l=(args.kind=='sell' or args.kind=='register') and Config.Buyer; if not l or not l.enabled then return false,'Location not configured' end; TriggerClientEvent('whip_waink:waypoint',src,l.coords.x,l.coords.y); return true end)
end)
local function scheduleDealerAndBlip() scheduleDealer(); scheduleDealerBlip() end
Whip.onConfigChanged('Buyer',scheduleDealerAndBlip); Whip.onConfigChanged('Enabled',scheduleDealerAndBlip); Whip.onConfigChanged('Blips',scheduleDealerBlip)
AddEventHandler('playerDropped',function() local src=source; lastScan[src]=nil; local t=pending[src]; if t and busy[t.id]==t then busy[t.id]=nil end; pending[src]=nil; scans[src]=nil; for _,p in pairs(profiles) do if p.owner==src then p.owner=nil; p.char=nil end end end)
AddEventHandler('whip_core:vehicle:deleted',function(d) if type(d)=='table' then profiles[d.vehicleId]=nil end end)
AddEventHandler('whip_core:vehicle:released',function(d) if type(d)=='table' then profiles[d.vehicleId]=nil end end)
AddEventHandler('whip_core:vehicle:claimed',function(d) if type(d)=='table' then profiles[d.from]=nil end end)
CreateThread(function() while true do Wait(60000); for id,p in pairs(profiles) do if not DoesEntityExist(p.entity) then profiles[id]=nil end end; for src,t in pairs(pending) do if now()>t.expires then if busy[t.id]==t then busy[t.id]=nil end; pending[src]=nil end end; for src,t in pairs(scans) do if now()>t.untilAt then scans[src]=nil end end end end)
