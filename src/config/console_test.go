package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestIsConsole(t *testing.T) {
	t.Parallel()

	// consoleTerms is platform-specific, so the console case is expressed in
	// terms of it. Its actual contents are pinned per platform elsewhere.
	require.NotEmpty(t, consoleTerms, "no console TERM values for this platform")

	consoleTerm := consoleTerms[0]

	cases := []struct {
		env      map[string]string
		name     string
		onDevice bool
		expected bool
	}{
		{
			name:     "console TERM",
			env:      map[string]string{"TERM": consoleTerm},
			expected: true,
		},
		{
			name:     "terminal emulator",
			env:      map[string]string{"TERM": "xterm-256color"},
			expected: false,
		},
		{
			name:     "no TERM at all",
			env:      map[string]string{},
			expected: false,
		},
		{
			// A vt(4) console: TERM says xterm, the device says otherwise.
			name:     "console device behind an emulator TERM",
			env:      map[string]string{"TERM": "xterm"},
			onDevice: true,
			expected: true,
		},
		{
			name:     "forced on overrides both signals",
			env:      map[string]string{"TERM": "xterm-256color", ConsoleEnv: "1"},
			expected: true,
		},
		{
			name:     "forced off overrides TERM",
			env:      map[string]string{"TERM": consoleTerm, ConsoleEnv: "0"},
			expected: false,
		},
		{
			name:     "forced off overrides the console device",
			env:      map[string]string{"TERM": "xterm", ConsoleEnv: "0"},
			onDevice: true,
			expected: false,
		},
		{
			name:     "unrecognized override value falls back to the signals",
			env:      map[string]string{"TERM": consoleTerm, ConsoleEnv: "yes"},
			expected: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			getenv := func(key string) string { return tc.env[key] }
			onDevice := func() bool { return tc.onDevice }

			require.Equal(t, tc.expected, IsConsole(getenv, onDevice))
		})
	}
}

// Opening /dev/tty is the expensive half of detection, so a TERM we already
// recognize has to answer on its own.
func TestIsConsoleSkipsTheDeviceProbeOnAConsoleTerm(t *testing.T) {
	t.Parallel()

	getenv := func(key string) string {
		if key == "TERM" {
			return consoleTerms[0]
		}

		return ""
	}

	probed := false
	onDevice := func() bool {
		probed = true
		return false
	}

	require.True(t, IsConsole(getenv, onDevice))
	require.False(t, probed, "the device probe ran despite a console TERM")
}

func TestConsoleVariant(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "default config",
			input:    filepath.Join("home", "prompto", "config.yaml"),
			expected: filepath.Join("home", "prompto", "config.console.yaml"),
		},
		{
			name:     "yml extension is preserved",
			input:    filepath.Join("home", "config.yml"),
			expected: filepath.Join("home", "config.console.yml"),
		},
		{
			name:     "dots in the name only split on the extension",
			input:    filepath.Join("home", "my.theme.yaml"),
			expected: filepath.Join("home", "my.theme.console.yaml"),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			require.Equal(t, tc.expected, ConsoleVariant(tc.input))
		})
	}
}

// Resolve consults the real terminal, so these force detection through
// PROMPTO_CONSOLE rather than TERM: what is under test is the variant
// swapping, and the result must not depend on where the tests are run from.
func TestResolveUsesConsoleVariantOnlyWhenItExists(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.yaml")
	consolePath := filepath.Join(dir, "config.console.yaml")

	require.NoError(t, os.WriteFile(configPath, []byte("prompt: []\n"), 0o644))

	t.Setenv(ConsoleEnv, "1")

	// No variant on disk yet: the requested config is kept.
	require.Equal(t, configPath, Resolve(configPath))

	require.NoError(t, os.WriteFile(consolePath, []byte("prompt: []\n"), 0o644))

	require.Equal(t, consolePath, Resolve(configPath))
}

func TestResolveIgnoresConsoleVariantOffConsole(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.yaml")
	consolePath := filepath.Join(dir, "config.console.yaml")

	require.NoError(t, os.WriteFile(configPath, []byte("prompt: []\n"), 0o644))
	require.NoError(t, os.WriteFile(consolePath, []byte("prompt: []\n"), 0o644))

	t.Setenv(ConsoleEnv, "0")

	require.Equal(t, configPath, Resolve(configPath))
}

// A console config passed explicitly must not send us looking for
// config.console.console.yaml.
func TestResolveIsIdempotentOnAConsoleConfig(t *testing.T) {
	dir := t.TempDir()
	consolePath := filepath.Join(dir, "config.console.yaml")

	require.NoError(t, os.WriteFile(consolePath, []byte("prompt: []\n"), 0o644))

	t.Setenv(ConsoleEnv, "1")

	require.Equal(t, consolePath, Resolve(consolePath))
}

func TestResolveFallsBackToDefaultPath(t *testing.T) {
	t.Setenv(ConsoleEnv, "0")

	require.Equal(t, DefaultPath(), Resolve(""))
}
