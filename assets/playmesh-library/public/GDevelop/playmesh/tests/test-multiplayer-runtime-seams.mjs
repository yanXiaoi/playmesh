import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.dirname(testDirectory);
const sourcePolicyPath = path.join(
  playmeshDirectory,
  'scripts',
  'apply-source-policy.mjs'
);
const manifestPath = path.join(
  playmeshDirectory,
  'source-policy-output-manifest.json'
);
const sourcePolicy = await readFile(sourcePolicyPath, 'utf8');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const allowPendingOutputManifest = process.argv.includes(
  '--allow-pending-output-manifest'
);

const lockedFiles = [
  {
    relativePath: 'Extensions/Multiplayer/peerJsHelper.ts',
    upstreamGitBlobSha: 'dfd4a73aa4b272e6eccea2aa3f288b5778ca76b5',
  },
  {
    relativePath: 'Extensions/Multiplayer/multiplayertools.ts',
    upstreamGitBlobSha: 'ffd474906ff9b3c8d01ba46b499347656f31558f',
  },
  {
    relativePath: 'Extensions/Multiplayer/multiplayercomponents.ts',
    upstreamGitBlobSha: '1ba58f95a6f59add9033724c5ef601c5f2b02696',
  },
  {
    relativePath:
      'Extensions/PlayerAuthentication/playerauthenticationtools.ts',
    upstreamGitBlobSha: 'c3aabe47feb2782d560ff45af8915cc87eebbd6f',
  },
  {
    relativePath:
      'Extensions/PlayerAuthentication/playerauthenticationcomponents.ts',
    upstreamGitBlobSha: '8352080d4345e9fae45b1940ee1317e2875e8735',
  },
];
const unchangedOfficialFiles = [
  {
    relativePath: 'Extensions/Multiplayer/messageManager.ts',
    gitBlobSha: '146a9b0bf321c71f3a227b10cf97028d539ae52e',
  },
  {
    relativePath: 'Extensions/Multiplayer/peer.js',
    gitBlobSha: '0abdf49a5335afc03c8977d7072a9755a27a7b94',
  },
  {
    relativePath: 'Extensions/Multiplayer/multiplayerVariablesManager.ts',
    gitBlobSha: '6bfc0160afe40ffe09124b6203d9fe3c5eb56677',
  },
  {
    relativePath:
      'Extensions/Multiplayer/multiplayerobjectruntimebehavior.ts',
    gitBlobSha: '05d77a67b5b70661e0fd30c33e02bc39094ad184',
  },
];

for (const lockedFile of lockedFiles) {
  assert.equal(
    sourcePolicy.split(`'${lockedFile.relativePath}'`).length - 1,
    1,
    `${lockedFile.relativePath} must have one source-policy patch`
  );
  assert.equal(
    sourcePolicy.split(
      `expectedGitBlobSha: '${lockedFile.upstreamGitBlobSha}'`
    ).length - 1,
    1,
    `${lockedFile.relativePath} must lock its exact official preimage`
  );
  const records = manifest.patchedOfficialFiles.filter(
    entry => entry.relativePath === lockedFile.relativePath
  );
  assert.equal(records.length, 1);
  assert.equal(records[0].upstreamGitBlobSha, lockedFile.upstreamGitBlobSha);
}

for (const marker of [
  "Symbol.for('playmesh.runtime.backends.v1')",
  "feature: 'multiplayer'",
  "feature: 'playerAuthentication'",
  'createOfficialPeer()',
  'createOfficialLobbyControlFacade()',
  'configureOfficialLobbyFrame(iframe)',
  'typeof backend.consumeOfficialLobbyFrameMessage',
  'handleOfficialLobbyFrameMessage(',
  'postOfficialLobbyFrameMessage(iframe, message)',
  "request('checkGameRegistration', { gameId })",
  'checkGameRegistration({ gameId })',
  'createOfficialAuthenticationControlFacade()',
  'configureOfficialAuthenticationFrame(iframe)',
  'consumeOfficialAuthenticationFrameMessage(event)',
  'readOfficialIdentity(identityKey)',
  'writeOfficialIdentity(identityKey, identityRecord)',
  'removeOfficialIdentity(identityKey)',
]) {
  assert.ok(sourcePolicy.includes(marker), `missing source seam marker: ${marker}`);
}

for (const officialFile of unchangedOfficialFiles) {
  assert.ok(sourcePolicy.includes(`'${officialFile.relativePath}'`));
  assert.ok(sourcePolicy.includes(`'${officialFile.gitBlobSha}'`));
}

