package config

import (
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/po1o/prompto/src/log"
	"github.com/po1o/prompto/src/runtime/path"
)

const (
	// ConsoleEnv forces console detection on ("1") or off ("0"), taking
	// precedence over every other signal.
	ConsoleEnv = "PROMPTO_CONSOLE"
	// consoleMarker is inserted before the extension to name the console
	// variant of a config, e.g. config.yaml -> config.console.yaml.
	consoleMarker = ".console"
)

// IsConsole reports whether the prompt is rendered on a text console rather
// than a graphical terminal emulator. A console has no Nerd Font glyphs and
// only the 16 ANSI colors, so it needs a config written for those limits.
//
// Two signals are consulted. TERM is the cheap one, and the only one that
// survives an SSH hop, but it cannot be trusted on its own: /etc/ttys gives
// FreeBSD's vt(4) console the terminal type "xterm", which is exactly what an
// emulator reports. onDevice catches those by asking whether the controlling
// terminal is a console device.
//
// PROMPTO_CONSOLE overrides both, so the behavior can be forced either way for
// testing and for the sessions neither signal can reach: SSH out of a vt(4)
// console, or a multiplexer running on a console.
func IsConsole(getenv func(string) string, onDevice func() bool) bool {
	switch getenv(ConsoleEnv) {
	case "1":
		return true
	case "0":
		return false
	}

	if slices.Contains(consoleTerms, getenv("TERM")) {
		return true
	}

	return onDevice()
}

// ConsoleVariant returns the console-specific sibling of configFile by
// inserting ".console" before the extension:
//
//	~/.config/prompto/config.yaml -> ~/.config/prompto/config.console.yaml
func ConsoleVariant(configFile string) string {
	ext := filepath.Ext(configFile)
	return strings.TrimSuffix(configFile, ext) + consoleMarker + ext
}

// isConsoleVariant reports whether configFile already carries the console
// marker, so we never look for config.console.console.yaml.
func isConsoleVariant(configFile string) bool {
	ext := filepath.Ext(configFile)
	return strings.HasSuffix(strings.TrimSuffix(configFile, ext), consoleMarker)
}

// Resolve picks the config a session should use: the requested file, or
// DefaultPath when nothing was requested, swapped for its console variant when
// running on a console and that variant exists on disk.
//
// This runs in the shell's own process during `prompto init`, where TERM and
// the controlling terminal are the session's, and the result is baked into the
// init script. Every later render in that session then passes the resolved
// path back via --config, so console and non-console sessions can share one
// daemon without interfering.
func Resolve(configFile string) string {
	if configFile == "" {
		configFile = DefaultPath()
	}

	if !IsConsole(os.Getenv, onConsoleDevice) {
		return configFile
	}

	expanded := path.ReplaceTildePrefixWithHomeDir(configFile)
	if isConsoleVariant(expanded) {
		return configFile
	}

	variant := ConsoleVariant(expanded)
	if _, err := os.Stat(variant); err != nil {
		log.Debugf("console detected, but no config at %s, keeping %s", variant, configFile)
		return configFile
	}

	log.Debugf("console detected, using %s", variant)

	return variant
}
