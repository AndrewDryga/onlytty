---
name: production-checks
description: checking production from outside after an apply — old responses, one real session, session lookups across instances, and how many runtimes answered
subsystem: release
sources: [portal/lib/onlytty_web/controllers/socket_controller.ex, portal/lib/onlytty/session_store.ex, portal/lib/onlytty/session.ex, portal/lib/onlytty/rate_limit.ex, portal/lib/onlytty_web/endpoint.ex, portal/config/config.exs, runner/e2e/e2e_test.go, infra/main.tf, infra/lb.tf, infra/variables.tf]
updated: 2026-11-17
---
**Is every instance on the new image?** A finished apply leaves no old instance
(`wait_for_instances_status` in `main.tf`), but an agent can't see Terraform Cloud, and while
the replace is rolling old instances still answer. So one passing request proves little. Load a
route the release changed a few dozen times, on separate connections, and expect no old
response.

**Does a session work?** `ONLYTTY_SERVER=https://onlytty.com go test -tags e2e -count=1 -v
./runner/e2e/` must print `--- PASS: TestEndToEnd`: one real encrypted session through the
relay, with pairing, take control, typed input echoed by `cat`, and exit. The test skips when
`GET /healthz` fails, and without `-v` a skip prints `ok`.

**Do the instances see each other's sessions?** A session process lives on the instance that
took `POST /api/sessions` and is registered under `:global`. `SessionStore.lookup/1` reads
`:global`, so `SocketController.viewer/2` upgrades `GET /ws/viewer/:id` (101) on any instance
clustered with the owner, and answers 404 `unknown session` on one that isn't. The backend
service has no session affinity (`lb.tf`), so each upgrade can land on any instance. Create one
session (`id` and `runner_token`, 16 to 128 URL-safe characters), upgrade it a dozen or so
times, and expect 101 every time. An id nobody created must get 404.
- Send a real WebSocket handshake and no `Origin` header. A plain GET for a live session raises
  `WebSockAdapter.UpgradeError`, which is a 500 and an error in the relay's log.
- Creates and upgrades are each limited to 30 per 60 s per client IP on each instance, and
  refused upgrades count. Pace the probe.
- A session with no runner is reaped after 120 s (`@unconnected_ms` in `Session`). Finish
  before that, or a 404 means the session is gone.

**How many runtimes answered?** The lookup probe means something only when more than one
instance answers. The count is the workspace's `instance_count`, which the repo doesn't show,
and the load balancer doesn't say which instance answered. `x-request-id` tells runtimes
apart. `Plug.RequestId.generate/0` ends it with `:erlang.unique_integer()`: the last 4 of its
15 bytes are a per-scheduler counter above the scheduler id. The id takes as many bits as it
takes to count the schedulers, dirty ones included: 4 on a 2-vCPU instance. Requests made one
after another show, for each scheduler id, a counter that only rises when one runtime answers
them, and counters that jump between two rising runs when two do. A single drop is also what a
restart or a replaced instance looks like. Static assets carry no id (`Plug.Static` answers
first), and an id the client sends is echoed, so send none.

## Changelog
- 2026-11-17 — created from the v0.4.18 rollout. One runtime answered all 98 requests sampled
  over six and a half minutes, so lookups across instances went untested, and with them cluster
  discovery after the hackney 4.10.2 and libcluster 3.6.0 bumps (checked against the sources,
  `request_id.ex` in plug 1.20.4, `upgrade_error.ex` in websock_adapter 0.7.2 and
  `erlang:unique_integer/0` on OTP 29.1.2).
