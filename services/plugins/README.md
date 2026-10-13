# Tradera runtime plugins

The node has three layers:

| Layer | Ownership |
| --- | --- |
| Fixed foundation | `internal/kernel`, `internal/routing`, `internal/plugins`: capability wiring, routing, native loading, lifecycle, host maintenance, signing and shared identity. `internal/app` bootstraps these mechanisms. |
| Adapters | `plugins/adapters/<category>` owns `ports`, lifecycle wrappers in `runtime`, provider modules and their `entry/main.go`. Provider-specific models/configuration remain inside the provider. `base` and `cfg` are adapter support libraries. |
| Actions | `plugins/actions/<namespace>`: service logic, action controllers, consumer-owned ports/bridge facades, DTOs, owned models/schemas, configuration and workers. `entry/main.go` exports the native factory. |

`internal/app` composes the host, loads binaries and binds the protocol gateway. It imports shared contracts and the protocol gateway, and loads namespace/provider implementations through native factories. Each namespace's `NewPlugin` constructs and wires its own service. Existing action names and request bodies remain available. LLM implementations register in `llm`; the `admin` and `bots` namespaces own delegated aliases for their existing provider-management/catalog endpoints.

All business records and descriptors belong to actions: accounts/sessions to `auth`, spaces/rooms/memberships/invitations/files/proxies to `spaces`, bots to `bots`, wallets/ledger to `finance`, nodes to `federation`, and follows to `users`. Routine, post, market, usage and LLM records remain with their namespaces. Shared action persistence helpers live in `plugins/actions/support`. Each namespace registers its own schemas; `plugins/testutil` assembles them only for test fixtures. Unloading retains stored records and known schemas.

No agent prompts, tools, execution loops or skills implementation live under `internal`. VMM port contracts and provider wrappers live under `plugins/adapters/vmm`; the agent engine (the deep agents runtime and its Go adapter) lives under `plugins/adapters/vmm/deepagents`. Namespace-specific configuration types live with their owner; `plugins/config` composes the node manifest using those contracts.

Federation owns its peer gateway, allocation/discovery, node bootstrap, remote transport and model registration. Its native plugin optionally provides an identity preflight hook. Host bootstrap discovers that hook through the generic plugin contract; standalone identity provisioning remains available when no plugin provides one. Federation route bindings follow network provider changes and are removed on unload. Business initialization uses optional plugin bootstrap hooks rather than host-owned business code.

## Build and bootstrap

From `services`:

```sh
make build
./bin/traderad -config configs/config.yml
```

This builds the daemon, CLI and individual native `.so` files using CGO and `-trimpath`. Adapter binaries are under `bin/plugins/adapters`; namespace binaries are under `bin/plugins/actions`. Bootstrap loads enabled configured adapters and namespaces; namespace startup registers its owned schemas. With no explicit action-plugin list, the existing platform namespaces load by default. `actions.enabled` can select a subset; a nonempty `plugins.actions` list supplies the explicit action-plugin inventory.

```yaml
plugins:
  directory: bin/plugins
  source_root: .
  adapters:
    - name: memory
      enabled: true
  actions:
    - name: auth-ns
      enabled: true
    - name: users-ns
      enabled: true
    # Include the other namespaces required by this node.
    - name: greeter-ns
      source: bin/plugins/actions/greeter-ns.so
      enabled: true
```

`source` is a `.so` path, relative to `source_root` or absolute. An omitted source resolves to `<directory>/<layer>/<plugin-name>.so`. `directory` is relative to the daemon's working directory; `source_root` identifies the matching Go module for runtime builds. Environment overrides are `TRADERA_PLUGIN_DIRECTORY` and `TRADERA_PLUGIN_SOURCE_ROOT`.

## Runtime administration

Log in as the configured node administrator, then:

```sh
./bin/tradera plugins
./bin/tradera plugins-build source=plugins/adapters/example
./bin/tradera plugins-load path=/path/returned/by/build.so
./bin/tradera plugins-build source=plugins/actions/greeter
./bin/tradera plugins-load path=/path/returned/by/build.so
./bin/tradera call greeter.hello name=Ada
./bin/tradera plugins-stop name=greeter-ns
./bin/tradera plugins-load name=greeter-ns
./bin/tradera plugins-unload name=greeter-ns
```

