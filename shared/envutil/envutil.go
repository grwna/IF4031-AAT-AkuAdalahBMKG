package envutil

import (
	"os"
	"strconv"
)

// Str returns the value of the environment variable key,
// or fallback if the variable is unset or empty.
func Str(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Int returns the integer value of the environment variable key,
// or fallback if the variable is unset, empty, or not a valid integer.
func Int(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}
