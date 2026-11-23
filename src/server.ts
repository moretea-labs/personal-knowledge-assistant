// @ts-nocheck
import { createServer } from 'node:http';
import { loadConfig } from './config.js';
import { PKSService } from './core/service.js';
import { makeHandler } from './api/router.js';
import { ForgeSocketServer } from './forge/socket-server.js';

const config = await loadConfig(
  process.argv.find(argument => argument.startsWith('--pks-config='))?.split('=').slice(1).join('=')
);
const service = await new PKSService(config).open();
service.startWatching();

let forgeSocket: ForgeSocketServer | undefined;
if (config.forge?.enabled !== false && config.forge?.socketPath) {
  forgeSocket = await new ForgeSocketServer(service, config.forge.socketPath).start();
}

const server = createServer(makeHandler(service));
server.listen(config.port, config.host, () => {
  console.log(
    `PKS API http://${config.host}:${config.port} data=${config.dataDir}${config.forge?.socketPath ? ` forge=${config.forge.socketPath}` : ''}`
  );
});

let stopping = false;
const stop = async (): Promise<void> => {
  if (stopping) return;
  stopping = true;
  service.stopWatching();
  await forgeSocket?.stop().catch(() => {});
  server.close(() => {
    service.db.close();
    process.exit(0);
  });
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
