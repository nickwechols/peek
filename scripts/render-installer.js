// Renders design/installer-background.html to the 1x and 2x installer backgrounds.
// Usage: node scripts/render-installer.js   (needs: npm i playwright)
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const root = path.resolve(__dirname, '..');
  const b = await chromium.launch();
  for (const [scale, name] of [[1, 'background.png'], [2, 'background@2x.png']]) {
    const p = await b.newPage({ viewport: { width: 640, height: 400 }, deviceScaleFactor: scale });
    await p.goto('file://' + path.join(root, 'design/installer-background.html'));
    await p.waitForTimeout(800);
    await p.screenshot({ path: path.join(root, 'Resources/Installer', name) });
  }
  await b.close();
})();
