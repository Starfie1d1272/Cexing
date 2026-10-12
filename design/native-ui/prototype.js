'use strict';
// Original offline design simulation. No platform, HTTP, storage or clipboard access.
const scenes={first:'首次使用',import:'导入订阅',override:'选择覆写',preview:'差异预览',invalid:'校验失败',idle:'未连接',auth:'授权说明',denied:'授权未完成',connecting:'连接中',connected:'内核就绪',disconnecting:'断开中',failed:'连接失败',profiles:'订阅管理',update:'订阅更新',updateFailed:'更新失败',settings:'设置',restore:'恢复设置',diagnostics:'诊断',report:'诊断预览',panel:'面板衔接',panelFailed:'面板异常'};
let scene='first',session='idle',hasProfile=false,authorized=false,method='URL',policy='none',autoRestore=true,autoUpdate=false;
const params=new URLSearchParams(location.search);const $=s=>document.querySelector(s);
const b=(label,action,kind='')=>`<button class="${kind}" data-action="${action}">${label}</button>`;
const card=(title,body)=>`<section class="card"><h3>${title}</h3>${body}</section>`;
function go(next){scene=next;render();$('#content').scrollTop=0;}
function home(){go(session);}
function render(){
 const tab=['profiles','import','override','preview','invalid','update','updateFailed'].includes(scene)?'profiles':['settings','restore','diagnostics','report'].includes(scene)?'settings':'home';
 $('#scene').value=scene;
 $('#header').innerHTML=`<h1>${tab==='profiles'?'订阅':tab==='settings'?'设置':'连接'}</h1>${['first','idle','connected','profiles','settings'].includes(scene)?'<span class="tag">原生</span>':b('返回','back')}`;
 $('#nav').innerHTML=[['连接','home'],['订阅','profiles'],['设置','settings']].map(([label,key])=>`<button data-action="${key}" ${tab===key?'aria-current="page"':''}>${label}</button>`).join('');
 let content='';
 switch(scene){
 case 'first':content=`<div class="hero"><div class="eyebrow">开始使用</div><h2>先添加订阅</h2><p class="muted">准备配置后，再授权连接。</p>${b('添加订阅','import','primary full')}</div><ol class="steps"><li>导入 URL、文件或剪贴板</li><li>选择覆写并查看变更</li><li>授权系统 VPN</li></ol><p class="screen-footer">节点、策略组与规则在面板管理。</p>`;break;
 case 'import':content=`<h2>导入订阅</h2><p class="muted">此处仅使用演示配置。</p><div class="choice">${['URL','文件','剪贴板'].map(x=>b(x,'method:'+x,method===x?'selected':'')).join('')}</div>${method==='URL'?'<label class="field">订阅地址<input aria-label="订阅地址" value="https://example.invalid/demo.yaml" readonly></label>':card(method==='文件'?'演示文件':'演示剪贴板','<p>demo.yaml · 合成配置</p><small>未访问文件或剪贴板。</small>')}<label class="field">显示名称<input aria-label="显示名称" value="示例订阅" readonly></label><p class="muted">来源地址默认隐藏；名称不取自令牌。</p>${b('继续','override','primary full')}`;break;
 case 'override':content=`<h2>选择覆写</h2><p class="muted">普通导入可直接继续。</p>${card('策略选择',b('沿用订阅','policy:none',policy==='none'?'primary full':'full')+b('通用策略（演示）','policy:demo',policy==='demo'?'primary full':'full'))}<div class="note">Merge 与策略转换是待实现目标，不执行 JS 或 Shell。</div>${b('校验与预览','preview','primary full')}${b('演示校验失败','invalid','full')}`;break;
 case 'preview':content=`<h2>启用前确认</h2><p class="muted">演示校验通过 · 未运行 Mihomo 校验</p>${card('本次变更',`<div class="row"><span>配置</span><strong>示例订阅</strong></div><div class="row"><span>覆写</span><strong>${policy==='demo'?'通用策略':'无'}</strong></div><div class="row"><span>平台保护字段</span><span>由宿主固定</span></div>`)}<p class="muted">启用与更新使用同一事务；失败保留有效版本。此为目标能力。</p>${b('启用配置','activate','primary full')}${b('返回修改','override','full')}`;break;
 case 'invalid':content=`<h2 class="bad">配置未通过</h2>${card('规则引用不存在','<p>规则目标「示例组」未定义。</p><small>演示错误 · 未启用新配置</small>')}<p>修改后重新校验，现有配置保持可用。</p>${b('返回修改','override','primary full')}`;break;
 case 'idle':case 'connected':case 'failed':case 'connecting':case 'disconnecting':{
 const map={idle:['未连接','配置已准备','连接','connect'],connected:['内核就绪','系统会话已就绪 · 转发健康待验证','断开','disconnect'],failed:['连接失败','内核启动超时 · 演示错误','重试','retry'],connecting:['连接中','等待内核就绪 · 还未连接','取消连接','cancel'],disconnecting:['断开中','正在释放系统会话','请稍候','noop']};const [title,sub,action,target]=map[scene];
 content=`<div class="hero"><div class="eyebrow"><span class="state-mark"></span>VPN 状态</div><h2 ${scene==='failed'?'class="bad"':''}>${title}</h2><p class="muted" role="status">${sub}</p>${scene==='connecting'?'<ol class="steps"><li>系统授权已完成</li><li>系统会话已建立</li><li>等待内核初始化</li></ol>':''}${scene==='connected'?'<div class="metrics"><div><small>上传 · 合成</small><strong>12 KB/s</strong></div><div><small>下载 · 合成</small><strong>86 KB/s</strong></div></div>':''}${scene==='disconnecting'?'<button class="full" disabled>请稍候</button>':b(action,target,'primary full')}</div>${card('当前订阅','<div class="row"><span>示例订阅<small>最近有效版本 · 演示</small></span>'+b('管理','profiles','text-link')+'</div>')}`;
 if(scene==='connecting')content+=`<div class="pair">${b('模拟就绪','ready')}${b('模拟超时','fail')}</div>`;
 if(scene==='disconnecting')content+=b('模拟释放完成','stopped','full');
 if(scene==='connected')content+=card('面板','<p class="muted">节点组、Smart、连接、规则与日志</p>'+b('打开 Zashboard','panel','full'));
 if(scene==='failed')content+=`<div class="pair">${b('查看诊断','diagnostics')}${b('恢复设置','restore')}</div>`;
 content+='<p class="screen-footer">控制面可达不代表真实流量正常。</p>';break;}
 case 'auth':content=`<div class="hero"><div class="eyebrow">系统授权前</div><h2>允许 VPN 连接</h2><p>系统将显示授权窗口。</p><p class="muted">应用通过系统 VPN 管理网络流量；排除的应用与网段不进入隧道。</p></div><div class="note">这里只演示授权结果，不仿制系统窗口。</div>${b('模拟允许','allow','primary full')}${b('模拟拒绝','denied','full')}${b('暂不连接','idle','full')}`;break;
 case 'denied':content=`<h2>授权未完成</h2><p>当前未连接。可以稍后重试。</p>${b('重新授权','auth','primary full')}${b('返回连接','idle','full')}`;break;
 case 'profiles':content=`<h2>订阅管理</h2>${hasProfile?card('示例订阅','<p><span class="tag">当前使用</span></p><small>来源已隐藏 · URL 导入 · 演示</small>'+b('更新订阅','update','full')+b('查看覆写','override','full')):'<p class="muted">还没有配置。</p>'}${b('添加订阅','import','primary full')}<p class="screen-footer">只管理来源与生成配置，不管理节点组。</p>`;break;
 case 'update':content=`<h2>更新订阅</h2>${card('准备应用','<p>重新应用已选覆写与平台保护字段。</p><small>目标事务：校验 → 保存 → 内核应用</small>')}<p>应用成功后才切换有效版本。</p>${b('模拟更新成功','updated','primary full')}${b('模拟应用失败','updateFailed','full')}`;break;
 case 'updateFailed':content=`<h2 class="bad">更新未应用</h2><p>内核拒绝新配置 · 演示错误</p>${card('保留上一有效版本','<p>订阅与当前会话保持原版本。</p><small>回滚运行配置是待实现目标。</small>')}${b('重试更新','update','primary full')}${b('返回订阅','profiles','full')}`;break;
 case 'settings':content=card('运行与恢复',`<div class="row"><span>自动更新<small>每 24 小时 · 演示</small></span>${toggle('autoUpdate',autoUpdate)}</div>`+b('恢复设置','restore','full'))+card('系统与诊断','<p class="muted">VPN 授权由系统管理。</p>'+b('查看诊断','diagnostics','full'))+'<p class="screen-footer">高级网络设置沿用实际平台能力，不在概念中承诺双栈健康。</p>';break;
 case 'restore':content=`<h2>恢复设置</h2>${card('会话恢复',`<div class="row"><span>打开应用自动恢复<small>仅上次曾成功连接</small></span>${toggle('autoRestore',autoRestore)}</div>`)}<p class="muted">主动断开或取消会撤销待恢复任务。恢复偏好不保证后台永不被系统结束。</p>${b('恢复显示偏好','resetConfirm','full')}<div id="confirm"></div>`;break;
 case 'diagnostics':content=`<h2>连接诊断</h2>${card('分别检查',`<div class="row"><span>系统 VPN 会话</span><span>${session==='connected'?'就绪（演示）':'未确认'}</span></div><div class="row"><span>Controller</span><span>${session==='connected'?'可达（演示）':'未确认'}</span></div><div class="row"><span>真实转发</span><span class="warning">待验证</span></div><div class="row"><span>配置版本</span><span>最近有效版本</span></div>`)}<p class="muted">诊断仅核对状态，不发送探测流量。</p>${b('预览诊断摘要','report','primary full')}${b('返回连接','home','full')}`;break;
 case 'report':content=`<h2>诊断摘要预览</h2>${card('分享前检查','<p>状态：待确认<br>错误：START_TIMEOUT（演示）<br>转发：未验证<br>配置：合成版本</p>')}<p class="muted">摘要排除来源地址、密钥、节点、证书与完整配置。真实实现须再次脱敏确认。</p>${b('返回诊断','diagnostics','primary full')}`;break;
 case 'panel':content=`<h2>Zashboard</h2><div class="hero"><div class="eyebrow">面板宿主 · 演示</div><h2>打开面板</h2><p class="muted">此处不复制面板内容。集成后加载固定离线资源。</p></div><p>节点组、Smart、连接、规则与日志由面板负责。</p>${b('模拟资源缺失','panelFailed','full')}${b('返回原生连接','home','primary full')}<p class="screen-footer">返回与关闭面板不停止 VPN。</p>`;break;
 case 'panelFailed':content=`<h2 class="bad">面板暂不可用</h2><p>离线资源缺失 · 演示错误</p>${card('VPN 会话独立运行','<p>面板失败不会触发断开。</p>')}${b('重试加载','panel','primary full')}${b('返回原生连接','home','full')}`;break;
 }
 $('#content').innerHTML=content;
}
function toggle(name,on){return `<button class="switch" role="switch" aria-label="${name==='autoRestore'?'打开应用自动恢复':'自动更新'}" aria-checked="${on}" data-action="toggle:${name}">${on?'已开启':'已关闭'}</button>`;}
document.addEventListener('click',event=>{
 const element=event.target.closest('[data-action]');if(!element)return;const a=element.dataset.action;
 if(a.startsWith('method:')){method=a.slice(7);render();return;}
 if(a.startsWith('policy:')){policy=a.slice(7);render();return;}
 if(a.startsWith('toggle:')){a.endsWith('autoRestore')?autoRestore=!autoRestore:autoUpdate=!autoUpdate;render();return;}
 switch(a){case 'home':home();break;case 'activate':hasProfile=true;go('idle');break;case 'connect':if(!hasProfile){go('import');break;}authorized?(session='connecting',go('connecting')):go('auth');break;case 'allow':authorized=true;session='connecting';go('connecting');break;case 'ready':session='connected';home();break;case 'fail':session='failed';home();break;case 'retry':session='connecting';go('connecting');break;case 'cancel':case 'stopped':session='idle';home();break;case 'disconnect':session='disconnecting';home();break;case 'updated':hasProfile=true;go('profiles');$('#content').insertAdjacentHTML('afterbegin','<div class="note" role="status">更新成功 · 演示结果</div>');break;case 'back':tabBack();break;case 'resetConfirm':$('#confirm').innerHTML='<div class="note">恢复主题与视觉深度，不删除订阅或恢复偏好。</div>'+b('确认恢复','reset','full')+b('取消','restore','full');break;case 'reset':$('#theme').value='light';$('#depth').value='minimal';applyStyle();go('settings');break;case 'noop':break;default:if(a in scenes)go(a);}
});
function tabBack(){if(['import','override','preview','invalid','update','updateFailed'].includes(scene))go('profiles');else if(['restore','diagnostics','report'].includes(scene))go('settings');else home();}
function applyStyle(){document.documentElement.dataset.theme=$('#theme').value;document.documentElement.dataset.arkDepth=$('#depth').value;}
$('#scene').innerHTML=Object.entries(scenes).map(([value,label])=>`<option value="${value}">${label}</option>`).join('');
$('#scene').addEventListener('change',()=>{const next=$('#scene').value;hasProfile=next!=='first';if(['idle','connecting','connected','failed','disconnecting'].includes(next)){session=next;authorized=next!=='idle';}go(next);$('.review').classList.remove('open');});
$('#theme').value=params.get('theme')==='dark'?'dark':'light';$('#depth').value=params.get('depth')==='moderate'?'moderate':'minimal';$('#theme').onchange=applyStyle;$('#depth').onchange=applyStyle;
$('#options').onclick=()=>$('.review').classList.toggle('open');applyStyle();if(params.get('scene') in scenes){scene=params.get('scene');hasProfile=scene!=='first';if(['idle','connecting','connected','failed','disconnecting'].includes(scene)){session=scene;authorized=scene!=='idle';}}render();
