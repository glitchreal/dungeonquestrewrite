-- Exercise actual checkpoint policy against folded-floor and streaming regressions.
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local vector={}
vector.__index=function(v,k) if k=='Magnitude' then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end;return vector[k] end
local function V(x,y,z) return setmetatable({X=x,Y=y,Z=z},vector) end
vector.__sub=function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
vector.__add=function(a,b) return V(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
local checkpoints={}
local dungeon={QueryDescendants=function() return checkpoints end}
local function checkpoint(roomName,x,y)
    local room={Name=roomName,Parent=dungeon}
    local p={Name='checkpoint',Parent=room,Position=V(x,y,0),GetFullName=function() return 'dungeon.'..roomName..'.checkpoint' end}
    checkpoints[#checkpoints+1]=p;return p
end
checkpoint('room1',0,0);checkpoint('room2',100,0);checkpoint('bossRoom',200,0)
local world={FindFirstChild=function(_,name) if name=='dungeon' then return dungeon end end}
local state={routeAnchors={},routeAnchorIndex=1,kills=0}
local source=read('src/CombatController.luau')
local route=source:match('(local hasBlockingRay.-)\nlocal function isValidTarget')
local globals=setmetatable({state=state,Workspace=world,Vector3={new=V},ROUTE_GUIDED_DUNGEONS={['Northern Lands']={reach=12,height=10,watchdog=12}},
    dungeonName=function() return 'Northern Lands' end},{__index=_G})
local getGoal,refresh=assert(load(route..'\nhasBlockingRay=function() return false end\nreturn mapRouteGoal,refreshRouteAnchors','route','t',globals))()
local root={Position=V(0,50,0),Parent={}}
local _,anchor=getGoal(root);assert(anchor.name=='room1','Different floor must not skip room checkpoint')
root.Position=V(0,3,0);_,anchor=getGoal(root);assert(anchor.name=='room2')
root.Position=V(100,3,0);_,anchor=getGoal(root);assert(anchor.name=='bossRoom')
checkpoint('room3',150,0);refresh(true);_,anchor=getGoal(root)
assert(anchor.name=='room3','Streaming refresh must include new forward checkpoint without backtracking')
print('PASS checkpoint floor tolerance, forward advancement, streaming refresh without backtracking')
