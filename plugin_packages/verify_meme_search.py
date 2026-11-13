import json, subprocess, urllib.request, urllib.parse, zipfile, hashlib
from pathlib import Path
root = Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev/plugin_packages/meme_search')
u = 'https://www.bing.com/images/search?q=' + urllib.parse.quote('猫猫无语 表情包') + '&first=1&count=12&adlt=strict'
r = urllib.request.urlopen(urllib.request.Request(u, headers={'User-Agent':'Mozilla/5.0','Accept-Language':'zh-CN,zh;q=0.9'}), timeout=10)
body = r.read().decode()
print('Live HTTP', r.status, 'bytes', len(body.encode()))
script = r'''
const vm = require('node:vm'), assert = require('node:assert/strict');
let input = '';
process.stdin.on('data', c => input += c);
process.stdin.on('end', async () => {
 const x = JSON.parse(input); let handler, mode = 'live';
 const fixture = '<a m="' + JSON.stringify({murl:'https://example.com/a.gif',purl:'https://example.com/source',t:'测试'}).replace(/"/g,String.fromCharCode(38)+'quot;') + '"></a>';
 vm.runInNewContext(x.source, {tide:{registerTool(n,h){assert.equal(n,'search_memes');handler=h},async request(o){assert.ok(o.url.startsWith('https://'));if(mode==='fail')throw Error('offline');return {status:200,body:mode==='live'?x.body:fixture+fixture}}}});
 try {
  let result = await handler({keyword:'猫猫无语'});
  assert.ok(result.count>0,'live parser returned no results');assert.ok(result.count<=6);assert.equal(result.delivery.sent,false);
  console.log('Live parsed candidates:', result.count, JSON.stringify(result.candidates[0]));
  mode='fixture';result=await handler({keyword:'谢谢',limit:10});assert.equal(result.count,1);console.log('PASS deduplication and entity decoding');
  await assert.rejects(handler({keyword:'   '}));await assert.rejects(handler({keyword:'hi',limit:0}));console.log('PASS input validation');
  mode='fail';result=await handler({keyword:'开心'});assert.equal(result.status,'unavailable');assert.equal(result.count,0);assert.equal(result.errors.length,2);console.log('PASS network failure handling');
 } catch(e) { console.error(e);process.exitCode=1; }
});
'''
p = subprocess.run(['node','-e',script], input=json.dumps({'source':(root/'main.js').read_text(),'body':body}), text=True, capture_output=True)
print(p.stdout, p.stderr)
if p.returncode: raise SystemExit(p.returncode)
out = Path('/sdcard/Download/yutan123-meme-search-1.0.0.zip')
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
    for name in ['manifest.json','main.js','README.md']: z.write(root/name,name)
with zipfile.ZipFile(out) as z:
    assert z.testzip() is None
    assert json.loads(z.read('manifest.json'))['author']=='yutan123'
print('ZIP:',out,'bytes:',out.stat().st_size,'SHA256:',hashlib.sha256(out.read_bytes()).hexdigest())
