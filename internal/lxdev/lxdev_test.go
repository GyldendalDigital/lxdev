package lxdev

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSameDevicesIgnoresNames(t *testing.T) {
	a := map[string]map[string]string{
		"shared_folder_1": {"type": "disk", "source": "/a", "path": "/x"},
		"shared_folder_2": {"type": "disk", "source": "/b", "path": "/y"},
	}
	b := map[string]map[string]string{
		"shared_folder_1": {"type": "disk", "source": "/b", "path": "/y"},
		"shared_folder_2": {"type": "disk", "source": "/a", "path": "/x"},
	}
	if !sameDevices(a, b) {
		t.Fatal("expected renamed but identical devices to be equal")
	}

	b["shared_folder_2"]["path"] = "/z"
	if sameDevices(a, b) {
		t.Fatal("expected changed device to differ")
	}
}

func TestImageSource(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	tests := []struct {
		backend Backend
		image   string
		want    imageRef
	}{
		{BackendIncus, "images:debian/12", imageRef{Server: "https://images.linuxcontainers.org", Protocol: "simplestreams", Alias: "debian/12"}},
		{BackendLXD, "images:debian/12", imageRef{Server: "https://images.lxd.canonical.com", Protocol: "simplestreams", Alias: "debian/12"}},
		{BackendIncus, "ubuntu:noble", imageRef{Server: "https://cloud-images.ubuntu.com/releases", Protocol: "simplestreams", Alias: "noble"}},
		{BackendIncus, "my-local-image", imageRef{Alias: "my-local-image"}},
	}
	for _, tt := range tests {
		got, err := tt.backend.imageSource(tt.image)
		if err != nil {
			t.Fatalf("%s %s: %v", tt.backend, tt.image, err)
		}
		if got != tt.want {
			t.Errorf("%s %s: got %+v, want %+v", tt.backend, tt.image, got, tt.want)
		}
	}

	if _, err := BackendIncus.imageSource("nope:foo"); err == nil {
		t.Error("expected error for unknown remote")
	}
}

func TestImageSourceReadsClientConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".config", "incus")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := "remotes:\n  mirror:\n    addr: https://mirror.example.com\n    protocol: simplestreams\n    public: true\n"
	if err := os.WriteFile(filepath.Join(dir, "config.yml"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := BackendIncus.imageSource("mirror:alpine/3.20")
	if err != nil {
		t.Fatal(err)
	}
	if got.Server != "https://mirror.example.com" || got.Alias != "alpine/3.20" {
		t.Errorf("got %+v", got)
	}
}

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lxdev.yml")
	yml := `box:
  name: huba
  user: huba
  image: images:ubuntu/24.04
  ports:
    80: 9999
  folders:
    ".": "/home/huba/lxdev"
  provisioning:
    - apt-get update
`
	if err := os.WriteFile(path, []byte(yml), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	resolved, _ := filepath.EvalSymlinks(dir)
	if cfg.Box.Folders[resolved] != "/home/huba/lxdev" {
		t.Errorf("folders not resolved relative to config: %v", cfg.Box.Folders)
	}
	if cfg.Box.Ports[80] != 9999 || cfg.Box.PortBind != "0.0.0.0" {
		t.Errorf("unexpected ports: %v bind %s", cfg.Box.Ports, cfg.Box.PortBind)
	}
}
