'use strict';
/**
 * UI 截图巡检：用 Edge headless 打开本地服务器，登录测试账号，逐页截图。
 * 产物在 artifacts/ui-shots/（已 gitignore），用于人工/模型目检排版。
 *
 * 用法：node scripts/ui-screenshot.js [baseUrl]
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { launchEdge, delay } = require('../browser-tests/edge-cdp');

const ROOT = path.resolve(__dirname, '..');
const BASE = process.argv[2] || 'http://127.0.0.1:4173/';
const OUT = path.join(ROOT, 'artifacts', 'ui-shots');
const USER = 'uiprobe';
const PASS = 'uiprobe1234';

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'zhsh-ui-'));
  const page = await launchEdge({ profileDirectory: profile, downloadRoot: path.join(profile, 'dl') });
  const errors = [];
  try {
    await page.navigate(BASE);
    const auth = await page.evaluate(`(async()=>{
      const body=JSON.stringify({username:${JSON.stringify(USER)},password:${JSON.stringify(PASS)}});
      const headers={'Content-Type':'application/json'};
      let r=await fetch('/api/auth/register',{method:'POST',headers,body});
      if(!r.ok) r=await fetch('/api/auth/login',{method:'POST',headers,body});
      return await r.json();
    })()`);
    if (!auth?.token) throw new Error(`auth failed: ${JSON.stringify(auth)}`);
    await page.evaluate(`(()=>{localStorage.setItem('zhsh_token',${JSON.stringify(auth.token)});localStorage.setItem('zhsh_player_id',${JSON.stringify(auth.player.player_canonical_id)});})()`);
    await page.reload();
    await page.waitFor(() => document.body.dataset.page === 'location', { label: 'location page' });

    // 种子数据：铜币 + 几件物品，方便看背包/商店/烹饪行
    await page.evaluate(`(async()=>{
      const token=${JSON.stringify(auth.token)};
      const post=async(p,b)=>{const r=await fetch(p,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(b)});return r.ok?r.json():null;};
      await post('/api/admin/set_money',{money:5000});
      for(const id of ['entity.item.3078715788fffba1','entity.item.b47d2dd709e68b18','entity.item.ea2bd40c4d621957']) await post('/api/admin/add_item',{item_canonical_id:id,quantity:2});
      return true;
    })()`);

    const shot = async (name) => {
      await delay(250);
      const { data } = await page.send('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(path.join(OUT, `${name}.png`), Buffer.from(data, 'base64'));
      process.stdout.write(`shot ${name}\n`);
    };
    const clickFirst = (selector) => page.evaluate(`(()=>{
      const el=Array.from(document.querySelectorAll(${JSON.stringify(selector)})).find((node)=>{const s=getComputedStyle(node),r=node.getBoundingClientRect();return s.visibility!=='hidden'&&s.display!=='none'&&r.width>0&&r.height>0;});
      if(!el)throw new Error('no visible element for '+${JSON.stringify(selector)});
      el.scrollIntoView({block:'center'});el.click();return true;
    })()`);
    const go = async (selector, pageName) => {
      await clickFirst(selector);
      if (pageName) await page.waitFor(`document.body.dataset.page===${JSON.stringify(pageName)}`, { label: `${pageName} page` });
      await page.waitFor(() => !document.querySelector('#save-status')?.textContent?.includes('正在'), { timeout: 5000 }).catch(() => {});
    };

    await page.reload();
    await page.waitFor(() => document.body.dataset.page === 'location', { label: 'location page' });
    await shot('01-location');

    await go('[data-page="tasks"]', 'tasks');
    await shot('02-tasks');
    await page.evaluate("document.querySelector('.series-switch summary')?.click()||false");
    await delay(200);
    await shot('03-tasks-series');

    await go('[data-page="location"]', 'location');
    await go('[data-page="map"]', 'map');
    await shot('04-city-map');
    if (await page.evaluate("Boolean(document.querySelector('[data-map-scope=\"full\"]'))")) {
      await clickFirst('[data-map-scope="full"]');
      await page.waitFor("document.body.dataset.page==='map'", { label: 'full map' });
      await delay(300);
      await shot('04b-city-map-full');
      await clickFirst('[data-map-scope="local"]').catch(() => {});
    }

    await go('[data-page="backpack"]', 'backpack');
    await shot('05-backpack');

    await go('[data-page="market"]', 'market');
    await page.waitFor(() => !document.querySelector('#market-holds')?.textContent?.includes('加载'), { timeout: 8000 }).catch(() => {});
    await shot('06-market');

    await go('[data-page="location"]', 'location');
    await go('[data-page="cook"]', 'cook');
    await shot('07-cook');

    await go('[data-page="status"]', 'status');
    await shot('08-status');

    await go('[data-page="settings"]', 'settings');
    await shot('09-settings');

    if (await page.evaluate("Boolean(document.querySelector('[data-page=\"admin\"]'))")) {
      await go('[data-page="admin"]', 'admin');
      await shot('10-admin');
      await go('[data-page="location"]', 'location');
    }

    // 回城点，去商店页
    await go('[data-page="location"]', 'location');
    const moved = await page.evaluate(`(()=>{const b=Array.from(document.querySelectorAll('[data-move]')).find((el)=>el.textContent.trim()==='商店');if(!b)return false;b.click();return true;})()`);
    if (moved) {
      await page.waitFor(() => document.body.dataset.page === 'location', { timeout: 8000 }).catch(() => {});
      await go('[data-page="shop"]', 'shop');
      await shot('10-shop');
    }

    const consoleErrors = page.console.filter((entry) => entry.level === 'error');
    if (consoleErrors.length) {
      process.stdout.write(`console errors: ${JSON.stringify(consoleErrors).slice(0, 800)}\n`);
    }
    process.stdout.write(`done. screenshots: ${OUT}\n`);
  } catch (error) {
    process.stderr.write(`UI screenshot failed: ${error.message}\n`);
    if (page.console.length) process.stderr.write(`${JSON.stringify(page.console.slice(-8))}\n`);
    process.exitCode = 1;
  } finally {
    await page.close().catch(() => {});
    const resolved = path.resolve(profile);
    if (resolved.startsWith(path.resolve(os.tmpdir()))) {
      try { fs.rmSync(resolved, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch {}
    }
  }
})();
