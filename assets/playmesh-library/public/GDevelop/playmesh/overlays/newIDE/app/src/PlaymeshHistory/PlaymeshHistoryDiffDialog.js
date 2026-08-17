// @flow

import * as React from "react";
import Dialog from "../UI/Dialog";
import Text from "../UI/Text";
import PlaceholderLoader from "../UI/PlaceholderLoader";
import AlertMessage from "../UI/AlertMessage";
import { playmeshMessages } from "../PlaymeshLocalization/PlaymeshMessageKeys";
import {
  filterPlaymeshHistoryDiffEntries,
  groupPlaymeshHistoryDiffEntries,
  HISTORY_DIFF_ENTRY_PAGE_SIZE,
  HISTORY_DIFF_FIELD_PAGE_SIZE,
  HISTORY_DIFF_INITIAL_ENTRY_LIMIT,
  HISTORY_DIFF_INITIAL_FIELD_LIMIT
} from "./PlaymeshHistoryDiffModel";
import type {
  PlaymeshHistoryDiffCategory,
  PlaymeshHistoryDiffEntry,
  PlaymeshHistoryDiffModel,
  PlaymeshHistoryDiffStatus
} from "./PlaymeshHistoryDiffModel";
import { getPlaymeshHistoryResourcePreview } from "./PlaymeshHistoryClient";
import type {
  PlaymeshHistoryDiff,
  PlaymeshHistoryResourceDto,
  PlaymeshHistoryResourcePreview
} from "./PlaymeshHistoryClient";
import diffStyles from "./PlaymeshHistoryDiffDialog.module.css";

const categoryMessage = (category: PlaymeshHistoryDiffCategory): any => {
  if (category === "scenes") return playmeshMessages.historyScenes;
  if (category === "objects") return playmeshMessages.historyObjects;
  if (category === "resources") return playmeshMessages.historyResources;
  return playmeshMessages.historyProjectSettings;
};

const statusMessage = (status: PlaymeshHistoryDiffStatus): any => {
  if (status === "added") return playmeshMessages.historyChangeAdded;
  if (status === "removed") return playmeshMessages.historyChangeRemoved;
  return playmeshMessages.historyChangeModified;
};

const statusLetter = (status: PlaymeshHistoryDiffStatus): string => {
  if (status === "added") return "A";
  if (status === "removed") return "D";
  return "M";
};

const statusColor = (
  status: PlaymeshHistoryDiffStatus,
  theme: any
): string => {
  if (status === "added") return theme.statusIndicator.success;
  if (status === "removed") return theme.statusIndicator.error;
  return theme.statusIndicator.warning;
};

const safePrettyJson = (source: string): string => {
  try {
    return JSON.stringify(JSON.parse(source), null, 2);
  } catch (error) {
    return source;
  }
};

const RawJsonDetails = ({ diff, translate, theme, isMobile }: any) => {
  const [open, setOpen] = React.useState<boolean>(false);
  return (
    <details
      className={diffStyles.rawDetails}
      style={{ borderColor: theme.toolbar.separatorColor }}
      onToggle={(event: any) => setOpen(event.currentTarget.open)}
    >
      <summary className={diffStyles.rawSummary}>
        {translate(playmeshMessages.historyRawJson)}
      </summary>
      {open && (
        <div
          className={diffStyles.rawGrid}
          data-mobile-stacked={isMobile ? "true" : "false"}
        >
          <section>
            <Text noMargin size="sub-title">
              {translate(playmeshMessages.historyBefore)}
            </Text>
            <pre
              className={diffStyles.rawJson}
              style={{ backgroundColor: theme.paper.backgroundColor.dark }}
            >
              {safePrettyJson(diff.before)}
            </pre>
          </section>
          <section>
            <Text noMargin size="sub-title">
              {translate(playmeshMessages.historyAfter)}
            </Text>
            <pre
              className={diffStyles.rawJson}
              style={{ backgroundColor: theme.paper.backgroundColor.dark }}
            >
              {safePrettyJson(diff.after)}
            </pre>
          </section>
        </div>
      )}
    </details>
  );
};

const formatResourceSize = (size: number): string =>
  `${new Intl.NumberFormat().format(size)} B`;

