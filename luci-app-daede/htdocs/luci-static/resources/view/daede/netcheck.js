// SPDX-License-Identifier: Apache-2.0

'use strict';
'require fs';
'require baseclass';

/* IP + access-check card for the Settings page. UI, probes and behaviour are
   ported from OpenClash's myip.htm (GPL-3.0, © vernesong/OpenClash,
   https://github.com/vernesong/OpenClash). Router-side probing runs
   /usr/share/luci-app-daede/net-check.sh through fs.exec instead of OpenClash's
   streaming Lua controller, and every DOM lookup is scoped to the card node
   (this view may build the card while it is still detached from the document,
   so document-wide ids cannot be used). */

const IP_FIELDS = {
	pcol:  { id: 'dd-nip-pcol',  geo: 'dd-nip-pcol-geo' },
	ipip:  { id: 'dd-nip-ipip',  geo: 'dd-nip-ipip-geo' },
	ipsb:  { id: 'dd-nip-ipsb',  geo: 'dd-nip-ipsb-geo' },
	ipify: { id: 'dd-nip-ipify', geo: 'dd-nip-ipify-geo' }
};

const PRIVACY_KEY = 'daede_privacy_my_ip';
const MODE_KEY = 'daede_myip_check_mode';
const MASK = '***.***.***.***';

const INTERVAL = {
	HTTP_CHECK_MIN: 20 * 1000,
	HTTP_CHECK_MAX: 50 * 1000,
	IP_CHECK_MIN: 50 * 1000,
	IP_CHECK_MAX: 80 * 1000
};

const ICON_PATHS = {
	baidu: 'M9.154 0C7.71 0 6.54 1.658 6.54 3.707c0 2.051 1.171 3.71 2.615 3.71 1.446 0 2.614-1.659 2.614-3.71C11.768 1.658 10.6 0 9.154 0zm7.025.594C14.86.58 13.347 2.589 13.2 3.927c-.187 1.745.25 3.487 2.179 3.735 1.933.25 3.175-1.806 3.422-3.364.252-1.555-.995-3.364-2.362-3.674a1.218 1.218 0 0 0-.261-.03zM3.582 5.535a2.811 2.811 0 0 0-.156.008c-2.118.19-2.428 3.24-2.428 3.24-.287 1.41.686 4.425 3.297 3.864 2.617-.561 2.262-3.68 2.183-4.362-.125-1.018-1.292-2.773-2.896-2.75zm16.534 1.753c-2.308 0-2.617 2.119-2.617 3.616 0 1.43.121 3.425 2.988 3.362 2.867-.063 2.553-3.238 2.553-3.988 0-.745-.62-2.99-2.924-2.99zm-8.264 2.478c-1.424.014-2.708.925-3.323 1.947-1.118 1.868-2.863 3.05-3.112 3.363-.25.309-3.61 2.116-2.864 5.42.746 3.301 3.365 3.237 3.365 3.237s1.93.19 4.171-.31c2.24-.495 4.17.123 4.17.123s5.233 1.748 6.665-1.616c1.43-3.364-.808-5.109-.808-5.109s-2.99-2.306-4.736-4.798c-1.072-1.665-2.348-2.268-3.528-2.257zm-2.234 3.84 1.542.024v8.197H7.758c-1.47-.291-2.055-1.292-2.13-1.462-.072-.173-.488-.976-.268-2.343.635-2.049 2.447-2.196 2.447-2.196h1.81zm3.964 2.39v3.881c.096.413.612.488.612.488h1.614v-4.343h1.689v5.782h-3.915c-1.517-.39-1.59-1.465-1.59-1.465v-4.317zm-5.458 1.147c-.66.197-.978.708-1.05.928-.076.22-.247.78-.1 1.269.294 1.095 1.248 1.144 1.248 1.144h1.37v-3.34z',
	netease: 'M13.046 9.388a3.919 3.919 0 0 0-.66.19c-.809.312-1.447.991-1.666 1.775a2.269 2.269 0 0 0-.074.81c.048.546.333 1.05.764 1.35a1.483 1.483 0 0 0 2.01-.286c.406-.531.355-1.183.24-1.636-.098-.387-.22-.816-.345-1.249a64.76 64.76 0 0 1-.269-.954zm-.82 10.07c-3.984 0-7.224-3.24-7.224-7.223 0-.98.226-3.02 1.884-4.822A7.188 7.188 0 0 1 9.502 5.6a.792.792 0 1 1 .587 1.472 5.619 5.619 0 0 0-2.795 2.462 5.538 5.538 0 0 0-.707 2.7 5.645 5.645 0 0 0 5.638 5.638c1.844 0 3.627-.953 4.542-2.428 1.042-1.68.772-3.931-.627-5.238a3.299 3.299 0 0 0-1.437-.777c.172.589.334 1.18.494 1.772.284 1.12.1 2.181-.519 2.989-.39.51-.956.888-1.592 1.064a3.038 3.038 0 0 1-2.58-.44 3.45 3.45 0 0 1-1.44-2.514c-.04-.467.002-.93.128-1.376.35-1.256 1.356-2.339 2.622-2.826a5.5 5.5 0 0 1 .823-.246l-.134-.505c-.37-1.371.25-2.579 1.547-3.007.329-.109.68-.145 1.025-.105.792.09 1.476.592 1.709 1.023.258.507-.096 1.153-.706 1.153a.788.788 0 0 1-.54-.213c-.088-.08-.163-.174-.259-.247a.825.825 0 0 0-.632-.166.807.807 0 0 0-.634.551c-.056.191-.031.406.02.595.07.256.159.597.217.82 1.11.098 2.162.54 2.97 1.296 1.974 1.844 2.35 4.886.892 7.233-1.197 1.93-3.509 3.177-5.889 3.177zM0 12c0 6.627 5.373 12 12 12s12-5.373 12-12S18.627 0 12 0 0 5.373 0 12Z',
	github: 'M512 0C229.12 0 0 229.12 0 512c0 226.56 146.56 417.92 350.08 485.76 25.6 4.48 35.2-10.88 35.2-24.32 0-12.16-.64-52.48-.64-95.36-128.64 23.68-161.92-31.36-172.16-60.16-5.76-14.72-30.72-60.16-52.48-72.32-17.92-9.6-43.52-33.28-.64-33.92 40.32-.64 69.12 37.12 78.72 52.48 46.08 77.44 119.68 55.68 149.12 42.24 4.48-33.28 17.92-55.68 32.64-68.48-113.92-12.8-232.96-56.96-232.96-252.8 0-55.68 19.84-101.76 52.48-137.6-5.12-12.8-23.04-65.28 5.12-135.68 0 0 42.88-13.44 140.8 52.48 40.96-11.52 84.48-17.28 128-17.28s87.04 5.76 128 17.28c97.92-66.56 140.8-52.48 140.8-52.48 28.16 70.4 10.24 122.88 5.12 135.68 32.64 35.84 52.48 81.28 52.48 137.6 0 196.48-119.68 240-233.6 252.8 18.56 16 34.56 46.72 34.56 94.72 0 68.48-.64 123.52-.64 140.8 0 13.44 9.6 29.44 35.2 24.32C877.44 929.92 1024 737.92 1024 512 1024 229.12 794.88 0 512 0',
	youtube: 'M250.346 28.075A32.18 32.18 0 0 0 227.69 5.418C207.824 0 127.87 0 127.87 0S47.912.164 28.046 5.582A32.18 32.18 0 0 0 5.39 28.24c-6.009 35.298-8.34 89.084.165 122.97a32.18 32.18 0 0 0 22.656 22.657c19.866 5.418 99.822 5.418 99.822 5.418s79.955 0 99.82-5.418a32.18 32.18 0 0 0 22.657-22.657c6.338-35.348 8.291-89.1-.164-123.134Z'
};

