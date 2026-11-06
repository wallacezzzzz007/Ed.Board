# Ed.Board Bridge for Obsidian

Use separate keyboard layers for Markdown and Excalidraw without changing apps. Requires **macOS**, **Obsidian 1.5+**, and **Ed.Board 0.6.6 (48) or later**. Install the Excalidraw community plugin if you want drawing detection.

## Install manually

1. Download this repository's source and open `plugins/obsidian/`.
2. Copy **only the `edboard-bridge` folder** into your vault's plugin directory:

   ```text
   Your vault/
   └── .obsidian/
       └── plugins/
           └── edboard-bridge/
               ├── main.js
               └── manifest.json
   ```

   `.obsidian` is hidden by default; press **Command + Shift + .** in Finder to show hidden files. If you use a custom Obsidian configuration folder, use that folder instead.
3. Restart Obsidian. In **Settings → Community plugins**, turn off Restricted mode if necessary and enable **Ed.Board Bridge**.

`main.js` is both the source and the runnable plugin. No compilation or package manager is needed. Nothing installs automatically; you copy the folder yourself, and the plugin does not edit your notes. Install and enable it in **every vault** where you want the integration. All enabled vaults on this Mac share one pairing; switching vault windows does not require re-pairing. Split panes and popout windows are supported.

## Pair with Ed.Board

1. Open **Ed.Board → Settings → Plugins** (below Power & Sleep) and enable **Obsidian**.
2. Click **Pair…**, then **Copy Pairing Code**. The code expires after **2 minutes**.
3. Open **Obsidian → Settings → Ed.Board Bridge**, paste the code and click **Pair**.
4. Return to a document. Ed.Board shows **Connected** while Obsidian is in front; **Paired · Obsidian in background** is normal when you focus another app.
5. With your keyboard connected, choose **Default layer** and **Excalidraw layer** in Ed.Board. These settings save automatically, separately from Keymap drafts.

## How it works

- Markdown and other views use **Default layer**. Excalidraw uses **Excalidraw layer**; selecting **Use default layer** shares the default mapping.
- **Use app matching** leaves the default choice to your existing Ed.Board application rules.
- Only the focused editor counts, across vaults, split panes and popout windows. Background vaults send no page-state reports; late reports from older focus sessions cannot replace the current editor. A drawing opened as Markdown source counts as Markdown; an embedded drawing alone does not change the outer editor's type.
- Ed.Board independently checks that **Obsidian is the frontmost app**. Leaving Obsidian immediately discards the active view; returning waits for a fresh focused-window report. It uses the existing automatic-layer policy and does not edit your actions, override manual-selection rules or select the layer being edited.
- State normally updates when the view changes, with a heartbeat every 5 seconds. Missing heartbeats expire after 15 seconds and normal app matching resumes. Disable or unload the companion plugin to stop its reports.
- Closing the Ed.Board window is fine; quitting Ed.Board stops the integration. No firmware update is required beyond the App's existing compatible firmware requirement.

## Privacy and permissions

All communication goes to **127.0.0.1:27124** on this Mac, authenticated by a paired credential. Ed.Board opens this listener only when its Obsidian integration is enabled. The plugin sends a view type, a temporary random client ID, a focus timestamp and a message sequence, **never note contents, file names, vault paths or keyboard configuration**. No internet service or extra Accessibility/Screen Recording permission is needed for this bridge.

Credentials are stored outside the vault, with owner-only file permissions:

- App settings and layer mappings: `~/Library/Application Support/Ed.Board/Settings/obsidian-plugin.json`
- Companion credential: `~/Library/Application Support/Ed.Board/ObsidianBridge/client.json`

Do not share these files or pairing codes. No credential is saved in the plugin's `data.json`. Obsidian's community-plugin system does not provide per-plugin permission isolation; the narrow behavior above is implemented in this plugin's code.

## Disable, disconnect or uninstall

- **Temporarily off:** turn off Obsidian in Ed.Board's Plugins section. It closes the listener and falls back to existing app matching; mappings and pairing remain for later use.
- **Revoke pairing:** click **Disconnect** in Ed.Board. The old credential stops working; generate a new pairing code to reconnect.
- **Remove the shared companion credential:** click **Disconnect this Mac** in the Obsidian plugin settings. This affects all vaults on this Mac. To stop just one vault, disable its companion plugin instead.
- **Uninstall:** disable the plugin in that vault and delete its copied `edboard-bridge` folder. Other enabled vaults keep working. Turn off the integration in Ed.Board only if you want to stop all vaults. This does not change any notes or Keymap actions.

## Updating

Copy both plugin files into each vault where the companion is installed, then disable/re-enable the plugin or restart Obsidian. Version 0.2.0 and App build 48 use focus-ordered state messages; update both ends together. The existing Mac-local pairing can be reused, without changing notes or vault settings.

## Troubleshooting

- **Waiting for Obsidian:** return to a document in a vault with the plugin enabled. Check that both applications are running.
- **Pairing fails:** generate a fresh code, enable Ed.Board integration and check that another Ed.Board copy is not using the local port. Re-pair on a different Mac; credentials do not sync with the vault.
- **Connected but no layer change:** check the mappings for the currently connected keyboard and ensure the layers have been saved. Missing layers fall back to existing app matching. Existing manual-selection rules still apply.
- **After updating plugin files:** disable/re-enable the plugin or restart Obsidian. Never copy local credentials into a shared plugin package.

This companion is part of Ed.Board and uses **GPL-3.0-only**; see the repository's [LICENSE](../../LICENSE).
