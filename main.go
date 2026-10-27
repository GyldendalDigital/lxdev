// Command lxdev is a lightweight, vagrant-like dev environment on top of Incus or LXD.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/GyldendalDigital/lxdev/internal/lxdev"
)

const usage = `Usage: lxdev [options] command

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

The backend (Incus or LXD) is auto-detected. Override it with "backend:" in
the config file or the LXDEV_BACKEND environment variable.
`

func main() {
	os.Exit(run())
}

func run() int {
	var configFile string
	var showVersion bool

	flags := flag.NewFlagSet("lxdev", flag.ContinueOnError)
	flags.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flags.StringVar(&configFile, "c", "lxdev.yml", "")
	flags.StringVar(&configFile, "config", "lxdev.yml", "")
	flags.BoolVar(&showVersion, "v", false, "")
	flags.BoolVar(&showVersion, "version", false, "")
	if err := flags.Parse(os.Args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 1
	}

	if showVersion {
		fmt.Printf("Version %s\n", lxdev.Version)
		return 0
	}

	args := flags.Args()
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "No arguments.\nRun \"lxdev --help\" for info")
		return 1
	}
	command, args := args[0], args[1:]

	if !knownCommands[command] {
		fmt.Fprintln(os.Stderr, "Unknown command.\nRun \"lxdev --help\" for info")
		return 1
	}

	cfg, err := lxdev.LoadConfig(configFile)
	if err != nil {
		return fail(err)
	}
	box, err := lxdev.Open(cfg)
	if err != nil {
		return fail(err)
	}

	switch command {
	case "up":
		err = box.Up()
	case "status":
		err = box.Status()
	case "ssh":
		err = box.SSH(args)
	case "halt":
		err = box.Halt()
	case "destroy":
		err = box.Destroy()
	case "provision":
		err = box.Provision()
	case "exec":
		if len(args) == 0 {
			return fail(errors.New("needs a command to run"))
		}
		code, err := box.Exec(args)
		if err != nil {
			return fail(err)
		}
		return code
	case "revert":
		err = box.Revert()
	case "snapshot", "restore", "rmsnapshot":
		if len(args) == 0 {
			return fail(errors.New("needs a snapshot name"))
		}
		switch command {
		case "snapshot":
			err = box.Snapshot(args[0])
		case "restore":
			err = box.Restore(args[0])
		case "rmsnapshot":
			err = box.RemoveSnapshot(args[0])
		}
	}

	if errors.Is(err, lxdev.ErrNotCreated) {
		fmt.Println("Container not created yet. Run lxdev up")
		return 0
	}
	if err != nil {
		return fail(err)
	}
	return 0
}

var knownCommands = map[string]bool{
	"up": true, "status": true, "ssh": true, "halt": true, "destroy": true, "provision": true,
	"exec": true, "snapshot": true, "rmsnapshot": true, "restore": true, "revert": true,
}

func fail(err error) int {
	fmt.Fprintf(os.Stderr, "Error: %s\n", err)
	return 1
}
