const {lookup}=require('./tools/lookup');
tide.registerTool('lookup',lookup);
tide.on('ui.action',async ({action,values})=>{if(action!=='lookup')throw Error('未知操作');return lookup(values);});
