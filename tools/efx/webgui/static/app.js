/* efx web interface.
 *
 * Every button maps to one `efx <component> <verb>` invocation, and the log pane
 * is that command's live output. Nothing here reimplements build logic — if the
 * GUI can do it, the same thing can be typed into a shell.
 */

'use strict';

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const state = {
  page: 'dashboard',
  status: null,
  schema: null,
  job: null,          // { id, component }
  stream: null,       // EventSource
  autoscroll: true,
};

/* ------------------------------------------------------------------ api --- */

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  let data = null;
  try { data = await res.json(); } catch { /* some endpoints return text */ }
  if (!res.ok) throw new Error((data && data.error) || `${res.status} ${res.statusText}`);
  return data;
}

function toast(message, kind = '') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = message;
  $('#toast-host').append(el);
  setTimeout(() => el.remove(), kind === 'err' ? 8000 : 4000);
}

/* ------------------------------------------------------------- formatting --- */

const COMPONENT_LABEL = {
  config: 'Configuration', fsbl: 'FSBL', opensbi: 'OpenSBI', uboot: 'U-Boot',
  kernel: 'Kernel', image: 'Rootfs & Image', fpga: 'FPGA / Bitstream',
  flash: 'Flash', logs: 'Logs', settings: 'Settings', dashboard: 'Dashboard',
};

