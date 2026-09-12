package shell

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// fakeDaemonRender stands in for `prompto render`. It emits the batches a
// render produces when a segment outruns the deadline and then answers late,
// releasing each one only when the driver asks for it, so the test never races
// the shell.
const fakeDaemonRender = `#!/usr/bin/env zsh
print "primary:PENDING"
print "right:"
print "status:update"

while [[ ! -f "$PROMPTO_TEST_GATE_TIMEOUT" ]]; do sleep 0.01; done
print "primary:TIMEDOUT"
print "right:"
print "status:update"

while [[ ! -f "$PROMPTO_TEST_GATE_RESOLVED" ]]; do sleep 0.01; done
print "primary:RESOLVED"
print "right:"
print "status:complete"
`

// zshDriver exercises the integration the way ZLE would. Outside a terminal
// there is no ZLE, so the zle builtin is replaced by a function: it records the
// fd handler zsh would invoke when the stream has more to say, and the driver
// then calls that handler itself, in ZLE's place.
const zshDriver = `
disable zle 2>/dev/null
typeset -g _test_resets=0
typeset -g _test_fd=

zle() {
  case "$1" in
    -F)
      if [[ -n "$3" ]]; then
        _test_fd=$2
      else
        _test_fd=
      fi
      ;;
    .reset-prompt)
      _test_resets=$(( _test_resets + 1 ))
      ;;
  esac
  return 0
}

source ::SCRIPT::

_prompto_daemon_render
print "RESULT after-render ps1=$PS1 fd=${_test_fd:-none} resets=$_test_resets"

touch ::GATE_TIMEOUT::
_prompto_daemon_handler $_test_fd
print "RESULT after-timeout ps1=$PS1 resets=$_test_resets"

touch ::GATE_RESOLVED::
_prompto_daemon_handler $_test_fd
print "RESULT after-resolved ps1=$PS1 resets=$_test_resets tracked=${_prompto_daemon_fd:-empty}"
`

// TestZshAppliesEveryStreamedPromptUpdate drives the real zsh integration
// against a stand-in daemon. The shell half of the streaming contract had only
// ever been checked by reading the scripts, so nothing caught whether zsh
// actually applies what the daemon streams.
//
// The sequence is the one a slow segment produces: the pending placeholder
// first, the timed-out marker once the render deadline passes, then the real
// value when the segment answers after all. zsh has to land on each in turn,
// repaint for each, and let go of the stream when it completes — a prompt that
// is never repainted is the bug this whole path exists to avoid.
func TestZshAppliesEveryStreamedPromptUpdate(t *testing.T) {
	if _, err := exec.LookPath("zsh"); err != nil {
		t.Skip("zsh is not installed")
	}

	dir := t.TempDir()

	executable := filepath.Join(dir, "prompto")
	require.NoError(t, os.WriteFile(executable, []byte(fakeDaemonRender), 0o700))

	gateTimeout := filepath.Join(dir, "gate-timeout")
	gateResolved := filepath.Join(dir, "gate-resolved")

	script := filepath.Join(dir, "prompto.zsh")
	integration := strings.NewReplacer(
		"::PROMPTO::", "'"+executable+"'",
		"::CONFIG::", "''",
	).Replace(zshInit)
	require.NoError(t, os.WriteFile(script, []byte(integration), 0o600))

	driver := filepath.Join(dir, "driver.zsh")
	body := strings.NewReplacer(
		"::SCRIPT::", "'"+script+"'",
		"::GATE_TIMEOUT::", "'"+gateTimeout+"'",
		"::GATE_RESOLVED::", "'"+gateResolved+"'",
	).Replace(zshDriver)
	require.NoError(t, os.WriteFile(driver, []byte(body), 0o600))

	command := exec.CommandContext(t.Context(), "zsh", "-f", driver)
	command.Env = append(os.Environ(),
		"PROMPTO_TEST_GATE_TIMEOUT="+gateTimeout,
		"PROMPTO_TEST_GATE_RESOLVED="+gateResolved,
	)

	output, err := command.CombinedOutput()
	require.NoError(t, err, "driver failed:\n%s", output)

	results := resultLines(string(output))
	require.Len(t, results, 3, "driver did not reach every step:\n%s", output)

	require.Contains(t, results[0], "ps1=PENDING", "the first batch must reach PS1")
	require.NotContains(t, results[0], "fd=none", "zsh must watch the stream for the rest")

	require.Contains(t, results[1], "ps1=TIMEDOUT", "the timed-out marker must reach PS1")
	require.Contains(t, results[1], "resets=1", "the marker must repaint the prompt")

	require.Contains(t, results[2], "ps1=RESOLVED", "the late value must replace the marker")
	require.Contains(t, results[2], "resets=2", "the late value must repaint the prompt")
	require.Contains(t, results[2], "tracked=empty", "zsh must let go of a completed stream")
}

