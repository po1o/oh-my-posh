package shell

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/po1o/prompto/src/log"
	"github.com/po1o/prompto/src/runtime"
	"github.com/po1o/prompto/src/runtime/path"
	"github.com/po1o/prompto/src/text"
)

const (
	noExe = "echo \"Unable to find Prompto executable\""
)

var (
	// identify ble.sh by validating the existence of BLE_SESSION_ID
	bashBLEsession bool
)

func getExecutablePath(env runtime.Environment) (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}

	if env.Flags().Strict {
		return path.Base(executable), nil
	}

	return stableExecutablePath(executable), nil
}

func stableExecutablePath(executable string) string {
	if len(executable) == 0 {
		return executable
	}

	cleanExe := filepath.Clean(executable)

	// If invoked via an explicit path (e.g. /opt/homebrew/bin/prompto), check if
	// that path is a symlink resolving to executable.
	if len(os.Args) > 0 && os.Args[0] != "" {
		argPath := os.Args[0]
		if filepath.IsAbs(argPath) || strings.ContainsRune(argPath, filepath.Separator) {
			if absArg, err := filepath.Abs(argPath); err == nil {
				cleanArg := filepath.Clean(absArg)
				if cleanArg != cleanExe {
					if target, err := filepath.EvalSymlinks(cleanArg); err == nil && filepath.Clean(target) == cleanExe {
						return cleanArg
					}
				}
			}
		}
	}

	// If invoked as a command name (e.g. "prompto") or if executable is inside a
	// package-manager cellar/store, search PATH for a stable entrypoint pointing to it.
	binNames := []string{"prompto"}
	if len(os.Args) > 0 && os.Args[0] != "" && !strings.ContainsRune(os.Args[0], filepath.Separator) {
		binNames = append([]string{os.Args[0]}, binNames...)
	}
	baseName := filepath.Base(cleanExe)
	if baseName != "prompto" {
		binNames = append(binNames, baseName)
	}

	for _, name := range binNames {
		lookPath, err := exec.LookPath(name)
		if err != nil {
			continue
		}

		absLook, err := filepath.Abs(lookPath)
		if err != nil {
			continue
		}

		cleanLook := filepath.Clean(absLook)
		if cleanLook == cleanExe {
			continue
		}

		target, err := filepath.EvalSymlinks(cleanLook)
		if err != nil {
			continue
		}

		if filepath.Clean(target) == cleanExe {
			return cleanLook
		}
	}

	return cleanExe
}

// Init returns the command to initialize prompto for the shell.
// It writes the init script to the appropriate location and returns
// a source command or wrapper command depending on the shell.
// For PWSH, it returns a wrapper command that re-invokes prompto.
func Init(env runtime.Environment, feats Features) string {
	switch env.Flags().Shell {
	case PWSH:
		if !env.Flags().Eval {
			return generateAndSourceScript(env, feats)
		}

		return recurseInitCommand(env)
	case ZSH, BASH, FISH:
		return generateAndSourceScript(env, feats)
	default:
		return fmt.Sprintf(`echo "%s is not supported by Prompto"`, env.Flags().Shell)
	}
}

// Script returns the init script content directly.
// This is used by the --print flag to output the script to stdout.
func Script(env runtime.Environment, feats Features) string {
	script := generateScript(env, feats)
	return script
}

// Debug writes the init script and returns debug information.
// This is used by the --debug flag.
func Debug(env runtime.Environment, feats Features, startTime *time.Time) string {
	script := generateScript(env, feats)

	log.Debug(script)

	if _, err := writeScript(env, script); err != nil {
		log.Error(err)
	}

	return printDebugInfo(env, startTime)
}

// recurseInitCommand returns a wrapper command that re-invokes prompto
// with --print. This is used by PWSH which evals the script.
func recurseInitCommand(env runtime.Environment) string {
	executable, err := getExecutablePath(env)
	if err != nil {
		return noExe
	}

	var additionalParams string

	if env.Flags().Strict {
		additionalParams += " --strict"
	}

	if env.Flags().Eval {
		additionalParams += " --eval"
	}

	config := quotePwshOrElvishStr(env.Flags().ConfigPath)
	executable = quotePwshOrElvishStr(executable)

	command := "(@(& %s init %s --config=%s --print%s) -join \"`n\") | Invoke-Expression"
	return fmt.Sprintf(command, executable, env.Flags().Shell, config, additionalParams)
}

