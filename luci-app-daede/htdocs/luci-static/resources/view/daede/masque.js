// SPDX-License-Identifier: Apache-2.0

'use strict';
'require fs';
'require form';
'require poll';
'require uci';
'require ui';
'require view';
'require view.daede.backend as backend';
'require view.daede.clash-converter as clashConverter';
'require view.daede.daed-session as daedSession';
'require view.daede.styles as styles';
'require view.daede.widgets as widgets';

const SCRIPT = '/usr/share/luci-app-daede/usque.sh';
const GENERATOR = '/usr/share/luci-app-daede/gen-dae-config.sh';
const UPDATER = '/usr/share/luci-app-daede/update-pkg.sh';
const STAGE = '/tmp/daede-usque-save.json';
const REG_LOG = '/tmp/luci-app-daede.usque-register.log';
const PKG_LOG = '/tmp/luci-app-daede.pkg-usque.log';
const GROUP_NAME = 'warp';
const NODE_TAG = 'warp_usque';
const DAED_STATE = 'query State{nodes(first:10000){edges{id link tag}} groups{id name nodes{id}} subscriptions{id link tag}}';

function parseKV(stdout) {
	const out = {};
	String(stdout || '').split('\n').forEach(function(line) {
		const i = line.indexOf('=');
		if (i > 0)
			out[line.slice(0, i)] = line.slice(i + 1).trim();
	});
	return out;
}

function execChecked(cmd, args) {
	return fs.exec(cmd, args || []).then(function(res) {
		if (res && res.code !== 0)
			throw new Error((res.stderr || res.stdout || ('exit ' + res.code)).trim());
		return res;
	});
}

function fetchStatus() {
	return fs.exec(SCRIPT, ['status']).then(function(res) {
		return parseKV(res && res.stdout);
	}).catch(function() {
		return {};
	});
}

function lastLine(text) {
	const lines = String(text || '').split('\n').filter(function(l) { return l.trim(); });
	return lines[lines.length - 1] || '';
}

function applyUciChanges() {
	return uci.save().then(function() {
		return uci.changes().then(function(ch) {
			return (ch && Object.keys(ch).length) ? uci.apply() : null;
		});
	}).then(function() {
		return new Promise(function(resolve) { window.setTimeout(resolve, 1800); });
	}).then(function() {
		return ui.changes.init();
	});
}

/* SOCKS5 link for the dae/daed node — a wildcard bind cannot be dialed, and a
   bare IPv6 literal needs brackets inside a URL. */
function socksLink(st) {
	let bind = String(st.bind || '127.0.0.1');
	const port = String(st.port || '1080');
	if (!bind || bind === '0.0.0.0' || bind === '::' || bind === '[::]')
		bind = '127.0.0.1';
	else if (bind.charAt(0) === '[')
		bind = bind.slice(1, -1);
	if (bind.indexOf(':') >= 0)
		bind = '[' + bind + ']';
	return 'socks5://' + bind + ':' + port;
}

/* status line under a card's buttons — flash(text, kind, hold); hold 0 = stay */
function makeStatus() {
	const node = E('span', { 'class': 'dd-editor-status' }, '');
	let timer = null;
	node.flash = function(text, kind, hold) {
		node.textContent = text;
		node.classList.remove('ok', 'err');
		if (kind) node.classList.add(kind);
		node.classList.add('show');
		if (timer) clearTimeout(timer);
		if (hold !== 0)
			timer = setTimeout(function() { node.classList.remove('show'); }, hold || 4000);
	};
	return node;
}

/* poll a background log until it logs a final checkmark (true) / cross (false);
   null = timeout */
function waitLog(path, onTick) {
	let tries = 0;
	const check = function() {
		return L.resolveDefault(fs.read_direct(path, 'text'), '').then(function(c) {
			if (onTick && c) onTick(c);
			if (/✓/.test(c)) return true;
			if (/✗/.test(c)) return false;
			if (++tries > 90) return null;
			return new Promise(function(r) { setTimeout(r, 2000); }).then(check);
		});
	};
	return check();
}

