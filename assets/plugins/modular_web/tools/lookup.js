const messages=require('../services/messages');
exports.lookup=async args=>({text:await messages.lookup(args.keyword)});
