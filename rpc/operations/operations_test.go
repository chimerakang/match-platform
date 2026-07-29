package operations

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSignedImmutablePackageAndDefaultDenyLaunchPlan(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root, encoded := packageFixture(t, privateKey, "counter-adapter", "1.0.0", "one")
	value, err := Verify(root, encoded, Policy{
		TrustedSigners:  map[string]ed25519.PublicKey{"release": publicKey},
		AllowedPackages: map[string]bool{"counter-adapter": true},
	})
	if err != nil {
		t.Fatal(err)
	}
	plan := value.LaunchPlan()
	if err := plan.Validate(); err != nil {
		t.Fatal(err)
	}
	processSpec, err := plan.ProcessSpec("/usr/local/bin/hersir-sandbox-launcher",
		"/var/lib/hersir/plans/counter.json")
	if err != nil {
		t.Fatal(err)
	}
	if !processSpec.Sandboxed || processSpec.InheritEnvironment ||
		processSpec.Command != "/usr/local/bin/hersir-sandbox-launcher" {
		t.Fatalf("unsafe process spec: %+v", processSpec)
	}
	planJSON, err := plan.JSON()
	if err != nil {
		t.Fatal(err)
	}
	text := string(planJSON)
	for _, required := range []string{
		`"read_only_root": true`, `"network_namespace": "loopback-only"`,
		`"no_new_privileges": true`, `"capabilities": []`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("launch plan missing %s:\n%s", required, text)
		}
	}
	for name := range plan.Environment {
		if strings.Contains(strings.ToLower(name), "secret") {
			t.Fatal("launch plan environment contains a secret")
		}
	}
}

func TestVerificationRejectsTamperingSupplyChainAndUnsafeSandbox(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	policy := Policy{
		TrustedSigners:  map[string]ed25519.PublicKey{"release": publicKey},
		AllowedPackages: map[string]bool{"counter-adapter": true},
	}
	t.Run("artifact tamper", func(t *testing.T) {
		root, encoded := packageFixture(t, privateKey, "counter-adapter", "1", "tamper")
		if err := os.WriteFile(filepath.Join(root, "adapter"), []byte("changed"), 0o755); err != nil {
			t.Fatal(err)
		}
		if _, err := Verify(root, encoded, policy); err == nil ||
			!strings.Contains(err.Error(), "digest mismatch") {
			t.Fatalf("tampered artifact accepted: %v", err)
		}
	})
	t.Run("untrusted signer", func(t *testing.T) {
		root, encoded := packageFixture(t, privateKey, "counter-adapter", "1", "signer")
		if _, err := Verify(root, encoded, Policy{
			TrustedSigners:  map[string]ed25519.PublicKey{},
			AllowedPackages: map[string]bool{"counter-adapter": true},
		}); err == nil {
			t.Fatal("unknown signer was accepted")
		}
	})
	t.Run("not allowlisted", func(t *testing.T) {
		root, encoded := packageFixture(t, privateKey, "counter-adapter", "1", "allowlist")
		if _, err := Verify(root, encoded, Policy{
			TrustedSigners:  map[string]ed25519.PublicKey{"release": publicKey},
			AllowedPackages: map[string]bool{},
		}); err == nil {
			t.Fatal("package outside the operator allowlist was accepted")
		}
	})
	t.Run("unsafe environment", func(t *testing.T) {
		root, encoded := packageFixture(t, privateKey, "counter-adapter", "1", "env")
		var manifest Manifest
		if err := json.Unmarshal(encoded, &manifest); err != nil {
			t.Fatal(err)
		}
		manifest.Sandbox.Environment["GAME_SECRET_TOKEN"] = "leak"
		manifest, err = Sign(manifest, privateKey)
		if err != nil {
			t.Fatal(err)
		}
		encoded, _ = json.Marshal(manifest)
		if _, err := Verify(root, encoded, policy); err == nil ||
			!strings.Contains(err.Error(), "secret") {
			t.Fatalf("unsafe environment accepted: %v", err)
		}
	})
	t.Run("failed vulnerability scan", func(t *testing.T) {
		root, encoded := packageFixture(t, privateKey, "counter-adapter", "1", "vuln")
		var manifest Manifest
		if err := json.Unmarshal(encoded, &manifest); err != nil {
			t.Fatal(err)
		}
		report := []byte(fmt.Sprintf(
			`{"status":"fail","artifact_sha256":%q,"critical":1,"high":0}`,
			manifest.Artifact.SHA256))
		if err := os.WriteFile(filepath.Join(root, "vulnerabilities.json"), report, 0o600); err != nil {
			t.Fatal(err)
		}
		manifest.Artifact.VulnerabilitySHA256 = digest(report)
		manifest, err = Sign(manifest, privateKey)
		if err != nil {
			t.Fatal(err)
		}
		encoded, _ = json.Marshal(manifest)
		if _, err := Verify(root, encoded, policy); err == nil ||
			!strings.Contains(err.Error(), "vulnerability") {
			t.Fatalf("failed scan accepted: %v", err)
		}
	})
}

