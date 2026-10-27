package lxdev

import (
	"errors"
	"fmt"
	"maps"
	"net/http"
	"os"
	"os/exec"
	"slices"
	"sort"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

const (
	Version = "0.3.0"

	// containerID is the uid/gid of the box user inside the container. The
	// host user's uid/gid is mapped onto it, so shared folders get the right owner.
	containerID = 1001

	bootTimeout = 60 * time.Second

	folderDevicePrefix = "shared_folder_"
	portDevicePrefix   = "lxdev_port_"
)

// Shells that `lxdev exec` runs interactively on a PTY.
var Shells = []string{"bash", "zsh", "sh", "csh", "tcsh", "ash", "fish"}

// ErrNotCreated is returned when a command needs an existing container.
var ErrNotCreated = errors.New("container not created yet. Run lxdev up")

// Box is a dev container managed through the Incus/LXD API.
type Box struct {
	cfg     BoxConfig
	backend Backend
	socket  string
	client  incus.InstanceServer
}

// Open detects the backend, connects to it and checks that it is initialized.
func Open(cfg *Config) (*Box, error) {
	backend, socket, err := DetectBackend(cfg.Box.Backend)
	if err != nil {
		return nil, err
	}
	client, err := Connect(backend, socket)
	if err != nil {
		return nil, err
	}

	b := &Box{cfg: cfg.Box, backend: backend, socket: socket, client: client}
	if err := b.checkInitialized(); err != nil {
		return nil, err
	}
	return b, nil
}

// checkInitialized verifies that the default profile has a root disk and a
// network, which is what `incus admin init` / `lxd init` sets up.
func (b *Box) checkInitialized() error {
	profile, _, err := b.client.GetProfile("default")
	if err != nil {
		return fmt.Errorf("reading default profile: %w", err)
	}
	var hasRoot, hasNIC bool
	for _, dev := range profile.Devices {
		switch dev["type"] {
		case "disk":
			hasRoot = hasRoot || dev["path"] == "/"
		case "nic":
			hasNIC = true
		}
	}
	if !hasRoot || !hasNIC {
		return fmt.Errorf("%s is not initialized. Please run '%s' first", b.backend, b.backend.initCommand())
	}
	return nil
}

func (b *Box) instance() (*api.Instance, string, error) {
	inst, etag, err := b.client.GetInstance(b.cfg.Name)
	if api.StatusErrorCheck(err, http.StatusNotFound) {
		return nil, "", ErrNotCreated
	}
	return inst, etag, err
}

func (b *Box) ensureRunning() error {
	inst, _, err := b.instance()
	if err != nil {
		return err
	}
	if inst.StatusCode != api.Running {
		return fmt.Errorf("%s is not running", b.cfg.Name)
	}
	return nil
}

// ipAddress returns the container's first global IPv4 address, preferring eth0.
func (b *Box) ipAddress() (string, error) {
	state, _, err := b.client.GetInstanceState(b.cfg.Name)
	if err != nil {
		return "", err
	}

	names := slices.Sorted(maps.Keys(state.Network))
	slices.SortStableFunc(names, func(a, c string) int {
		switch {
		case a == "eth0":
			return -1
		case c == "eth0":
			return 1
		}
		return 0
	})
	for _, name := range names {
		if name == "lo" {
			continue
		}
		for _, addr := range state.Network[name].Addresses {
			if addr.Family == "inet" && addr.Scope == "global" {
				return addr.Address, nil
			}
		}
	}
	return "", nil
}

// Up creates (and provisions) the container, or starts it if it exists.
func (b *Box) Up() error {
	inst, _, err := b.instance()
	created := false
	switch {
	case errors.Is(err, ErrNotCreated):
		if err := b.create(); err != nil {
			return err
		}
		created = true
	case err != nil:
		return err
	case inst.StatusCode == api.Running:
		return fmt.Errorf("%s is already running", b.cfg.Name)
	default:
		if err := b.syncDevices(); err != nil {
			return err
		}
		fmt.Printf("Starting %s...\n", b.cfg.Name)
		if err := b.setState("start", false); err != nil {
			return err
		}
	}

	fmt.Println("Waiting for boot...")
	if err := b.waitForIP(); err != nil {
		return err
	}

	if created {
		fmt.Printf("Creating user %s...\n", b.cfg.User)
		if err := b.createUser(); err != nil {
			return err
		}
		// Folders are mounted after the user exists, so useradd creates a
		// proper home directory instead of finding a root-owned mount point.
		fmt.Println("Mapping folders...")
		if err := b.syncDevices(); err != nil {
			return err
		}
	}

	b.printPorts()

	if created {
		return b.Provision()
	}
	return nil
}

func (b *Box) create() error {
	if err := b.ensureIDMapAllowed(); err != nil {
		return err
	}

	ref, err := b.backend.imageSource(b.cfg.Image)
	if err != nil {
		return err
	}

	fmt.Printf("Launching %s from %s...\n", b.cfg.Name, b.cfg.Image)
	req := api.InstancesPost{
		Name: b.cfg.Name,
		Type: api.InstanceTypeContainer,
		Source: api.InstanceSource{
			Type:     "image",
			Mode:     "pull",
			Server:   ref.Server,
			Protocol: ref.Protocol,
			Alias:    ref.Alias,
		},
		InstancePut: api.InstancePut{
			Config: map[string]string{
				"raw.idmap":      fmt.Sprintf("uid %d %d\ngid %d %d", os.Getuid(), containerID, primaryGID(), containerID),
				"boot.autostart": "false",
			},
			Devices: b.portDevices(),
		},
	}
	op, err := b.client.CreateInstance(req)
	if err != nil {
		return err
	}
	if err := waitWithProgress(op); err != nil {
		return fmt.Errorf("creating %s: %w", b.cfg.Name, err)
	}

	return b.setState("start", false)
}

// ensureIDMapAllowed adds the subuid/subgid entries raw.idmap depends on,
// restarting the daemon and reconnecting if needed.
func (b *Box) ensureIDMapAllowed() error {
	changed, err := ensureSubIDs(os.Getuid(), primaryGID())
	if err != nil || !changed {
		return err
	}
	if err := restartService(b.backend); err != nil {
		return err
	}
	b.client.Disconnect()
	client, err := connectWait(b.backend, b.socket, 30*time.Second)
	if err != nil {
		return err
	}
	b.client = client
	return nil
}

// waitWithProgress waits for an operation, printing download/unpack progress.
func waitWithProgress(op incus.Operation) error {
	last := ""
	_, _ = op.AddHandler(func(o api.Operation) {
		for k, v := range o.Metadata {
			if s, ok := v.(string); ok && strings.HasSuffix(k, "_progress") && s != last {
				last = s
				fmt.Printf("\r\033[K  %s", s)
			}
		}
	})
	err := op.Wait()
	if last != "" {
		fmt.Print("\r\033[K")
	}
	return err
}

func (b *Box) setState(action string, force bool) error {
	op, err := b.client.UpdateInstanceState(b.cfg.Name, api.InstanceStatePut{
		Action:  action,
		Timeout: 30,
		Force:   force,
	}, "")
	if err != nil {
		return err
	}
	return op.Wait()
}

func (b *Box) waitForIP() error {
	deadline := time.Now().Add(bootTimeout)
	for time.Now().Before(deadline) {
		ip, err := b.ipAddress()
		if err != nil {
			return err
		}
		if ip != "" {
			return nil
		}
		time.Sleep(time.Second)
	}
	return errors.New("timeout waiting for the container to get an IPv4 address. " +
		"If it never does, check that the host firewall (ufw, firewalld, Docker's iptables rules) allows DHCP on the bridge, e.g.\n" +
		"  sudo ufw allow in on incusbr0 && sudo ufw route allow in on incusbr0 && sudo ufw route allow out on incusbr0")
}

func (b *Box) createUser() error {
	user := b.cfg.User
	home := "/home/" + user
	id := fmt.Sprint(containerID)

	for _, cmd := range [][]string{
		{"groupadd", "--gid", id, user},
		{"useradd", "--uid", id, "--gid", id, "-s", "/bin/bash", "-m", user},
	} {
		code, err := b.execCommand(cmd, os.Stdout, os.Stderr)
		if err != nil {
			return err
		}
		if code != 0 {
			return fmt.Errorf("%s failed with exit code %d", cmd[0], code)
		}
	}

	keys, err := sshPublicKeys()
	if err != nil {
		return err
	}

	files := []struct {
		path string
		args fileArgs
	}{
		{home + "/.ssh", fileArgs{Type: "directory", UID: containerID, GID: containerID, Mode: 0o700}},
		{home + "/.ssh/authorized_keys", fileArgs{Content: []byte(keys), UID: containerID, GID: containerID, Mode: 0o600}},
		{home + "/.hushlogin", fileArgs{UID: containerID, GID: containerID, Mode: 0o644}},
		{"/etc/sudoers", fileArgs{Content: []byte(user + " ALL=(ALL) NOPASSWD: ALL\n"), Mode: 0o440, Append: true}},
	}
	for _, f := range files {
		if err := pushFile(b.client, b.backend, b.cfg.Name, f.path, f.args); err != nil {
			return err
		}
	}
	return nil
}

func (b *Box) folderDevices() map[string]map[string]string {
	guests := make([]string, 0, len(b.cfg.Folders))
	byGuest := map[string]string{}
	for host, guest := range b.cfg.Folders {
		guests = append(guests, guest)
		byGuest[guest] = host
	}
	sort.Strings(guests)

	devices := map[string]map[string]string{}
	for i, guest := range guests {
		devices[fmt.Sprintf("%s%d", folderDevicePrefix, i+1)] = map[string]string{
			"type":   "disk",
			"source": byGuest[guest],
			"path":   guest,
		}
	}
	return devices
}

// portDevices forwards host ports to the container using proxy devices, so
// the daemon does the forwarding (including privileged ports) without redir or sudo.
func (b *Box) portDevices() map[string]map[string]string {
	devices := map[string]map[string]string{}
	for guest, host := range b.cfg.Ports {
		devices[fmt.Sprintf("%s%d", portDevicePrefix, guest)] = map[string]string{
			"type":    "proxy",
			"listen":  fmt.Sprintf("tcp:%s:%d", b.cfg.PortBind, host),
			"connect": fmt.Sprintf("tcp:127.0.0.1:%d", guest),
		}
	}
	return devices
}

// syncDevices makes the container's shared folders and forwarded ports match
// the config. Devices whose settings are unchanged are left alone, even if
// they were created with different names.
func (b *Box) syncDevices() error {
	inst, etag, err := b.instance()
	if err != nil {
		return err
	}

	desired := b.folderDevices()
	maps.Copy(desired, b.portDevices())

	current := map[string]map[string]string{}
	for name, dev := range inst.Devices {
		if strings.HasPrefix(name, folderDevicePrefix) || strings.HasPrefix(name, portDevicePrefix) {
			current[name] = dev
		}
	}
	if sameDevices(current, desired) {
		return nil
	}

	existing := map[string]bool{}
	put := inst.Writable()
	for name, dev := range current {
		existing[deviceKey(dev)] = true
		delete(put.Devices, name)
	}
	if put.Devices == nil {
		put.Devices = map[string]map[string]string{}
	}
	for name, dev := range desired {
		put.Devices[name] = dev
		if dev["type"] == "disk" && !existing[deviceKey(dev)] {
			fmt.Printf("Mounting %s in %s\n", dev["source"], dev["path"])
		}
	}

	op, err := b.client.UpdateInstance(b.cfg.Name, put, etag)
	if err != nil {
		return err
	}
	return op.Wait()
}

// sameDevices compares device sets by their settings, ignoring names.
func sameDevices(a, b map[string]map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	counts := map[string]int{}
	for _, d := range a {
		counts[deviceKey(d)]++
	}
	for _, d := range b {
		counts[deviceKey(d)]--
	}
	for _, n := range counts {
		if n != 0 {
			return false
		}
	}
	return true
}

// deviceKey serializes a device's settings for comparison.
func deviceKey(d map[string]string) string {
	var s strings.Builder
	for _, k := range slices.Sorted(maps.Keys(d)) {
		fmt.Fprintf(&s, "%s=%s;", k, d[k])
	}
	return s.String()
}

func (b *Box) printPorts() {
	guests := slices.Sorted(maps.Keys(b.cfg.Ports))
	for _, guest := range guests {
		fmt.Printf("Forwarding container port %d to %s:%d\n", guest, b.cfg.PortBind, b.cfg.Ports[guest])
	}
}

// Halt stops the container. Forwarded ports go away with it.
func (b *Box) Halt() error {
	if err := b.ensureRunning(); err != nil {
		return err
	}
	if err := b.setState("stop", false); err != nil {
		fmt.Println("Clean shutdown failed, forcing stop...")
		return b.setState("stop", true)
	}
	return nil
}

// Destroy stops (if needed) and deletes the container.
func (b *Box) Destroy() error {
	inst, _, err := b.instance()
	if err != nil {
		return err
	}
	if inst.StatusCode == api.Running {
		if err := b.setState("stop", true); err != nil {
			return err
		}
	}
	op, err := b.client.DeleteInstance(b.cfg.Name)
	if err != nil {
		return err
	}
	return op.Wait()
}

// SSH replaces the current process with an ssh session into the container.
func (b *Box) SSH(args []string) error {
	if err := b.ensureRunning(); err != nil {
		return err
	}
	ip, err := b.ipAddress()
	if err != nil {
		return err
	}
	if ip == "" {
		return fmt.Errorf("%s has no IP address", b.cfg.Name)
	}

	sshPath, err := exec.LookPath("ssh")
	if err != nil {
		return err
	}
	argv := []string{"ssh",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
		"-t", b.cfg.User + "@" + ip,
	}
	if len(args) > 0 {
		argv = append(argv, strings.Join(args, " "))
	}
	return syscall.Exec(sshPath, argv, os.Environ())
}

// Exec runs a command as root in the container and returns its exit code.
// Shells are run interactively, anything else through `sh -c`.
func (b *Box) Exec(args []string) (int, error) {
	if err := b.ensureRunning(); err != nil {
		return -1, err
	}
	if len(args) == 1 && slices.Contains(Shells, args[0]) {
		return b.execInteractive(args)
	}
	return b.execShell(strings.Join(args, " "))
}

// Provision runs the provisioning commands from the config, stopping at the first failure.
func (b *Box) Provision() error {
	if err := b.ensureRunning(); err != nil {
		return err
	}
	if len(b.cfg.Provisioning) == 0 {
		fmt.Println("Nothing to provision")
		return nil
	}
	if b.cfg.AutoSnapshots {
		if err := b.Snapshot(fmt.Sprintf("provision_%d", time.Now().Unix())); err != nil {
			return err
		}
	}

	fmt.Printf("Provisioning %s...\n", b.cfg.Name)
	for _, cmd := range b.cfg.Provisioning {
		fmt.Printf("==> %s\n", cmd)
		code, err := b.execShell(cmd)
		if err != nil {
			return err
		}
		if code != 0 {
			return fmt.Errorf("provisioning command failed with exit code %d: %s", code, cmd)
		}
	}
	return nil
}

// Status prints a summary of the container.
func (b *Box) Status() error {
	inst, _, err := b.instance()
	if err != nil {
		return err
	}
	ip, _ := b.ipAddress()
	snapshots, err := b.snapshots()
	if err != nil {
		return err
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintf(w, "Name\t%s\n", inst.Name)
	fmt.Fprintf(w, "Status\t%s\n", inst.Status)
	fmt.Fprintf(w, "IP\t%s\n", ip)
	fmt.Fprintf(w, "Image\t%s\n", b.cfg.Image)
	fmt.Fprintf(w, "Backend\t%s (%s)\n", b.backend, b.socket)

	names := slices.Sorted(maps.Keys(inst.Devices))
	for _, name := range names {
		dev := inst.Devices[name]
		switch dev["type"] {
		case "disk":
			if dev["source"] != "" {
				fmt.Fprintf(w, "%s\t%s => %s\n", name, dev["source"], dev["path"])
			}
		case "proxy":
			fmt.Fprintf(w, "Forwarded port\tguest: %s host: %s\n", dev["connect"], dev["listen"])
		}
	}

	if len(snapshots) > 0 {
		fmt.Fprintln(w, "Snapshots\t")
		for _, s := range snapshots {
			fmt.Fprintf(w, "  %s\t%s\n", snapshotName(s), s.CreatedAt.Local().Format(time.DateTime))
		}
	}
	return w.Flush()
}

// snapshots returns the container's snapshots, oldest first.
func (b *Box) snapshots() ([]api.InstanceSnapshot, error) {
	snaps, err := b.client.GetInstanceSnapshots(b.cfg.Name)
	if err != nil {
		return nil, err
	}
	slices.SortFunc(snaps, func(a, c api.InstanceSnapshot) int { return a.CreatedAt.Compare(c.CreatedAt) })
	return snaps, nil
}

// snapshotName strips the "instance/" prefix some API versions include.
func snapshotName(s api.InstanceSnapshot) string {
	if _, name, found := strings.Cut(s.Name, "/"); found {
		return name
	}
	return s.Name
}

// Snapshot creates a snapshot of the container.
func (b *Box) Snapshot(name string) error {
	if _, _, err := b.instance(); err != nil {
		return err
	}
	fmt.Printf("Creating snapshot %s\n", name)
	op, err := b.client.CreateInstanceSnapshot(b.cfg.Name, api.InstanceSnapshotsPost{Name: name})
	if err != nil {
		return err
	}
	return op.Wait()
}

// Restore restores the container to a snapshot.
func (b *Box) Restore(name string) error {
	if _, _, err := b.instance(); err != nil {
		return err
	}
	fmt.Printf("Restoring snapshot %s\n", name)
	op, err := b.client.UpdateInstance(b.cfg.Name, api.InstancePut{Restore: name}, "")
	if err != nil {
		return err
	}
	return op.Wait()
}

// RemoveSnapshot deletes a snapshot.
func (b *Box) RemoveSnapshot(name string) error {
	if _, _, err := b.instance(); err != nil {
		return err
	}
	fmt.Printf("Deleting snapshot %s\n", name)
	op, err := b.client.DeleteInstanceSnapshot(b.cfg.Name, name)
	if err != nil {
		return err
	}
	return op.Wait()
}

// Revert restores the most recent snapshot and then deletes it.
func (b *Box) Revert() error {
	snaps, err := b.snapshots()
	if err != nil {
		return err
	}
	if len(snaps) == 0 {
		return errors.New("no snapshots to revert to")
	}
	name := snapshotName(snaps[len(snaps)-1])
	if err := b.Restore(name); err != nil {
		return err
	}
	fmt.Printf("Reverted to snapshot %s\n", name)
	return b.RemoveSnapshot(name)
}
