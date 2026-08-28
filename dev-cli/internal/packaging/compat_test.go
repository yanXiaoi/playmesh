package packaging

import "github.com/yanXiaoi/playmesh/dev-cli/internal/sdk"

const (
	rootIconName           = RootIconName
	requiredGameSDKVersion = "4.1.0"
	requiredAppSDKVersion  = "3.3.0"
)

type sdkBundle = sdk.Bundle
type sdkVersions = sdk.Versions

var (
	buildPackage                = Build
	extractProjectPackage       = Extract
	buildDevelopmentBasePackage = BuildDevelopmentBase
	installSDK                  = sdk.Install
	installSDKAt                = sdk.InstallAt
	versionsFromSDK             = sdk.VersionsFromProject
	versionsFromSDKAt           = sdk.VersionsAt
	updateManifestSDKVersions   = sdk.UpdateManifestVersions
)
