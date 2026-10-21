// Package main is a deliberately small HTTP service. The app itself is not the
// point of this project; the pipeline and cluster controls around it are.
package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"
)

var version = "dev" // overwritten at build time with -ldflags

func newMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"service": "secure-api",
			"version": version,
			"time":    time.Now().UTC().Format(time.RFC3339),
		})
	})

	return mux
}

// securityHeaders adds a baseline set of response headers.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'none'")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

// probe does a single HTTP GET and reports success. The distroless image has
// no shell or curl, so `secure-api probe <url>` is how scripts/demo-attacks.sh
// tests NetworkPolicies using the same signed image (no unsigned debug images).
func probe(url string) error {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url) // #nosec G107 G704 -- URL is an operator-supplied CLI arg used only for in-cluster probes, never request input
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	return nil
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "probe" {
		if err := probe(os.Args[2]); err != nil {
			fmt.Println("BLOCKED/FAILED:", err)
			os.Exit(1)
		}
		fmt.Println("REACHABLE:", os.Args[2])
		return
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}

	// Explicit timeouts: gosec (G114) flags a bare http.ListenAndServe because
	// it has no read/write timeouts and is open to slowloris-style attacks.
	srv := &http.Server{
		Addr:              addr,
		Handler:           securityHeaders(newMux()),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	logger.Info("starting", "addr", addr, "version", version)
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
