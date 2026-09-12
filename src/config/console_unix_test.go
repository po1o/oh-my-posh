//go:build linux || freebsd

package config

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
)

// Whatever console devices this machine has must be recognised by number,
// which is the comparison onConsoleDevice ultimately rests on.
func TestConsoleDevicesAreRecognisedByNumber(t *testing.T) {
	t.Parallel()

	devices, err := filepath.Glob(consoleDevGlob)
	require.NoError(t, err)

	if len(devices) == 0 {
		t.Skipf("no console devices matching %s on this machine", consoleDevGlob)
	}

	for _, name := range devices {
		var console unix.Stat_t
		if err := unix.Stat(name, &console); err != nil {
			continue
		}

		require.True(t, isConsoleDevice(console.Rdev), "%s was not recognised", name)
	}
}

func TestAnUnusedDeviceNumberIsNotAConsole(t *testing.T) {
	t.Parallel()

	require.False(t, isConsoleDevice(0), "0 is never a console device number")
}
