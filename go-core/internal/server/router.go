package server

import "net/http"

func NewRouter(healthHandler, sessionHandler http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/health", healthHandler)
	mux.Handle("/v1/sessions", sessionHandler)
	mux.Handle("/v1/sessions/", sessionHandler)
	return allowGameSDKOrigins(mux)
}

func allowGameSDKOrigins(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Access-Control-Allow-Origin", "*")
		writer.Header().Set(
			"Access-Control-Allow-Headers",
			"Authorization, Content-Type",
		)
		writer.Header().Set(
			"Access-Control-Allow-Methods",
			"GET, POST, PATCH, DELETE, OPTIONS",
		)
		if request.Header.Get("Access-Control-Request-Private-Network") == "true" {
			writer.Header().Set("Access-Control-Allow-Private-Network", "true")
		}
		if request.Method == http.MethodOptions {
			writer.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(writer, request)
	})
}
