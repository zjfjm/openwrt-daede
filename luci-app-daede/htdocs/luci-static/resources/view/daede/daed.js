// SPDX-License-Identifier: Apache-2.0

'use strict';
'require baseclass';
'require form';
'require fs';
'require ui';
'require uci';
'require view.daede.widgets as widgets';

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

const DEFAULT_DASHBOARD_USER = 'admin';
const DEFAULT_DASHBOARD_PASS = '123456';

function daedEndpoint() {
	/* HTTPS page: browsers block plain-HTTP :2023 fetches as mixed content,
	   so relay through the same-origin CGI (as converter.js does) */
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

function daedLogin(endpoint, username, password) {
	return graphQL(endpoint,
		'query Login($username:String!,$password:String!){token(username:$username,password:$password)}',
		{ username: username, password: password }).then(function(r) { return r.token; });
}

function promptFields(title, fields, submitLabel) {
	return new Promise(function(resolve) {
		const inputs = {};
		const cancel = E('button', { 'class': 'btn cbi-button' }, _('Cancel'));
		const submit = E('button', { 'class': 'btn cbi-button cbi-button-positive' }, submitLabel);
		const rows = fields.map(function(f) {
			const el = E('input', {
				'class': f.secret ? 'cbi-input-password' : 'cbi-input-text',
				'type': f.secret ? 'password' : 'text',
				'autocomplete': 'off'
			});
			if (f.value)
				el.value = f.value;
			inputs[f.key] = el;
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, f.label),
				E('div', { 'class': 'cbi-value-field' }, el)
			]);
		});

		const clearSecrets = function() {
			fields.forEach(function(f) { if (f.secret) inputs[f.key].value = ''; });
		};

		cancel.addEventListener('click', function() {
			clearSecrets();
			ui.hideModal();
			resolve(null);
		});
		submit.addEventListener('click', function() {
			const out = {};
			for (let i = 0; i < fields.length; i++) {
				const f = fields[i];
				let v = inputs[f.key].value;
				if (!f.secret) v = v.trim();
				if (!v) { inputs[f.key].focus(); return; }
				out[f.key] = v;
			}
			clearSecrets();
			ui.hideModal();
			resolve(out);
		});

		ui.showModal(title, [
			E('div', { 'class': 'dd-daed-login' }, rows.concat([
				E('div', { 'class': 'right dd-daed-login-actions' }, [ cancel, ' ', submit ])
			]))
		]);
		const first = inputs[fields[0].key];
		if (first) first.focus();
	});
}