/* ------------------------------------------------------------------------- */
/* daed GraphQL helpers (mirrors converter.js — not exported there)           */
/* ------------------------------------------------------------------------- */
function daedEndpoint() {
	// HTTPS page: browser blocks the plain-HTTP :2023 fetch as mixed content,
	// so relay via a same-origin CGI. HTTP: hit daed direct. #11
	if (window.location.protocol === 'https:')
		return '/cgi-bin/daede-graphql';
	const listen = uci.get('daed', 'config', 'listen_addr') || '0.0.0.0:2023';
	const match = String(listen).match(/:(\d+)$/);
	const port = match ? match[1] : '2023';
	const host = window.location.hostname.indexOf(':') >= 0 ? '[' + window.location.hostname + ']' : window.location.hostname;
	return 'http://' + host + ':' + port + '/graphql';
}

function graphQL(endpoint, query, variables, token) {
	const headers = { 'Content-Type': 'application/json' };
	if (token)
		headers.Authorization = 'Bearer ' + token;

	return fetch(endpoint, {
		method: 'POST',
		headers: headers,
		body: JSON.stringify({ query: query, variables: variables || {} })
	}).then(function(response) {
		if (!response.ok)
			throw new Error(_('daed returned HTTP %s').format(response.status));
		return response.json();
	}).then(function(body) {
		if (body.errors && body.errors.length)
			throw new Error(body.errors.map(function(e) { return e.message; }).join('; '));
		return body.data;
	});
}

function requestDaedCredentials(mode) {
	const init = (mode === 'init');
	return new Promise(function(resolve, reject) {
		const username = E('input', { 'class': 'cbi-input-text', 'autocomplete': 'username', 'placeholder': _('Username') });
		const password = E('input', { 'class': 'cbi-input-password', 'type': 'password', 'autocomplete': init ? 'new-password' : 'current-password', 'placeholder': _('Password') });
		if (init) {
			username.value = uci.get('daed', 'config', 'dashboard_username') || '';
			password.value = uci.get('daed', 'config', 'dashboard_password') || '';
		}
		const cancel = E('button', { 'class': 'btn cbi-button' }, _('Cancel'));
		const submit = E('button', { 'class': 'btn cbi-button cbi-button-positive' },
			init ? _('Initialize and import') : _('Sign in and import'));

		cancel.addEventListener('click', function() {
			password.value = '';
			ui.hideModal();
			reject(new Error(init
				? _('daed is not initialized yet. Open the daed web panel (port 2023) to create an admin account, then import again.')
				: _('Import cancelled')));
		});
		submit.addEventListener('click', function() {
			if (!username.value || !password.value)
				return;
			const result = { username: username.value, password: password.value };
			password.value = '';
			ui.hideModal();
			resolve(result);
		});

		const intro = init
			? _('daed has not been initialized yet. The account below will be created as the daed admin (password needs at least 6 characters with both letters and numbers), then used to import.')
			: _('The password is not saved. Sign-in is remembered in this browser for up to 30 days.');

		ui.showModal(init ? _('Initialize daed') : _('Sign in to daed'), [ E('div', { 'class': 'dd-daed-login' }, [
			E('p', {}, intro),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Username')), E('div', { 'class': 'cbi-value-field' }, username) ]),
			E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Password')), E('div', { 'class': 'cbi-value-field' }, password) ]),
			E('div', { 'class': 'right dd-daed-login-actions' }, [ cancel, ' ', submit ])
		]) ]);
		username.focus();
	});
}

