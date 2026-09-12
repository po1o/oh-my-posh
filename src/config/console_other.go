//go:build !linux && !freebsd

package config

// consoleTerms are the TERM values that identify a text console. Only TERM is
// consulted on these platforms, and it still carries TERM=linux across an SSH
// hop from a Linux console.
var consoleTerms = []string{"linux"}

// onConsoleDevice reports whether the controlling terminal is a console
// device. No device check is implemented here: darwin and windows have no text
// console, and the BSDs this tag also covers would each need their own wscons
// device names.
func onConsoleDevice() bool { return false }
