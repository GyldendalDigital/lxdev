package lxdev

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"golang.org/x/term"
)

// execCommand runs a command in the box with stdout/stderr attached and
// stdin closed, returning the command's exit code.
func (b *Box) execCommand(cmd []string, stdout, stderr io.Writer) (int, error) {
	req := api.InstanceExecPost{
		Command:   cmd,
		WaitForWS: true,
	}
	return b.runExec(req, &incus.InstanceExecArgs{Stdout: stdout, Stderr: stderr, DataDone: make(chan bool)})
}

// execShell runs `sh -c command` as root, streaming output to the terminal.
func (b *Box) execShell(command string) (int, error) {
	return b.execCommand([]string{"/bin/sh", "-c", command}, os.Stdout, os.Stderr)
}

// execInteractive runs a command on a PTY connected to the local terminal,
// like `incus exec <name> -- bash`.
func (b *Box) execInteractive(cmd []string) (int, error) {
	stdinFd := int(os.Stdin.Fd())
	if !term.IsTerminal(stdinFd) {
		return b.execCommand(cmd, os.Stdout, os.Stderr)
	}

	width, height, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil {
		width, height = 80, 24
	}

	oldState, err := term.MakeRaw(stdinFd)
	if err != nil {
		return -1, err
	}
	defer term.Restore(stdinFd, oldState)

	env := map[string]string{"TERM": "xterm"}
	if t := os.Getenv("TERM"); t != "" {
		env["TERM"] = t
	}

	req := api.InstanceExecPost{
		Command:     cmd,
		WaitForWS:   true,
		Interactive: true,
		Width:       width,
		Height:      height,
		Environment: env,
	}
	return b.runExec(req, &incus.InstanceExecArgs{
		Stdin:    os.Stdin,
		Stdout:   os.Stdout,
		Control:  forwardWindowResize,
		DataDone: make(chan bool),
	})
}

// forwardWindowResize sends local terminal size changes over the exec control socket.
func forwardWindowResize(conn *websocket.Conn) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGWINCH)
	defer signal.Stop(ch)

	for range ch {
		width, height, err := term.GetSize(int(os.Stdout.Fd()))
		if err != nil {
			continue
		}
		msg := api.InstanceExecControl{
			Command: "window-resize",
			Args:    map[string]string{"width": fmt.Sprint(width), "height": fmt.Sprint(height)},
		}
		if conn.WriteJSON(msg) != nil {
			return
		}
	}
}

func (b *Box) runExec(req api.InstanceExecPost, args *incus.InstanceExecArgs) (int, error) {
	op, err := b.client.ExecInstance(b.cfg.Name, req, args)
	if err != nil {
		return -1, err
	}
	if err := op.Wait(); err != nil {
		return -1, err
	}
	// Wait for all output to be flushed before returning.
	<-args.DataDone

	code, ok := op.Get().Metadata["return"].(float64)
	if !ok {
		return -1, fmt.Errorf("exec returned no exit code")
	}
	return int(code), nil
}
