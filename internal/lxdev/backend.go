package lxdev

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"gopkg.in/yaml.v3"
)

// Backend identifies which daemon we talk to. Incus and LXD share the same
// REST API, so a single client library works for both; the differences are
// socket locations, client config, service names and a few HTTP headers.
type Backend string

const (
	BackendIncus Backend = "incus"
	BackendLXD   Backend = "lxd"
)

func (b Backend) socketCandidates() []string {
	var paths []string
	switch b {
	case BackendIncus:
		if s := os.Getenv("INCUS_SOCKET"); s != "" {
			paths = append(paths, s)
		}
		if d := os.Getenv("INCUS_DIR"); d != "" {
			paths = append(paths, filepath.Join(d, "unix.socket"))
		}
		paths = append(paths, "/run/incus/unix.socket", "/var/lib/incus/unix.socket")
	case BackendLXD:
		if s := os.Getenv("LXD_SOCKET"); s != "" {
			paths = append(paths, s)
		}
		if d := os.Getenv("LXD_DIR"); d != "" {
			paths = append(paths, filepath.Join(d, "unix.socket"))
		}
		paths = append(paths, "/var/snap/lxd/common/lxd/unix.socket", "/var/lib/lxd/unix.socket")
	}
	return paths
}

func (b Backend) socketPath() string {
	for _, p := range b.socketCandidates() {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func (b Backend) adminGroup() string {
	if b == BackendIncus {
		return "incus-admin"
	}
	return "lxd"
}

func (b Backend) initCommand() string {
	if b == BackendIncus {
		return "incus admin init"
	}
	return "lxd init"
}

// headerPrefix is the prefix used for file transfer headers (X-Incus-uid vs X-LXD-uid).
func (b Backend) headerPrefix() string {
	if b == BackendIncus {
		return "X-Incus-"
	}
	return "X-LXD-"
}

// serviceNames lists systemd units that may run the daemon, in order of preference.
func (b Backend) serviceNames() []string {
	if b == BackendIncus {
		return []string{"incus.service"}
	}
	return []string{"snap.lxd.daemon.service", "lxd.service"}
}

// DetectBackend picks the backend from an explicit choice (config or
// LXDEV_BACKEND), or falls back to whichever daemon socket exists, preferring Incus.
func DetectBackend(preferred string) (Backend, string, error) {
	if env := os.Getenv("LXDEV_BACKEND"); env != "" {
		preferred = env
	}

	switch strings.ToLower(preferred) {
	case "incus":
		return detectOne(BackendIncus)
	case "lxd", "lxc":
		return detectOne(BackendLXD)
	case "":
		for _, b := range []Backend{BackendIncus, BackendLXD} {
			if p := b.socketPath(); p != "" {
				return b, p, nil
			}
		}
		return "", "", errors.New("found neither an Incus nor an LXD socket. Is Incus or LXD installed and running?")
	default:
		return "", "", fmt.Errorf("unknown backend %q (expected \"incus\" or \"lxd\")", preferred)
	}
}

func detectOne(b Backend) (Backend, string, error) {
	p := b.socketPath()
	if p == "" {
		return "", "", fmt.Errorf("no %s socket found (looked in %s)", b, strings.Join(b.socketCandidates(), ", "))
	}
	return b, p, nil
}

// Connect opens an API connection over the daemon's unix socket.
func Connect(b Backend, socket string) (incus.InstanceServer, error) {
	c, err := incus.ConnectIncusUnix(socket, &incus.ConnectionArgs{UserAgent: "lxdev/" + Version})
	if err != nil {
		if errors.Is(err, syscall.EACCES) || strings.Contains(err.Error(), "permission denied") {
			return nil, fmt.Errorf("permission denied on %s.\nAdd yourself to the '%s' group and log in again (or start a new login shell):\n  sudo usermod -a -G %s %s",
				socket, b.adminGroup(), b.adminGroup(), currentUsername())
		}
		return nil, fmt.Errorf("connecting to %s at %s: %w", b, socket, err)
	}
	return c, nil
}

// connectWait retries Connect until the daemon answers, e.g. after a restart.
func connectWait(b Backend, socket string, timeout time.Duration) (incus.InstanceServer, error) {
	deadline := time.Now().Add(timeout)
	for {
		c, err := Connect(b, socket)
		if err == nil || time.Now().After(deadline) {
			return c, err
		}
		time.Sleep(time.Second)
	}
}

// remote is an entry in the incus/lxc client config.yml.
type remote struct {
	Addr     string `yaml:"addr"`
	Protocol string `yaml:"protocol"`
	Public   bool   `yaml:"public"`
}

var defaultRemotes = map[Backend]map[string]remote{
	BackendIncus: {
		"images": {Addr: "https://images.linuxcontainers.org", Protocol: "simplestreams", Public: true},
	},
	BackendLXD: {
		"images": {Addr: "https://images.lxd.canonical.com", Protocol: "simplestreams", Public: true},
	},
}

// Ubuntu's cloud image servers work with both daemons and keep old configs
// using "ubuntu:<release>" working.
var ubuntuRemotes = map[string]remote{
	"ubuntu":               {Addr: "https://cloud-images.ubuntu.com/releases", Protocol: "simplestreams", Public: true},
	"ubuntu-daily":         {Addr: "https://cloud-images.ubuntu.com/daily", Protocol: "simplestreams", Public: true},
	"ubuntu-minimal":       {Addr: "https://cloud-images.ubuntu.com/minimal/releases", Protocol: "simplestreams", Public: true},
	"ubuntu-minimal-daily": {Addr: "https://cloud-images.ubuntu.com/minimal/daily", Protocol: "simplestreams", Public: true},
}

func (b Backend) clientConfigPaths() []string {
	home, _ := os.UserHomeDir()
	var paths []string
	switch b {
	case BackendIncus:
		if d := os.Getenv("INCUS_CONF"); d != "" {
			paths = append(paths, filepath.Join(d, "config.yml"))
		}
		paths = append(paths, filepath.Join(home, ".config", "incus", "config.yml"))
	case BackendLXD:
		if d := os.Getenv("LXD_CONF"); d != "" {
			paths = append(paths, filepath.Join(d, "config.yml"))
		}
		paths = append(paths,
			filepath.Join(home, "snap", "lxd", "common", "config", "config.yml"),
			filepath.Join(home, ".config", "lxc", "config.yml"))
	}
	return paths
}

// remotes returns the image remotes known to the backend's CLI, falling back
// to the built-in defaults.
func (b Backend) remotes() map[string]remote {
	all := map[string]remote{}
	for k, v := range ubuntuRemotes {
		all[k] = v
	}
	for k, v := range defaultRemotes[b] {
		all[k] = v
	}
	for _, p := range b.clientConfigPaths() {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var cfg struct {
			Remotes map[string]remote `yaml:"remotes"`
		}
		if yaml.Unmarshal(data, &cfg) == nil {
			for k, v := range cfg.Remotes {
				all[k] = v
			}
		}
		break
	}
	return all
}

// imageSource turns "remote:alias" (as in `incus launch images:debian/12`)
// into an API instance source. Images without a remote are looked up locally.
func (b Backend) imageSource(image string) (src imageRef, err error) {
	remoteName, alias, found := strings.Cut(image, ":")
	if !found {
		return imageRef{Alias: image}, nil
	}

	r, ok := b.remotes()[remoteName]
	if !ok {
		return src, fmt.Errorf("unknown image remote %q in %q", remoteName, image)
	}
	if strings.HasPrefix(r.Addr, "unix:") {
		return imageRef{Alias: alias}, nil
	}
	return imageRef{Server: r.Addr, Protocol: r.Protocol, Alias: alias}, nil
}

type imageRef struct {
	Server   string
	Protocol string
	Alias    string
}

// fileArgs describes a file or directory pushed into an instance.
type fileArgs struct {
	Content []byte
	UID     int
	GID     int
	Mode    os.FileMode
	Type    string // "file" or "directory"
	Append  bool
}

// pushFile writes a file into the instance through the files API. The incus
// client only sends X-Incus-* headers, which LXD ignores, so the request is
// built here with the right header prefix for the backend.
func pushFile(c incus.InstanceServer, b Backend, instance, path string, f fileArgs) error {
	u := fmt.Sprintf("http://unix.socket/1.0/instances/%s/files?path=%s", url.PathEscape(instance), url.QueryEscape(path))
	req, err := http.NewRequest(http.MethodPost, u, bytes.NewReader(f.Content))
	if err != nil {
		return err
	}

	p := b.headerPrefix()
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set(p+"uid", fmt.Sprint(f.UID))
	req.Header.Set(p+"gid", fmt.Sprint(f.GID))
	req.Header.Set(p+"mode", fmt.Sprintf("%04o", f.Mode.Perm()))
	if f.Type != "" {
		req.Header.Set(p+"type", f.Type)
	}
	if f.Append {
		req.Header.Set(p+"write", "append")
	}

	resp, err := c.DoHTTP(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		var apiErr struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(body, &apiErr) == nil && apiErr.Error != "" {
			return fmt.Errorf("writing %s: %s", path, apiErr.Error)
		}
		return fmt.Errorf("writing %s: %s", path, resp.Status)
	}
	return nil
}