func resultLines(output string) []string {
	var results []string
	for line := range strings.SplitSeq(output, "\n") {
		if after, ok := strings.CutPrefix(line, "RESULT "); ok {
			results = append(results, after)
		}
	}

	return results
}

func TestZshDaemonRenderRecoversFromDeletedExecutable(t *testing.T) {
	if _, err := exec.LookPath("zsh"); err != nil {
		t.Skip("zsh is not installed")
	}

	dir := t.TempDir()

	binDir := filepath.Join(dir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0o755))
	newExecutable := filepath.Join(binDir, "prompto")
	simpleRender := `#!/usr/bin/env zsh
print "primary:HEALED"
print "right:"
print "status:complete"
`
	require.NoError(t, os.WriteFile(newExecutable, []byte(simpleRender), 0o700))

	deletedExecutable := filepath.Join(dir, "deleted", "prompto")

	script := filepath.Join(dir, "prompto.zsh")
	integration := strings.NewReplacer(
		"::PROMPTO::", "'"+deletedExecutable+"'",
		"::CONFIG::", "''",
	).Replace(zshInit)
	require.NoError(t, os.WriteFile(script, []byte(integration), 0o600))

	driverCode := `
source ::SCRIPT::
_prompto_daemon_render
print "RESULT ps1=$PS1 exe=$_prompto_executable"
`
	driver := filepath.Join(dir, "driver.zsh")
	body := strings.NewReplacer(
		"::SCRIPT::", "'"+script+"'",
	).Replace(driverCode)
	require.NoError(t, os.WriteFile(driver, []byte(body), 0o600))

	command := exec.CommandContext(t.Context(), "zsh", "-f", driver)
	command.Env = append(os.Environ(), "PATH="+binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	output, err := command.CombinedOutput()
	require.NoError(t, err, "driver failed:\n%s", output)

	results := resultLines(string(output))
	require.Len(t, results, 1)
	require.Contains(t, results[0], "ps1=HEALED")
	require.Contains(t, results[0], "exe="+newExecutable)
}

func TestZshDaemonRenderRestoresPrimaryPromptOnRenderFailure(t *testing.T) {
	if _, err := exec.LookPath("zsh"); err != nil {
		t.Skip("zsh is not installed")
	}

	dir := t.TempDir()

	deletedExecutable := filepath.Join(dir, "nonexistent", "prompto")

	script := filepath.Join(dir, "prompto.zsh")
	integration := strings.NewReplacer(
		"::PROMPTO::", "'"+deletedExecutable+"'",
		"::CONFIG::", "''",
	).Replace(zshInit)
	require.NoError(t, os.WriteFile(script, []byte(integration), 0o600))

	driverCode := `
source ::SCRIPT::
_prompto_last_primary_prompt="FALLBACK_PROMPT"
PS1="TRANSIENT_PROMPT"
_prompto_daemon_render
print "RESULT ps1=$PS1"
`
	driver := filepath.Join(dir, "driver.zsh")
	body := strings.NewReplacer(
		"::SCRIPT::", "'"+script+"'",
	).Replace(driverCode)
	require.NoError(t, os.WriteFile(driver, []byte(body), 0o600))

	command := exec.CommandContext(t.Context(), "zsh", "-f", driver)
	command.Env = []string{"PATH=/usr/empty_path_for_test"}

	output, err := command.CombinedOutput()
	require.NoError(t, err, "driver failed:\n%s", output)

	results := resultLines(string(output))
	require.Len(t, results, 1)
	require.Contains(t, results[0], "ps1=FALLBACK_PROMPT")
}
