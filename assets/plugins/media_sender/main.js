tide.registerTool('send_media', async (args, context) => {
  const previous = await context.chat.getStatus(args.requestId);
  if (previous.status === 'sent') return previous;
  if (args.kind === 'text') {
    return await context.chat.sendText({text: args.text, requestId: args.requestId});
  }
  const resource = await context.media.download({url: args.url, kind: args.kind});
  try {
    const options = {resourceId: resource.resourceId, requestId: args.requestId};
    if (args.kind === 'image') return await context.chat.sendImage(options);
    if (args.kind === 'video') return await context.chat.sendVideo(options);
    return await context.chat.sendAudio(options);
  } finally {
    await context.media.release(resource.resourceId);
  }
});
