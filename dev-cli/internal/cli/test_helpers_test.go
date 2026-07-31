package cli

import (
	"encoding/base64"
	"os"
	"testing"

	cocosadapter "github.com/yanXiaoi/playmesh/dev-cli/internal/adapter/cocos"
	scriptadapter "github.com/yanXiaoi/playmesh/dev-cli/internal/adapter/script"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/development"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/packaging"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/scaffold"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/sdk"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/target"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/testutil"
)

type testCredentialProtector struct{}

func (testCredentialProtector) Protect(token string) (string, string, error) {
	return "test-protected", base64.StdEncoding.EncodeToString([]byte(token)), nil
}

func (testCredentialProtector) Unprotect(
	storage string,
	protected string,
) (string, error) {
	data, err := base64.StdEncoding.DecodeString(protected)
	return string(data), err
}

func TestMain(testSuite *testing.M) {
	targetStore = target.NewSystemStoreWithProtector(testCredentialProtector{})
	os.Exit(testSuite.Run())
}

const (
	projectConfigName           = project.ConfigName
	rootIconName                = packaging.RootIconName
	requiredGameSDKVersion      = sdk.RequiredGameVersion
	requiredAppSDKVersion       = sdk.RequiredAppVersion
	developmentCredentialHeader = development.CredentialHeader
	playmeshCLIProjectSchema    = cocosadapter.ProjectSchema
)

type (
	targetConfig              = target.Config
	apiClient                 = target.Client
	sdkBundle                 = sdk.Bundle
	sdkVersions               = sdk.Versions
	projectContext            = project.Context
	cliProjectConfig          = project.Config
	cliIntegrationConfig      = project.IntegrationConfig
	createPromptDefaults      = scaffold.Defaults
	cocosProjectAdapter       = cocosadapter.Cocos
	javascriptProjectAdapter  = scriptadapter.JavaScript
	typescriptProjectAdapter  = scriptadapter.TypeScript
	developmentSessionRequest = development.SessionRequest
)

func saveTarget(config target.Config) error {
	return targetStore.Save(config)
}

func loadTarget() (target.Config, error) {
	return targetStore.Load()
}

func newAPIClient(config target.Config) *target.Client {
	return newTargetClient(config)
}

func writeTestFile(testingContext *testing.T, path, value string) {
	testingContext.Helper()
	testutil.WriteFile(testingContext, path, value)
}

func writeTestBytes(testingContext *testing.T, path string, value []byte) {
	testingContext.Helper()
	testutil.WriteBytes(testingContext, path, value)
}

func validRootIcon(testingContext *testing.T) []byte {
	testingContext.Helper()
	return testutil.ValidPNG(testingContext)
}

var (
	ensureProjectNotInitialized = project.EnsureNotInitialized
	writeProjectConfig          = project.WriteConfig
	resolveProjectContext       = project.Resolve
	currentProjectContext       = project.Current
	projectContextFromConfig    = project.FromConfig
	buildPackage                = packaging.Build
	extractProjectPackage       = packaging.Extract
	installSDK                  = sdk.Install
	installSDKAt                = sdk.InstallAt
	versionsFromSDK             = sdk.VersionsFromProject
	versionsFromSDKAt           = sdk.VersionsAt
	updateManifestSDKVersions   = sdk.UpdateManifestVersions
)
