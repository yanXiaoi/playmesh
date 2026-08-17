// @flow
import * as React from 'react';
import Dialog from '../../../UI/Dialog';
import FlatButton from '../../../UI/FlatButton';
import Paper from '../../../UI/Paper';
import Text from '../../../UI/Text';
import AlertMessage from '../../../UI/AlertMessage';
import GDevelopThemeContext from '../../../UI/Theme/GDevelopThemeContext';
import { ColumnStackLayout } from '../../../UI/Layout';
import { usePlaymeshLocalization } from '../../../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../../../PlaymeshLocalization/PlaymeshMessageKeys';

type Props = {|
  open: boolean,
  onClose: () => void,
|};

const styles = {
  identity: {
    display: 'flex',
    alignItems: 'flex-start',
    gap: 12,
    paddingBottom: 16,
    borderBottomWidth: 1,
    borderBottomStyle: 'solid',
  },
  identityLogo: {
    display: 'block',
    flex: '0 0 auto',
    width: 32,
    height: 32,
    objectFit: 'contain',
    background: 'transparent',
    border: 0,
    boxShadow: 'none',
  },
  noticeSection: {
    marginTop: 18,
    minHeight: 0,
  },
  noticeSectionHeader: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    flexWrap: 'wrap',
    gap: 8,
  },
  noticeActions: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'flex-end',
    flexWrap: 'wrap',
    gap: 4,
  },
  noticeContent: {
    margin: 0,
    padding: 12,
    maxHeight: 'min(52vh, 520px)',
    overflow: 'auto',
    whiteSpace: 'pre-wrap',
    overflowWrap: 'anywhere',
    fontFamily: 'monospace',
    fontSize: 12,
    lineHeight: 1.55,
    userSelect: 'text',
  },
  status: {
    minHeight: 20,
    marginTop: 6,
  },
};

const PlaymeshDistributionNotice = ({ open, onClose }: Props): React.Node => {
  const gdevelopTheme = React.useContext(GDevelopThemeContext);
  const { t: playmeshT } = usePlaymeshLocalization();
  const [expanded, setExpanded] = React.useState(false);
  const [loading, setLoading] = React.useState(false);
  const [notices, setNotices] = React.useState<?string>(null);
  const [error, setError] = React.useState<?string>(null);
  const [copyStatus, setCopyStatus] = React.useState<
    'idle' | 'copied' | 'failed'
  >('idle');

  const loadNotices = React.useCallback(async () => {
    if (loading || notices !== null) return;
    setLoading(true);
    setError(null);
    try {
      const response = await window.fetch('./THIRD_PARTY_NOTICES.md', {
        cache: 'no-store',
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const source = await response.text();
      if (!source.includes('GDevelop MIT license')) {
        throw new Error('notice content is incomplete');
      }
      setNotices(source);
    } catch (fetchError) {
      setError(
        fetchError instanceof Error ? fetchError.message : String(fetchError)
      );
    } finally {
      setLoading(false);
    }
  }, [loading, notices]);

  const toggleNotices = React.useCallback(() => {
    setCopyStatus('idle');
    if (expanded) {
      setExpanded(false);
      return;
    }
    setExpanded(true);
    loadNotices();
  }, [expanded, loadNotices]);

  const copyNotices = React.useCallback(async () => {
    if (!notices) return;
    try {
      const clipboard: any =
        window.navigator && (window.navigator: any).clipboard;
      if (!clipboard || typeof clipboard.writeText !== 'function') {
        throw new Error('clipboard unavailable');
      }
      await clipboard.writeText(notices);
      setCopyStatus('copied');
    } catch (clipboardError) {
      setCopyStatus('failed');
    }
  }, [notices]);

  const closeDialog = React.useCallback(() => {
    setExpanded(false);
    setCopyStatus('idle');
    onClose();
  }, [onClose]);

  return (
    <Dialog
      open={open}
      id="playmesh-editor-about-dialog"
      title={playmeshT(playmeshMessages.homeAboutEditor)}
      actions={[
        <FlatButton
          key="close"
          label={playmeshT(playmeshMessages.homeNoticesClose)}
          onClick={closeDialog}
        />,
      ]}
      onRequestClose={closeDialog}
      maxWidth="md"
      fullHeight
      flexColumnBody
      forceScrollVisible
    >
      <ColumnStackLayout noMargin>
        <div
          style={{
            ...styles.identity,
            borderBottomColor: gdevelopTheme.home.separator.color,
          }}
        >
          <img
            src="./playmesh-logo.png"
            alt=""
            aria-hidden="true"
            style={styles.identityLogo}
          />
          <ColumnStackLayout noMargin>
            <Text noMargin size="sub-title">
              {playmeshT(playmeshMessages.homeVisualEditorName)}
            </Text>
            <Text noMargin color="secondary">
              {playmeshT(playmeshMessages.homeUnofficialNotice)}
            </Text>
          </ColumnStackLayout>
        </div>

        <section
          style={styles.noticeSection}
          aria-label={playmeshT(playmeshMessages.homeNoticesTitle)}
        >
          <div style={styles.noticeSectionHeader}>
            <Text noMargin size="sub-title">
              {playmeshT(playmeshMessages.homeNoticesTitle)}
            </Text>
            <div style={styles.noticeActions}>
              {expanded && notices && (
                <FlatButton
                  label={playmeshT(playmeshMessages.homeNoticesCopy)}
                  onClick={copyNotices}
                />
              )}
              <FlatButton
                label={playmeshT(
                  expanded
                    ? playmeshMessages.homeNoticesHide
                    : playmeshMessages.homeNoticesShow
                )}
                onClick={toggleNotices}
              />
            </div>
          </div>

          {expanded && (
            <div id="playmesh-complete-notices">
              {error ? (
                <ColumnStackLayout noMargin>
                  <AlertMessage kind="error">
                    {playmeshT(playmeshMessages.homeNoticesLoadFailed, {
                      error,
                    })}
                  </AlertMessage>
                  <FlatButton
                    label={playmeshT(playmeshMessages.homeNoticesRetry)}
                    onClick={loadNotices}
                    disabled={loading}
                  />
                </ColumnStackLayout>
              ) : notices ? (
                <Paper variant="outlined" background="dark">
                  <pre
                    tabIndex={0}
                    aria-label={playmeshT(playmeshMessages.homeNoticesTitle)}
                    style={styles.noticeContent}
                  >
                    {notices}
                  </pre>
                </Paper>
              ) : (
                <Text color="secondary">
                  {playmeshT(playmeshMessages.homeNoticesLoading)}
                </Text>
              )}
            </div>
          )}

          <div style={styles.status} role="status" aria-live="polite">
            {copyStatus === 'copied'
              ? playmeshT(playmeshMessages.homeNoticesCopied)
              : copyStatus === 'failed'
              ? playmeshT(playmeshMessages.homeNoticesCopyFailed)
              : ''}
          </div>
        </section>
      </ColumnStackLayout>
    </Dialog>
  );
};

export default PlaymeshDistributionNotice;
