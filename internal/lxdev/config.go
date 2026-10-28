package lxdev

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// Config mirrors the lxdev.yml format used by the original Ruby version.
type Config struct {
	Box BoxConfig `yaml:"box"`
}

// BoxConfig describes the dev container.
type BoxConfig struct {
	Name          string            `yaml:"name"`
	User          string            `yaml:"user"`
	Image         string            `yaml:"image"`
	Backend       string            `yaml:"backend"` // "incus", "lxd" or empty for auto-detect
	Ports         map[int]int       `yaml:"ports"`   // guest port => host port
	PortBind      string            `yaml:"port_bind_address"`
	Folders       map[string]string `yaml:"folders"` // host path => guest path
	Provisioning  []string          `yaml:"provisioning"`
	AutoSnapshots bool              `yaml:"auto_snapshots"`
}

// LoadConfig reads and validates a config file. Relative folder sources are
// resolved against the directory containing the config file.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%s not found", path)
		}
		return nil, err
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}

	box := &cfg.Box
	switch {
	case box.Name == "":
		return nil, fmt.Errorf("%s: box.name is required", path)
	case box.User == "":
		return nil, fmt.Errorf("%s: box.user is required", path)
	case box.Image == "":
		return nil, fmt.Errorf("%s: box.image is required", path)
	}

	if box.PortBind == "" {
		box.PortBind = "0.0.0.0"
	}

	baseDir, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return nil, err
	}

	folders := make(map[string]string, len(box.Folders))
	for host, guest := range box.Folders {
		if !filepath.IsAbs(host) {
			host = filepath.Join(baseDir, host)
		}
		resolved, err := filepath.EvalSymlinks(host)
		if err != nil {
			return nil, fmt.Errorf("folder %s: %w", host, err)
		}
		folders[resolved] = guest
	}
	box.Folders = folders

	return &cfg, nil
}
