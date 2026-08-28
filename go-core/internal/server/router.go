package server

import "net/http"

func NewRouter(healthHandler, sessionHandler http.Handler, optionalHandlers ...http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/health", healthHandler)
	mux.Handle("/v1/sessions", sessionHandler)
	mux.Handle("/v1/sessions/", sessionHandler)
	if len(optionalHandlers) > 0 && optionalHandlers[0] != nil {
		mux.Handle("/v1/relay/", optionalHandlers[0])
	}
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
