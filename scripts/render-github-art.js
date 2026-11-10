// Renders design/github-banner.html to the README banner (2x, for sharp retina display) and the
// repository social preview (1280 x 640, upload it under Settings, General, Social preview).
// Usage: node scripts/render-github-art.js   (needs: npm i playwright)
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const root = path.resolve(__dirname, '..');
  const b = await chromium.launch();
  for (const [scale, name] of [[2, 'banner.jpg'], [1, 'social-preview.jpg']]) {
    const p = await b.newPage({ viewport: { width: 1280, height: 640 }, deviceScaleFactor: scale });
    await p.goto('file://' + path.join(root, 'design/github-banner.html'));
    await p.waitForTimeout(800);
    await p.screenshot({ path: path.join(root, '.github/assets', name), type: 'jpeg', quality: 86 });
  }
  await b.close();
})();
