package server

import "net/http"

func NewRouter(healthHandler, sessionHandler http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/health", healthHandler)
	mux.Handle("/v1/sessions", sessionHandler)
	mux.Handle("/v1/sessions/", sessionHandler)
	return mux
}
