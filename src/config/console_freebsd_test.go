//go:build freebsd

package config

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// FreeBSD 9.0 onwards assigns the virtual consoles "xterm" in /etc/ttys, so
// that value must never appear here: matching it would treat every FreeBSD
// terminal emulator as a console.
func TestFreeBSDConsoleTerms(t *testing.T) {
	t.Parallel()

	require.Contains(t, consoleTerms, "cons25")
	require.NotContains(t, consoleTerms, "xterm")
}

func TestFreeBSDConsoleDevGlob(t *testing.T) {
	t.Parallel()

	cases := []struct {
		device  string
		matches bool
	}{
		// vt(4) creates ttyv0..ttyvb, syscons up to ttyvf.
		{device: "/dev/ttyv0", matches: true},
		{device: "/dev/ttyvb", matches: true},
		{device: "/dev/ttyvf", matches: true},
		{device: "/dev/pts/0", matches: false},
		{device: "/dev/ttyu0", matches: false},
		{device: "/dev/tty", matches: false},
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