function bytes(n) {
  if (!n) return '—';
  const u = ['B', 'KiB', 'MiB', 'GiB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n < 10 && i ? n.toFixed(1) : Math.round(n)} ${u[i]}`;
}

function ago(epoch) {
  if (!epoch) return '—';
  const s = Math.max(0, Date.now() / 1000 - epoch);
  if (s < 60) return `${Math.round(s)}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

function chip(stateName) {
  return `<span class="chip chip-${stateName}">${stateName}</span>`;
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ---------------------------------------------------------------- status --- */

async function refreshStatus() {
  try {
    state.status = await api('/api/status');
  } catch (err) {
    toast(`status failed: ${err.message}`, 'err');
    return;
  }

  for (const c of state.status.components) {
    const dot = $(`.dot[data-state-for="${c.id}"]`);
    if (dot) dot.dataset.state = c.state;
  }

  const busy = state.status.busy || (state.job && state.job.running);
  $('#busy-indicator').classList.toggle('hidden', !busy);
  if (busy) {
    $('#busy-text').textContent = state.job
      ? `${state.job.component} ${state.job.action}`
      : (state.status.lock_holder || 'building').split(' (')[0];
  }

  const s = state.status;
  $('#topbar-meta').textContent =
    `${s.board} · ${s.soc_variant} SoC · rv${s.arch} · ${s.rootfs_mode} · ${s.free_gib} GiB free`;
}

function componentStatus(id) {
  return state.status && state.status.components.find(c => c.id === id);
}

/* ------------------------------------------------------------------ jobs --- */

async function runAction(component, action, { destructive = false, label = '' } = {}) {
  if (destructive) {
    const ok = await confirmDialog(
      `Run ${component} ${action}?`,
      'This changes or removes files that took time to produce.',
      `efx ${component} ${action}`);
    if (!ok) return;
  }

  let job;
  try {
    job = await api('/api/jobs', {
      method: 'POST',
      body: { component, action, confirm: destructive },
    });
  } catch (err) {
    toast(err.message, 'err');
    return;
  }

  state.job = job;
  toast(`started: efx ${component} ${action || ''}`.trim());
  attachStream(job.id, true);
  refreshStatus();
}

function attachStream(jobId, clear) {
  if (state.stream) { state.stream.close(); state.stream = null; }

  const log = $('#log');
  if (log && clear) log.textContent = '';

  const es = new EventSource(`/api/stream/${jobId}`);
  state.stream = es;

  es.addEventListener('line', ev => {
    const { text } = JSON.parse(ev.data);
    appendLogLine(text);
  });

  es.addEventListener('done', ev => {
    const summary = JSON.parse(ev.data);
    state.job = summary;
    es.close();
    state.stream = null;
    toast(summary.returncode === 0
      ? `${summary.component} ${summary.action} finished`
      : `${summary.component} ${summary.action} failed (exit ${summary.returncode})`,
      summary.returncode === 0 ? 'ok' : 'err');
    refreshStatus().then(() => { if (state.page !== 'logs') render(); });
  });

  // EventSource reconnects on its own and replays from Last-Event-ID, so a page
  // reload or a dropped connection mid-build resumes without a gap.
  es.onerror = () => { /* browser retries; nothing to do */ };
}

function appendLogLine(text) {
  const log = $('#log');
  if (!log) return;

  const span = document.createElement('span');
  if (/^ERROR|^FAIL|error:|Error \d/.test(text)) span.className = 'l-err';
  else if (/^WARN|warning:/.test(text)) span.className = 'l-warn';
  else if (/^\s*ok\b|^INFO/.test(text)) span.className = 'l-ok';
  else if (/^==>|^###/.test(text)) span.className = 'l-head';
  span.textContent = text + '\n';
  log.append(span);

  if (state.autoscroll) log.scrollTop = log.scrollHeight;
}

async function cancelJob() {
  if (!state.job) return;
  try {
    await api(`/api/cancel/${state.job.id}`, { method: 'POST' });
    toast('cancel requested');
  } catch (err) {
    toast(err.message, 'err');
  }
}

function confirmDialog(title, body, cmd) {
  return new Promise(resolve => {
    const dlg = $('#confirm-dialog');
    $('#confirm-title').textContent = title;
    $('#confirm-body').textContent = body;
    $('#confirm-cmd').textContent = cmd;
    dlg.returnValue = 'cancel';
    dlg.showModal();
    dlg.addEventListener('close', () => resolve(dlg.returnValue === 'ok'), { once: true });
  });
}

/* ----------------------------------------------------------- shared parts --- */

function logCard(title = 'Output') {
  return `
    <section class="card log-wrap">
      <h2>${title}</h2>
      <pre class="log" id="log"></pre>
      <div class="log-toolbar">
        <label><input type="checkbox" id="autoscroll" ${state.autoscroll ? 'checked' : ''}> Follow output</label>
        <button class="ghost" id="cancel-btn" ${state.job && state.job.running ? '' : 'disabled'}>Cancel</button>
        <span class="mono" id="log-meta"></span>
      </div>
    </section>`;
}

function artifactsCard(comp) {
  if (!comp || !comp.artifacts.length) return '';
  const rows = comp.artifacts.map(a => `
    <tr>
      <td class="mono">${esc(a.name)}<div class="path">${esc(a.path)}</div></td>
      <td>${a.exists ? chip('ok') : chip('missing')}</td>
      <td class="num mono">${a.exists ? bytes(a.size) : '—'}</td>
      <td class="mono">${a.exists ? ago(a.mtime) : '—'}</td>
    </tr>`).join('');

  return `
    <section class="card">
      <h2>Artifacts</h2>
      <div class="card-body tight">
        <table>
          <thead><tr><th>File</th><th>State</th><th>Size</th><th>Built</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    </section>`;
}

function actionBar(component, verbs) {
  const destructive = new Set(['reset', 'clean', 'workspace', 'images', 'restore', 'configure']);
  return `<div class="actions">` + verbs.map(v => {
    const cls = v.verb === 'build' || v.verb === 'rebuild' ? 'primary'
              : destructive.has(v.verb) ? 'danger' : 'action';
    return `<button class="${cls}" data-run="${component}" data-verb="${v.verb}"
              ${destructive.has(v.verb) ? 'data-destructive="1"' : ''}>${v.label}</button>`;
  }).join('') + `</div>`;
}

/* ----------------------------------------------------------------- pages --- */

function pageDashboard() {
  const s = state.status;
  if (!s) return '<p class="hint">Loading…</p>';

  const stages = s.components.map(c => `
    <button class="stage" data-page="${c.id}">
      <div class="stage-name">${esc(c.label)}</div>
      <div class="stage-state">${chip(c.state)}</div>
    </button>`).join('');

  const fsbl = componentStatus('fsbl');
  let fsblCard = '';
  if (fsbl && fsbl.size_limit > 0) {
    const pct = Math.min(100, Math.round(fsbl.size_used * 100 / fsbl.size_limit));
    const over = fsbl.size_used > fsbl.size_limit;
    fsblCard = `
      <section class="card">
        <h2>FSBL on-chip RAM budget</h2>
        <div class="card-body">
          <div class="row spread"><span class="mono">${fsbl.size_used} / ${fsbl.size_limit} bytes</span>
            <span class="mono">${pct}%</span></div>
          <div class="meter ${over ? 'over' : ''}" style="margin-top:8px"><span style="width:${pct}%"></span></div>
          <p class="hint" style="margin-top:10px">The bootloader runs from the SoC's on-chip RAM.
            Exceeding this budget produces an image that fails to boot with no diagnostic.</p>
        </div>
      </section>`;
  }

  const notReady = s.rootfs_mode === 'initramfs' ? `
    <div class="banner banner-warn">
      <strong>Bring-up mode.</strong> The root filesystem is built into the kernel image
      (<code>ROOTFS_MODE=initramfs</code>) and U-Boot loads it from the SPI flash, so the board boots
      with no SD card. Switch to <code>sdcard</code> for a persistent root filesystem.
    </div>` : '';

  return `
    ${notReady}
    <section class="card">
      <h2>Pipeline</h2>
      <div class="card-body"><div class="pipeline">${stages}</div></div>
    </section>
    ${fsblCard}
    <section class="card">
      <h2>Build environment</h2>
      <div class="card-body">
        <dl class="kv">
          <dt>Repo</dt><dd>${esc(s.repo)}</dd>
          <dt>Workspace</dt><dd>${esc(s.workspace)}</dd>
          <dt>Images</dt><dd>${esc(s.images_dir)}</dd>
          <dt>Board</dt><dd>${esc(s.board)} · ${esc(s.soc_variant)} SoC · rv${esc(s.arch)}</dd>
          <dt>Configured</dt><dd>${s.configured ? 'yes' : 'no'}</dd>
          <dt>Parallel jobs</dt><dd>${s.jobs}</dd>
          <dt>Free disk</dt><dd>${s.free_gib} GiB</dd>
        </dl>
      </div>
    </section>
    <section class="card">
      <h2>Recent jobs</h2>
      <div class="card-body tight"><table id="jobs-table">
        <thead><tr><th>Job</th><th>Result</th><th>Started</th></tr></thead>
        <tbody><tr><td colspan="3" class="hint" style="padding:16px">Loading…</td></tr></tbody>
      </table></div>
    </section>`;
}

function pageConfig() {
  const comp = componentStatus('config');
  return `
    <div class="banner banner-info">
      Wraps <code>init.sh</code>. The project's <code>soc.h</code> is copied, never modified, the
      project-specific AXI map from <code>socmap/</code> is injected, and every file
      <code>init.sh</code> rewrites is restored from git first — so running this twice
      produces an identical tree.
    </div>
    <section class="card">
      <h2>Actions</h2>
      <div class="card-body">
        ${actionBar('config', [
          { verb: 'configure',   label: 'Configure' },
          { verb: 'reconfigure', label: 'Reconfigure' },
          { verb: 'regen-dt',    label: 'Regenerate device tree' },
          { verb: 'diff',        label: 'Show changes' },
          { verb: 'detect',      label: 'Detect paths' },
          { verb: 'reset',       label: 'Reset repo' },
        ])}
        <p class="hint" style="margin-top:12px">
          <strong>Configure</strong> starts fresh (refuses if the build directory exists).
          <strong>Reconfigure</strong> re-runs configuration only;
          <strong>Regenerate device tree</strong> also rebuilds the DTS from <code>soc.h</code>.
        </p>
      </div>
    </section>
    ${artifactsCard(comp)}
    ${logCard()}`;
}

function pageBuildComponent(id) {
  const comp = componentStatus(id);
  const verbs = [
    { verb: 'build', label: 'Build' },
    { verb: 'rebuild', label: 'Rebuild' },
    { verb: 'clean', label: 'Clean' },
  ];
  if (id === 'kernel' || id === 'uboot') {
    verbs.push({ verb: 'savedefconfig', label: 'Save defconfig' });
    verbs.push({ verb: 'config', label: 'Show config sources' });
  }

  let banner = '';
  if (id === 'kernel') {
    banner = `<div class="banner banner-info">
      A kernel-only build installs <code>vmlinux</code> and <code>linux.dtb</code>.
      <code>Image</code> and <code>uImage</code> come from the post-build hook, which Buildroot runs
      during target-finalize — build <strong>Rootfs &amp; Image</strong> to produce them.</div>`;
  }
  if (comp && comp.state === 'cancelled') {
    banner = `<div class="banner banner-warn">
      This component was cancelled mid-build, so its package directory may be half-written.
      <strong>Clean</strong> it before building again.</div>`;
  } else if (comp && comp.state === 'stale') {
    banner = `<div class="banner banner-warn">
      A configuration input is newer than the built artifacts. <strong>Rebuild</strong> to pick it up.</div>`;
  }

  const editor = (id === 'kernel' || id === 'uboot') ? `
    <section class="card">
      <h2>Configuration fragments</h2>
      <div class="card-body">
        <p class="hint">
          <code>menuconfig</code> is a terminal program and cannot run in a browser. Edit the fragment
          files that feed the build instead — they are the actual source of truth, and unlike a
          <code>.config</code> edit they survive a reconfigure.
        </p>
        <div class="field">
          <label for="frag-select">File</label>
          <select id="frag-select" data-component="${id}"></select>
        </div>
        <div class="field" style="margin-top:12px">
          <textarea class="editor mono" id="frag-editor" spellcheck="false"></textarea>
        </div>
        <div class="actions" style="margin-top:12px">
          <button class="primary" id="frag-save">Save fragment</button>
          <span class="hint" id="frag-path" style="margin:0;align-self:center"></span>
        </div>
      </div>
    </section>` : '';

  return `
    ${banner}
    <section class="card">
      <h2>Actions</h2>
      <div class="card-body">${actionBar(id, verbs)}</div>
    </section>
    ${artifactsCard(comp)}
    ${editor}
    ${logCard()}`;
}

function pageFsbl() {
  const comp = componentStatus('fsbl');
  const s = state.status || {};
  let meter = '';
  if (comp && comp.size_limit > 0 && comp.size_used > 0) {
    const pct = Math.min(100, Math.round(comp.size_used * 100 / comp.size_limit));
    const over = comp.size_used > comp.size_limit;
    meter = `
      <div class="row spread" style="margin-top:14px">
        <span class="mono">on-chip RAM: ${comp.size_used} / ${comp.size_limit} bytes</span>
        <span class="mono">${pct}%</span>
      </div>
      <div class="meter ${over ? 'over' : ''}" style="margin-top:6px"><span style="width:${pct}%"></span></div>`;
  }

  return `
    <div class="banner banner-info">
      Built from the Efinity project BSP with the native Linux toolchain, not the vendor IDE
      (which ships here as Windows binaries only). <code>-march</code> and <code>-mabi</code> are derived
      from <code>soc.h</code>, with <code>_zicsr_zifencei</code> spelled out — GCC 12+ no longer implies
      <code>zifencei</code>, and the BSP uses <code>fence.i</code>.
    </div>
    <section class="card">
      <h2>Actions</h2>
      <div class="card-body">
        ${actionBar('fsbl', [
          { verb: 'build', label: 'Build' },
          { verb: 'rebuild', label: 'Rebuild' },
          { verb: 'clean', label: 'Clean' },
          { verb: 'restore', label: 'Restore project config' },
        ])}
        ${meter}
        <p class="hint" style="margin-top:12px">
          Host BSP: <code>${esc(s.soc_variant === 'hard' ? 'efx_hard_soc' : 'EfxSapphireFCU')}</code>
          (set by <code>FSBL_HOST</code> in Settings).
        </p>
      </div>
    </section>
    ${artifactsCard(comp)}
    ${logCard()}`;
}

function pageFpga() {
  const comp = componentStatus('fpga');
  const hard = state.status && state.status.soc_variant === 'hard';
  return `
    <div class="banner ${hard ? 'banner-warn' : 'banner-info'}">
      ${hard
        ? `The hardened SoC's 16 KiB app RAM lives inside the hard block, so
           <strong>Patch FSBL into bitstream</strong> cannot reach it — only the soft SoC's fabric RAM is
           initialisable. Loading a bootloader there means <strong>Point IP at FSBL</strong> followed by a
           full <strong>Build bitstream</strong> (hours). Use <code>FSBL_HOST=fcu</code> for fast turnaround.`
        : `The soft SoC's on-chip RAM is fabric BRAM, so the FSBL can be patched straight into a finished
           bitstream — seconds instead of a full place &amp; route.`}
    </div>
    <section class="card">
      <h2>Actions</h2>
      <div class="card-body">
        ${actionBar('fpga', [
          { verb: 'check', label: 'Check toolchain' },
          { verb: 'memories', label: 'List memories' },
          { verb: 'bram-update', label: 'Patch FCU firmware into bitstream' },
          { verb: 'pgm', label: 'Generate programming image' },
          { verb: 'verify-fsbl', label: 'Verify FSBL in bitstream' },
          { verb: 'build', label: 'Build bitstream' },
        ])}
      </div>
    </section>
    ${artifactsCard(comp)}
    ${logCard()}`;
}

function pageFlash() {
  const s = state.status || {};
  return `
    <div class="banner banner-warn">
      Writing to a block device or to the board's SPI flash is deliberately <strong>not</strong> available
      from the browser. A mis-clicked target destroys a disk, and a web page is the wrong place to make
      that decision. Run these in a terminal, where the device is named explicitly and confirmed.
    </div>
    <section class="card">
      <h2>Images and devices</h2>
      <div class="card-body">
        ${actionBar('flash', [
          { verb: 'image', label: 'Assemble SPI flash image' },
          { verb: 'list', label: 'List removable devices' },
        ])}
      </div>
    </section>
    <section class="card">
      <h2>Commands</h2>
      <div class="card-body">
        <p class="hint">Try a bitstream over JTAG without touching the flash (lost at power-off):</p>
        <p class="confirm-cmd"><code>tools/efx/efx flash sram</code></p>
        <p class="hint" style="margin-top:14px">Program the SPI flash with the assembled image
          (bitstream, OpenSBI, U-Boot, device tree, boot script, kernel); backs the flash up first:</p>
        <p class="confirm-cmd"><code>tools/efx/efx flash spi</code></p>
        <p class="hint" style="margin-top:14px">Rewrite only what changed, e.g. after a kernel or device tree rebuild (seconds, no backup):</p>
        <p class="confirm-cmd"><code>tools/efx/efx flash spi --part dtb,bootscr,kernel</code></p>
        <p class="hint" style="margin-top:14px">Write the SD card image (asks for the device and a typed confirmation):</p>
        <p class="confirm-cmd"><code>tools/efx/efx flash sdcard --device /dev/sdX</code></p>
        <p class="hint" style="margin-top:14px">Images come from <code>${esc(s.images_dir || '')}</code>.</p>
      </div>
    </section>
    ${logCard()}`;
}

function pageLogs() {
  return `
    <section class="card">
      <h2>Log files</h2>
      <div class="card-body tight">
        <table id="logs-table">
          <thead><tr><th>File</th><th>Size</th><th>Written</th></tr></thead>
          <tbody><tr><td colspan="3" class="hint" style="padding:16px">Loading…</td></tr></tbody>
        </table>
      </div>
    </section>
    <section class="card log-wrap">
      <h2>Contents</h2>
      <pre class="log" id="log-view"></pre>
    </section>`;
}

function pageSettings() {
  return `
    <div class="banner banner-info">
      These are the keys in <code>tools/efx/efx.conf</code>. The schema, including every description shown
      here, lives in <code>tools/efx/efx.keys</code>.
    </div>
    <section class="card">
      <h2>Configuration</h2>
      <div class="card-body">
        <div class="fields" id="settings-fields"><p class="hint">Loading…</p></div>
        <div class="actions" style="margin-top:18px">
          <button class="primary" id="settings-save">Save</button>
          <button class="ghost" id="settings-reload">Reload</button>
        </div>
      </div>
    </section>`;
}

/* ---------------------------------------------------------------- render --- */

const PAGES = {
  dashboard: pageDashboard,
  config: pageConfig,
  fsbl: pageFsbl,
  opensbi: () => pageBuildComponent('opensbi'),
  uboot: () => pageBuildComponent('uboot'),
  kernel: () => pageBuildComponent('kernel'),
  image: () => pageBuildComponent('image'),
  fpga: pageFpga,
  flash: pageFlash,
  logs: pageLogs,
  settings: pageSettings,
};

function render() {
  $('#page-title').textContent = COMPONENT_LABEL[state.page] || state.page;
  $$('.nav-item').forEach(b => b.classList.toggle('active', b.dataset.page === state.page));
  $('#page').innerHTML = (PAGES[state.page] || pageDashboard)();

  wirePage();

  // Keep showing the current job's output across page switches. Only a *running*
  // job gets a stream: re-attaching to a finished one would replay its `done`
  // event, which re-renders, which re-attaches — a loop.
  if (state.job && $('#log')) {
    if (state.job.running) attachStream(state.job.id, true);
    else loadJobOutput(state.job.id);
  }
}

async function loadJobOutput(jobId) {
  const log = $('#log');
  if (!log) return;
  try {
    const data = await api(`/api/jobs/${jobId}?after=-1`);
    log.textContent = '';
    for (const line of data.output) appendLogLine(line.text);
  } catch { /* the job aged out of the ring buffer */ }
}

function wirePage() {
  $$('[data-run]').forEach(btn => {
    btn.addEventListener('click', () => runAction(
      btn.dataset.run, btn.dataset.verb,
      { destructive: btn.dataset.destructive === '1' }));
  });

  $$('.stage[data-page]').forEach(el => {
    el.addEventListener('click', () => { state.page = el.dataset.page; render(); });
  });

  const auto = $('#autoscroll');
  if (auto) auto.addEventListener('change', () => { state.autoscroll = auto.checked; });

  const cancel = $('#cancel-btn');
  if (cancel) cancel.addEventListener('click', cancelJob);

  if (state.page === 'dashboard') loadJobs();
  if (state.page === 'logs') loadLogs();
  if (state.page === 'settings') loadSettings();
  if (state.page === 'kernel' || state.page === 'uboot') loadFragments(state.page);
}

/* ------------------------------------------------------------ page loads --- */

async function loadJobs() {
  const { jobs } = await api('/api/jobs');
  const body = $('#jobs-table tbody');
  if (!body) return;
  body.innerHTML = jobs.length ? jobs.map(j => `
    <tr>
      <td class="mono">${esc(j.component)} ${esc(j.action)}</td>
      <td>${j.running ? chip('running') : chip(j.returncode === 0 ? 'ok' : 'failed')}</td>
      <td class="mono">${ago(j.started)}</td>
    </tr>`).join('')
    : '<tr><td colspan="3" class="hint" style="padding:16px">No jobs yet this session.</td></tr>';
}

async function loadLogs() {
  const { logs } = await api('/api/logs');
  const body = $('#logs-table tbody');
  if (!body) return;
  body.innerHTML = logs.length ? logs.map(l => `
    <tr data-log="${esc(l.name)}" style="cursor:pointer">
      <td class="mono">${esc(l.name)}</td>
      <td class="num mono">${bytes(l.size)}</td>
      <td class="mono">${ago(l.mtime)}</td>
    </tr>`).join('')
    : '<tr><td colspan="3" class="hint" style="padding:16px">No logs yet.</td></tr>';

  $$('#logs-table tbody tr[data-log]').forEach(tr => {
    tr.addEventListener('click', async () => {
      const res = await fetch(`/api/logs/${encodeURIComponent(tr.dataset.log)}`);
      $('#log-view').textContent = await res.text();
    });
  });
}

/* The fragment editor is the browser-side stand-in for menuconfig. */
const FRAGMENTS = {
  kernel: [
    ['overlays/linux_ti375_oob.config', 'efx overlay (hand-authored)'],
    ['state/linux_derived.config', 'efx overlay (generated from soc.h)'],
    ['boards/efinix/BOARD/linux/linux.config', 'board kernel config'],
    ['boards/efinix/BOARD/linux/linux.dts', 'board device tree'],
    ['boards/efinix/common/dts/sapphire.dtsi', 'shared device tree'],
  ],
  uboot: [
    ['overlays/uboot_ti375_oob.cfg', 'efx overlay (hand-authored)'],
    ['state/uboot_derived.cfg', 'efx overlay (generated from soc.h)'],
    ['boards/efinix/common/u-boot/uboot_base_defconfig', 'base U-Boot config'],
    ['boards/efinix/BOARD/u-boot/uboot.dts', 'U-Boot device tree'],
  ],
};

function loadFragments(component) {
  const sel = $('#frag-select');
  if (!sel || !state.status) return;

  const repo = state.status.repo;
  const board = state.status.board;
  const efxDir = `${repo}/tools/efx`;

  sel.innerHTML = FRAGMENTS[component].map(([rel, label]) => {
    const abs = rel.startsWith('overlays/') || rel.startsWith('state/')
      ? `${efxDir}/${rel}`
      : `${repo}/${rel.replace('BOARD', board)}`;
    return `<option value="${esc(abs)}">${esc(label)} — ${esc(rel.replace('BOARD', board))}</option>`;
  }).join('');

  const open = async () => {
    try {
      const data = await api(`/api/file?path=${encodeURIComponent(sel.value)}`);
      $('#frag-editor').value = data.content;
      $('#frag-path').textContent = data.path;
    } catch (err) {
      $('#frag-editor').value = '';
      $('#frag-path').textContent = err.message;
    }
  };

  sel.addEventListener('change', open);
  $('#frag-save').addEventListener('click', async () => {
    try {
      await api('/api/file', {
        method: 'POST',
        body: { path: sel.value, content: $('#frag-editor').value },
      });
      toast('saved — rebuild the component to apply it', 'ok');
    } catch (err) {
      toast(err.message, 'err');
    }
  });

  open();
}

async function loadSettings() {
  const data = await api('/api/config');
  state.schema = data.keys;

  const groups = {};
  for (const k of data.keys) (groups[k.group] ||= []).push(k);

  $('#settings-fields').innerHTML = Object.entries(groups).map(([group, keys]) => `
    <div class="nav-group" style="padding-left:0">${esc(group)}</div>
    ${keys.map(k => `
      <div class="field">
        <label for="set-${esc(k.name)}">${esc(k.name)}</label>
        ${k.options
          ? `<select id="set-${esc(k.name)}" data-key="${esc(k.name)}">${
              k.options.map(o => `<option ${o === k.value ? 'selected' : ''}>${esc(o)}</option>`).join('')
            }</select>`
          : `<input id="set-${esc(k.name)}" data-key="${esc(k.name)}" value="${esc(k.value)}">`}
        <span class="desc">${esc(k.description)}</span>
      </div>`).join('')}
  `).join('');

  $('#settings-save').addEventListener('click', async () => {
    const values = {};
    $$('[data-key]').forEach(el => { values[el.dataset.key] = el.value; });
    try {
      const res = await api('/api/config', { method: 'POST', body: { values } });
      if (res.ok) toast('saved', 'ok');
      else toast(`saved, but validation complains: ${res.message}`, 'err');
      refreshStatus();
    } catch (err) {
      toast(err.message, 'err');
    }
  });

  $('#settings-reload').addEventListener('click', loadSettings);
}

/* ------------------------------------------------------------------ init --- */

function initTheme() {
  const saved = localStorage.getItem('efx-theme');
  if (saved) document.documentElement.dataset.theme = saved;

  $('#theme-toggle').addEventListener('click', () => {
    const current = document.documentElement.dataset.theme
      || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    const next = current === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    localStorage.setItem('efx-theme', next);
  });
}

function initNav() {
  $$('.nav-item').forEach(btn => {
    btn.addEventListener('click', () => {
      state.page = btn.dataset.page;
      location.hash = btn.dataset.page;
      render();
    });
  });

  // The click handler above already rendered and set the hash, so only act on a
  // hash that actually differs — otherwise every click renders twice.
  addEventListener('hashchange', () => {
    const page = location.hash.slice(1);
    if (PAGES[page] && page !== state.page) { state.page = page; render(); }
  });

  const initial = location.hash.slice(1);
  if (PAGES[initial]) state.page = initial;
}

async function main() {
  initTheme();
  initNav();
  await refreshStatus();
  render();
  setInterval(refreshStatus, 5000);
}

main();
