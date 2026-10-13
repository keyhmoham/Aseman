// Command traderad runs a tradera federation node: it boots the kernel,
// loads the configured adapters and namespaces as plugins, registers the
// database models and serves the action API over the active network adapter.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/tradera/tradera/internal/app"
	"github.com/tradera/tradera/plugins/config"
)

func main() {
	var (
		configPath = flag.String("config", envOr("TRADERA_CONFIG", "configs/config.yml"), "path to the config file (env TRADERA_CONFIG)")
		central    = flag.Bool("central", false, "override: mark this node as the central node")
		nodeID     = flag.String("node-id", "", "override: this node's 16-hex id")
		adminPass  = flag.String("admin-password", os.Getenv("TRADERA_ADMIN_PASSWORD"), "bootstrap an admin account with this password (env TRADERA_ADMIN_PASSWORD)")
	)
	flag.Parse()

	cfg, err := dconfig.Load(*configPath)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "config %s not found; run with an existing config file\n", *configPath)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "load config: %v\n", err)
		os.Exit(1)
	}
	cfg.Defaults()

	env := map[string]string{}
	if *central {
		env["central"] = "true"
		cfg.Node.Central = true
	}
	if *nodeID != "" {
		cfg.Node.ID = *nodeID
	}
	if *adminPass != "" {
		env["admin_password"] = *adminPass
		env["admin_handle"] = cfg.Node.Name
	}

	// The sandbox size from the config/environment is where the admin's Machine
	// settings start from (settings.Machine reads these).
	env["sandbox_cpu"] = strconv.FormatFloat(cfg.Sandbox.CPU, 'f', -1, 64)
	env["sandbox_memory_mb"] = strconv.FormatInt(cfg.Sandbox.MemoryMB, 10)
	env["sandbox_disk_mb"] = strconv.FormatInt(cfg.Sandbox.DiskMB, 10)

	application, err := app.New(cfg, env)
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot: %v\n", err)
		os.Exit(1)
	}

	if err := application.Bootstrap(context.Background()); err != nil {
		application.Log.Error("bootstrap failed", "error", err)
		_ = application.Shutdown(context.Background())
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		application.Log.Info("shutting down")
		_ = application.Shutdown(context.Background())
	}()

	application.Log.Info("tradera node serving",
		"node", application.K.NodeID().String(),
		"central", application.K.Env()["central"] == "true")
	if err := application.Serve(ctx); err != nil {
		application.Log.Error("serve failed", "error", err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
