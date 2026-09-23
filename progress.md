# Party lifecycle reliability — 2026-09-23

Implementation is in dungeonquestrewrite, per the user's explicit repository clarification.
The autotest checkout and its remotes were not changed.

## Root causes and changes

- Every unsynced Carry/Alt made its own end-of-run selection; absent difficulty data
  was enough to make `sameDungeon` false and trigger a needless return. Host now
  owns progression, requires a proven higher eligible requirement (or completed
  healer provisioning), and otherwise replays. Followers consume the same decision.
- Replay invoked `PlaceManager.IsDungeonOwner`, which the current client does not
  export. Replay now uses the existing owner resolver and the inspected game UI
  payload, including `isHardcore` and dungeon/boss ValueBase fields. Server owner
  validation is retained. Three bounded attempts lead to controlled recovery.
- Completion events missed on reload were not recovered from `completeGui`.
  Completion is now latched before request handling; a previously-running job can
  never become joinable merely because `HasDungeonStarted()` turns false.
- Join handling accepted requests with only a false started flag. Acceptance now
  requires PRE_START, selected membership, compatible owner, and no completion,
  failure, return, or teleport. Other requests are declined at bounded intervals.
  Senders require fresh Host PRE_START evidence, excluding their old dungeon job;
  otherwise they use inspected actual lobby queue/global listing interfaces.
- `canRun` mixed player presence with `sync.Ready` for both starts and combat.
  AutoStartRole, SyncEnabled, and RequireScriptsReady are now separate. Readiness
  gates starts only. An unavailable transport has an explicit presence-only policy.
- OCD previously armed from `started` alone and kept missing timers across phase
  changes. Now only a fully observed stable party arms recovery. Transitions reset
  its grace; Host is the authority, with Carry takeover only on Host absence.
- Transition IDs include authority, job, place, dungeon, phase, and fixed expiry.
  Both relays carry this context; repeated IDs cannot renew expiry or supersede a
  newer epoch. Same-job reloads preserve pending attempts; old jobs cannot eject new runs.
- Profiles now override stale account/snapshot automation settings on teleport as
  well as fresh execution. Runtime observations stay account-specific. Profile
  AutoStartRole works with sync on or off; manual enabled state continues on teleport.
- Checkpoint height tolerance was 60 studs, empty target lists stopped progression,
  adaptive ranking could still prefer blocked targets, and restarting movement
  reset checkpoint history. Navigation now keeps floor/progress constraints,
  prioritizes visible targets, advances cleared rooms, refreshes streamed anchors,
  and runs an objective/health watchdog. Combat no longer independently teleports
  a stalled solo account to the lobby. Existing dodge limits and facing are unchanged.
- Added opt-in BoostManager. The real gold shop supports x2 Gold/+1 Item/VIP and
  XP 1h/2h/4h. Purchases are ordered, gold-only, affordable, and rate limited; server
  offers/ownership are reread. Saved data never substitutes for daily server state.

## Inspected current client interfaces (read-only MCP)

Connected client: VanguardAttacker, lobby place 77649408247578.

- ReplicatedStorage.Utility.PlaceManager: `HasDungeonStarted` reads workspace flags
  and returns true when dungeonStarted is absent in a level. Both `IsDungeonOwner`
  and `GetDungeonOwnerId` were confirmed nil in the connected client.
- ReplayDungeonButton.Replay.LocalScript: owner from teleport.ownerId;
  `replayDungeon:FireServer(data)`, workspace fields, dungeon/boss values, isHardcore.
- PlayerScripts.remoteGuiHandler: loadCompleteGui clones completeGui.
- PlayerScripts.JoinRequestLobbyClient: `sendJoinRequest(username, force)`; automatic
  requests use false, never the manual force-join path.
- Ui.queue.gameSearch and lobbyInfo: workspace.games.inLobby; replicated Roster
  records n/l; whitelist and minLevelReq; `joinDungeon(hostName)`,
  `listGlobalParties(dungeon)`, `joinGlobalParty(jobId, ownerName)`.
- Ui.shop: `getGoldGamepassPrice(key)`, `requestGoldGamepassPurchase(key)`, ownership
  BoolValues goldGamepass/extraItemGamepass/vip; `getGoldXPBoostPrice(productId)` and
  `requestGoldXPBoostPurchase(productId, currency)`. XP product IDs were read from
  the live shop rows and matched 1/2/4-hour labels. Gold balance is leaderstats.Gold.
- Read-only price probes at level 201: permanent offers cost 56,000,000,000 gold
  each; XP offers were 112,500,000,000 / 206,253,000,000 / 472,500,000,000 gold,
  with remaining=1, limit=1, nextAvailableIn=0. These prices are not hardcoded.

No live purchases, premium prompts, dungeon starts, or teleports were performed.

## Verification and remaining live coverage

Focused fixtures run the real RoleController/HubLogic against small game fakes:
unchanged replay, progression authority, join guards, post-start flag regression,
readiness/combat separation, initial loading delays, continuous disconnect grace,
transition consumption, bounded retries, and stale job/place/authority/expiry.
Profiles/boost tests exercise all three profiles on fresh execute and teleport,
priority, affordability, server allowance, retries, and non-gold rejection.
Navigation fixtures exercise folded-floor checkpoints and streamed forward routes.
Relay tests cover both existing transports plus version-2 authority/expiry/ordering.

A–R are covered by focused policy/coordinator/profile checks where possible, not
by an actual multi-account session. S has navigation fixtures and code inspection;
Northern Lands geometry/doors/stairs/boss route still needs a live dungeon traversal.
T/U have policy checks and live read-only offer inspection, not actual purchases.
Only one client in a lobby was available. A full Carry + Host + multiple Alt run,
replay teleport timing, global lobby membership, disconnect/rejoin, and actual
purchase-result replication still require live integration. Existing HTTP relay
services must restart/redeploy this updated code; no deployment was performed.

Final local verification: `lua build.lua` generated both bundles; Luau compilation
passed for all source modules and both runtime bundles. All 17 focused lifecycle
checks, profile/boost checks, navigation fixtures, and 3 relay tests passed.
`git diff --check` passed. These are implementation checks, not a pre-commit gate.


## Follow-up screenshot fix

The screenshot showed a Carry account displaying `Party ready; start delay 147 / 3s`.
Only Host owns the start action, so that counter was misleading on Carry/Alt and
made auto-farm appear stuck. Carry/Alt now immediately show `Waiting for Host to
start`; the delay counter is Host-only and its displayed elapsed value is capped at
the configured delay.
