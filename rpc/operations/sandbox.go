package operations

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"

	rpcruntime "github.com/chimerakang/hersir/rpc/runtime"
)

// LaunchPlan is consumed by the trusted OCI/container launcher. It contains no
// client-selected executable, endpoint or secret.
type LaunchPlan struct {
	PackageID   string            `json:"package_id"`
	Digest      string            `json:"digest"`
	Artifact    string            `json:"artifact"`
	Environment map[string]string `json:"environment"`
	Sandbox     SandboxProfile    `json:"sandbox"`
}

type SandboxProfile struct {
	ReadOnlyRoot         bool           `json:"read_only_root"`
	NetworkNamespace     string         `json:"network_namespace"`
	NoNewPrivileges      bool           `json:"no_new_privileges"`
	Capabilities         []string       `json:"capabilities"`
	WritableTmpfs        []string       `json:"writable_tmpfs"`
	ReadOnlyIdentityPath string         `json:"read_only_identity_path"`
	MaskedPaths          []string       `json:"masked_paths"`
	Limits               ResourceLimits `json:"limits"`
}

func (p *VerifiedPackage) LaunchPlan() LaunchPlan {
	environment := make(map[string]string, len(p.Manifest.Sandbox.Environment))
	for key, value := range p.Manifest.Sandbox.Environment {
		environment[key] = value
	}
	writable := append([]string(nil), p.Manifest.Sandbox.WritablePaths...)
	sort.Strings(writable)
	return LaunchPlan{
		PackageID: p.Manifest.PackageID, Digest: p.Digest,
		Artifact: p.ArtifactPath, Environment: environment,
		Sandbox: SandboxProfile{
			ReadOnlyRoot: true, NetworkNamespace: "loopback-only",
			NoNewPrivileges: true, Capabilities: []string{},
			WritableTmpfs: writable, ReadOnlyIdentityPath: "/run/hersir-tls",
			MaskedPaths: []string{
				"/proc/acpi", "/proc/keys", "/proc/kcore", "/proc/timer_list",
				"/sys/firmware", "/sys/fs/cgroup", "/run/secrets",
			},
			Limits: p.Manifest.Sandbox.Limits,
		},
	}
}

func (p LaunchPlan) Validate() error {
	if p.PackageID == "" || p.Digest == "" || p.Artifact == "" {
		return fmt.Errorf("launch plan identity is incomplete")
	}
	if !p.Sandbox.ReadOnlyRoot || p.Sandbox.NetworkNamespace != "loopback-only" ||
		!p.Sandbox.NoNewPrivileges || len(p.Sandbox.Capabilities) != 0 {
		return fmt.Errorf("launch plan is not default-deny")
	}
	return validateSandbox(SandboxManifest{
		ReadOnlyRoot: true, Network: "loopback-only", NoNewPrivileges: true,
		Capabilities: p.Sandbox.Capabilities, WritablePaths: p.Sandbox.WritableTmpfs,
		Environment: p.Environment, Limits: p.Sandbox.Limits,
	})
}

func (p LaunchPlan) JSON() ([]byte, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	return json.MarshalIndent(p, "", "  ")
}

// ProcessSpec binds a verified plan to a trusted launcher. The adapter artifact
// is data passed to that launcher; ProcessRuntime never executes it directly in
// production.
func (p LaunchPlan) ProcessSpec(launcher, materializedPlan string) (rpcruntime.ProcessSpec, error) {
	if err := p.Validate(); err != nil {
		return rpcruntime.ProcessSpec{}, err
	}
	if !filepath.IsAbs(launcher) || !filepath.IsAbs(materializedPlan) {
		return rpcruntime.ProcessSpec{}, fmt.Errorf("sandbox launcher and plan paths must be absolute")
	}
	return rpcruntime.ProcessSpec{
		Command: launcher, Args: []string{"--plan", materializedPlan},
		Sandboxed: true, InheritEnvironment: false,
	}, nil
}
