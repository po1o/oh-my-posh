//go:build linux || freebsd

package config

import (
	"os"
	"path/filepath"
	"syscall"

	"github.com/po1o/prompto/src/log"
	"golang.org/x/sys/unix"
)

// onConsoleDevice reports whether the controlling terminal is one of this
// platform's console devices.
//
// We ask for /dev/tty rather than inspect a standard stream: this runs during
// `prompto init`, whose stdout is the pipe feeding the shell's eval, so no
// stream is reliably the terminal. O_NONBLOCK keeps the open from waiting on
// carrier when the terminal is a serial line without CLOCAL, and O_NOCTTY
// keeps us from acquiring a controlling terminal by accident.
func onConsoleDevice() bool {
	tty, err := os.OpenFile("/dev/tty", os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
	if err != nil {
		log.Debugf("cannot open /dev/tty, assuming no console: %s", err)
		return false
	}

	defer tty.Close()

	device, ok := controllingTerminalDev(tty)
	if !ok {
		return false
	}

	return isConsoleDevice(device)
}

// isConsoleDevice reports whether device is the number of one of this
// platform's console devices.
//
// The devices are looked up on disk rather than hardcoded because their
// numbering is a kernel detail; what we can rely on is their names. The glob
// only has to be a superset — a name that matches but is not the terminal we
// were handed simply fails the number comparison.
func isConsoleDevice(device uint64) bool {
	devices, err := filepath.Glob(consoleDevGlob)
	if err != nil {
		// Glob only fails on a malformed pattern, which would be our bug.
		log.Debugf("bad console device pattern %s: %s", consoleDevGlob, err)
		return false
	}

	for _, name := range devices {
		var console unix.Stat_t
		if err := unix.Stat(name, &console); err != nil {
			continue
		}

		if console.Rdev == device {
			log.Debugf("controlling terminal is the console device %s", name)
			return true
		}
	}

	return false
}