function randomBetween(min, max) {
	return Math.floor(Math.random() * (max - min + 1) + min);
}

/* LuCI's E()/dom.create uses document.createElement without a namespace, which
   yields non-rendering HTML-namespace <svg> elements, so icon nodes are built
   with createElementNS instead. */
function S(tag, attrs, children) {
	const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
	if (attrs)
		Object.keys(attrs).forEach(function(key) {
			if (attrs[key] != null) node.setAttribute(key, attrs[key]);
		});
	if (children != null)
		(Array.isArray(children) ? children : [children]).forEach(function(child) {
			node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
		});
	return node;
}

function latencyClass(ms) {
	if (ms <= 500) return 'dd-nip-fast';
	if (ms <= 1000) return 'dd-nip-mid';
	return 'dd-nip-slow';
}

function latencyColor(lc) {
	if (lc === 'dd-nip-mid') return 'var(--dd-nip-warn)';
	if (lc === 'dd-nip-slow') return 'var(--dd-nip-err)';
	return 'var(--dd-nip-ok)';
}

function decodeGeoHex(hex) {
	try {
		const bytes = new Uint8Array(hex.match(/.{2}/g).map(function(h) { return parseInt(h, 16); }));
		try {
			return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
		} catch (e) {
			return new TextDecoder('gbk').decode(bytes);
		}
	} catch (e) {
		return '';
	}
}

function brandIcon(name) {
	const viewBox = name === 'github' ? '0 0 1024 1024'
		: name === 'youtube' ? '0 0 256 180' : '0 0 24 24';
	const children = [ S('path', { 'fill': name === 'youtube' ? 'red' : 'currentColor', 'fill-rule': name === 'github' ? 'evenodd' : null, 'd': ICON_PATHS[name] }) ];
	if (name === 'youtube')
		children.push(S('path', { 'fill': '#FFF', 'd': 'm102.421 128.06 66.328-38.418-66.328-38.418z' }));
	return S('svg', { 'class': 'dd-nip-icon ic-' + name, 'viewBox': viewBox, 'xmlns': 'http://www.w3.org/2000/svg' }, children);
}