function requestDaedToken(endpoint, forceLogin) {
	const cached = forceLogin ? '' : daedSession.load(window.localStorage);
	if (cached)
		return Promise.resolve({ token: cached, cached: true });

	// numberUsers is unauthenticated; 0 means the daed panel was never
	// initialized, so log-in can never succeed — bootstrap it with createUser.
	return graphQL(endpoint, 'query Init{numberUsers}', {}).then(function(state) {
		const needInit = !state || state.numberUsers === 0;
		let credentials;
		return requestDaedCredentials(needInit ? 'init' : 'login').then(function(value) {
			credentials = value;
			if (needInit)
				return graphQL(endpoint,
					'mutation Init($username:String!,$password:String!){createUser(username:$username,password:$password)}',
					credentials).then(function(r) { return r.createUser; });
			return graphQL(endpoint,
				'query Login($username:String!,$password:String!){token(username:$username,password:$password)}',
				credentials).then(function(r) { return r.token; });
		}).then(function(token) {
			daedSession.save(window.localStorage, token);
			return { token: token, cached: false };
		}).finally(function() {
			if (credentials)
				credentials.password = '';
			credentials = null;
		});
	});
}

/* ------------------------------------------------------------------------- */
/* status card                                                                */
/* ------------------------------------------------------------------------- */
function renderStatusCard(initial) {
	let busy = false;
	let lastError = '';
	let refreshGeneration = 0;
	const probeState = { running: false, text: '', kind: '' };

	const body = E('div', { 'id': 'dd-usque-status' }, E('em', {}, _('Collecting data\u2026')));
	const card = E('div', { 'class': 'dd-card dd-status-card' }, [
		E('h4', { 'class': 'dd-card-title' }, _('Service Status')),
		body
	]);

	const render = function(st) {
		while (body.firstChild) body.removeChild(body.firstChild);

		const badge = st.running === '1'
			? E('span', { 'class': 'dd-badge dd-badge-run' }, [ E('span', { 'class': 'dd-badge-dot' }), _('RUNNING') ])
			: E('span', { 'class': 'dd-badge dd-badge-stop' }, [ E('span', { 'class': 'dd-badge-dot' }), _('STOPPED') ]);

		const meta = [];
		if (st.running === '1' && st.pid)
			meta.push(E('span', { 'class': 'dd-meta' }, [ E('span', { 'class': 'dd-meta-label' }, 'PID'), st.pid ]));
		meta.push(E('span', { 'class': 'dd-meta' }, [ E('span', { 'class': 'dd-meta-label' }, _('Listen')), (st.bind || '?') + ':' + (st.port || '?') ]));

		const swErr = E('span', { 'class': 'dd-meta dd-err', 'style': lastError ? '' : 'display:none' }, lastError);
		const sw = E('button', {
			'class': 'dd-switch' + (st.running === '1' ? ' is-on' : ''),
			'type': 'button',
			'aria-label': _('Toggle service'),
			'disabled': st.installed === '1' ? null : 'disabled'
		}, [
			E('span', { 'class': 'dd-switch-knob' })
		]);
		sw.addEventListener('click', function(ev) {
			ev.preventDefault();
			if (busy) return;
			refreshGeneration++;
			busy = true;
			sw.disabled = true;
			lastError = '';
			swErr.style.display = 'none';
			const turnOn = st.running !== '1';
			// instant optimistic feedback while the start/stop chain runs
			sw.classList.toggle('is-on', turnOn);
			const lbl = sw.parentNode && sw.parentNode.querySelector('.dd-switch-label');
			if (lbl) lbl.textContent = '\u2026';

			const chain = execChecked('/sbin/uci', ['set', 'usque.config.enabled=' + (turnOn ? '1' : '0')])
				.then(function() { return execChecked('/sbin/uci', ['commit', 'usque']); })
				.then(function() { return execChecked('/etc/init.d/usque', [turnOn ? 'enable' : 'disable']); })
				.then(function() { return execChecked('/etc/init.d/usque', [turnOn ? 'start' : 'stop']); })
				.then(function() { return waitForRunning(turnOn, 40); });

			chain
				.then(function() {
					busy = false;
					return refresh(true);
				})
				.catch(function(e) {
					busy = false;
					lastError = _('Toggle failed: %s').format(e.message || e);
					return refresh(true);
				});
		});

		const row = E('div', { 'class': 'dd-status-row' }, [
			badge,
			E('span', { 'class': 'dd-grow' }),
			swErr,
			E('span', { 'class': 'dd-switch-wrap' }, [
				E('span', { 'class': 'dd-switch-label' }, st.running === '1' ? 'ON' : 'OFF'),
				sw
			])
		]);
		body.appendChild(row);
		if (meta.length)
			body.appendChild(E('div', { 'class': 'dd-status-meta' }, meta));

		const actions = [];
		if (st.running === '1') {
			const restart = E('button', { 'class': 'cbi-button cbi-button-positive' }, _('Restart'));
			restart.addEventListener('click', function(ev) {
				ev.preventDefault();
				if (busy) return;
				busy = true;
				restart.disabled = true;
				lastError = '';
				swErr.style.display = 'none';
				execChecked('/etc/init.d/usque', ['restart'])
					.then(function() { return waitForRunning(true, 40); })
					.then(function() {
						busy = false;
						return refresh(true);
					})
					.catch(function(e) {
						busy = false;
						lastError = _('Restart failed: %s').format(e.message || e);
						return refresh(true);
					})
					.finally(function() { restart.disabled = false; });
			});
			actions.push(restart);
		}

		const ckBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Test Tunnel'));
		const ckRes = E('span', {
			'class': 'dd-meta' + (probeState.kind ? ' ' + probeState.kind : ''),
			'style': probeState.text ? '' : 'display:none'
		}, probeState.text);
		ckBtn.disabled = probeState.running;
		ckBtn.addEventListener('click', function(ev) {
			ev.preventDefault();
			if (probeState.running) return;
			probeState.running = true;
			probeState.text = _('Testing\u2026');
			probeState.kind = '';
			ckBtn.disabled = true;
			ckRes.style.display = 'inline';
			ckRes.classList.remove('dd-ok', 'dd-err');
			ckRes.textContent = probeState.text;
			fs.exec(SCRIPT, ['probe']).then(function(r) {
				const out = (r && r.stdout) || '';
				const ok = /\bok=1\b/.test(out);
				const tool = /\btool=1\b/.test(out);
				const code = (out.match(/http=(\S+)/) || [])[1] || '000';
				const warp = (out.match(/warp=(\S+)/) || [])[1] || '?';
				const ms = parseInt((out.match(/ms=(\d+)/) || [])[1] || '0', 10);
				if (!tool) {
					probeState.kind = 'dd-err';
					probeState.text = _('Probe needs curl or nc');
				} else if (ok && warp === 'on') {
					probeState.kind = 'dd-ok';
					probeState.text = _('Tunnel OK (WARP on) \u00b7 %d ms').format(ms);
				} else if (ok) {
					probeState.kind = 'dd-err';
					probeState.text = _('Tunnel reachable but WARP is off \u00b7 %d ms').format(ms);
				} else {
					probeState.kind = 'dd-err';
					probeState.text = _('Tunnel unreachable (HTTP %s)').format(code);
				}
			}).catch(function() {
				probeState.kind = 'dd-err';
				probeState.text = _('Tunnel unreachable (HTTP %s)').format('000');
			}).finally(function() {
				probeState.running = false;
				refresh(true);
			});
		});
		actions.push(ckBtn);
		actions.push(ckRes);

		body.appendChild(E('div', { 'class': 'dd-actions' }, actions));
	};

	const waitForRunning = function(want, attempts) {
		return fetchStatus().then(function(st) {
			if ((st.running === '1') === want)
				return st;
			if (attempts <= 0)
				throw new Error(want ? _('Service did not start in time.') : _('Service did not stop in time.'));
			return new Promise(function(resolve) { setTimeout(resolve, 250); })
				.then(function() { return waitForRunning(want, attempts - 1); });
		});
	};

	const refresh = function(force) {
		if (busy && !force)
			return Promise.resolve();
		const generation = refreshGeneration;
		return fetchStatus().then(function(st) {
			if (generation !== refreshGeneration || (busy && !force)) return;
			render(st);
		});
	};

	poll.add(refresh);
	render(initial || {});
	refresh();
	card._ddCleanup = function() { poll.remove(refresh); };
	return card;
}

