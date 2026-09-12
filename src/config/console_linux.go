//go:build linux

package config

import (
	"os"

	"github.com/po1o/prompto/src/log"
	"golang.org/x/sys/unix"
)

// consoleTerms are the TERM values that identify a text console. The Linux
// virtual console reports "linux", and carries that across an SSH hop too.
var consoleTerms = []string{"linux"}

// consoleDevGlob matches the virtual console devices, /dev/tty1 upwards. It is
// deliberately loose at the tail, since what it produces is a candidate list
// checked by device number, but it must not catch /dev/tty0 — an alias for
// whichever console is current, never a session's controlling terminal — nor
// /dev/tty itself.
const consoleDevGlob = "/dev/tty[1-9]*"

// controllingTerminalDev returns the device number of the terminal behind tty.
//
// This cannot be a plain fstat. On Linux /dev/tty is a character device in its
// own right, 5:0, and open(2) keeps that inode while redirecting only the
// operations to the real terminal, so fstat reports 5:0 for every session
// rather than the device underneath. TIOCGDEV asks the kernel for the latter.
func controllingTerminalDev(tty *os.File) (uint64, bool) {
	device, err := unix.IoctlGetInt(int(tty.Fd()), unix.TIOCGDEV)
	if err != nil {
		log.Debugf("cannot read the controlling terminal device: %s", err)
		return 0, false
	}

	// TIOCGDEV reports the kernel's packed 32-bit dev_t. Unpack it the way
	// new_decode_dev() does before comparing against stat(2) device numbers.
	major := (uint32(device) & 0xfff00) >> 8
	minor := uint32(device)&0xff | (uint32(device)>>12)&0xfff00

	return unix.Mkdev(major, minor), true
}
