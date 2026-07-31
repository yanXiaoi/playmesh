package credential

type Protector interface {
	Protect(token string) (storage string, protected string, err error)
	Unprotect(storage string, protected string) (token string, err error)
}

type PlatformProtector struct{}

func (PlatformProtector) Protect(token string) (string, string, error) {
	return platformProtect(token)
}

func (PlatformProtector) Unprotect(storage, protected string) (string, error) {
	return platformUnprotect(storage, protected)
}