function renderNetCheckCard() {
	const SITES = [
		{ svc: 'baidu',   domain: 'www.baidu.com',          label: _('Baidu Search'), icon: 'baidu' },
		{ svc: '163',     domain: 's1.music.126.net/style', label: _('NetEase Music'), icon: 'netease' },
		{ svc: 'github',  domain: 'github.com',             label: 'GitHub',          icon: 'github' },
		{ svc: 'youtube', domain: 'www.youtube.com',        label: 'YouTube',         icon: 'youtube' }
	];
	const QUERYING = _('Querying...');
	const refs = { ip: {}, geo: {}, dot: {}, lat: {}, spark: {} };
	let disposed = false;
	let refreshHttp = null;
	let refreshIp = null;
	let routerBusy = false;
	let routerGeneration = 0;
	let jsonpActive = false;
	let useRouterMode = true;

	const SpeedHistory = {
		max: 10,
		data: { baidu: [], '163': [], github: [], youtube: [] },
		_prevPath: { baidu: null, '163': null, github: null, youtube: null },
		push: function(svc, ms) {
			this.data[svc].push(ms);
			if (this.data[svc].length > this.max) this.data[svc].shift();
		},
		_buildPath: function(pts) {
			const w = 90, h = 20, pad = 4;
			const max = Math.max.apply(null, pts), min = Math.min.apply(null, pts);
			const range = max - min || 1;
			const stepX = (w - pad * 2) / (this.max - 1);
			let endX, endY;
			const points = [];
			const d = pts.map(function(v, i) {
				const x = (pad + i * stepX).toFixed(1);
				const y = (h - pad - (v - min) / range * (h - pad * 2)).toFixed(1);
				points.push({ x: x, y: y, v: v });
				if (i === pts.length - 1) { endX = x; endY = y; }
				return (i === 0 ? 'M' : 'L') + x + ',' + y;
			}).join(' ');
			return { d: d, w: w, h: h, endX: endX, endY: endY, points: points, stepX: stepX };
		},
		renderSparkline: function(svc, el, lc) {
			const pts = this.data[svc];
			const stroke = latencyColor(lc);
			if (!el) return;
			if (pts.length < 2) {
				const w = 90, h = 20;
				const d = 'M28.0,10.0 L36.0,10.0 L40.0,5.0 L43.0,15.0 L47.0,10.0 L61.0,10.0';
				el.innerHTML =
					'<svg viewBox="0 0 ' + w + ' ' + h + '" class="dd-nip-spark-svg">' +
					'<path d="' + d + '" class="spark-ghost" style="stroke:' + stroke + '"/>' +
					'</svg>';
				const ghostEl = el.querySelector('.spark-ghost');
				if (ghostEl && ghostEl.getTotalLength) {
					const len = ghostEl.getTotalLength();
					if (len > 0) {
						ghostEl.style.strokeDasharray = len;
						ghostEl.animate([
							{ strokeDashoffset: len, offset: 0 },
							{ strokeDashoffset: 0, offset: 0.55 },
							{ strokeDashoffset: len, offset: 1 }
						], { duration: 5500, easing: 'ease-out', iterations: Infinity });
					}
				}
				return;
			}

			const g = this._buildPath(pts);
			const points = g.points || [];

			let ghostHTML = '';
			if (this._prevPath[svc] && pts.length >= 3)
				ghostHTML = '<path d="' + this._prevPath[svc] + '" class="spark-ghost" style="stroke:' + stroke + '"/>';
			this._prevPath[svc] = g.d;

			el.innerHTML =
				'<svg viewBox="0 0 ' + g.w + ' ' + g.h + '" class="dd-nip-spark-svg">' +
				ghostHTML +
				'<path d="' + g.d + '" class="spark-line" style="stroke:' + stroke + '"/>' +
				'<line x1="' + g.endX + '" y1="0" x2="' + g.endX + '" y2="' + g.h + '" class="spark-crosshair" stroke="' + stroke + '" stroke-width="1" vector-effect="non-scaling-stroke" style="display:none"/>' +
				'<circle cx="' + g.endX + '" cy="' + g.endY + '" r="3" class="spark-hover-dot" style="fill:' + stroke + ';display:none"/>' +
				'<circle cx="' + g.endX + '" cy="' + g.endY + '" r="3" class="spark-dot-glow" style="fill:' + stroke + '"/>' +
				'<circle cx="' + g.endX + '" cy="' + g.endY + '" r="2.5" class="spark-dot" style="fill:' + stroke + '"/>' +
				'</svg>';

			const lineEl = el.querySelector('.spark-line');
			if (lineEl && lineEl.getTotalLength) {
				const len = lineEl.getTotalLength();
				if (len > 0) {
					lineEl.style.strokeDasharray = len;
					lineEl.style.strokeDashoffset = len;
					lineEl.getBoundingClientRect();
					lineEl.style.transition = 'stroke-dashoffset 3s ease-out';
					requestAnimationFrame(function() { lineEl.style.strokeDashoffset = '0'; });
				}
			}

			const svgEl = el.querySelector('.dd-nip-spark-svg');
			const crosshair = el.querySelector('.spark-crosshair');
			if (svgEl && crosshair && points.length >= 2) {
				const hoverDot = el.querySelector('.spark-hover-dot');
				const tip = document.createElement('div');
				tip.className = 'spark-tip';
				tip.style.display = 'none';
				el.appendChild(tip);

				const showAt = function(clientX, clientY) {
					const svgRect = svgEl.getBoundingClientRect();
					let ctm = null;
					try { ctm = svgEl.getScreenCTM(); } catch (err) {}
					let x = -1;
					if (ctm) {
						const pt = svgEl.createSVGPoint();
						pt.x = clientX;
						pt.y = clientY;
						x = pt.matrixTransform(ctm.inverse()).x;
					}
					if (x < 0) return;

					let nearest = points[0];
					let best = Math.abs(parseFloat(points[0].x) - x);
					for (let k = 1; k < points.length; k++) {
						const dv = Math.abs(parseFloat(points[k].x) - x);
						if (dv < best) { best = dv; nearest = points[k]; }
					}
					if (best > g.stepX / 2) { hideAll(); return; }

					crosshair.setAttribute('x1', nearest.x);
					crosshair.setAttribute('x2', nearest.x);
					crosshair.setAttribute('y1', 0);
					crosshair.setAttribute('y2', g.h);
					crosshair.style.display = 'block';

					hoverDot.setAttribute('cx', nearest.x);
					hoverDot.setAttribute('cy', nearest.y);
					hoverDot.style.display = 'block';

					const elRect = el.getBoundingClientRect();
					const ep = svgEl.createSVGPoint();
					ep.x = parseFloat(nearest.x);
					ep.y = parseFloat(nearest.y);
					const epScreen = ep.matrixTransform(ctm);
					const px = epScreen.x - elRect.left;
					tip.textContent = nearest.v + ' ms';
					tip.style.color = latencyColor(latencyClass(nearest.v));
					tip.style.display = 'block';
					const tw = tip.offsetWidth;
					let left = px - tw / 2;
					left = Math.max(0, Math.min(left, el.clientWidth - tw));
					tip.style.left = left + 'px';
					tip.style.top = '-17px';
				};

				const hideAll = function() {
					crosshair.style.display = 'none';
					hoverDot.style.display = 'none';
					tip.style.display = 'none';
				};

				el.onmousemove = function(e) { showAt(e.clientX, e.clientY); };
				el.onmouseleave = hideAll;
				el.ontouchstart = function(e) { e.preventDefault(); const t = e.touches && e.touches[0]; if (t) showAt(t.clientX, t.clientY); };
				el.ontouchmove = function(e) { e.preventDefault(); const t = e.touches && e.touches[0]; if (t) showAt(t.clientX, t.clientY); };
				el.ontouchend = hideAll;
				el.ontouchcancel = hideAll;
			}
		},
		reset: function(svc) {
			this.data[svc] = [];
			this._prevPath[svc] = null;
		}
	};

	const ipList = E('div', { 'class': 'dd-nip-list' });
	Object.keys(IP_FIELDS).forEach(function(key) {
		const ipEl = E('span', { 'class': 'dd-nip-ip', 'id': IP_FIELDS[key].id }, QUERYING);
		const geoEl = E('span', { 'class': 'dd-nip-geo', 'id': IP_FIELDS[key].geo });
		refs.ip[key] = ipEl;
		refs.geo[key] = geoEl;
		const label = { pcol: 'PConline', ipip: 'IPIP.NET', ipsb: 'IP.SB', ipify: 'IPIFY' }[key];
		ipList.appendChild(E('div', { 'class': 'dd-nip-tile' }, [
			E('span', { 'class': 'dd-nip-label' }, label),
			ipEl,
			geoEl
		]));
	});

	const checkList = E('div', { 'class': 'dd-nip-list' });
	SITES.forEach(function(s) {
		const latEl = E('span', { 'class': 'dd-nip-lat' }, '--');
		const dotEl = E('div', { 'class': 'dd-nip-dot testing', 'title': _('Testing...') });
		const sparkEl = E('div', { 'class': 'dd-nip-spark' });
		refs.lat[s.svc] = latEl;
		refs.dot[s.svc] = dotEl;
		refs.spark[s.svc] = sparkEl;
		checkList.appendChild(E('div', { 'class': 'dd-nip-tile dd-nip-check' }, [
			E('span', { 'class': 'dd-nip-label' }, [
				brandIcon(s.icon),
				E('span', {}, s.label)
			]),
			E('div', { 'class': 'dd-nip-row' }, [
				latEl,
				E('span', { 'class': 'dd-nip-unit' }, 'ms'),
				dotEl
			]),
			sparkEl
		]));
	});

	const eyeOpen = S('svg', {
		'class': 'dd-nip-icon-btn', 'width': '18', 'height': '18',
		'viewBox': '0 0 256 256', 'fill': 'none', 'stroke': 'currentColor',
		'stroke-width': '12', 'stroke-linecap': 'round', 'stroke-linejoin': 'round'
	}, [
		S('title', {}, _('Hide IP')),
		S('path', { 'd': 'M128,56C48,56,16,128,16,128s32,72,112,72,112-72,112-72S208,56,128,56Z' }),
		S('circle', { 'cx': '128', 'cy': '128', 'r': '40' })
	]);
	const eyeClosed = S('svg', {
		'class': 'dd-nip-icon-btn dd-nip-hidden', 'width': '18', 'height': '18',
		'viewBox': '0 0 256 256', 'fill': 'none', 'stroke': 'currentColor',
		'stroke-width': '12', 'stroke-linecap': 'round', 'stroke-linejoin': 'round'
	}, [
		S('title', {}, _('Show IP')),
		S('line', { 'x1': '48', 'y1': '40', 'x2': '208', 'y2': '216' }),
		S('path', { 'd': 'M154.9,157.6A39.6,39.6,0,0,1,128,168a40,40,0,0,1-26.9-69.6' }),
		S('path', { 'd': 'M74,68.6C33.2,89.2,16,128,16,128s32,72,112,72a117.9,117.9,0,0,0,54-12.6' }),
		S('path', { 'd': 'M208.6,169.1C230.4,149.6,240,128,240,128S208,56,128,56a123.9,123.9,0,0,0-20.7,1.7' }),
		S('path', { 'd': 'M135.5,88.7a39.9,39.9,0,0,1,32.3,35.5' })
	]);

	const modeIcon = S('svg', {
		'class': 'dd-nip-mode-icon dd-nip-icon-btn', 'width': '20', 'height': '20',
		'viewBox': '0 0 48 48', 'fill': 'none', 'xmlns': 'http://www.w3.org/2000/svg'
	}, [
		S('title', {}, _('Router Mode')),
		S('rect', { 'x': '4', 'y': '28', 'width': '40', 'height': '14', 'rx': '2', 'fill': '#2F88FF', 'stroke': '#333', 'stroke-width': '3', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }),
		S('path', { 'd': 'M14 35L22 35', 'stroke': '#FFF', 'stroke-width': '3', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }),
		S('rect', { 'x': '30', 'y': '33', 'width': '4', 'height': '4', 'rx': '2', 'fill': '#FFF' }),
		S('path', { 'd': 'M12 28L12 8', 'stroke': '#333', 'stroke-width': '3', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }),
		S('path', { 'd': 'M36 28V8', 'stroke': '#333', 'stroke-width': '3', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' })
	]);

	const refreshIcon = S('svg', {
		'class': 'dd-nip-icon-btn', 'width': '17', 'height': '17',
		'viewBox': '0 0 24 24', 'fill': 'none', 'stroke': 'currentColor',
		'stroke-width': '2', 'xmlns': 'http://www.w3.org/2000/svg'
	}, [
		S('title', {}, _('Refresh')),
		S('path', { 'd': 'M23 4v6h-6' }),
		S('path', { 'd': 'M20.49 15a9 9 0 1 1-2.12-9.36L23 10' })
	]);

	const card = E('div', { 'class': 'dd-card dd-netcheck-card' }, [
		E('h4', { 'class': 'dd-card-title' }, _('IP & Access Check')),
		E('div', { 'class': 'dd-nip-grid' }, [
			E('div', { 'class': 'dd-nip-sec' }, [
				E('p', { 'class': 'dd-nip-title' }, [
					E('span', {}, _('IP Address')),
					E('span', { 'class': 'dd-nip-tools' }, [ eyeOpen, eyeClosed ])
				]),
				ipList
			]),
			E('div', { 'class': 'dd-nip-sec' }, [
				E('p', { 'class': 'dd-nip-title' }, [
					E('span', {}, _('Access Check')),
					E('span', { 'class': 'dd-nip-tools' }, [ modeIcon, refreshIcon ])
				]),
				checkList
			]),
			E('div', { 'class': 'dd-nip-footer' }, [
				E('p', {}, [
					document.createTextNode('Powered by '),
					E('a', {
						'href': 'https://ip.skk.moe', 'target': '_blank',
						'rel': 'noreferrer noopener'
					}, 'ip.skk.moe')
				])
			])
		])
	]);

	function addTitleOnOverflow() {
		card.querySelectorAll('.dd-nip-ip, .dd-nip-geo').forEach(function(span) {
			if (span.scrollWidth > span.clientWidth && localStorage.getItem(PRIVACY_KEY) !== 'true')
				span.setAttribute('title', span.textContent);
			else
				span.removeAttribute('title');
		});
	}

	function updateCheckCard(svc, status, latency) {
		const dot = refs.dot[svc], lat = refs.lat[svc], spk = refs.spark[svc];
		if (!dot || !lat || !spk) return;
		if (status === 'ok') {
			const lc = latencyClass(latency);
			dot.className = 'dd-nip-dot ' + lc;
			dot.title = _('Access Normal');
			lat.textContent = latency;
			lat.className = 'dd-nip-lat ' + lc;
			SpeedHistory.push(svc, latency);
			SpeedHistory.renderSparkline(svc, spk, lc);
		} else if (status === 'timeout') {
			dot.className = 'dd-nip-dot err';
			dot.title = _('Access Timed Out');
			lat.textContent = '--';
			lat.className = 'dd-nip-lat';
			spk.innerHTML = '<span class="dd-nip-spark-err">' + _('Access Timed Out') + '</span>';
		} else if (status === 'denied') {
			dot.className = 'dd-nip-dot err';
			dot.title = _('Access Denied');
			lat.textContent = '--';
			lat.className = 'dd-nip-lat';
			spk.innerHTML = '<span class="dd-nip-spark-err">' + _('Access Denied') + '</span>';
		} else {
			dot.className = 'dd-nip-dot testing';
			dot.title = _('Testing...');
			lat.textContent = '--';
			lat.className = 'dd-nip-lat';
		}
	}

	function updateIpSingle(obj) {
		if (!obj || !obj.service || !IP_FIELDS[obj.service]) return;
		const ipEl = refs.ip[obj.service];
		const geoEl = refs.geo[obj.service];
		const isPrivacy = localStorage.getItem(PRIVACY_KEY) === 'true';

		if (obj.error) {
			const cur = ipEl.textContent;
			if (!cur || cur === QUERYING || cur === MASK)
				ipEl.textContent = (obj.error === 'timeout') ? _('Timeout') : QUERYING;
			geoEl.textContent = '';
			return;
		}
		if (obj.ip)
			ipEl.textContent = isPrivacy ? MASK : obj.ip;
		if (obj.geo_hex) {
			const decoded = decodeGeoHex(obj.geo_hex);
			if (decoded) geoEl.textContent = decoded;
		} else if (obj.geo) {
			geoEl.textContent = obj.geo;
		}
		addTitleOnOverflow();
	}

	function hasIpCache() {
		return Object.keys(IP_FIELDS).some(function(k) {
			const val = refs.ip[k].textContent;
			return val && val !== QUERYING && val !== MASK;
		});
	}

	function showQueryingState() {
		const isPrivacy = localStorage.getItem(PRIVACY_KEY) === 'true';
		Object.keys(IP_FIELDS).forEach(function(k) {
			refs.ip[k].textContent = isPrivacy ? MASK : QUERYING;
			refs.geo[k].textContent = '';
		});
		addTitleOnOverflow();
	}

	function domainToSvc(domain) {
		for (let i = 0; i < SITES.length; i++)
			if (SITES[i].domain === domain) return SITES[i].svc;
		return null;
	}

	function handleDomainResult(obj) {
		const svc = domainToSvc(obj.domain);
		if (!svc) return;
		if (obj.success)
			updateCheckCard(svc, 'ok', obj.response_time);
		else if (obj.error === 'timeout')
			updateCheckCard(svc, 'timeout');
		else
			updateCheckCard(svc, 'denied');
	}

	function runRouterCheck() {
		if (routerBusy || disposed) return;
		routerBusy = true;
		const generation = ++routerGeneration;
		fs.exec('/usr/share/luci-app-daede/net-check.sh', []).then(function(res) {
			if (disposed || generation !== routerGeneration) return;
			const out = (res && res.stdout) || '';
			const seen = {};
			out.split('\n').forEach(function(line) {
				line = line.trim();
				if (!line) return;
				let obj;
				try { obj = JSON.parse(line); } catch (e) { return; }
				if (obj.service) {
					seen[obj.service] = true;
					updateIpSingle(obj);
				} else if (obj.domain) {
					handleDomainResult(obj);
				}
			});
			if (res && res.code === 0) {
				Object.keys(IP_FIELDS).forEach(function(k) {
					if (seen[k]) return;
					const el = refs.ip[k];
					const cur = el.textContent;
					if (!cur || cur === QUERYING)
						el.textContent = _('Timeout');
				});
				addTitleOnOverflow();
			} else {
				if (!hasIpCache()) showQueryingState();
				SITES.forEach(function(s) { updateCheckCard(s.svc, 'denied'); });
			}
		}).catch(function() {
			if (disposed || generation !== routerGeneration) return;
			if (!hasIpCache()) showQueryingState();
			SITES.forEach(function(s) { updateCheckCard(s.svc, 'denied'); });
		}).finally(function() {
			routerBusy = false;
		});
	}

	/* ---- browser-mode probes: run from the client, like OpenClash ---- */
	const HTTP = {
		checkerBrowser: function(svcName, domain, timeoutMs) {
			const img = new Image();
			const startTime = (+new Date());
			const t = timeoutMs || 5000;
			const timer = setTimeout(function() {
				img.onerror = img.onload = null;
				if (!disposed) updateCheckCard(svcName, 'timeout');
			}, t);
			img.onerror = function() {
				clearTimeout(timer);
				if (!disposed) updateCheckCard(svcName, 'denied');
			};
			img.onload = function() {
				clearTimeout(timer);
				if (!disposed) updateCheckCard(svcName, 'ok', (new Date()) - startTime);
			};
			img.src = 'https://' + domain + '/favicon.ico?' + (+new Date());
		},
		runCheck: function() {
			if (useRouterMode) {
				runRouterCheck();
				return;
			}
			SITES.forEach(function(s) {
				HTTP.checkerBrowser(s.svc, s.domain);
			});
		}
	};

	const browserIp = {
		fetchGeo: function(ip, key) {
			const v4 = '(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]\\d|\\d)(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]\\d|\\d)){3}';
			const v4Exact = new RegExp('^' + v4 + '$');
			let anon = ip;
			if (v4Exact.test(ip)) {
				const parts = ip.split('.');
				anon = parts[0] + '.' + parts[1] + '.' + parts[2] + '.0';
			}
			fetch('https://api.ip.sb/geoip/' + anon, { referrerPolicy: 'no-referrer-when-downgrade' })
				.then(function(r) { return r.json(); })
				.then(function(resp) {
					if (disposed) return;
					if (resp.country && resp.country !== '' && resp.isp && resp.isp !== '') {
						refs.geo[key].textContent = resp.country + ' ' + resp.isp;
					} else {
						return fetch('https://qqwry.api.skk.moe/' + anon, { referrerPolicy: 'no-referrer-when-downgrade' })
							.then(function(r2) { return r2.json(); })
							.then(function(resp2) {
								if (disposed) return;
								refs.geo[key].textContent = (resp2.geo.indexOf('skk.moe') === -1) ? resp2.geo : 'Unknown';
							});
					}
				})
				.catch(function() {})
				.finally(function() { if (!disposed) addTitleOnOverflow(); });
		},
		getPcol: function() {
			document.querySelectorAll('script[data-dip-pcol]').forEach(function(el) {
				el.parentNode.removeChild(el);
			});
			window.IPCallBack = null;
			const script = document.createElement('script');
			script.setAttribute('data-dip-pcol', '');
			script.src = 'https://whois.pconline.com.cn/ipJson.jsp?z=' + randomBetween(1, 100000000);
			window.IPCallBack = function(data) {
				jsonpActive = false;
				if (disposed) return;
				if (data && data.ip) {
					if (localStorage.getItem(PRIVACY_KEY) !== 'true')
						refs.ip.pcol.textContent = data.ip;
					const geo = [];
					if (data.pro) geo.push(data.pro);
					if (data.city) geo.push(data.city);
					if (data.addr) {
						const parts = data.addr.split(/\s+/);
						if (parts.length > 1) geo.push(parts[parts.length - 1]);
					}
					refs.geo.pcol.textContent = geo.join(' ');
				}
				addTitleOnOverflow();
			};
			jsonpActive = true;
			document.head.appendChild(script);
		},
		getIpip: function() {
			fetch('http://myip.ipip.net?z=' + randomBetween(1, 100000000))
				.then(function(r) { return r.text(); })
				.then(function(text) {
					if (disposed) return;
					const ipMatch = text.match(/当前 IP：([0-9A-Fa-f:.]+)/);
					const geoMatch = text.match(/来自于：(.+)/);
					if (ipMatch && geoMatch) {
						if (localStorage.getItem(PRIVACY_KEY) !== 'true')
							refs.ip.ipip.textContent = ipMatch[1];
						refs.geo.ipip.textContent = geoMatch[1].trim();
						addTitleOnOverflow();
					}
				})
				.catch(function() {});
		},
		getIpify: function() {
			fetch('https://api.ipify.org/?format=json&z=' + randomBetween(1, 100000000))
				.then(function(r) { return r.json(); })
				.then(function(data) {
					if (disposed) return;
					if (localStorage.getItem(PRIVACY_KEY) !== 'true')
						refs.ip.ipify.textContent = data.ip;
					browserIp.fetchGeo(data.ip, 'ipify');
				})
				.catch(function() {});
		},
		getIpsb: function() {
			fetch('https://api.ip.sb/geoip?z=' + randomBetween(1, 100000000))
				.then(function(r) { return r.json(); })
				.then(function(data) {
					if (disposed) return;
					if (localStorage.getItem(PRIVACY_KEY) !== 'true')
						refs.ip.ipsb.textContent = data.ip;
					refs.geo.ipsb.textContent = (data.country || '') + ' ' + (data.isp || '');
					addTitleOnOverflow();
				})
				.catch(function() {});
		},
		load: function() {
			browserIp.getPcol();
			browserIp.getIpip();
			browserIp.getIpify();
			browserIp.getIpsb();
		}
	};

	function clearAllIntervals() {
		if (refreshHttp) { clearInterval(refreshHttp); refreshHttp = null; }
		if (refreshIp) { clearInterval(refreshIp); refreshIp = null; }
	}

	function startHttpInterval() {
		if (refreshHttp) clearInterval(refreshHttp);
		refreshHttp = setInterval(function() {
			if (!disposed) HTTP.runCheck();
		}, randomBetween(INTERVAL.HTTP_CHECK_MIN, INTERVAL.HTTP_CHECK_MAX));
	}

	function startIpInterval() {
		if (refreshIp) clearInterval(refreshIp);
		if (localStorage.getItem(PRIVACY_KEY) === 'true') return;
		refreshIp = setInterval(function() {
			if (disposed) return;
			if (useRouterMode)
				runRouterCheck();
			else
				browserIp.load();
		}, randomBetween(INTERVAL.IP_CHECK_MIN, INTERVAL.IP_CHECK_MAX));
	}

	function showAllGhosts() {
		SITES.forEach(function(s) {
			SpeedHistory.renderSparkline(s.svc, refs.spark[s.svc]);
		});
	}

	function setMasked() {
		Object.keys(IP_FIELDS).forEach(function(k) {
			refs.ip[k].textContent = MASK;
			refs.geo[k].textContent = '';
		});
		addTitleOnOverflow();
	}

	function updateEyeIcon(open) {
		eyeOpen.classList.toggle('dd-nip-hidden', !open);
		eyeClosed.classList.toggle('dd-nip-hidden', open);
	}

	function togglePrivacy() {
		const isOpen = !eyeOpen.classList.contains('dd-nip-hidden');
		if (isOpen) {
			if (refreshIp) { clearInterval(refreshIp); refreshIp = null; }
			localStorage.setItem(PRIVACY_KEY, 'true');
			updateEyeIcon(false);
			setMasked();
		} else {
			updateEyeIcon(true);
			localStorage.removeItem(PRIVACY_KEY);
			showQueryingState();
			if (useRouterMode) runRouterCheck(); else browserIp.load();
			startIpInterval();
		}
	}

	function updateModeIcon() {
		const rect = modeIcon.querySelector('rect[x="4"]');
		const paths = modeIcon.querySelectorAll('path');
		const smallRect = modeIcon.querySelector('rect[x="30"]');
		const title = modeIcon.querySelector('title');
		if (useRouterMode) {
			rect.setAttribute('fill', '#2F88FF');
			rect.setAttribute('stroke', '#333');
			paths[0].setAttribute('stroke', '#FFF');
			paths[1].setAttribute('stroke', '#333');
			paths[2].setAttribute('stroke', '#333');
			smallRect.setAttribute('fill', '#FFF');
			if (title) title.textContent = _('Router Mode');
		} else {
			rect.setAttribute('fill', '#6B7280');
			rect.setAttribute('stroke', '#9CA3AF');
			paths[0].setAttribute('stroke', '#D1D5DB');
			paths[1].setAttribute('stroke', '#9CA3AF');
			paths[2].setAttribute('stroke', '#9CA3AF');
			smallRect.setAttribute('fill', '#D1D5DB');
			if (title) title.textContent = _('Browser Mode');
		}
	}

	function toggleMode() {
		useRouterMode = !useRouterMode;
		localStorage.setItem(MODE_KEY, useRouterMode ? 'true' : 'false');
		updateModeIcon();
		clearAllIntervals();
		if (useRouterMode)
			initRouterMode();
		else
			initBrowserMode();
	}

	function initRouterMode() {
		if (refreshIp) { clearInterval(refreshIp); refreshIp = null; }
		if (localStorage.getItem(PRIVACY_KEY) === 'true') setMasked();
		showAllGhosts();
		runRouterCheck();
		HTTP.runCheck();
		startHttpInterval();
		startIpInterval();
	}

	function initBrowserMode() {
		if (refreshIp) { clearInterval(refreshIp); refreshIp = null; }
		if (localStorage.getItem(PRIVACY_KEY) === 'true')
			setMasked();
		else
			showQueryingState();
		showAllGhosts();
		browserIp.load();
		HTTP.runCheck();
		startHttpInterval();
		startIpInterval();
	}

	function refreshAll() {
		clearAllIntervals();
		if (useRouterMode) {
			if (localStorage.getItem(PRIVACY_KEY) === 'true') setMasked();
			runRouterCheck();
		} else {
			if (localStorage.getItem(PRIVACY_KEY) === 'true')
				setMasked();
			else
				showQueryingState();
			browserIp.load();
		}
		HTTP.runCheck();
		startHttpInterval();
		startIpInterval();
		return false;
	}

	eyeOpen.addEventListener('click', function(ev) { ev.preventDefault(); togglePrivacy(); });
	eyeClosed.addEventListener('click', function(ev) { ev.preventDefault(); togglePrivacy(); });
	modeIcon.addEventListener('click', function(ev) { ev.preventDefault(); toggleMode(); });
	refreshIcon.addEventListener('click', function(ev) { ev.preventDefault(); refreshAll(); });

	const savedMode = localStorage.getItem(MODE_KEY);
	useRouterMode = (savedMode !== 'false');
	updateModeIcon();
	if (localStorage.getItem(PRIVACY_KEY) === 'true')
		updateEyeIcon(false);
	else
		updateEyeIcon(true);

	if (useRouterMode)
		initRouterMode();
	else
		initBrowserMode();

	card._ddCleanup = function() {
		disposed = true;
		routerGeneration++;
		clearAllIntervals();
		if (jsonpActive) {
			document.querySelectorAll('script[data-dip-pcol]').forEach(function(el) {
				el.parentNode.removeChild(el);
			});
			window.IPCallBack = null;
			jsonpActive = false;
		}
	};

	return card;
}

return baseclass.extend({
	renderNetCheckCard: renderNetCheckCard
});
