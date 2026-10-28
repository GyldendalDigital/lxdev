# LxDev
###### Automagic dev environment using Incus or LXD

A lightweight, vagrant-like dev environment: describe a container in `lxdev.yml`,
run `lxdev up`, and get a container with your user, your ssh keys, your project
folder mounted with the right ownership, forwarded ports and provisioning.

Works with both [Incus](https://linuxcontainers.org/incus/) and
[LXD](https://canonical.com/lxd). It talks to the daemon through its REST API
over the local unix socket, so neither the `incus` nor the `lxc` CLI is needed.

## Install

```
go install github.com/GyldendalDigital/lxdev@latest
```

Or build from a checkout with `go build`.

## Requirements

* Incus or LXD installed and initialized (`incus admin init` / `lxd init`)
* Your user in the `incus-admin` (Incus) or `lxd` (LXD) group
* An ssh key, either in a running agent (`ssh-add -L`) or in `~/.ssh/*.pub`
* `ssh` for `lxdev ssh`

On the first `lxdev up`, lxdev adds `root:<uid>:1` to `/etc/subuid` and
`root:<gid>:1` to `/etc/subgid` if needed, and restarts the daemon (using
`sudo`). This allows the host user to be mapped into the container
(`raw.idmap`), so files in shared folders are owned by you on both sides.

If the container never gets an IPv4 address, the host firewall is probably
blocking DHCP on the bridge. With ufw:

```
sudo ufw allow in on incusbr0
sudo ufw route allow in on incusbr0
sudo ufw route allow out on incusbr0
```

(Use `lxdbr0` for LXD.)

## Usage

```
Usage: lxdev [options] command

Options:
  -c, --config FILE   Specify config file, defaults to lxdev.yml
  -h, --help          Prints this help
  -v, --version       Prints the version

Commands:
  up          Bring container up
  status      Show status of the container
  ssh         Log into the container
  halt        Stop the container
  destroy     Destroy the container
  provision   Run provisioning commands from YAML file
  exec        Run command as root in container
  snapshot    Snapshots the container. Takes a snapshot name as parameter.
  rmsnapshot  Deletes a snapshot. Takes a snapshot name as parameter.
  restore     Restore container to a snapshot with a previous state. Takes a snapshot name as parameter.
  revert      Restore container to the last snapshot taken.
```

`lxdev exec bash` (or any other shell) opens an interactive root shell; any
other command is run with `sh -c` and its exit code is passed on.

## Backend selection

lxdev looks for an Incus socket first, then an LXD socket. To choose
explicitly, set `backend: incus` or `backend: lxd` in the config, or the
`LXDEV_BACKEND` environment variable. The usual `INCUS_SOCKET`/`INCUS_DIR`
and `LXD_DIR` variables are respected.

Image remotes (`images:`, `ubuntu:` and so on) are read from the backend's
client config (`~/.config/incus/config.yml`, or for LXD
`~/snap/lxd/common/config/config.yml` / `~/.config/lxc/config.yml`), with
built-in defaults for `images:` and the `ubuntu*:` remotes. An image without a
remote prefix refers to a local image alias.

## Config

```
box:
  name: huba                  # container name
  user: huba                  # user created in the container (uid/gid 1001)
  image: images:ubuntu/24.04  # remote:alias, as in `incus launch`
  backend: incus              # optional: incus or lxd, auto-detected by default
  ports:                      # guest port: host port
    80: 9999
  port_bind_address: 0.0.0.0  # optional: host address to listen on (default 0.0.0.0)
  folders:                    # host path: guest path (relative to the config file)
    ".": "/home/huba/lxdev"
  auto_snapshots: true        # optional: snapshot before each provisioning run
  provisioning:               # run as root with sh -c, stops at the first failure
    - apt-get update
    - apt-get -y install nginx
```

Ports are forwarded with `proxy` devices on the container, so forwarding is
done by the daemon, also for ports below 1024, and lasts as long as the
container runs. Changes to `ports` and `folders` are applied on the next
`lxdev up` of a stopped container.

### Fedora with provisioned ssh server
```
box:
  name: fedorawithssh
  user: huba
  image: images:fedora/42
  folders:
    ".": "/home/huba/lxdev"
  provisioning:
    - dnf install -y openssh-server
    - systemctl enable --now sshd.service
```

### "Vagrant clone" Ubuntu with puppet manifest
```
box:
  name: huba
  user: vagrant
  image: images:ubuntu/24.04
  ports:
    3000: 3000
  folders:
    ".": "/home/vagrant/lxdev"
  provisioning:
    - dpkg -l | grep -q puppet || (apt-get update && apt-get install -y puppet)
    - mkdir -p /tmp/vagrant-puppet && rsync -rtv /home/vagrant/lxdev/manifests /tmp/vagrant-puppet/
    - puppet apply /tmp/vagrant-puppet/manifests/lxdev.pp
```

## Upgrading from the Ruby version

* The config format is unchanged, apart from the new optional keys above.
* Port forwarding no longer uses `redir` and no longer needs `sudo` for
  privileged ports. The `.lxdev/` state directory is no longer used and can be
  deleted.
* Existing containers keep working. Forwarded ports are added as proxy devices
  on the next `lxdev up` of a stopped container.
* Provisioning now stops at the first failing command.
* `ubuntu:` images still work, but `images:` is the remote that both Incus and
  LXD ship with by default.
