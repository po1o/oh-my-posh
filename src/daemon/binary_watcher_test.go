package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestBinaryWatcherTriggersOnWrite(t *testing.T) {
	tmpDir := t.TempDir()
	binaryPath := filepath.Join(tmpDir, "prompto")
	require.NoError(t, os.WriteFile(binaryPath, []byte("v1"), 0o755))

	triggered := make(chan struct{}, 1)
	watcher, err := newBinaryWatcher(binaryPath, func() {
		select {
		case triggered <- struct{}{}:
		default:
		}
	}, 25*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = watcher.Close() })

	require.NoError(t, os.WriteFile(binaryPath, []byte("v2"), 0o755))

	require.Eventually(t, func() bool {
		select {
		case <-triggered:
			return true
		default:
			return false
		}
	}, time.Second, 10*time.Millisecond)
}

func TestBinaryWatcherTriggersOnRemove(t *testing.T) {
	tmpDir := t.TempDir()
	binaryPath := filepath.Join(tmpDir, "prompto")
	require.NoError(t, os.WriteFile(binaryPath, []byte("v1"), 0o755))

	triggered := make(chan struct{}, 1)
	watcher, err := newBinaryWatcher(binaryPath, func() {
		select {
		case triggered <- struct{}{}:
		default:
		}
	}, 25*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = watcher.Close() })

	require.NoError(t, os.Remove(binaryPath))

	require.Eventually(t, func() bool {
		select {
		case <-triggered:
			return true
		default:
			return false
		}
	}, time.Second, 10*time.Millisecond)
}

func TestBinaryWatcherTracksResolvedPathForSymlinkInput(t *testing.T) {
	tmpDir := t.TempDir()
	binDir := filepath.Join(tmpDir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0o755))

	realBinaryV1 := filepath.Join(tmpDir, "prompto-v1")
	require.NoError(t, os.WriteFile(realBinaryV1, []byte("v1"), 0o755))

	symlinkPath := filepath.Join(binDir, "prompto")
	require.NoError(t, os.Symlink(realBinaryV1, symlinkPath))

	triggered := make(chan struct{}, 1)
	watcher, err := newBinaryWatcher(symlinkPath, func() {
		select {
		case triggered <- struct{}{}:
		default:
		}
	}, 25*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = watcher.Close() })

	require.NoError(t, os.WriteFile(realBinaryV1, []byte("v2"), 0o755))

	require.Eventually(t, func() bool {
		select {
		case <-triggered:
			return true
		default:
			return false
		}
	}, time.Second, 10*time.Millisecond)
}

func TestBinaryWatcherTracksSymlinkWhenInputIsResolvedPath(t *testing.T) {
	tmpDir := t.TempDir()
	binDir := filepath.Join(tmpDir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0o755))

	cellarDir1 := filepath.Join(tmpDir, "Cellar", "1")
	require.NoError(t, os.MkdirAll(cellarDir1, 0o755))
	realBinaryV1 := filepath.Join(cellarDir1, "prompto")
	require.NoError(t, os.WriteFile(realBinaryV1, []byte("v1"), 0o755))

	cellarDir2 := filepath.Join(tmpDir, "Cellar", "2")
	require.NoError(t, os.MkdirAll(cellarDir2, 0o755))
	realBinaryV2 := filepath.Join(cellarDir2, "prompto")
	require.NoError(t, os.WriteFile(realBinaryV2, []byte("v2-different-size"), 0o755))

	symlinkPath := filepath.Join(binDir, "prompto")
	require.NoError(t, os.Symlink(realBinaryV1, symlinkPath))

	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	triggered := make(chan struct{}, 1)
	watcher, err := newBinaryWatcher(realBinaryV1, func() {
		select {
		case triggered <- struct{}{}:
		default:
		}
	}, 25*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = watcher.Close() })

	// Update symlink in PATH to point to v2
	require.NoError(t, os.Remove(symlinkPath))
	require.NoError(t, os.Symlink(realBinaryV2, symlinkPath))

	require.Eventually(t, func() bool {
		select {
		case <-triggered:
			return true
		default:
			return false
		}
	}, time.Second, 10*time.Millisecond)
}

func TestBinaryWatcherTriggersOnWatchedDirectoryRemoval(t *testing.T) {
	tmpDir := t.TempDir()
	cellarDir := filepath.Join(tmpDir, "Cellar", "prompto", "1.0.0", "bin")
	require.NoError(t, os.MkdirAll(cellarDir, 0o755))

	binaryPath := filepath.Join(cellarDir, "prompto")
	require.NoError(t, os.WriteFile(binaryPath, []byte("v1"), 0o755))

	triggered := make(chan struct{}, 1)
	watcher, err := newBinaryWatcher(binaryPath, func() {
		select {
		case triggered <- struct{}{}:
		default:
		}
	}, 25*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = watcher.Close() })

	// Simulate brew cleanup removing Cellar/prompto/1.0.0
	require.NoError(t, os.RemoveAll(filepath.Join(tmpDir, "Cellar", "prompto", "1.0.0")))

	require.Eventually(t, func() bool {
		select {
		case <-triggered:
			return true
		default:
			return false
		}
	}, time.Second, 10*time.Millisecond)
}
