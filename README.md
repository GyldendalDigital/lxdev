[![Gem Version](https://badge.fury.io/rb/lxdev.svg)](https://badge.fury.io/rb/lxdev)

# LxDev
###### Automagic dev environment using LXD

## TODO
* ~~Automatic creation of sudoers file~~
* ~~YAML config with container name, forwarded ports, mapped folders etc~~
* ~~Create user within container~~
* ~~Insertion of developer's ssh key in container~~
* ~~Some support for automatic provisioning~~
* ~~'status' command~~
* ~~Create a gem~~

## Architectural decisions
* Simple commandline based interface like vagrant
* Use existing tools as far as possible (ssh-add -L for keys, redir for port forwarding, and of course LXD)
* Use lxc commands with --format=json for ease of processing

## Nice to have
* Take advantage of snapshots if possible
* Support for distros other than Ubuntu

## Building gem
```
gem build lxdev.gemspec
gem install lxdev-0.1.0.gem
```

## Config examples

### Fedora 27 with provisioned ssh server
```
box:
  name: fedorawithssh
  user: huba
  image: images:fedora/27
  folders:
    ".": "/home/huba/lxdev"
  provisioning:
    - dnf install -y openssh-server
    - systemctl enable sshd.service
    - systemctl start sshd.service
```

### "Vagrant clone" Ubuntu 16.04 with puppet manifest
```
box:
  name: huba
  user: vagrant
  image: ubuntu:xenial
  ports:
    3000: 3000
  folders:
    ".": "/home/vagrant/lxdev"
  provisioning:
    - dpkg -l | grep -q puppet || (apt-get update && apt-get install -y puppet)
    - mkdir -p /tmp/vagrant-puppet && rsync -rtv /home/vagrant/lxdev/manifests /tmp/vagrant-puppet/
    - puppet apply /tmp/vagrant-puppet/manifests/lxdev.pp
```