function renderDaedSettings() {
	let m, s, o;
	m = new form.Map('daed', null, null);

	s = m.section(form.NamedSection, 'config', 'daed');
	s.addremove = false;
	s.anonymous = true;

	o = s.option(form.Value, 'listen_addr', _('Listen Address'));
	o.datatype = 'ipaddrport(1)';
	o.default = '0.0.0.0:2023';
	o.rmempty = false;

	o = s.option(form.Value, 'dashboard_username', _('daed Username'),
		_('Used by LuCI to access daed (subscription updates and import). If daed is not initialized yet, this account is used to create the daed admin.'));
	o.placeholder = 'admin';
	o.rmempty = false;

	o = s.option(form.Value, 'dashboard_password', _('daed Password'));
	o.password = true;

	o = s.option(form.Flag, 'subscribe_auto_update', _('Enable subscription auto-update'));
	o.default = '0';

	o = s.option(form.ListValue, 'subscribe_update_cycle', _('Update Cycle'));
	o.value('daily', _('Daily'));
	o.value('weekly', _('Weekly'));
	o.default = 'daily';
	o.depends('subscribe_auto_update', '1');

	o = s.option(form.ListValue, 'subscribe_update_hour', _('Update Time'));
	for (let h = 0; h < 24; h++) {
		const hh = ('0' + h).slice(-2);
		o.value(String(h), hh + ':00');
	}
	o.default = '4';
	o.depends('subscribe_auto_update', '1');

	o = s.option(form.Value, 'log_maxsize', _('Max Log Size (MB)'),
		_('Rotate the log file once it grows past this many megabytes.'));
	o.datatype = 'uinteger';
	o.default = '5';

	o = s.option(form.Value, 'log_maxbackups', _('Max Log Backups'),
		_('Number of rotated log files to keep.'));
	o.datatype = 'uinteger';
	o.default = '1';

	return widgets.wrapSettingsCard(
		_('daede Settings'),
		null,
		m.render(),
		_('Log Settings'),
		['log_maxsize', 'log_maxbackups']
	).then(function(card) {
		/* native Save/Apply footer is suppressed view-wide, so daed carries its
		   own primary action */
		const status = E('span', { 'class': 'dd-editor-status' }, '');
		let statusTimer = null;
		function flash(text, kind, hold) {
			status.textContent = text;
			status.classList.remove('ok', 'err');
			if (kind) status.classList.add(kind);
			status.classList.add('show');
			if (statusTimer) clearTimeout(statusTimer);
			statusTimer = setTimeout(function() { status.classList.remove('show'); }, hold || 3000);
		}

		/* ---- account credentials: initialize / change (daed GraphQL) ---- */
		const ep = daedEndpoint();
		const findRow = function(title) {
			const rows = card.querySelectorAll('.cbi-value');
			for (let i = 0; i < rows.length; i++) {
				const t = rows[i].querySelector('.cbi-value-title');
				if (t && t.textContent.trim() === title)
					return rows[i];
			}
			return null;
		};
		const syncAccountInputs = function(user, pass) {
			const uRow = findRow(_('daed Username'));
			const pRow = findRow(_('daed Password'));
			if (uRow) { const el = uRow.querySelector('input'); if (el) el.value = user; }
			if (pRow) { const el = pRow.querySelector('input'); if (el) el.value = pass; }
		};
		const commitAccount = function(user, pass, okMsg) {
			uci.set('daed', 'config', 'dashboard_username', user);
			uci.set('daed', 'config', 'dashboard_password', pass);
			return applyUciChanges().then(function() {
				syncAccountInputs(user, pass);
				flash(okMsg.format(user, pass), 'ok', 9000);
			});
		};
		const obtainSession = function() {
			const savedU = uci.get('daed', 'config', 'dashboard_username') || '';
			const savedP = uci.get('daed', 'config', 'dashboard_password') || '';
			const attempt = (savedU && savedP)
				? daedLogin(ep, savedU, savedP).catch(function() { return ''; })
				: Promise.resolve('');
			return attempt.then(function(token) {
				if (token)
					return { token: token, username: savedU, password: savedP };
				return promptFields(_('Verify Current Account'), [
					{ key: 'username', label: _('Username'), value: savedU || 'admin' },
					{ key: 'password', label: _('Password'), secret: true }
				], _('Sign in')).then(function(cred) {
					if (!cred) return null;
					return daedLogin(ep, cred.username, cred.password).then(function(t2) {
						return { token: t2, username: cred.username, password: cred.password };
					});
				});
			});
		};
		const applyAccountChange = function(sess, newUser, newPass) {
			if (sess.username === newUser && sess.password === newPass)
				return Promise.resolve();
			let chain = Promise.resolve();
			if (sess.username !== newUser)
				chain = chain.then(function() {
					return graphQL(ep,
						'mutation UpdateUsername($username:String!){updateUsername(username:$username)}',
						{ username: newUser }, sess.token);
				});
			return chain.then(function() {
				return graphQL(ep,
					'mutation UpdatePassword($currentPassword:String!,$newPassword:String!){updatePassword(currentPassword:$currentPassword,newPassword:$newPassword)}',
					{ currentPassword: sess.password, newPassword: newPass }, sess.token);
			});
		};
		const doInit = function() {
			return graphQL(ep, 'query{numberUsers}').then(function(r) {
				if (!r || r.numberUsers === 0)
					return graphQL(ep,
						'mutation Init($username:String!,$password:String!){createUser(username:$username,password:$password)}',
						{ username: DEFAULT_DASHBOARD_USER, password: DEFAULT_DASHBOARD_PASS });
				return obtainSession().then(function(sess) {
					if (!sess) return null;
					return applyAccountChange(sess, DEFAULT_DASHBOARD_USER, DEFAULT_DASHBOARD_PASS);
				});
			}).then(function(res) {
				if (res === null) return;
				return commitAccount(DEFAULT_DASHBOARD_USER, DEFAULT_DASHBOARD_PASS,
					_('Account initialized: %s / %s (plain text)'));
			});
		};
		const doChange = function() {
			return graphQL(ep, 'query{numberUsers}').then(function(r) {
				if (!r || r.numberUsers === 0)
					throw new Error(_('daed is not initialized yet. Use Initialize Account & Password first.'));
				return promptFields(_('Change Account & Password'), [
					{ key: 'curUser', label: _('Current Username'), value: uci.get('daed', 'config', 'dashboard_username') || 'admin' },
					{ key: 'curPass', label: _('Current Password'), secret: true },
					{ key: 'newUser', label: _('New Username'), value: uci.get('daed', 'config', 'dashboard_username') || 'admin' },
					{ key: 'newPass', label: _('New Password'), secret: true }
				], _('Save'));
			}).then(function(v) {
				if (!v) return;
				return daedLogin(ep, v.curUser, v.curPass).then(function(token) {
					return applyAccountChange({ token: token, username: v.curUser, password: v.curPass }, v.newUser, v.newPass);
				}).then(function() {
					return commitAccount(v.newUser, v.newPass, _('Account updated: %s / %s (plain text)'));
				});
			});
		};

		const initBtn = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button' }, _('Initialize Account & Password'));
		const changeBtn = E('button', { 'class': 'cbi-button', 'type': 'button' }, _('Change Account & Password'));
		const acctNote = E('div', { 'class': 'dd-acct-note' },
			_('After initialization: username %s, password %s (shown in plain text)').format(DEFAULT_DASHBOARD_USER, DEFAULT_DASHBOARD_PASS));
		const acctBox = E('div', { 'class': 'dd-acct-box' }, [ initBtn, ' ', changeBtn, acctNote ]);
		const runOp = function(op) {
			initBtn.disabled = true;
			changeBtn.disabled = true;
			op().catch(function(e) {
				flash(_('Account operation failed: %s').format(e && e.message ? e.message : e), 'err', 9000);
			}).finally(function() {
				initBtn.disabled = false;
				changeBtn.disabled = false;
			});
		};
		initBtn.addEventListener('click', function(ev) { ev.preventDefault(); runOp(doInit); });
		changeBtn.addEventListener('click', function(ev) { ev.preventDefault(); runOp(doChange); });
		const pwRow = findRow(_('daed Password'));
		if (pwRow && pwRow.parentNode)
			pwRow.insertAdjacentElement('afterend', acctBox);
		else
			card.appendChild(acctBox);

		const save = E('button', { 'class': 'cbi-button cbi-button-positive' }, _('Save and Apply'));
		const update = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Update subscriptions now'));
		update.addEventListener('click', function(ev) {
			ev.preventDefault();
			update.disabled = true;
			flash(_('Updating daed subscriptions…'));
			fs.exec('/usr/share/luci-app-daede/daed-sub-update.sh', []).then(function(res) {
				if (res && res.code !== 0) {
					const err = (res.stderr || res.stdout || ('exit ' + res.code)).trim().split('\n')[0];
					flash(_('Subscription update failed: %s').format(err), 'err', 9000);
				} else {
					flash(_('Subscriptions updated and applied'), 'ok');
				}
			}).catch(function(e) {
				flash(_('Subscription update failed: %s').format(e.message || e), 'err', 9000);
			}).finally(function() { update.disabled = false; });
		});
		save.addEventListener('click', function(ev) {
			ev.preventDefault();
			save.disabled = true;
			m.save(null, true)
				.then(applyUciChanges)
				.then(function() {
					const enabled = uci.get('daed', 'config', 'subscribe_auto_update') === '1';
					return fs.exec('/usr/share/luci-app-daede/daed-sub-cron.sh', [ enabled ? 'enable' : 'disable' ]);
				})
				.then(function(res) {
					if (res && res.code !== 0)
						throw new Error((res.stderr || res.stdout || ('exit ' + res.code)).trim());
				})
				.then(function() {
					/* no success popup — the reload is feedback enough */
					setTimeout(function() { window.location.reload(); }, 500);
				})
				.catch(function(e) {
					if (e && e.name === 'CBIValidationError')
						flash(_('Please fix the highlighted fields.'), 'err', 6000);
					else
						flash(_('Save failed: %s').format(e.message || e), 'err', 9000);
				})
				.finally(function() { save.disabled = false; });
		});
		card.appendChild(E('div', { 'class': 'dd-editor-actions' }, [ update, save, status ]));
		return card;
	});
}

return baseclass.extend({ renderDaedSettings: renderDaedSettings });
