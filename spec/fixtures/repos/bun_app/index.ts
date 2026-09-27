const server = Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  fetch() {
    return new Response("ok");
  },
});
console.log(`listening on ${server.port}`);