func TestCanaryDrainPromotionAndRollbackPreserveMatchPins(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	policy := Policy{
		TrustedSigners:  map[string]ed25519.PublicKey{"release": publicKey},
		AllowedPackages: map[string]bool{"counter-adapter": true},
	}
	rootOne, encodedOne := packageFixture(
		t, privateKey, "counter-adapter", "1.0.0", "one")
	one, err := Verify(rootOne, encodedOne, policy)
	if err != nil {
		t.Fatal(err)
	}
	rootTwo, encodedTwo := packageFixture(
		t, privateKey, "counter-adapter", "2.0.0", "two")
	two, err := Verify(rootTwo, encodedTwo, policy)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(278, 0)
	registry := NewRegistry(func() time.Time { return now })
	if err := registry.Install(one); err != nil {
		t.Fatal(err)
	}
	if err := registry.Install(two); err != nil {
		t.Fatal(err)
	}
	if err := registry.Activate("counter-reference", one.Digest, 100); err != nil {
		t.Fatal(err)
	}
	if err := registry.Activate("counter-reference", two.Digest, 50); err != nil {
		t.Fatal(err)
	}
	stableMatch, canaryMatch := matchesForBuckets(t, 50)
	stable, err := registry.Resolve("counter-reference", stableMatch)
	if err != nil || stable.Digest != one.Digest {
		t.Fatalf("stable selection = %v, %v", stable, err)
	}
	canary, err := registry.Resolve("counter-reference", canaryMatch)
	if err != nil || canary.Digest != two.Digest {
		t.Fatalf("canary selection = %v, %v", canary, err)
	}
	if err := registry.Drain("counter-reference", two.Digest); err != nil {
		t.Fatal(err)
	}
	pinned, _ := registry.Resolve("counter-reference", canaryMatch)
	if pinned.Digest != two.Digest {
		t.Fatal("drain moved an existing match to another package")
	}
	newAfterDrain, _ := registry.Resolve("counter-reference", canaryMatch+"-new")
	if newAfterDrain.Digest != one.Digest {
		t.Fatal("draining package accepted a new match")
	}
	if err := registry.Rollback("counter-reference"); err != nil {
		t.Fatal(err)
	}
	pinned, _ = registry.Resolve("counter-reference", canaryMatch)
	if pinned.Digest != two.Digest {
		t.Fatal("canary rollback changed an existing match identity")
	}

	if err := registry.Activate("counter-reference", two.Digest, 25); err != nil {
		t.Fatal(err)
	}
	if err := registry.Promote("counter-reference"); err != nil {
		t.Fatal(err)
	}
	afterPromote, _ := registry.Resolve("counter-reference", "promoted-new")
	if afterPromote.Digest != two.Digest {
		t.Fatal("promotion did not select the candidate for new matches")
	}
	if err := registry.Rollback("counter-reference"); err != nil {
		t.Fatal(err)
	}
	afterRollback, _ := registry.Resolve("counter-reference", "rollback-new")
	if afterRollback.Digest != one.Digest {
		t.Fatal("rollback did not restore the previous package")
	}
	pinned, _ = registry.Resolve("counter-reference", "promoted-new")
	if pinned.Digest != two.Digest {
		t.Fatal("rollback moved an existing promoted match")
	}
	audit := registry.Audit()
	if len(audit) < 8 {
		t.Fatalf("rollout audit is incomplete: %+v", audit)
	}
	auditJSON, _ := json.Marshal(audit)
	if strings.Contains(string(auditJSON), `"payload"`) ||
		!strings.Contains(string(auditJSON), `"action":"rollback"`) {
		t.Fatalf("audit leaked payload or omitted rollback: %s", auditJSON)
	}
}

