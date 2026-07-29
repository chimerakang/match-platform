package operations

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const ManifestVersion = 1

type ArtifactManifest struct {
	Path                string `json:"path"`
	SHA256              string `json:"sha256"`
	SBOMPath            string `json:"sbom_path"`
	SBOMSHA256          string `json:"sbom_sha256"`
	ProvenancePath      string `json:"provenance_path"`
	ProvenanceSHA256    string `json:"provenance_sha256"`
	VulnerabilityPath   string `json:"vulnerability_path"`
	VulnerabilitySHA256 string `json:"vulnerability_sha256"`
}

type ResourceLimits struct {
	CPUMillis        int   `json:"cpu_millis"`
	MemoryBytes      int64 `json:"memory_bytes"`
	MaxProcesses     int   `json:"max_processes"`
	MaxRequestBytes  int   `json:"max_request_bytes"`
	MaxResponseBytes int   `json:"max_response_bytes"`
	QueueCapacity    int   `json:"queue_capacity"`
}

type SandboxManifest struct {
	ReadOnlyRoot    bool              `json:"read_only_root"`
	Network         string            `json:"network"`
	NoNewPrivileges bool              `json:"no_new_privileges"`
	Capabilities    []string          `json:"capabilities"`
	WritablePaths   []string          `json:"writable_paths"`
	Environment     map[string]string `json:"environment"`
	Limits          ResourceLimits    `json:"limits"`
}

type Manifest struct {
	SchemaVersion   int              `json:"schema_version"`
	PackageID       string           `json:"package_id"`
	GameID          string           `json:"game_id"`
	AdapterVersion  string           `json:"adapter_version"`
	ContentVersions []string         `json:"content_versions"`
	ContentHashes   []string         `json:"content_hashes"`
	CodecIDs        []string         `json:"codec_ids"`
	RPCSchema       string           `json:"rpc_schema"`
	Artifact        ArtifactManifest `json:"artifact"`
	Sandbox         SandboxManifest  `json:"sandbox"`
	SignerID        string           `json:"signer_id"`
	Signature       string           `json:"signature,omitempty"`
}

type Policy struct {
	TrustedSigners  map[string]ed25519.PublicKey
	AllowedPackages map[string]bool
}

type VerifiedPackage struct {
	Manifest     Manifest
	Root         string
	ArtifactPath string
	Digest       string
}

func Sign(manifest Manifest, privateKey ed25519.PrivateKey) (Manifest, error) {
	manifest.Signature = ""
	canonical, err := canonicalManifest(manifest)
	if err != nil {
		return Manifest{}, err
	}
	manifest.Signature = base64.StdEncoding.EncodeToString(
		ed25519.Sign(privateKey, canonical))
	return manifest, nil
}

