-- Targeted settings/boost regressions; run `lua testing/profiles-boosts.lua`.
table.clone = table.clone or function(t) local copy={};for k,v in pairs(t) do copy[k]=v end;return copy end
table.find = table.find or function(t,v) for i,x in ipairs(t) do if x==v then return i end end end
math.clamp = math.clamp or function(v,a,b) return math.max(a,math.min(b,v)) end
local Logic=dofile('src/HubLogic.luau')
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local header=read('src/ObsidianHub.luau'):match('^(.-)local repo =')..'return C, runtime'
for role,id in pairs({Host=1,Carry=2,Alt=3}) do
    for _,teleport in ipairs({false,true}) do
        local player={Name=role,UserId=id}
        local old={Version=2,Config={Role='Carry',Enabled=true,Distance=51,AutoSell=true},Runtime={Levels={['1']=156}}}
        local env={autoloadconfig=true,DQRewriteResume=teleport and old or nil}
        local files={['DungeonQuestRewrite-'..id..'.json']=old,
            ['DungeonQuestRewrite-party.json']={Version=1,Party={Host='Host',Carry='Carry',Alts='Alt'}},
            ['DungeonQuestRewrite-role-'..role..'.json']={Version=1,Config={AutoStartRole=true,Distance=19,SyncEnabled=false}}}
        local globals=setmetatable({Logic=Logic,getgenv=function() return env end,readfile=function(path) return files[path] end,
            game={GetService=function(_,name) if name=='Players' then return {LocalPlayer=player} end;return {JSONDecode=function(_,s) return s end} end}}, {__index=_G})
        local config,runtime=assert(load(header,'profile','t',globals))()
        assert(config.Role==role and config.Enabled and config.AutoStartRole and config.Distance==19)
        assert(not config.SyncEnabled and not config.AutoSell, 'Account settings leaked into role profile')
        assert(runtime.Levels['1']==156)
    end
end
print('PASS Carry/Host/Alt auto-start and profile precedence on fresh execute + teleport')
local offers={gold={ready=true,owned=false,cost=100},drop={ready=true,owned=false,cost=200},vip={ready=true,owned=false,cost=300},
    [1]={ready=true,valid=true,currency='gold',remaining=1,cost=100},
    [2]={ready=true,valid=true,currency='gold',remaining=1,cost=200},
    [4]={ready=true,valid=true,currency='gold',remaining=1,cost=400}}
local purchases={}
local config={AutoBuyBoosts=true}
local runtime={Boosts={['1']={remaining=0}}} -- stale saved data must not skip today's first offer.
local adapter={PermanentBoosts={{name='Gold',key='gold'},{name='Drop',key='drop'},{name='VIP',key='vip'}},
    XPBoosts={{name='XP 1h',id=1},{name='XP 2h',id=2},{name='XP 4h',id=4}},gold=function() return 1000 end,
    value=function() return false end,boostOffer=function(e) return offers[e.key or e.id] end,
    buyBoost=function(e) purchases[#purchases+1]=e.key or e.id end}
local globals=setmetatable({Adapter=adapter,game={GetService=function() return {LocalPlayer={}} end}}, {__index=_G})
local Boost=assert(loadfile('src/BoostManager.luau','t',globals))().new(config,runtime,function() return true end)
Boost.Tick(0);Boost.Tick(1);assert(#purchases==1 and purchases[1]=='gold')
offers.gold.owned=true;Boost.Tick(15);assert(purchases[2]=='drop')
offers.drop.owned=true;Boost.Tick(30);assert(purchases[3]=='vip')
offers.vip.owned=true;Boost.Tick(45);assert(purchases[4]==1)
offers[1].remaining=0;Boost.Tick(60);assert(purchases[5]==2)
offers[2].nextAvailableIn=3600;Boost.Tick(75);assert(purchases[6]==4)
offers[4].currency='robux';Boost.Tick(90);assert(#purchases==6)
offers[4].currency='gems';Boost.Tick(105);assert(#purchases==6)
offers[1].remaining=1;offers[1].cost=2000;Boost.Tick(120);assert(#purchases==6)
print('PASS permanent/XP priority, server-cycle authority, affordability, rate limits, no Robux/gems purchases')