/* ------------------------------------------------------------------------- */
/* settings card (bind / port / watchdog)                                     */
/* ------------------------------------------------------------------------- */
function renderSettingsCard() {
	let m, s, o;
	m = new form.Map('usque', null, null);

	s = m.section(form.NamedSection, 'config', 'usque');
	s.addremove = false;
	s.anonymous = true;

	o = s.option(form.Value, 'bind', _('Bind Address'),
		_('SOCKS5 listen address. Use 127.0.0.1 unless dae/daed run in a network namespace.'));
	o.datatype = 'ipaddr';
	o.default = '127.0.0.1';
	o.rmempty = false;

	o = s.option(form.Value, 'port', _('SOCKS5 Port'));
	o.datatype = 'port';
	o.default = '1080';
	o.rmempty = false;

	o = s.option(form.Flag, 'watchdog', _('Watchdog'),
		_('Restart the tunnel when it stops responding (checked every 5 minutes).'));
	o.default = '1';

	return widgets.wrapSettingsCard(
		_('MASQUE Settings'),
		null,
		m.render(),
		null,
		[]
	).then(function(card) {
		const status = makeStatus();
		const save = E('button', { 'class': 'cbi-button cbi-button-positive' }, _('Save and Apply'));
		save.addEventListener('click', function(ev) {
			ev.preventDefault();
			save.disabled = true;
			m.save(null, true)
				.then(applyUciChanges)
				.then(function() {
					const wd = uci.get('usque', 'config', 'watchdog') === '0' ? 'disable' : 'enable';
					return fs.exec(SCRIPT, ['watchdog-cron', wd]);
				})
				.then(function(res) {
					if (res && res.code !== 0)
						throw new Error((res.stderr || res.stdout || ('exit ' + res.code)).trim());
				})
				.then(fetchStatus)
				.then(function(st) {
					// bind/port changes only take effect on the running service
					if (st.running === '1')
						return execChecked('/etc/init.d/usque', ['restart']);
				})
				.then(function() {
					status.flash(_('Settings saved'), 'ok');
				})
				.catch(function(e) {
					if (e && e.name === 'CBIValidationError')
						status.flash(_('Please fix the highlighted fields.'), 'err', 6000);
					else
						status.flash(_('Save failed: %s').format(e.message || e), 'err', 9000);
				})
				.finally(function() { save.disabled = false; });
		});
		card.appendChild(E('div', { 'class': 'dd-editor-actions' }, [ save, status ]));
		return card;
	});
}