The sample adapter provides `example/greeting`; the greeter namespace consumes a small interface resolved through the bridge. Neither imports the other's implementation. Adapter configuration can set `prefix` when loading, for example:

```sh
./bin/tradera call _node.plugins_load --json '{"path":"/path/example.so","config":{"prefix":"Welcome"}}'
```

To update implementation code, edit its namespace/provider source, build a new revision, then:

```sh
./bin/tradera plugins-replace name=greeter-ns path=/path/new-revision.so
./bin/tradera plugins-active category=database plugin=postgres
```

`plugins-build` copies the module into a unique package path under the hidden `plugins/.builds` staging directory before compiling it; updated namespace DTOs cross the bridge using compatible JSON representations. Replacement validates the binary first, drains the old instance, starts the new one, and restores the previous instance if initialization fails. Config updates use `call _node.plugins_update` with `name` and `config`. Adapter updates drain operations, reinitialize their provider configuration, restart bindings, and restore the previous configuration on failure. Namespace configuration overlays use the same section names as global configuration, for example `{"sandbox":{"backend":"docker"}}`.

The CLI's `_node` operations are fixed-host maintenance commands, authenticated and signature-verified by the same gateway. They remain available with existing administrator sessions after unloading `auth-ns` or `admin-ns`. The administrator action namespace retains its existing `admin.plugins_*` endpoints. Previously validated administrator sessions can use host control for up to five minutes while the database is disconnected (bounded by their original expiry); ordinary action authentication still requires the database. This allows the CLI to restore a stopped database adapter. A disconnected network cannot receive commands, so select a replacement protocol provider before unloading the old one remotely.

## Bridge and lifetime

Plugins receive `api.Dependencies`: the kernel interfaces, plugin configuration, global configuration and logger. Request identity, execution attribution, cancellation and budgets travel through `context.Context`. Consumers own narrow interfaces and resolve services on each call through `bridge.Invoke`. `repo.New` uses the database category bridge so existing repositories follow active-provider changes. Sibling DTO/model contracts may be imported where useful; sibling service implementations must not be imported.

`module.Instance` publishes its service, actions, schemas and worker lifecycle. Start registers schemas, actions and optional plugin-owned route bindings. Bootstrap invokes optional namespace initialization hooks after all plugins start. Stop rejects new calls, removes routes, cancels the namespace lifetime and drains requests/workers. Room turns remain durable when callers disconnect; unloading cancels local execution, and agent threads stay checkpointed in the agent runtime. Repository operations resolve the current database; transactions remain bound to their selected provider. Provider guards cancel and drain operations before close. Database selection registers all known schemas on the target provider; it does not transfer records between databases. Network selection binds the common gateway and switches the supervised listener.

## Native Go constraints

Go plugins require a supported operating system, CGO, and the same Go toolchain, build flags and shared dependency sources as the host. Changes to the shared core/bridge/support libraries require a matching host rebuild. Namespace/provider implementation updates use the versioned builder. Native Go has no close/unmap API: unload removes routes, bindings and live execution, while loaded code stays mapped until process exit. See [Go's plugin documentation](https://pkg.go.dev/plugin).

The container retains the matching toolchain and source tree so administrator builds work inside the node. Plugins execute inside the node process and therefore have the same operating-system privileges as the daemon.

## Verification

```sh
go test ./...
go test -race ./internal/kernel ./internal/plugins/... ./plugins/actions/...
make plugins
TRADERA_NATIVE_TEST=1 go test -v ./internal/plugins/host
```

The native test runs a separate compatible host, boots platform namespaces, exercises stop/restart/unload, loads the example adapter and greeter, replaces both using independently compiled revisions, rejects an incompatible replacement, restores a provider after failed initialization, and replaces the database while preserving registered schemas. It also checks the agent tool bridge, maintenance access with auth/admin/database providers stopped, federation route unload/reload, and listener restart after configuration updates.

Runtime inventory and configuration changes apply to the running process. Update the node configuration to retain the selected plugin inventory and settings after a daemon restart.
