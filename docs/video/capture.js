// 逐帧确定性捕获：用本机 Edge + Playwright，把时间轴按 1/60s 推进逐帧截图，
// 再交给 ffmpeg 编码。不用 screencast，避免掉帧与时间抖动。
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const ROOT = 'D:/code/study/InphicBatteryTray/docs/video';
const FRAMES = path.join(ROOT, 'frames');
const FPS = Number(process.env.FPS || 60);
const DURATION = 24.0;

(async () => {
  fs.rmSync(FRAMES, { recursive: true, force: true });
  fs.mkdirSync(FRAMES, { recursive: true });

  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 720 },
    deviceScaleFactor: 1,
  });
  const page = await ctx.newPage();
  await page.goto('file:///' + ROOT + '/video.html?record=1', { waitUntil: 'load' });
  await page.waitForFunction(() => typeof window.seekTo === 'function', null, { timeout: 20000 });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(400);

  const total = Math.round(DURATION * FPS);
  const t0 = Date.now();
  for (let i = 0; i < total; i++) {
    const t = i / FPS;
    await page.evaluate(tt => window.seekTo(tt), t);
    const name = String(i).padStart(5, '0') + '.png';
    await page.screenshot({ path: path.join(FRAMES, name) });
    if (i % 120 === 0) {
      const el = ((Date.now() - t0) / 1000).toFixed(1);
      console.log(`frame ${i}/${total}  t=${t.toFixed(2)}s  elapsed=${el}s`);
    }
  }
  await browser.close();
  console.log('DONE frames=' + total + ' fps=' + FPS);
})();
