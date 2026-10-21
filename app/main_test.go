package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	rr := httptest.NewRecorder()
	securityHeaders(newMux()).ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rr.Code)
	}
	if rr.Body.String() != "ok" {
		t.Fatalf("want body ok, got %q", rr.Body.String())
	}
}

func TestProbe(t *testing.T) {
	srv := httptest.NewServer(securityHeaders(newMux()))
	defer srv.Close()

	if err := probe(srv.URL + "/healthz"); err != nil {
		t.Fatalf("probe to healthy server failed: %v", err)
	}
	if err := probe("http://127.0.0.1:1/healthz"); err == nil {
		t.Fatal("probe to closed port should fail")
	}
}

func TestSecurityHeaders(t *testing.T) {
	rr := httptest.NewRecorder()
	securityHeaders(newMux()).ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/", nil))

	for k, want := range map[string]string{
		"X-Content-Type-Options": "nosniff",
		"X-Frame-Options":        "DENY",
	} {
		if got := rr.Header().Get(k); got != want {
			t.Errorf("%s: want %q, got %q", k, want, got)
		}
	}
}