func TestCrashAndResourceTelemetryArePackageIsolatedAndAudited(t *testing.T) {
	registry := NewRegistry(func() time.Time { return time.Unix(278, 0) })
	registry.Observe("digest-a", PackageTelemetry{
		Starts: 3, Crashes: 2, ResourceExhaustions: 7, HealthFailures: 1,
	})
	if registry.Telemetry("digest-a").Crashes != 2 {
		t.Fatal("package crash telemetry was not recorded")
	}
	if registry.Telemetry("digest-b") != (PackageTelemetry{}) {
		t.Fatal("one package polluted another telemetry partition")
	}
}

func packageFixture(
	t *testing.T,
	privateKey ed25519.PrivateKey,
	packageID, version, artifactSuffix string,
) (string, []byte) {
	t.Helper()
	root := t.TempDir()
	artifact := []byte("#!/bin/sh\n# " + artifactSuffix + "\n")
	artifactDigest := digest(artifact)
	sbom := []byte(fmt.Sprintf(
		`{"spdxVersion":"SPDX-2.3","artifact_sha256":%q}`, artifactDigest))
	provenance := []byte(fmt.Sprintf(
		`{"predicate_type":"https://slsa.dev/provenance/v1",`+
			`"subject_sha256":%q,"builder_id":"ci://hersir"}`, artifactDigest))
	vulnerabilities := []byte(fmt.Sprintf(
		`{"status":"pass","artifact_sha256":%q,"critical":0,"high":0}`,
		artifactDigest))
	files := []struct {
		name string
		data []byte
		mode os.FileMode
	}{
		{"adapter", artifact, 0o755},
		{"sbom.spdx.json", sbom, 0o600},
		{"provenance.json", provenance, 0o600},
		{"vulnerabilities.json", vulnerabilities, 0o600},
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(root, file.name), file.data, file.mode); err != nil {
			t.Fatal(err)
		}
	}
	manifest := Manifest{
		SchemaVersion: ManifestVersion, PackageID: packageID,
		GameID: "counter-reference", AdapterVersion: version,
		ContentVersions: []string{"counter-rules.1"}, ContentHashes: []string{"content"},
		CodecIDs: []string{"counter.json.v1"}, RPCSchema: "hersir.adapter.rpc.v1",
		Artifact: ArtifactManifest{
			Path: "adapter", SHA256: artifactDigest,
			SBOMPath: "sbom.spdx.json", SBOMSHA256: digest(sbom),
			ProvenancePath: "provenance.json", ProvenanceSHA256: digest(provenance),
			VulnerabilityPath:   "vulnerabilities.json",
			VulnerabilitySHA256: digest(vulnerabilities),
		},
		Sandbox: SandboxManifest{
			ReadOnlyRoot: true, Network: "loopback-only", NoNewPrivileges: true,
			Capabilities: []string{}, WritablePaths: []string{"/tmp"},
			Environment: map[string]string{"GAME_LOG_LEVEL": "info"},
			Limits: ResourceLimits{
				CPUMillis: 500, MemoryBytes: 128 << 20, MaxProcesses: 8,
				MaxRequestBytes: 1 << 20, MaxResponseBytes: 16 << 20,
				QueueCapacity: 32,
			},
		},
		SignerID: "release",
	}
	manifest, err := Sign(manifest, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return root, encoded
}

func matchesForBuckets(t *testing.T, threshold int) (string, string) {
	t.Helper()
	stable, canary := "", ""
	for index := 0; index < 10000 && (stable == "" || canary == ""); index++ {
		matchID := fmt.Sprintf("match-%d", index)
		if bucket("counter-reference", matchID) < threshold {
			canary = matchID
		} else {
			stable = matchID
		}
	}
	if stable == "" || canary == "" {
		t.Fatal("could not find deterministic rollout buckets")
	}
	return stable, canary
}