const ResourcePreviewMedia = ({
  preview,
  label,
  onError
}: {
  preview: PlaymeshHistoryResourcePreview,
  label: string,
  onError: () => void
}): React.Node => {
  if (preview.kind === "image") {
    return (
      <img
        className={diffStyles.previewMedia}
        src={preview.url}
        alt={label}
        loading="lazy"
        decoding="async"
        onError={onError}
      />
    );
  }
  if (preview.kind === "audio") {
    return (
      <audio
        className={diffStyles.previewAudio}
        src={preview.url}
        controls
        preload="metadata"
        aria-label={label}
        onError={onError}
      />
    );
  }
  return (
    <video
      className={diffStyles.previewMedia}
      src={preview.url}
      controls
      preload="metadata"
      aria-label={label}
      onError={onError}
    />
  );
};

const ResourceEvidenceCard = ({
  diff,
  side,
  logicalId,
  translate,
  theme
}: {
  diff: PlaymeshHistoryDiff,
  side: "before" | "after",
  logicalId: ?string,
  translate: (key: any, argumentsMap?: any) => string,
  theme: any
}): React.Node => {
  const [failed, setFailed] = React.useState<boolean>(false);
  const revision = side === "before" ? diff.fromRevision : diff.toRevision;
  const sideLabel = translate(
    side === "before"
      ? playmeshMessages.historyBefore
      : playmeshMessages.historyAfter
  );
  const revisionLabel = translate(playmeshMessages.historyResourceRevision, {
    revision
  });
  const label = `${sideLabel} · ${revisionLabel}`;
  const resources = diff.resourceEvidence[side];
  const resource: ?PlaymeshHistoryResourceDto = logicalId
    ? resources.find(item => item.logicalId === logicalId) || null
    : null;
  const preview = getPlaymeshHistoryResourcePreview(diff, side, logicalId);

  return (
    <section
      className={diffStyles.evidenceCard}
      style={{
        borderColor: theme.toolbar.separatorColor,
        backgroundColor: theme.paper.backgroundColor.medium
      }}
      aria-label={label}
      tabIndex={0}
    >
      <header
        className={diffStyles.evidenceHeader}
        style={{ borderColor: theme.toolbar.separatorColor }}
      >
        <span>{sideLabel}</span>
        <span className={diffStyles.evidenceRevision}>{revisionLabel}</span>
      </header>
      <div
        className={diffStyles.previewViewport}
        style={{ backgroundColor: theme.paper.backgroundColor.dark }}
      >
        {!resource ? (
          <span className={diffStyles.previewEmpty}>
            {translate(playmeshMessages.historyResourceNoEvidence)}
          </span>
        ) : !preview ? (
          <span className={diffStyles.previewEmpty}>
            {translate(playmeshMessages.historyResourceUnsupported)}
          </span>
        ) : failed ? (
          <span className={diffStyles.previewEmpty} role="status">
            {translate(playmeshMessages.historyResourceLoadFailed)}
          </span>
        ) : (
          <ResourcePreviewMedia
            preview={preview}
            label={`${label} · ${resource.name || resource.logicalId}`}
            onError={() => setFailed(true)}
          />
        )}
      </div>
      {resource && (
        <dl className={diffStyles.evidenceMetadata}>
          <div>
            <dt>{translate(playmeshMessages.historyResourceMime)}</dt>
            <dd>{resource.mime}</dd>
          </div>
          <div>
            <dt>{translate(playmeshMessages.historyResourceSize)}</dt>
            <dd>{formatResourceSize(resource.size)}</dd>
          </div>
          <div>
            <dt>{translate(playmeshMessages.historyResourceHash)}</dt>
            <dd title={resource.contentHash}>
              {resource.contentHash.slice(0, 12)}…
            </dd>
          </div>
        </dl>
      )}
    </section>
  );
};

const ResourceEvidenceComparison = ({
  diff,
  entry,
  translate,
  theme
}: {
  diff: PlaymeshHistoryDiff,
  entry: PlaymeshHistoryDiffEntry,
  translate: (key: any, argumentsMap?: any) => string,
  theme: any
}): React.Node => (
  <section
    className={diffStyles.evidenceSection}
    aria-label={translate(playmeshMessages.historyResourceEvidence)}
  >
    <Text noMargin size="sub-title">
      {translate(playmeshMessages.historyResourceEvidence)}
    </Text>
    <div className={diffStyles.evidenceGrid}>
      <ResourceEvidenceCard
        diff={diff}
        side="before"
        logicalId={entry.resourceLogicalIdBefore}
        translate={translate}
        theme={theme}
      />
      <ResourceEvidenceCard
        diff={diff}
        side="after"
        logicalId={entry.resourceLogicalIdAfter}
        translate={translate}
        theme={theme}
      />
    </div>
  </section>
);

