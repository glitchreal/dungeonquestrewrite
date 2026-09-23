-- Focused regressions for the party bugs: run `lua testing/lifecycle.lua`.
-- Uses the actual policy/coordinator with small game-interface fakes; no live mutations.
table.clone = table.clone or function(t) local copy = {}; for k,v in pairs(t) do copy[k]=v end; return copy end
table.clear = table.clear or function(t) for k in pairs(t) do t[k]=nil end end
table.find = table.find or function(t,v) for i,x in ipairs(t) do if x==v then return i end end end
math.clamp = math.clamp or function(v,a,b) return math.max(a,math.min(b,v)) end
local Logic = dofile('src/HubLogic.luau')
local tests = 0
local function check(name, fn) fn(); tests=tests+1; print('PASS '..name) end
local function fixture(role, mode)
    local world = { now=0, started=false, complete=false, calls={}, running=false, ready=true, present={[1]=true,[2]=true,[3]=true},
        level=156, dungeon={Dungeon='Volcanic Chambers',Difficulty='Nightmare',levelReq=155} }
    local ids={Host=1,Carry=2,Alt=3}
    local player={UserId=ids[role],Name=role}
    local players={LocalPlayer=player,GetPlayerByUserId=function(_,id) return world.present[id] and {} or nil end}
    local roster={{id=1,name='Host'},{id=2,name='Carry'},{id=3,name='Alt'}}
    local config={Enabled=true,Role=role,Host='Host',Carry='Carry',Alts='Alt',SyncEnabled=true,SyncURL='',RequireScriptsReady=false,
        AutoBest=true,AutoSwitch=true,AutoJoin=true,AutoAccept=true,LevelKaitun=true,JoinInterval=10,StartDelay=3,RecoveryGrace=45,OCD=true}
    local Adapter={level=function() return world.level end,value=function(_,_,fallback) return fallback end,
        roster=function() return roster,roster[1],roster[2] end,currentDungeon=function() return world.dungeon end,
        started=function() return world.started end,finished=function() return world.complete end,failed=function() return false end,
        ownerId=function() return 1 end,pendingRequests=function() return {} end,catalog=function() return Logic.catalog() end,
        members=function() local out={}; for _,a in ipairs(roster) do out[#out+1]={id=a.id,name=a.name,present=world.present[a.id],level=world.present[a.id] and world.level} end; return out end,
        call=function(name,...) world.calls[#world.calls+1]={name,...}; return true end,
        replay=function() world.calls[#world.calls+1]={'replayDungeon'}; return true end,
        joinLobby=function() world.calls[#world.calls+1]={'joinLobby'}; return true,'Joining actual queue' end }
    local sync={status='Sync: waiting for Alt heartbeat',Update=function() end,Pause=function() end,SetPhase=function() end,
        Ready=function() return world.ready end,Member=function() return world.hostState end,
        NewCommand=function(phase,reason) return {id=phase..world.now,at=world.now,phase=phase,reason=reason} end,
        Announce=function(command) world.announced=command; return true end,Command=function() return world.command end}
    local runtime={}
    local env=setmetatable({Logic=Logic,Adapter=Adapter,AbilityController={new=function() return {} end},
        game={JobId='job',GetService=function() return players end},os={clock=function() return world.now end,time=function() return world.now end}}, {__index=_G})
    local Roles=assert(loadfile('src/RoleController.luau','t',env))()
    local state=Roles.new(config,runtime,mode or 'Dungeon',{SetRunning=function(v) world.running=v end},function() end,function() return true end,sync)
    function world.tick(now) world.now=now;state.Tick(now) end
    function world.count(name) local n=0;for _,c in ipairs(world.calls) do if c[1]==name then n=n+1 end end;return n end
    return world,state,config,runtime
end
check('same dungeon replays without script heartbeat; followers stay',function()
    for _,role in ipairs({'Host','Carry','Alt'}) do
        local w,s=fixture(role);w.complete=true;w.ready=false;w.tick(0);w.tick(6)
        assert(w.count('teleToLobby')==0);assert(w.count('replayDungeon')==(role=='Host' and 1 or 0))
        assert(s.phase==(role=='Host' and 'REPLAYING' or 'REWARDS_SETTLING'))
    end
end)
check('only Host decides newly eligible progression',function()
    local w,s=fixture('Host');w.level=160;w.complete=true;w.tick(0);w.tick(6)
    assert(w.count('teleToLobby')==1 and s.phase=='PROGRESSION_RETURN');assert(w.count('replayDungeon')==0)
    for _,role in ipairs({'Carry','Alt'}) do
        local f=fixture(role);f.level=160;f.complete=true;f.tick(0);f.tick(6);assert(f.count('teleToLobby')==0)
    end
end)
check('missing difficulty never invents an unlock',function()
    assert(not Logic.shouldProgress({Dungeon='Northern Lands',Difficulty='Nightmare',levelReq=185},{Dungeon='Northern Lands'}))
end)
check('completed Host rejects stale requests even when started is false',function()
    local w,s=fixture('Host');w.complete=true;s.OnRequest(77,'Alt');w.tick(0)
    assert(w.calls[1][1]=='respondJoinRequest' and w.calls[1][3]==false)
end)
check('started flag falling cannot reopen Host joins',function()
    local w,s=fixture('Host');w.started=true;w.tick(0);w.started=false;s.OnRequest(77,'Alt');w.tick(1)
    assert(s.phase=='REWARDS_SETTLING')
    for _,c in ipairs(w.calls) do if c[1]=='respondJoinRequest' then assert(c[3]==false) end end
end)
check('lobby follower never sends to a completed Host or its previous job',function()
    local w,_,_,r=fixture('Carry','Lobby');w.hostState={enabled=true,ready=true,mode='Dungeon',phase='REWARDS_SETTLING',jobId='old'}
    w.tick(0);assert(#w.calls==0)
    w.hostState.phase='PRE_START';r.LastDungeonJob='old';w.tick(11);assert(w.count('sendJoinRequest')==0)
    w.hostState.jobId='new';w.tick(22);assert(w.count('sendJoinRequest')==1)
end)
check('presence-only join uses actual lobby interface',function()
    local w,_,c=fixture('Alt','Lobby');c.SyncEnabled=false;w.tick(0)
    assert(w.count('joinLobby')==1 and w.count('sendJoinRequest')==0)
end)
check('Carry runs with missing heartbeat once dungeon started',function()
    for _,enabled in ipairs({true,false}) do
        local w,_,c=fixture('Carry');c.SyncEnabled=enabled;c.RequireScriptsReady=true;w.ready=false;w.started=true;w.tick(0)
        assert(w.running)
    end
end)
check('script readiness gates start only when requested',function()
    local w,_,c=fixture('Host');c.RequireScriptsReady=true;w.ready=false;w.tick(0);w.tick(10);assert(w.count('changeStartValue')==0)
    c.RequireScriptsReady=false;w.tick(11);w.tick(14);assert(w.count('changeStartValue')==1)
end)
check('slow initial arrival never arms OCD, even in a running job',function()
    local w,s=fixture('Host');w.started=true;w.present[3]=false;w.tick(0);w.tick(60)
    assert(w.count('teleToLobby')==0 and s.missingAt==nil)
    w.present[3]=true;w.tick(61);w.tick(65);assert(s.partySeen)
end)
check('continuous loss after stable party produces one epoch',function()
    local w,s=fixture('Host');w.started=true;w.tick(0);w.tick(4);w.present[3]=false;w.tick(5);w.tick(49)
    assert(w.count('teleToLobby')==0);w.tick(50);assert(w.count('teleToLobby')==1 and s.phase=='RECOVERING')
    local id=s.transition.id;w.tick(51);assert(s.transition.id==id and w.count('teleToLobby')==1)
end)
check('temporary loss resets continuous grace',function()
    local w=fixture('Host');w.started=true;w.tick(0);w.tick(4);w.present[3]=false;w.tick(5)
    w.present[3]=true;w.tick(30);w.present[3]=false;w.tick(31);w.tick(60);assert(w.count('teleToLobby')==0)
end)
check('replay transition suspends recovery for delayed arrivals',function()
    local w,s=fixture('Alt');w.started=true;w.tick(0);w.tick(4)
    w.command={id='epoch',at=5,phase='REPLAYING',reason='Replay'};w.tick(5);w.present[1]=false;w.present[2]=false;w.tick(25);w.tick(65)
    assert(w.count('teleToLobby')==0 and s.phase=='REPLAYING')
end)
check('unsynced Host departure allows slow replay teleport before fallback return',function()
    local w,_,c=fixture('Alt');c.SyncEnabled=false;w.complete=true;w.tick(0);w.tick(6)
    w.present[1]=false;w.tick(7);w.tick(27);assert(w.count('teleToLobby')==0)
    w.tick(37);assert(w.count('teleToLobby')==1)
end)
check('return command consumed once; teleport callbacks do not spam',function()
    local w,s=fixture('Alt');w.command={id='return-1',at=0,phase='PROGRESSION_RETURN',reason='New map'};w.tick(0);w.tick(1)
    assert(w.count('teleToLobby')==1);s.TeleportStarted();w.tick(20);assert(w.count('teleToLobby')==1)
    s.TeleportFailed();w.tick(21);assert(w.count('teleToLobby')==2);w.tick(22);assert(w.count('teleToLobby')==2)
end)
check('replay attempts bounded before controlled return',function()
    local w,s=fixture('Host');w.complete=true;w.tick(0);w.tick(6);w.tick(7);w.tick(10);w.tick(18);w.tick(30)
    assert(w.count('replayDungeon')==3 and w.count('teleToLobby')==1 and s.phase=='RECOVERING')
end)
check('old job/place/authority/expired epochs cannot eject new run',function()
    local c={version=2,id='a',reason='return',phase='RECOVERING',authorId=1,jobId='old',placeId=10,at=100,expiresAt=190}
    assert(Logic.validCommand(c,1,2,'old',10,110,false))
    assert(not Logic.validCommand(c,1,2,'new',10,110,false));assert(not Logic.validCommand(c,1,2,'old',20,110,false))
    assert(not Logic.validCommand(c,1,2,'old',10,191,false));c.authorId=3;assert(not Logic.validCommand(c,1,2,'old',10,110,true))
    c.authorId=2;assert(not Logic.validCommand(c,1,2,'old',10,110,false));assert(Logic.validCommand(c,1,2,'old',10,110,true))
end)
print(tests..' focused lifecycle checks passed')
