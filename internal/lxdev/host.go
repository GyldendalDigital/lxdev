package lxdev

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
)

func currentUsername() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return os.Getenv("USER")
}

// primaryGID returns the user's primary group from the passwd database. The
// process gid can differ, e.g. when run under `sg`.
func primaryGID() int {
	if u, err := user.Current(); err == nil {
		if gid, err := strconv.Atoi(u.Gid); err == nil {
			return gid
		}
	}
	return os.Getgid()
}

// sshPublicKeys returns the keys loaded in the ssh agent, falling back to
// ~/.ssh/*.pub when no agent is available.
func sshPublicKeys() (string, error) {
	// ssh-add -L exits non-zero when there is no agent or it holds no keys.
	if out, err := exec.Command("ssh-add", "-L").Output(); err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return string(out), nil
	}

	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, ".ssh", "*.pub"))
	var keys strings.Builder
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		keys.WriteString(strings.TrimSpace(string(data)))
		keys.WriteString("\n")
	}
	if keys.Len() == 0 {
		return "", fmt.Errorf("no ssh keys detected. Make sure you have an ssh key, either added to a running agent (ssh-add) or in ~/.ssh/*.pub")
	}
	return keys.String(), nil
}

// ensureSubIDs makes sure root may map the host uid/gid into containers,
// which raw.idmap needs. Returns true if the files changed and the daemon
// must be restarted.
func ensureSubIDs(uid, gid int) (bool, error) {
	changed := false
	for _, entry := range []struct {
		file string
		id   int
	}{{"/etc/subuid", uid}, {"/etc/subgid", gid}} {
		line := fmt.Sprintf("root:%d:1", entry.id)
		has, err := fileHasLine(entry.file, line)
		if err != nil {
			return false, err
		}
		if has {
			continue
		}
		fmt.Printf("Adding %s to %s (root privileges needed)\n", line, entry.file)
		cmd := exec.Command("sudo", "tee", "-a", entry.file)
		cmd.Stdin = strings.NewReader(line + "\n")
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return false, fmt.Errorf("updating %s: %w", entry.file, err)
		}
		changed = true
	}
	return changed, nil
}

func fileHasLine(path, line string) (bool, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	for s.Scan() {
		if strings.TrimSpace(s.Text()) == line {
			return true, nil
		}
	}
	return false, s.Err()
}

func restartService(b Backend) error {
	for _, svc := range b.serviceNames() {
		if exec.Command("systemctl", "status", svc).Run() != nil {
			continue
		}
		fmt.Printf("Restarting %s (root privileges needed)\n", svc)
		cmd := exec.Command("sudo", "systemctl", "restart", svc)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		return cmd.Run()
	}
	return fmt.Errorf("the %s service needs to be restarted, but the service name cannot be detected. Please restart it manually", b)
}
