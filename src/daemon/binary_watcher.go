package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/po1o/prompto/src/log"

	"github.com/fsnotify/fsnotify"
)

// BinaryWatcher watches the prompto executable for changes using fsnotify.
// When the binary is replaced (e.g. by brew upgrade, go install, or an installer),
// it calls the onChange callback so the daemon can shut down gracefully.
//
// Like ConfigWatcher, we watch the parent directory rather than the file itself,
// because installers replace binaries atomically (delete + rename or rename + rename).
type BinaryWatcher struct {
	watcher     *fsnotify.Watcher
	done        chan struct{}
	watchedDirs map[string]bool
	targetPaths map[string]bool
	signatures  map[string]binarySignature
	once        sync.Once
}

type binarySignature struct {
	exists  bool
	size    int64
	modUnix int64
}

// NewBinaryWatcher creates a watcher that monitors binPath for changes.
// onChange is called at most once when the binary is replaced.
func NewBinaryWatcher(binPath string, onChange func()) (*BinaryWatcher, error) {
	return newBinaryWatcher(binPath, onChange, time.Second)
}

func newBinaryWatcher(binPath string, onChange func(), debounceWindow time.Duration) (*BinaryWatcher, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}

	bw := &BinaryWatcher{
		watcher:     watcher,
		done:        make(chan struct{}),
		watchedDirs: make(map[string]bool),
		targetPaths: make(map[string]bool),
		signatures:  make(map[string]binarySignature),
	}

	if err := bw.addTargetPath(binPath); err != nil {
		_ = bw.Close()
		return nil, err
	}

	// Also track the resolved path when available so we catch updates done against
	// the real binary target (common with Homebrew and other symlink-based installs).
	resolved, err := filepath.EvalSymlinks(binPath)
	if err == nil {
		if err := bw.addTargetPath(resolved); err != nil {
			_ = bw.Close()
			return nil, err
		}
	}

	// If the binary was invoked via its real path (e.g. Linux procfs), also try to
	// discover any stable symlink entry in PATH (e.g. Homebrew bin) that resolves to it.
	binName := filepath.Base(binPath)
	if lookPath, err := exec.LookPath(binName); err == nil {
		if resolvedLook, err := filepath.EvalSymlinks(lookPath); err == nil {
			cleanResolvedLook := filepath.Clean(resolvedLook)
			cleanTarget := filepath.Clean(binPath)
			if resolved != "" {
				cleanTarget = filepath.Clean(resolved)
			}
			if cleanResolvedLook == cleanTarget {
				_ = bw.addTargetPath(lookPath)
			}
		}
	}

	go bw.eventLoop(onChange, debounceWindow)

	return bw, nil
}

// Close stops the watcher.
func (bw *BinaryWatcher) Close() error {
	bw.once.Do(func() { close(bw.done) })
	return bw.watcher.Close()
}

func (bw *BinaryWatcher) addTargetPath(path string) error {
	if path == "" {
		return nil
	}

	absPath, err := filepath.Abs(path)
	if err != nil {
		return err
	}

	cleanPath := filepath.Clean(absPath)
	bw.targetPaths[cleanPath] = true
	bw.signatures[cleanPath] = binarySignatureFor(cleanPath)

	dir := filepath.Dir(cleanPath)
	if bw.watchedDirs[dir] {
		return nil
	}

	err = bw.watcher.Add(dir)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	// Directory might not exist yet during install/upgrade windows.
	// We still keep the target path so later events can match once the dir appears.

	if err == nil {
		bw.watchedDirs[dir] = true
		log.Debugf("watching binary directory: %s", dir)
	}

	return nil
}

func binarySignatureFor(path string) binarySignature {
	info, err := os.Stat(path)
	if err != nil {
		return binarySignature{}
	}

	return binarySignature{
		exists:  true,
		size:    info.Size(),
		modUnix: info.ModTime().UnixNano(),
	}
}

func (bw *BinaryWatcher) hasBinaryChanged() bool {
	for path := range bw.targetPaths {
		current := binarySignatureFor(path)
		if current == bw.signatures[path] {
			continue
		}

		return true
	}

	return false
}

// eventLoop processes fsnotify events with debounce.
func (bw *BinaryWatcher) eventLoop(onChange func(), debounceWindow time.Duration) {
	var debounce *time.Timer

	for {
		select {
		case event, ok := <-bw.watcher.Events:
			if !ok {
				return
			}

			eventPath, err := filepath.Abs(event.Name)
			if err != nil {
				continue
			}

			cleanEventPath := filepath.Clean(eventPath)
			isTarget := bw.targetPaths[cleanEventPath]
			isWatchedDir := bw.watchedDirs[cleanEventPath] && event.Op&(fsnotify.Remove|fsnotify.Rename) != 0

			if !isTarget && !isWatchedDir {
				continue
			}

			// Binary replacement across platforms often manifests as rename/remove/create sequences.
			if event.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Rename|fsnotify.Remove) == 0 {
				continue
			}

			log.Debugf("binary changed (%s): %s", event.Op, event.Name)

			// Debounce: atomic saves can produce multiple events.
			if debounce != nil {
				debounce.Stop()
			}
			debounce = time.AfterFunc(debounceWindow, func() {
				if !bw.hasBinaryChanged() {
					return
				}

				log.Debug("binary change confirmed, triggering callback")
				onChange()
			})

		case err, ok := <-bw.watcher.Errors:
			if !ok {
				return
			}
			log.Debugf("binary watcher error: %v", err)

		case <-bw.done:
			if debounce != nil {
				debounce.Stop()
			}
			return
		}
	}
}