// generateAndSourceScript writes the init script to the cache and returns a source command.
func generateAndSourceScript(env runtime.Environment, feats Features) string {
	async := feats&Async != 0

	if scriptPath, ok := hasScript(env); ok {
		return sourceCommand(env, scriptPath, async)
	}

	script := generateScript(env, feats)

	log.Debug(script)

	scriptPath, err := writeScript(env, script)
	if err != nil {
		return fmt.Sprintf("echo \"Failed to write init script: %s\"", err.Error())
	}

	return sourceCommand(env, scriptPath, async)
}

// generateScript generates the init script content for the current shell.
func generateScript(env runtime.Environment, feats Features) string {
	executable, err := getExecutablePath(env)
	if err != nil {
		return noExe
	}

	bashBLEsession = len(env.Getenv("BLE_SESSION_ID")) != 0

	var script string
	configPath := env.Flags().ConfigPath

	switch env.Flags().Shell {
	case PWSH:
		executable = quotePwshOrElvishStr(executable)
		configPath = quotePwshOrElvishStr(configPath)
		script = pwshInit
	case ZSH:
		executable = QuotePosixStr(executable)
		configPath = QuotePosixStr(configPath)
		script = zshInit
	case BASH:
		executable = QuotePosixStr(executable)
		configPath = QuotePosixStr(configPath)
		script = bashInit
	case FISH:
		executable = quoteFishStr(executable)
		configPath = quoteFishStr(configPath)
		script = fishInit
	default:
		return fmt.Sprintf("echo \"No initialization script available for %s\"", env.Flags().Shell)
	}

	init := strings.NewReplacer(
		"::PROMPTO::", executable,
		"::CONFIG::", configPath,
	).Replace(script)

	return feats.Lines(env.Flags().Shell).String(init)
}

// sourceCommand returns the command to source the init script.
func sourceCommand(env runtime.Environment, scriptPath string, async bool) string {
	if env.IsCygwin() {
		var err error
		scriptPath, err = env.RunCommand("cygpath", "-u", scriptPath)
		if err != nil {
			log.Error(err)
			return fmt.Sprintf("echo \"Failed to convert Cygwin path due to %s\"", err.Error())
		}
	}

	if async {
		return sourceCommandAsync(env.Flags().Shell, scriptPath)
	}

	switch env.Flags().Shell {
	case PWSH:
		return fmt.Sprintf("& %s", quotePwshOrElvishStr(scriptPath))
	case ZSH, BASH:
		return fmt.Sprintf("source %s", QuotePosixStr(scriptPath))
	case FISH:
		return fmt.Sprintf("source %s", quoteFishStr(scriptPath))
	default:
		return fmt.Sprintf("echo \"No source command available for %s\"", env.Flags().Shell)
	}
}

// sourceCommandAsync returns the async source command for supported shells.
func sourceCommandAsync(shell, scriptPath string) string {
	switch shell {
	case PWSH:
		return fmt.Sprintf("function prompt() { & %s }", quotePwshOrElvishStr(scriptPath))
	case ZSH:
		return fmt.Sprintf("precmd() { source %s }", QuotePosixStr(scriptPath))
	case BASH:
		command := fmt.Sprintf("source %s", QuotePosixStr(scriptPath))
		return fmt.Sprintf("PROMPT_COMMAND=%s", QuotePosixStr(command))
	case FISH:
		return fmt.Sprintf("function fish_prompt; source %s; end", quoteFishStr(scriptPath))
	default:
		return ""
	}
}

func printDebugInfo(env runtime.Environment, startTime *time.Time) string {
	builder := text.NewBuilder()

	builder.WriteString(fmt.Sprintf("\n%s %s\n", log.Text("Init duration:").Green().Bold().Plain(), time.Since(*startTime)))

	builder.WriteString(log.Text("\n\nLogs:\n\n").Green().Bold().Plain().String())
	builder.WriteString(env.Logs())

	return builder.String()
}