func Verify(root string, encoded []byte, policy Policy) (*VerifiedPackage, error) {
	var manifest Manifest
	decoder := json.NewDecoder(strings.NewReader(string(encoded)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return nil, fmt.Errorf("manifest is malformed: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("manifest has trailing content")
	}
	if err := validateIdentity(manifest, policy); err != nil {
		return nil, err
	}
	signature, err := base64.StdEncoding.DecodeString(manifest.Signature)
	if err != nil {
		return nil, fmt.Errorf("manifest signature is malformed")
	}
	unsigned := manifest
	unsigned.Signature = ""
	canonical, err := canonicalManifest(unsigned)
	if err != nil {
		return nil, err
	}
	if !ed25519.Verify(policy.TrustedSigners[manifest.SignerID], canonical, signature) {
		return nil, fmt.Errorf("manifest signature is not trusted")
	}
	artifactPath, artifact, err := verifyFile(root, manifest.Artifact.Path,
		manifest.Artifact.SHA256, true)
	if err != nil {
		return nil, fmt.Errorf("artifact: %w", err)
	}
	_, sbom, err := verifyFile(root, manifest.Artifact.SBOMPath,
		manifest.Artifact.SBOMSHA256, false)
	if err != nil {
		return nil, fmt.Errorf("SBOM: %w", err)
	}
	if err := verifySBOM(sbom, manifest.Artifact.SHA256); err != nil {
		return nil, err
	}
	_, provenance, err := verifyFile(root, manifest.Artifact.ProvenancePath,
		manifest.Artifact.ProvenanceSHA256, false)
	if err != nil {
		return nil, fmt.Errorf("provenance: %w", err)
	}
	if err := verifyProvenance(provenance, manifest.Artifact.SHA256); err != nil {
		return nil, err
	}
	_, vulnerabilities, err := verifyFile(root, manifest.Artifact.VulnerabilityPath,
		manifest.Artifact.VulnerabilitySHA256, false)
	if err != nil {
		return nil, fmt.Errorf("vulnerability report: %w", err)
	}
	if err := verifyVulnerabilities(vulnerabilities, manifest.Artifact.SHA256); err != nil {
		return nil, err
	}
	artifactSum := sha256.Sum256(artifact)
	return &VerifiedPackage{
		Manifest: manifest, Root: root, ArtifactPath: artifactPath,
		Digest: "sha256:" + hex.EncodeToString(artifactSum[:]),
	}, nil
}

func validateIdentity(manifest Manifest, policy Policy) error {
	if manifest.SchemaVersion != ManifestVersion {
		return fmt.Errorf("manifest schema version is unsupported")
	}
	if manifest.PackageID == "" || manifest.GameID == "" || manifest.AdapterVersion == "" ||
		manifest.RPCSchema != "hersir.adapter.rpc.v1" {
		return fmt.Errorf("manifest identity is incomplete")
	}
	if !policy.AllowedPackages[manifest.PackageID] {
		return fmt.Errorf("package is not on the operator allowlist")
	}
	if len(policy.TrustedSigners[manifest.SignerID]) != ed25519.PublicKeySize {
		return fmt.Errorf("manifest signer is not trusted")
	}
	if len(manifest.ContentVersions) == 0 || len(manifest.ContentHashes) == 0 ||
		len(manifest.CodecIDs) == 0 {
		return fmt.Errorf("manifest game compatibility is incomplete")
	}
	return validateSandbox(manifest.Sandbox)
}

func validateSandbox(value SandboxManifest) error {
	if !value.ReadOnlyRoot || value.Network != "loopback-only" || !value.NoNewPrivileges ||
		len(value.Capabilities) != 0 {
		return fmt.Errorf("sandbox must deny root writes, network, privileges and capabilities")
	}
	for _, path := range value.WritablePaths {
		if path != "/tmp" {
			return fmt.Errorf("sandbox writable path %q is not allowed", path)
		}
	}
	for name := range value.Environment {
		upper := strings.ToUpper(name)
		if strings.Contains(upper, "SECRET") || strings.Contains(upper, "TOKEN") ||
			strings.Contains(upper, "PASSWORD") || strings.Contains(upper, "PRIVATE") ||
			strings.Contains(upper, "CREDENTIAL") || strings.Contains(upper, "KEY") {
			return fmt.Errorf("sandbox environment %q may contain a secret", name)
		}
	}
	limits := value.Limits
	if limits.CPUMillis < 10 || limits.CPUMillis > 1000 ||
		limits.MemoryBytes < 16<<20 || limits.MaxProcesses < 1 ||
		limits.MaxProcesses > 64 || limits.MaxRequestBytes <= 0 ||
		limits.MaxResponseBytes <= 0 || limits.QueueCapacity < 0 {
		return fmt.Errorf("sandbox resource limits are incomplete or unsafe")
	}
	return nil
}

func verifyFile(root, name, expected string, executable bool) (string, []byte, error) {
	if name == "" || filepath.IsAbs(name) {
		return "", nil, fmt.Errorf("path must be relative")
	}
	cleanRoot, err := filepath.Abs(root)
	if err != nil {
		return "", nil, err
	}
	path := filepath.Join(cleanRoot, filepath.Clean(name))
	relative, err := filepath.Rel(cleanRoot, path)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", nil, fmt.Errorf("path escapes package root")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", nil, fmt.Errorf("file must be regular and not a symlink")
	}
	resolvedRoot, err := filepath.EvalSymlinks(cleanRoot)
	if err != nil {
		return "", nil, err
	}
	resolvedPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", nil, err
	}
	resolvedRelative, err := filepath.Rel(resolvedRoot, resolvedPath)
	if err != nil || resolvedRelative == ".." ||
		strings.HasPrefix(resolvedRelative, ".."+string(filepath.Separator)) {
		return "", nil, fmt.Errorf("resolved path escapes package root")
	}
	if executable && info.Mode().Perm()&0o111 == 0 {
		return "", nil, fmt.Errorf("artifact is not executable")
	}
	value, err := os.ReadFile(path)
	if err != nil {
		return "", nil, err
	}
	if digest(value) != expected {
		return "", nil, fmt.Errorf("digest mismatch")
	}
	return path, value, nil
}

func verifySBOM(encoded []byte, artifactDigest string) error {
	var value struct {
		SPDXVersion    string `json:"spdxVersion"`
		ArtifactSHA256 string `json:"artifact_sha256"`
	}
	if json.Unmarshal(encoded, &value) != nil || !strings.HasPrefix(value.SPDXVersion, "SPDX-") ||
		value.ArtifactSHA256 != artifactDigest {
		return fmt.Errorf("SBOM does not describe the verified artifact")
	}
	return nil
}

func verifyProvenance(encoded []byte, artifactDigest string) error {
	var value struct {
		PredicateType string `json:"predicate_type"`
		SubjectSHA256 string `json:"subject_sha256"`
		BuilderID     string `json:"builder_id"`
	}
	if json.Unmarshal(encoded, &value) != nil || value.PredicateType == "" ||
		value.BuilderID == "" || value.SubjectSHA256 != artifactDigest {
		return fmt.Errorf("provenance does not attest the verified artifact")
	}
	return nil
}

func verifyVulnerabilities(encoded []byte, artifactDigest string) error {
	var value struct {
		Status         string `json:"status"`
		ArtifactSHA256 string `json:"artifact_sha256"`
		Critical       int    `json:"critical"`
		High           int    `json:"high"`
	}
	if json.Unmarshal(encoded, &value) != nil || value.Status != "pass" ||
		value.ArtifactSHA256 != artifactDigest || value.Critical != 0 || value.High != 0 {
		return fmt.Errorf("vulnerability policy did not pass")
	}
	return nil
}

func canonicalManifest(value Manifest) ([]byte, error) {
	return json.Marshal(value)
}

func digest(value []byte) string {
	sum := sha256.Sum256(value)
	return "sha256:" + hex.EncodeToString(sum[:])
}
