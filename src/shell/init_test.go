package shell

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestStableExecutablePathWithSymlinkInPath(t *testing.T) {
	tempDir := t.TempDir()

	cellarDir := filepath.Join(tempDir, "Cellar", "prompto", "1.0.0", "bin")
	require.NoError(t, os.MkdirAll(cellarDir, 0o755))
	realBinary := filepath.Join(cellarDir, "prompto")
	require.NoError(t, os.WriteFile(realBinary, []byte("#!/bin/sh\n"), 0o755))

	binDir := filepath.Join(tempDir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0o755))
	symlink := filepath.Join(binDir, "prompto")
	require.NoError(t, os.Symlink(realBinary, symlink))

	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	oldArgs := os.Args
	t.Cleanup(func() { os.Args = oldArgs })
	os.Args = []string{"prompto", "init", "zsh"}

	resolved := stableExecutablePath(realBinary)
	assert.Equal(t, symlink, resolved)
}

func TestStableExecutablePathExplicitSymlinkArg(t *testing.T) {
	tempDir := t.TempDir()

	cellarDir := filepath.Join(tempDir, "Cellar", "prompto", "1.0.0", "bin")
	require.NoError(t, os.MkdirAll(cellarDir, 0o755))
	realBinary := filepath.Join(cellarDir, "prompto")
	require.NoError(t, os.WriteFile(realBinary, []byte("#!/bin/sh\n"), 0o755))

	binDir := filepath.Join(tempDir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0o755))
	symlink := filepath.Join(binDir, "prompto")
	require.NoError(t, os.Symlink(realBinary, symlink))

	oldArgs := os.Args
	t.Cleanup(func() { os.Args = oldArgs })
	os.Args = []string{symlink, "init", "zsh"}

	resolved := stableExecutablePath(realBinary)
	assert.Equal(t, symlink, resolved)
}

func TestStableExecutablePathWithoutSymlink(t *testing.T) {
	tempDir := t.TempDir()
	binPath := filepath.Join(tempDir, "prompto")
	require.NoError(t, os.WriteFile(binPath, []byte("#!/bin/sh\n"), 0o755))

	oldArgs := os.Args
	t.Cleanup(func() { os.Args = oldArgs })
	os.Args = []string{binPath, "init", "zsh"}

	resolved := stableExecutablePath(binPath)
	assert.Equal(t, binPath, resolved)
}
