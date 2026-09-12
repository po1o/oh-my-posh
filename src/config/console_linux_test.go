//go:build linux

package config

import (
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
)

func TestLinuxConsoleTerms(t *testing.T) {
	t.Parallel()

	require.Contains(t, consoleTerms, "linux")
}

// On Linux the /dev/tty node is a device in its own right, 5:0, distinct from
// the terminal it stands for — which is why controllingTerminalDev cannot be a
// plain fstat here. That number must never be taken for a console.
//
// This is a Linux-only property: FreeBSD's devfs resolves the name to the
// controlling terminal itself, so the same assertion there would fail on a
// real console, correctly.
func TestTheDevTTYNodeIsNotAConsoleDevice(t *testing.T) {
	t.Parallel()

	var node unix.Stat_t
	if err := unix.Stat("/dev/tty", &node); err != nil {
		t.Skipf("no /dev/tty node here: %s", err)
	}

	require.False(t, isConsoleDevice(node.Rdev),
		"the /dev/tty node's own device number is being treated as a console")
}

// TIOCGDEV has to decode to exactly the device number stat(2) reports for the
// same terminal, since that is what isConsoleDevice compares against. A pty
// gives us a terminal whose number we can read independently, so this pins the
// dev_t arithmetic without needing a controlling terminal — unlike the test
// below, it runs in CI.
func TestControllingTerminalDevDecodesToTheStatDevice(t *testing.T) {
	t.Parallel()

	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Skipf("no /dev/ptmx here: %s", err)
	}

	defer master.Close()

	number, err := unix.IoctlGetInt(int(master.Fd()), unix.TIOCGPTN)
	require.NoError(t, err)
	require.NoError(t, unix.IoctlSetPointerInt(int(master.Fd()), unix.TIOCSPTLCK, 0))

	name := filepath.Join("/dev/pts", strconv.Itoa(number))

	slave, err := os.OpenFile(name, os.O_RDWR|syscall.O_NOCTTY|syscall.O_NONBLOCK, 0)
	require.NoError(t, err)

	defer slave.Close()

	// A pts slave is not /dev/tty, so fstat does report its real device here.
	var stat unix.Stat_t
	require.NoError(t, unix.Fstat(int(slave.Fd()), &stat))

	device, ok := controllingTerminalDev(slave)
	require.True(t, ok)
	require.Equal(t, stat.Rdev, device, "TIOCGDEV decoded to a different device than stat reports")
}

// The regression test for the mistake this probe started out making: fstat on
// an fd opened from /dev/tty returns that node's own 5:0, identically for
// every session, so a probe built on it reports "not a console" even on a real
// console — while looking perfectly correct on any developer machine.
func TestControllingTerminalDevIsNotTheDevTTYNode(t *testing.T) {
	t.Parallel()

	tty, err := os.OpenFile("/dev/tty", os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Skipf("no controlling terminal here: %s", err)
	}

	defer tty.Close()

	device, ok := controllingTerminalDev(tty)
	if !ok {
		t.Skip("the controlling terminal reported no device")
	}

	var node unix.Stat_t
	require.NoError(t, unix.Stat("/dev/tty", &node))
	require.NotEqual(t, node.Rdev, device, "got the /dev/tty node's own device number")

	// Pins the reason the ioctl is needed rather than a plain fstat.
	var stat unix.Stat_t
	require.NoError(t, unix.Fstat(int(tty.Fd()), &stat))
	require.Equal(t, node.Rdev, stat.Rdev, "fstat unexpectedly resolved the terminal")
}

func TestLinuxConsoleDevGlob(t *testing.T) {
	t.Parallel()

	cases := []struct {
		device  string
		matches bool
	}{
		{device: "/dev/tty1", matches: true},
		{device: "/dev/tty12", matches: true},
		{device: "/dev/tty63", matches: true},
		// The tail of the pattern is loose on purpose: it produces candidates,
		// and the device-number comparison is what decides.
		{device: "/dev/tty64", matches: true},
		// An alias for the current console, never a controlling terminal.
		{device: "/dev/tty0", matches: false},
		{device: "/dev/tty", matches: false},
		{device: "/dev/pts/0", matches: false},
		{device: "/dev/ttyS0", matches: false},
	}

	for _, tc := range cases {
		t.Run(tc.device, func(t *testing.T) {
			t.Parallel()

			matched, err := filepath.Match(consoleDevGlob, tc.device)
			require.NoError(t, err)
			require.Equal(t, tc.matches, matched)
		})
	}
}
