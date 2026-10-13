package dconfig

import "testing"

func TestSandboxResourcesCanBeConfiguredWithoutInvalidEnvironmentOverrides(t *testing.T) {
	c := &Config{}
	c.Defaults()
	if c.Sandbox.CPU != 2 || c.Sandbox.MemoryMB != 2048 || c.Sandbox.DiskMB != 4096 {
		t.Fatalf("%+v", c.Sandbox)
	}
	t.Setenv(EnvSandboxCPU, "1.5")
	t.Setenv(EnvSandboxMemoryMB, "3072")
	t.Setenv(EnvSandboxDiskMB, "8192")
	c.ApplyEnv()
	if c.Sandbox.CPU != 1.5 || c.Sandbox.MemoryMB != 3072 || c.Sandbox.DiskMB != 8192 {
		t.Fatalf("%+v", c.Sandbox)
	}
	t.Setenv(EnvSandboxCPU, "NaN")
	t.Setenv(EnvSandboxMemoryMB, "-1")
	c.ApplyEnv()
	if c.Sandbox.CPU != 1.5 || c.Sandbox.MemoryMB != 3072 {
		t.Fatalf("invalid override %+v", c.Sandbox)
	}
}
