//go:build freebsd

package config

import (
	"os"

	"github.com/po1o/prompto/src/log"
	"golang.org/x/sys/unix"
)

// consoleTerms are the TERM values that identify a text console. A virtual
// console's TERM comes from the static /etc/ttys shipped with the release, not
// from the console driver: releases up to 8.x assigned "cons25", and 9.0
// onwards assign "xterm", which is why the device check below exists. These
// values are kept for those older releases and because they are what survives
// an SSH hop, where no local device can match.
var consoleTerms = []string{"cons25", "cons25w"}

// consoleDevGlob matches the virtual console devices. vt(4) creates twelve of
// them, /dev/ttyv0 through /dev/ttyvb, and syscons up to sixteen, through
// /dev/ttyvf. Terminal emulators get a pseudo-terminal under /dev/pts instead.
const consoleDevGlob = "/dev/ttyv*"

// controllingTerminalDev returns the device number of the terminal behind tty.
//
// Unlike Linux, no ioctl is needed: devfs resolves the name "tty" to the
// session's controlling terminal during lookup, so the file we opened is that
// terminal and fstat reports its device number directly.
func controllingTerminalDev(tty *os.File) (uint64, bool) {
	var terminal unix.Stat_t
	if err := unix.Fstat(int(tty.Fd()), &terminal); err != nil {
		log.Debugf("cannot stat the controlling terminal: %s", err)
		return 0, false
	}

	return terminal.Rdev, true
}
