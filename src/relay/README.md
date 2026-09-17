# Private party relay

This Worker supports the hub's optional cross-client script readiness and host
regroup messages. No Roblox login, cookies, or game passwords are needed.

Use Cloudflare **Workers Free**, without upgrading billing. The
[Free limits](https://developers.cloudflare.com/durable-objects/platform/pricing/)
include 100,000 Durable Object requests/day; Workers has its own matching daily
request allowance. Each enabled client polls every 10 seconds (8,640 requests/day).
Ten accounts leave a little headroom; larger groups running continuously need a
longer polling/expiry design or a separate capacity decision.

## Deploy your own

From this directory, using Node.js and npm:

```sh
npm ci
npx wrangler login
npx wrangler deploy
npx wrangler secret put RELAY_TOKEN
```

For `RELAY_TOKEN`, supply a randomly generated private value of at least 32
characters. Keep it out of source control. The Worker returns 503 until this
secret is configured. Enter its `https://…workers.dev` URL (without `/sync`) and
that key into every account's Cross-client sync settings, then enable sync on all
of them. Keep the same host, carry, and selected alts across accounts. Alt order
and username versus numeric-ID input do not change the room after resolution.

`GET /health` returns only a public protocol health check. `POST /sync` requires
`Authorization: Bearer <key>` and validates the heartbeat. Only the configured
host ID can publish a regroup, scoped to its current dungeon job. Everyone holding
the shared key is trusted; IDs are client-reported and not independently verified
by Roblox. Rotating the secret requires updating every account.

Readiness lives in memory and expires after 35 seconds; eviction causes a safe
wait for fresh reports. Regroup messages survive object eviction in storage and
expire after three minutes. No timers keep the object awake. No account profiles,
credentials, or arbitrary commands/code are exchanged. Relay outages pause synced
starts/farming; host automatic regroup waits for acknowledgment. Disabling sync or
the manual Return to lobby action remains available in the hub.

## Local verification

Create an ignored `.dev.vars` file containing `RELAY_TOKEN=<test key>` and run
`npm run dev`. `npm test` checks heartbeat expiry, regroup authority, old-job scope,
and eviction. The production client requires HTTPS; local HTTP is for relay tests.
