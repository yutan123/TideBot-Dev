exports.lookup=async keyword=>{
 const key=String(keyword||'').trim();
 if(!key||key.length>80)throw Error('请输入1～80字关键词');
 const data=await tide.resources.readJson('resources/messages.json');
 return Object.prototype.hasOwnProperty.call(data,key)?data[key]:'暂无匹配内容，试试：你好、谢谢';
};
