// @flow
import {
  type EventsFunctionCodeWriter,
  type EventsFunctionCodeWriterCallbacks,
} from '..';
import slugs from 'slugs';

const sessionPrefix = `${Date.now().toString(36)}-${Math.random()
  .toString(36)
  .slice(2, 10)}`;

const getPathFor = (codeNamespace: string): string => {
  const filename = `${sessionPrefix}-${slugs(codeNamespace)}.js`;
  return `${window.location.origin}/dev/api/gdevelop/generated-code/${encodeURIComponent(
    filename
  )}`;
};

const writeCode = async (path: string, code: string): Promise<void> => {
  const response = await fetch(path, {
    method: 'PUT',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: { 'Content-Type': 'text/javascript; charset=utf-8' },
    body: code,
  });
  if (!response.ok) {
    throw new Error(
      `Playmesh 无法暂存 GDevelop 事件代码（HTTP ${response.status}）。`
    );
  }
};

/**
 * 将当前预览或导出的事件函数代码暂存在 App 会话内存中。
 * 项目事实仍只写入 playmesh-library/GDevelop/packages；浏览器不创建预览数据库。
 */
export const makePlaymeshEventsFunctionCodeWriter = ({
  onWriteFile,
}: EventsFunctionCodeWriterCallbacks): EventsFunctionCodeWriter => {
  const write = (codeNamespace: string, code: string): Promise<void> => {
    const path = getPathFor(codeNamespace);
    onWriteFile({ includeFile: path, content: code });
    return writeCode(path, code);
  };

  return {
    getIncludeFileFor: (codeNamespace: string) => getPathFor(codeNamespace),
    writeFunctionCode: write,
    writeBehaviorCode: write,
    writeObjectCode: write,
  };
};

