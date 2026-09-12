package cli

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"github.com/po1o/prompto/src/log"
	"github.com/po1o/prompto/src/runtime/path"
)

func startDetachedDaemon() error {
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to get executable path: %w", err)
	}

	if lookPath, err := exec.LookPath("prompto"); err == nil {
		if resolved, err := filepath.EvalSymlinks(lookPath); err == nil && filepath.Clean(resolved) == filepath.Clean(executable) {
			executable = lookPath
		}
	}

	// The detached process runs "daemon serve"
	args := []string{"daemon", daemonSubcommandServe}
	if configFlag != "" {
		configFlag = path.ReplaceTildePrefixWithHomeDir(configFlag)
		if abs, err := filepath.Abs(configFlag); err == nil {
			configFlag = abs
		}
		args = append(args, "--config", configFlag)
	}

	cmd := exec.CommandContext(context.Background(), executable, args...)

	// Detach from parent process
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid: true,
	}
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start daemon: %w", err)
	}

	// Release the process so it continues after we exit
	if err := cmd.Process.Release(); err != nil {
		log.Error(err)
	}

	log.Debug("daemon started")

	return nil
}
