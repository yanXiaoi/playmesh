// @flow

import * as React from 'react';
import { MarketingPlansStoreContext } from '../MarketingPlans/MarketingPlansStoreContext';
import { ProductLicenseStoreContext } from '../AssetStore/ProductLicense/ProductLicenseStoreContext';
import {
  CreditsPackageStoreContext,
  initialCreditsPackageStoreState,
} from '../AssetStore/CreditsPackages/CreditsPackageStoreContext';

type Props = {|
  children: React.Node,
|};

const noOperation = (): void => {};

// PlayMesh has no official GDevelop commerce, credit or product-license
// surface. These providers keep the official Context contracts intact while
// making every fetch entry point inert at the lowest mounted Provider seam.
// They only return children and therefore cannot close/reset a gdProject or
// change the active editor container.
export const PlaymeshMarketingPlansStoreStateProvider = ({
  children,
}: Props): React.Node => (
  <MarketingPlansStoreContext.Provider
    value={{
      fetchMarketingPlans: noOperation,
      marketingPlans: [],
      error: null,
    }}
  >
    {children}
  </MarketingPlansStoreContext.Provider>
);

export const PlaymeshProductLicenseStoreStateProvider = ({
  children,
}: Props): React.Node => (
  <ProductLicenseStoreContext.Provider
    value={{
      fetchProductLicenses: noOperation,
      assetPackLicenses: [],
      gameTemplateLicenses: [],
      error: null,
    }}
  >
    {children}
  </ProductLicenseStoreContext.Provider>
);

export const PlaymeshCreditsPackageStoreStateProvider = ({
  children,
}: Props): React.Node => (
  <CreditsPackageStoreContext.Provider
    value={{
      ...initialCreditsPackageStoreState,
      fetchCreditsPackages: noOperation,
      creditsPackageListingDatas: [],
    }}
  >
    {children}
  </CreditsPackageStoreContext.Provider>
);
