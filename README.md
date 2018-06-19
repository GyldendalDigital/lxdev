# LxDev
###### Automagic dev environment using LXD

## TODO
* Automatic creation of sudoers file
* YAML config with container name, forwarded ports, mapped folders etc
* Create user within container
* Insertion of developer's ssh key in container
* Some support for automatic provisioning
* Keep it lightweight and simple

## Architectural decisions
* Simple commandline based interface like vagrant
* Use existing tools as far as possible (ssh-add -L for keys, redir for port forwarding, and of course LXD)
* Use lxc commands with --format=json for ease of processing

## Nice to have
* Take advantage of snapshots if possible
* Support for distros other than Ubuntu

