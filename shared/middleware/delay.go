package middleware

import (
	"math/rand"
	"net/http"
	"time"
)

// DelayMiddleware returns a middleware that sleeps a random duration between
// minMS and maxMS milliseconds before calling the next handler.
// This simulates configurable network latency. No delay is applied when
// maxMS <= 0 or maxMS < minMS.
func DelayMiddleware(minMS, maxMS int) func(http.HandlerFunc) http.HandlerFunc {
	return func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if maxMS > 0 && maxMS >= minMS {
				delay := minMS
				if maxMS > minMS {
					delay += rand.Intn(maxMS - minMS)
				}
				time.Sleep(time.Duration(delay) * time.Millisecond)
			}
			next(w, r)
		}
	}
}
