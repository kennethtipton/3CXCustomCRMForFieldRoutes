# FieldRoutes CRM for 3CX — Extension Install Guide

Three browser extensions are included, each in its own folder:

| Folder | Browser | Format |
|---|---|---|
| `extension-chrome/` | Google Chrome | Manifest V3 |
| `extension-edge/`   | Microsoft Edge | Manifest V3 (Chromium) |
| `extension-firefox/`| Mozilla Firefox | Manifest V2 |

---

## First-time setup (all browsers)

After installing in any browser, click the extension icon and fill in:

1. **My 3CX Extension Number** — the 3CX extension assigned to this workstation (e.g. `101`)
2. **Server** — IP address and port of the middleware server (e.g. `192.168.1.50:3000` or `middleware.yourcompany.com:443`)
3. **Shared Secret** — the secret from the middleware `/settings` page

Each operator enters their own extension number. The server address and secret are the same for everyone.

---

## Google Chrome

### Option A — Load unpacked (internal / development)
1. Go to `chrome://extensions`
2. Enable **Developer mode** (top-right toggle)
3. Click **Load unpacked**
4. Select the `extension-chrome\` folder
5. Pin the extension to the toolbar via the puzzle-piece icon

### Option B — Pack to .crx for distribution
1. Go to `chrome://extensions` with Developer mode on
2. Click **Pack extension** → select `extension-chrome\`
3. Distribute the `.crx` file — keep the generated `.pem` key for future updates

### Option C — Group Policy (managed devices, no Developer mode required)
1. Pack the extension to get its ID
2. Host the `.crx` and an `update_manifest.xml` on an internal server
3. Push via **ExtensionInstallForcelist** Group Policy key

---

## Microsoft Edge

Edge is Chromium-based and runs Chrome MV3 extensions natively — the process is identical.

### Option A — Load unpacked
1. Go to `edge://extensions`
2. Enable **Developer mode** (left sidebar toggle)
3. Click **Load unpacked**
4. Select the `extension-edge\` folder
5. Pin via the puzzle-piece icon in the toolbar

### Option B — Pack to .crx
Same as Chrome — use `edge://extensions` → **Pack extension**.

### Option C — Group Policy
Same policy keys as Chrome work on Edge. Use **ExtensionInstallForcelist** in the Edge ADMX templates.

### Option D — Microsoft Edge Add-ons store
If you have a Microsoft partner account you can publish to the Edge Add-ons store for easier managed distribution.

---

## Mozilla Firefox

Firefox requires the MV2 version in `extension-firefox\`.

### Option A — Load temporary add-on (testing only, removed on browser close)
1. Go to `about:debugging#/runtime/this-firefox`
2. Click **Load Temporary Add-on**
3. Navigate to `extension-firefox\` and select `manifest.json`

### Option B — Install permanently via signed .xpi (recommended for production)
Firefox requires add-ons to be signed by Mozilla for permanent installation in standard Firefox.

1. Create a free account at [addons.mozilla.org](https://addons.mozilla.org/developers/)
2. Submit the `extension-firefox\` folder as a **Unlisted** add-on (for internal distribution — no review queue)
3. Mozilla signs it automatically and provides a `.xpi` download link within minutes
4. Distribute the `.xpi` — users install by dragging it onto Firefox or via `about:addons`

### Option C — Firefox ESR / enterprise with policies.json (no signing required)
For managed Firefox deployments you can bypass signing:

1. Create `C:\Program Files\Mozilla Firefox\distribution\policies.json`:
```json
{
  "policies": {
    "Extensions": {
      "Install": ["file:///C:/path/to/extension-firefox.xpi"]
    }
  }
}
```
2. Or use the **ExtensionSettings** policy to force-install from a URL

### Option D — Firefox Developer Edition or Nightly
Developer Edition and Nightly allow unsigned extensions:
1. Go to `about:config`
2. Set `xpinstall.signatures.required` to `false`
3. Load via `about:addons` → gear icon → **Install Add-on From File**

---

## Updating the extension

When a new version is deployed:

- **Chrome / Edge unpacked**: repeat Load Unpacked with the new folder — or click the refresh icon on `chrome://extensions`
- **Chrome / Edge .crx**: re-pack with the same `.pem` key and redistribute
- **Firefox signed .xpi**: upload new version to AMO as an update — the signed `.xpi` URL stays the same
- **Firefox policies.json**: update the file path to the new `.xpi` and restart Firefox

---

## Verifying the connection

After installing and configuring, the extension badge should show **ON** in green. If it shows **OFF**:

- Check the server address and port are reachable from the workstation
- Confirm the shared secret matches what's in the middleware `/settings` page
- Check `http://[server]:[port]/health` returns JSON — if it doesn't, the middleware isn't running
