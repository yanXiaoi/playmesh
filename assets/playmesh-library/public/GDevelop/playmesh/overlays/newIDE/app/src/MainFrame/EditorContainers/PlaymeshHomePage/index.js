// @flow
import * as React from 'react';
import { type RenderEditorContainerPropsWithRef } from '../BaseEditor';
import { HomePageMenu } from '../HomePage/HomePageMenu';
import PlaymeshCreateSection from './PlaymeshCreateSection';
import PlaymeshHomePageHeader from './PlaymeshHomePageHeader';
import PlaymeshDistributionNotice from './PlaymeshDistributionNotice';
import { setEditorHotReloadNeeded } from '../../../EmbeddedGame/EmbeddedGameFrame';
import { usePlaymeshLocalization } from '../../../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../../../PlaymeshLocalization/PlaymeshMessageKeys';
import RouterContext from '../../RouterContext';
import { useResponsiveWindowSize } from '../../../UI/Responsive/ResponsiveWindowMeasurer';

const noop = () => {};
const playmeshHomePageRouteArguments = [
  'play',
  'learn',
  'build',
  'create',
  'games-dashboard',
  'asset-store',
  'store',
  'education',
];

const styles = {
  container: {
    display: 'flex',
    margin: 0,
    flex: 1,
    minHeight: 0,
    width: '100%',
  },
  desktopContainer: {
    flexDirection: 'row-reverse',
  },
  mobileContainer: {
    // HomePageMenu renders a full-width bottom bar on mobile. Keeping the
    // desktop row here makes that bar compete with the page for horizontal
    // space and collapses the project section to a few characters wide.
    flexDirection: 'column',
  },
  scrollableContainer: {
    display: 'flex',
    position: 'relative',
    flexDirection: 'column',
    alignItems: 'stretch',
    flex: 1,
    minWidth: 0,
    overflowY: 'auto',
  },
};

const PlaymeshHomePage = React.forwardRef<any, any>((props, ref) => {
  const {
    setToolbar,
    setGamesPlatformFrameShown,
    onOpenLanguageDialog,
    onOpenVersionHistory,
    onSave,
    canSave,
    project,
    fileMetadata,
    onOpenRecentFile,
    onOpenNewProjectSetupDialog,
    canOpen,
    onOpenPreferences,
    closeProject,
  } = props;
  const { t: playmeshT } = usePlaymeshLocalization();
  const { isMobile } = useResponsiveWindowSize();
  const { routeArguments, removeRouteArguments } = React.useContext(
    RouterContext
  );
  const [distributionNoticeOpen, setDistributionNoticeOpen] = React.useState(
    false
  );

  // The official HomePage consumes this one-shot route after selecting its tab.
  // Playmesh replaces that component, so it must preserve the same lifecycle.
  // Otherwise any later RouterContext update can replay useHomePageSwitch and
  // unexpectedly replace an editor tab with the project list.
  React.useEffect(
    () => {
      const initialDialog = routeArguments['initial-dialog'];
      if (!initialDialog) return;

      // $FlowFixMe[incompatible-type]
      if (!playmeshHomePageRouteArguments.includes(initialDialog)) return;

      removeRouteArguments(['initial-dialog']);
    },
    [routeArguments, removeRouteArguments]
  );

  React.useLayoutEffect(
    () => {
      setToolbar(
        <PlaymeshHomePageHeader
          hasProject={!!project}
          onOpenLanguageDialog={onOpenLanguageDialog}
          onOpenVersionHistory={onOpenVersionHistory}
          onSave={onSave}
          canSave={canSave}
        />
      );
      setGamesPlatformFrameShown({ shown: false, isMobile: false });
    },
    [
      setToolbar,
      setGamesPlatformFrameShown,
      onOpenLanguageDialog,
      onOpenVersionHistory,
      onSave,
      canSave,
      project,
    ]
  );

  React.useImperativeHandle(ref, () => ({
    getProject: () => undefined,
    updateToolbar: noop,
    forceUpdateEditor: noop,
    onEventsBasedObjectChildrenEdited: noop,
    onSceneObjectEdited: noop,
    onSceneObjectsDeleted: noop,
    onSceneEventsModifiedOutsideEditor: noop,
    notifyChangesToInGameEditor: setEditorHotReloadNeeded,
    switchInGameEditorIfNoHotReloadIsNeeded: noop,
    onInstancesModifiedOutsideEditor: noop,
    onObjectsModifiedOutsideEditor: noop,
    onObjectGroupsModifiedOutsideEditor: noop,
  }));

  return (
    <div
      style={{
        ...styles.container,
        ...(isMobile ? styles.mobileContainer : styles.desktopContainer),
      }}
    >
      <div style={styles.scrollableContainer}>
        <PlaymeshCreateSection
          project={project}
          currentFileMetadata={fileMetadata}
          onOpenProject={onOpenRecentFile}
          onOpenNewProjectSetupDialog={onOpenNewProjectSetupDialog}
          canOpen={canOpen}
          closeProject={closeProject}
        />
      </div>
      <HomePageMenu
        activeTab="create"
        setActiveTab={noop}
        onOpenPreferences={onOpenPreferences}
        aboutLabel={playmeshT(playmeshMessages.homeAboutEditor)}
        onOpenAbout={() => setDistributionNoticeOpen(true)}
      />
      <PlaymeshDistributionNotice
        open={distributionNoticeOpen}
        onClose={() => setDistributionNoticeOpen(false)}
      />
    </div>
  );
});

export const renderHomePageContainer = (
  props: RenderEditorContainerPropsWithRef
): React.MixedElement => <PlaymeshHomePage ref={props.ref} {...props} />;
