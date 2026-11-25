# Phone integration — original WHIP Duo 1.1.0

WAiNK registers via the normal external module API. The original phone must also expose `SetWainkAim` to temporarily return look controls to GTA while the app stays visible. This guide is based on the original 1.1.0 source and the previously supplied V1.6 bridge. It does not install a replacement phone.

## Option A — apply the supplied patch (recommended)

1. Stop the server and back up `whip_phone/client/main.lua`.
2. Download [whip_phone-1.1.0.patch](phone-bridge/whip_phone-1.1.0.patch). Open a terminal in your installed `whip_phone` directory. Git Bash works on Windows. Replace the example patch path with your actual absolute path (keep quotes if it contains spaces).

```bash
git apply --check "/path/to/whip_phone-1.1.0.patch"
git apply "/path/to/whip_phone-1.1.0.patch"
```

If the check fails, **do not force the patch**. Your phone may already contain the bridge, or be a different version. Search for `exports('SetWainkAim'` and check the surrounding lifecycle code; otherwise use Option B to merge the changes carefully. The patch was verified against the supplied unmodified 1.1.0 phone. Custom physical DUI forks are not covered by this patch.

## Option B — manual installation

All edits below are in `whip_phone/client/main.lua`. Back up the file first. Do not duplicate existing definitions.

### 1. Track the aiming lease

Immediately above `local blockWarned = false`, insert:

```lua
local externalAim = nil -- CookieLabs: registered WAiNK module camera input lease
```

### 2. Extract the existing control block into a helper

Immediately before the `setOpen(on, mode)` function (before its `--- mode:` comment), insert:

```lua
local function blockPhoneControls()
    local blocked, why = Whip.core:BlockControls('whip_phone', { groups = Config.BlockControls, controls = { 199, 200 } })
    if blocked ~= true and GetResourceState('whip_core') == 'started' then
        if not blockWarned then
            blockWarned = true
            print(('^3[whip_phone] Config.BlockControls was refused: %s. Only Start / Esc are blocked while the phone is up.^7')
                :format(tostring(why)))
        end
        Whip.core:BlockControls('whip_phone', { controls = { 199, 200 } })
    end
end
```

Inside `setOpen`, immediately after `open = on`, insert:

```lua
if not on then externalAim = nil end
```

Still inside `setOpen`, find the existing `local blocked, why = Whip.core:BlockControls('whip_phone', ...)` block and its following `if blocked ~= true ... end` error/fallback block. Replace just those statements with `blockPhoneControls()`. Leave the surrounding `if on then ... else ... end` and existing screen, emote and event code intact.

### 3. Add the camera export and cleanup

After `endForced = function(result) ... end`, immediately before the `--- Is this a phone app` comment and `local function hasApp(id)`, insert the full block:

```lua
-- CookieLabs WAiNK: temporarily release look controls while keeping the original Duo NUI visible.
-- Only the resource that registered WAiNK can acquire/release this lease.
local function releaseExternalAim()
    if not externalAim then return end
    externalAim = nil
    if open then
        Whip.core:UnblockControls('whip_phone')
        blockPhoneControls()
        screen:open()
        nui({ type = 'focus', on = true })
    end
end
exports('SetWainkAim', function(on)
    local m = external.waink
    if not m or m.resource ~= GetInvokingResource() then return false end
    if not on then releaseExternalAim(); return true end
    if not open or view ~= 'phone' or forced or externalAim then return false end
    externalAim = m.resource
    screen:close()
    Whip.core:UnblockControls('whip_phone')
    Whip.core:UnblockControls('whip_phone:keys')
    local ok = Whip.core:BlockControls('whip_phone', { groups = { 'combat', 'vehicleCombat', 'weaponWheel' }, controls = { 199, 200 } })
    if ok ~= true then
        releaseExternalAim()
        return false
    end
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    nui({ type = 'focus', on = false })
    return true
end)
AddEventHandler('onResourceStop', function(res)
    if externalAim == res then releaseExternalAim() end
end)
RegisterNUICallback('wainkPoll', function(data, cb)
    local m = external.waink
    if not open or not m or m.resource ~= 'whip_waink' or GetResourceState(m.resource) ~= 'started' then return cb({active=false, reason='WAiNK camera unavailable'}) end
    local ok, result = pcall(function() return exports.whip_waink:CameraPoll(type(data)=='table' and data.readyGeneration or -1) end)
    cb(ok and type(result)=='table' and result or {active=false,reason='WAiNK camera unavailable'})
end)
```

The `wainkPoll` callback is retained for compatibility with the earlier bridge; the current app uses direct WebGL rendering and normal phone push events. The resource name must remain `whip_waink`.

### 4. Release aiming before a forced phone skill game

Inside `local function runApp(id, args)`, after the `Whip.core:IsPlayerDead()` guard and immediately before `local f = { app = id, ... }`, add:

```lua
releaseExternalAim()
```

### 5. Restart and test

Start `whip_core`, `whip_phone` and `whip_waink` in that order. Open WAiNK in the original phone. Start a scan, aim at a vehicle, then check completion, cancellation with Backspace and phone closure. The previous camera and normal cursor should return. Confirm other phone apps and native skill games still function.

## Upgrading or reverting

Existing V1.6+ phone bridges do not need to be installed again. To revert, restore your backed-up phone file (or reverse the patch against an otherwise unchanged file with `git apply -R`). Reverting will disable WAiNK's camera aiming; remove WAiNK as well if you no longer need it.

[Patch licensing and attribution](phone-bridge/NOTICE.md) · [Back to README](../README.md)
