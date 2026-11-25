fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'CookieLabs'
description 'WAiNK inspired fictional vehicle scanner and street car gameplay for WHIP'
version '1.12.5'
dependencies { 'whip_core', 'whip_phone' }
shared_scripts { '@whip_core/lib/satellite.lua', 'config.lua', 'settings.lua' }
client_script 'client/main.lua'
server_script 'server/main.lua'
files { 'html/phone_app.js', 'html/img/logo.svg', 'html/img/items/*.webp' }
