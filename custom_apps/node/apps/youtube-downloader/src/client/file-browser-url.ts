import type { CurrentUser } from '../shared/types.js';

export const buildFileBrowserUrl = (
  outputFolder: string | undefined,
  currentUser: CurrentUser | undefined,
  location: Pick<Location, 'hostname' | 'protocol'> = window.location,
): string | undefined => {
  if (!outputFolder) {
    return undefined;
  }
  const browserPath = fileBrowserPathFor(outputFolder, currentUser);
  const encodedBrowserPath = browserPath ? encodePathSegments(browserPath) : undefined;
  const template = currentUser?.fileBrowserUrlTemplate;
  if (template && encodedBrowserPath) {
    if (template.includes('%path%')) {
      return template.replaceAll('%path%', encodedBrowserPath);
    }
    return `${template.replace(/\/$/, '')}/files/${encodedBrowserPath}/`;
  }
  if (template) {
    return `${template.replace(/\/$/, '')}/#/?path=${encodeURIComponent(outputFolder)}`;
  }

  const hostParts = location.hostname.split('.');
  const filesHost = hostParts.length > 1 ? `files.${hostParts.slice(1).join('.')}` : `files.${location.hostname}`;
  if (encodedBrowserPath) {
    return `${location.protocol}//${filesHost}/files/${encodedBrowserPath}/`;
  }
  return `${location.protocol}//${filesHost}/#/?path=${encodeURIComponent(outputFolder)}`;
};

const pathWithoutTrailingSlash = (value: string): string => value.replace(/\/+$/, '');

const trimSlashes = (value: string): string => value.replace(/^\/+|\/+$/g, '');

const pathRelativeTo = (root: string, path: string): string | undefined => {
  const cleanRoot = pathWithoutTrailingSlash(root);
  const cleanPath = pathWithoutTrailingSlash(path);
  if (cleanPath === cleanRoot) {
    return '';
  }
  return cleanPath.startsWith(`${cleanRoot}/`) ? cleanPath.slice(cleanRoot.length + 1) : undefined;
};

const joinBrowserPath = (...parts: string[]): string => parts.map(trimSlashes).filter(Boolean).join('/');

const fileBrowserPathFor = (outputFolder: string, currentUser?: CurrentUser): string | undefined => {
  const roots = currentUser?.fileBrowserPathRoots;
  if (!currentUser || !roots) {
    return undefined;
  }

  const personalRelative = pathRelativeTo(`${roots.usersRoot}/${currentUser.username}`, outputFolder);
  if (personalRelative != null) {
    return personalRelative;
  }

  const sharedRoots = [...roots.sharedRoots].sort((left, right) => right.serverRoot.length - left.serverRoot.length);
  for (const root of sharedRoots) {
    const sharedRelative = pathRelativeTo(root.serverRoot, outputFolder);
    if (sharedRelative != null) {
      return joinBrowserPath(root.browserPath, sharedRelative);
    }
  }

  return undefined;
};

const encodePathSegments = (path: string): string => path.split('/').map(encodeURIComponent).join('/');