/* ------------------------------------------------------------------------- */
/* configuration card (upload / register / remove)                            */
/* ------------------------------------------------------------------------- */
function renderConfigCard(initial) {
	const st = initial || {};
	const status = makeStatus();
	const configState = E('div', { 'class': 'dd-meta' },
		st.config === '1' ? _('Configuration loaded') : _('No configuration yet \u2014 register or upload one'));
	const fileInput = E('input', { 'type': 'file', 'accept': '.json,application/json', 'style': 'display:none' });
	const uploadBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Upload'));
	const registerBtn = E('button', { 'class': 'cbi-button cbi-button-positive' }, _('Register'));
	const removeBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Remove'));

	uploadBtn.addEventListener('click', function() { fileInput.click(); });
	fileInput.addEventListener('change', function(ev) {
		const file = ev.target.files && ev.target.files[0];
		fileInput.value = '';
		if (!file) return;
		if (file.size > 65536) {
			status.flash(_('Config exceeds the 64 KiB limit.'), 'err', 8000);
			return;
		}
		status.flash(_('Reading config\u2026'), null, 0);
		const reader = new FileReader();
		reader.onerror = function() { status.flash(_('Unable to read the file.'), 'err', 8000); };
		reader.onload = function() {
			const text = String(reader.result || '');
			let parsed = null;
			try { parsed = JSON.parse(text); } catch (e) {}
			if (!parsed || !parsed.private_key || !parsed.endpoint_pub_key) {
				status.flash(_('Not a valid WARP config: private_key / endpoint_pub_key missing.'), 'err', 9000);
				return;
			}
			uploadBtn.disabled = true;
			status.flash(_('Saving config\u2026'), null, 0);
			fs.write(STAGE, text)
				.then(function() { return execChecked(SCRIPT, ['save']); })
				.then(function() {
					configState.textContent = _('Configuration loaded');
					status.flash(_('Config saved'), 'ok');
				})
				.catch(function(e) {
					status.flash(_('Save failed: %s').format(e.message || e), 'err', 9000);
				})
				.finally(function() { uploadBtn.disabled = false; });
		};
		reader.readAsText(file);
	});

	registerBtn.addEventListener('click', function() {
		if (!window.confirm(_('Register a new WARP account? The current config is backed up first and restored if registration fails.')))
			return;
		registerBtn.disabled = true;
		status.flash(_('Registering\u2026 (can take up to a minute)'), null, 0);
		fs.exec(SCRIPT, ['register']).then(function(res) {
			if (res && res.code !== 0)
				throw new Error((res.stderr || res.stdout || ('exit ' + res.code)).trim());
			let logText = '';
			return waitLog(REG_LOG, function(c) {
				logText = c;
				status.flash(lastLine(c), null, 0);
			}).then(function(done) {
				if (done === true) {
					configState.textContent = _('Configuration loaded');
					status.flash(_('Registered \u2014 WARP account ready'), 'ok');
				} else if (done === false) {
					throw new Error(lastLine(logText) || _('Registration failed'));
				} else {
					throw new Error(_('Registration timed out. Check the system log.'));
				}
			});
		}).catch(function(e) {
			status.flash(_('Registration failed: %s').format(e.message || e), 'err', 12000);
		}).finally(function() { registerBtn.disabled = false; });
	});

	removeBtn.addEventListener('click', function() {
		if (!window.confirm(_('Remove the WARP configuration and stop the tunnel?')))
			return;
		removeBtn.disabled = true;
		execChecked(SCRIPT, ['clear'])
			.then(function() {
				configState.textContent = _('No configuration yet \u2014 register or upload one');
				status.flash(_('Configuration removed'), 'ok');
			})
			.catch(function(e) { status.flash(_('Remove failed: %s').format(e.message || e), 'err', 9000); })
			.finally(function() { removeBtn.disabled = false; });
	});

	return E('div', { 'class': 'dd-card' }, [
		E('h4', { 'class': 'dd-card-title' }, _('WARP Configuration')),
		E('div', { 'class': 'dd-settings-descr' },
			_('Upload a WARP config.json exported elsewhere, or register a fresh account directly on the router.')),
		configState,
		E('div', { 'class': 'dd-actions' }, [ uploadBtn, registerBtn, removeBtn, status ]),
		fileInput
	]);
}

