package packaging

import "github.com/yanXiaoi/playmesh/dev-cli/internal/sdk"

const (
	rootIconName                  = RootIconName
	requiredGameSDKVersion        = sdk.RequiredGameVersion
	requiredAppSDKVersion         = sdk.RequiredAppVersion
	minimumSupportedAppSDKVersion = sdk.MinimumSupportedAppVersion
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
	requireCurrentSDKVersions   = sdk.RequireCurrentVersions
	updateManifestSDKVersions   = sdk.UpdateManifestVersions
)
