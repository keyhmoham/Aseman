# Workload identity (SPIFFE / SPIRE)

Optional. Every call the agent runtime makes to the node's agent gateway is
authorized by the turn's token; with SPIRE it also carries a JWT-SVID that
proves which workload made it, so a token copied out of a turn is not enough.

```bash
docker compose --profile spire up -d spire-server spire-oidc spire-agent spiffe-helper
```

Register the agent runtime with the server (once):

```bash
docker compose exec spire-server /opt/spire/bin/spire-server token generate -spiffeID spiffe://aseman.internal/node/agent
```

```bash
docker compose exec spire-server /opt/spire/bin/spire-server entry create -parentID spiffe://aseman.internal/node/agent -spiffeID spiffe://aseman.internal/agent-runtime -selector docker:label:aseman.workload:agent-runtime
```

Give the agent runtime `ASEMAN_SVID_FILE=/run/spire/svid/jwt_svid.token` and
the `spire-svid` volume. Then, in Admin → Enterprise → Workload identity, set
the trust domain `aseman.internal`, the bundle address
`http://spire-oidc:8008/keys` (the JWT keys), the audience `aseman`, and turn on
"Require workload identity" once calls carry SVIDs.