/* ------------------------------------------------------------------------- */
/* node import card                                                           */
/* ------------------------------------------------------------------------- */
function renderImportCard(ctx) {
	const status = makeStatus();
	const be = ctx.backend || {};
	const beName = (be.installed && be.installed[be.name]) ? be.name : '';
	const btn = E('button', { 'class': 'cbi-button cbi-button-positive' },
		_('Add node to group "%s"').format(GROUP_NAME));

	if (!beName)
		btn.disabled = true;

	const importDae = function(link) {
		return uci.load('dae').catch(function() {}).then(function() {
			const nodes = uci.sections('dae', 'node') || [];
			let found = null, i;
			for (i = 0; i < nodes.length; i++)
				if (nodes[i].tag === NODE_TAG) { found = nodes[i]; break; }
			let sid = found ? found['.name'] : '';
			if (!sid) {
				const base = 'warp_usque_node';
				sid = base;
				let n = 1;
				while (uci.get('dae', sid))
					sid = base + '_' + (++n);
				uci.add('dae', 'node', sid);
			}
			uci.set('dae', sid, 'tag', NODE_TAG);
			uci.set('dae', sid, 'link', link);
			uci.set('dae', sid, 'enabled', '1');

			const groups = uci.sections('dae', 'group') || [];
			const existing = groups.find(function(g) { return g.name === GROUP_NAME; });
			if (!existing) {
				const base = 'warp_group';
				let gsid = base;
				let n = 1;
				while (uci.get('dae', gsid))
					gsid = base + '_' + (++n);
				uci.add('dae', 'group', gsid);
				uci.set('dae', gsid, 'name', GROUP_NAME);
				uci.set('dae', gsid, 'policy', 'min_moving_avg');
				uci.set('dae', gsid, 'source', [ NODE_TAG ]);
			} else if (existing.source && existing.source.length && existing.source.indexOf(NODE_TAG) < 0) {
				// an empty source already includes every node; a filtered one
				// needs our tag or the node would never match the group
				uci.set('dae', existing['.name'], 'source', existing.source.concat([ NODE_TAG ]));
			}
			return applyUciChanges().then(function() {
				return execChecked(GENERATOR, ['generate']);
			}).then(function() {
				status.flash(_('Node added to group "%s" on dae. Start dae to apply routing.').format(GROUP_NAME), 'ok', 8000);
			});
		});
	};

	const importDaed = function(link) {
		const endpoint = daedEndpoint();
		let token = '';
		const norm = clashConverter.normalizeLink(link);

		const load = function(force) {
			return requestDaedToken(endpoint, force).then(function(auth) {
				token = auth.token;
				return graphQL(endpoint, DAED_STATE, {}, token);
			});
		};

		return load(false).catch(function(e) {
			if (daedSession.isAccessDenied(e))
				return load(true);
			throw e;
		}).then(function(state) {
			let node = null;
			(((state || {}).nodes || {}).edges || []).forEach(function(n) {
				if (clashConverter.normalizeLink(n.link) === norm)
					node = n;
			});
			const ensureNode = node ? Promise.resolve({ id: node.id, created: false })
				: graphQL(endpoint,
					'mutation ImportNodes($args:[ImportArgument!]!){importNodes(rollbackError:false,args:$args){link error node{id}}}',
					{ args: [ { link: link, tag: 'WARP MASQUE' } ] }, token).then(function(result) {
						const row = ((result || {}).importNodes || [])[0] || {};
						if (row.node && row.node.id)
							return { id: row.node.id, created: true };
						if (row.error && /already exists/i.test(row.error))
							return load(false).then(function(fresh) {
								let retry = null;
								(((fresh || {}).nodes || {}).edges || []).forEach(function(n) {
									if (clashConverter.normalizeLink(n.link) === norm)
										retry = n;
								});
								if (retry) return { id: retry.id, created: false };
								throw new Error(row.error);
							});
						throw new Error(row.error || _('No usable nodes were imported'));
					});

			return ensureNode.then(function(r) {
				let group = null;
				((state || {}).groups || []).forEach(function(g) {
					if (g.name === GROUP_NAME) group = g;
				});
				const ensureGroup = group ? Promise.resolve(group.id)
					: graphQL(endpoint,
						'mutation CreateGroup($name:String!,$policy:Policy!){createGroup(name:$name,policy:$policy){id}}',
						{ name: GROUP_NAME, policy: 'min_moving_avg' }, token)
						.then(function(v) { return v.createGroup.id; });

				return ensureGroup.then(function(gid) {
					return graphQL(endpoint,
						'mutation AddNodes($id:ID!,$nodeIDs:[ID!]!){groupAddNodes(id:$id,nodeIDs:$nodeIDs)}',
						{ id: gid, nodeIDs: [ r.id ] }, token)
						.catch(function(e) {
							// already a member is success, anything else is not
							if (!/exist/i.test(String(e.message || e)))
								throw e;
						})
						.then(function() { return r; });
				});
			});
		}).then(function(r) {
			status.flash(r.created
				? _('Node added to group "%s" on daed.').format(GROUP_NAME)
				: _('Node already existed \u2014 linked to group "%s".').format(GROUP_NAME), 'ok', 8000);
		});
	};

	btn.addEventListener('click', function(ev) {
		ev.preventDefault();
		if (btn.disabled) return;
		btn.disabled = true;
		status.flash(_('Adding node\u2026'), null, 0);
		fetchStatus()
			.then(function(st) { return socksLink(st); })
			.then(function(link) {
				return beName === 'dae' ? importDae(link) : importDaed(link);
			})
			.catch(function(e) {
				status.flash(_('Import failed: %s').format(e.message || e), 'err', 12000);
			})
			.finally(function() { btn.disabled = false; });
	});

	return E('div', { 'class': 'dd-card' }, [
		E('h4', { 'class': 'dd-card-title' }, _('Node Import')),
		E('div', { 'class': 'dd-settings-descr' },
			!beName
				? _('Install dae or daed first, then import the tunnel as a SOCKS5 node.')
				: _('Adds the tunnel as node "%s" to group "%s" on %s. Set that group as a route policy yourself.').format(NODE_TAG, GROUP_NAME, beName)),
		E('div', { 'class': 'dd-actions' }, [ btn, status ])
	]);
}