type Props = {|
  open: boolean,
  loading: boolean,
  error: ?string,
  diff: ?any,
  model: ?PlaymeshHistoryDiffModel,
  isMobile: boolean,
  translate: (key: any, argumentsMap?: any) => string,
  theme: any,
  onClose: () => void
|};

const PlaymeshHistoryDiffDialog = ({
  open,
  loading,
  error,
  diff,
  model,
  isMobile,
  translate,
  theme,
  onClose
}: Props): React.Node => {
  const [query, setQuery] = React.useState("");
  const [category, setCategory] = React.useState<
    "all" | PlaymeshHistoryDiffCategory
  >("all");
  const [status, setStatus] = React.useState<
    "all" | PlaymeshHistoryDiffStatus
  >("all");
  const [entryLimit, setEntryLimit] = React.useState(
    HISTORY_DIFF_INITIAL_ENTRY_LIMIT
  );
  const [fieldLimit, setFieldLimit] = React.useState(
    HISTORY_DIFF_INITIAL_FIELD_LIMIT
  );
  const [selectedId, setSelectedId] = React.useState<?string>(null);
  const [mobilePane, setMobilePane] = React.useState<"tree" | "detail">("tree");
  const [collapsed, setCollapsed] = React.useState<{
    [category: PlaymeshHistoryDiffCategory]: boolean
  }>({});
  const mobileBackButtonRef = React.useRef<?HTMLButtonElement>(null);

  React.useEffect(
    () => {
      if (!open) return;
      setQuery("");
      setCategory("all");
      setStatus("all");
      setEntryLimit(HISTORY_DIFF_INITIAL_ENTRY_LIMIT);
      setFieldLimit(HISTORY_DIFF_INITIAL_FIELD_LIMIT);
      setSelectedId(null);
      setMobilePane("tree");
      setCollapsed({});
    },
    [open, diff && diff.fromRevision, diff && diff.toRevision]
  );

  const filteredEntries = React.useMemo(
    () =>
      model
        ? filterPlaymeshHistoryDiffEntries(model, { query, category, status })
        : [],
    [category, model, query, status]
  );
  const visibleEntries = filteredEntries.slice(0, entryLimit);
  const groups = groupPlaymeshHistoryDiffEntries(visibleEntries);
  const selectedEntry = model
    ? model.entries.find(entry => entry.id === selectedId) || null
    : null;

  React.useEffect(
    () => {
      if (!filteredEntries.length) {
        setSelectedId(null);
        if (isMobile) setMobilePane("tree");
        return;
      }
      if (!filteredEntries.some(entry => entry.id === selectedId)) {
        setSelectedId(filteredEntries[0].id);
        setFieldLimit(HISTORY_DIFF_INITIAL_FIELD_LIMIT);
      }
    },
    [filteredEntries, isMobile, selectedId]
  );

  React.useEffect(
    () => {
      if (!isMobile || mobilePane !== "detail") return;
      const frame = window.requestAnimationFrame(() => {
        if (mobileBackButtonRef.current) mobileBackButtonRef.current.focus();
      });
      return () => window.cancelAnimationFrame(frame);
    },
    [isMobile, mobilePane, selectedId]
  );

  const selectEntry = (entry: PlaymeshHistoryDiffEntry): void => {
    setSelectedId(entry.id);
    setFieldLimit(HISTORY_DIFF_INITIAL_FIELD_LIMIT);
    if (isMobile) setMobilePane("detail");
  };

  const returnToTree = (): void => {
    setMobilePane("tree");
    window.requestAnimationFrame(() => {
      const selectedButton = document.querySelector(
        '#playmesh-history-diff-dialog [data-history-diff-entry="true"][aria-current="true"]'
      );
      if (selectedButton instanceof HTMLElement) selectedButton.focus();
    });
  };

  const onTreeKeyDown = (event: any): void => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const buttons = Array.from(
      event.currentTarget.querySelectorAll('[data-history-diff-entry="true"]')
    );
    const index = buttons.indexOf(event.target);
    if (index < 0 || !buttons.length) return;
    const nextIndex =
      event.key === "ArrowDown"
        ? Math.min(index + 1, buttons.length - 1)
        : Math.max(index - 1, 0);
    const nextButton: any = buttons[nextIndex];
    if (nextButton) nextButton.focus();
    event.preventDefault();
  };

  const title = diff
    ? translate(playmeshMessages.historyComparisonTitle, {
        fromRevision: diff.fromRevision,
        toRevision: diff.toRevision
      })
    : translate(playmeshMessages.historyCompare);

  return (
    <Dialog
      id="playmesh-history-diff-dialog"
      open={open}
      title={title}
      subtitle={translate(playmeshMessages.historyComparisonDescription)}
      onRequestClose={onClose}
      maxWidth="xl"
      fullHeight
      flexColumnBody
    >
      {loading ? (
        <PlaceholderLoader />
      ) : error ? (
        <AlertMessage kind="error">{error}</AlertMessage>
      ) : !diff || !model ? null : (
        <div className={diffStyles.root}>
          <div className={diffStyles.toolbar}>
            <label>
              <span className={diffStyles.srOnly}>
                {translate(playmeshMessages.historySearchLabel)}
              </span>
              <input
                className={diffStyles.searchInput}
                style={{
                  borderColor: theme.toolbar.separatorColor,
                  backgroundColor: theme.paper.backgroundColor.medium
                }}
                type="search"
                value={query}
                placeholder={translate(
                  playmeshMessages.historySearchPlaceholder
                )}
                onChange={event => {
                  setQuery(event.currentTarget.value);
                  setEntryLimit(HISTORY_DIFF_INITIAL_ENTRY_LIMIT);
                }}
              />
            </label>
            <div className={diffStyles.filters}>
              <label>
                <span className={diffStyles.srOnly}>
                  {translate(playmeshMessages.historyCategoryFilter)}
                </span>
                <select
                  className={diffStyles.selectInput}
                  style={{
                    borderColor: theme.toolbar.separatorColor,
                    backgroundColor: theme.paper.backgroundColor.medium
                  }}
                  value={category}
                  onChange={event => {
                    setCategory(event.currentTarget.value);
                    setEntryLimit(HISTORY_DIFF_INITIAL_ENTRY_LIMIT);
                  }}
                >
                  <option value="all">
                    {translate(playmeshMessages.historyAllCategories)}
                  </option>
                  {(([
                    "scenes",
                    "objects",
                    "resources",
                    "project"
                  ]: Array<PlaymeshHistoryDiffCategory>)).map(value => (
                    <option key={value} value={value}>
                      {translate(categoryMessage(value))}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span className={diffStyles.srOnly}>
                  {translate(playmeshMessages.historyStatusFilter)}
                </span>
                <select
                  className={diffStyles.selectInput}
                  style={{
                    borderColor: theme.toolbar.separatorColor,
                    backgroundColor: theme.paper.backgroundColor.medium
                  }}
                  value={status}
                  onChange={event => {
                    setStatus(event.currentTarget.value);
                    setEntryLimit(HISTORY_DIFF_INITIAL_ENTRY_LIMIT);
                  }}
                >
                  <option value="all">
                    {translate(playmeshMessages.historyAllStatuses)}
                  </option>
                  {(([
                    "added",
                    "modified",
                    "removed"
                  ]: Array<PlaymeshHistoryDiffStatus>)).map(value => (
                    <option key={value} value={value}>
                      {statusLetter(value)} · {translate(statusMessage(value))}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          </div>
          <div
            className={diffStyles.summaryLine}
            aria-live="polite"
            aria-atomic="true"
          >
            <span>
              {translate(playmeshMessages.historyVisibleChanges, {
                visible: Math.min(entryLimit, filteredEntries.length),
                total: filteredEntries.length
              })}
            </span>
            <span>
              {translate(playmeshMessages.historyFieldChangesCount, {
                count: model.totalFields
              })}
            </span>
          </div>
          {diff.summary && diff.summary.resources && (
            <Text noMargin color="secondary" size="body-small">
              {translate(playmeshMessages.historyStoredResources, {
                added: diff.summary.resources.added,
                removed: diff.summary.resources.removed,
                modified: diff.summary.resources.changed
              })}
            </Text>
          )}
          <div
            className={diffStyles.workspace}
            style={{ borderColor: theme.toolbar.separatorColor }}
          >
            {(!isMobile || mobilePane === "tree") && (
              <nav
                className={diffStyles.treePane}
                style={{ borderColor: theme.toolbar.separatorColor }}
                aria-label={translate(playmeshMessages.historyChangeTree)}
                onKeyDown={onTreeKeyDown}
              >
                {!groups.length ? (
                  <div className={diffStyles.emptyState}>
                    <Text noMargin color="secondary">
                      {translate(playmeshMessages.historyNoMatchingChanges)}
                    </Text>
                  </div>
                ) : (
                  groups.map(group => {
                    const isCollapsed = !!collapsed[group.category];
                    const groupId = `history-diff-group-${group.category}`;
                    const allCategoryEntries = filteredEntries.filter(
                      entry => entry.category === group.category
                    );
                    const categoryStatusCount = (
                      kind: PlaymeshHistoryDiffStatus
                    ): number =>
                      allCategoryEntries.filter(entry => entry.status === kind)
                        .length;
                    return (
                      <section
                        className={diffStyles.group}
                        key={group.category}
                      >
                        <button
                          className={diffStyles.groupToggle}
                          type="button"
                          aria-expanded={!isCollapsed}
                          aria-controls={groupId}
                          onClick={() =>
                            setCollapsed(previous => ({
                              ...previous,
                              [group.category]: !previous[group.category]
                            }))
                          }
                        >
                          <span>
                            {isCollapsed ? "›" : "⌄"}{" "}
                            {translate(categoryMessage(group.category))}
                          </span>
                          <span className={diffStyles.groupCount}>
                            A {categoryStatusCount("added")} · M{" "}
                            {categoryStatusCount("modified")} · D{" "}
                            {categoryStatusCount("removed")}
                          </span>
                        </button>
                        {!isCollapsed && (
                          <div id={groupId}>
                            {group.entries.map(entry => {
                              const selected = entry.id === selectedId;
                              const color = statusColor(entry.status, theme);
                              return (
                                <button
                                  key={entry.id}
                                  className={diffStyles.entryButton}
                                  type="button"
                                  data-history-diff-entry="true"
                                  aria-current={selected ? "true" : undefined}
                                  title={entry.path}
                                  style={
                                    selected
                                      ? {
                                          backgroundColor:
                                            theme.paper.backgroundColor.medium,
                                          boxShadow: `inset 3px 0 0 ${color}`
                                        }
                                      : undefined
                                  }
                                  onClick={() => selectEntry(entry)}
                                >
                                  <span
                                    className={diffStyles.status}
                                    style={{ color }}
                                    aria-hidden="true"
                                  >
                                    {statusLetter(entry.status)}
                                  </span>
                                  <span className={diffStyles.srOnly}>
                                    {translate(statusMessage(entry.status))}
                                  </span>
                                  <span className={diffStyles.entryName}>
                                    {entry.path}
                                  </span>
                                  <span className={diffStyles.fieldCount}>
                                    {entry.fields.length || "—"}
                                  </span>
                                </button>
                              );
                            })}
                          </div>
                        )}
                      </section>
                    );
                  })
                )}
                {visibleEntries.length < filteredEntries.length && (
                  <button
                    className={diffStyles.loadMoreButton}
                    type="button"
                    onClick={() =>
                      setEntryLimit(
                        limit => limit + HISTORY_DIFF_ENTRY_PAGE_SIZE
                      )
                    }
                  >
                    {translate(playmeshMessages.historyLoadMoreChanges, {
                      count: Math.min(
                        HISTORY_DIFF_ENTRY_PAGE_SIZE,
                        filteredEntries.length - visibleEntries.length
                      )
                    })}
                  </button>
                )}
              </nav>
            )}
            {(!isMobile || mobilePane === "detail") && (
              <section
                className={diffStyles.detailPane}
                aria-label={translate(playmeshMessages.historyChangeDetails)}
              >
                {isMobile && (
                  <button
                    ref={mobileBackButtonRef}
                    className={diffStyles.mobileBackButton}
                    type="button"
                    onClick={returnToTree}
                  >
                    ← {translate(playmeshMessages.historyBackToChanges)}
                  </button>
                )}
                {!selectedEntry ? (
                  <div className={diffStyles.emptyState}>
                    <Text noMargin color="secondary">
                      {translate(playmeshMessages.historySelectChange)}
                    </Text>
                  </div>
                ) : (
                  <React.Fragment>
                    <header
                      className={diffStyles.detailHeader}
                      style={{ borderColor: theme.toolbar.separatorColor }}
                    >
                      <div className={diffStyles.detailPath}>
                        <Text noMargin size="sub-title">
                          {selectedEntry.path}
                        </Text>
                        {selectedEntry.resourceKind && (
                          <Text noMargin color="secondary">
                            {selectedEntry.resourceKind}
                          </Text>
                        )}
                      </div>
                      <span
                        className={diffStyles.status}
                        style={{
                          color: statusColor(selectedEntry.status, theme)
                        }}
                        aria-label={translate(
                          statusMessage(selectedEntry.status)
                        )}
                      >
                        {statusLetter(selectedEntry.status)}
                      </span>
                    </header>
                    {selectedEntry.category === "resources" && (
                      <ResourceEvidenceComparison
                        key={selectedEntry.id}
                        diff={diff}
                        entry={selectedEntry}
                        translate={translate}
                        theme={theme}
                      />
                    )}
                    {!selectedEntry.fields.length ? (
                      <div className={diffStyles.emptyState}>
                        <Text noMargin color="secondary">
                          {translate(playmeshMessages.historyNoEntryFields)}
                        </Text>
                      </div>
                    ) : (
                      <div className={diffStyles.fieldList}>
                        {selectedEntry.fields
                          .slice(0, fieldLimit)
                          .map((field, index) => {
                            const color = statusColor(field.kind, theme);
                            return (
                              <article
                                className={diffStyles.fieldCard}
                                key={`${field.path}:${index}`}
                                style={{
                                  borderColor: color,
                                  backgroundColor:
                                    theme.paper.backgroundColor.medium
                                }}
                              >
                                <div
                                  className={diffStyles.fieldPath}
                                  style={{ color }}
                                >
                                  {translate(statusMessage(field.kind))} ·{" "}
                                  {field.path}
                                </div>
                                <div className={diffStyles.fieldValues}>
                                  <div className={diffStyles.valueBlock}>
                                    <span className={diffStyles.valueLabel}>
                                      {translate(
                                        playmeshMessages.historyBefore
                                      )}
                                    </span>
                                    <textarea
                                      className={diffStyles.value}
                                      style={{
                                        backgroundColor:
                                          theme.paper.backgroundColor.dark
                                      }}
                                      value={field.before || "—"}
                                      readOnly
                                      rows={Math.min(
                                        8,
                                        Math.max(
                                          1,
                                          (field.before || "—").split("\n")
                                            .length
                                        )
                                      )}
                                      spellCheck={false}
                                      aria-label={`${translate(
                                        playmeshMessages.historyBefore
                                      )} · ${field.path}`}
                                      data-history-diff-value="before"
                                    />
                                  </div>
                                  <div className={diffStyles.valueBlock}>
                                    <span className={diffStyles.valueLabel}>
                                      {translate(playmeshMessages.historyAfter)}
                                    </span>
                                    <textarea
                                      className={diffStyles.value}
                                      style={{
                                        backgroundColor:
                                          theme.paper.backgroundColor.dark
                                      }}
                                      value={field.after || "—"}
                                      readOnly
                                      rows={Math.min(
                                        8,
                                        Math.max(
                                          1,
                                          (field.after || "—").split("\n")
                                            .length
                                        )
                                      )}
                                      spellCheck={false}
                                      aria-label={`${translate(
                                        playmeshMessages.historyAfter
                                      )} · ${field.path}`}
                                      data-history-diff-value="after"
                                    />
                                  </div>
                                </div>
                              </article>
                            );
                          })}
                        {fieldLimit < selectedEntry.fields.length && (
                          <button
                            className={diffStyles.loadMoreButton}
                            type="button"
                            onClick={() =>
                              setFieldLimit(
                                limit => limit + HISTORY_DIFF_FIELD_PAGE_SIZE
                              )
                            }
                          >
                            {translate(playmeshMessages.historyLoadMoreFields, {
                              count: Math.min(
                                HISTORY_DIFF_FIELD_PAGE_SIZE,
                                selectedEntry.fields.length - fieldLimit
                              )
                            })}
                          </button>
                        )}
                      </div>
                    )}
                    {model.fieldsTruncated && (
                      <Text color="secondary" size="body-small">
                        {translate(
                          playmeshMessages.historyFieldChangesTruncated
                        )}
                      </Text>
                    )}
                    <RawJsonDetails
                      diff={diff}
                      translate={translate}
                      theme={theme}
                      isMobile={isMobile}
                    />
                  </React.Fragment>
                )}
              </section>
            )}
          </div>
        </div>
      )}
    </Dialog>
  );
};

export default PlaymeshHistoryDiffDialog;