const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex !== -1) {
  const sourceRoot = process.argv[sourceArgumentIndex + 1];
  if (!sourceRoot) throw new Error('--source requires a patched GDevelop root');

  const sources = new Map();
  for (const lockedFile of lockedFiles) {
    const bytes = await readFile(
      path.join(sourceRoot, ...lockedFile.relativePath.split('/'))
    );
    const digest = createHash('sha256').update(bytes).digest('hex');
    const record = manifest.patchedOfficialFiles.find(
      entry => entry.relativePath === lockedFile.relativePath
    );
    if (
      allowPendingOutputManifest &&
      record.postPatchSha256 === 'pending'
    ) {
      console.warn(
        `PENDING OUTPUT MANIFEST: ${lockedFile.relativePath} must be frozen as ${digest}`
      );
    } else {
      assert.equal(record.postPatchSha256, digest, lockedFile.relativePath);
    }
    sources.set(lockedFile.relativePath, bytes.toString('utf8'));
  }
  for (const officialFile of unchangedOfficialFiles) {
    const bytes = await readFile(
      path.join(sourceRoot, ...officialFile.relativePath.split('/'))
    );
    const header = Buffer.from(`blob ${bytes.length}\0`, 'utf8');
    const gitBlobSha = createHash('sha1')
      .update(header)
      .update(bytes)
      .digest('hex');
    assert.equal(gitBlobSha, officialFile.gitBlobSha, officialFile.relativePath);
  }

  const peerHelper = sources.get('Extensions/Multiplayer/peerJsHelper.ts');
  assert.equal(
    peerHelper.split('peer = new Peer(peerConfig);').length - 1,
    0,
    'the official direct Peer construction expression must be replaced'
  );
  assert.equal(
    peerHelper.split('playmeshBackend.createOfficialPeer()').length - 1,
    1
  );
  assert.equal(
    peerHelper.split('export const sendDataTo').length - 1,
    1,
    'the official helper API must not be reimplemented'
  );

  const multiplayerTools = sources.get(
    'Extensions/Multiplayer/multiplayertools.ts'
  );
  assert.equal(
    multiplayerTools.includes('_websocket = new WebSocket(wsUrl.toString())'),
    false
  );
  assert.equal(
    multiplayerTools.split(
      '_websocket = createPlaymeshLobbyControl(wsUrl.toString())'
    ).length - 1,
    1
  );
  assert.equal(
    multiplayerTools.includes("playmeshBackend ? 'about:blank' : targetUrl"),
    false,
    'lobby navigation must be replaced only at the component iframe seam'
  );
  assert.equal(
    multiplayerTools.match(/postOfficialLobbyFrameMessage\(\s*lobbiesIframe,/g)
      ?.length,
    5,
    'every official lobby frame output must pass the private capability'
  );
  assert.match(
    multiplayerTools,
    /handleOfficialLobbyFrameMessage\([\s\S]*checkOrigin: false/
  );
  for (const officialStateFunction of [
    'export const authenticateAndQuickJoinLobby',
    'export const leaveGameLobby',
    'export const handleLobbyGameEnded',
    'const handleGameStartedEvent',
  ]) {
    assert.equal(
      multiplayerTools.split(officialStateFunction).length - 1,
      1,
      `${officialStateFunction} must remain the sole official state machine`
    );
  }

  const multiplayerComponents = sources.get(
    'Extensions/Multiplayer/multiplayercomponents.ts'
  );
  assert.match(
    multiplayerComponents,
    /if \(playmeshBackend\) \{\s*playmeshBackend\.configureOfficialLobbyFrame\(iframe\);\s*\} else \{\s*iframe\.src = url;/
  );

  const playerAuthentication = sources.get(
    'Extensions/PlayerAuthentication/playerauthenticationtools.ts'
  );
  assert.equal(
    playerAuthentication.includes(
      'window.localStorage.getItem(\n          getLocalStorageKey(gameId)'
    ),
    false
  );
  assert.equal(
    playerAuthentication.includes('_websocket = new WebSocket(wsPlayApi);'),
    false,
    'the direct official authentication WebSocket seam must be replaced'
  );
  assert.match(
    playerAuthentication,
    /playmeshBackend\.checkGameRegistration\(\{ gameId \}\)/
  );
  assert.match(
    playerAuthentication,
    /playmeshBackend\.createOfficialAuthenticationControlFacade\(\)/
  );
  assert.equal(
    playerAuthentication.match(
      /consumeOfficialAuthenticationFrameMessage\(event\)/g
    )?.length,
    2,
    'web popup and web iframe authentication must share the local frame capability'
  );
  assert.equal(
    playerAuthentication.match(
      /if \(getPlaymeshPlayerAuthenticationBackend\(\)\) return;/g
    )?.length,
    2,
    'Electron and Cordova must retain their socket state machine without cloud navigation'
  );
  assert.match(
    playerAuthentication,
    /checkOrigin: !playmeshBackend/
  );
  for (const getter of [
    'export const getUsername',
    'export const getUserToken',
    'export const getUserId',
  ]) {
    assert.equal(
      playerAuthentication.split(getter).length - 1,
      1,
      `${getter} must remain official`
    );
  }

  const authenticationComponents = sources.get(
    'Extensions/PlayerAuthentication/playerauthenticationcomponents.ts'
  );
  assert.match(
    authenticationComponents,
    /if \(playmeshBackend\) \{\s*playmeshBackend\.configureOfficialAuthenticationFrame\(iframe\);\s*\} else \{\s*iframe\.src = url;/
  );
}

process.stdout.write('GDevelop Multiplayer lowest-I/O seam contract passed.\n');