/* ------------------------------------------------------------------------- */
/* install card (usque package missing)                                       */
/* ------------------------------------------------------------------------- */
function renderInstallCard() {
	const status = makeStatus();
	const btn = E('button', { 'class': 'cbi-button cbi-button-positive' }, _('Install'));

	btn.addEventListener('click', function(ev) {
		ev.preventDefault();
		if (btn.disabled) return;
		btn.disabled = true;
		status.flash(_('Installing usque\u2026'), null, 0);
		fs.exec(UPDATER, ['usque']).then(function(res) {
			if (res && res.code !== 0)
				throw new Error((res.stderr || res.stdout || ('exit ' + res.code)).trim());
			let logText = '';
			return waitLog(PKG_LOG, function(c) {
				logText = c;
				status.flash(lastLine(c), null, 0);
			}).then(function(done) {
				if (done === true) {
					status.flash(_('usque installed. Reloading\u2026'), 'ok', 0);
					setTimeout(function() { window.location.reload(); }, 1200);
				} else if (done === false) {
					throw new Error(lastLine(logText) || _('Install failed'));
				} else {
					throw new Error(_('Install timed out. Check the package log.'));
				}
			});
		}).catch(function(e) {
			status.flash(_('Install failed: %s').format(e.message || e), 'err', 12000);
		}).finally(function() { btn.disabled = false; });
	});

	return E('div', { 'class': 'dd-card dd-warning' }, [
		E('h4', { 'class': 'dd-card-title' }, _('usque is not installed')),
		E('div', { 'class': 'dd-settings-descr' },
			_('The WARP MASQUE tunnel needs the usque package from the package feed.')),
		E('div', { 'class': 'dd-actions' }, [ btn, status ])
	]);
}

/* ------------------------------------------------------------------------- */
/* view                                                                        */
/* ------------------------------------------------------------------------- */
return view.extend({
	load: function() {
		return Promise.all([
			backend.detectBackend().catch(function() { return null; }),
			uci.load('usque').catch(function() {}),
			uci.load('daed').catch(function() {}),
			uci.load('dae').catch(function() {}),
			uci.load('daede').catch(function() {}),
			fetchStatus()
		]).then(function(r) {
			return { backend: r[0], st: r[5] || {} };
		});
	},

	render: function(ctx) {
		const st = ctx.st || {};
		const installed = st.installed === '1';

		const children = [
			E('style', {}, styles.CSS),
			renderStatusCard(st)
		];

		if (installed) {
			children.push(renderSettingsCard());
			children.push(renderConfigCard(st));
			children.push(renderImportCard(ctx));
		} else {
			children.push(renderInstallCard());
		}

		return Promise.all(children.map(function(child) {
			return child && child.then ? child : Promise.resolve(child);
		})).then(function(nodes) {
			return E('div', { 'class': 'dd-wrap dd-config-page' }, nodes);
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
