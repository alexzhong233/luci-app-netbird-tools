'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var TOOL = '/usr/bin/netbird-compat-ctl';

function call(args) {
	return fs.exec(TOOL, args).then(function(res) {
		var text = ((res && res.stdout) || '') + ((res && res.stderr) || '');
		return { code: res ? res.code : 1, text: text.replace(/\s+$/, '') };
	}).catch(function(err) {
		return { code: 1, text: '执行失败：' + (err && err.message ? err.message : err) };
	});
}

function parseStatus(text) {
	var out = {};

	(text || '').split('\n').forEach(function(line) {
		var idx = line.indexOf('=');

		if (idx > 0)
			out[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
	});

	return out;
}

function flag(value) {
	return String(value) === '1';
}

function badge(ok, onText, offText) {
	return E('span', {
		'class': 'label ' + (ok ? 'success' : 'warning')
	}, [ ok ? onText : offText ]);
}

function plain(text, cls) {
	return E('span', { 'class': cls || '' }, [ text ]);
}

return view.extend({
	load: function() {
		return call([ 'status' ]);
	},

	buildRows: function(st) {
		var running = parseInt(st.watch_running || '0', 10);
		var procs = parseInt(st.watch_procs || String(running), 10);
		var wstate = st.watch_state || (running === 0 ? 'off' : (running > 1 ? 'stray' : 'ok'));
		var wt0Rules = parseInt(st.wt0_rules || '0', 10);
		var compatRules = parseInt(st.compat_rules || '0', 10);

		/* 守护脚本会 fork 出看门狗和读 nft monitor 的子 shell，命令行与主进程
		 * 一模一样，按字符串数进程会把一个正常实例数成三个。后端已经按父子关系
		 * 排除掉子 shell，这里只显示独立实例数，子 shell 的数量单独标注。 */
		var watchText, watchOk;

		if (wstate === 'ok') {
			watchOk = true;
			watchText = _('运行中（1 个实例）');
		} else if (wstate === 'orphan') {
			watchOk = false;
			watchText = _('1 个，但模式是 off');
		} else if (wstate === 'stray') {
			watchOk = false;
			watchText = running + ' ' + _('个实例，存在遗留进程');
		} else {
			watchOk = true;
			watchText = _('未运行');
		}

		if (procs > running)
			watchText += ' · ' + _('子进程') + ' ' + (procs - running);

		/* value 可以是字符串，也可以是节点数组（同一格里放多个 badge）。
		 * 数组必须直接展开成 td 的子节点，否则 [ value ] 会把它当成单个
		 * 子节点，E() 不递归展开数组，最终渲染成 "[object HTMLSpanElement]"。 */
		function row(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:38%' }, [ label ]),
				E('td', { 'class': 'td' }, Array.isArray(value) ? value : [ value ])
			]);
		}

		return [
			row(_('NetBird 服务'), [
				badge(flag(st.netbird_enabled), _('开机自启'), _('未设自启')),
				' ',
				badge(flag(st.netbird_running), _('运行中'), _('未运行'))
			]),
			row(_('管理连接'), badge(st.netbird_state === 'Connected',
				_('已连接'), st.netbird_state || _('未知'))),
			row(_('NetBird IP'), plain(st.netbird_ip || '—')),
			row(_('可访问网段'), plain(st.networks || '—')),
			row(_('wt0 隧道接口'), badge(flag(st.wt0), _('存在'), _('缺失'))),
			row(_('wt0 转发规则'), badge(wt0Rules > 0,
				wt0Rules + ' ' + _('条'), _('0 条，远端进不来内网'))),
			row(_('兼容守护模式'), plain(st.mode === 'watch'
				? _('watch（事件驱动）')
				: _('off（关闭，推荐保持）'))),
			row(_('守护实例'), badge(watchOk, watchText, watchText)),
			row(_('兼容规则条数'), badge(compatRules > 0,
				String(compatRules), _('0')))
		];
	},

	render: function(result) {
		var self = this;
		var st = parseStatus(result ? result.text : '');
		var tbody = E('tbody', {}, this.buildRows(st));

		var out = E('pre', {
			'id': 'nb-out',
			'style': 'max-height:22rem;overflow:auto;white-space:pre-wrap;word-break:break-all;margin:0'
		}, [ _('（还没有执行任何操作）') ]);

		function setOut(text) {
			out.textContent = text || _('（无输出）');
		}

		function refresh() {
			return call([ 'status' ]).then(function(res) {
				var fresh = parseStatus(res.text);

				while (tbody.firstChild)
					tbody.removeChild(tbody.firstChild);

				self.buildRows(fresh).forEach(function(tr) {
					tbody.appendChild(tr);
				});
			});
		}

		function run(args, label) {
			setOut(_('正在执行：') + label + ' ...');

			return call(args).then(function(res) {
				setOut('$ netbird-compat-ctl ' + args.join(' ') + '\n\n' + (res.text || _('（无输出）')));
				return refresh();
			});
		}

		var modeSel = E('select', {
			'id': 'nb-mode',
			'class': 'cbi-input-select',
			'style': 'min-width:16rem'
		}, [
			E('option', { 'value': 'off' }, [ _('off — 关闭（默认）') ]),
			E('option', { 'value': 'watch' }, [ _('watch — 事件驱动（推荐）') ])
		]);

		modeSel.value = (st.mode === 'watch') ? 'watch' : 'off';

		var btnMode = E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': function(ev) {
				ev.preventDefault();
				return run([ 'mode', modeSel.value ], _('切换模式'));
			}
		}, [ _('应用') ]);

		function actionButton(label, args) {
			return E('button', {
				'class': 'btn cbi-button',
				'style': 'margin-right:.5rem;margin-bottom:.5rem',
				'click': function(ev) {
					ev.preventDefault();
					return run(args, label);
				}
			}, [ label ]);
		}

		poll.add(function() {
			return refresh();
		}, 10);

		return E('div', {}, [
			E('h2', {}, [ _('NetBird 工具') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('这里只看和 NetBird 有关的本地状态。兼容规则守护用于 NetBird 与 PassWall 同时运行时补回被覆盖的 nftables 标记，两者都不用时保持 off 即可。')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, [ tbody ])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('兼容守护模式') ]),
				E('div', {}, [
					modeSel,
					' ',
					btnMode
				]),
				E('div', { 'class': 'cbi-map-descr', 'style': 'margin-top:.5rem' }, [
					_('只有 watch 一种守护：事件驱动，NetBird 重建规则时立即补回，另有兜底定时检查。不用 PassWall 就保持 off。')
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('操作') ]),
				E('div', {}, [
					actionButton(_('立即补一次规则'), [ 'once' ]),
					actionButton(_('重建 wt0 转发'), [ 'netbird-restart' ]),
					actionButton(_('查看日志'), [ 'log' ])
				]),
				out
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
